#import "YTABRuntimeBrowser.h"

NS_ASSUME_NONNULL_BEGIN

/// Readable, direct-control UI for the runtime patch engine. The engine and
/// persisted patch format remain owned by YTABRuntimeBrowser.m.
@interface YTABRuntimeBrowserModernViewController : YTABRuntimeBrowserViewController
/// Start in unified Boolean controls (0) or active local overrides (1).
/// The same underlying runtime patch engine remains authoritative.
- (instancetype)initWithInitialScope:(NSInteger)scope;
/// Open directly in a native class family, without an Overrides-only scope.
- (instancetype)initWithCategory:(NSString *)category;
@end

NS_ASSUME_NONNULL_END
