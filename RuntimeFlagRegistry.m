#import "RuntimeFlagRegistry.h"

#import "RuntimeOverrideState.h"

#import <objc/message.h>
#import <pthread.h>
#import <substrate.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const YTABCPersistencePrefix = @"YTABC";
static NSString * const YTABCExactBoolMethodEncoding = @"B16@0:8";
static const NSUInteger YTABCNativeRefreshBatchSize = 48;

static NSArray<NSString *> *YTABCCanonicalConfigClassNames(void) {
    static NSArray<NSString *> *classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classNames = @[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"];
    });
    return classNames;
}

@interface YTABCRuntimeFlagRecord : NSObject
@property(nonatomic, assign) Class ownerClass;
@property(nonatomic, assign) SEL selector;
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *preferenceKey;
@property(nonatomic, assign) BOOL nativeValue;
@property(nonatomic, assign) BOOL hasNativeValue;
@property(nonatomic, copy, nullable) NSString *nativeCapturedAt;
@property(nonatomic, assign) IMP discoveredIMP;
@property(nonatomic, assign, nullable) IMP originalIMP;
@property(nonatomic, weak, nullable) id instance;
@property(nonatomic, assign) YTABCRuntimeOverrideState overrideState;
@end

@implementation YTABCRuntimeFlagRecord
@end

static NSMutableDictionary<NSString *, YTABCRuntimeFlagRecord *> *YTABCRecords;
static NSMutableDictionary<NSString *, NSMutableArray<YTABCRuntimeFlagRecord *> *> *
    YTABCRecordsBySelector;
static NSMapTable<NSString *, id> *YTABCInstancesByClassName;
static NSMutableSet<NSString *> *YTABCActiveOverrideRecordKeys;
static NSUserDefaults *YTABCDefaults;
static id _Nullable YTABCDefaultsObserver;
static pthread_mutex_t YTABCRegistryMutex;
static dispatch_once_t YTABCRegistryOnce;

static void YTABCInitializeRegistry(void) {
    dispatch_once(&YTABCRegistryOnce, ^{
        YTABCRecords = [NSMutableDictionary dictionary];
        YTABCRecordsBySelector = [NSMutableDictionary dictionary];
        YTABCInstancesByClassName = [NSMapTable strongToWeakObjectsMapTable];
        YTABCActiveOverrideRecordKeys = [NSMutableSet set];
        YTABCDefaults = NSUserDefaults.standardUserDefaults;
        pthread_mutexattr_t attributes;
        pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&YTABCRegistryMutex, &attributes);
        pthread_mutexattr_destroy(&attributes);
    });
}

NSString *YTABCOverrideKey(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) return @"";
    return [NSString stringWithFormat:@"%@.%@.%@", YTABCPersistencePrefix, className, selectorName];
}

static NSString *YTABCRecordKey(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) return @"";
    return [NSString stringWithFormat:@"%@.%@", className, selectorName];
}

static BOOL YTABCParsePreferenceKey(
    NSString *preferenceKey,
    NSString **className,
    NSString **selectorName
) {
    if (![preferenceKey isKindOfClass:NSString.class]) return NO;
    NSString *prefix = [YTABCPersistencePrefix stringByAppendingString:@"."];
    if (![preferenceKey hasPrefix:prefix]) return NO;
    NSString *runtimeKey = [preferenceKey substringFromIndex:prefix.length];
    for (NSString *candidateClass in YTABCCanonicalConfigClassNames()) {
        NSString *classPrefix = [candidateClass stringByAppendingString:@"."];
        if (![runtimeKey hasPrefix:classPrefix] || runtimeKey.length == classPrefix.length) continue;
        if (className) *className = candidateClass;
        if (selectorName) *selectorName = [runtimeKey substringFromIndex:classPrefix.length];
        return YES;
    }
    return NO;
}

static BOOL YTABCValidStoredBoolean(id value, BOOL *result) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double numericValue = [value doubleValue];
    if (numericValue != 0.0 && numericValue != 1.0) return NO;
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL YTABCInvokeBOOL(IMP implementation, id target, SEL selector) {
    return ((BOOL (*)(id, SEL))implementation)(target, selector);
}

