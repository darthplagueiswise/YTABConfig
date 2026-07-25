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
  --expected-count YTColdConfig=6351 \
  --expected-count YTGlobalConfig=21 \
  --expected-count YTHotConfig=2459 \
  --include-callsites \
  --max-callsites 3 \
  --output catalog/generated/youtube-21.28.3.json
```

Definition extraction reads only `YTGlobalConfig.c`, `YTColdConfig.c`, and
`YTHotConfig.c`. It reports recognized headers, BOOL candidates, and extracted
records per class. Extraction requires at least one record per class by default;
use explicit `--expected-count CLASS=COUNT` arguments for release artifacts so
decompiler format drift fails closed. Callsite collection is opt-in, streams
the C tree while ignoring comments and strings, deduplicates source lines, and
records whether the per-selector bounded evidence was truncated.

Curated overlays are version-bound. `Inferred` and `Verified` entries require a
non-empty rationale and evidence IDs that exist on the extracted record. The
committed seed remains `Unknown` until that binding is supplied.

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
rejects oversized, duplicate-key, non-finite, unknown-field, or inconsistent
state input, and returns a defensive copy.
`render_markdown_report(document)` returns a stable category-sorted shareable
report. Runtime integration can therefore capture selector values in Objective-C
and pass the resulting state map to this provider without coupling catalog
generation to hooks or settings UI.

Run the dependency-free contract tests with:

```bash
python3 -m unittest discover -s tests -v
```
