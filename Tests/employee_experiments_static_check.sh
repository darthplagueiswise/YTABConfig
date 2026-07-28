#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
    local file="$1"
    local text="$2"
    if ! grep -Fq "$text" "$file"; then
        echo "missing '$text' in $file" >&2
        exit 1
    fi
}

reject_text() {
    local file="$1"
    local text="$2"
    if grep -Fq "$text" "$file"; then
        echo "unexpected '$text' in $file" >&2
        exit 1
    fi
}

# Hook timing: install one verified Objective-C hook set before the original
# app delegate work. Hooks remain installed and consult independent keys live.
require_text Tweak.x "YTABCInstallEmployeeExperimentHooks();"
require_text Tweak.x "return %orig;"
require_text YTInternalIdentity.x 'objc_lookUpClass("PHTHeterodyneSyncer")'
require_text YTInternalIdentity.x 'MSHookMessageEx(cls, selector, replacement, original);'
require_text YTInternalIdentity.x 'static BOOL YTABCTestEnabled(NSString *key)'
reject_text YTInternalIdentity.x '_dyld_register_func_for_add_image'
reject_text YTInternalIdentity.x 'MSHookFunction'

# Exact YouTube 21.30.5 Objective-C ABI contracts proved from the executable.
for contract in \
    '"B24@0:8@16"' \
    '"B16@0:8"' \
    '"@16@0:8"' \
    '"@28@0:8@16i24"' \
    '"v40@0:8@16@24@?32"' \
    '"@52@0:8@16q24i32B36@40B48"' \
    '"@64@0:8@16@24B32@36@?44@?52B60"' \
    '"v40@0:8@16@24@32"' \
    '"v60@0:8@16@24B32@36Q44@52"'; do
    require_text YTInternalIdentity.x "$contract"
done

# Each hypothesis has its own persisted switch. The old all-in-one identity
# key must not silently enable unrelated behavior.
for key in \
    YTABCForceIsGooglerAccount \
    YTABCForceHasGooglerAccount \
    YTABCForceMaybeGooglerClientProperty \
    YTABCForceStandardInternalSyncer \
    YTABCTracePhenotype \
    YTABCAutoPhenotypeResync \
    YTABCTraceExperimentsSearch \
    YTABCTraceExperimentsOptIn \
    YTABCTraceExperimentsOptOut \
    YTABCBypassIdentitySearch \
    YTABCBypassIdentityOptIn \
    YTABCBypassIdentityOptOut; do
    require_text YTInternalIdentity.x "@\"${key}\""
    require_text Settings.x "@\"${key}\""
done
reject_text YTInternalIdentity.x '@"YTABCInternalIdentity"'
reject_text Settings.x '@"YTABCInternalIdentity"'

# Resync must reuse the native PHTHeterodyneSyncerProtocol object captured from
# YouTube's own sync path; never instantiate a fake/internal syncer.
require_text YTInternalIdentity.x "YTABCCapturePhenotypeSyncer(syncer);"
require_text YTInternalIdentity.x 'syncExperimentsWithServer:callback:'
require_text YTInternalIdentity.x "YTABCLastPhenotypeSyncer"
reject_text YTInternalIdentity.x 'alloc] initWithOverrideServerURL:'
reject_text YTInternalIdentity.x 'objc_lookUpClass("PHTInternalHeterodyneSyncer")'

# InnerTube identity bypasses are request-scoped to services 49/50/51, never a
# global requestor disableActiveIdentityChecks call.
require_text YTInternalIdentity.x "YTABCExperimentsOptInService = 49"
require_text YTInternalIdentity.x "YTABCExperimentsOptOutService = 50"
require_text YTInternalIdentity.x "YTABCExperimentsSearchService = 51"
require_text YTInternalIdentity.x "objc_setAssociatedObject(request"
require_text YTInternalIdentity.x "effectiveVerify = NO;"
reject_text YTInternalIdentity.x "disableActiveIdentityChecks"

# Native service cache action must target an observed YTExperimentsServiceImpl,
# not construct a parallel service or account identity.
require_text YTInternalIdentity.x "YTABCCaptureExperimentsService(self);"
require_text YTInternalIdentity.x "YTABCClearNativeExperimentsCaches"
require_text Settings.x "Run Phenotype resync now"
require_text Settings.x "Clear native experiments caches"

echo "employee experiments static checks passed"
