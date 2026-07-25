#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class YTABLabFlag;

typedef void (^YTABLabJSONExportCompletion)(NSURL * _Nullable fileURL, NSError * _Nullable error);

FOUNDATION_EXPORT NSString * const YTABLabMetadataTitleKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataDescriptionKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataStatusKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataCategoryKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataRiskKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataEvidenceKey;
FOUNDATION_EXPORT NSString * const YTABLabMetadataDocumentedKey;

// Catalog providers return only verified fields. Omitted fields deliberately
// render as Unknown / Needs Research; the UI never guesses descriptions.
@protocol YTABLabCatalogProviding <NSObject>
- (nullable NSDictionary<NSString *, id> *)metadataForSelector:(NSString *)selector
                                                    sourceClass:(NSString *)sourceClass;
@end

@protocol YTABLabRuntimeProviding <NSObject>
- (NSArray<YTABLabFlag *> *)allFlags;
- (BOOL)setOverrideValue:(BOOL)value forFlag:(YTABLabFlag *)flag;
- (BOOL)resetOverrideForFlag:(YTABLabFlag *)flag;
- (BOOL)resetAllOverrides;
- (NSString *)exportText;
- (void)writeJSONExportWithCompletion:(YTABLabJSONExportCompletion)completion;
- (NSUInteger)importText:(NSString *)text;
@optional
- (nullable YTABLabFlag *)refreshedFlagMatchingFlag:(YTABLabFlag *)flag;
@end

@interface YTABLabFlag : NSObject

@property(nonatomic, copy, readonly) NSString *readableTitle;
@property(nonatomic, copy, readonly) NSString *rawSelector;
@property(nonatomic, copy, readonly) NSString *sourceClass;
@property(nonatomic, copy, readonly) NSString *flagDescription;
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, copy, readonly) NSString *category;
@property(nonatomic, copy, readonly) NSString *risk;
@property(nonatomic, copy, readonly) NSString *evidence;
@property(nonatomic, assign, readonly) BOOL nativeValue;
@property(nonatomic, assign, readonly) BOOL effectiveValue;
@property(nonatomic, assign, readonly) BOOL hasNativeValue;
@property(nonatomic, assign, readonly) BOOL hasEffectiveValue;
@property(nonatomic, assign, readonly) BOOL hasOverride;
@property(nonatomic, assign, readonly) BOOL documented;
@property(nonatomic, assign, readonly) BOOL removed;

@end

@interface YTABLegacyRuntimeAdapter : NSObject <YTABLabRuntimeProviding>
- (instancetype)initWithCatalog:(nullable id<YTABLabCatalogProviding>)catalog;
@end

@interface YTABLabDashboardViewController : UITableViewController
- (instancetype)initWithProvider:(id<YTABLabRuntimeProviding>)provider;
@end

NS_ASSUME_NONNULL_END
