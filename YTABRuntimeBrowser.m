#import "YTABRuntimeBrowser.h"
#import "RuntimeFlagRegistry.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>

static NSString * const YTABRuntimeBrowserOverridesKey = @"YTABCRuntimeBrowserOverrides";

// The IPA bundles sideload tweaks in Frameworks/, so that directory must
// never be misrepresented as a source of official YouTube Boolean flags.
typedef NS_ENUM(NSInteger, YTABRuntimeImageScope) {
    YTABRuntimeImageScopeFlags = 0,      // original launch-captured config BOOLs
    YTABRuntimeImageScopeMethods = 1,    // general runtime methods, not flags
    YTABRuntimeImageScopeOverrides = 2,  // only overridden entries
    YTABRuntimeImageScopeAll = 3,        // combined config flags + native BOOLs
};

typedef NS_ENUM(NSInteger, YTABRuntimeArgumentKind) {
    YTABRuntimeArgumentKindNone = 0,
    YTABRuntimeArgumentKindObject = 1,
    YTABRuntimeArgumentKindInteger = 2,
    YTABRuntimeArgumentKindUnsupported = -1,
};

@interface YTABRuntimeMethod : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeEncoding;
@property(nonatomic, copy) NSString *imageName;
@property(nonatomic) BOOL classMethod;
@property(nonatomic) YTABRuntimeArgumentKind argumentKind;
@property(nonatomic) BOOL configFlag;
@property(nonatomic, readonly) NSString *patchKey;
@end

@implementation YTABRuntimeMethod
- (NSString *)patchKey {
    return [NSString stringWithFormat:@"%@%@#%@",
            self.classMethod ? @"+" : @"", self.className, self.selectorName];
}
@end

static NSDictionary<NSString *, NSNumber *> *sYTABRuntimeOverrideCache;
static NSMutableSet<NSString *> *sYTABRuntimeInstalledKeys;
static NSMutableDictionary<NSString *, NSNumber *> *sYTABRuntimeObservedNative;
static BOOL sYTABRuntimeSampleRefreshPending;
// The generic selector inventory is immutable within the current YouTube process.
// Cache it after its first complete scan instead of re-enumerating on every tab switch.
static NSArray<YTABRuntimeMethod *> *sYTABRuntimeMethodCatalog;
static NSMutableDictionary<NSString *, NSArray<YTABRuntimeMethod *> *> *sYTABRuntimeFamilyCatalog;
static NSString *YTABRuntimeFamilyForClassName(NSString *name);
static dispatch_queue_t YTABRuntimeInventoryQueue(void);
static BOOL sYTABRuntimeAutomaticIndexStarted;
static NSMutableArray<YTABRuntimeMethod *> *sYTABRuntimeIncrementalCatalog;
NSString * const YTABRuntimeAutoIndexNotification = @"YTABRuntimeAutoIndexNotification";
NSString * const YTABRuntimeNativeSampleChangedNotification = @"YTABRuntimeNativeSampleChangedNotification";
NSString * const YTABRuntimeInventoryProgressNotification = @"YTABRuntimeInventoryProgressNotification";

static NSDictionary<NSString *, NSNumber *> *YTABRuntimeStoredOverrides(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTABRuntimeBrowserOverridesKey];
    if (![value isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![object isKindOfClass:[NSNumber class]]) return;
        clean[key] = @([(NSNumber *)object boolValue]);
    }];
    return clean.copy;
}

static void YTABRuntimeRefreshOverrideCache(void) {
    sYTABRuntimeOverrideCache = YTABRuntimeStoredOverrides();
}

static NSNumber *YTABRuntimeCachedOverride(NSString *key) {
    id value = sYTABRuntimeOverrideCache[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static void YTABRuntimeRememberNative(NSString *key, BOOL value) {
    if (!key.length) return;
    BOOL shouldPost = NO;
    @synchronized([YTABRuntimeMethod class]) {
        if (!sYTABRuntimeObservedNative)
            sYTABRuntimeObservedNative = [NSMutableDictionary dictionary];
        NSNumber *previous = sYTABRuntimeObservedNative[key];
        if (!previous || previous.boolValue != value) {
            sYTABRuntimeObservedNative[key] = @(value);
            if (!sYTABRuntimeSampleRefreshPending) {
                sYTABRuntimeSampleRefreshPending = YES;
                shouldPost = YES;
            }
        }
    }
    // Coalesce native getter observations into at most one UI refresh per
    // main queue turn. Never force a getter to execute for UI sampling.
    if (shouldPost) dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized([YTABRuntimeMethod class]) {
            sYTABRuntimeSampleRefreshPending = NO;
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTABRuntimeNativeSampleChangedNotification object:nil];
    });
}

static NSNumber *YTABRuntimeObservedNative(NSString *key) {
    @synchronized([YTABRuntimeMethod class]) {
        return sYTABRuntimeObservedNative[key];
    }
}

