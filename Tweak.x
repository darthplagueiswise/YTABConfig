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
extern void updateAllKeys(void);

static void YTABCRegisterConfigs(YTAppDelegate *delegate) {
    YTGlobalConfig *globalConfig = nil;
    YTColdConfig *coldConfig = nil;
    YTHotConfig *hotConfig = nil;
    @try {
        globalConfig = [delegate valueForKey:@"_globalConfig"];
        coldConfig = [delegate valueForKey:@"_coldConfig"];
        hotConfig = [delegate valueForKey:@"_hotConfig"];
    } @catch (__unused id exception) {
        @try {
            id settings = [delegate valueForKey:@"_settings"];
            globalConfig = [settings valueForKey:@"_globalConfig"];
            coldConfig = [settings valueForKey:@"_coldConfig"];
            hotConfig = [settings valueForKey:@"_hotConfig"];
        } @catch (__unused id nestedException) {
            NSLog(@"[YTABConfig Runtime] Unable to locate YouTube config instances");
        }
    }

    pthread_mutex_lock(&cacheMutex);
    YTABCRuntimeRegisterConfigInstance(globalConfig, cache);
    YTABCRuntimeRegisterConfigInstance(coldConfig, cache);
    YTABCRuntimeRegisterConfigInstance(hotConfig, cache);
    pthread_mutex_unlock(&cacheMutex);
}

%hook YTAppDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    if (tweakEnabled()) {
        updateAllKeys();
        YTABCRuntimeRegistryStart(NSUserDefaults.standardUserDefaults);
        YTABCRegisterConfigs(self);
        if (!groupedSettings()) SearchHook();
    }
    return %orig;
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
