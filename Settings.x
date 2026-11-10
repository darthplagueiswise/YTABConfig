#import <PSHeader/Misc.h>
#import <YouTubeHeader/YTAlertView.h>
#import <YouTubeHeader/YTSearchableSettingsViewController.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTUIUtils.h>
#import <YouTubeHeader/YTVersionUtils.h>
#import <pthread.h>
#import "RuntimeFlagRegistry.h"
#import "YTABCatalogProvider.h"
#import "YTABLabUI.h"
#import "YTABCNativeMenus.h"
extern void YTABCInstallNativeDiagnostics(void);
extern BOOL YTABCRunPhenotypeResync(void);
extern BOOL YTABCClearNativeExperimentsCaches(void);
extern NSDictionary<NSString *, id> *YTABCCopyNativeDiagnostics(void);

#define Prefix @"YTABC"
#define EnabledKey @"EnabledYTABC"
#define GroupedKey @"GroupedYTABC"

#define _LOC(b, x) [b localizedStringForKey:x value:nil table:nil]
#define LOC(x) _LOC(tweakBundle, x)

static const NSInteger YTABCSection = 404;
static NSString * const KeyFormatString = @"%@.%@";
static NSString * const FullKeyFormatString = @"%@.%@.%@";

@interface YTSettingsSectionItemManager (YTABConfig)
- (void)updateYTABCSectionWithEntry:(id)entry;
@end

NSUserDefaults *defaults;
extern NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;
extern BOOL YTABCPushNativeExperiments(id settingsViewController);
extern BOOL YTABCPresentNativeExperiments(id settingsViewController);
NSSet<NSString *> *allKeysSet;
BOOL allKeysNeedsUpdate = YES;
pthread_mutex_t cacheMutex;
NSMutableDictionary<NSString *, NSString *> *keyCache;
NSUInteger prefixLength;

static YTSettingsSectionItem *YTABCDiagnosticsSwitch(
    Class itemClass, NSString *title, NSString *detail, NSString *identifier, NSString *defaultsKey
) {
    return [(id)itemClass switchItemWithTitle:title
        titleDescription:detail
        accessibilityIdentifier:identifier
        switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:defaultsKey]
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            (void)cell;
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:defaultsKey];
            YTABCInstallNativeDiagnostics();
            return YES;
        }
        settingItemId:0];
}

static void YTABCShowTestResult(UIViewController *presenter, NSString *title, BOOL success,
                                NSString *successMessage, NSString *failureMessage) {
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:(success ? successMessage : failureMessage)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

BOOL tweakEnabled() {
    return [defaults boolForKey:EnabledKey];
}

BOOL groupedSettings() {
    return [defaults boolForKey:GroupedKey];
}

NSBundle *YTABCBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTABC" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: PS_ROOT_PATH_NS(@"/Library/Application Support/" Prefix ".bundle")];
    });
    return bundle;
}

NSString *getKey(NSString *method, NSString *classKey) {
    NSString *cacheKey =
        [NSString stringWithFormat:KeyFormatString, classKey, method];
    pthread_mutex_lock(&cacheMutex);
    NSString *fullKey = keyCache[cacheKey];
    if (!fullKey) {
        fullKey = [NSString stringWithFormat:FullKeyFormatString,
                   Prefix, classKey, method];
        keyCache[cacheKey] = fullKey;
    }
    pthread_mutex_unlock(&cacheMutex);
    return fullKey;
}

BOOL getValue(NSString *methodKey) {
    if (!methodKey) return NO;
    pthread_mutex_lock(&cacheMutex);
    BOOL contains = [allKeysSet containsObject:methodKey];
    BOOL result = NO;
    if (!contains) {
        NSString *keyPath =
            [methodKey substringFromIndex:prefixLength + 1];
        id value = [cache valueForKeyPath:keyPath];
        result = value ? [value boolValue] : NO;
    } else {
        result = [defaults boolForKey:methodKey];
    }
    pthread_mutex_unlock(&cacheMutex);
    return result;
}

