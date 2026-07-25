"""Structured runtime import/export and shareable report provider."""

from __future__ import annotations

import copy
import json
from typing import Any, Mapping, Sequence

try:
    from tools.catalog_model import SCHEMA_VERSION, validate_runtime_export
except ModuleNotFoundError:
    from catalog_model import SCHEMA_VERSION, validate_runtime_export


def _state_label(value: bool | None) -> str:
    if value is None:
        return "Unknown"
    return "On" if value else "Off"


def _override_value(mode: str) -> bool | None:
    values = {"inherit": None, "force-on": True, "force-off": False}
    if mode not in values:
        raise ValueError(f"invalid override mode: {mode}")
    return values[mode]


def build_runtime_export(
    catalog_records: Sequence[Mapping[str, Any]],
    *,
    youtube_version: str,
    tweak_version: str,
    exported_at: str,
    context: Mapping[str, Any],
    states: Mapping[tuple[str, str], Mapping[str, Any]],
) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    for catalog_record in catalog_records:
        key = (catalog_record["class"], catalog_record["selector"])
        state = states.get(key, {})
        native_value = state.get("native")
        if native_value is not None and not isinstance(native_value, bool):
            raise ValueError(f"native state for {key[0]}.{key[1]} must be boolean or null")
        override_mode = state.get("override", "inherit")
        override_value = _override_value(override_mode)
        effective_value = override_value if override_mode != "inherit" else native_value
        records.append(
            {
                "class": key[0],
                "selector": key[1],
                "native": {
                    "value": native_value,
                    "source": "runtime" if native_value is not None else "unavailable",
                    "capturedAt": exported_at if native_value is not None else None,
                },
                "override": {"mode": override_mode, "value": override_value},
                "effective": {
                    "value": effective_value,
                    "source": (
                        "override"
                        if override_mode != "inherit"
                        else ("native" if native_value is not None else "unavailable")
                    ),
                },
                "title": catalog_record["title"],
                "summary": catalog_record.get("summary"),
                "category": catalog_record.get("category", "Uncategorized"),
                "risk": catalog_record.get("risk", "Unknown"),
                "status": catalog_record.get("status", "Unknown"),
            }
        )
    records.sort(
        key=lambda item: (
            item["category"].casefold(),
            item["title"].casefold(),
            item["class"],
            item["selector"],
        )
    )
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "exportedAt": exported_at,
        "youtubeVersion": youtube_version,
        "tweakVersion": tweak_version,
        "context": copy.deepcopy(dict(context)),
        "records": records,
    }
    validate_runtime_export(document)
    return document


def import_runtime_export(payload: str | bytes | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(payload, bytes):
        parsed = json.loads(payload.decode("utf-8"))
    elif isinstance(payload, str):
        parsed = json.loads(payload)
    elif isinstance(payload, Mapping):
        parsed = copy.deepcopy(dict(payload))
    else:
        raise ValueError("runtime export must be a JSON object")
    if not isinstance(parsed, dict):
        raise ValueError("runtime export must be a JSON object")
    validate_runtime_export(parsed)
    return parsed


def render_markdown_report(document: Mapping[str, Any]) -> str:
    validate_runtime_export(document)
    lines = [
        "# YTABConfig Runtime Report",
        "",
        f"- YouTube: {document['youtubeVersion']}",
        f"- Tweak: {document['tweakVersion']}",
        f"- Exported: {document['exportedAt']}",
        "",
    ]
    categories: dict[str, list[Mapping[str, Any]]] = {}
    for record in document["records"]:
        categories.setdefault(record["category"], []).append(record)
    override_labels = {
        "inherit": "Native",
        "force-on": "Force On",
        "force-off": "Force Off",
    }
    for category in sorted(categories, key=str.casefold):
        lines.extend(
            [
                f"## {category}",
                "",
                "| Setting | Override | Effective | Risk |",
                "| --- | --- | --- | --- |",
            ]
        )
        for record in sorted(
            categories[category],
            key=lambda item: (
                item["title"].casefold(),
                item["class"],
                item["selector"],
            ),
        ):
            lines.append(
                "| "
                + " | ".join(
                    (
                        record["title"].replace("|", "\\|"),
                        override_labels[record["override"]["mode"]],
                        _state_label(record["effective"]["value"]),
                        record["risk"],
                    )
                )
                + " |"
            )
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"
