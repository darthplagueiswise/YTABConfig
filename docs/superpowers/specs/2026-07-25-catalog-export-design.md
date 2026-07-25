# Catalog and Export Design

## Scope

Add standalone tooling for mining `YTGlobalConfig`, `YTColdConfig`, and
`YTHotConfig` BOOL methods from a completed YouTube decompile. The tool does
not modify or depend on `Settings.x` or `Tweak.x`.

## Architecture

The implementation uses only the Python standard library and has three
boundaries:

1. `tools/catalog_extractor.py` streams the three class files, extracts BOOL
   method definitions, experiment IDs, conservative default inference, and
   optionally bounded callsites. Evidence, callsites, and default inference
   remain separate fields.
2. `tools/catalog_model.py` merges a small curated overlay, validates catalog
   and runtime documents, and performs deterministic JSON serialization.
3. `tools/report_provider.py` imports/exports runtime state and renders a
   shareable Markdown or JSON report without any UIKit or tweak dependency.

Checked-in JSON Schemas version both the catalog and runtime export contracts.
The generated YouTube 21.28.3 catalog is reproducible by supplying an explicit
RFC 3339 `generatedAt` value.

## Data and Confidence

Every extracted selector gets a record. Generated titles are mechanical
camel-case splitting only; summaries remain `null`. Automated records have
`Unknown` editorial status. The curated overlay may add a human title,
category, risk, and `Inferred` or `Verified` status only when cited evidence
supports it. Unknown values remain JSON `null`; the tooling never generates a
feature description from a selector name.

`experimentID` is emitted only when the method body contains an
`objectForKey:` numeric literal. A native default is inferred only for
recognized decompiler branches that explicitly assign zero or one before the
method returns. The inference stores its method, confidence, and evidence
reference separately from definition evidence.

## Callsites and Scale

Definition extraction reads only the three known class files. Optional
callsite collection streams `.c` files once, recognizes direct decompiler
calls such as `-[YTColdConfig selector]`, excludes the selector's own
definition, sorts by source-relative path and line, and applies a deterministic
per-selector limit. This keeps memory bounded and makes callsite work optional
for very large trees.

## Runtime Export

Runtime documents identify the YouTube version, tweak version, device/app
context, and export time. Each record includes `native`, `override`, and
`effective` state plus catalog metadata. Import rejects an incompatible schema
or malformed record. The report provider sorts records by category, title,
class, and selector and never mutates the imported document.

## Testing

Fixtures cover experiment-backed and direct-backed BOOL methods, non-BOOL
rejection, default inference, evidence/callsite separation, deterministic
ordering, curated overlay behavior, schema validation, runtime round-trip, and
stable report rendering. Tests run with `python3 -m unittest discover`.

