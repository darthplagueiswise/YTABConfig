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
require_text RuntimeFlagRegistry.m "YTABCRecordsBySelector[selectorName]"
require_text RuntimeFlagRegistry.m "YTABCRuntimeDiscoverFlags"
require_text RuntimeFlagRegistry.m "YTABCRuntimeApplyPersistedOverrides"
require_text RuntimeFlagRegistry.m "YTABCNativeRefreshBatchSize"
require_text RuntimeFlagRegistry.m "YTABCDefaultsSnapshot"
require_text RuntimeFlagRegistry.m "removeObserver:observerToRemove"
require_text RuntimeFlagRegistry.h "FOUNDATION_EXPORT BOOL YTABCRuntimeRegisterConfigInstance"
require_text RuntimeFlagRegistry.h "YTABCRuntimeValuesSnapshot"
require_text RuntimeFlagRegistry.h "YTABCRuntimeRefreshAllNativeValues"
require_text RuntimeFlagRegistry.m "nativeCapturedAt"
require_text RuntimeFlagRegistry.m "hasNativeValue"

require_text Settings.x '#import "RuntimeFlagRegistry.h"'
require_text Settings.x "YTABCRuntimeDiscoverFlags"
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
require_text Tweak.x "YTABCRegistrationResult registration = { 0 }"
require_text Tweak.x "registration.availableConfigCount < 3"
require_text Tweak.x "without sampling getters"
require_text Tweak.x "post-original"
require_text Tweak.x "bounded-retry"
reject_text Tweak.x "discoveredFlagCount"
reject_text Tweak.x "YouTube 21.28.3"
reject_text Tweak.x "YTABCRuntimeDiscoverFlags"

conflict_body="$(sed -n '/^static BOOL YTABCRecordConflictsWithOwnerHierarchy/,/^}/p' RuntimeFlagRegistry.m)"
if grep -Fq "YTABCRecords.allValues" <<<"$conflict_body"; then
    echo "hierarchy conflict lookup must not scan every registered flag" >&2
    exit 1
fi

registration_count="$(grep -Fc 'YTABCRegisterAvailableConfigs(self,' Tweak.x)"
if [[ "$registration_count" -ne 2 ]]; then
    echo "expected pre/post instance refresh registration, found $registration_count call sites" >&2
    exit 1
fi

register_body="$(sed -n '/^BOOL YTABCRuntimeRegisterConfigInstance/,/^}/p' RuntimeFlagRegistry.m)"
if grep -Fq "YTABCInvokeBOOL" <<<"$register_body"; then
    echo "launch-time config registration must not invoke native getters" >&2
    exit 1
fi

discover_body="$(sed -n '/^NSUInteger YTABCRuntimeDiscoverFlags/,/^}/p' RuntimeFlagRegistry.m)"
if grep -Fq "YTABCInvokeBOOL" <<<"$discover_body"; then
    echo "live flag discovery must enumerate metadata without invoking getters" >&2
    exit 1
fi

hook_body="$(sed -n '/^static BOOL YTABCRuntimeHook/,/^}/p' RuntimeFlagRegistry.m)"
if grep -Fq "objectForKey" <<<"$hook_body"; then
    echo "hot getter hooks must use reconciled in-memory override state" >&2
    exit 1
fi

orig_count="$(grep -Ec '(^|[^[:alnum:]_])%orig([^[:alnum:]_]|$)' Tweak.x)"
if [[ "$orig_count" -ne 1 ]]; then
    echo "expected exactly one %orig in Tweak.x, found $orig_count" >&2
    exit 1
fi

echo "runtime registry static checks passed"