static YTABRuntimeArgumentKind YTABRuntimeArgumentKindForMethod(Method method) {
    if (!method) return YTABRuntimeArgumentKindUnsupported;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return YTABRuntimeArgumentKindNone;
    if (count != 3) return YTABRuntimeArgumentKindUnsupported;

    char type[32] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    const char *cursor = type;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor == '@' || *cursor == '#' || *cursor == ':') {
        return YTABRuntimeArgumentKindObject;
    }
    if (*cursor && strchr("BcCsSiIlLqQ^*", *cursor)) {
        return YTABRuntimeArgumentKindInteger;
    }
    return YTABRuntimeArgumentKindUnsupported;
}

static BOOL YTABRuntimeMethodSupported(Method method) {
    if (!method) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (!(returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C')) return NO;
    return YTABRuntimeArgumentKindForMethod(method) != YTABRuntimeArgumentKindUnsupported;
}

static BOOL YTABRuntimeSelectorAllowed(Method method) {
    if (!YTABRuntimeMethodSupported(method)) return NO;
    // Main Boolean controls represent zero-argument getters only. Methods
    // requiring an object or integer context have no global current value.
    if (method_getNumberOfArguments(method) != 2) return NO;
    const char *name = sel_getName(method_getName(method));
    if (!name || !*name || strchr(name, ':')) return NO;
    if (!strncmp(name, "set", 3) || !strncmp(name, "init", 4)) return NO;
    static const char *blocked[] = {
        "hash", "retainCount", "isProxy", "isFault", "isFinished",
        "respondsToSelector", "conformsToProtocol", "isMemberOfClass"
    };
    for (NSUInteger index = 0; index < sizeof(blocked) / sizeof(blocked[0]); index++) {
        if (!strcmp(name, blocked[index])) return NO;
    }
    return YES;
}

static BOOL YTABRuntimeIsCapturedConfigKey(NSString *key,
                                             NSString **sourceClass,
                                             NSString **sourceSelector) {
    if (![key isKindOfClass:NSString.class] || [key hasPrefix:@"+"]) return NO;
    NSRange boundary = [key rangeOfString:@"#"];
    if (boundary.location == NSNotFound) return NO;
    NSString *cls = [key substringToIndex:boundary.location];
    if (![@[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"] containsObject:cls])
        return NO;
    NSString *sel = [key substringFromIndex:NSMaxRange(boundary)];
    if (!sel.length || [sel containsString:@":"]) return NO;
    if (sourceClass) *sourceClass = cls;
    if (sourceSelector) *sourceSelector = sel;
    return YES;
}

static BOOL YTABRuntimeParsePatchKey(NSString *key,
                                     NSString **className,
                                     NSString **selectorName,
                                     BOOL *classMethod) {
    if (!key.length) return NO;
    BOOL isClassMethod = [key hasPrefix:@"+"];
    NSString *body = isClassMethod ? [key substringFromIndex:1] : key;
    NSRange separator = [body rangeOfString:@"#"];
    if (separator.location == NSNotFound || separator.location == 0 ||
        NSMaxRange(separator) >= body.length) return NO;
    if (className) *className = [body substringToIndex:separator.location];
    if (selectorName) *selectorName = [body substringFromIndex:NSMaxRange(separator)];
    if (classMethod) *classMethod = isClassMethod;
    return YES;
}

static BOOL YTABRuntimeInstallPatchKey(NSString *key) {
    if (!key.length) return NO;
    @synchronized([YTABRuntimeMethod class]) {
        if (!sYTABRuntimeInstalledKeys) sYTABRuntimeInstalledKeys = [NSMutableSet set];
        if ([sYTABRuntimeInstalledKeys containsObject:key]) return YES;
    }

    NSString *className = nil;
    NSString *selectorName = nil;
    BOOL classMethod = NO;
    if (!YTABRuntimeParsePatchKey(key, &className, &selectorName, &classMethod)) return NO;

    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !selector) return NO;

    Class hookClass = classMethod ? object_getClass(cls) : cls;
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    if (!hookClass || !YTABRuntimeMethodSupported(method)) return NO;

    YTABRuntimeArgumentKind argumentKind = YTABRuntimeArgumentKindForMethod(method);
    NSString *capturedKey = key.copy;
    SEL capturedSelector = selector;
    __block IMP original = NULL;
    IMP replacement = NULL;

    if (argumentKind == YTABRuntimeArgumentKindNone) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            // Force ON/OFF must short-circuit the original implementation.
            // Only System executes the getter and records its native result.
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            if (override) return override.boolValue;
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            return nativeValue;
        });
    } else if (argumentKind == YTABRuntimeArgumentKindObject) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
            // Force ON/OFF must short-circuit the original implementation.
            // Only System executes the getter and records its native result.
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            if (override) return override.boolValue;
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL, id))original)(receiver, capturedSelector, argument)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            return nativeValue;
        });
    } else if (argumentKind == YTABRuntimeArgumentKindInteger) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, uint64_t argument) {
            // Force ON/OFF must short-circuit the original implementation.
            // Only System executes the getter and records its native result.
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            if (override) return override.boolValue;
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL, uint64_t))original)(receiver, capturedSelector, argument)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            return nativeValue;
        });
    }

    if (!replacement) return NO;
    MSHookMessageEx(hookClass, selector, replacement, &original);
    if (!original) return NO;

    @synchronized([YTABRuntimeMethod class]) {
        [sYTABRuntimeInstalledKeys addObject:key];
    }
    return YES;
}

