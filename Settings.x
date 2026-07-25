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

@interface YTSettingsSectionItemManager (YTABConfig)
- (void)updateYTABCSectionWithEntry:(id)entry;
@end

extern NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;
NSUserDefaults *defaults;
pthread_mutex_t cacheMutex;

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
    return [NSString stringWithFormat:@"%@.%@.%@", Prefix, classKey, method];
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

NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *YTABCopyRuntimeValues() {
    pthread_mutex_lock(&cacheMutex);
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithCapacity:cache.count];
    [cache enumerateKeysAndObjectsUsingBlock:^(NSString *classKey, NSDictionary *methods, BOOL *stop) {
        snapshot[classKey] = [methods copy];
    }];
    pthread_mutex_unlock(&cacheMutex);
    return [snapshot copy];
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
    NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *nativeValues
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
    int totalSettings = 0;
    NSBundle *tweakBundle = YTABCBundle();
    NSString *yesText = _LOC([NSBundle mainBundle], @"settings.yes");
    NSString *cancelText = _LOC([NSBundle mainBundle], @"confirm.cancel");
    Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);
    Class YTAlertViewClass = %c(YTAlertView);

    if (tweakEnabled()) {
        NSDictionary *runtimeValues = YTABCopyRuntimeValues();
        for (NSDictionary *methods in runtimeValues.allValues) totalSettings += methods.count;

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
            @"Afterglow Labs Feature Lab %@ • %d runtime flags",
            @(OS_STRINGIFY(TWEAK_VERSION)), totalSettings];
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
    [defaults registerDefaults:@{EnabledKey: @YES}];

    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&cacheMutex, &attr);
    pthread_mutexattr_destroy(&attr);

    %init;
}
