#import <Foundation/Foundation.h>
#import "YTABLabUI.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTABCatalogProvider : NSObject <YTABLabCatalogProviding>

- (instancetype)initWithBundle:(NSBundle *)bundle
                youtubeVersion:(NSString *)youtubeVersion NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
