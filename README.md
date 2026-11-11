# YTABConfig Feature Lab

YTABConfig Feature Lab is the maintained Afterglow Labs fork of YTABConfig for
reviewing experimental YouTube features with clear, reversible choices. It is
not a raw selector dump: unknown behavior stays marked for research instead of
being presented as a promise.

## iOS 27 startup crash + native Liquid Glass browser update (2026-11-10)

The 10:17:59 iOS 27 IPS shows an uncaught main-thread Core Data exception
at `NSManagedObjectModel _initWithContentsOfURL:options:` and a YTABConfig
frame directly beneath it. This is the same failure family as the three
09:13 IPS logs. The new crash-time dylib UUID
`59B88B83-A8D4-32F9-A600-45110A3524E1` does not match the last distributed
Feather build UUID `F7E4A4DF-428C-3D86-B5D4-23880ACDD63A`.
The exact failure reason is absent from the IPS, and on-device acceptance
of any fix cannot be inferred from a successful compile.

The earlier Core Data compatibility hook attempted the original optimized
`.momd` first and retried an unoptimized model only after the exception;
the new IPS demonstrates that **strategy did not prevent the abort**.
Now it verifies and prefers the original IPA's VersionInfo-selected
`DataLibDataModel-20.27.mom` *before* attempting the `.momd` initializer,
using the original Core Data implementation. No model is fabricated,
and unrelated model URLs pass through unchanged. If both paths fail, the
original exception remains visible. This is a targeted model-loader
compatibility hypothesis, **not** a device-validated crash fix.

The Runtime Patch Browser row UI has also been rebuilt. Before, it showed
an oversized stack with a monospaced selector, full type encoding, patch
key, multi-line status and three-segment selector in *every* cell.
Now rows use native UIKit Dynamic Type `Subheadline`, `Caption1`, and
`Caption2` with adaptive truncation, a real `UISwitch` for the effective
boolean, and a native button using iOS 26
`UIButtonConfiguration.glassButtonConfiguration` for the selected
`System / Force OFF / Force ON` mode. Choosing `System` restores the native
implementation. The checked mode menu shows which selection is active.
Tap a row to inspect the Objective-C encoding and copy the key; these are
no longer forced into the list. The standalone pinned `UISearchBar` still
feeds `ytab_currentSearchText` into `applyFilter` on every keystroke.
UIKit decides the surrounding native navigation material; the tweak does
not fake Liquid Glass using custom blur overlays. Source-level behavior
is verifiable; exact presentation on iOS 27 needs an on-device test.

## Runtime Patch Browser: observed system BOOL versus overrides

The old Runtime Patch Browser did **not** represent the current native BOOL
for getters that had never executed while instrumented. It displayed a
false-looking switch in those cases. It also only scanned the app main binary
and one optional Module_Framework.framework under the misleading `All` tab.

Revised state behavior:

- **System ON (last native getter result true):** green ON UIKit switch.
- **Override ON (forced true):** blue ON UIKit switch regardless of native.
- **Override OFF (forced false):** OFF switch, blue Override label even if
  the last native getter returned true.
- **System unknown:** visible `?` instead of an OFF switch, because it would
  be incorrect to invoke unknown getters on arbitrary receivers or argument
  values merely to populate the UI. `Native` values are the last observed
  return, not a timeless class-wide property.
- Long-press the row **or** its UISwitch for a native UIKit context menu.
  `Remove override (System)` immediately removes that selector's stored
  override and restores pass-through; `Force ON/OFF` remain available.
  The optional `Observe native calls (pass-through)` installs a transparent
  original-preserving hook for that getter without invoking it; future
  native calls update the visible switch via a coalesced main-thread
  notification.

Scope labels now mean: `YouTube` = the original main executable;
`Frameworks` = all **currently loaded** in-app framework images under
`YouTube.app/Frameworks/` (excluding injected tweak/support dylibs);
`All` = union of those two. Enumeration reads Objective-C runtime
classes and eligible BOOL/char-return instance/class methods with zero
or one supported argument. It does **not** cover all app logic:
not-yet-loaded classes, C/C++/Swift-only functions, generic non-BOOL
methods, multiple-argument methods, system images, or separately managed
`YTGlobalConfig`/`YTColdConfig`/`YTHotConfig` getters (these remain in
Raw Lab). Thus, the word `All` means all **supported, currently
enumerated Objective-C getters within those app images**, not the
entire app. Merely discovering a selector does not install an override.

## Real native BOOLs versus generic Objective-C methods (21.43.5)