void updateAllKeys(void) {
    pthread_mutex_lock(&cacheMutex);
    if (allKeysNeedsUpdate) {
        allKeysSet =
            [NSSet setWithArray:defaults.dictionaryRepresentation.allKeys];
        allKeysNeedsUpdate = NO;
    }
    pthread_mutex_unlock(&cacheMutex);
}

static BOOL YTABCParseRuntimeKey(NSString *runtimeKey, NSString **classKey, NSString **selector) {
    NSRange separator = [runtimeKey rangeOfString:@"."];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location + 1 >= runtimeKey.length) {
        return NO;
    }
    if (classKey) *classKey = [runtimeKey substringToIndex:separator.location];
    if (selector) *selector = [runtimeKey substringFromIndex:separator.location + 1];
    return YES;
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCopyRuntimeValues() {
    return YTABCRuntimeValuesSnapshot();
}

static BOOL YTABCValidOverrideNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    double numericValue = [value doubleValue];
    return numericValue == 0.0 || numericValue == 1.0;
}

NSDictionary<NSString *, NSNumber *> *YTABCopyOverrideValues() {
    NSDictionary *representation = [defaults dictionaryRepresentation];
    NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
    [representation enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key hasPrefix:@"YTABC."] && YTABCValidOverrideNumber(value)) overrides[key] = value;
    }];
    return [overrides copy];
}

BOOL YTABSetRuntimeOverride(NSString *sourceClass, NSString *selector, BOOL value) {
    return YTABCSetOverride(sourceClass, selector, value);
}

BOOL YTABResetRuntimeOverride(NSString *sourceClass, NSString *selector, BOOL nativeValue) {
    (void)nativeValue;
    BOOL success = YTABCClearOverride(sourceClass, selector);
    if (!success) {
        NSString *fullKey = getKey(selector, sourceClass);
        if ([defaults objectForKey:fullKey]) {
            [defaults removeObjectForKey:fullKey];
            success = YES;
        }
    }
    return success;
}

BOOL YTABResetAllRuntimeOverrides(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *nativeValues
) {
    (void)nativeValues;
    NSDictionary *representation = [defaults dictionaryRepresentation];
    for (NSString *key in representation) {
        if (![key hasPrefix:@"YTABC."]) continue;
        NSString *runtimeKey = [key substringFromIndex:[@"YTABC." length]];
        NSString *classKey = nil;
        NSString *selector = nil;
        if (YTABCParseRuntimeKey(runtimeKey, &classKey, &selector)) {
            YTABCClearOverride(classKey, selector);
        }
        [defaults removeObjectForKey:key];
    }
    for (NSString *key in [defaults dictionaryRepresentation]) {
        if ([key hasPrefix:@"YTABC."]) return NO;
    }
    return YES;
}

%group Search

%hook YTSettingsViewController

- (void)loadWithModel:(id)model fromView:(UIView *)view {
    %orig;
    @try {
        if ([[self valueForKey:@"_detailsCategoryID"] integerValue] == YTABCSection) {
            [self setValue:@(YES) forKey:@"_shouldShowSearchBar"];
        }
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Settings] Search-bar KVC drift in loadWithModel: %@", exception.reason);
    }
}

- (void)setSectionControllers {
    %orig;
    @try {
        if (![[self valueForKey:@"_shouldShowSearchBar"] boolValue]) return;
        YTSettingsSectionController *settingsSectionController =
            [self settingsSectionControllers][[self valueForKey:@"_detailsCategoryID"]];
        if (!settingsSectionController) {
            NSLog(@"[YTABConfig Settings] Feature Lab search section controller is unavailable");
            return;
        }
        YTSearchableSettingsViewController *searchableVC =
            [self valueForKey:@"_searchableSettingsViewController"];
        if (!searchableVC) {
            NSLog(@"[YTABConfig Settings] Feature Lab searchable controller is unavailable");
            return;
        }
        [searchableVC storeCollectionViewSections:@[settingsSectionController]];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Settings] Search section KVC drift: %@", exception.reason);
    }
}

