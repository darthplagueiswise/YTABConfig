import json
import unittest

from tools.report_provider import (
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


if __name__ == "__main__":
    unittest.main()