The earlier screenshot displayed `?` next to `_ASCollectionPendingState`
methods because general Objective-C methods are not guaranteed to be called
after a hook is installed; their result may depend on the receiver and
arguments. Treating unknown as false would fabricate a value.

The Runtime Patch Browser now defaults to **Flags**, powered by the existing
`YTGlobalConfig`, `YTColdConfig`, `YTHotConfig` original native getter
cache obtained at launch by the PoomSmart-compatible hook path. The UI
reads `YTABCRuntimeValuesSnapshot` and `YTABCNativeValue` directly; config
override changes delegate to `YTABCSetOverride` / `YTABCClearOverride`,
rather than writing an independent override dictionary or duplicating the
config hooks. Native true = green, forced true = blue; forced false stays
off with a blue override label. Long-press Remove override (System) restores
the cached original behavior. `Flags` will be empty if native config
objects weren't captured (including when YTABConfig's main switch is off
at launch). This is reported explicitly instead of showing false values.

`Methods` isolates generic runtime Objective-C BOOL methods from the
main YouTube Mach-O. Their native value remains unknown until actually
observed, including argument- and receiver-dependent selectors. `Overrides`
shows only modified known config flags and runtime method entries.

The old `Frameworks` tab has been removed. The supplied sideload IPA's
`YouTube.app/Frameworks` includes CydiaSubstrate and many injected tweak
binaries, plus Widevine DRM and libswiftCompatibilitySpan; this directory
is not another YouTube feature-flag source. No second config hook system
is installed. `Methods` is not a universal function browser; it enumerates
compatible Objective-C BOOL-returning selectors only.

## YouTube 21.43.5 native Settings menus and iOS 26/27 search (2026-11-10)

The previous Runtime Patch Browser placed a custom UISearchBar inside a
pinned UITableView section header, which prevented **native iOS 26 search
morphing**. On iOS 26 and later, the browser now retains the original
`UISearchController` in `UINavigationItem.searchController`, opts into
`UINavigationItemSearchBarPlacementIntegrated` and
`searchBarPlacementAllowsToolbarIntegration`, places Apple's
`searchBarPlacementBarButtonItem` in `UIViewController.toolbarItems`, and
unhides the native `UINavigationController` toolbar while presented.
`updateSearchResultsForSearchController:` remains the real filter callback.
Prior iOS releases retain the pinned-header fallback. UIKit is responsible
for the Liquid Glass material, scroll edges, and search expand/collapse
transition; no artificial animation is created. The actual result must
still be evaluated on the sideloaded iOS 27 host navigation controller.

Four direct buttons were added at the front of the Feature Lab Settings
category: **Native Experiments — search & studies**, **Debug & QA tools**,
**Native Configs / Phenotype**, and **Hidden Settings rows**. The original
experiments launcher uses the real `YTSettingsExperimentsTopViewController`
with live `YTSettingsViewController` as its parentResponder. Debug and Config
actions open focused, real native tools sections; Config flags open the
captured-BOOL browser without duplicate config hooks.

`YTABCSettingsRowsInspector.m` is a read-only native Settings inspector.
It validates the Objective-C method ABIs and reads
`-[YTSettingsViewController settingsSectionControllers]`,
`+[YTAppSettingsPresentationData settingsCategoryOrder]`, and
`YTSettingsSectionController` properties `items`, `title`, `isHeaderHidden`,
and `isDisabled`. It distinguishes an actual loaded section from a
declared-but-unloaded category; only loaded rows can be inspected.
No server-ineligible categories or rows are fabricated or unlocked.

The original YouTube executable has methods:
`YTSettingsViewController updateDebugAndQASections:withEntry:`
(`0x1013cde08`) with an empty `ret` implementation in 21.43.5;
`YTSettingsViewController collectionView:layout:itemIsHiddenAtIndexPath:`
(`0x1013cde0c`); `settingsSectionControllers` (`0x1013ccda0`);
`YTAppSettingsPresentationData settingsCategoryOrder` (`0x10141f460`).
These were confirmed from the IPA's original ARM64 binary; methods with
Debug or Internal in their names are not necessarily UIViewControllers or
legitimate launchers.

## Operational contract

- Runs inside the iOS YouTube app; YouTube 16.29.4 and newer are the supported
  baseline.
- Raw Lab enumerates the three live Objective-C config classes from the
  installed YouTube build through the same cache-backed method hooks used by
  PoomSmart 1.9.2. Runtime behavior is not gated by a catalog version or by
  hard-coded expected counts.
