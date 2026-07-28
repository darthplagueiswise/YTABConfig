#import "YTABRuntimeBrowser.h"

%ctor {
    @autoreleasepool {
        // RyukGram-style timing: reinstall only explicitly persisted selector
        // hooks. No class sweep, method enumeration, JSON parsing, or request.
        YTABRuntimeBrowserReinstallPersistedHooks();

        // Module_Framework may be loaded by another constructor. Retry once on
        // the main queue; the installer is idempotent and still O(saved keys).
        dispatch_async(dispatch_get_main_queue(), ^{
            YTABRuntimeBrowserReinstallPersistedHooks();
        });
    }
}
