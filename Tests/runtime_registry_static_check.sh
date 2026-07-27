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

# Preserve the launch path proven by PoomSmart 1.9.2: enumerate exact BOOL
# getters, capture each native value, cache it, and install one cache-backed
# hook before the original app delegate implementation.
require_text Tweak.x "static NSMutableArray<NSString *> *getBooleanMethods"
require_text Tweak.x 'strcmp(encoding, "B16@0:8") != 0'
require_text Tweak.x "static void hookClass(NSObject *instance)"
require_text Tweak.x "BOOL nativeValue = getValueFromInvocation(instance, selector);"
require_text Tweak.x "classCache[method] = @(nativeValue);"
require_text Tweak.x "MSHookMessageEx("
require_text Tweak.x "YTABCRuntimeRegisterOriginalImplementation("
require_text Tweak.x "hookClass(globalConfig);"
require_text Tweak.x "hookClass(coldConfig);"
require_text Tweak.x "hookClass(hotConfig);"
require_text Tweak.x "if (!groupedSettings()) SearchHook();"
require_text Tweak.x "return %orig;"
reject_text Tweak.x "dispatch_async(dispatch_get_main_queue()"
reject_text Tweak.x "post-original"
reject_text Tweak.x "bounded-retry"
reject_text Tweak.x "YTABCRuntimeDiscoverFlags"

# Feature Lab is a bridge over that one hook/cache. It must never install a
# second hook set or observe defaults globally during YouTube startup.
require_text RuntimeFlagRegistry.h "YTABCRuntimeRegisterOriginalImplementation"
require_text RuntimeFlagRegistry.h "YTABCRuntimeValuesSnapshot"
require_text RuntimeFlagRegistry.h "YTABCRuntimeRefreshAllNativeValues"
require_text RuntimeFlagRegistry.m "YTABCRuntimeOriginalImplementations"
require_text RuntimeFlagRegistry.m "YTABCRuntimeDiscoverFlags"
require_text RuntimeFlagRegistry.m "YTABCRuntimeApplyPersistedOverrides"
require_text RuntimeFlagRegistry.m "YTABCNativeRefreshBatchSize"
require_text RuntimeFlagRegistry.m "originalImplementation"
require_text RuntimeFlagRegistry.m "nativeCapturedAt"
reject_text RuntimeFlagRegistry.m "MSHookMessageEx"
reject_text RuntimeFlagRegistry.m "class_copyMethodList"
reject_text RuntimeFlagRegistry.m "NSUserDefaultsDidChangeNotification"
reject_text RuntimeFlagRegistry.m "addObserverForName:"
reject_text RuntimeFlagRegistry.m "removeObserver:"

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
require_text Settings.x "YTABCRuntimeRegistryStart(defaults);"
require_text Settings.x "dispatch_once(&searchHookOnceToken"
require_text Settings.x "pthread_mutex_t cacheMutex;"
require_text Settings.x "BOOL allKeysNeedsUpdate = YES;"
require_text Settings.x "BOOL getValue(NSString *methodKey)"
require_text Settings.x "void updateAllKeys(void)"
require_text Settings.x "pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);"
reject_text Settings.x "[defaults setBool:YES forKey:EnabledKey]"
reject_text Settings.x "if (NO && tweakEnabled())"
reject_text Settings.x "importRegex"
reject_text Settings.x "categoryCache"
reject_text Settings.x "titleSortDescriptor"
reject_text Settings.x "UIApplicationDidReceiveMemoryWarningNotification"

orig_count="$(grep -Ec '(^|[^[:alnum:]_])%orig([^[:alnum:]_]|$)' Tweak.x)"
if [[ "$orig_count" -ne 1 ]]; then
    echo "expected exactly one %orig in Tweak.x, found $orig_count" >&2
    exit 1
fi

hook_count="$(grep -Fc 'MSHookMessageEx(' Tweak.x)"
if [[ "$hook_count" -ne 1 ]]; then
    echo "expected one PoomSmart-compatible hook call site, found $hook_count" >&2
    exit 1
fi

native_line="$(grep -nF 'BOOL nativeValue = getValueFromInvocation(instance, selector);' Tweak.x | cut -d: -f1)"
cache_line="$(grep -nF 'classCache[method] = @(nativeValue);' Tweak.x | cut -d: -f1)"
hook_line="$(grep -nF 'MSHookMessageEx(' Tweak.x | cut -d: -f1)"
capture_line="$(grep -nF 'YTABCRuntimeRegisterOriginalImplementation(' Tweak.x | cut -d: -f1)"
if [[ -z "$native_line" || -z "$cache_line" || -z "$hook_line" || -z "$capture_line" ||
      "$native_line" -ge "$cache_line" || "$cache_line" -ge "$hook_line" ||
      "$hook_line" -ge "$capture_line" ]]; then
    echo "native capture, cache, hook, and bridge registration order drifted" >&2
    exit 1
fi

global_line="$(grep -nF 'hookClass(globalConfig);' Tweak.x | cut -d: -f1)"
hot_line="$(grep -nF 'hookClass(hotConfig);' Tweak.x | cut -d: -f1)"
search_line="$(grep -nF 'if (!groupedSettings()) SearchHook();' Tweak.x | cut -d: -f1)"
orig_line="$(grep -nF 'return %orig;' Tweak.x | cut -d: -f1)"
if [[ -z "$global_line" || -z "$hot_line" || -z "$search_line" || -z "$orig_line" ||
      "$global_line" -ge "$hot_line" || "$hot_line" -ge "$search_line" ||
      "$search_line" -ge "$orig_line" ]]; then
    echo "PoomSmart-compatible launch ordering drifted" >&2
    exit 1
fi

echo "runtime registry static checks passed"
