import json
import unittest

from tools.report_provider import (
    MAX_IMPORT_BYTES,
    build_runtime_export,
    import_runtime_export,
    render_markdown_report,
)


CATALOG_RECORDS = [
    {
        "class": "YTColdConfig",
        "selector": "betaFlag",
        "title": "Beta Flag",
        "summary": None,
        "category": "Playback",
        "risk": "Low",
        "status": "Inferred",
    },
    {
        "class": "YTHotConfig",
        "selector": "alphaFlag",
        "title": "Alpha Flag",
        "summary": None,
        "category": "Account",
        "risk": "Unknown",
        "status": "Unknown",
    },
]


class ReportProviderTests(unittest.TestCase):
    def test_runtime_export_round_trips_structured_state(self):
        document = build_runtime_export(
            CATALOG_RECORDS,
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={"device": "iPhone", "bundleID": "com.google.ios.youtube"},
            states={
                ("YTColdConfig", "betaFlag"): {
                    "native": False,
                    "override": "force-on",
                }
            },
        )

        payload = json.dumps(document)
        imported = import_runtime_export(payload)

        beta = next(record for record in imported["records"] if record["selector"] == "betaFlag")
        self.assertEqual(beta["native"]["value"], False)
        self.assertEqual(beta["override"], {"mode": "force-on", "value": True})
        self.assertEqual(beta["effective"], {"value": True, "source": "override"})

    def test_report_is_sorted_and_marks_unknown_native_state(self):
        document = build_runtime_export(
            CATALOG_RECORDS,
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={},
            states={},
        )

        report = render_markdown_report(document)

        self.assertLess(report.index("## Account"), report.index("## Playback"))
        self.assertIn("| Alpha Flag | Native | Unknown | Unknown |", report)
        self.assertIn("| Beta Flag | Native | Unknown | Low |", report)
        self.assertNotIn("None", report)

    def test_import_rejects_non_object_json(self):
        with self.assertRaisesRegex(ValueError, "object"):
            import_runtime_export("[]")

    def test_import_rejects_nonfinite_duplicate_and_unknown_json(self):
        with self.assertRaisesRegex(ValueError, "constant"):
            import_runtime_export('{"context": NaN}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            import_runtime_export('{"schemaVersion": 1, "schemaVersion": 1}')
        with self.assertRaisesRegex(ValueError, "maximum size"):
            import_runtime_export(b" " * (MAX_IMPORT_BYTES + 1))

        document = build_runtime_export(
            CATALOG_RECORDS,
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={},
            states={},
        )
        document["unexpected"] = True
        with self.assertRaisesRegex(ValueError, "unsupported"):
            import_runtime_export(document)

    def test_markdown_report_flattens_untrusted_newlines(self):
        records = [
            {
                **CATALOG_RECORDS[0],
                "title": "Safe\n## Forged",
                "category": "Playback\n# Injected",
            }
        ]
        document = build_runtime_export(
            records,
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={},
            states={},
        )

        report = render_markdown_report(document)

        self.assertIn("## Playback # Injected", report)
        self.assertIn("| Safe ## Forged |", report)
        self.assertNotIn("\n# Injected", report)


if __name__ == "__main__":
    unittest.main()
