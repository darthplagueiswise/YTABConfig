#import <YouTubeHeader/YTAppDelegate.h>
#import <YouTubeHeader/YTGlobalConfig.h>
#import <YouTubeHeader/YTColdConfig.h>
#import <YouTubeHeader/YTHotConfig.h>

#import "RuntimeFlagRegistry.h"

extern void SearchHook(void);
extern BOOL tweakEnabled(void);
extern BOOL groupedSettings(void);

typedef struct {
    NSUInteger availableConfigCount;
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

    NSUInteger availableConfigCount = 0;
    for (id instance in instances) {
        if (YTABCRuntimeRegisterConfigInstance(instance)) availableConfigCount++;
    }
    YTABCRuntimeApplyPersistedOverrides();

    NSLog(@"[YTABConfig Runtime] %@ registered %lu/3 live config instances without sampling getters",
          context, (unsigned long)availableConfigCount);
    YTABCRegistrationResult result = { availableConfigCount };
    return result;
}

static void YTABCScheduleBoundedRegistrationRetry(YTAppDelegate *delegate) {
    static dispatch_once_t retryOnceToken;
    dispatch_once(&retryOnceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            YTABCRegistrationResult retry = YTABCRegisterAvailableConfigs(delegate, @"bounded-retry");
            if (retry.availableConfigCount < 3) {
                NSLog(@"[YTABConfig Runtime] Bounded retry incomplete: %lu/3 live configs. "
                      "The current YouTube runtime ownership may have changed.",
                      (unsigned long)retry.availableConfigCount);
            }
        });
    });
}

%hook YTAppDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL enabled = tweakEnabled();
    YTABCRegistrationResult registration = { 0 };
    if (enabled) {
        YTABCRuntimeRegistryStart(NSUserDefaults.standardUserDefaults);
        registration = YTABCRegisterAvailableConfigs(self, @"pre-original");
    }
    BOOL result = %orig;
    if (enabled) {
        registration = YTABCRegisterAvailableConfigs(self, @"post-original");
        if (registration.availableConfigCount < 3) {
            YTABCScheduleBoundedRegistrationRetry(self);
        }
        if (!groupedSettings()) SearchHook();
    }
    return result;
}

%end

%ctor {
    NSString *modulePath = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/Module_Framework.framework"];
    if ([NSFileManager.defaultManager fileExistsAtPath:modulePath]) {
        [[NSBundle bundleWithPath:modulePath] load];
    }
    %init;
}
