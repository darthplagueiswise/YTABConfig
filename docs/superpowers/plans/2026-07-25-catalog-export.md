# Catalog and Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic, evidence-preserving YouTube config catalog and standalone runtime export/report API.

**Architecture:** A streaming extractor produces normalized catalog records, a model module validates and merges curated metadata, and a report provider handles runtime state separately. JSON Schemas make both documents machine-readable and versioned.

**Tech Stack:** Python 3 standard library, JSON Schema documents, `unittest`.

## Global Constraints

- Do not edit `Settings.x` or `Tweak.x`.
- Mine BOOL selectors only from `YTGlobalConfig`, `YTColdConfig`, and `YTHotConfig`.
- Never invent descriptions; unknown values remain unknown.
- Output must be deterministic for identical inputs and explicit generation metadata.
- Evidence, callsites, and default inference remain separately addressable.

---

### Task 1: Extraction Contract

**Files:**
- Create: `tests/fixtures/decompile/*.c`
- Create: `tests/test_catalog_extractor.py`
- Create: `tools/catalog_extractor.py`

**Interfaces:**
- Produces: `extract_catalog(source_root, youtube_version, generated_at, curated=None, include_callsites=False, max_callsites=20) -> dict`

- [ ] Write fixture-driven tests for BOOL filtering, experiment ID/default extraction, stable ordering, and distinct callsites.
- [ ] Run `python3 -m unittest tests.test_catalog_extractor -v` and confirm failure because the module is absent.
- [ ] Implement streaming definition extraction and optional bounded callsite collection.
- [ ] Re-run the extractor tests and confirm they pass.

### Task 2: Versioned Schemas and Validation

**Files:**
- Create: `catalog/schema/catalog-v1.schema.json`
- Create: `catalog/schema/runtime-export-v1.schema.json`
- Create: `tools/catalog_model.py`
- Create: `tests/test_catalog_model.py`

**Interfaces:**
- Produces: `validate_catalog(document)`, `validate_runtime_export(document)`, `merge_curated(records, overlay)`, and `dump_json(document)`.

- [ ] Write tests that reject missing fields, invalid statuses, duplicate selector keys, and invalid runtime override/effective state.
- [ ] Run `python3 -m unittest tests.test_catalog_model -v` and confirm failure because the module is absent.
- [ ] Implement dependency-free contract validation, deterministic serialization, and overlay merging.
- [ ] Re-run model tests and confirm they pass.

### Task 3: Runtime Export and Shareable Reports

**Files:**
- Create: `tools/report_provider.py`
- Create: `tests/test_report_provider.py`

**Interfaces:**
- Produces: `build_runtime_export(...) -> dict`, `import_runtime_export(payload) -> dict`, and `render_markdown_report(document) -> str`.

- [ ] Write round-trip and stable-report tests using literal expected state.
- [ ] Run `python3 -m unittest tests.test_report_provider -v` and confirm failure because the module is absent.
- [ ] Implement immutable import/export normalization and Markdown rendering.
- [ ] Re-run report tests and confirm they pass.

### Task 4: Curated 21.28.3 Artifact

**Files:**
- Create: `catalog/curated/youtube-21.28.3.json`
- Create: `catalog/generated/youtube-21.28.3.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: extractor CLI and curated overlay.
- Produces: checked-in full catalog and documented integration commands.

- [ ] Add a small overlay for directly evidenced language, transcript, badge, and long-press candidates, with null summaries where semantics are not proven.
- [ ] Generate twice with the same metadata and compare SHA-256 digests.
- [ ] Validate the generated catalog and report record/evidence/callsite counts.
- [ ] Document generation, validation, and runtime/report APIs.

### Task 5: Verification and Commit

**Files:**
- Verify all changed files.

- [ ] Run `python3 -m unittest discover -s tests -v`.
- [ ] Run `python3 -m compileall -q tools tests`.
- [ ] Run `make` if the local Theos environment is available; otherwise record the precise prerequisite failure.
- [ ] Verify `git diff -- Settings.x Tweak.x` is empty and `git diff --check` passes.
- [ ] Commit the complete implementation without pushing.
