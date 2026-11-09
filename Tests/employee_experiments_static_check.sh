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
require_text Makefile "YTNativeExperiments.x YTABCNativeMenus.m"
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

# No unimplemented hooks, missing linker symbols or false toggles are shipped.
for symbol in \
  YTABCInstallEmployeeExperimentHooks \
  YTABCRunPhenotypeResync \
  YTABCClearNativeExperimentsCaches; do
  reject_text Tweak.x "$symbol"
  reject_text Settings.x "$symbol"
done
reject_text Makefile 'YTInternalIdentity.x'
reject_text Settings.x '@"YTABCForceIsGooglerAccount"'
reject_text Settings.x '@"YTABCBypassIdentitySearch"'
reject_text Settings.x '@"YTABCTracePhenotype"'

# The native-menu observer must never depend on an inline Mach-O text patch.
reject_text YTABCNativeMenus.m "MSHookFunction"
reject_text YTABCNativeMenus.m "YTABCForceIsGooglerAccount"
echo "native experiments and menu static checks passed"
