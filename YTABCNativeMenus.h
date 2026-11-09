#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Observes an already-created native playback debug overlay. Does not allocate
/// YouTube services, change account eligibility or patch executable text.
FOUNDATION_EXPORT void YTABCInstallNativeMenuObservationHooks(void);

/// Opens the local diagnostic/navigation hub from Feature Lab settings.
FOUNDATION_EXPORT BOOL YTABCPushNativeMenuHub(id settingsViewController);

NS_ASSUME_NONNULL_END
