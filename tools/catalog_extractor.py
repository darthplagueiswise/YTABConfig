#!/usr/bin/env python3
"""Extract a deterministic BOOL-selector catalog from decompiler C output."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Iterator, Mapping

try:
    from tools.catalog_model import (
        SCHEMA_VERSION,
        dump_json,
        merge_curated,
        validate_catalog,
    )
except ModuleNotFoundError:
    from catalog_model import SCHEMA_VERSION, dump_json, merge_curated, validate_catalog


CLASS_NAMES = ("YTColdConfig", "YTGlobalConfig", "YTHotConfig")
HEADER_RE = re.compile(
    r"^// -\[(YTColdConfig|YTGlobalConfig|YTHotConfig) ([^\]]+)\] @ (0x[0-9A-Fa-f]+)\s*$"
)
DIRECT_CALL_RE = re.compile(
    r"-\[(YTColdConfig|YTGlobalConfig|YTHotConfig) ([A-Za-z_][A-Za-z0-9_:]*)\]"
)
EXPERIMENT_RE = re.compile(r'objectForKey:",\s*(\d+)\)')
RETURN_RE = re.compile(r"\breturn\s+([A-Za-z_][A-Za-z0-9_]*|[01])\s*;")
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
    returns = RETURN_RE.findall(block)
    if len(returns) == 1 and returns[0] in {"0", "1"}:
        return {
            "value": returns[0] == "1",
            "confidence": "High",
            "method": "constant-return",
            "evidence": [evidence_id],
        }
    if not returns:
        return None
    return_variable = returns[-1]
    candidates: list[bool] = []
    for match in ELSE_ASSIGN_RE.finditer(block):
        variable = match.group("low") or match.group("plain")
        if variable == return_variable:
            candidates.append(match.group("value") == "1")
    if candidates and len(set(candidates)) == 1:
        return {
            "value": candidates[0],
            "confidence": "High",
            "method": "explicit-fallback-assignment",
            "evidence": [evidence_id],
        }
    return None


def _extract_definitions(source_root: Path) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    records: list[dict[str, Any]] = []
    source_files: list[dict[str, str]] = []
    for class_name in CLASS_NAMES:
        path = source_root / f"{class_name}.c"
        if not path.is_file():
            raise FileNotFoundError(f"missing decompiler class file: {path}")
        relative_path = path.relative_to(source_root).as_posix()
        source_files.append({"path": relative_path, "sha256": _sha256(path)})
        for line_start, line_end, header, block in _iter_sections(path):
            found_class, selector, address = header.groups()
            signature = re.search(
                rf"^bool __cdecl -\[{re.escape(found_class)} {re.escape(selector)}\]",
                block,
                re.MULTILINE,
            )
            if signature is None:
                continue
            evidence_id = f"definition:{found_class}:{selector}"
            experiment = EXPERIMENT_RE.search(block)
            inference = _infer_default(block, evidence_id)
            native_value = inference["value"] if inference is not None else None
            records.append(
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "class": found_class,
                    "selector": selector,
                    "experimentID": int(experiment.group(1)) if experiment else None,
                    "native": {
                        "value": native_value,
                        "source": (
                            "decompile-default-inference"
                            if inference is not None
                            else "unavailable"
                        ),
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
                    "defaultInference": inference,
                    "verifiedVersions": [],
                }
            )
    records.sort(key=lambda item: (item["class"], item["selector"]))
    source_files.sort(key=lambda item: item["path"])
    return records, source_files


def _iter_c_files(source_root: Path) -> Iterator[Path]:
    for current, directories, files in os.walk(source_root):
        directories.sort()
        for filename in sorted(files):
            if filename.endswith(".c"):
                yield Path(current) / filename


def _iter_direct_call_lines(source_root: Path) -> Iterator[tuple[str, int, str]]:
    ripgrep = shutil.which("rg")
    if ripgrep is not None:
        command = [
            ripgrep,
            "--json",
            "--glob",
            "*.c",
            "--",
            r"-\[(YTColdConfig|YTGlobalConfig|YTHotConfig) [A-Za-z_][A-Za-z0-9_:]*\]",
            str(source_root),
        ]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert process.stdout is not None
        for raw_event in process.stdout:
            event = json.loads(raw_event)
            if event.get("type") != "match":
                continue
            data = event["data"]
            path = Path(data["path"]["text"])
            yield (
                path.relative_to(source_root).as_posix(),
                data["line_number"],
                data["lines"]["text"].rstrip("\r\n"),
            )
        stderr = process.communicate()[1]
        if process.returncode not in {0, 1}:
            raise RuntimeError(f"ripgrep callsite scan failed: {stderr.strip()}")
        return
    for path in _iter_c_files(source_root):
        relative_path = path.relative_to(source_root).as_posix()
        with path.open("r", encoding="utf-8", errors="replace") as source:
            for line_number, line in enumerate(source, start=1):
                if DIRECT_CALL_RE.search(line):
                    yield relative_path, line_number, line.rstrip("\r\n")


def _add_bounded_callsite(
    callsites: list[dict[str, Any]],
    callsite: dict[str, Any],
    *,
    limit: int,
) -> None:
    if limit == 0:
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
    for relative_path, line_number, line in _iter_direct_call_lines(source_root):
        if "__cdecl" in line or line.lstrip().startswith("//"):
            continue
        for match in DIRECT_CALL_RE.finditer(line):
            key = match.groups()
            record = by_key.get(key)
            if record is None:
                continue
            _add_bounded_callsite(
                record["callsites"],
                {
                    "id": (
                        f"callsite:{key[0]}:{key[1]}:"
                        f"{relative_path}:{line_number}"
                    ),
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


def extract_catalog(
    source_root: str | Path,
    *,
    youtube_version: str,
    generated_at: str,
    curated: Mapping[str, Any] | None = None,
    include_callsites: bool = False,
    max_callsites: int = 20,
) -> dict[str, Any]:
    root = Path(source_root)
    records, source_files = _extract_definitions(root)
    if include_callsites:
        _collect_callsites(root, records, max_callsites)
    records = merge_curated(records, curated)
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "youtubeVersion": youtube_version,
        "generatedAt": generated_at,
        "source": {
            "kind": "decompiler-c-files",
            "root": ".",
            "files": source_files,
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--youtube-version", required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--curated", type=Path)
    parser.add_argument("--include-callsites", action="store_true")
    parser.add_argument("--max-callsites", type=int, default=20)
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
    )
    write_catalog(document, args.output)
    print(
        f"wrote {len(document['records'])} records to {args.output} "
        f"(callsites={'on' if args.include_callsites else 'off'})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