static NSString *YTABCCurrentTimestamp(void) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:NSDate.date];
}

static NSUserDefaults *YTABCDefaultsSnapshot(void) {
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    NSUserDefaults *defaults = YTABCDefaults;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return defaults;
}

static Class YTABCCanonicalConfigOwnerClass(id instance) {
    for (Class currentClass = object_getClass(instance);
         currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        NSString *currentName = NSStringFromClass(currentClass);
        if ([YTABCCanonicalConfigClassNames() containsObject:currentName]) return currentClass;
    }
    return Nil;
}

static BOOL YTABCClassIsInHierarchy(Class candidate, Class otherClass) {
    for (Class currentClass = candidate;
         currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        if (currentClass == otherClass) return YES;
    }
    return NO;
}

static BOOL YTABCRecordConflictsWithOwnerHierarchy(Class ownerClass, NSString *selectorName) {
    for (YTABCRuntimeFlagRecord *record in YTABCRecordsBySelector[selectorName]) {
        if (record.ownerClass == ownerClass) continue;
        if (YTABCClassIsInHierarchy(ownerClass, record.ownerClass) ||
            YTABCClassIsInHierarchy(record.ownerClass, ownerClass)) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTABCMethodIsEligible(Method method) {
    const char *encoding = method_getTypeEncoding(method);
    return encoding && strcmp(encoding, YTABCExactBoolMethodEncoding.UTF8String) == 0;
}

static BOOL YTABCSelectorIsExcluded(NSString *selectorName) {
    static NSSet<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = [NSSet setWithArray:@[
            @"android", @"amsterdam", @"kidsClient", @"musicClient",
            @"musicOfflineClient", @"unplugged"
        ]];
    });
    for (NSString *prefix in prefixes) {
        if ([selectorName hasPrefix:prefix]) return YES;
    }
    return [selectorName rangeOfString:@"Android"].location != NSNotFound;
}

static YTABCRuntimeFlagRecord * _Nullable YTABCRecordForRuntimeReceiver(id receiver, SEL selector) {
    NSString *selectorName = NSStringFromSelector(selector);
    for (Class currentClass = object_getClass(receiver);
         currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        NSString *className = NSStringFromClass(currentClass);
        YTABCRuntimeFlagRecord *record =
            YTABCRecords[YTABCRecordKey(className, selectorName)];
        if (record) return record;
    }

    for (NSString *canonicalClassName in YTABCCanonicalConfigClassNames()) {
        YTABCRuntimeFlagRecord *record =
            YTABCRecords[YTABCRecordKey(canonicalClassName, selectorName)];
        if (record && [receiver isKindOfClass:record.ownerClass]) return record;
    }
    return nil;
}

static BOOL YTABCRuntimeHook(id self, SEL selector) {
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeFlagRecord *record = YTABCRecordForRuntimeReceiver(self, selector);
    if (!record) {
        pthread_mutex_unlock(&YTABCRegistryMutex);
        NSLog(@"[YTABConfig Runtime] Missing hook record for %@.%@",
              NSStringFromClass([self class]), NSStringFromSelector(selector));
        return NO;
    }
    YTABCRuntimeOverrideState state = record.overrideState;
    IMP originalIMP = record.originalIMP ?: record.discoveredIMP;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    if (state.hasOverride) return state.overrideValue;
    return originalIMP ? YTABCInvokeBOOL(originalIMP, self, selector) : NO;
}

static BOOL YTABCInstallHookForRecord(YTABCRuntimeFlagRecord *record) {
    if (!record) return NO;
    pthread_mutex_lock(&YTABCRegistryMutex);
    if (record.overrideState.hookInstalled) {
        pthread_mutex_unlock(&YTABCRegistryMutex);
        return YES;
    }

    IMP originalIMP = NULL;
    MSHookMessageEx(record.ownerClass, record.selector, (IMP)YTABCRuntimeHook, &originalIMP);
    record.originalIMP = originalIMP ?: record.discoveredIMP;
    YTABCRuntimeOverrideState state = record.overrideState;
    YTABCRuntimeOverrideStateMarkHookInstalled(&state);
    record.overrideState = state;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    NSLog(@"[YTABConfig Runtime] Hooked persisted/live override %@", record.preferenceKey);
    return YES;
}

