#import <YouTubeHeader/YTAppDelegate.h>
#import <YouTubeHeader/YTGlobalConfig.h>
#import <YouTubeHeader/YTColdConfig.h>
#import <YouTubeHeader/YTHotConfig.h>

#import "RuntimeFlagRegistry.h"

#import <pthread.h>

NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *cache;

extern pthread_mutex_t cacheMutex;
extern void SearchHook(void);
extern BOOL tweakEnabled(void);
extern BOOL groupedSettings(void);

typedef struct {
    NSUInteger availableConfigCount;
    NSUInteger discoveredFlagCount;
} YTABCRegistrationResult;

static id YTABCSafeValueForKey(id object, NSString *key, NSString *context) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig Runtime] KVC drift reading %@ from %@ during %@: %@",
              key, NSStringFromClass([object class]), context, exception.reason);
        return nil;
    }
}

static YTABCRegistrationResult YTABCRegisterAvailableConfigs(
    YTAppDelegate *delegate,
    NSString *context
) {
    NSArray<NSString *> *keys = @[@"_globalConfig", @"_coldConfig", @"_hotConfig"];
    NSMutableArray *instances = [NSMutableArray arrayWithCapacity:keys.count];
    id settings = nil;
    BOOL attemptedSettingsFallback = NO;
    for (NSString *key in keys) {
        id instance = YTABCSafeValueForKey(delegate, key, context);
        if (!instance) {
            if (!attemptedSettingsFallback) {
                settings = YTABCSafeValueForKey(delegate, @"_settings", context);
                attemptedSettingsFallback = YES;
            }
            instance = YTABCSafeValueForKey(settings, key, context);
        }
        if (instance) [instances addObject:instance];
    }

    NSUInteger flagCount = 0;
    pthread_mutex_lock(&cacheMutex);
    for (id instance in instances) {
        flagCount += YTABCRuntimeRegisterConfigInstance(instance, cache);
    }
    pthread_mutex_unlock(&cacheMutex);

    NSLog(@"[YTABConfig Runtime] %@ registration found %lu/3 configs and %lu flags",
          context, (unsigned long)instances.count, (unsigned long)flagCount);
    YTABCRegistrationResult result = { instances.count, flagCount };
    return result;
}

static void YTABCScheduleBoundedRegistrationRetry(YTAppDelegate *delegate) {
    static dispatch_once_t retryOnceToken;
    dispatch_once(&retryOnceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            YTABCRegistrationResult retry = YTABCRegisterAvailableConfigs(delegate, @"bounded-retry");
            if (retry.availableConfigCount < 3 || retry.discoveredFlagCount == 0) {
                NSLog(@"[YTABConfig Runtime] Bounded retry incomplete: %lu/3 configs, %lu flags. "
                      "YouTube 21.28.3 private config ownership may have changed.",
                      (unsigned long)retry.availableConfigCount,
                      (unsigned long)retry.discoveredFlagCount);
            }
        });
    });
}

%hook YTAppDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL enabled = tweakEnabled();
    YTABCRegistrationResult registration = { 0, 0 };
    if (enabled) {
        YTABCRuntimeRegistryStart(NSUserDefaults.standardUserDefaults);
        registration = YTABCRegisterAvailableConfigs(self, @"pre-original");
    }
    BOOL result = %orig;
    if (enabled) {
        if (registration.availableConfigCount < 3 || registration.discoveredFlagCount == 0) {
            registration = YTABCRegisterAvailableConfigs(self, @"post-original");
        }
        if (registration.availableConfigCount < 3 || registration.discoveredFlagCount == 0) {
            YTABCScheduleBoundedRegistrationRetry(self);
        }
        if (!groupedSettings()) SearchHook();
    }
    return result;
}

%end

%ctor {
    [[NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Frameworks/Module_Framework.framework",
                              NSBundle.mainBundle.bundlePath]] load];
    cache = [NSMutableDictionary dictionary];
    %init;
}

%dtor {
    [cache removeAllObjects];
}
