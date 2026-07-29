#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Selects the defaults store used by the runtime registry.
/// Preference changes from the Feature Lab are reconciled directly by the set/clear APIs.
FOUNDATION_EXPORT void YTABCRuntimeRegistryStart(NSUserDefaults *defaults);

/// Applies only valid persisted overrides whose selectors still exist in the registered runtime.
/// This path is intentionally proportional to the number of saved overrides, not all live flags.
FOUNDATION_EXPORT void YTABCRuntimeApplyPersistedOverrides(void);

/// Counts the selectors captured by PoomSmart's launch-time cache.
FOUNDATION_EXPORT NSUInteger YTABCRuntimeDiscoverFlags(void);

/// Returns the native BOOL values captured immediately before each hook.
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
YTABCRuntimeValuesSnapshot(void);
FOUNDATION_EXPORT BOOL YTABCRuntimeHasFlag(NSString *className, NSString *selectorName);

/// Stable persisted key used by existing YTABConfig releases.
FOUNDATION_EXPORT NSString *YTABCOverrideKey(NSString *className, NSString *selectorName);

/// Runtime override API intended for Settings UI integration.
FOUNDATION_EXPORT BOOL YTABCSetOverride(NSString *className, NSString *selectorName, BOOL value);
FOUNDATION_EXPORT BOOL YTABCClearOverride(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCNativeValue(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCOverrideValue(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCEffectiveValue(NSString *className, NSString *selectorName);

/// Diagnostic snapshot keyed by "Class.selector". Reads only the shared cache.
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCRuntimeSnapshot(void);

NS_ASSUME_NONNULL_END
