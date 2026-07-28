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
extern void YTABCInstallInternalIdentityHooks(void);
NSSet<NSString *> *allKeysSet;
BOOL allKeysNeedsUpdate = YES;
pthread_mutex_t cacheMutex;
NSMutableDictionary<NSString *, NSString *> *keyCache;
NSUInteger prefixLength;

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

        // Duas versões pra testar (ambas instanciam via initWithParentResponder:;
        // diferem só na apresentação). Ver YTNativeExperiments.x.
        // V1 — push na própria nav do settings (jeito nativo do YT).
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

        // V2 — modal numa nav nova com botão Done (estilo FBTweak).
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

        // Flip client-side Googler/internal identity gates (Phenotype).
        // Aplica ao vivo pras classes já carregadas; resto no próximo launch.
        YTSettingsSectionItem *internalIdentity = [YTSettingsSectionItemClass switchItemWithTitle:@"Internal identity (Googler/dogfood)"
            titleDescription:@"Force client-side Phenotype Googler/internal gates to YES. Unlocks client-gated internal behavior. Server-driven screens (e.g. Search Experiments) still authorize by the real account. Restart recommended."
            accessibilityIdentifier:nil
            switchOn:[defaults boolForKey:@"YTABCInternalIdentity"]
            switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
                [defaults setBool:enabled forKey:@"YTABCInternalIdentity"];
                if (enabled) YTABCInstallInternalIdentityHooks();
                return YES;
            }
            settingItemId:0];
        [sectionItems addObject:internalIdentity];
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