%end

%end

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks))) {
        return %orig;
    }
    NSArray *categories = %orig;
    NSMutableArray *mutableCategories = categories.mutableCopy;
    if (![mutableCategories containsObject:@(YTABCSection)]) {
        [mutableCategories insertObject:@(YTABCSection) atIndex:0];
    }
    return mutableCategories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray<NSNumber *> *order = %orig;
    NSMutableArray<NSNumber *> *mutableOrder = order.mutableCopy;
    if (![mutableOrder containsObject:@(YTABCSection)]) {
        [mutableOrder insertObject:@(YTABCSection) atIndex:0];
    }
    return mutableOrder.copy;
}

%end

// The section-item manager owns the real _dataDelegate used to publish
// category headers/items. Keep only a weak reference for the optional local
// reveal controller; never instantiate or fabricate a manager.
static __weak id sYTABCLiveSectionItemManager;
id YTABCLiveSettingsSectionItemManager(void) {
    return sYTABCLiveSectionItemManager;
}

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateYTABCSectionWithEntry:(id)entry {
    (void)entry;
    NSMutableArray *sectionItems = [NSMutableArray array];
    NSBundle *tweakBundle = YTABCBundle();
    NSString *yesText = _LOC([NSBundle mainBundle], @"settings.yes");
    NSString *cancelText = _LOC([NSBundle mainBundle], @"confirm.cancel");
    Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);
    Class YTAlertViewClass = %c(YTAlertView);

    if (tweakEnabled()) {
        __block YTSettingsViewController *settingsViewController = nil;
        @try {
            settingsViewController = [self valueForKey:@"_settingsViewControllerDelegate"];
        } @catch (NSException *exception) {
            NSLog(@"[YTABConfig Settings] Settings delegate KVC drift: %@", exception.reason);
        }

        YTSettingsSectionItem *featureLab = [YTSettingsSectionItemClass itemWithTitle:@"Open Feature Lab"
            titleDescription:@"Search, review, and safely override experimental features"
            accessibilityIdentifier:@"YTABC_FEATURE_LAB"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                if (!settingsViewController) {
                    NSLog(@"[YTABConfig Settings] Cannot open Feature Lab without a settings delegate");
                    return NO;
                }
                NSUInteger liveFlagCount = YTABCRuntimeDiscoverFlags();
                if (liveFlagCount == 0) {
                    NSLog(@"[YTABConfig Runtime] Feature Lab opened without a live flag surface");
                }
                id<YTABLabCatalogProviding> catalog = [[YTABCatalogProvider alloc]
                    initWithBundle:YTABCBundle()
                    youtubeVersion:[%c(YTVersionUtils) appVersion]];
                id<YTABLabRuntimeProviding> provider =
                    [[YTABLegacyRuntimeAdapter alloc] initWithCatalog:catalog];
                YTABLabDashboardViewController *dashboard =
                    [[YTABLabDashboardViewController alloc] initWithProvider:provider];
                [settingsViewController pushViewController:dashboard];
                return YES;
            }];
        [sectionItems addObject:featureLab];

        // Four prominent, working destinations inside YouTube Settings.
        // Original native experiments are a real controller; Debug/Configs
        // are audited local navigation hubs; Hidden Rows opens the actual
        // live YTSettingsSectionController inventory, not synthetic rows.
        NSArray<NSDictionary<NSString *, NSString *> *> *nativeQuickMenus = @[
            @{@"title": @"Native Experiments — search & studies",
              @"subtitle": @"Open the original YTSettingsExperimentsViewController and its native tabs",
              @"route": @"experiments"},
            @{@"title": @"Debug & QA tools",
              @"subtitle": @"Native playback overlay, editor console, and developer diagnostics",
              @"route": @"debug"},
            @{@"title": @"Native Configs / Phenotype",
              @"subtitle": @"Captured Global/Cold/Hot flags and Phenotype inventory",
              @"route": @"configs"},
            @{@"title": @"Hidden Settings rows",
              @"subtitle": @"Inspect real settings categories, headers and loaded rows",
              @"route": @"hidden"}
        ];
        for (NSDictionary<NSString *, NSString *> *entry in nativeQuickMenus) {
            NSString *route = [entry[@"route"] copy];
            YTSettingsSectionItem *action = [YTSettingsSectionItemClass
                itemWithTitle:entry[@"title"]
                titleDescription:entry[@"subtitle"]
                accessibilityIdentifier:[@"YTABC_NATIVE_QUICK_" stringByAppendingString:
                    route.uppercaseString]
                detailTextBlock:nil
                selectBlock:^BOOL (__unused YTSettingsCell *cell, __unused NSUInteger index) {
                    if (!settingsViewController) return NO;
                    if ([route isEqualToString:@"experiments"])
                        return YTABCPushNativeExperiments(settingsViewController);
                    return YTABCPushNativeMenuHubForCategory(settingsViewController, route);
                }];
            [sectionItems addObject:action];
        }

        YTSettingsSectionItem *nativeExpPush = [YTSettingsSectionItemClass itemWithTitle:@"Open native experiments (push)"
            titleDescription:@"Force-open via pushViewController: on the settings nav (orphaned VC, server-driven)"
            accessibilityIdentifier:@"YTABC_NATIVE_EXPERIMENTS_PUSH"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                if (!settingsViewController) {
                    NSLog(@"[YTABConfig Settings] Cannot open native experiments without a settings delegate");
                    return NO;
                }
                return YTABCPushNativeExperiments(settingsViewController);
            }];
        [sectionItems addObject:nativeExpPush];

        YTSettingsSectionItem *nativeExpModal = [YTSettingsSectionItemClass itemWithTitle:@"Open native experiments (modal / FBTweak)"
            titleDescription:@"Force-open modally in a fresh nav with a Done button (FBTweak opener style)"
            accessibilityIdentifier:@"YTABC_NATIVE_EXPERIMENTS_MODAL"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                if (!settingsViewController) {
                    NSLog(@"[YTABConfig Settings] Cannot open native experiments without a settings delegate");
                    return NO;
                }
                return YTABCPresentNativeExperiments(settingsViewController);
            }];
        [sectionItems addObject:nativeExpModal];

        // Native 21.43.5 debugger/experiments hub. Instantiation is always
        // user-driven, and unavailable native controllers are diagnosed in UI.
        YTSettingsSectionItem *nativeTools = [YTSettingsSectionItemClass
            itemWithTitle:@"Open YouTube native tools"
            titleDescription:@"Native studies, search, results, playback and editor debug; read-only Phenotype/QA inventory"
            accessibilityIdentifier:@"YTABC_NATIVE_TOOLS_OPEN"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger argument) {
                (void)cell;
                (void)argument;
                if (!settingsViewController) {
                    NSLog(@"[YTABC NativeMenus] Settings responder unavailable");
                    return NO;
                }
                BOOL opened = YTABCPushNativeMenuHub(settingsViewController);
                if (!opened) {
                    YTABCShowTestResult(settingsViewController,
                        @"Native tools navigation", NO, @"",
                        @"This build's settings navigator could not open the local native tools hub.");
                }
                return opened;
            }];
        [sectionItems addObject:nativeTools];

        // Three independent local-only Phenotype overrides. These switches
        // return YES from the selected Objective-C getter while enabled,
        // and return the native result when disabled. No network hooks.
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Force isGooglerAccount: (local)",
            @"Override this per-account Phenotype getter to YES. Default OFF; native result when OFF.",
            @"YTABC_FORCE_IS_GOOGLER_LOCAL", @"YTABCForceIsGooglerAccount")];
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Force hasGooglerAccount (local)",
            @"Override this aggregate Phenotype getter to YES. Default OFF; native result when OFF.",
            @"YTABC_FORCE_HAS_GOOGLER_LOCAL", @"YTABCForceHasGooglerAccount")];
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Force isInternalHeterodyneSyncer (local)",
            @"Override this local internal-syncer getter to YES. Default OFF; native result when OFF.",
            @"YTABC_FORCE_INTERNAL_SYNCER_LOCAL", @"YTABCForceStandardInternalSyncer")];

        // Native diagnostics keep the original and effective values separate.
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Trace native Phenotype sync and classification",
            @"Observe genuine Googler/internal checks and Heterodyne sync events. No account or token overrides.",
            @"YTABC_TRACE_NATIVE_PHENOTYPE", @"YTABCTracePhenotype")];
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Trace native experiment search",
            @"Log InnerTube experiment search invocation without request bodies or auth data.",
            @"YTABC_TRACE_NATIVE_SEARCH", @"YTABCTraceExperimentsSearch")];
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Trace native experiment opt-in",
            @"Log genuine opt-in request invocation without altering the request.",
            @"YTABC_TRACE_NATIVE_OPTIN", @"YTABCTraceExperimentsOptIn")];
        [sectionItems addObject:YTABCDiagnosticsSwitch(YTSettingsSectionItemClass,
            @"Trace native experiment opt-out",
            @"Log genuine opt-out request invocation without altering the request.",
            @"YTABC_TRACE_NATIVE_OPTOUT", @"YTABCTraceExperimentsOptOut")];

        YTSettingsSectionItem *nativeStatus = [YTSettingsSectionItemClass
            itemWithTitle:@"Native Phenotype / Experiments status"
            titleDescription:@"Show observed native/effective toggles, call counts and installed hooks"
            accessibilityIdentifier:@"YTABC_NATIVE_DIAGNOSTIC_STATUS"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger argument) {
                (void)cell; (void)argument;
                NSDictionary *snapshot = YTABCCopyNativeDiagnostics();
                NSArray *sortedKeys = [[snapshot allKeys] sortedArrayUsingSelector:@selector(compare:)];
                NSMutableArray *lines = [NSMutableArray array];
                for (NSString *key in sortedKeys)
                    [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, snapshot[key]]];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Native diagnostic state"
                    message:[lines componentsJoinedByString:@"\n"]
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault handler:nil]];
                [settingsViewController presentViewController:alert animated:YES completion:nil];
                return YES;
            }];
        [sectionItems addObject:nativeStatus];

        YTSettingsSectionItem *nativeResync = [YTSettingsSectionItemClass
            itemWithTitle:@"Run native Phenotype resync"
            titleDescription:@"Use only the actual syncer observed on the original Heterodyne path"
            accessibilityIdentifier:@"YTABC_NATIVE_PHENOTYPE_RESYNC"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger argument) {
                (void)cell; (void)argument;
                BOOL issued = YTABCRunPhenotypeResync();
                YTABCShowTestResult(settingsViewController, @"Native Phenotype resync", issued,
                    @"Called syncWithCallback: on the observed native syncer. Server success is not implied.",
                    @"No live native syncer was observed or its ABI does not match.");
                return YES;
            }];
        [sectionItems addObject:nativeResync];

        YTSettingsSectionItem *nativeClear = [YTSettingsSectionItemClass
            itemWithTitle:@"Clear native experiment cache"
            titleDescription:@"Call clearCaches on the observed YTExperimentsServiceImpl only"
            accessibilityIdentifier:@"YTABC_NATIVE_EXPERIMENT_CACHE"
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger argument) {
                (void)cell; (void)argument;
                BOOL issued = YTABCClearNativeExperimentsCaches();
                YTABCShowTestResult(settingsViewController, @"Native experiments cache", issued,
                    @"Called clearCaches on the observed native experiments service.",
                    @"No native experiments service observed. Open Search Experiments first.");
                return YES;
            }];
        [sectionItems addObject:nativeClear];


        // Phenotype/InnerTube test switches from an older draft were removed:
        // their declared callback implementations did not exist in this branch.
        // Keep only the verified native UI openers and diagnostics.
    }

    YTSettingsSectionItem *thread = [YTSettingsSectionItemClass itemWithTitle:LOC(@"OPEN_MEGATHREAD")
        titleDescription:LOC(@"OPEN_MEGATHREAD_DESC")
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://github.com/PoomSmart/YTABConfig/discussions"]];
        }];
    [sectionItems insertObject:thread atIndex:0];

    YTSettingsSectionItem *master = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"ENABLED")
        titleDescription:LOC(@"ENABLED_DESC")
        accessibilityIdentifier:nil
        switchOn:tweakEnabled()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [defaults setBool:enabled forKey:EnabledKey];
            YTAlertView *alertView = [YTAlertViewClass confirmationDialogWithAction:^{ exit(0); }
                actionTitle:yesText
                cancelAction:^{
                    [cell setSwitchOn:!enabled animated:YES];
                    [defaults setBool:!enabled forKey:EnabledKey];
                }
                cancelTitle:cancelText];
            alertView.title = LOC(@"WARNING");
            alertView.subtitle = LOC(@"APPLY_DESC");
            [alertView show];
            return YES;
        }
        settingItemId:0];
    [sectionItems insertObject:master atIndex:0];

    if (tweakEnabled()) {
        NSString *titleDescription = [NSString stringWithFormat:
            @"Afterglow Labs Feature Lab %@ • live flags load on demand",
            @(OS_STRINGIFY(TWEAK_VERSION))];
        YTSettingsSectionItem *info = [YTSettingsSectionItemClass itemWithTitle:nil
            titleDescription:titleDescription
            accessibilityIdentifier:nil
            detailTextBlock:nil
            selectBlock:nil];
        info.enabled = NO;
        [sectionItems insertObject:info atIndex:0];
    }

    id delegate = nil;
    @try {
        delegate = [self valueForKey:@"_dataDelegate"];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Settings] Data delegate KVC drift: %@", exception.reason);
    }
    if (!delegate) {
        NSLog(@"[YTABConfig Settings] Cannot inject Feature Lab category without a data delegate");
        return;
    }

    NSString *title = @"Feature Lab";
    if ([delegate respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_EXPERIMENT;
        [delegate setSectionItems:sectionItems
            forCategory:YTABCSection
            title:title
            icon:icon
            titleDescription:nil
            headerHidden:NO];
    } else if ([delegate respondsToSelector:
        @selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
        [delegate setSectionItems:sectionItems
            forCategory:YTABCSection
            title:title
            titleDescription:nil
            headerHidden:NO];
    } else {
        NSLog(@"[YTABConfig Settings] YouTube settings injection selectors are unavailable");
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    sYTABCLiveSectionItemManager = self;
    // Observe whether YouTube actually asks to construct categories 30/37.
    // Do not generate entries for missing or account-gated sections.
    extern void YTABCRecordSettingsCategoryUpdate(NSUInteger, id);
    YTABCRecordSettingsCategoryUpdate(category, entry);
    if (category == YTABCSection) {
        [self updateYTABCSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end

void SearchHook() {
    static dispatch_once_t searchHookOnceToken;
    dispatch_once(&searchHookOnceToken, ^{
        %init(Search);
    });
}

%ctor {
    defaults = [NSUserDefaults standardUserDefaults];
    prefixLength = [Prefix length];
    keyCache = [NSMutableDictionary new];

    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&cacheMutex, &attributes);
    pthread_mutexattr_destroy(&attributes);

    YTABCRuntimeRegistryStart(defaults);

    %init;
}
