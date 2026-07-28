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
require_text Tweak.x "MSHookMessageEx(instanceClass, selector, (IMP)returnFunction, NULL);"
require_text Tweak.x "hookClass(globalConfig);"
require_text Tweak.x "hookClass(coldConfig);"
require_text Tweak.x "hookClass(hotConfig);"
require_text Tweak.x "if (!groupedSettings()) SearchHook();"
require_text Tweak.x "return %orig;"
reject_text Tweak.x "dispatch_async(dispatch_get_main_queue()"
reject_text Tweak.x "post-original"
reject_text Tweak.x "bounded-retry"
reject_text Tweak.x "YTABCRuntimeDiscoverFlags"
reject_text Tweak.x "originalImplementation"
reject_text Tweak.x "YTABCRuntimeRegisterConfigInstance"
reject_text Tweak.x "YTABCRuntimeRegisterOriginalImplementation"

# Feature Lab is a bridge over that one hook/cache. It must never install a
# second hook set, retain original IMPs, or observe defaults globally.
require_text RuntimeFlagRegistry.h "YTABCRuntimeValuesSnapshot"
require_text RuntimeFlagRegistry.m "YTABCRuntimeDiscoverFlags"
require_text RuntimeFlagRegistry.m "YTABCRuntimeApplyPersistedOverrides"
require_text RuntimeFlagRegistry.m "nativeCapturedAt"
reject_text RuntimeFlagRegistry.m "MSHookMessageEx"
reject_text RuntimeFlagRegistry.m "class_copyMethodList"
reject_text RuntimeFlagRegistry.m "NSMapTable"
reject_text RuntimeFlagRegistry.m "NSValue"
reject_text RuntimeFlagRegistry.m "originalImplementation"
reject_text RuntimeFlagRegistry.m "YTABCRuntimeRegisterConfigInstance"
reject_text RuntimeFlagRegistry.m "YTABCRuntimeRegisterOriginalImplementation"
reject_text RuntimeFlagRegistry.m "YTABCRuntimeRefreshAllNativeValues"
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
require_text Settings.x "YTABCRuntimeRegistryStart(defaults);"
require_text Settings.x "dispatch_once(&searchHookOnceToken"
require_text Settings.x "pthread_mutex_t cacheMutex;"
require_text Settings.x "NSMutableDictionary<NSString *, NSString *> *keyCache;"
require_text Settings.x "NSUInteger prefixLength;"
require_text Settings.x "keyCache[cacheKey]"
require_text Settings.x "[cache valueForKeyPath:keyPath]"
require_text Settings.x "BOOL allKeysNeedsUpdate = YES;"
require_text Settings.x "BOOL getValue(NSString *methodKey)"
require_text Settings.x "void updateAllKeys(void)"
require_text Settings.x "pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);"
reject_text Settings.x "[defaults setBool:YES forKey:EnabledKey]"
reject_text Settings.x "registerDefaults:"
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
if [[ -z "$native_line" || -z "$cache_line" || -z "$hook_line" ||
      "$native_line" -ge "$cache_line" || "$cache_line" -ge "$hook_line" ]]; then
    echo "native capture, cache, and hook order drifted" >&2
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


# RyukGram-style runtime patch browser. Full class/method discovery is on demand;
# launch restores only explicitly persisted Class#selector keys.
require_text Makefile "YTABRuntimeBrowser.m YTABRuntimeBrowserHooks.x YTABRuntimeBrowserEntry.x"
require_text YTABRuntimeBrowserEntry.x '#import "YTABRuntimeBrowser.h"'
require_text YTABRuntimeBrowserEntry.x "Open Runtime Patch Browser"
require_text YTABRuntimeBrowserEntry.x "YTABRuntimeBrowserPersistedOverrideCount()"
require_text YTABRuntimeBrowserEntry.x "YTABCFeatureLabCategory = 404"
require_text YTABRuntimeBrowserEntry.x '@"YTABC_FEATURE_LAB"'
require_text YTABRuntimeBrowserEntry.x "YTABItemsByAddingRuntimeBrowser"
require_text YTABRuntimeBrowserEntry.x "YTABInstallFeatureLabDelegateHookIfNeeded(dataDelegate);"
reject_text YTABRuntimeBrowserEntry.x "YTABRuntimeBrowserCategory = 405"
reject_text YTABRuntimeBrowserEntry.x "orderedCategories"
reject_text YTABRuntimeBrowserEntry.x "settingsCategoryOrder"
require_text YTABRuntimeBrowser.m "objc_copyClassList(&classCount)"
require_text YTABRuntimeBrowser.m "class_getImageName(cls)"
require_text YTABRuntimeBrowser.m "class_copyMethodList(owner, &methodCount)"
require_text YTABRuntimeBrowser.m "imp_implementationWithBlock"
require_text YTABRuntimeBrowser.m "MSHookMessageEx(hookClass, selector, replacement, &original);"
require_text YTABRuntimeBrowser.m "YTABCRuntimeBrowserOverrides"
require_text YTABRuntimeBrowser.m "YTABRuntimeArgumentKindObject"
require_text YTABRuntimeBrowser.m "YTABRuntimeArgumentKindInteger"
require_text YTABRuntimeBrowser.m "YTABRuntimeImageScopeYouTube"
require_text YTABRuntimeBrowser.m "YTABRuntimeImageScopeModule"
require_text YTABRuntimeBrowser.m "Force OFF"
require_text YTABRuntimeBrowser.m "Force ON"
require_text YTABRuntimeBrowser.m '@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"'
require_text YTABRuntimeBrowserHooks.x "YTABRuntimeBrowserReinstallPersistedHooks();"
reject_text YTABRuntimeBrowser.m "MSHookFunction"
reject_text YTABRuntimeBrowser.m "_dyld_register_func_for_add_image"
reject_text YTABRuntimeBrowserHooks.x "objc_copyClassList"
reject_text YTABRuntimeBrowserHooks.x "class_copyMethodList"
reject_text YTABRuntimeBrowserHooks.x "MSHookMessageEx"

browser_retry_count="$(grep -Fc 'YTABRuntimeBrowserReinstallPersistedHooks();' YTABRuntimeBrowserHooks.x)"
if [[ "$browser_retry_count" -ne 2 ]]; then
    echo "expected persisted restore plus one bounded retry, found $browser_retry_count" >&2
    exit 1
fi

echo "runtime registry static checks passed"
