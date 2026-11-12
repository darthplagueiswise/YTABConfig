import copy
import json
import unittest
from importlib.util import find_spec
from pathlib import Path

if __package__:
    from .test_catalog_model import minimal_catalog
else:
    from test_catalog_model import minimal_catalog
from tools.report_provider import build_runtime_export


JSONSCHEMA_AVAILABLE = find_spec("jsonschema") is not None
ROOT = Path(__file__).parents[1]


@unittest.skipUnless(JSONSCHEMA_AVAILABLE, "optional jsonschema package not installed")
class JsonSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import jsonschema

        cls.jsonschema = jsonschema

    def test_catalog_schema_accepts_valid_document_and_rejects_bad_status(self):
        schema = json.loads(
            (ROOT / "catalog/schema/catalog-v1.schema.json").read_text()
        )
        document = minimal_catalog()
        self.jsonschema.Draft202012Validator.check_schema(schema)
        self.jsonschema.validate(document, schema)

        invalid = copy.deepcopy(document)
        invalid["records"][0]["status"] = "Maybe"
        with self.assertRaises(self.jsonschema.ValidationError):
            self.jsonschema.validate(invalid, schema)

        invalid = copy.deepcopy(document)
        invalid["records"][0]["experimentID"] = -1
        with self.assertRaises(self.jsonschema.ValidationError):
            self.jsonschema.validate(invalid, schema)

    def test_runtime_schema_accepts_provider_output(self):
        schema = json.loads(
            (ROOT / "catalog/schema/runtime-export-v1.schema.json").read_text()
        )
        catalog_record = minimal_catalog()["records"][0]
        document = build_runtime_export(
            [catalog_record],
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={},
            states={},
        )

        self.jsonschema.Draft202012Validator.check_schema(schema)
        self.jsonschema.validate(document, schema)

        document["records"][0]["override"] = {"mode": "force-on", "value": False}
        with self.assertRaises(self.jsonschema.ValidationError):
            self.jsonschema.validate(document, schema)

        document = build_runtime_export(
            [catalog_record],
            youtube_version="21.28.3",
            tweak_version="1.9.2",
            exported_at="2026-07-25T00:00:00Z",
            context={},
            states={("YTColdConfig", "sampleFlag"): {"native": True}},
        )
        document["records"][0]["effective"] = {
            "value": False,
            "source": "native",
        }
        with self.assertRaises(self.jsonschema.ValidationError):
            self.jsonschema.validate(document, schema)


if __name__ == "__main__":
    unittest.main()