- Uses the established `com.ps.ytabconfig` package identity and existing
  `YTABC` preferences, so this 2.0.4 fork release upgrades without discarding
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

There are three independent, default-OFF **local** Objective-C BOOL
overrides: `isGooglerAccount:`, `hasGooglerAccount`, and
`isInternalHeterodyneSyncer`. Each hook returns `YES` when its respective
toggle is ON and returns the original native BOOL when OFF. The diagnostic
view distinguishes observed native results from enabled local overrides.
These hooks do not alter identity credentials or remote requests.

The module also observes the original
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
unavailable until the corresponding native instance has been observed. The three opt-in local BOOL overrides do not grant server-side entitlements.

The old incomplete `YTInternalIdentity.x` remains as uncompiled historical
source; it must not be used to claim that an Employee mode exists. This is
separate from exposing local debug UI controllers.

## YouTube 21.43.5 startup CoreData crash — 2026-11-10

Three independent iOS 27.0 `.ips` crash reports (09:13:45, 09:13:51,
09:13:56) showed identical main-thread `EXC_CRASH / SIGABRT` stacks:
`YTPingStoreImpl.init` → `YTInnerTubeCoreDataContext.init` →
`YTCoreDataContext.initWithModelName:...` →
`NSManagedObjectModel.initWithContentsOfURL:` →
`CoreData _initWithContentsOfURL:options:` (exception thrown).
The executable and tweak UUIDs were verified against the provided IPA and
Feather `.deb`, respectively. The report has no exception *reason*, so the
underlying failure (a missing resource in the installed IPA, a malformed
model, iOS 27 .omo compatibility, or another hook interfering with lookup)
is **not proven** by stack traces alone.

The YouTube ARM64 initializer supplies `DataLibDataModel`. The original IPA
contains `DataLibDataModel.momd/VersionInfo.plist` (current version
`DataLibDataModel-20.27`), as well as compiled `.omo` and `.mom` files.
The current `.mom` decodes as a valid NSKeyedArchiver binary plist.

`YTABCoreDataModelCompatibility.m` hooks only
`-[NSManagedObjectModel initWithContentsOfURL:]`. Normally it delegates to
the original implementation unchanged. For an original URL inside
`DataLibDataModel.momd` **and only if the original model load fails**, it
locates the `VersionInfo.plist`-selected version's `.mom` file, invokes
the same original CoreData initializer on a fresh model object, and returns
the valid model if loaded. When neither load works, it rethrows the original
exception rather than manufacturing a blank model or continuing with
corrupt state. The logs include the CoreData exception name/reason to make
follow-up diagnosis possible. This is a compatibility fallback, **not**
proof of a resolved on-device crash.

**Packaging requirement:** Feather/injection must preserve the entire
`Payload/YouTube.app/DataLibDataModel.momd` directory. The tweak .deb does
not contain or replace Google's proprietary model resources. If the
installed app lacks the directory, reinstall from an IPA with the original
model bundle intact. Running a different injected tweak suite can still
alter the underlying process independently.

The user-supplied `settings_experiments_study_header.flexb` is a 120-byte
native study-header layout definition with `root`, `layerLabel`,
`titleLabel`, `disclosureArrow`, and `linkLabel`. It is not the
CoreData model and supplies no experiment query parameters or auth gates.

## Audited study layouts and live study controls (YouTube 21.43.5)

Both resources are loaded by original app classes, as established from ARM64
XREFs into the Mach-O CFString table (not only by scanning names):

- `settings_experiments_study_header.flexb` CFString `0x10bb485c0`:
  `YTSettingsExperimentStudyHeader -resetLayout` at `0x10143197c`
  uses ADRP `0x1014319b8` + ADD `0x1014319bc`.
- `settings_experiments_study_item_cell.flexb` CFString `0x10bb485e0`:
  `YTSettingsExperimentStudyItemCell -resetLayout` at `0x10143243c`
  uses ADRP `0x101432498` + ADD `0x10143249c`.
  It selects `shortCell` (`0x10bb48600`) or `regularCell`
  (`0x10bb48620`) based on the cell's native method result.

The native ownership path is:
`YTSettingsExperimentStudySectionController -handleEntries:`
(`0x101432eb0`) -> `-createCellControllerForEntry:` (`0x101432f18`)
-> `YTSettingsExperimentStudyItemCellController -initWithEntry:parentResponder:`
(`0x101432644`) -> `YTSettingsExperimentStudyItemCell -setEntry:`
(`0x1014320c4`). Header updates use
`YTSettingsExperimentStudySectionController -updateHeader:` (`0x101433038`).
Study selection and opt-in are handled by native
`YTSettingsExperimentStudyItemCellController -didToggleSwitch`
(`0x101432990`) and `-showAlertForJoiningExperiment`
(`0x101432ab8`). The cell exposes `studyIneligibleBadge` and `optInButton`;
that is UI state, not proof of a particular server eligibility gate.

