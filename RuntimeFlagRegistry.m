#import "RuntimeFlagRegistry.h"

#import "RuntimeOverrideState.h"

#import <objc/message.h>
#import <pthread.h>
#import <substrate.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const YTABCPersistencePrefix = @"YTABC";
static NSString * const YTABCExactBoolMethodEncoding = @"B16@0:8";
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
@property(nonatomic, assign) IMP discoveredIMP;
@property(nonatomic, assign, nullable) IMP originalIMP;
@property(nonatomic, weak, nullable) id instance;
@property(nonatomic, assign) YTABCRuntimeOverrideState overrideState;
@end

@implementation YTABCRuntimeFlagRecord
@end

static NSMutableDictionary<NSString *, YTABCRuntimeFlagRecord *> *YTABCRecords;
static NSUserDefaults *YTABCDefaults;
static id _Nullable YTABCDefaultsObserver;
static pthread_mutex_t YTABCRegistryMutex;
static dispatch_once_t YTABCRegistryOnce;

static void YTABCInitializeRegistry(void) {
    dispatch_once(&YTABCRegistryOnce, ^{
        YTABCRecords = [NSMutableDictionary dictionary];
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

static BOOL YTABCValidStoredBoolean(id value, BOOL *result) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double numericValue = [value doubleValue];
    if (numericValue != 0.0 && numericValue != 1.0) return NO;
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL YTABCInvokeBOOL(IMP implementation, id target, SEL selector) {
    if (!implementation || !target || !selector) return NO;
    return ((BOOL (*)(id, SEL))implementation)(target, selector);
}

static NSUserDefaults *YTABCDefaultsSnapshot(void) {
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

static BOOL YTABCRecordConflictsWithOwnerHierarchy(Class ownerClass, SEL selector) {
    for (YTABCRuntimeFlagRecord *record in YTABCRecords.allValues) {
        if (record.selector != selector || record.ownerClass == ownerClass) continue;
        if (YTABCClassIsInHierarchy(ownerClass, record.ownerClass) ||
            YTABCClassIsInHierarchy(record.ownerClass, ownerClass)) {
            return YES;
        }
    }
    return NO;
}

static YTABCRuntimeFlagRecord *YTABCRecordForRuntimeReceiver(id receiver, SEL selector) {
    NSString *selectorName = NSStringFromSelector(selector);
    for (Class currentClass = object_getClass(receiver);
         currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        YTABCRuntimeFlagRecord *record = YTABCRecords[YTABCRecordKey(NSStringFromClass(currentClass), selectorName)];
        if (record) return record;
    }
    return nil;
}

static BOOL YTABCRuntimeHook(id self, SEL selector) {
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeFlagRecord *record = YTABCRecordForRuntimeReceiver(self, selector);
    if (!record) {
        pthread_mutex_unlock(&YTABCRegistryMutex);
        NSLog(@"[YTABConfig Runtime] Missing record for %@.%@", NSStringFromClass([self class]), NSStringFromSelector(selector));
        return NO;
    }

    BOOL overrideValue = NO;
    id storedValue = [YTABCDefaults objectForKey:record.preferenceKey];
    YTABCRuntimeOverrideState state = record.overrideState;
    if (YTABCValidStoredBoolean(storedValue, &overrideValue)) {
        YTABCRuntimeOverrideStateSetOverride(&state, overrideValue);
    } else {
        YTABCRuntimeOverrideStateClearOverride(&state);
    }
    record.overrideState = state;
    IMP originalIMP = record.originalIMP ?: record.discoveredIMP;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    if (state.hasOverride) return state.overrideValue;
    return YTABCInvokeBOOL(originalIMP, self, selector);
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

    NSLog(@"[YTABConfig Runtime] Lazily hooked %@", record.preferenceKey);
    return YES;
}

static void YTABCReconcilePersistedOverrides(void) {
    YTABCInitializeRegistry();
    pthread_mutex_lock(&YTABCRegistryMutex);
    NSArray<YTABCRuntimeFlagRecord *> *records = YTABCRecords.allValues.copy;
    NSUserDefaults *defaults = YTABCDefaults;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    for (YTABCRuntimeFlagRecord *record in records) {
        BOOL value = NO;
        id storedValue = [defaults objectForKey:record.preferenceKey];
        if (!YTABCValidStoredBoolean(storedValue, &value)) {
            if (storedValue) {
                NSLog(@"[YTABConfig Runtime] Ignoring invalid override value for %@", record.preferenceKey);
            }
            pthread_mutex_lock(&YTABCRegistryMutex);
            YTABCRuntimeOverrideState state = record.overrideState;
            YTABCRuntimeOverrideStateClearOverride(&state);
            record.overrideState = state;
            pthread_mutex_unlock(&YTABCRegistryMutex);
            continue;
        }

        pthread_mutex_lock(&YTABCRegistryMutex);
        YTABCRuntimeOverrideState state = record.overrideState;
        YTABCRuntimeOverrideStateSetOverride(&state, value);
        record.overrideState = state;
        pthread_mutex_unlock(&YTABCRegistryMutex);
        YTABCInstallHookForRecord(record);
    }
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
            YTABCReconcilePersistedOverrides();
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
    YTABCReconcilePersistedOverrides();
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

static BOOL YTABCRefreshRecordNativeSample(YTABCRuntimeFlagRecord *record, id instance) {
    pthread_mutex_lock(&YTABCRegistryMutex);
    IMP implementation = record.originalIMP ?: record.discoveredIMP;
    SEL selector = record.selector;
    pthread_mutex_unlock(&YTABCRegistryMutex);

    BOOL nativeValue = YTABCInvokeBOOL(implementation, instance, selector);
    pthread_mutex_lock(&YTABCRegistryMutex);
    record.instance = instance;
    record.nativeValue = nativeValue;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return nativeValue;
}

void YTABCRuntimeRegisterConfigInstance(
    id instance,
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *nativeCatalog
) {
    if (!instance || !nativeCatalog) {
        NSLog(@"[YTABConfig Runtime] Refusing to register a nil instance or catalog");
        return;
    }

    YTABCInitializeRegistry();
    Class ownerClass = YTABCCanonicalConfigOwnerClass(instance);
    if (!ownerClass) {
        NSLog(@"[YTABConfig Runtime] Refusing unknown config class %@", NSStringFromClass(object_getClass(instance)));
        return;
    }
    NSString *className = NSStringFromClass(ownerClass);
    NSMutableDictionary<NSString *, NSNumber *> *classCatalog = [NSMutableDictionary dictionary];

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(ownerClass, &methodCount);
    for (unsigned int index = 0; index < methodCount; ++index) {
        Method method = methods[index];
        if (!YTABCMethodIsEligible(method)) continue;

        SEL selector = method_getName(method);
        NSString *selectorName = NSStringFromSelector(selector);
        if (YTABCSelectorIsExcluded(selectorName) || classCatalog[selectorName]) continue;

        NSString *recordKey = YTABCRecordKey(className, selectorName);
        pthread_mutex_lock(&YTABCRegistryMutex);
        YTABCRuntimeFlagRecord *existingRecord = YTABCRecords[recordKey];
        pthread_mutex_unlock(&YTABCRegistryMutex);
        if (existingRecord) {
            classCatalog[selectorName] = @(YTABCRefreshRecordNativeSample(existingRecord, instance));
            continue;
        }

        IMP discoveredIMP = method_getImplementation(method);
        BOOL nativeValue = YTABCInvokeBOOL(discoveredIMP, instance, selector);

        YTABCRuntimeFlagRecord *record = [YTABCRuntimeFlagRecord new];
        record.ownerClass = ownerClass;
        record.selector = selector;
        record.className = className;
        record.selectorName = selectorName;
        record.preferenceKey = YTABCOverrideKey(className, selectorName);
        record.nativeValue = nativeValue;
        record.discoveredIMP = discoveredIMP;
        record.instance = instance;
        record.overrideState = YTABCRuntimeOverrideStateMake();

        pthread_mutex_lock(&YTABCRegistryMutex);
        existingRecord = YTABCRecords[recordKey];
        BOOL hierarchyConflict = YTABCRecordConflictsWithOwnerHierarchy(ownerClass, selector);
        if (!existingRecord && !hierarchyConflict) YTABCRecords[recordKey] = record;
        pthread_mutex_unlock(&YTABCRegistryMutex);

        if (existingRecord) {
            nativeValue = YTABCRefreshRecordNativeSample(existingRecord, instance);
        } else if (hierarchyConflict) {
            NSLog(@"[YTABConfig Runtime] Skipping ambiguous hierarchy selector %@.%@", className, selectorName);
            continue;
        }
        classCatalog[selectorName] = @(nativeValue);
    }
    free(methods);

    nativeCatalog[className] = classCatalog;
    NSLog(@"[YTABConfig Runtime] Discovered %lu native BOOL flags on %@",
          (unsigned long)classCatalog.count, className);
    YTABCReconcilePersistedOverrides();
}

static YTABCRuntimeFlagRecord *YTABCValidatedRecord(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) return nil;
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeFlagRecord *record = YTABCRecords[YTABCRecordKey(className, selectorName)];
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return record;
}

BOOL YTABCSetOverride(NSString *className, NSString *selectorName, BOOL value) {
    YTABCInitializeRegistry();
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) {
        NSLog(@"[YTABConfig Runtime] Rejected override for unknown flag %@.%@", className, selectorName);
        return NO;
    }

    [YTABCDefaultsSnapshot() setBool:value forKey:record.preferenceKey];
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeOverrideState state = record.overrideState;
    YTABCRuntimeOverrideStateSetOverride(&state, value);
    record.overrideState = state;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return YTABCInstallHookForRecord(record);
}

BOOL YTABCClearOverride(NSString *className, NSString *selectorName) {
    YTABCInitializeRegistry();
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) {
        NSLog(@"[YTABConfig Runtime] Rejected clear for unknown flag %@.%@", className, selectorName);
        return NO;
    }

    [YTABCDefaultsSnapshot() removeObjectForKey:record.preferenceKey];
    pthread_mutex_lock(&YTABCRegistryMutex);
    YTABCRuntimeOverrideState state = record.overrideState;
    YTABCRuntimeOverrideStateClearOverride(&state);
    record.overrideState = state;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return YES;
}

NSNumber *YTABCNativeValue(NSString *className, NSString *selectorName) {
    YTABCInitializeRegistry();
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) return nil;
    pthread_mutex_lock(&YTABCRegistryMutex);
    BOOL nativeValue = record.nativeValue;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return @(nativeValue);
}

NSNumber *YTABCOverrideValue(NSString *className, NSString *selectorName) {
    YTABCInitializeRegistry();
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) return nil;
    BOOL value = NO;
    return YTABCValidStoredBoolean([YTABCDefaultsSnapshot() objectForKey:record.preferenceKey], &value) ? @(value) : nil;
}

