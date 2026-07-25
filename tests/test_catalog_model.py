import copy
import unittest

from tools.catalog_model import (
    ContractError,
    dump_json,
    merge_curated,
    validate_catalog,
    validate_runtime_export,
)


def minimal_record():
    return {
        "schemaVersion": 1,
        "class": "YTColdConfig",
        "selector": "sampleFlag",
        "experimentID": None,
        "native": {"value": None, "source": "unavailable", "capturedAt": None},
        "override": {"mode": "inherit", "value": None},
        "effective": {"value": None, "source": "unavailable"},
        "title": "Sample Flag",
        "summary": None,
        "category": "Uncategorized",
        "risk": "Unknown",
        "dependencies": [],
        "conflicts": [],
        "status": "Unknown",
        "evidence": [],
        "callsites": [],
        "callsiteSummary": {"observed": 0, "stored": 0, "truncated": False},
        "defaultInference": None,
        "verifiedVersions": [],
        "curationEvidence": [],
        "curationRationale": None,
    }


def minimal_catalog():
    return {
        "schemaVersion": 1,
        "youtubeVersion": "21.28.3",
        "generatedAt": "2026-07-25T00:00:00Z",
        "source": {
            "kind": "decompiler-c-files",
            "root": ".",
            "files": [{"path": "YTColdConfig.c", "sha256": "0" * 64}],
            "classCounts": [
                {
                    "class": class_name,
                    "headers": 1,
                    "candidates": 1 if class_name == "YTColdConfig" else 0,
                    "extracted": 1 if class_name == "YTColdConfig" else 0,
                    "minimum": 1 if class_name == "YTColdConfig" else 0,
                    "expected": None,
                }
                for class_name in ("YTColdConfig", "YTGlobalConfig", "YTHotConfig")
            ],
            "callsiteScan": {"enabled": False, "limitPerRecord": 20},
        },
        "records": [minimal_record()],
    }


