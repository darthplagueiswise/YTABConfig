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
        "defaultInference": None,
        "verifiedVersions": [],
    }


def minimal_catalog():
    return {
        "schemaVersion": 1,
        "youtubeVersion": "21.28.3",
        "generatedAt": "2026-07-25T00:00:00Z",
        "source": {"kind": "decompiler-c-files", "root": ".", "files": []},
        "records": [minimal_record()],
    }


class CatalogModelTests(unittest.TestCase):
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
            merge_curated([record], overlay)

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
                    "dependencies": [],
                    "conflicts": [],
                    "verifiedVersions": ["21.28.3"],
                }
            ],
        }

        merged = merge_curated([record], overlay)

        self.assertEqual(merged[0]["title"], "Curated Sample")
        self.assertEqual(merged[0]["category"], "Playback")
        self.assertEqual(merged[0]["status"], "Inferred")
        self.assertEqual(merged[0]["summary"], None)

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
