"""Versioned catalog contracts and deterministic JSON helpers."""

from __future__ import annotations

import copy
import json
from datetime import datetime
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
STATUSES = {"Verified", "Inferred", "Unknown"}
RISKS = {"Low", "Medium", "High", "Unknown"}
OVERRIDE_MODES = {"inherit", "force-on", "force-off"}
RECORD_REQUIRED = {
    "schemaVersion",
    "class",
    "selector",
    "experimentID",
    "native",
    "override",
    "effective",
    "title",
    "summary",
    "category",
    "risk",
    "dependencies",
    "conflicts",
    "status",
    "evidence",
    "callsites",
    "defaultInference",
    "verifiedVersions",
}


class ContractError(ValueError):
    """Raised when a catalog or export violates its versioned contract."""


def dump_json(document: Any) -> str:
    return json.dumps(
        document,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"


def _require_object(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ContractError(f"{path} must be an object")
    return value


def _require_keys(value: Mapping[str, Any], keys: set[str], path: str) -> None:
    missing = sorted(keys - set(value))
    if missing:
        raise ContractError(f"{path} missing required field: {missing[0]}")


def _require_string(value: Any, path: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise ContractError(f"{path} must be a non-empty string")
    return value


def _require_bool_or_none(value: Any, path: str) -> None:
    if value is not None and not isinstance(value, bool):
        raise ContractError(f"{path} must be boolean or null")


def _require_timestamp(value: Any, path: str) -> None:
    text = _require_string(value, path)
    try:
        datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ContractError(f"{path} must be an RFC 3339 timestamp") from error


def _validate_state(record: Mapping[str, Any], path: str, *, runtime: bool) -> None:
    native = _require_object(record.get("native"), f"{path}.native")
    _require_keys(native, {"value", "source", "capturedAt"}, f"{path}.native")
    _require_bool_or_none(native["value"], f"{path}.native.value")
    _require_string(native["source"], f"{path}.native.source")
    if native["capturedAt"] is not None:
        _require_timestamp(native["capturedAt"], f"{path}.native.capturedAt")

    override = _require_object(record.get("override"), f"{path}.override")
    _require_keys(override, {"mode", "value"}, f"{path}.override")
    if override["mode"] not in OVERRIDE_MODES:
        raise ContractError(f"{path}.override.mode is invalid")
    _require_bool_or_none(override["value"], f"{path}.override.value")
    expected_override = {
        "inherit": None,
        "force-on": True,
        "force-off": False,
    }[override["mode"]]
    if override["value"] is not expected_override:
        raise ContractError(
            f"{path}.override {override['mode']} requires value {expected_override!r}"
        )

    effective = _require_object(record.get("effective"), f"{path}.effective")
    _require_keys(effective, {"value", "source"}, f"{path}.effective")
    _require_bool_or_none(effective["value"], f"{path}.effective.value")
    if effective["source"] not in {"native", "override", "unavailable"}:
        raise ContractError(f"{path}.effective.source is invalid")

    if runtime:
        expected_effective = (
            override["value"] if override["mode"] != "inherit" else native["value"]
        )
        if effective["value"] is not expected_effective:
            raise ContractError(f"{path}.effective.value does not match runtime state")
        expected_source = (
            "override"
            if override["mode"] != "inherit"
            else ("native" if native["value"] is not None else "unavailable")
        )
        if effective["source"] != expected_source:
            raise ContractError(f"{path}.effective.source does not match runtime state")


def _validate_metadata(record: Mapping[str, Any], path: str) -> None:
    _require_string(record.get("class"), f"{path}.class")
    _require_string(record.get("selector"), f"{path}.selector")
    _require_string(record.get("title"), f"{path}.title")
    if record.get("summary") is not None:
        _require_string(record["summary"], f"{path}.summary")
    _require_string(record.get("category"), f"{path}.category")
    if record.get("risk") not in RISKS:
        raise ContractError(f"{path}.risk is invalid")
    if record.get("status") not in STATUSES:
        raise ContractError(f"{path}.status is invalid")


def _validate_catalog_record(record: Any, index: int) -> tuple[str, str]:
    path = f"records[{index}]"
    item = _require_object(record, path)
    _require_keys(item, RECORD_REQUIRED, path)
    if item["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError(f"{path}.schemaVersion must be {SCHEMA_VERSION}")
    _validate_metadata(item, path)
    experiment_id = item["experimentID"]
    if experiment_id is not None and (
        not isinstance(experiment_id, int)
        or isinstance(experiment_id, bool)
        or experiment_id < 0
    ):
        raise ContractError(f"{path}.experimentID must be a non-negative integer or null")
    _validate_state(item, path, runtime=False)
    for field in ("dependencies", "conflicts", "evidence", "callsites", "verifiedVersions"):
        if not isinstance(item[field], list):
            raise ContractError(f"{path}.{field} must be an array")
    for field in ("dependencies", "conflicts", "verifiedVersions"):
        for value in item[field]:
            _require_string(value, f"{path}.{field}[]")
    for field, expected_kind in (("evidence", "definition"), ("callsites", "callsite")):
        for evidence_index, evidence in enumerate(item[field]):
            evidence_path = f"{path}.{field}[{evidence_index}]"
            evidence_item = _require_object(evidence, evidence_path)
            _require_keys(
                evidence_item,
                {"id", "kind", "source", "excerpt"},
                evidence_path,
            )
            _require_string(evidence_item["id"], f"{evidence_path}.id")
            if evidence_item["kind"] != expected_kind:
                raise ContractError(f"{evidence_path}.kind must be {expected_kind}")
            source = _require_object(evidence_item["source"], f"{evidence_path}.source")
            _require_keys(
                source,
                {"path", "lineStart", "lineEnd", "address"},
                f"{evidence_path}.source",
            )
            _require_string(source["path"], f"{evidence_path}.source.path")
            for line_field in ("lineStart", "lineEnd"):
                if not isinstance(source[line_field], int) or source[line_field] < 1:
                    raise ContractError(
                        f"{evidence_path}.source.{line_field} must be a positive integer"
                    )
            if source["address"] is not None:
                _require_string(source["address"], f"{evidence_path}.source.address")
            _require_string(evidence_item["excerpt"], f"{evidence_path}.excerpt")
    inference = item["defaultInference"]
    if inference is not None:
        inference_item = _require_object(inference, f"{path}.defaultInference")
        _require_keys(
            inference_item,
            {"value", "confidence", "method", "evidence"},
            f"{path}.defaultInference",
        )
        if not isinstance(inference_item["value"], bool):
            raise ContractError(f"{path}.defaultInference.value must be boolean")
        if inference_item["confidence"] not in {"High", "Medium", "Low"}:
            raise ContractError(f"{path}.defaultInference.confidence is invalid")
        _require_string(inference_item["method"], f"{path}.defaultInference.method")
        if not isinstance(inference_item["evidence"], list):
            raise ContractError(f"{path}.defaultInference.evidence must be an array")
    return item["class"], item["selector"]


def validate_catalog(document: Any) -> Mapping[str, Any]:
    root = _require_object(document, "catalog")
    _require_keys(
        root,
        {"schemaVersion", "youtubeVersion", "generatedAt", "source", "records"},
        "catalog",
    )
    if root["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError(f"catalog.schemaVersion must be {SCHEMA_VERSION}")
    _require_string(root["youtubeVersion"], "catalog.youtubeVersion")
    _require_timestamp(root["generatedAt"], "catalog.generatedAt")
    source = _require_object(root["source"], "catalog.source")
    _require_keys(source, {"kind", "root", "files"}, "catalog.source")
    _require_string(source["kind"], "catalog.source.kind")
    _require_string(source["root"], "catalog.source.root")
    if not isinstance(source["files"], list):
        raise ContractError("catalog.source.files must be an array")
    if not isinstance(root["records"], list):
        raise ContractError("catalog.records must be an array")
    keys: set[tuple[str, str]] = set()
    for index, record in enumerate(root["records"]):
        key = _validate_catalog_record(record, index)
        if key in keys:
            raise ContractError(f"duplicate catalog record: {key[0]}.{key[1]}")
        keys.add(key)
    return root


def validate_runtime_export(document: Any) -> Mapping[str, Any]:
    root = _require_object(document, "runtimeExport")
    _require_keys(
        root,
        {
            "schemaVersion",
            "exportedAt",
            "youtubeVersion",
            "tweakVersion",
            "context",
            "records",
        },
        "runtimeExport",
    )
    if root["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError(f"runtimeExport.schemaVersion must be {SCHEMA_VERSION}")
    _require_timestamp(root["exportedAt"], "runtimeExport.exportedAt")
    _require_string(root["youtubeVersion"], "runtimeExport.youtubeVersion")
    _require_string(root["tweakVersion"], "runtimeExport.tweakVersion")
    _require_object(root["context"], "runtimeExport.context")
    if not isinstance(root["records"], list):
        raise ContractError("runtimeExport.records must be an array")
    keys: set[tuple[str, str]] = set()
    for index, record in enumerate(root["records"]):
        path = f"records[{index}]"
        item = _require_object(record, path)
        _require_keys(
            item,
            {
                "class",
                "selector",
                "native",
                "override",
                "effective",
                "title",
                "summary",
                "category",
                "risk",
                "status",
            },
            path,
        )
        _validate_metadata(item, path)
        _validate_state(item, path, runtime=True)
        key = (item["class"], item["selector"])
        if key in keys:
            raise ContractError(f"duplicate runtime record: {key[0]}.{key[1]}")
        keys.add(key)
    return root


def merge_curated(
    records: Sequence[Mapping[str, Any]],
    overlay: Mapping[str, Any] | None,
) -> list[dict[str, Any]]:
    merged = [copy.deepcopy(record) for record in records]
    if overlay is None:
        return merged
    overlay_root = _require_object(overlay, "curated")
    _require_keys(
        overlay_root,
        {"schemaVersion", "youtubeVersion", "records"},
        "curated",
    )
    if overlay_root["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError(f"curated.schemaVersion must be {SCHEMA_VERSION}")
    if not isinstance(overlay_root["records"], list):
        raise ContractError("curated.records must be an array")
    by_key = {(item["class"], item["selector"]): item for item in merged}
    allowed = {
        "title",
        "summary",
        "category",
        "risk",
        "status",
        "dependencies",
        "conflicts",
        "verifiedVersions",
    }
    for index, raw_patch in enumerate(overlay_root["records"]):
        patch = _require_object(raw_patch, f"curated.records[{index}]")
        _require_keys(patch, {"class", "selector"}, f"curated.records[{index}]")
        key = (patch["class"], patch["selector"])
        if key not in by_key:
            raise ContractError(f"curated record not found in extraction: {key[0]}.{key[1]}")
        unknown = sorted(set(patch) - allowed - {"class", "selector"})
        if unknown:
            raise ContractError(f"curated record contains unsupported field: {unknown[0]}")
        resulting_status = patch.get("status", by_key[key]["status"])
        if patch.get("summary") is not None and resulting_status == "Unknown":
            raise ContractError("curated summary requires Inferred or Verified status")
        for field in allowed:
            if field in patch:
                by_key[key][field] = copy.deepcopy(patch[field])
    return sorted(merged, key=lambda item: (item["class"], item["selector"]))