static NSNumber *YTABRuntimeOverrideForKey(NSString *key) {
    // The previous implementation rebuilt the entire NSUserDefaults
    // dictionary for EACH row during applyFilter and table rendering.
    // Use the immutable snapshot refreshed by every local write/restore.
    if (!sYTABRuntimeOverrideCache) YTABRuntimeRefreshOverrideCache();
    return YTABRuntimeCachedOverride(key);
}

static BOOL YTABRuntimeSetOverride(NSNumber *value, NSString *key) {
    if (!key.length) return NO;
    // Install BEFORE writing preferences, otherwise the UI can claim "ON"
    // while the ABI is unsupported or the target class is not loaded.
    if (value && !YTABRuntimeInstallPatchKey(key)) return NO;
    NSMutableDictionary *overrides = [YTABRuntimeStoredOverrides() mutableCopy];
    if (value) overrides[key] = @(value.boolValue);
    else [overrides removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:overrides.copy
                                              forKey:YTABRuntimeBrowserOverridesKey];
    YTABRuntimeRefreshOverrideCache();
    return YES;
}

// Read-only state bridges used by the native UIKit presentation.
BOOL YTABRuntimeBrowserApplyMode(NSString *patchKey, NSInteger mode) {
    if (mode < 0 || mode > 2) return NO;
    NSString *cls = nil, *selector = nil;
    if (YTABRuntimeIsCapturedConfigKey(patchKey, &cls, &selector)) {
        // Reuse the existing one-time config getter snapshot and override
        // engine; never hook the same config getter a second time.
        return mode == 0 ? YTABCClearOverride(cls, selector)
                         : YTABCSetOverride(cls, selector, mode == 2);
    }
    NSNumber *value = mode == 0 ? nil : @(mode == 2);
    return YTABRuntimeSetOverride(value, patchKey);
}

NSNumber *YTABRuntimeBrowserNativeSample(NSString *patchKey) {
    NSString *cls = nil, *selector = nil;
    if (YTABRuntimeIsCapturedConfigKey(patchKey, &cls, &selector))
        return YTABCNativeValue(cls, selector);
    return YTABRuntimeObservedNative(patchKey);
}

NSNumber *YTABRuntimeBrowserOverrideValue(NSString *patchKey) {
    NSString *cls = nil, *selector = nil;
    if (YTABRuntimeIsCapturedConfigKey(patchKey, &cls, &selector))
        return YTABCOverrideValue(cls, selector);
    return YTABRuntimeOverrideForKey(patchKey);
}

BOOL YTABRuntimeBrowserPatchInstalled(NSString *patchKey) {
    NSString *cls = nil, *selector = nil;
    if (YTABRuntimeIsCapturedConfigKey(patchKey, &cls, &selector))
        return YTABCRuntimeHasFlag(cls, selector);
    @synchronized([YTABRuntimeMethod class]) {
        return patchKey.length && [sYTABRuntimeInstalledKeys containsObject:patchKey];
    }
}

// Passive observation is optional. It intercepts an eligible getter only
// after an explicit user action; it never calls arbitrary methods just to
// fill in a switch state. A getter can depend on receiver / arguments,
// so the recorded BOOL is the last native result, not a global constant.
BOOL YTABRuntimeBrowserObserveKey(NSString *patchKey) {
    NSString *cls = nil, *selector = nil;
    if (YTABRuntimeIsCapturedConfigKey(patchKey, &cls, &selector))
        return YTABCRuntimeHasFlag(cls, selector);
    return YTABRuntimeInstallPatchKey(patchKey);
}

static void YTABRuntimeClearOverrides(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTABRuntimeBrowserOverridesKey];
    YTABRuntimeRefreshOverrideCache();
}

void YTABRuntimeBrowserReinstallPersistedHooks(void) {
    YTABRuntimeRefreshOverrideCache();
    for (NSString *key in sYTABRuntimeOverrideCache) {
        YTABRuntimeInstallPatchKey(key);
    }
}

NSUInteger YTABRuntimeBrowserPersistedOverrideCount(void) {
    return YTABRuntimeStoredOverrides().count;
}

static BOOL YTABRuntimeClassExcluded(NSString *className) {
    static NSSet<NSString *> *excluded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"]];
    });
    return [excluded containsObject:className];
}

