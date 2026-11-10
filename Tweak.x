#import <YouTubeHeader/YTAppDelegate.h>
#import <YouTubeHeader/YTGlobalConfig.h>
#import <YouTubeHeader/YTColdConfig.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <substrate.h>
#import "YTABCNativeMenus.h"
#import <pthread.h>

extern pthread_mutex_t cacheMutex;

NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;

extern void SearchHook(void);
extern void YTABCInstallNativeDiagnostics(void);
extern BOOL tweakEnabled(void);
extern BOOL groupedSettings(void);
extern void updateAllKeys(void);
extern NSString *getKey(NSString *method, NSString *classKey);
extern BOOL getValue(NSString *methodKey);

static BOOL returnFunction(id const self, SEL selector) {
    NSString *method = NSStringFromSelector(selector);
    NSString *methodKey = getKey(method, NSStringFromClass([self class]));
    return getValue(methodKey);
}

static BOOL getValueFromInvocation(id target, SEL selector) {
    IMP implementation = [target methodForSelector:selector];
    return ((BOOL (*)(id, SEL))implementation)(target, selector);
}

static NSSet<NSString *> *excludedPrefixes;

static NSMutableArray<NSString *> *getBooleanMethods(Class targetClass) {
    NSMutableArray<NSString *> *allMethods = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    for (unsigned int index = 0; index < methodCount; ++index) {
        Method method = methods[index];
        const char *encoding = method_getTypeEncoding(method);
        if (!encoding || strcmp(encoding, "B16@0:8") != 0) continue;

        NSString *selector = NSStringFromSelector(method_getName(method));
        BOOL excluded = NO;
        for (NSString *prefix in excludedPrefixes) {
            if ([selector hasPrefix:prefix]) {
                excluded = YES;
                break;
            }
        }
        if (!excluded && [selector rangeOfString:@"Android"].location != NSNotFound) {
            excluded = YES;
        }
        if (excluded) continue;

        if (![allMethods containsObject:selector]) [allMethods addObject:selector];
    }
    free(methods);
    return allMethods;
}

static void hookClass(NSObject *instance) {
    if (!instance) {
        // Config objects are not guaranteed to be initialized when a sideload
        // build reaches didFinishLaunching. Never crash during app launch.
        NSLog(@"[YTABConfig Runtime] Skipping an unavailable native config instance");
        return;
    }

    Class instanceClass = [instance class];
    NSMutableArray<NSString *> *methods = getBooleanMethods(instanceClass);
    NSString *classKey = NSStringFromClass(instanceClass);

    pthread_mutex_lock(&cacheMutex);
    NSMutableDictionary<NSString *, NSNumber *> *classCache =
        cache[classKey] = [NSMutableDictionary new];
    for (NSString *method in methods) {
        SEL selector = NSSelectorFromString(method);
        BOOL nativeValue = getValueFromInvocation(instance, selector);
        classCache[method] = @(nativeValue);
        MSHookMessageEx(instanceClass, selector, (IMP)returnFunction, NULL);
    }
    pthread_mutex_unlock(&cacheMutex);
}

%hook YTAppDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    // Observe native UI components without modifying account eligibility.
    YTABCInstallNativeMenuObservationHooks();
    YTABCInstallNativeDiagnostics();

    if (tweakEnabled()) {
        updateAllKeys();
        YTGlobalConfig *globalConfig = nil;
        YTColdConfig *coldConfig = nil;
        YTHotConfig *hotConfig = nil;
        @try {
            globalConfig = [self valueForKey:@"_globalConfig"];
            coldConfig = [self valueForKey:@"_coldConfig"];
            hotConfig = [self valueForKey:@"_hotConfig"];
        } @catch (NSException *exception) {
            @try {
                id settings = [self valueForKey:@"_settings"];
                globalConfig = [settings valueForKey:@"_globalConfig"];
                coldConfig = [settings valueForKey:@"_coldConfig"];
                hotConfig = [settings valueForKey:@"_hotConfig"];
            } @catch (NSException *fallbackException) {
                NSLog(@"[YTABConfig Runtime] Config KVC lookup failed: %@ / %@",
                      exception.reason, fallbackException.reason);
            }
        }

        // Preserve PoomSmart 1.9.2's proven launch contract: capture each live
        // getter before replacing it, then install the same cache-backed hook.
        hookClass(globalConfig);
        hookClass(coldConfig);
        hookClass(hotConfig);

        if (!groupedSettings()) SearchHook();
    }
    return %orig;
}

%end

%ctor {
    NSString *modulePath = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/Module_Framework.framework"];
    if ([NSFileManager.defaultManager fileExistsAtPath:modulePath]) {
        [[NSBundle bundleWithPath:modulePath] load];
    }

    // Attempt registration here and again during the app delegate launch.
    YTABCInstallNativeMenuObservationHooks();
    YTABCInstallNativeDiagnostics();

    cache = [NSMutableDictionary new];
    excludedPrefixes = [NSSet setWithArray:@[
        @"android", @"amsterdam", @"kidsClient", @"musicClient",
        @"musicOfflineClient", @"unplugged"
    ]];
    %init;
}

%dtor {
    [cache removeAllObjects];
}