static YTABCRuntimeFlagRecord * _Nullable YTABCEnsureRecord(
    NSString *className,
    NSString *selectorName
) {
    if (className.length == 0 || selectorName.length == 0 ||
        ![YTABCCanonicalConfigClassNames() containsObject:className]) {
        return nil;
    }

    YTABCInitializeRegistry();
    NSString *recordKey = YTABCRecordKey(className, selectorName);
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeFlagRecord *existingRecord = YTABCRecords[recordKey];
    id instance = [YTABCInstancesByClassName objectForKey:className];
    pthread_mutex_unlock(&YTABCRegistryMutex);
    if (existingRecord) {
        if (instance) existingRecord.instance = instance;
        return existingRecord;
    }
    if (!instance) return nil;

    Class ownerClass = YTABCCanonicalConfigOwnerClass(instance);
    if (!ownerClass || ![NSStringFromClass(ownerClass) isEqualToString:className]) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(ownerClass, selector);
    if (!method || !YTABCMethodIsEligible(method) || YTABCSelectorIsExcluded(selectorName)) return nil;

    YTABCRuntimeFlagRecord *record = [YTABCRuntimeFlagRecord new];
    record.ownerClass = ownerClass;
    record.selector = selector;
    record.className = className;
    record.selectorName = selectorName;
    record.preferenceKey = YTABCOverrideKey(className, selectorName);
    record.discoveredIMP = method_getImplementation(method);
    record.instance = instance;
    record.overrideState = YTABCRuntimeOverrideStateMake();

    pthread_mutex_lock(&YTABCRegistryMutex);
    existingRecord = YTABCRecords[recordKey];
    BOOL hierarchyConflict = YTABCRecordConflictsWithOwnerHierarchy(ownerClass, selectorName);
    if (!existingRecord && !hierarchyConflict) {
        YTABCRecords[recordKey] = record;
        NSMutableArray<YTABCRuntimeFlagRecord *> *selectorRecords =
            YTABCRecordsBySelector[selectorName];
        if (!selectorRecords) {
            selectorRecords = [NSMutableArray array];
            YTABCRecordsBySelector[selectorName] = selectorRecords;
        }
        [selectorRecords addObject:record];
    }
    pthread_mutex_unlock(&YTABCRegistryMutex);

    if (existingRecord) {
        existingRecord.instance = instance;
        return existingRecord;
    }
    if (hierarchyConflict) {
        NSLog(@"[YTABConfig Runtime] Skipping ambiguous hierarchy selector %@.%@",
              className, selectorName);
        return nil;
    }
    return record;
}

static NSNumber * _Nullable YTABCSampleRecordNativeValue(
    YTABCRuntimeFlagRecord *record,
    NSString *capturedAt
) {
    if (!record) return nil;
    pthread_mutex_lock(&YTABCRegistryMutex);
    id instance = record.instance;
    IMP implementation = record.originalIMP ?: record.discoveredIMP;
    SEL selector = record.selector;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    if (!instance || !implementation || !selector) return nil;

    BOOL nativeValue = NO;
    @try {
        nativeValue = YTABCInvokeBOOL(implementation, instance, selector);
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Runtime] Native sample failed for %@: %@",
              record.preferenceKey, exception.reason);
        return nil;
    }

    pthread_mutex_lock(&YTABCRegistryMutex);
    record.instance = instance;
    record.nativeValue = nativeValue;
    record.hasNativeValue = YES;
    record.nativeCapturedAt = capturedAt;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return @(nativeValue);
}

static YTABCRuntimeFlagRecord * _Nullable YTABCValidatedRecord(
    NSString *className,
    NSString *selectorName
) {
    if (className.length == 0 || selectorName.length == 0) return nil;
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeFlagRecord *record = YTABCRecords[YTABCRecordKey(className, selectorName)];
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return record;
}

