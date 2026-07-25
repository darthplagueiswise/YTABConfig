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

require_text RuntimeFlagRegistry.m "YTABCCanonicalConfigOwnerClass"
require_text RuntimeFlagRegistry.m "YTABCRecordConflictsWithOwnerHierarchy"
require_text RuntimeFlagRegistry.m "YTABCRefreshRecordNativeSample"
require_text RuntimeFlagRegistry.m "YTABCDefaultsSnapshot"
require_text RuntimeFlagRegistry.m "removeObserver:observerToRemove"
require_text RuntimeFlagRegistry.h "FOUNDATION_EXPORT NSUInteger YTABCRuntimeRegisterConfigInstance"
require_text RuntimeFlagRegistry.m "nativeCapturedAt"

require_text Settings.x '#import "RuntimeFlagRegistry.h"'
require_text Settings.x "YTABCSetOverride"
require_text Settings.x "YTABCClearOverride"
require_text Settings.x "BOOL YTABSetRuntimeOverride"
require_text Settings.x "BOOL YTABResetRuntimeOverride"
require_text Settings.x "YTABCValidOverrideNumber"
require_text Settings.x "NSDictionary *representation = [defaults dictionaryRepresentation]"
require_text Settings.x "[defaults objectForKey:fullKey]"
require_text Settings.x '[defaults registerDefaults:@{EnabledKey: @YES}]'
require_text Settings.x "dispatch_once(&searchHookOnceToken"
reject_text Settings.x "[defaults setBool:YES forKey:EnabledKey]"
reject_text Settings.x "[cache setValue:@(value)"
reject_text Settings.x "cache[sourceClass][selector] = @(nativeValue)"
reject_text Settings.x "cache[classKey][selector] = value"
reject_text Settings.x "if (NO && tweakEnabled())"
reject_text Settings.x "importRegex"
reject_text Settings.x "categoryCache"
reject_text Settings.x "titleSortDescriptor"
reject_text Settings.x "UIApplicationDidReceiveMemoryWarningNotification"

require_text Tweak.x "YTABCRegisterAvailableConfigs"
require_text Tweak.x "YTABCScheduleBoundedRegistrationRetry"
require_text Tweak.x "post-original"
require_text Tweak.x "bounded-retry"
orig_count="$(grep -Ec '(^|[^[:alnum:]_])%orig([^[:alnum:]_]|$)' Tweak.x)"
if [[ "$orig_count" -ne 1 ]]; then
    echo "expected exactly one %orig in Tweak.x, found $orig_count" >&2
    exit 1
fi

echo "runtime registry static checks passed"
