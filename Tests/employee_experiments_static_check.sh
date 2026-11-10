#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

require_text() {
  local file="$1" needle="$2"
  grep -Fq -- "$needle" "$file" || { echo "missing '$needle' in $file" >&2; exit 1; }
}
reject_text() {
  local file="$1" needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "obsolete/unimplemented hook '$needle' still referenced by $file" >&2
    exit 1
  fi
}

# Existing native studies push+modal entry points remain callable and compiled.
require_text Makefile "YTNativeExperiments.x YTABCNativeMenus.m YTABCSettingsRowsInspector.m YTABNativeDiagnostics.m"
require_text Settings.x "YTABCPushNativeMenuHubForCategory(settingsViewController, route)"
require_text Settings.x "YTABC_NATIVE_QUICK_"
require_text Settings.x '@"Native Experiments — search & studies"'
require_text Settings.x '@"Debug & QA tools"'
require_text Settings.x '@"Native Configs / Phenotype"'
require_text Settings.x '@"Hidden Settings rows"'
require_text YTABCNativeMenus.h "YTABCPushNativeMenuHubForCategory"
require_text YTABCNativeMenus.m "YTABCCreateSettingsRowsInspector(owner)"
require_text YTABCNativeMenus.m '@"configFlags"'
require_text YTABCSettingsRowsInspector.m '"settingsSectionControllers"'
require_text YTABCSettingsRowsInspector.m '@selector(settingsCategoryOrder)'
require_text YTABCSettingsRowsInspector.m '"isHeaderHidden"'
require_text YTABCSettingsRowsInspector.m '"isDisabled"'
require_text YTABCSettingsRowsInspector.m '"items"'
require_text YTABCSettingsRowsInspector.m "Rows suppressed by server logic are not synthesized or unlocked."
# Native loaded-section visibility is reversible; no server-supplied rows or
# isDisabled/eligibility setters are synthesized by the inspector.
require_text YTABCSettingsRowsInspector.m 'ytabc_setHeaderHidden:'
require_text YTABCSettingsRowsInspector.m 'ytabc_revealButtonTapped:'
require_text YTABCSettingsRowsInspector.m 'setSectionItems:forCategory:title:icon:titleDescription:headerHidden:'
require_text YTABCSettingsRowsInspector.m 'existing, number.unsignedIntegerValue'
require_text YTABCSettingsRowsInspector.m 'self.originalHidden[category]'
require_text YTABCSettingsRowsInspector.m 'if (![items isKindOfClass:NSArray.class]'
reject_text YTABCSettingsRowsInspector.m 'setDisabled:'
require_text YTABCNativeMenus.m 'Reveal loaded Settings sections'