void YTABCRuntimeApplyPersistedOverrides(void) {
    YTABCInitializeRegistry();
    NSUserDefaults *defaults = YTABCDefaultsSnapshot();
    NSDictionary *representation = [defaults dictionaryRepresentation];
    NSMutableDictionary<NSString *, NSNumber *> *desiredOverrides = [NSMutableDictionary dictionary];

    [representation enumerateKeysAndObjectsUsingBlock:^(NSString *preferenceKey, id value, BOOL *stop) {
        NSString *className = nil;
        NSString *selectorName = nil;
        if (!YTABCParsePreferenceKey(preferenceKey, &className, &selectorName)) return;
        BOOL overrideValue = NO;
        if (!YTABCValidStoredBoolean(value, &overrideValue)) {
            NSLog(@"[YTABConfig Runtime] Ignoring invalid override value for %@", preferenceKey);
            return;
        }
        YTABCRuntimeFlagRecord *record = YTABCEnsureRecord(className, selectorName);
        if (record) desiredOverrides[YTABCRecordKey(className, selectorName)] = @(overrideValue);
    }];

    pthread_mutex_lock(&YTABCRegistryMutex);
    NSSet<NSString *> *previousActiveKeys = YTABCActiveOverrideRecordKeys.copy;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    for (NSString *recordKey in previousActiveKeys) {
        if (desiredOverrides[recordKey]) continue;
        pthread_mutex_lock(&YTABCRegistryMutex);
        YTABCRuntimeFlagRecord *record = YTABCRecords[recordKey];
        if (record) {
            YTABCRuntimeOverrideState state = record.overrideState;
            YTABCRuntimeOverrideStateClearOverride(&state);
            record.overrideState = state;
        }
        pthread_mutex_unlock(&YTABCRegistryMutex);
    }

    NSMutableSet<NSString *> *activeKeys = [NSMutableSet set];
    [desiredOverrides enumerateKeysAndObjectsUsingBlock:
        ^(NSString *recordKey, NSNumber *value, BOOL *stop) {
        pthread_mutex_lock(&YTABCRegistryMutex);
        YTABCRuntimeFlagRecord *record = YTABCRecords[recordKey];
        if (record) {
            YTABCRuntimeOverrideState state = record.overrideState;
            YTABCRuntimeOverrideStateSetOverride(&state, value.boolValue);
            record.overrideState = state;
        }
        pthread_mutex_unlock(&YTABCRegistryMutex);
        if (record && YTABCInstallHookForRecord(record)) [activeKeys addObject:recordKey];
    }];

    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCActiveOverrideRecordKeys = activeKeys;
    pthread_mutex_unlock(&YTABCRegistryMutex);
}

void YTABCRuntimeRegistryStart(NSUserDefaults *defaults) {
    YTABCInitializeRegistry();
    NSUserDefaults *selectedDefaults = defaults ?: NSUserDefaults.standardUserDefaults;
    id observerToRemove = nil;

    pthread_mutex_lock(&YTABCRegistryMutex);
    if (YTABCDefaults != selectedDefaults) {
        observerToRemove = YTABCDefaultsObserver;
        YTABCDefaultsObserver = nil;
        YTABCDefaults = selectedDefaults;
    }
    BOOL needsObserver = YTABCDefaultsObserver == nil;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    if (observerToRemove) {
        [NSNotificationCenter.defaultCenter removeObserver:observerToRemove];
    }
    if (needsObserver) {
        id newObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSUserDefaultsDidChangeNotification
                       object:selectedDefaults
                        queue:nil
                   usingBlock:^(__unused NSNotification *notification) {
            YTABCRuntimeApplyPersistedOverrides();
        }];
        pthread_mutex_lock(&YTABCRegistryMutex);
        if (YTABCDefaults == selectedDefaults && !YTABCDefaultsObserver) {
            YTABCDefaultsObserver = newObserver;
            newObserver = nil;
        }
        pthread_mutex_unlock(&YTABCRegistryMutex);
        if (newObserver) {
            [NSNotificationCenter.defaultCenter removeObserver:newObserver];
        }
    }
}

