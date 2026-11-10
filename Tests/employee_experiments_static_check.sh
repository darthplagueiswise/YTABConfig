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
require_text Makefile "YTNativeExperiments.x YTABCNativeMenus.m YTABNativeDiagnostics.m"
require_text Settings.x "YTABCPushNativeExperiments(settingsViewController)"
require_text Settings.x "YTABCPresentNativeExperiments(settingsViewController)"
require_text Settings.x "YTABCPushNativeMenuHub(settingsViewController)"
require_text Settings.x '@"YTABC_NATIVE_TOOLS_OPEN"'
require_text YTNativeExperiments.x 'initWithParentResponder:'
require_text YTABCNativeMenus.m 'YTSettingsExperimentsViewController'
require_text YTABCNativeMenus.m 'YTSettingsExperimentsResultsViewController'
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