// Only the primary YouTube Mach-O is scanned for generic runtime methods.
// In this sideloaded IPA Frameworks/ contains mostly third-party tweak dylibs
// and a Widevine DRM binary, not a second catalog of YouTube feature flags.
static BOOL YTABRuntimeIsMainExecutableClass(Class cls) {
    const char *path = cls ? class_getImageName(cls) : NULL;
    if (!path) return NO;
    NSString *image = [NSString stringWithUTF8String:path];
    return [image isEqualToString:[NSBundle mainBundle].executablePath];
}

static NSArray<YTABRuntimeMethod *> *YTABRuntimeDiscoverMethods(
    YTABRuntimeImageScope scope, NSString *family, BOOL (^cancelled)(void),
    void (^onBatch)(NSArray<YTABRuntimeMethod *> *)) {
    if (scope == YTABRuntimeImageScopeMethods) {
        @synchronized([YTABRuntimeMethod class]) {
            if (sYTABRuntimeMethodCatalog) return sYTABRuntimeMethodCatalog;
        }
    }
    NSMutableArray<YTABRuntimeMethod *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // These values already exist as original method results from the
    // PoomSmart-compatible launch capture. No new IMP and no fabricated BOOL.
    if (scope != YTABRuntimeImageScopeMethods) {
        NSDictionary<NSString *, NSDictionary<NSString *, id> *> *captured =
            YTABCRuntimeValuesSnapshot();
        for (NSString *className in @[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"]) {
            NSDictionary<NSString *, id> *values = captured[className];
            for (NSString *selector in values) {
                if (![values[selector] isKindOfClass:NSNumber.class]) continue;
                if (scope == YTABRuntimeImageScopeOverrides &&
                    !YTABCOverrideValue(className, selector)) continue;
                YTABRuntimeMethod *entry = [YTABRuntimeMethod new];
                entry.className = className;
                entry.selectorName = selector;
                entry.typeEncoding = @"B16@0:8";
                entry.imageName = @"Captured config";
                entry.configFlag = YES;
                [results addObject:entry];
                [seen addObject:entry.patchKey];
            }
        }
        if (scope == YTABRuntimeImageScopeFlags) {
            [results sortUsingComparator:^NSComparisonResult(YTABRuntimeMethod *a,
                                                               YTABRuntimeMethod *b) {
                NSComparisonResult r = [a.className compare:b.className];
                return r == NSOrderedSame
                    ? [a.selectorName localizedCaseInsensitiveCompare:b.selectorName] : r;
            }];
            return results.copy;
        }
    }

    // Saved overrides should not trigger a full application class scan.
    if (scope == YTABRuntimeImageScopeOverrides) {
        NSDictionary<NSString *, NSNumber *> *stored = YTABRuntimeStoredOverrides();
        for (NSString *key in stored) {
            if ([seen containsObject:key]) continue;
            NSString *className = nil, *selectorName = nil;
            BOOL classMethod = NO;
            if (!YTABRuntimeParsePatchKey(key, &className, &selectorName, &classMethod))
                continue;
            Class cls = NSClassFromString(className);
            if (!cls || !YTABRuntimeIsMainExecutableClass(cls)
                || YTABRuntimeClassExcluded(className)) continue;
            SEL selector = NSSelectorFromString(selectorName);
            Method method = classMethod ? class_getClassMethod(cls, selector)
                                        : class_getInstanceMethod(cls, selector);
            // Historical overrides can include selectors with arguments.
            // Keep them in Overrides so they can still be reset, while
            // excluding new argument-taking selectors from All BOOLs.
            if (!YTABRuntimeMethodSupported(method)) continue;
            YTABRuntimeMethod *entry = [YTABRuntimeMethod new];
            entry.className = className;
            entry.selectorName = selectorName;
            entry.classMethod = classMethod;
            entry.argumentKind = YTABRuntimeArgumentKindForMethod(method);
            entry.typeEncoding = [NSString stringWithUTF8String:
                method_getTypeEncoding(method) ?: ""];
            entry.imageName = @"YouTube runtime";
            [results addObject:entry];
            [seen addObject:key];
        }
        [results sortUsingComparator:^NSComparisonResult(YTABRuntimeMethod *a,
                                                           YTABRuntimeMethod *b) {
            NSComparisonResult order = [a.className localizedCaseInsensitiveCompare:b.className];
            return order == NSOrderedSame
                ? [a.selectorName localizedCaseInsensitiveCompare:b.selectorName] : order;
        }];
        return results.copy;
    }

    // The unified controls view starts with captured config BOOLs and appends
    // compatible Objective-C BOOL getters. Cache the generic inventory so
    // switching tabs never repeats an expensive class sweep.
    if (scope == YTABRuntimeImageScopeAll) {
        NSArray<YTABRuntimeMethod *> *cached = nil;
        @synchronized([YTABRuntimeMethod class]) {
            cached = (!family.length || [family isEqualToString:@"Runtime"])
                ? sYTABRuntimeMethodCatalog : sYTABRuntimeFamilyCatalog[family];
        }
        if (cached) {
            for (YTABRuntimeMethod *method in cached) {
                if (![seen containsObject:method.patchKey]) {
                    [seen addObject:method.patchKey];
                    [results addObject:method];
                }
            }
            [results sortUsingComparator:^NSComparisonResult(
                YTABRuntimeMethod *a, YTABRuntimeMethod *b) {
                NSComparisonResult order =
                    [a.className localizedCaseInsensitiveCompare:b.className];
                return order == NSOrderedSame
                    ? [a.selectorName localizedCaseInsensitiveCompare:b.selectorName]
                    : order;
            }];
            return results.copy;
        }
        // Launch-captured flags have already been published by the fast
        // stage in loadMethods. Never send duplicate table reloads here.
    }

    // The generic method inventory is deliberately segregated from flags:
    // selectors with arguments or arbitrary receivers cannot have one
    // global current BOOL until a real invocation has been observed.
    // The YouTube executable is the only generic-method source. Query its
    // image directly first instead of inspecting every injected/system class.
    // Fall back to the global class list if dyld cannot resolve the image.
    // Critical: NEVER place ObjC Class objects in Foundation collections.
    // YouTube includes ObjC runtime root classes whose metaclasses do not
    // implement +retain. NSMutableArray insertObject:atIndex: retains the
    // class object and raises an unrecognized-selector SIGTRAP on the worker
    // queue. Both supplied 2026-11-11 crash logs faulted at that call.
    // Store NSString class names (retainable objects) and resolve Class only
    // when inspecting each entry. Keep the worker scan read-only.
    BOOL limitedToFamily = (scope == YTABRuntimeImageScopeAll &&
        family.length && ![family isEqualToString:@"Runtime"]);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    unsigned int imageClassCount = 0;
    const char **imageNames = objc_copyClassNamesForImage(
        [NSBundle mainBundle].executablePath.fileSystemRepresentation, &imageClassCount);
    if (imageNames && imageClassCount) {
        for (unsigned int index = 0; index < imageClassCount; ++index) {
            const char *name = imageNames[index];
            if (!name || !name[0]) continue;
            NSString *className = [NSString stringWithUTF8String:name];
            if (!className.length || (limitedToFamily &&
                ![YTABRuntimeFamilyForClassName(className) isEqualToString:family]))
                continue;
            Class cls = objc_getClass(name);
            if (cls && YTABRuntimeIsMainExecutableClass(cls))
                [candidates addObject:className];
        }
    } else {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int index = 0; classes && index < classCount; ++index) {
            Class cls = classes[index];
            NSString *className = cls ? NSStringFromClass(cls) : nil;
            if (!className.length || (limitedToFamily &&
                ![YTABRuntimeFamilyForClassName(className) isEqualToString:family]))
                continue;
            if (YTABRuntimeIsMainExecutableClass(cls))
                [candidates addObject:className];
        }
        if (classes) free(classes);
    }
    if (imageNames) free(imageNames);
    NSUInteger scannedClasses = 0, totalClasses = candidates.count;
    NSMutableArray<YTABRuntimeMethod *> *pendingBatch = [NSMutableArray array];
    for (NSString *className in candidates) {
        if (cancelled && cancelled()) return @[];
        scannedClasses++;
        // No per-class main-thread notifications. UI already shows the
        // native snapshot while background indexing runs.
        if (!className.length || YTABRuntimeClassExcluded(className)) continue;
        Class cls = NSClassFromString(className);
        if (!cls || !YTABRuntimeIsMainExecutableClass(cls)) continue;
        for (NSUInteger pass = 0; pass < 2; pass++) {
            BOOL isClassMethod = pass == 1;
            Class owner = isClassMethod ? object_getClass(cls) : cls;
            if (!owner) continue;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(owner, &count);
            for (unsigned int i = 0; methods && i < count; ++i) {
                Method method = methods[i];
                if (!YTABRuntimeSelectorAllowed(method)) continue;
                NSString *selector = NSStringFromSelector(method_getName(method));
                NSString *key = [NSString stringWithFormat:@"%@%@#%@",
                                 isClassMethod ? @"+" : @"", className, selector];
                if ([seen containsObject:key]) continue;
                // A generic override-only query returned before enumeration.
                [seen addObject:key];
                YTABRuntimeMethod *entry = [YTABRuntimeMethod new];
                entry.className = className;
                entry.selectorName = selector;
                entry.classMethod = isClassMethod;
                entry.argumentKind = YTABRuntimeArgumentKindForMethod(method);
                entry.typeEncoding = [NSString stringWithUTF8String:
                                        method_getTypeEncoding(method) ?: ""];
                entry.imageName = @"YouTube runtime";
                [results addObject:entry];
                if (onBatch) [pendingBatch addObject:entry];
            }
            if (methods) free(methods);
        }
        // Emit bounded DELTAS, never a growing copy of the full catalog.
        // Each dispatch is independent of current category and search text.
        if (onBatch && pendingBatch.count &&
            (scannedClasses % 1500 == 0 || pendingBatch.count >= 4000)) {
            onBatch(pendingBatch.copy);
            [pendingBatch removeAllObjects];
        }
    }
    if (onBatch && pendingBatch.count) onBatch(pendingBatch.copy);
    [results sortUsingComparator:^NSComparisonResult(YTABRuntimeMethod *a,
                                                       YTABRuntimeMethod *b) {
        NSComparisonResult clsResult =
            [a.className localizedCaseInsensitiveCompare:b.className];
        if (clsResult != NSOrderedSame) return clsResult;
        if (a.classMethod != b.classMethod)
            return a.classMethod ? NSOrderedAscending : NSOrderedDescending;
        return [a.selectorName localizedCaseInsensitiveCompare:b.selectorName];
    }];
    NSArray<YTABRuntimeMethod *> *complete = results.copy;
    if (scope == YTABRuntimeImageScopeMethods ||
        scope == YTABRuntimeImageScopeAll) {
        // Don't put launch-captured flags into the generic catalog: they
        // must be reread from the current session on each combined load.
        NSMutableArray<YTABRuntimeMethod *> *generic = [NSMutableArray array];
        for (YTABRuntimeMethod *method in complete)
            if (!method.configFlag) [generic addObject:method];
        @synchronized([YTABRuntimeMethod class]) {
            if (!family.length || [family isEqualToString:@"Runtime"]) {
                sYTABRuntimeMethodCatalog = generic.copy;
            } else {
                if (!sYTABRuntimeFamilyCatalog)
                    sYTABRuntimeFamilyCatalog = [NSMutableDictionary dictionary];
                sYTABRuntimeFamilyCatalog[family] = generic.copy;
            }
        }
    }
    return complete;
}