BOOL YTABCRuntimeRegisterConfigInstance(id instance) {
    if (!instance) return NO;
    YTABCInitializeRegistry();
    Class ownerClass = YTABCCanonicalConfigOwnerClass(instance);
    if (!ownerClass) {
        NSLog(@"[YTABConfig Runtime] Refusing unknown config class %@",
              NSStringFromClass(object_getClass(instance)));
        return NO;
    }

    NSString *className = NSStringFromClass(ownerClass);
    pthread_mutex_lock(&YTABCRegistryMutex);
    [YTABCInstancesByClassName setObject:instance forKey:className];
    for (YTABCRuntimeFlagRecord *record in YTABCRecords.allValues) {
        if ([record.className isEqualToString:className]) record.instance = instance;
    }
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return YES;
}

NSUInteger YTABCRuntimeDiscoverFlags(void) {
    YTABCInitializeRegistry();
    NSMutableDictionary<NSString *, id> *instances = [NSMutableDictionary dictionary];
    pthread_mutex_lock(&YTABCRegistryMutex);
    for (NSString *className in YTABCCanonicalConfigClassNames()) {
        id instance = [YTABCInstancesByClassName objectForKey:className];
        if (instance) instances[className] = instance;
    }
    pthread_mutex_unlock(&YTABCRegistryMutex);

    NSUInteger discoveredCount = 0;
    for (NSString *className in YTABCCanonicalConfigClassNames()) {
        id instance = instances[className];
        if (!instance) continue;
        Class ownerClass = YTABCCanonicalConfigOwnerClass(instance);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(ownerClass, &methodCount);
        for (unsigned int index = 0; index < methodCount; ++index) {
            Method method = methods[index];
            if (!YTABCMethodIsEligible(method)) continue;
            NSString *selectorName = NSStringFromSelector(method_getName(method));
            if (YTABCSelectorIsExcluded(selectorName)) continue;
            if (YTABCEnsureRecord(className, selectorName)) discoveredCount++;
        }
        free(methods);
    }

    YTABCRuntimeApplyPersistedOverrides();
    NSLog(@"[YTABConfig Runtime] Lazily discovered %lu live BOOL flags",
          (unsigned long)discoveredCount);
    return discoveredCount;
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCRuntimeValuesSnapshot(void) {
    YTABCInitializeRegistry();
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *values =
        [NSMutableDictionary dictionary];
    for (NSString *className in YTABCCanonicalConfigClassNames()) {
        values[className] = [NSMutableDictionary dictionary];
    }

    pthread_mutex_lock(&YTABCRegistryMutex);
    for (YTABCRuntimeFlagRecord *record in YTABCRecords.allValues) {
        values[record.className][record.selectorName] =
            record.hasNativeValue ? @(record.nativeValue) : NSNull.null;
    }
    pthread_mutex_unlock(&YTABCRegistryMutex);

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *snapshot =
        [NSMutableDictionary dictionaryWithCapacity:values.count];
    [values enumerateKeysAndObjectsUsingBlock:
        ^(NSString *className, NSMutableDictionary<NSString *, id> *classValues, BOOL *stop) {
        snapshot[className] = classValues.copy;
    }];
    return snapshot.copy;
}

BOOL YTABCRuntimeHasFlag(NSString *className, NSString *selectorName) {
    return YTABCValidatedRecord(className, selectorName) != nil;
}

BOOL YTABCSetOverride(NSString *className, NSString *selectorName, BOOL value) {
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) {
        NSLog(@"[YTABConfig Runtime] Rejected override for unknown flag %@.%@",
              className, selectorName);
        return NO;
    }

    [YTABCDefaultsSnapshot() setBool:value forKey:record.preferenceKey];
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeOverrideState state = record.overrideState;
    YTABCRuntimeOverrideStateSetOverride(&state, value);
    record.overrideState = state;
    [YTABCActiveOverrideRecordKeys addObject:YTABCRecordKey(className, selectorName)];
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return YTABCInstallHookForRecord(record);
}

