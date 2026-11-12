#import "RuntimeFlagRegistry.h"

#import <pthread.h>

NS_ASSUME_NONNULL_BEGIN

extern NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;
extern pthread_mutex_t cacheMutex;
extern NSUserDefaults *defaults;
extern BOOL allKeysNeedsUpdate;
extern void updateAllKeys(void);

static NSString * const YTABCPersistencePrefix = @"YTABC";
static NSUserDefaults *YTABCRuntimeDefaults;
static NSString *YTABCRuntimeLaunchCaptureDate;
static dispatch_once_t YTABCRuntimeLaunchCaptureOnce;

static NSArray<NSString *> *YTABCCanonicalClassNames(void) {
    static NSArray<NSString *> *classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classNames = @[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"];
    });
    return classNames;
}

static NSString *YTABCRuntimeRecordKey(NSString *className, NSString *selectorName) {
    return [NSString stringWithFormat:@"%@.%@", className, selectorName];
}

static NSString *YTABCCurrentTimestamp(void) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:NSDate.date];
}

static BOOL YTABCValidStoredBoolean(id value, BOOL *result) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double numericValue = [value doubleValue];
    if (numericValue != 0.0 && numericValue != 1.0) return NO;
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL YTABCCanonicalClass(NSString *className) {
    return [YTABCCanonicalClassNames() containsObject:className];
}

static NSNumber * _Nullable YTABCCachedNativeValue(
    NSString *className,
    NSString *selectorName
) {
    if (!YTABCCanonicalClass(className) || selectorName.length == 0) return nil;
    pthread_mutex_lock(&cacheMutex);
    NSNumber *value = cache[className][selectorName];
    pthread_mutex_unlock(&cacheMutex);
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static NSUserDefaults *YTABCSelectedDefaults(void) {
    return YTABCRuntimeDefaults ?: defaults ?: NSUserDefaults.standardUserDefaults;
}

NSString *YTABCOverrideKey(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) return @"";
    return [NSString stringWithFormat:@"%@.%@.%@",
            YTABCPersistencePrefix, className, selectorName];
}

void YTABCRuntimeRegistryStart(NSUserDefaults *selectedDefaults) {
    YTABCRuntimeDefaults =
        selectedDefaults ?: defaults ?: NSUserDefaults.standardUserDefaults;
}

void YTABCRuntimeApplyPersistedOverrides(void) {
    allKeysNeedsUpdate = YES;
    updateAllKeys();
}

NSUInteger YTABCRuntimeDiscoverFlags(void) {
    NSUInteger count = 0;
    pthread_mutex_lock(&cacheMutex);
    for (NSString *className in YTABCCanonicalClassNames()) {
        count += cache[className].count;
    }
    pthread_mutex_unlock(&cacheMutex);
    return count;
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
YTABCRuntimeValuesSnapshot(void) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *snapshot =
        [NSMutableDictionary dictionary];
    pthread_mutex_lock(&cacheMutex);
    for (NSString *className in YTABCCanonicalClassNames()) {
        snapshot[className] = [cache[className] copy] ?: @{};
    }
    pthread_mutex_unlock(&cacheMutex);
    return snapshot.copy;
}

BOOL YTABCRuntimeHasFlag(NSString *className, NSString *selectorName) {
    return YTABCCachedNativeValue(className, selectorName) != nil;
}

BOOL YTABCSetOverride(NSString *className, NSString *selectorName, BOOL value) {
    if (!YTABCRuntimeHasFlag(className, selectorName)) return NO;
    [YTABCSelectedDefaults() setBool:value
                              forKey:YTABCOverrideKey(className, selectorName)];
    YTABCRuntimeApplyPersistedOverrides();
    return YES;
}

BOOL YTABCClearOverride(NSString *className, NSString *selectorName) {
    if (!YTABCRuntimeHasFlag(className, selectorName)) return NO;
    [YTABCSelectedDefaults() removeObjectForKey:
        YTABCOverrideKey(className, selectorName)];
    YTABCRuntimeApplyPersistedOverrides();
    return YES;
}

NSNumber * _Nullable YTABCNativeValue(
    NSString *className,
    NSString *selectorName
) {
    return YTABCCachedNativeValue(className, selectorName);
}

NSNumber * _Nullable YTABCOverrideValue(
    NSString *className,
    NSString *selectorName
) {
    if (!YTABCRuntimeHasFlag(className, selectorName)) return nil;
    BOOL value = NO;
    id stored = [YTABCSelectedDefaults() objectForKey:
        YTABCOverrideKey(className, selectorName)];
    return YTABCValidStoredBoolean(stored, &value) ? @(value) : nil;
}

NSNumber * _Nullable YTABCEffectiveValue(
    NSString *className,
    NSString *selectorName
) {
    return YTABCOverrideValue(className, selectorName) ?:
        YTABCNativeValue(className, selectorName);
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
YTABCRuntimeSnapshot(void) {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *values =
        YTABCRuntimeValuesSnapshot();
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *snapshot =
        [NSMutableDictionary dictionary];
    dispatch_once(&YTABCRuntimeLaunchCaptureOnce, ^{
        YTABCRuntimeLaunchCaptureDate = YTABCCurrentTimestamp();
    });

    for (NSString *className in YTABCCanonicalClassNames()) {
        [values[className] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *selectorName, NSNumber *native, BOOL *stop) {
            NSString *recordKey =
                YTABCRuntimeRecordKey(className, selectorName);
            NSNumber *override = YTABCOverrideValue(className, selectorName);
            snapshot[recordKey] = @{
                @"class": className,
                @"selector": selectorName,
                @"preferenceKey": YTABCOverrideKey(className, selectorName),
                @"native": native,
                @"nativeCapturedAt": YTABCRuntimeLaunchCaptureDate ?: NSNull.null,
                @"override": override ?: NSNull.null,
                @"effective": override ?: native,
                @"hookInstalled": @YES
            };
        }];
    }
    return snapshot.copy;
}

NS_ASSUME_NONNULL_END