// Exactly one automatic enumeration for this process. It starts after the
// snapshot request has been queued, continues while any category is shown,
// and publishes bounded method batches to any open Runtime Browser.
static void YTABRuntimeStartAutomaticIndex(void) {
    @synchronized([YTABRuntimeMethod class]) {
        if (sYTABRuntimeAutomaticIndexStarted || sYTABRuntimeMethodCatalog) return;
        sYTABRuntimeAutomaticIndexStarted = YES;
        sYTABRuntimeIncrementalCatalog = [NSMutableArray array];
    }
    dispatch_async(YTABRuntimeInventoryQueue(), ^{
        YTABRuntimeDiscoverMethods(YTABRuntimeImageScopeAll, @"Runtime", nil,
            ^(NSArray<YTABRuntimeMethod *> *batch) {
                @synchronized([YTABRuntimeMethod class]) {
                    [sYTABRuntimeIncrementalCatalog addObjectsFromArray:batch];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:YTABRuntimeAutoIndexNotification
                        object:nil userInfo:@{@"newMethods": batch}];
                });
            });
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:YTABRuntimeAutoIndexNotification
                object:nil userInfo:@{@"complete": @YES}];
        });
    });
}

static NSArray<YTABRuntimeMethod *> *YTABRuntimeCurrentIndexSnapshot(void) {
    @synchronized([YTABRuntimeMethod class]) {
        return sYTABRuntimeMethodCatalog ?:
            [sYTABRuntimeIncrementalCatalog copy] ?: @[];
    }
}

