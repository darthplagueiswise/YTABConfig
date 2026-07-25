import json
import tempfile
import unittest
from pathlib import Path

from tools.catalog_extractor import _add_bounded_callsite, extract_catalog, write_catalog
from tools.catalog_model import ContractError


FIXTURE_ROOT = Path(__file__).parent / "fixtures" / "decompile"


class CatalogExtractorTests(unittest.TestCase):
    def _extract_sources(self, sources, **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for class_name in ("YTColdConfig", "YTGlobalConfig", "YTHotConfig"):
                (root / f"{class_name}.c").write_text(
                    sources.get(class_name, ""), encoding="utf-8"
                )
            if "Consumer" in sources:
                (root / "Consumer.c").write_text(
                    sources["Consumer"], encoding="utf-8"
                )
            return extract_catalog(
                root,
                youtube_version="21.28.3",
                generated_at="2026-07-25T00:00:00Z",
                **kwargs,
            )

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
        self.assertEqual(
            {
                item["class"]: item["extracted"]
                for item in document["source"]["classCounts"]
            },
            {"YTColdConfig": 1, "YTGlobalConfig": 1, "YTHotConfig": 1},
        )

    def test_supports_verified_decompiler_header_and_declaration_variants(self):
        document = self._extract_sources(
            {
                "YTColdConfig": """
/* -[YTColdConfig coldFlag] @ 0x1 */
_BOOL8 __fastcall -[YTColdConfig coldFlag](YTColdConfig *self, SEL cmd)
{
  return 1;
}
""",
                "YTGlobalConfig": """
// -[YTGlobalConfig globalFlag]
BOOL -[YTGlobalConfig globalFlag](YTGlobalConfig *self, SEL cmd)
{
  return 0;
}
""",
                "YTHotConfig": """
// -[YTHotConfig hotFlag] @ 0x3
bool __cdecl -[YTHotConfig hotFlag](YTHotConfig *self, SEL cmd)
{
  return 1;
}
""",
            }
        )

        self.assertEqual(
            [record["selector"] for record in document["records"]],
            ["coldFlag", "globalFlag", "hotFlag"],
        )
        self.assertEqual(
            [
                (item["headers"], item["candidates"], item["extracted"])
                for item in document["source"]["classCounts"]
            ],
            [(1, 1, 1), (1, 1, 1), (1, 1, 1)],
        )

    def test_fails_closed_on_minimum_or_expected_count_mismatch(self):
        with self.assertRaisesRegex(ContractError, "minimum"):
            self._extract_sources({})

        with self.assertRaisesRegex(ContractError, "expected"):
            self._extract_sources(
                {
                    "YTColdConfig": """
// -[YTColdConfig coldFlag] @ 0x1
bool __cdecl -[YTColdConfig coldFlag](void) { return 1; }
""",
                    "YTGlobalConfig": """
// -[YTGlobalConfig globalFlag] @ 0x2
bool __cdecl -[YTGlobalConfig globalFlag](void) { return 1; }
""",
                    "YTHotConfig": """
// -[YTHotConfig hotFlag] @ 0x3
bool __cdecl -[YTHotConfig hotFlag](void) { return 1; }
""",
                },
                expected_counts={
                    "YTColdConfig": 2,
                    "YTGlobalConfig": 1,
                    "YTHotConfig": 1,
                },
            )

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
        self.assertIsNone(record["native"]["value"])
        self.assertEqual(record["evidence"][0]["kind"], "definition")
        self.assertEqual(record["evidence"][0]["source"]["path"], "YTColdConfig.c")
        self.assertEqual(record["callsites"][0]["source"]["path"], "Consumer.c")
        self.assertNotEqual(record["evidence"], record["callsites"])

    def test_static_inference_never_populates_runtime_native_state(self):
        document = extract_catalog(
            FIXTURE_ROOT,
            youtube_version="21.28.3",
            generated_at="2026-07-25T00:00:00Z",
        )
        record = document["records"][0]

        self.assertIsNone(record["native"]["value"])
        self.assertEqual(record["native"]["source"], "unavailable")
        self.assertIsNotNone(record["defaultInference"])

    def test_unparsed_return_path_disables_default_inference(self):
        document = self._extract_sources(
            {
                "YTColdConfig": """
// -[YTColdConfig dynamicFlag] @ 0x1
bool __cdecl -[YTColdConfig dynamicFlag](YTColdConfig *self, SEL cmd)
{
  if ( condition(self) )
    return objc_msgSend(self, "dynamicFlag");
  return 0;
}
// -[YTColdConfig partialFlag] @ 0x4
bool __cdecl -[YTColdConfig partialFlag](YTColdConfig *self, SEL cmd)
{
  unsigned int v4;
  if ( first(self) )
    v4 = dynamic(self);
  else
    v4 = 0;
  if ( second(self) )
    v4 = dynamic(self);
  return v4;
}
""",
                "YTGlobalConfig": """
// -[YTGlobalConfig globalFlag] @ 0x2
bool __cdecl -[YTGlobalConfig globalFlag](void) { return 1; }
""",
                "YTHotConfig": """
// -[YTHotConfig hotFlag] @ 0x3
bool __cdecl -[YTHotConfig hotFlag](void) { return 1; }
""",
            }
        )

        dynamic = next(
            record for record in document["records"] if record["selector"] == "dynamicFlag"
        )
        self.assertIsNone(dynamic["defaultInference"])
        partial = next(
            record for record in document["records"] if record["selector"] == "partialFlag"
        )
        self.assertIsNone(partial["defaultInference"])

    def test_experiment_id_requires_unambiguous_experiment_flag_evidence(self):
        document = self._extract_sources(
            {
                "YTColdConfig": """
// -[YTColdConfig unrelatedLookup] @ 0x1
bool __cdecl -[YTColdConfig unrelatedLookup](void)
{
  hasExperimentFlags();
  id x = objc_msgSend(dict, "objectForKey:", 12345);
  return 1;
}
""",
                "YTGlobalConfig": """
// -[YTGlobalConfig ambiguousExperiment] @ 0x2
bool __cdecl -[YTGlobalConfig ambiguousExperiment](void)
{
  hasExperimentFlags();
  experimentFlags();
  flags();
  id x = objc_msgSend(dict, "objectForKey:", 111);
  id y = objc_msgSend(dict, "objectForKey:", 222);
  return 1;
}
""",
                "YTHotConfig": """
// -[YTHotConfig evidencedExperiment] @ 0x3
bool __cdecl -[YTHotConfig evidencedExperiment](void)
{
  hasExperimentFlags();
  experimentFlags();
  flags();
  id x = objc_msgSend(dict, "objectForKey:", 333);
  return 1;
}
""",
            }
        )
        records = {record["selector"]: record for record in document["records"]}

        self.assertIsNone(records["unrelatedLookup"]["experimentID"])
        self.assertIsNone(records["ambiguousExperiment"]["experimentID"])
        self.assertEqual(records["evidencedExperiment"]["experimentID"], 333)

    def test_callsites_ignore_comments_and_strings_dedupe_and_report_truncation(self):
        document = self._extract_sources(
            {
                "YTColdConfig": """
// -[YTColdConfig coldFlag] @ 0x1
bool __cdecl -[YTColdConfig coldFlag](void) { return 1; }
""",
                "YTGlobalConfig": """
// -[YTGlobalConfig globalFlag] @ 0x2
bool __cdecl -[YTGlobalConfig globalFlag](void) { return 1; }
""",
                "YTHotConfig": """
// -[YTHotConfig hotFlag] @ 0x3
bool __cdecl -[YTHotConfig hotFlag](void) { return 1; }
""",
                "Consumer": """
/* -[YTColdConfig coldFlag](ignored); */
const char *sample = "-[YTColdConfig coldFlag](ignored)";
bool a(void) { return -[YTColdConfig coldFlag](x) || -[YTColdConfig coldFlag](y); }
bool b(void) { return -[YTColdConfig coldFlag](z); }
""",
            },
            include_callsites=True,
            max_callsites=1,
        )
        record = next(
            record for record in document["records"] if record["selector"] == "coldFlag"
        )

        self.assertEqual(len(record["callsites"]), 1)
        self.assertEqual(
            record["callsiteSummary"],
            {"observed": 2, "stored": 1, "truncated": True},
        )
        self.assertEqual(
            document["source"]["callsiteScan"],
            {"enabled": True, "limitPerRecord": 1},
        )

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