BOOL YTABCClearOverride(NSString *className, NSString *selectorName) {
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) {
        NSLog(@"[YTABConfig Runtime] Rejected clear for unknown flag %@.%@",
              className, selectorName);
        return NO;
    }

    [YTABCDefaultsSnapshot() removeObjectForKey:record.preferenceKey];
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeOverrideState state = record.overrideState;
    YTABCRuntimeOverrideStateClearOverride(&state);
    record.overrideState = state;
    [YTABCActiveOverrideRecordKeys removeObject:YTABCRecordKey(className, selectorName)];
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return YES;
}

NSNumber * _Nullable YTABCNativeValue(NSString *className, NSString *selectorName) {
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) return nil;
    return YTABCSampleRecordNativeValue(record, YTABCCurrentTimestamp());
}

NSNumber * _Nullable YTABCOverrideValue(NSString *className, NSString *selectorName) {
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) return nil;
    BOOL value = NO;
    id storedValue = [YTABCDefaultsSnapshot() objectForKey:record.preferenceKey];
    return YTABCValidStoredBoolean(storedValue, &value) ? @(value) : nil;
}

NSNumber * _Nullable YTABCEffectiveValue(NSString *className, NSString *selectorName) {
    NSNumber *override = YTABCOverrideValue(className, selectorName);
    return override ?: YTABCNativeValue(className, selectorName);
}

static void YTABCRefreshNativeBatch(
    NSArray<YTABCRuntimeFlagRecord *> *records,
    NSUInteger startIndex,
    NSString *capturedAt,
    dispatch_block_t _Nullable completion
) {
    NSCAssert(NSThread.isMainThread, @"Runtime config getters must be sampled on the main thread");
    NSUInteger endIndex = MIN(startIndex + YTABCNativeRefreshBatchSize, records.count);
    @autoreleasepool {
        for (NSUInteger index = startIndex; index < endIndex; ++index) {
            YTABCSampleRecordNativeValue(records[index], capturedAt);
        }
    }
    if (endIndex < records.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTABCRefreshNativeBatch(records, endIndex, capturedAt, completion);
        });
    } else if (completion) {
        completion();
    }
}

void YTABCRuntimeRefreshAllNativeValues(dispatch_block_t completion) {
    YTABCInitializeRegistry();
    dispatch_block_t start = ^{
        pthread_mutex_lock(&YTABCRegistryMutex);
        NSArray<YTABCRuntimeFlagRecord *> *records = YTABCRecords.allValues.copy;
        pthread_mutex_unlock(&YTABCRegistryMutex);
        YTABCRefreshNativeBatch(records, 0, YTABCCurrentTimestamp(), completion);
    };
    if (NSThread.isMainThread) start();
    else dispatch_async(dispatch_get_main_queue(), start);
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCRuntimeSnapshot(void) {
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    NSArray<YTABCRuntimeFlagRecord *> *records = YTABCRecords.allValues.copy;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithCapacity:records.count];
    for (YTABCRuntimeFlagRecord *record in records) {
        NSNumber *override = YTABCOverrideValue(record.className, record.selectorName);
        pthread_mutex_lock(&YTABCRegistryMutex);
        BOOL hookInstalled = record.overrideState.hookInstalled;
        NSNumber *native = record.hasNativeValue ? @(record.nativeValue) : nil;
        NSString *nativeCapturedAt = record.nativeCapturedAt;
        pthread_mutex_unlock(&YTABCRegistryMutex);
        NSNumber *effective = override ?: native;
        snapshot[YTABCRecordKey(record.className, record.selectorName)] = @{
            @"class": record.className,
            @"selector": record.selectorName,
            @"preferenceKey": record.preferenceKey,
            @"native": native ?: NSNull.null,
            @"nativeCapturedAt": nativeCapturedAt ?: NSNull.null,
            @"override": override ?: NSNull.null,
            @"effective": effective ?: NSNull.null,
            @"hookInstalled": @(hookInstalled)
        };
    }
    return snapshot.copy;
}

NS_ASSUME_NONNULL_END
