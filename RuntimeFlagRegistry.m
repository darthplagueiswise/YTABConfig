#import "RuntimeFlagRegistry.h"

#import <pthread.h>

NS_ASSUME_NONNULL_BEGIN

extern NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;
extern pthread_mutex_t cacheMutex;
extern NSUserDefaults *defaults;
extern BOOL allKeysNeedsUpdate;
extern void updateAllKeys(void);

static NSString * const YTABCPersistencePrefix = @"YTABC";
static const NSUInteger YTABCNativeRefreshBatchSize = 48;

static pthread_mutex_t YTABCRuntimeMutex;
static dispatch_once_t YTABCRuntimeOnce;
static NSMapTable<NSString *, id> *YTABCRuntimeInstances;
static NSMutableDictionary<NSString *, NSValue *> *YTABCRuntimeOriginalImplementations;
static NSMutableDictionary<NSString *, NSString *> *YTABCRuntimeCaptureDates;
static NSUserDefaults *YTABCRuntimeDefaults;
static NSString *YTABCRuntimeLaunchCaptureDate;

static NSArray<NSString *> *YTABCCanonicalClassNames(void) {
    static NSArray<NSString *> *classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classNames = @[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"];
    });
    return classNames;
}

static void YTABCRuntimeInitialize(void) {
    dispatch_once(&YTABCRuntimeOnce, ^{
        pthread_mutexattr_t attributes;
        pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&YTABCRuntimeMutex, &attributes);
        pthread_mutexattr_destroy(&attributes);

        YTABCRuntimeInstances = [NSMapTable strongToWeakObjectsMapTable];
        YTABCRuntimeOriginalImplementations = [NSMutableDictionary dictionary];
        YTABCRuntimeCaptureDates = [NSMutableDictionary dictionary];
        YTABCRuntimeDefaults = NSUserDefaults.standardUserDefaults;
    });
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
    YTABCRuntimeInitialize();
    pthread_mutex_lock(&YTABCRuntimeMutex);
    NSUserDefaults *selected = YTABCRuntimeDefaults ?: defaults;
    pthread_mutex_unlock(&YTABCRuntimeMutex);
    return selected ?: NSUserDefaults.standardUserDefaults;
}

NSString *YTABCOverrideKey(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) return @"";
    return [NSString stringWithFormat:@"%@.%@.%@",
            YTABCPersistencePrefix, className, selectorName];
}

void YTABCRuntimeRegistryStart(NSUserDefaults *selectedDefaults) {
    YTABCRuntimeInitialize();
    pthread_mutex_lock(&YTABCRuntimeMutex);
    YTABCRuntimeDefaults =
        selectedDefaults ?: defaults ?: NSUserDefaults.standardUserDefaults;
    pthread_mutex_unlock(&YTABCRuntimeMutex);
}

BOOL YTABCRuntimeRegisterConfigInstance(id instance) {
    if (!instance) return NO;
    NSString *className = NSStringFromClass([instance class]);
    if (!YTABCCanonicalClass(className)) return NO;

    YTABCRuntimeInitialize();
    pthread_mutex_lock(&YTABCRuntimeMutex);
    [YTABCRuntimeInstances setObject:instance forKey:className];
    pthread_mutex_unlock(&YTABCRuntimeMutex);
    return YES;
}

void YTABCRuntimeRegisterOriginalImplementation(
    id instance,
    SEL selector,
    IMP originalImplementation,
    BOOL nativeValue
) {
    if (!instance || !selector || !originalImplementation) return;
    NSString *className = NSStringFromClass([instance class]);
    NSString *selectorName = NSStringFromSelector(selector);
    if (!YTABCCanonicalClass(className) || selectorName.length == 0) return;

    YTABCRuntimeInitialize();
    NSString *recordKey = YTABCRuntimeRecordKey(className, selectorName);
    pthread_mutex_lock(&YTABCRuntimeMutex);
    [YTABCRuntimeInstances setObject:instance forKey:className];
    YTABCRuntimeOriginalImplementations[recordKey] =
        [NSValue valueWithPointer:originalImplementation];
    pthread_mutex_unlock(&YTABCRuntimeMutex);

    // hookClass already owns cacheMutex and writes the same native value. Keep
    // this argument in the bridge contract so a registration cannot silently
    // lose which value was captured before the PoomSmart-compatible hook.
    (void)nativeValue;
}

void YTABCRuntimeApplyPersistedOverrides(void) {
    allKeysNeedsUpdate = YES;
    updateAllKeys();
}