// Groups use only native ObjC class metadata, never inferred eligibility.
static NSString *YTABRuntimeFamilyForClassName(NSString *name) {
    if ([name isEqualToString:@"YTColdConfig"]) return @"ColdConfig";
    if ([name isEqualToString:@"YTHotConfig"]) return @"HotConfig";
    if ([name isEqualToString:@"YTGlobalConfig"]) return @"GlobalConfig";
    NSString *lower = name.lowercaseString ?: @"";
    if ([lower containsString:@"phenotype"]) return @"Phenotype";
    if ([lower containsString:@"experiment"] || [lower containsString:@"abflag"] ||
        [lower containsString:@"abprop"] || [lower containsString:@"study"])
        return @"Experiments";
    if ([lower containsString:@"remoteconfig"] || [lower containsString:@"metaconfig"])
        return @"RemoteConfig";
    if ([lower containsString:@"settings"]) return @"Settings";
    if ([lower containsString:@"playback"] || [lower containsString:@"player"])
        return @"Playback";
    return @"Other";
}

static NSArray<NSString *> *YTABRuntimeSearchTokens(NSString *query) {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *component in [query componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        NSString *token = [component stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (token.length) [tokens addObject:token];
    }
    return tokens.copy;
}

@interface YTABRuntimeBrowserViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<YTABRuntimeMethod *> *allMethods;
@property(nonatomic, strong) NSArray<YTABRuntimeMethod *> *visibleMethods;
@property(nonatomic, strong) NSArray *visibleRows;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UISegmentedControl *scopeControl;
@property(nonatomic, copy) NSString *ytab_selectedCategory;
@property(atomic) NSUInteger scanGeneration;
@end

// Serialize inventory requests. A rapid Flags -> Methods -> Overrides switch
// must not launch overlapping expensive sweeps on the global worker pool.
static dispatch_queue_t YTABRuntimeInventoryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                    QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.ytabconfig.runtime.inventory",
                                      attributes);
    });
    return queue;
}

