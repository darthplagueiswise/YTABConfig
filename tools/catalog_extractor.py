#!/usr/bin/env python3
"""Extract a deterministic BOOL-selector catalog from decompiler C output."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Iterator, Mapping

try:
    from tools.catalog_model import (
        SCHEMA_VERSION,
        ContractError,
        dump_json,
        merge_curated,
        validate_catalog,
    )
except ModuleNotFoundError:
    from catalog_model import (
        SCHEMA_VERSION,
        ContractError,
        dump_json,
        merge_curated,
        validate_catalog,
    )


CLASS_NAMES = ("YTColdConfig", "YTGlobalConfig", "YTHotConfig")
HEADER_RE = re.compile(
    r"^\s*(?://|/\*)\s*(?:Function:\s*)?"
    r"-\[(YTColdConfig|YTGlobalConfig|YTHotConfig) ([^\]]+)\]"
    r"(?:\s*@\s*((?:0x)?[0-9A-Fa-f]+))?\s*(?:\*/)?\s*$"
)
DIRECT_CALL_RE = re.compile(
    r"-\[(YTColdConfig|YTGlobalConfig|YTHotConfig) ([A-Za-z_][A-Za-z0-9_:]*)\]"
)
EXPERIMENT_RE = re.compile(r'objectForKey:",\s*(\d+)\)')
RETURN_STATEMENT_RE = re.compile(r"\breturn\b\s*([^;]*)\s*;")
BOOL_DECLARATION_RE_TEMPLATE = (
    r"^\s*(?:bool|BOOL|_BOOL8|unsigned\s+__int8)\s+"
    r"(?:(?:__cdecl|__fastcall|__thiscall)\s+)?"
    r"-\[{class_name}\s+{selector}\]\s*\("
)
BOOL_DEFINITION_LINE_RE = re.compile(
    r"^\s*(?:bool|BOOL|_BOOL8|unsigned\s+__int8)\s+"
    r"(?:(?:__cdecl|__fastcall|__thiscall)\s+)?"
    r"-\[(?:YTColdConfig|YTGlobalConfig|YTHotConfig)\s+"
)
ELSE_ASSIGN_RE = re.compile(
    r"\belse\s*(?:\{\s*)?(?:LOBYTE\((?P<low>[A-Za-z_][A-Za-z0-9_]*)\)|"
    r"(?P<plain>[A-Za-z_][A-Za-z0-9_]*))\s*=\s*(?P<value>[01])\s*;",
    re.DOTALL,
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _mechanical_title(selector: str) -> str:
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", selector)
    spaced = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", spaced)
    return spaced.replace("_", " ").strip() or selector


def _iter_sections(path: Path) -> Iterator[tuple[int, int, re.Match[str], str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    headers: list[tuple[int, re.Match[str]]] = []
    for index, line in enumerate(lines):
        match = HEADER_RE.match(line)
        if match:
            headers.append((index, match))
    for position, (start, match) in enumerate(headers):
        end = headers[position + 1][0] - 1 if position + 1 < len(headers) else len(lines) - 1
        yield start + 1, end + 1, match, "\n".join(lines[start : end + 1])


def _infer_default(
    block: str,
    evidence_id: str,
) -> dict[str, Any] | None:
    returns = [expression.strip() for expression in RETURN_STATEMENT_RE.findall(block)]
    if len(returns) != 1 or len(re.findall(r"\breturn\b", block)) != 1:
        return None
    return_expression = returns[0]
    if return_expression in {"0", "1"}:
        return {
            "value": return_expression == "1",
            "confidence": "High",
            "method": "constant-return",
            "evidence": [evidence_id],
        }
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", return_expression):
        return None
    if re.search(r"\b(?:switch|goto|while|do|for)\b|\?", block):
        return None
    return_variable = return_expression
    structural_block = re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        " ",
        block,
        flags=re.DOTALL,
    )
    if_count = len(re.findall(r"\bif\s*\(", structural_block))
    else_count = len(re.findall(r"\belse\b", structural_block))
    candidates: list[bool] = []
    fallback_matches = list(ELSE_ASSIGN_RE.finditer(block))
    if len(fallback_matches) != else_count:
        return None
    for match in fallback_matches:
        variable = match.group("low") or match.group("plain")
        if variable == return_variable:
            candidates.append(match.group("value") == "1")
    if not candidates or len(set(candidates)) != 1:
        return None
    inferred_value = candidates[0]
    if if_count != else_count:
        safe_experiment_initialization = (
            if_count == else_count + 1
            and inferred_value is False
            and re.search(
                rf"\b{re.escape(return_variable)}\s*=\s*[^;]*"
                r"hasExperimentFlags[^;]*;",
                structural_block,
            )
            is not None
        )
        if not safe_experiment_initialization:
            return None
    if candidates:
        return {
            "value": inferred_value,
            "confidence": "High",
            "method": "explicit-fallback-assignment",
            "evidence": [evidence_id],
        }
    return None


def _normalize_counts(
    counts: Mapping[str, int] | None,
    *,
    default: int | None,
    label: str,
) -> dict[str, int | None]:
    unknown = set(counts or {}) - set(CLASS_NAMES)
    if unknown:
        raise ContractError(f"{label} contains unsupported class: {sorted(unknown)[0]}")
    result: dict[str, int | None] = {}
    for class_name in CLASS_NAMES:
        value = (counts or {}).get(class_name, default)
        if value is not None and (
            not isinstance(value, int) or isinstance(value, bool) or value < 0
        ):
            raise ContractError(f"{label}.{class_name} must be a non-negative integer")
        result[class_name] = value
    return result


def _extract_definitions(
    source_root: Path,
    *,
    minimum_counts: Mapping[str, int] | None,
    expected_counts: Mapping[str, int] | None,
) -> tuple[list[dict[str, Any]], list[dict[str, str]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    source_files: list[dict[str, str]] = []
    minimums = _normalize_counts(minimum_counts, default=1, label="minimum_counts")
    expected = _normalize_counts(expected_counts, default=None, label="expected_counts")
    class_counts: list[dict[str, Any]] = []
    for class_name in CLASS_NAMES:
        path = source_root / f"{class_name}.c"
        if not path.is_file():
            raise FileNotFoundError(f"missing decompiler class file: {path}")
        relative_path = path.relative_to(source_root).as_posix()
        source_files.append({"path": relative_path, "sha256": _sha256(path)})
        sections = list(_iter_sections(path))
        candidate_count = 0
        extracted_count = 0
        for line_start, line_end, header, block in sections:
            found_class, selector, address = header.groups()
            signature = re.search(
                BOOL_DECLARATION_RE_TEMPLATE.format(
                    class_name=re.escape(found_class),
                    selector=re.escape(selector),
                ),
                block,
                re.MULTILINE,
            )
            if signature is None:
                continue
            candidate_count += 1
            evidence_id = f"definition:{found_class}:{selector}"
            experiment_ids = EXPERIMENT_RE.findall(block)
            experiment_id = None
            if (
                len(experiment_ids) == 1
                and "hasExperimentFlags" in block
                and "experimentFlags" in block
            ):
                experiment_id = int(experiment_ids[0])
            inference = _infer_default(block, evidence_id)
            records.append(
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "class": found_class,
                    "selector": selector,
                    "experimentID": experiment_id,
                    "native": {
                        "value": None,
                        "source": "unavailable",
                        "capturedAt": None,
                    },
                    "override": {"mode": "inherit", "value": None},
                    "effective": {"value": None, "source": "unavailable"},
                    "title": _mechanical_title(selector),
                    "summary": None,
                    "category": "Uncategorized",
                    "risk": "Unknown",
                    "dependencies": [],
                    "conflicts": [],
                    "status": "Unknown",
                    "evidence": [
                        {
                            "id": evidence_id,
                            "kind": "definition",
                            "source": {
                                "path": relative_path,
                                "lineStart": line_start,
                                "lineEnd": line_end,
                                "address": address,
                            },
                            "excerpt": f"-[{found_class} {selector}]",
                        }
                    ],
                    "callsites": [],
                    "callsiteSummary": {
                        "observed": 0,
                        "stored": 0,
                        "truncated": False,
                    },
                    "defaultInference": inference,
                    "verifiedVersions": [],
                    "curationEvidence": [],
                    "curationRationale": None,
                }
            )
            extracted_count += 1
        minimum = minimums[class_name]
        exact = expected[class_name]
        if extracted_count < minimum:
            raise ContractError(
                f"{class_name} extracted count {extracted_count} is below minimum {minimum}"
            )
        if exact is not None and extracted_count != exact:
            raise ContractError(
                f"{class_name} extracted count {extracted_count} does not match expected {exact}"
            )
        class_counts.append(
            {
                "class": class_name,
                "headers": len(sections),
                "candidates": candidate_count,
                "extracted": extracted_count,
                "minimum": minimum,
                "expected": exact,
            }
        )
    records.sort(key=lambda item: (item["class"], item["selector"]))
    source_files.sort(key=lambda item: item["path"])
    return records, source_files, class_counts


def _iter_c_files(source_root: Path) -> Iterator[Path]:
    for current, directories, files in os.walk(source_root):
        directories.sort()
        for filename in sorted(files):
            if filename.endswith(".c"):
                yield Path(current) / filename


def _mask_noncode_line(line: str, in_block_comment: bool) -> tuple[str, bool]:
    masked = list(line)
    index = 0
    quote: str | None = None
    while index < len(line):
        if in_block_comment:
            end = line.find("*/", index)
            if end == -1:
                for position in range(index, len(line)):
                    masked[position] = " "
                return "".join(masked), True
            for position in range(index, end + 2):
                masked[position] = " "
            index = end + 2
            in_block_comment = False
            continue
        if quote is not None:
            masked[index] = " "
            if line[index] == "\\":
                if index + 1 < len(line):
                    masked[index + 1] = " "
                index += 2
                continue
            if line[index] == quote:
                quote = None
            index += 1
            continue
        if line.startswith("//", index):
            for position in range(index, len(line)):
                masked[position] = " "
            break
        if line.startswith("/*", index):
            masked[index] = masked[index + 1] = " "
            index += 2
            in_block_comment = True
            continue
        if line[index] in {'"', "'"}:
            quote = line[index]
            masked[index] = " "
        index += 1
    return "".join(masked), in_block_comment


def _iter_direct_call_lines(
    source_root: Path,
) -> Iterator[tuple[str, int, str, str]]:
    for path in _iter_c_files(source_root):
        relative_path = path.relative_to(source_root).as_posix()
        in_block_comment = False
        with path.open("r", encoding="utf-8", errors="replace") as source:
            for line_number, line in enumerate(source, start=1):
                raw_line = line.rstrip("\r\n")
                masked_line, in_block_comment = _mask_noncode_line(
                    raw_line, in_block_comment
                )
                if DIRECT_CALL_RE.search(masked_line):
                    yield relative_path, line_number, raw_line, masked_line


def _add_bounded_callsite(
    callsites: list[dict[str, Any]],
    callsite: dict[str, Any],
    *,
    limit: int,
) -> None:
    if limit == 0:
        return
    if any(item["id"] == callsite["id"] for item in callsites):
        return
    callsites.append(callsite)
    callsites.sort(
        key=lambda item: (
            item["source"]["path"],
            item["source"]["lineStart"],
            item["id"],
        )
    )
    del callsites[limit:]


def _collect_callsites(
    source_root: Path,
    records: list[dict[str, Any]],
    max_callsites: int,
) -> None:
    if max_callsites < 0:
        raise ValueError("max_callsites must be non-negative")
    by_key = {(item["class"], item["selector"]): item for item in records}
    observed = {key: 0 for key in by_key}
    seen: set[str] = set()
    for relative_path, line_number, line, masked_line in _iter_direct_call_lines(
        source_root
    ):
        if BOOL_DEFINITION_LINE_RE.match(masked_line):
            continue
        for match in DIRECT_CALL_RE.finditer(masked_line):
            key = match.groups()
            record = by_key.get(key)
            if record is None:
                continue
            callsite_id = f"callsite:{key[0]}:{key[1]}:{relative_path}:{line_number}"
            if callsite_id in seen:
                continue
            seen.add(callsite_id)
            observed[key] += 1
            _add_bounded_callsite(
                record["callsites"],
                {
                    "id": callsite_id,
                    "kind": "callsite",
                    "source": {
                        "path": relative_path,
                        "lineStart": line_number,
                        "lineEnd": line_number,
                        "address": None,
                    },
                    "excerpt": line.strip()[:300],
                },
                limit=max_callsites,
            )
    for key, record in by_key.items():
        stored = len(record["callsites"])
        record["callsiteSummary"] = {
            "observed": observed[key],
            "stored": stored,
            "truncated": stored < observed[key],
        }


def extract_catalog(
    source_root: str | Path,
    *,
    youtube_version: str,
    generated_at: str,
    curated: Mapping[str, Any] | None = None,
    include_callsites: bool = False,
    max_callsites: int = 20,
    minimum_counts: Mapping[str, int] | None = None,
    expected_counts: Mapping[str, int] | None = None,
) -> dict[str, Any]:
    root = Path(source_root)
    if max_callsites < 0:
        raise ContractError("max_callsites must be non-negative")
    records, source_files, class_counts = _extract_definitions(
        root,
        minimum_counts=minimum_counts,
        expected_counts=expected_counts,
    )
    if include_callsites:
        _collect_callsites(root, records, max_callsites)
    records = merge_curated(records, curated, youtube_version=youtube_version)
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "youtubeVersion": youtube_version,
        "generatedAt": generated_at,
        "source": {
            "kind": "decompiler-c-files",
            "root": ".",
            "files": source_files,
            "classCounts": class_counts,
            "callsiteScan": {
                "enabled": include_callsites,
                "limitPerRecord": max_callsites,
            },
        },
        "records": records,
    }
    validate_catalog(document)
    return document


def write_catalog(document: Mapping[str, Any], output_path: str | Path) -> None:
    validate_catalog(document)
    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(dump_json(document), encoding="utf-8")


def _parse_count_arguments(values: list[str], option: str) -> dict[str, int] | None:
    if not values:
        return None
    result: dict[str, int] = {}
    for raw_value in values:
        class_name, separator, count_text = raw_value.partition("=")
        if separator != "=" or class_name not in CLASS_NAMES:
            raise ContractError(f"{option} must use CLASS=COUNT for a supported class")
        if class_name in result:
            raise ContractError(f"{option} repeats class: {class_name}")
        try:
            count = int(count_text)
        except ValueError as error:
            raise ContractError(f"{option}.{class_name} must be an integer") from error
        if count < 0:
            raise ContractError(f"{option}.{class_name} must be non-negative")
        result[class_name] = count
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--youtube-version", required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--curated", type=Path)
    parser.add_argument("--include-callsites", action="store_true")
    parser.add_argument("--max-callsites", type=int, default=20)
    parser.add_argument(
        "--minimum-count",
        action="append",
        default=[],
        metavar="CLASS=COUNT",
    )
    parser.add_argument(
        "--expected-count",
        action="append",
        default=[],
        metavar="CLASS=COUNT",
    )
    args = parser.parse_args()
    curated = None
    if args.curated:
        curated = json.loads(args.curated.read_text(encoding="utf-8"))
    document = extract_catalog(
        args.source_root,
        youtube_version=args.youtube_version,
        generated_at=args.generated_at,
        curated=curated,
        include_callsites=args.include_callsites,
        max_callsites=args.max_callsites,
        minimum_counts=_parse_count_arguments(args.minimum_count, "--minimum-count"),
        expected_counts=_parse_count_arguments(args.expected_count, "--expected-count"),
    )
    write_catalog(document, args.output)
    print(
        f"wrote {len(document['records'])} records to {args.output} "
        f"(callsites={'on' if args.include_callsites else 'off'}; "
        + ", ".join(
            f"{item['class']}={item['extracted']}"
            for item in document["source"]["classCounts"]
        )
        + ")"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
