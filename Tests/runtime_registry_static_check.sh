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

require_text Settings.x '#import "RuntimeFlagRegistry.h"'
require_text Settings.x "YTABCSetOverride"
require_text Settings.x "YTABCClearOverride"
require_text Settings.x "BOOL YTABSetRuntimeOverride"
require_text Settings.x "BOOL YTABResetRuntimeOverride"
require_text Settings.x "YTABCValidOverrideNumber"
require_text Settings.x "NSDictionary *representation = [defaults dictionaryRepresentation]"
require_text Settings.x "[defaults objectForKey:fullKey]"
reject_text Settings.x "[cache setValue:@(value)"
reject_text Settings.x "cache[sourceClass][selector] = @(nativeValue)"
reject_text Settings.x "cache[classKey][selector] = value"

echo "runtime registry static checks passed"
