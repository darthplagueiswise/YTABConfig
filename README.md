# YTABConfig Feature Lab

YTABConfig Feature Lab is the maintained Afterglow Labs fork of YTABConfig for
reviewing experimental YouTube features with clear, reversible choices. It is
not a raw selector dump: unknown behavior stays marked for research instead of
being presented as a promise.

## Operational contract

- Runs inside the iOS YouTube app; YouTube 16.29.4 and newer are the supported
  baseline.
- Uses the established `com.ps.ytabconfig` package identity and existing
  `YTABC` preferences, so this 2.0.0 fork release upgrades without discarding
  existing choices.
- Apply changes only when you understand the setting; reset and restart
  YouTube to return to the app's normal behavior.
- Report support questions and verified findings in [Afterglow Labs
  Discussions](https://github.com/afterglow-labs/YTABConfig/discussions), and
  report defects through [GitHub Issues](https://github.com/afterglow-labs/YTABConfig/issues).

## Catalog workflow

Raw Lab discovers the live flag list at runtime. The committed catalog contains
only reviewed metadata; full decompile catalogs are generated on demand and are
not shipped in the tweak.

```bash
python3 tools/catalog_extractor.py "/path/to/YouTube (YT)" \
  --youtube-version 21.28.3 \
  --generated-at 2026-07-25T00:00:00Z \
  --curated catalog/curated/youtube-21.28.3.json \
  --expected-count YTColdConfig=6351 \
  --expected-count YTGlobalConfig=21 \
  --expected-count YTHotConfig=2459 \
  --include-callsites \
  --max-callsites 3 \
  --output catalog/generated/youtube-21.28.3.json

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

Run the dependency-free contract tests with:

```bash
python3 -m unittest discover -s tests -v
```

The schemas live under `catalog/schema/`. Unknown behavior stays unknown until
runtime evidence supports a documented explanation.

## Credits and license

Original YTABConfig by PoomSmart.

Afterglow Labs maintains this Feature Lab fork while preserving that
attribution. This project remains licensed under the
[GNU General Public License v3.0](LICENSE).
