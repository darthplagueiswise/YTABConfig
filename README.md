# YTABConfig Feature Lab

YTABConfig Feature Lab is the maintained Afterglow Labs fork of YTABConfig for
reviewing experimental YouTube features with clear, reversible choices. It is
not a raw selector dump: unknown behavior stays marked for research instead of
being presented as a promise.

## Operational contract

- Runs inside the iOS YouTube app; YouTube 16.29.4 and newer are the supported
  baseline.
- Raw Lab enumerates the three live Objective-C config classes from the
  installed YouTube build through the same cache-backed method hooks used by
  PoomSmart 1.9.2. Runtime behavior is not gated by a catalog version or by
  hard-coded expected counts.
- Uses the established `com.ps.ytabconfig` package identity and existing
  `YTABC` preferences, so this 2.0.0 fork release upgrades without discarding
  existing choices.
- Apply changes only when you understand the setting; reset and restart
  YouTube to return to the app's normal behavior.
- Report support questions and verified findings in [Afterglow Labs
  Discussions](https://github.com/afterglow-labs/YTABConfig/discussions), and
  report defects through [GitHub Issues](https://github.com/afterglow-labs/YTABConfig/issues).

## Live runtime workflow

Launch behavior deliberately stays compatible with PoomSmart 1.9.2: the tweak
enumerates the current `YTGlobalConfig`, `YTColdConfig`, and `YTHotConfig`
instances, invokes each supported native BOOL getter once, stores that value in
the shared cache, and calls `MSHookMessageEx(..., NULL)` before YouTube's
original app-delegate implementation. It does not retain original IMPs or
install a parallel registry. The master switch remains default-off, matching
PoomSmart; an existing `EnabledYTABC` preference is preserved.

Feature Lab is a query layer over that same live cache and hook set. It never
installs a second registry of hooks. Opening Raw Lab reads the current selector
set from the running app. Visible rows and reports read the native value captured
immediately before the hook; they never call the original getter again.

The YouTube 21.30.5 arm64 binary was audited as a compatibility fixture. The
three config classes are in the main executable (there is no
`Module_Framework.framework`) and expose 9,449 raw BOOL method-list entries.
The lists contain 147 duplicate entries across 142 selector names. Matching
PoomSmart's selector deduplication gives 9,302 unique BOOL getters before the
existing platform-prefix exclusions, or 6,093 Raw Lab flags after them. These
figures are diagnostic evidence only; they are never compiled into the runtime.

Both the rootless deb and sideload variants compile with the rootless Mach-O
scheme, but their final install names intentionally differ. The deb keeps the
rootless `@rpath/YTABConfig.dylib` identity. Sideload artifacts use explicit
`@executable_path` identities that must match where the injector copies the
file.

## Native Phenotype and InnerTube instrumentation (YouTube 21.43.5)

`YTABNativeDiagnostics.m` now implements a **compiled**, runtime-checked
diagnostics layer for the actual Objective-C methods in the YouTube main
executable. This supersedes the previous draft's missing functions. The module
uses `MSHookMessageEx` only after an exact type-encoding comparison, and
continues to call each original method unchanged.

It records the native results of `hasGooglerAccount` and
`isInternalHeterodyneSyncer` rather than pretending a non-Googler account
is an internal Google identity. It observes the original
`PHTHeterodyneSyncer.syncWithCallback:` and
`PHTFlatFilePhenotype.syncExperimentsWithServerInternal:syncAfterConfiguration:callback:`
paths. An optional manual resync uses only the real previously observed syncer.
It never changes authentication, tokens or server URLs. A successfully queued
native call does not imply that a server accepted the sync.

The native `YTExperimentsServiceImpl` search, opt-in, and opt-out calls are
traced independently. The `clearCaches` action targets only a live service
observed on one of those paths. Request payloads, account IDs and auth tokens
are intentionally omitted from logs.

Feature Lab provides switches for the four independent traces, a read-only
diagnostic state dialog, native resync and native cache clear. These actions are
unavailable until the corresponding native instance has been observed. No
authentication or employee/dogfood entitlement bypass is exposed.

The old incomplete `YTInternalIdentity.x` remains as uncompiled historical
source; it must not be used to claim that an Employee mode exists. This is
separate from exposing local debug UI controllers.

## Native YouTube menus (21.43.5 binary audit)

The **Open YouTube native tools** row is now available inside the existing
**Feature Lab** settings category. It is a local navigation hub, not a
server-authorized employee/internal account mode.

The hub exposes separate, guarded launchers for the native
`YTSettingsExperimentsTopViewController` (existing push/modal openers),
`YTSettingsExperimentsViewController` (search and tabs), and
`YTSettingsExperimentsResultsViewController` (results). Each constructor is
checked at runtime, receives the live settings `parentResponder`, and
reports failures without trying arbitrary initializers. A results page may
be empty unless the native experiment service has results available.

It also observes YouTube's own playback debug overlay when the player
installs its gesture recognizer. The toggle controls that *existing* object;
it does **not** create a fake player or assume the two-finger gesture was
activated. The creation timeline debug console can be toggled explicitly
when its native shared instance and selector are present.

Watch/Lens debug providers, Phenotype, Developer/QA and YouTube configuration
components are shown as **read-only class inventories**. They are not
represented as launchable UIViewControllers without verified constructors.
No hooks in this new module bypass authentication, change Googler status,
request experiment opt-in/opt-out, or write Phenotype snapshots.

The menu module was audited against the provided YouTube 21.43.5 IPA.
Its iOS build/runtime behavior still requires compilation and device
validation. Theos files: `YTABCNativeMenus.m`, `YTABCNativeMenus.h`,
`Settings.x`, `Tweak.x`, and `Makefile`.

## Sideload packaging

For Feather, use `YTABConfig_2.0.0_feather.deb` with the default
`@executable_path` + `Frameworks` injection options. Its archive uses
`data.tar.xz`, its rootless paths are recognized by Feather's deb importer, and
the contained dylib identifies itself as
`@executable_path/Frameworks/YTABConfig.dylib`. Feather copies `YTABC.bundle`
from Application Support to the app root.

Start from an IPA that does not already contain YTABConfig. Feather's current
`moveFileIfNeeded` implementation leaves an existing destination untouched, so
injecting this deb into an IPA that already has
`YouTube.app/Frameworks/YTABConfig.dylib` can preserve the old dylib even though
the new deb was selected. The supplied black-screen fixture had both that old
file and an existing
`@executable_path/Frameworks/YTABConfig.dylib` load command. Reusing it as the
input therefore does not test this build. Use a clean copy of the same YouTube
version, then add only `YTABConfig_2.0.0_feather.deb`; do not also add the
rootless deb, standalone injector, or an older YTABConfig dylib.

The recommended layout ZIP is ready to unpack into `YouTube.app/`:

- `Frameworks/YTABConfig.dylib` identifies itself as
  `@executable_path/Frameworks/YTABConfig.dylib`.
- `YTABC.bundle` remains at the root of `YouTube.app/`.
- Substrate loads through
  `@rpath/CydiaSubstrate.framework/CydiaSubstrate`, which resolves through
  YouTube's existing `@executable_path/Frameworks` rpath.

The separate `_injector.dylib` is for tools that accept one dylib and always
copy it to the root of `YouTube.app/`. Its identity is
`@executable_path/YTABConfig.dylib`; copy `YTABC.bundle` separately.

Do not combine an `@rpath/YTABConfig.dylib` load command with a
root-level `YouTube.app/YTABConfig.dylib` unless the executable also has an
`@executable_path` rpath. For the Feather artifact, the only supported pairing
is `YouTube.app/Frameworks/YTABConfig.dylib` with
`@executable_path/Frameworks/YTABConfig.dylib`.

## Catalog workflow

Raw Lab discovers the live flag list at runtime. The committed catalog contains
only reviewed metadata; full decompile catalogs are generated on demand and are
not shipped in the tweak. A catalog is loaded only when its `youtubeVersion`
matches the installed app. The embedded reviewed seed now targets 21.30.5 and
is opened only after the user selects **Open Feature Lab**; it is not read while
YouTube launches.

```bash
python3 tools/catalog_extractor.py "/path/to/YouTube (YT)" \
  --youtube-version 21.30.5 \
  --generated-at 2026-07-27T00:00:00Z \
  --curated catalog/curated/youtube-21.30.5.json \
  --expected-count YTColdConfig=6648 \
  --expected-count YTGlobalConfig=24 \
  --expected-count YTHotConfig=2630 \
  --include-callsites \
  --max-callsites 3 \
  --output catalog/generated/youtube-21.30.5.json

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