NSUInteger YTABCRuntimeDiscoverFlags(void) {
    YTABCRuntimeInitialize();
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
    NSNumber *fallback = YTABCCachedNativeValue(className, selectorName);
    if (!fallback) return nil;

    YTABCRuntimeInitialize();
    NSString *recordKey = YTABCRuntimeRecordKey(className, selectorName);
    pthread_mutex_lock(&YTABCRuntimeMutex);
    id instance = [YTABCRuntimeInstances objectForKey:className];
    IMP originalImplementation = (IMP)
        [YTABCRuntimeOriginalImplementations[recordKey] pointerValue];
    pthread_mutex_unlock(&YTABCRuntimeMutex);
    if (!instance || !originalImplementation) return fallback;

    BOOL nativeValue = fallback.boolValue;
    @try {
        nativeValue = ((BOOL (*)(id, SEL))originalImplementation)(
            instance,
            NSSelectorFromString(selectorName)
        );
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Runtime] Native sample failed for %@: %@",
              recordKey, exception.reason);
        return fallback;
    }

    pthread_mutex_lock(&cacheMutex);
    cache[className][selectorName] = @(nativeValue);
    pthread_mutex_unlock(&cacheMutex);
    pthread_mutex_lock(&YTABCRuntimeMutex);
    YTABCRuntimeCaptureDates[recordKey] = YTABCCurrentTimestamp();
    pthread_mutex_unlock(&YTABCRuntimeMutex);
    return @(nativeValue);
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

static void YTABCRefreshNativeBatch(
    NSArray<NSString *> *recordKeys,
    NSUInteger startIndex,
    dispatch_block_t _Nullable completion
) {
    NSUInteger endIndex =
        MIN(startIndex + YTABCNativeRefreshBatchSize, recordKeys.count);
    @autoreleasepool {
        for (NSUInteger index = startIndex; index < endIndex; ++index) {
            NSString *recordKey = recordKeys[index];
            NSRange separator = [recordKey rangeOfString:@"."];
            if (separator.location == NSNotFound) continue;
            NSString *className = [recordKey substringToIndex:separator.location];
            NSString *selectorName =
                [recordKey substringFromIndex:separator.location + 1];
            YTABCNativeValue(className, selectorName);
        }
    }
    if (endIndex < recordKeys.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTABCRefreshNativeBatch(recordKeys, endIndex, completion);
        });
    } else if (completion) {
        completion();
    }
}

void YTABCRuntimeRefreshAllNativeValues(dispatch_block_t completion) {
    YTABCRuntimeInitialize();
    dispatch_block_t start = ^{
        pthread_mutex_lock(&YTABCRuntimeMutex);
        NSArray<NSString *> *recordKeys =
            [YTABCRuntimeOriginalImplementations.allKeys copy];
        pthread_mutex_unlock(&YTABCRuntimeMutex);
        YTABCRefreshNativeBatch(recordKeys, 0, completion);
    };
    if (NSThread.isMainThread) start();
    else dispatch_async(dispatch_get_main_queue(), start);
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
YTABCRuntimeSnapshot(void) {
    YTABCRuntimeInitialize();
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *values =
        YTABCRuntimeValuesSnapshot();
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *snapshot =
        [NSMutableDictionary dictionary];
    pthread_mutex_lock(&YTABCRuntimeMutex);
    if (!YTABCRuntimeLaunchCaptureDate) {
        YTABCRuntimeLaunchCaptureDate = YTABCCurrentTimestamp();
    }
    pthread_mutex_unlock(&YTABCRuntimeMutex);

    for (NSString *className in YTABCCanonicalClassNames()) {
        [values[className] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *selectorName, NSNumber *native, BOOL *stop) {
            NSString *recordKey =
                YTABCRuntimeRecordKey(className, selectorName);
            NSNumber *override = YTABCOverrideValue(className, selectorName);
            pthread_mutex_lock(&YTABCRuntimeMutex);
            NSString *capturedAt =
                YTABCRuntimeCaptureDates[recordKey] ?: YTABCRuntimeLaunchCaptureDate;
            pthread_mutex_unlock(&YTABCRuntimeMutex);
            snapshot[recordKey] = @{
                @"class": className,
                @"selector": selectorName,
                @"preferenceKey": YTABCOverrideKey(className, selectorName),
                @"native": native,
                @"nativeCapturedAt": capturedAt ?: NSNull.null,
                @"override": override ?: NSNull.null,
                @"effective": override ?: native,
                @"hookInstalled": @YES
            };
        }];
    }
    return snapshot.copy;
}

NS_ASSUME_NONNULL_END