require_text Settings.x "YTABCPushNativeExperiments(settingsViewController)"
require_text Settings.x "YTABCPresentNativeExperiments(settingsViewController)"
require_text Settings.x "YTABCPushNativeMenuHub(settingsViewController)"
require_text Settings.x '@"YTABC_NATIVE_TOOLS_OPEN"'
require_text YTNativeExperiments.x 'initWithParentResponder:'
require_text YTNativeExperiments.x 'Class experimentsClass = NSClassFromString(@"YTSettingsExperimentsViewController");'
require_text YTNativeExperiments.x 'id parentResponder = settingsViewController;'
require_text YTNativeExperiments.x 'strcmp(method_getTypeEncoding(nativeInit), "@24@0:8@16")'
reject_text YTNativeExperiments.x 'parentResponder = [settingsViewController parentResponder];'
require_text YTABCNativeMenus.m 'id responder = owner;'
require_text YTABCNativeMenus.m 'YTSettingsExperimentsViewController'
require_text YTABCNativeMenus.m 'YTSettingsExperimentsResultsViewController'
require_text Makefile 'YTABNativeExperimentsHealth.m'
require_text Makefile 'YTABNativeStudyControls.m'
require_text YTNativeExperiments.x 'YTABCInstallNativeStudyControlsHooks();'
require_text YTABCNativeMenus.m 'YTABCCopyNativeStudyControls()'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudyHeader", "resetLayout", "v16@0:8"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudyItemCell", "resetLayout", "v16@0:8"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudyItemCell", "setEntry:", "v24@0:8@16"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudyItemCellController", "didToggleSwitch", "v16@0:8"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudyItemCellController", "showAlertForJoiningExperiment", "v16@0:8"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudySectionController", "updateHeader:", "v24@0:8@16"'
require_text YTABNativeStudyControls.m '"YTSettingsExperimentStudySectionController", "handleEntries:", "v24@0:8@16"'
require_text YTABNativeStudyControls.m 'sOriginalSetEntry(instance, selector, entry);'
reject_text Tweak.x 'YTABCInstallNativeStudyControlsHooks();'
# Crash reports: YTInnerTubeCoreDataContext.init -> DataLibDataModel model load
# on the main thread. A targeted fallback is safer than suppressing CoreData
# exceptions or modifying unrelated model initializers.
require_text Makefile 'YTABCoreDataModelCompatibility.m'
require_text Makefile '$(TWEAK_NAME)_FRAMEWORKS = UIKit CoreData'
require_text Tweak.x 'YTABCInstallCoreDataModelCompatibility();'
require_text YTABCoreDataModelCompatibility.m 'NSManagedObjectModel'
require_text YTABCoreDataModelCompatibility.m 'initWithContentsOfURL:'
require_text YTABCoreDataModelCompatibility.m 'DataLibDataModel.momd'
require_text YTABCoreDataModelCompatibility.m 'NSManagedObjectModel_CurrentVersionName'
require_text YTABCoreDataModelCompatibility.m 'YTABCDataLibUnoptimizedModelURL(url)'
require_text YTABCoreDataModelCompatibility.m 'sYTABCOriginalModelInit(receiver, selector, momURL)'
require_text YTABCoreDataModelCompatibility.m 'sYTABCOriginalModelInit([NSManagedObjectModel alloc], selector, url)'
require_text YTABCoreDataModelCompatibility.m 'memcmp(contents.bytes, "bplist00", 8)'
require_text YTABCoreDataModelCompatibility.m 'Loading VersionInfo-selected'
reject_text YTABCoreDataModelCompatibility.m 'mergedModelFromBundles'
reject_text YTABCoreDataModelCompatibility.m 'modelWithEntities'