NSNumber *YTABCEffectiveValue(NSString *className, NSString *selectorName) {
    YTABCInitializeRegistry();
    YTABCRuntimeFlagRecord *record = YTABCValidatedRecord(className, selectorName);
    if (!record) return nil;
    NSNumber *override = YTABCOverrideValue(className, selectorName);
    if (override) return override;

    pthread_mutex_lock(&YTABCRegistryMutex);
    id instance = record.instance;
    IMP implementation = record.originalIMP ?: record.discoveredIMP;
    SEL selector = record.selector;
    BOOL sampledNativeValue = record.nativeValue;
    pthread_mutex_unlock(&YTABCRegistryMutex);
    return instance ? @(YTABCInvokeBOOL(implementation, instance, selector)) : @(sampledNativeValue);
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
        BOOL nativeValue = record.nativeValue;
        pthread_mutex_unlock(&YTABCRegistryMutex);
        snapshot[YTABCRecordKey(record.className, record.selectorName)] = @{
            @"class": record.className,
            @"selector": record.selectorName,
            @"preferenceKey": record.preferenceKey,
            @"native": @(nativeValue),
            @"override": override ?: NSNull.null,
            @"effective": YTABCEffectiveValue(record.className, record.selectorName) ?: NSNull.null,
            @"hookInstalled": @(hookInstalled)
        };
    }
    return snapshot.copy;
}

NS_ASSUME_NONNULL_END
