#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reinstalls only persisted per-selector patches. This never scans the full
/// Objective-C runtime and is safe to call more than once during startup.
FOUNDATION_EXPORT void YTABRuntimeBrowserReinstallPersistedHooks(void);

/// Number of persisted runtime patches currently stored by the browser.
FOUNDATION_EXPORT NSUInteger YTABRuntimeBrowserPersistedOverrideCount(void);

/// On-demand browser for BOOL-returning Objective-C methods in the YouTube
/// executable and Module_Framework. Catalog discovery happens only after this
/// controller is opened.
@interface YTABRuntimeBrowserViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
