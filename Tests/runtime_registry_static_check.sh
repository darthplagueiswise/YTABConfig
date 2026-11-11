#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
    local file="$1"
    local text="$2"
    if ! grep -Fq -e "$text" "$file"; then
        echo "missing '$text' in $file" >&2
        exit 1
    fi
}

reject_text() {
    local file="$1"
    local text="$2"
    if grep -Fq -e "$text" "$file"; then
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
require_text Makefile "YTABRuntimeBrowser.m YTABRuntimeBrowserModern.m YTABRuntimeBrowserHooks.x YTABRuntimeBrowserEntry.x"
require_text YTABRuntimeBrowserEntry.x '#import "YTABRuntimeBrowserModern.h"'
require_text YTABRuntimeBrowserEntry.x "Open Runtime Patch Browser"
require_text YTABRuntimeBrowserEntry.x "YTABRuntimeBrowserModernViewController"
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
require_text YTABRuntimeBrowser.m "class_copyMethodList(owner, &count)"
require_text YTABRuntimeBrowser.m "imp_implementationWithBlock"
require_text YTABRuntimeBrowser.m "MSHookMessageEx(hookClass, selector, replacement, &original);"
require_text YTABRuntimeBrowser.m "YTABCRuntimeBrowserOverrides"
require_text YTABRuntimeBrowser.m "YTABRuntimeArgumentKindObject"
require_text YTABRuntimeBrowser.m "YTABRuntimeArgumentKindInteger"
# All captured config flags and compatible native BOOLs share one UI collection.
require_text YTABRuntimeBrowser.m "YTABRuntimeImageScopeFlags"
require_text YTABRuntimeBrowser.m "YTABRuntimeImageScopeMethods"
require_text YTABRuntimeBrowser.m "YTABRuntimeImageScopeOverrides"
require_text YTABRuntimeBrowser.m '@"All BOOLs", @"Overrides"'
reject_text YTABRuntimeBrowser.m '@"Flags", @"Methods", @"Overrides"'
require_text YTABRuntimeBrowser.m 'YTABRuntimeImageScopeAll'
require_text YTABRuntimeBrowser.m 'YTABRuntimeImageScopeAll : YTABRuntimeImageScopeOverrides'
require_text YTABRuntimeBrowser.m "YTABCRuntimeValuesSnapshot()"
require_text YTABRuntimeBrowser.m "YTABCNativeValue(cls, selector)"
require_text YTABRuntimeBrowser.m "YTABCOverrideValue(cls, selector)"
require_text YTABRuntimeBrowser.m "YTABCSetOverride(cls, selector, mode == 2)"
require_text YTABRuntimeBrowser.m "YTABCClearOverride(cls, selector)"
require_text YTABRuntimeBrowser.m "YTABRuntimeBrowserOverrideValue(NSString *patchKey)"
require_text YTABRuntimeBrowser.m "YTABRuntimeIsMainExecutableClass(cls)"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserOverrideValue(patchKey)"
require_text YTABRuntimeBrowserModern.m "captured at launch"
reject_text YTABRuntimeBrowser.m '@"YouTube", @"Frameworks", @"All"'
reject_text YTABRuntimeBrowser.m "[imageName hasPrefix:frameworksRoot]"
require_text YTABRuntimeBrowser.m '@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"'
require_text YTABRuntimeBrowserHooks.x "YTABRuntimeBrowserReinstallPersistedHooks();"
reject_text YTABRuntimeBrowser.m "MSHookFunction"
reject_text YTABRuntimeBrowser.m "_dyld_register_func_for_add_image"
reject_text YTABRuntimeBrowserHooks.x "objc_copyClassList"
reject_text YTABRuntimeBrowserHooks.x "class_copyMethodList"
reject_text YTABRuntimeBrowserHooks.x "MSHookMessageEx"

# The visible browser must remain readable and use standard UIKit surfaces:
# inline title, stacked top search, multiline labels, and direct tri-state
# controls in every row. Patching must not be hidden in an action sheet.
require_text YTABRuntimeBrowserModern.m "UINavigationItemLargeTitleDisplayModeNever"
# Keep a native UISearchBar pinned in a plain table section header.
# The old search in YouTube's navigation container vanished on scrolling.
require_text YTABRuntimeBrowserModern.m "UITableViewStyleInsetGrouped"
require_text YTABRuntimeBrowserModern.m "viewForHeaderInSection:"
# The visible pinned UISearchBar must be independent of UISearchController
# and supply the actual query to the engine.
require_text YTABRuntimeBrowser.m "- (NSString *)ytab_currentSearchText"
require_text YTABRuntimeBrowser.m "YTABRuntimeSearchTokens([self ytab_currentSearchText])"
require_text YTABRuntimeBrowserModern.m 'UISearchBar *search = [[UISearchBar alloc] initWithFrame:CGRectZero]'
# Native iOS 26/27 IntegratedButton morphs in the navigation bar. Disallow
# toolbar integration to avoid overlapping the final rows inside YouTube's
# custom Settings navigation container.
require_text YTABRuntimeBrowser.m "- (UISearchController *)ytab_ownedSearchController"
require_text YTABRuntimeBrowserModern.m "UINavigationItemSearchBarPlacementIntegrated"
require_text YTABRuntimeBrowserModern.m "searchBarPlacementAllowsToolbarIntegration = NO"
reject_text YTABRuntimeBrowserModern.m "searchBarPlacementBarButtonItem"
require_text YTABRuntimeBrowserModern.m "self.navigationItem.searchController = nativeSearch;"
require_text YTABRuntimeBrowserModern.m "self.toolbarItems = nil;"
reject_text YTABRuntimeBrowserModern.m "setToolbarHidden:NO"
require_text YTABRuntimeBrowserModern.m '(self.pinnedSearchBar.text ?: @"")'
require_text YTABRuntimeBrowserModern.m '[self applyFilter];'
reject_text YTABRuntimeBrowserModern.m "self.navigationItem.searchController.searchBar"
reject_text YTABRuntimeBrowserModern.m "[search removeFromSuperview]"
require_text YTABRuntimeBrowserModern.m "searchBar:(UISearchBar *)searchBar textDidChange:"
require_text YTABRuntimeBrowserModern.m "self.tableView.tableHeaderView = nil;"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserNativeSample"
# The UI must not turn a missing native sample into a fake System OFF state.
require_text YTABRuntimeBrowserModern.m "cell.overrideSwitch.hidden = !effectiveKnown;"
require_text YTABRuntimeBrowserModern.m "cell.unknownLabel.hidden = effectiveKnown;"
require_text YTABRuntimeBrowserModern.m "[valueSlot addSubview:_overrideSwitch]"
require_text YTABRuntimeBrowserModern.m "[valueSlot addSubview:_unknownLabel]"
reject_text YTABRuntimeBrowserModern.m "_unknownLabel.widthAnchor constraintEqualToConstant:49"
require_text YTABRuntimeBrowserModern.m "UIColor.systemGreenColor"
require_text YTABRuntimeBrowserModern.m "UIColor.systemBlueColor"
require_text YTABRuntimeBrowserModern.m "mode == YTABModernPatchModeSystem"
require_text YTABRuntimeBrowserModern.m "contextMenuConfigurationForRowAtIndexPath:"
require_text YTABRuntimeBrowserModern.m "contextMenuInteraction:(UIContextMenuInteraction *)interaction"
require_text YTABRuntimeBrowserModern.m "Remove override (System)"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserObserveKey(capturedKey)"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeNativeSampleChangedNotification"
require_text YTABRuntimeBrowser.m "if (!previous || previous.boolValue != value)"
require_text YTABRuntimeBrowser.m "postNotificationName:YTABRuntimeNativeSampleChangedNotification"
require_text YTABRuntimeBrowser.m "BOOL YTABRuntimeBrowserObserveKey"
reject_text YTABRuntimeBrowserModern.m "cell.overrideSwitch setOn:effectiveBool"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserPatchInstalled"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserApplyMode"
require_text YTABRuntimeBrowser.m "if (value && !YTABRuntimeInstallPatchKey(key)) return NO;"
require_text YTABRuntimeBrowser.m "BOOL YTABRuntimeBrowserApplyMode"
require_text YTABRuntimeBrowserModern.m "Patch unavailable"
require_text YTABRuntimeBrowserModern.m "Effective %@"
require_text YTABRuntimeBrowserModern.m "UITableViewAutomaticDimension"
require_text YTABRuntimeBrowserModern.m "NSLineBreakByTruncatingMiddle"
require_text YTABRuntimeBrowserModern.m "glassButtonConfiguration"
require_text YTABRuntimeBrowserModern.m "UIButtonConfiguration"
require_text YTABRuntimeBrowserModern.m "UISwitch *overrideSwitch"
require_text YTABRuntimeBrowserModern.m "overrideSwitchChanged:"
require_text YTABRuntimeBrowserModern.m "ytab_modeMenuForKey:"
require_text YTABRuntimeBrowserModern.m 'NSArray<NSString *> *titles = @[@"System", @"Force OFF", @"Force ON"]'
require_text YTABRuntimeBrowserModern.m "UIFontTextStyleBody"
require_text YTABRuntimeBrowserModern.m "UIFontTextStyleCaption2"
reject_text YTABRuntimeBrowserModern.m "monospacedSystemFontOfSize:15.0"
require_text YTABRuntimeBrowserModern.m "YTABRuntimeBrowserReinstallPersistedHooks();"
# The footer must not sit under the native bottom search bar on iOS 26/27.
require_text YTABRuntimeBrowserModern.m "Explanations belong in detail views"
require_text YTABRuntimeBrowserModern.m "UINavigationItemSearchBarPlacementIntegratedButton"
require_text YTABRuntimeBrowser.m "objc_copyClassNamesForImage"
require_text YTABRuntimeBrowser.m "sYTABRuntimeMethodCatalog = generic.copy"
require_text YTABRuntimeBrowser.m '"partialMethods": snapshot'
require_text YTABRuntimeBrowser.m 'if (override) return override.boolValue;'
override_short_circuits="$(grep -Fc 'if (override) return override.boolValue;' YTABRuntimeBrowser.m)"
if [[ "$override_short_circuits" -ne 3 ]]; then
    echo "all three generic BOOL hook signatures must short-circuit local overrides" >&2
    exit 1
fi
require_text YTABRuntimeBrowser.m "YTABRuntimeInventoryQueue()"
reject_text YTABRuntimeBrowserModern.m "UIAlertControllerStyleActionSheet"

browser_retry_count="$(grep -Fc 'YTABRuntimeBrowserReinstallPersistedHooks();' YTABRuntimeBrowserHooks.x)"
if [[ "$browser_retry_count" -ne 2 ]]; then
    echo "expected persisted restore plus one bounded retry, found $browser_retry_count" >&2
    exit 1
fi

echo "runtime registry static checks passed"
