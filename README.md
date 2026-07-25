# YTABConfig

Configures A/B settings in iOS YouTube app.

## Supported YouTube versions

Confirmed version 16.29.4 and newer. Lower are either untested or unsupported.

## Machine-readable config catalog

The extractor produces a versioned catalog of BOOL selectors recovered from a
YouTube decompile. Its records keep
definition evidence, optional callsites, and conservative native-default
inference in separate fields. Generated records have mechanical titles and
`null` summaries; only the small overlay in
`catalog/curated/youtube-21.28.3.json` adds human metadata. A selector name is
never expanded into a generated description.

Full generated catalogs are intentionally ignored under `catalog/generated/`;
they are reproducible analysis artifacts, not app payloads. The committed
curated seed is the small metadata surface intended for app integration.

The catalog and structured runtime export contracts are:

- `catalog/schema/catalog-v1.schema.json`
- `catalog/schema/runtime-export-v1.schema.json`

Generate a catalog with an explicit timestamp so identical inputs produce
byte-identical JSON:

```bash
python3 tools/catalog_extractor.py \
  "/path/to/YouTube_decompiled/C Files/YouTube (YT)" \
  --youtube-version 21.28.3 \
  --generated-at 2026-07-25T00:00:00Z \
  --curated catalog/curated/youtube-21.28.3.json \
  --include-callsites \
  --max-callsites 3 \
  --output catalog/generated/youtube-21.28.3.json
```

Definition extraction reads only `YTGlobalConfig.c`, `YTColdConfig.c`, and
`YTHotConfig.c`. Callsite collection is opt-in, uses ripgrep when available,
falls back to a single streaming tree pass, and keeps the lexicographically
first bounded set per selector regardless of scan order.

### Integration API

The standalone modules do not import or modify tweak runtime/UI code:

```python
from tools.catalog_extractor import extract_catalog
from tools.catalog_model import validate_catalog, validate_runtime_export
from tools.report_provider import (
    build_runtime_export,
    import_runtime_export,
    render_markdown_report,
)
```

`build_runtime_export(catalog_records, youtube_version=..., tweak_version=...,
exported_at=..., context=..., states=...)` accepts state entries keyed by
`(class_name, selector)`. Each state may contain `native` (`True`, `False`, or
`None`) and `override` (`inherit`, `force-on`, or `force-off`). The resulting
record contains explicit `native`, `override`, and `effective` objects.

`import_runtime_export(payload)` accepts JSON text, bytes, or a mapping,
validates schema version and state consistency, and returns a defensive copy.
`render_markdown_report(document)` returns a stable category-sorted shareable
report. Runtime integration can therefore capture selector values in Objective-C
and pass the resulting state map to this provider without coupling catalog
generation to hooks or settings UI.

Run the dependency-free contract tests with:

```bash
python3 -m unittest discover -s tests -v
```
