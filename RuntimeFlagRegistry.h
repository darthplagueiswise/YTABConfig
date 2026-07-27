#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Selects the defaults store used by the runtime registry.
/// Preference changes from the Feature Lab are reconciled directly by the set/clear APIs.
FOUNDATION_EXPORT void YTABCRuntimeRegistryStart(NSUserDefaults *defaults);

/// Registers one live YouTube config instance without enumerating or invoking its flag getters.
/// Returns YES only for a supported YTGlobalConfig/YTColdConfig/YTHotConfig hierarchy.
FOUNDATION_EXPORT BOOL YTABCRuntimeRegisterConfigInstance(id instance);

/// Captures the original IMP returned by the PoomSmart-compatible launch hook.
/// This allows Feature Lab to sample live native values without installing a
/// second hook or replacing the proven cache-backed launch path.
FOUNDATION_EXPORT void YTABCRuntimeRegisterOriginalImplementation(
    id instance,
    SEL selector,
    IMP originalImplementation,
    BOOL nativeValue
);

/// Applies only valid persisted overrides whose selectors still exist in the registered runtime.
/// This path is intentionally proportional to the number of saved overrides, not all live flags.
FOUNDATION_EXPORT void YTABCRuntimeApplyPersistedOverrides(void);

/// Enumerates the current runtime method lists without invoking any getters.
/// Call this lazily when the Feature Lab UI is opened.
FOUNDATION_EXPORT NSUInteger YTABCRuntimeDiscoverFlags(void);

/// Returns every discovered live selector. Values are NSNumber after a native sample, otherwise NSNull.
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

/// Samples all discovered native getters on the main queue in bounded batches.
/// Intended for an explicit user action such as exporting a full runtime report.
FOUNDATION_EXPORT void YTABCRuntimeRefreshAllNativeValues(dispatch_block_t completion);

/// Diagnostic snapshot keyed by "Class.selector". Never invokes a getter.
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *YTABCRuntimeSnapshot(void);

NS_ASSUME_NONNULL_END