// Snapshot of native config results and saved local overrides, without an
// exhaustive binary scan. This is the only work required for first paint.
static NSArray<YTABRuntimeMethod *> *YTABRuntimeMergeCatalogs(
    NSArray<YTABRuntimeMethod *> *first,
    NSArray<YTABRuntimeMethod *> *second) {
    NSMutableArray<YTABRuntimeMethod *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSArray<YTABRuntimeMethod *> *group in @[first ?: @[], second ?: @[]]) {
        for (YTABRuntimeMethod *method in group) {
            if (![keys containsObject:method.patchKey]) {
                [keys addObject:method.patchKey];
                [result addObject:method];
            }
        }
    }
    return result.copy;
}

@implementation YTABRuntimeBrowserViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Patches";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = 58.0;
    self.tableView.estimatedRowHeight = 58.0;

    // Exactly two user-facing collections. Generic methods are part of the
    // same BOOL controls list, not a separate confusing "Methods" tab.
    self.scopeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"All BOOLs", @"Overrides"]];
    self.scopeControl.selectedSegmentIndex = YTABRuntimeImageScopeFlags;
    self.ytab_selectedCategory = @"Runtime";
    [self.scopeControl addTarget:self action:@selector(scopeChanged:)
                forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.scopeControl;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Class, selector or encoding";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Clear"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(clearOverrides)];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(ytab_autoIndexUpdated:)
        name:YTABRuntimeAutoIndexNotification object:nil];

    [self loadMethods];              // immediate captured state
    YTABRuntimeStartAutomaticIndex(); // full catalog runs independently
}

- (void)scopeChanged:(UISegmentedControl *)sender {
    (void)sender;
    [self loadMethods];
}


- (void)loadMethods {
    NSUInteger generation = ++self.scanGeneration;
    self.tableView.backgroundView = nil;
    __weak typeof(self) weakSelf = self;
    // Snapshot work uses a separate user-initiated queue. A two-minute
    // low-priority ObjC enumeration must never queue in front of first paint
    // or a category change.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *captured = YTABRuntimeDiscoverMethods(
            YTABRuntimeImageScopeFlags, nil, nil, nil);
        NSArray *stored = YTABRuntimeDiscoverMethods(
            YTABRuntimeImageScopeOverrides, nil, nil, nil);
        NSArray *fast = YTABRuntimeMergeCatalogs(
            YTABRuntimeMergeCatalogs(captured, stored),
            YTABRuntimeCurrentIndexSnapshot());
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) owner = weakSelf;
            if (!owner || owner.scanGeneration != generation) return;
            // Preserve batches received since the snapshot was taken.
            owner.allMethods = YTABRuntimeMergeCatalogs(fast, owner.allMethods);
            [owner applyFilter];
            [owner.tableView.refreshControl endRefreshing];
        });
    });
}

// Optional pull-to-refresh only rereads local values; full discovery is
// started automatically and never requires a pull or search.
- (void)ytab_requestFullIndex {
    [self loadMethods];
}

- (void)ytab_autoIndexUpdated:(NSNotification *)notification {
    if (![NSThread isMainThread]) return;
    NSArray *newMethods = notification.userInfo[@"newMethods"];
    if ([newMethods isKindOfClass:NSArray.class] && newMethods.count) {
        self.allMethods = YTABRuntimeMergeCatalogs(self.allMethods, newMethods);
        [self applyFilter]; // includes the current search text and category
    } else if ([notification.userInfo[@"complete"] boolValue]) {
        [self loadMethods]; // normalize against the complete, sorted cache
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:YTABRuntimeAutoIndexNotification object:nil];
}


// Presentation-independent search source. The modern subclass provides a
// standalone UISearchBar which is not managed by UINavigationItem.
- (UISearchController *)ytab_ownedSearchController {
    return self.searchController;
}

- (NSString *)ytab_currentSearchText {
    return self.searchController.searchBar.text ?: @"";
}