require_text Tweak.x 'YTABCInstallNativeExperimentsHealthHooks();'
require_text YTABNativeExperimentsHealth.m 'initWithParentResponder:'
require_text YTABNativeExperimentsHealth.m 'addSectionsFromArray:'
require_text YTABNativeExperimentsHealth.m 'makeSearchWithQuery:forTabIndex:'
require_text YTABNativeExperimentsHealth.m 'updateDataForTab:'
require_text YTABNativeExperimentsHealth.m '@"parentResponderWasNonNil"'
require_text YTABNativeExperimentsHealth.m '@"lastResultSectionCount"'
require_text YTABCNativeMenus.m 'YTABCCopyNativeExperimentsHealth()'
require_text YTABCNativeMenus.m 'YTABCRetryNativeExperimentsSelectedTab()'
require_text YTABCNativeMenus.m 'classref 0x10cbdada8'
require_text YTABCNativeMenus.m 'YTSettingsExperimentsViewController'
reject_text YTABCNativeMenus.m '@"class": @"YTSettingsExperimentsResultsViewController"'
require_text YTABCNativeMenus.m 'YTPlaybackDebugOverlayController'
require_text YTABCNativeMenus.m 'YTCreationTimelineDebugConsole'
require_text YTABCNativeMenus.m 'YTABCInstallNativeMenuObservationHooks'
require_text YTABCNativeMenus.m 'method_getNumberOfArguments'
require_text YTABCNativeMenus.m 'sYTABCObservedPlaybackOverlay = self;'
require_text Tweak.x 'YTABCInstallNativeMenuObservationHooks();'
require_text Tweak.x 'YTABCInstallNativeDiagnostics();'
require_text YTABNativeDiagnostics.m 'objc_lookUpClass("PHTHeterodyneSyncer")'
require_text YTABNativeDiagnostics.m 'objc_lookUpClass("PHTFlatFilePhenotype")'
require_text YTABNativeDiagnostics.m 'objc_lookUpClass("YTExperimentsServiceImpl")'
require_text YTABNativeDiagnostics.m 'MSHookMessageEx(cls,selector,replacement,original);'
# Eligibility evidence: trace actual native category entries and service
# completion/error callbacks without introducing account or network forgery.
require_text Settings.x 'YTABCRecordSettingsCategoryUpdate(category, entry);'
require_text YTABNativeDiagnostics.m 'void YTABCRecordSettingsCategoryUpdate(NSUInteger category, id entry)'
require_text YTABNativeDiagnostics.m 'YTABReadEndpointPresence'
require_text YTABNativeDiagnostics.m 'searchSuccessCallbacks'
require_text YTABNativeDiagnostics.m 'searchFailureCallbacks'
require_text YTABNativeDiagnostics.m 'lastSearchHTTPStatus'
require_text YTABNativeDiagnostics.m 'category30EntryClass'
require_text YTABNativeDiagnostics.m 'category37EntryClass'
require_text YTABNativeDiagnostics.m 'originalCompletion(result);'
require_text YTABNativeDiagnostics.m 'originalFailure(error);'
require_text YTABCNativeMenus.m 'Eligibility / request diagnosis'
require_text YTABCNativeMenus.m 'showEligibilityHealth'
require_text YTABCNativeMenus.m 'YTABCRunPhenotypeResync()'
require_text YTABCNativeMenus.m 'YTABCClearNativeExperimentsCaches()'
require_text YTABNativeDiagnostics.m 'method_getTypeEncoding(method)'
require_text YTABNativeDiagnostics.m 'v40@0:8@16@24@?32'
require_text YTABNativeDiagnostics.m 'v40@0:8@16@?24@?32'
require_text YTABNativeDiagnostics.m 'v24@0:8@?16'
require_text Settings.x 'YTABCTracePhenotype'
require_text Settings.x 'YTABCTraceExperimentsSearch'
require_text Settings.x 'YTABCTraceExperimentsOptIn'
require_text Settings.x 'YTABCTraceExperimentsOptOut'
require_text Settings.x 'YTABCRunPhenotypeResync();'
require_text Settings.x 'YTABCClearNativeExperimentsCaches();'
require_text Settings.x 'YTABCCopyNativeDiagnostics()'

# No unimplemented hooks, missing linker symbols or false toggles are shipped.
for symbol in \
  YTABCInstallEmployeeExperimentHooks \
  YTABCBypassIdentitySearch; do
  reject_text Tweak.x "$symbol"
  reject_text Settings.x "$symbol"
done
reject_text Makefile 'YTInternalIdentity.x'
# Validate each local-only selector and its independent setting.
require_text YTABNativeDiagnostics.m '@"isGooglerAccount:"'
require_text YTABNativeDiagnostics.m '"B24@0:8@16"'
require_text YTABNativeDiagnostics.m '@"YTABCForceIsGooglerAccount"'
require_text YTABNativeDiagnostics.m '@"YTABCForceHasGooglerAccount"'
require_text YTABNativeDiagnostics.m '@"YTABCForceStandardInternalSyncer"'
require_text YTABNativeDiagnostics.m 'return forced ? YES : nativeValue;'
require_text Settings.x '@"YTABCForceIsGooglerAccount"'
require_text Settings.x '@"YTABCForceHasGooglerAccount"'
require_text Settings.x '@"YTABCForceStandardInternalSyncer"'
reject_text Settings.x '@"YTABCBypassIdentitySearch"'
require_text Settings.x '@"YTABCTracePhenotype"'

# The native-menu observer must never depend on an inline Mach-O text patch.
reject_text YTABCNativeMenus.m "MSHookFunction"
reject_text YTABCNativeMenus.m "YTABCForceIsGooglerAccount"
echo "native experiments and menu static checks passed"