class CatalogModelTests(unittest.TestCase):
    def test_catalog_rejects_unknown_fields_invalid_source_and_naive_timestamp(self):
        extra = minimal_catalog()
        extra["unexpected"] = True
        with self.assertRaisesRegex(ContractError, "unsupported"):
            validate_catalog(extra)

        bad_hash = minimal_catalog()
        bad_hash["source"]["files"][0]["sha256"] = "bad"
        with self.assertRaisesRegex(ContractError, "sha256"):
            validate_catalog(bad_hash)

        naive = minimal_catalog()
        naive["generatedAt"] = "2026-07-25T00:00:00"
        with self.assertRaisesRegex(ContractError, "RFC 3339"):
            validate_catalog(naive)

    def test_catalog_rejects_duplicate_record_keys(self):
        document = minimal_catalog()
        document["records"].append(copy.deepcopy(document["records"][0]))

        with self.assertRaisesRegex(ContractError, "duplicate"):
            validate_catalog(document)

    def test_catalog_rejects_invalid_status_and_missing_required_field(self):
        invalid_status = minimal_catalog()
        invalid_status["records"][0]["status"] = "Maybe"
        with self.assertRaisesRegex(ContractError, "status"):
            validate_catalog(invalid_status)

        missing_selector = minimal_catalog()
        del missing_selector["records"][0]["selector"]
        with self.assertRaisesRegex(ContractError, "selector"):
            validate_catalog(missing_selector)

    def test_curated_overlay_cannot_invent_summary_for_unknown_record(self):
        record = minimal_record()
        overlay = {
            "schemaVersion": 1,
            "youtubeVersion": "21.28.3",
            "records": [
                {
                    "class": "YTColdConfig",
                    "selector": "sampleFlag",
                    "title": "Curated Sample",
                    "summary": "Unsupported prose",
                    "status": "Unknown",
                }
            ]
        }

        with self.assertRaisesRegex(ContractError, "summary"):
            merge_curated([record], overlay, youtube_version="21.28.3")

    def test_curated_overlay_merges_supported_metadata(self):
        record = minimal_record()
        record["evidence"] = [{"id": "definition:YTColdConfig:sampleFlag", "kind": "definition", "source": {"path": "YTColdConfig.c", "lineStart": 4, "lineEnd": 9, "address": "0x1"}, "excerpt": "-[YTColdConfig sampleFlag]"}]
        overlay = {
            "schemaVersion": 1,
            "youtubeVersion": "21.28.3",
            "records": [
                {
                    "class": "YTColdConfig",
                    "selector": "sampleFlag",
                    "title": "Curated Sample",
                    "summary": None,
                    "category": "Playback",
                    "risk": "Low",
                    "status": "Inferred",
                    "curationEvidence": ["definition:YTColdConfig:sampleFlag"],
                    "curationRationale": "Conservative restatement of the selector name.",
                    "dependencies": [],
                    "conflicts": [],
                    "verifiedVersions": ["21.28.3"],
                }
            ],
        }

        merged = merge_curated(
            [record],
            overlay,
            youtube_version="21.28.3",
        )

        self.assertEqual(merged[0]["title"], "Curated Sample")
        self.assertEqual(merged[0]["category"], "Playback")
        self.assertEqual(merged[0]["status"], "Inferred")
        self.assertEqual(merged[0]["summary"], None)

    def test_curated_overlay_is_version_bound_and_inference_requires_evidence(self):
        record = minimal_record()
        record["evidence"] = [
            {
                "id": "definition:YTColdConfig:sampleFlag",
                "kind": "definition",
                "source": {
                    "path": "YTColdConfig.c",
                    "lineStart": 1,
                    "lineEnd": 2,
                    "address": "0x1",
                },
                "excerpt": "-[YTColdConfig sampleFlag]",
            }
        ]
        mismatch = {"schemaVersion": 1, "youtubeVersion": "999.0", "records": []}
        with self.assertRaisesRegex(ContractError, "youtubeVersion"):
            merge_curated([record], mismatch, youtube_version="21.28.3")

        unsupported = {
            "schemaVersion": 1,
            "youtubeVersion": "21.28.3",
            "records": [
                {
                    "class": "YTColdConfig",
                    "selector": "sampleFlag",
                    "status": "Inferred",
                }
            ],
        }
        with self.assertRaisesRegex(ContractError, "evidence"):
            merge_curated([record], unsupported, youtube_version="21.28.3")

        supported = copy.deepcopy(unsupported)
        supported["records"][0].update(
            {
                "curationEvidence": ["definition:YTColdConfig:sampleFlag"],
                "curationRationale": "Conservative restatement of the selector name.",
            }
        )
        merged = merge_curated([record], supported, youtube_version="21.28.3")
        self.assertEqual(merged[0]["status"], "Inferred")

    def test_runtime_contract_rejects_inconsistent_override(self):
        runtime = {
            "schemaVersion": 1,
            "exportedAt": "2026-07-25T00:00:00Z",
            "youtubeVersion": "21.28.3",
            "tweakVersion": "1.9.2",
            "context": {},
            "records": [
                {
                    "class": "YTColdConfig",
                    "selector": "sampleFlag",
                    "native": {"value": False, "source": "runtime", "capturedAt": "2026-07-25T00:00:00Z"},
                    "override": {"mode": "force-on", "value": False},
                    "effective": {"value": True, "source": "override"},
                    "title": "Sample Flag",
                    "summary": None,
                    "category": "Uncategorized",
                    "risk": "Unknown",
                    "status": "Unknown",
                }
            ],
        }

        with self.assertRaisesRegex(ContractError, "force-on"):
            validate_runtime_export(runtime)

    def test_dump_json_is_stable_and_newline_terminated(self):
        document = {"z": 1, "a": [2]}
        self.assertEqual(dump_json(document), '{\n  "a": [\n    2\n  ],\n  "z": 1\n}\n')


if __name__ == "__main__":
    unittest.main()
