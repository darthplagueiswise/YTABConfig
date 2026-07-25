#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts preference reconciliation. Safe to call more than once.
FOUNDATION_EXPORT void YTABCRuntimeRegistryStart(NSUserDefaults *defaults);

/// Discovers the exact BOOL/no-argument flag surface and records native values.
FOUNDATION_EXPORT void YTABCRuntimeRegisterConfigInstance(
    id instance,
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *nativeCatalog
);

/// Stable persisted key used by existing YTABConfig releases.
FOUNDATION_EXPORT NSString *YTABCOverrideKey(NSString *className, NSString *selectorName);

/// Runtime override API intended for Settings UI integration.
FOUNDATION_EXPORT BOOL YTABCSetOverride(NSString *className, NSString *selectorName, BOOL value);
FOUNDATION_EXPORT BOOL YTABCClearOverride(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCNativeValue(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCOverrideValue(NSString *className, NSString *selectorName);
FOUNDATION_EXPORT NSNumber * _Nullable YTABCEffectiveValue(NSString *className, NSString *selectorName);

/// Diagnostic snapshot keyed by "Class.selector".
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCRuntimeSnapshot(void);

NS_ASSUME_NONNULL_END
