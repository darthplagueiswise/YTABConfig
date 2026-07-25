import json
import tempfile
import unittest
from pathlib import Path

from tools.catalog_extractor import _add_bounded_callsite, extract_catalog, write_catalog


FIXTURE_ROOT = Path(__file__).parent / "fixtures" / "decompile"


class CatalogExtractorTests(unittest.TestCase):
    def test_callsite_limit_keeps_same_lexicographic_subset_for_any_scan_order(self):
        late = {
            "id": "late",
            "source": {"path": "Z.c", "lineStart": 9},
        }
        early = {
            "id": "early",
            "source": {"path": "A.c", "lineStart": 2},
        }
        middle = {
            "id": "middle",
            "source": {"path": "M.c", "lineStart": 4},
        }
        callsites = []

        for item in (late, middle, early):
            _add_bounded_callsite(callsites, item, limit=2)

        self.assertEqual([item["id"] for item in callsites], ["early", "middle"])

    def test_extracts_only_bool_methods_with_stable_order(self):
        document = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
        )

        keys = [(record["class"], record["selector"]) for record in document["records"]]
        self.assertEqual(
            keys,
            [
                ("YTColdConfig", "zebraFlag"),
                ("YTGlobalConfig", "alphaFlag"),
                ("YTHotConfig", "middleFlag"),
            ],
        )
        self.assertNotIn("notBoolean", [record["selector"] for record in document["records"]])
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["youtubeVersion"], "21.28.3")

    def test_preserves_experiment_default_evidence_and_callsites_separately(self):
        document = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
            include_callsites=True,
            max_callsites=2,
        )
        record = document["records"][0]

        self.assertEqual(record["experimentID"], 45789453)
        self.assertEqual(
            record["defaultInference"],
            {
                "value": False,
                "confidence": "High",
                "method": "explicit-fallback-assignment",
                "evidence": ["definition:YTColdConfig:zebraFlag"],
            },
        )
        self.assertEqual(record["native"]["value"], False)
        self.assertEqual(record["evidence"][0]["kind"], "definition")
        self.assertEqual(record["evidence"][0]["source"]["path"], "YTColdConfig.c")
        self.assertEqual(record["callsites"][0]["source"]["path"], "Consumer.c")
        self.assertNotEqual(record["evidence"], record["callsites"])

    def test_recognizes_direct_true_default(self):
        document = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
        )
        records = {record["selector"]: record for record in document["records"]}

        self.assertTrue(records["alphaFlag"]["defaultInference"]["value"])
        self.assertEqual(records["alphaFlag"]["defaultInference"]["method"], "constant-return")
        self.assertTrue(records["middleFlag"]["defaultInference"]["value"])
        self.assertEqual(
            records["middleFlag"]["defaultInference"]["method"],
            "explicit-fallback-assignment",
        )

    def test_same_inputs_serialize_to_identical_bytes(self):
        first = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
            include_callsites=True,
        )
        second = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
            include_callsites=True,
        )

        with tempfile.TemporaryDirectory() as directory:
            first_path = Path(directory) / "first.json"
            second_path = Path(directory) / "second.json"
            write_catalog(first, first_path)
            write_catalog(second, second_path)
            self.assertEqual(first_path.read_bytes(), second_path.read_bytes())
            self.assertEqual(json.loads(first_path.read_text()), first)

    def test_write_catalog_creates_output_parent(self):
        document = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
        )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "generated" / "catalog.json"
            write_catalog(document, output)
            self.assertEqual(json.loads(output.read_text()), document)


if __name__ == "__main__":
    unittest.main()