`YTABNativeStudyControls.m` instruments those actual methods with exact
Objective-C ABI checks and calls each original. Hooks are installed lazily
only when opening the experiments menu, not during YouTube cold start.
The Native Tools row **Study layout, badge & opt-in state** shows the
rendered item count, most recently bound cell's actual badge/opt-in
visibility/enabled/on state and count of user-triggered opt-in callbacks.
The module never creates a fake study, changes eligibility or supplies
a fabricated server response.

**Runtime search regression fixed:** The old modern Runtime Patch Browser
reparented `UISearchController.searchBar` into a `UITableView` header while
keeping the filter bound to the search controller's lifecycle. Its replacement
creates an independent `UISearchBar`, keeps it in the pinned plain-table
section header, and feeds `searchBar:textDidChange:` into the base engine via
the overridden `ytab_currentSearchText`. Filtering therefore uses exactly
the visible search field and does not depend on UISearchController activation.

## Native experiments empty screen / runtime UI corrections

The extracted YouTube 21.43.5 ARM64 image confirms that
`YTSettingsExperimentsViewController.initWithParentResponder:` takes a
**single parent responder**, and internally creates the results page. The
top-level experiment controller does **not** take a Googler or Heterodyne
parameter. It is incorrect to initialize `ResultsViewController`
independently or claim a specific account gate without runtime evidence.

**Concrete launcher bug fixed:** `YTSettingsViewController` and
`YTSettingsExperimentsViewController` both inherit from
`YTStyledViewController`. Previously the launcher supplied
`settingsVC.parentResponder`, skipping the live Settings controller in
the chain. The launcher now passes the current `settingsVC` itself
and validates the native Objective-C initializer encoding. The local
responder chain is corrected; a populated server response is not
guaranteed.

`YTABNativeExperimentsHealth.m` hooks the original view-controller lifecycle
and observes `updateDataForTab:`, `makeSearchWithQuery:forTabIndex:`,
and `YTSettingsExperimentsResultsViewController.addSectionsFromArray:`.
**Why is native experiments blank?** now reports the availability of the
native parent responder, the native tab controllers, whether search was
invoked, and whether result sections were received. **Retry current native
experiments tab** calls the app's original tab refresh method only for a
valid existing selected tab. Neither action forges experiments, auth,
service instances or a remote response. The exact cause of an empty result
still requires runtime evidence (no request vs. error vs. empty response).

Runtime Browser presentation now uses a plain UIKit table with a pinned
native `UISearchBar`, a stable source control and native iOS navigation
materials. It uses smaller system fonts and system segments. Patch mode
changes call the native hook engine and are **not persisted if hook
installation fails**. Rows distinguish `native` (last sampled),
`effective` and actual `hook installed` state, explicitly showing
`not sampled` when a getter has not executed. All modes retain the
persisted `YTABCRuntimeBrowserOverrides` format. The Feature Lab list
also retains its search bar on scroll, shows override modes, and disables
unavailable switches rather than representing them as OFF.

iOS 26/27 Liquid Glass comes from standard UIKit controls compiled with the
modern SDK; the tweak must not fake it with custom blur/background layers.
These static changes are **not** equivalent to verified on-device appearance.

## Native YouTube menus (21.43.5 binary audit)

The **Open YouTube native tools** row is now available inside the existing
**Feature Lab** settings category. It is a local navigation hub, not a
server-authorized employee/internal account mode.

The **YouTube 21.43.5 ARM64 disassembly** confirms the main experiment
view controller instantiates its Results controllers internally
(`0x101434748`, `YTSettingsExperimentsResultsViewController` class reference
`0x10cbdada8`). Results must therefore be opened through the parent
experiments screen, **not** through a standalone Results initializer.

The hub exposes separate, guarded launchers for the native
`YTSettingsExperimentsTopViewController` (existing push/modal openers),
`YTSettingsExperimentsViewController` (search and tabs), and
`YTSettingsExperimentsResultsViewController` (results, owned by the root). Each constructor is
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

For Feather, use `YTABConfig_2.0.4_feather.deb` with the default
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
version, then add only `YTABConfig_2.0.4_feather.deb`; do not also add the
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
