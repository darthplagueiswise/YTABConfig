#import <UIKit/UIKit.h>

@class YTABLabFlag;

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
- (NSDictionary<NSString *, id> *)metadataForSelector:(NSString *)selector
                                           sourceClass:(NSString *)sourceClass;
@end

@protocol YTABLabRuntimeProviding <NSObject>
- (NSArray<YTABLabFlag *> *)allFlags;
- (void)setOverrideValue:(BOOL)value forFlag:(YTABLabFlag *)flag;
- (void)resetOverrideForFlag:(YTABLabFlag *)flag;
- (void)resetAllOverrides;
- (NSString *)exportText;
- (NSUInteger)importText:(NSString *)text;
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
@property(nonatomic, assign, readonly) BOOL hasOverride;
@property(nonatomic, assign, readonly) BOOL documented;
@property(nonatomic, assign, readonly) BOOL removed;

@end

@interface YTABLegacyRuntimeAdapter : NSObject <YTABLabRuntimeProviding>
- (instancetype)initWithCatalog:(id<YTABLabCatalogProviding>)catalog;
@end

@interface YTABLabDashboardViewController : UITableViewController
- (instancetype)initWithProvider:(id<YTABLabRuntimeProviding>)provider;
@end
