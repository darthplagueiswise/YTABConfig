#import "YTABRuntimeBrowser.h"

NS_ASSUME_NONNULL_BEGIN

/// Readable, direct-control UI for the runtime patch engine. The engine and
/// persisted patch format remain owned by YTABRuntimeBrowser.m.
@interface YTABRuntimeBrowserModernViewController : YTABRuntimeBrowserViewController
/// Start directly in Flags (0), Methods (1) or Overrides (2).
/// The same underlying runtime patch engine remains authoritative.
- (instancetype)initWithInitialScope:(NSInteger)scope;
@end

NS_ASSUME_NONNULL_END