- (void)applyFilter {
    NSArray<NSString *> *tokens = YTABRuntimeSearchTokens([self ytab_currentSearchText]);
    BOOL searching = tokens.count > 0;
    BOOL showingOverrides = self.scopeControl.selectedSegmentIndex == 1;
    NSString *selectedCategory = self.ytab_selectedCategory ?: @"Runtime";
    // Stable partition: keep native browsing order, but always show local
    // overrides first as requested. No costly resorting or recomputation.
    NSMutableArray<YTABRuntimeMethod *> *overridden = [NSMutableArray array];
    NSMutableArray<YTABRuntimeMethod *> *unmodified = [NSMutableArray array];

    for (YTABRuntimeMethod *method in self.allMethods) {
        if (![selectedCategory isEqualToString:@"Runtime"] &&
            ![YTABRuntimeFamilyForClassName(method.className)
              isEqualToString:selectedCategory]) continue;
        // The default collection must show actual states, not thousands of
        // unobserved Objective-C selectors. A deliberate search can find a
        // compatible no-argument getter to explicitly patch or observe.
        NSNumber *override = YTABRuntimeBrowserOverrideValue(method.patchKey);
        if (showingOverrides && !override) continue;
        if (!showingOverrides) {
            if (!method.configFlag && [method.selectorName containsString:@":"])
                continue;
            if (!searching && [selectedCategory isEqualToString:@"Runtime"] &&
                !method.configFlag && !override &&
                !YTABRuntimeBrowserNativeSample(method.patchKey))
                continue;
        }

        if (searching) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                method.className, method.selectorName,
                method.typeEncoding, method.patchKey].lowercaseString;
            BOOL matchesAll = YES;
            for (NSString *token in tokens) {
                if (![haystack containsString:token]) {
                    matchesAll = NO;
                    break;
                }
            }
            if (!matchesAll) continue;
        }
        if (override) [overridden addObject:method];
        else [unmodified addObject:method];
    }
    [overridden addObjectsFromArray:unmodified];
    self.visibleMethods = overridden.copy;
    [self.tableView reloadData];
}

// Category changes only filter already discovered items; no new hooks
// are installed, no config refresh is forced, and no network calls occur.
- (void)ytab_setCategoryFilter:(NSString *)category {
    NSString *next = category.length ? category : @"Runtime";
    if ([self.ytab_selectedCategory isEqualToString:next]) return;
    self.ytab_selectedCategory = next;
    // Filtering is immediate even while the full background index runs.
    [self applyFilter];
}

- (NSArray<NSString *> *)ytab_availableCategories {
    NSMutableSet<NSString *> *families = [NSMutableSet set];
    for (YTABRuntimeMethod *method in self.allMethods)
        [families addObject:YTABRuntimeFamilyForClassName(method.className)];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithArray:
        @[@"Runtime", @"Phenotype", @"ColdConfig", @"HotConfig", @"GlobalConfig"]];
    for (NSString *extra in @[@"Experiments", @"RemoteConfig",
                               @"Settings", @"Playback", @"Other"]) {
        if ([families containsObject:extra]) [names addObject:extra];
    }
    return names.copy;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    // Search always filters the catalog currently present and automatically
    // refreshes as new methods are discovered. No manual start gate.
    [self applyFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleMethods.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%lu Boolean controls",
            (unsigned long)self.visibleMethods.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Local overrides can force ON, force OFF, or restore the native result. Some getters need a real invocation before their original value is known.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTABRuntimeMethodCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.detailTextLabel.numberOfLines = 1;
        cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }

    YTABRuntimeMethod *method = self.visibleMethods[indexPath.row];
    NSNumber *override = YTABRuntimeOverrideForKey(method.patchKey);
    NSNumber *native = YTABRuntimeObservedNative(method.patchKey);
    NSString *state = override ? (override.boolValue ? @"Force ON" : @"Force OFF") : @"System";
    NSString *nativeText = native ? (native.boolValue ? @"1" : @"0") : @"—";
    NSString *methodKind = method.classMethod ? @"class" : @"instance";

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
                           method.classMethod ? @"+ " : @"- ", method.selectorName];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · native %@",
                                 method.className, methodKind, state, nativeText];
    cell.detailTextLabel.textColor = override ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTABRuntimeMethod *method = self.visibleMethods[indexPath.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:method.selectorName
        message:[NSString stringWithFormat:@"%@\n%@\n%@",
                 method.className, method.typeEncoding, method.patchKey]
        preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    void (^applyValue)(NSNumber *) = ^(NSNumber *value) {
        BOOL success = YTABRuntimeSetOverride(value, method.patchKey);
        [weakSelf.tableView reloadData];
        if (!success) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"Patch unavailable"
                message:@"The class or method is no longer loaded, or its Objective-C ABI changed."
                preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:error animated:YES completion:nil];
        }
    };

    [sheet addAction:[UIAlertAction actionWithTitle:@"System"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(nil); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force OFF"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(@NO); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force ON"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(@YES); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy patch key"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = method.patchKey;
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        popover.sourceView = cell ?: self.view;
        popover.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)clearOverrides {
    if (!YTABRuntimeBrowserPersistedOverrideCount()) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear runtime patches?"
        message:@"Installed hooks remain pass-through until restart, but every saved override returns to System immediately."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            YTABRuntimeClearOverrides();
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
