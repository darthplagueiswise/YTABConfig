#import "YTABCatalogProvider.h"

static const NSUInteger YTABCatalogMaximumStringLength = 512;
static const NSUInteger YTABCatalogMaximumEvidenceItems = 3;
static NSString * const YTABCatalogResourceName = @"YTABCatalog-v1";

@interface YTABCatalogProvider ()
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *metadataByKey;
@end

static NSString *YTABCatalogString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;
    if (trimmed.length > YTABCatalogMaximumStringLength) {
        trimmed = [trimmed substringToIndex:YTABCatalogMaximumStringLength];
    }
    return trimmed;
}

static BOOL YTABCatalogSchemaVersionIsSupported(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    return [value doubleValue] == 1.0;
}

static BOOL YTABCatalogClassIsSupported(NSString *sourceClass) {
    static NSSet<NSString *> *supportedClasses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedClasses = [NSSet setWithArray:@[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"]];
    });
    return [supportedClasses containsObject:sourceClass];
}

static NSString *YTABCatalogStatus(id value) {
    NSString *status = YTABCatalogString(value);
    if ([status isEqualToString:@"Verified"] ||
        [status isEqualToString:@"Inferred"] ||
        [status isEqualToString:@"Unknown"]) {
        return status;
    }
    return @"Unknown";
}

static NSString *YTABCatalogRisk(id value) {
    NSString *risk = YTABCatalogString(value);
    if ([risk isEqualToString:@"Low"] ||
        [risk isEqualToString:@"Medium"] ||
        [risk isEqualToString:@"High"] ||
        [risk isEqualToString:@"Unknown"]) {
        return risk;
    }
    return nil;
}

static BOOL YTABCatalogVersionIsVerified(id value, NSString *youtubeVersion) {
    if (![value isKindOfClass:NSArray.class] || youtubeVersion.length == 0) return NO;
    for (id candidate in (NSArray *)value) {
        if ([candidate isKindOfClass:NSString.class] && [candidate isEqualToString:youtubeVersion]) {
            return YES;
        }
    }
    return NO;
}

static NSString *YTABCatalogEvidenceText(id value) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:YTABCatalogMaximumEvidenceItems];
    for (id candidate in (NSArray *)value) {
        NSString *label = nil;
        if ([candidate isKindOfClass:NSString.class]) {
            label = YTABCatalogString(candidate);
        } else if ([candidate isKindOfClass:NSDictionary.class]) {
            NSDictionary *evidence = candidate;
            label = YTABCatalogString(evidence[@"id"]);
            NSString *kind = YTABCatalogString(evidence[@"kind"]);
            if (label && kind) label = [NSString stringWithFormat:@"%@ (%@)", label, kind];
        }
        if (label) [labels addObject:label];
        if (labels.count == YTABCatalogMaximumEvidenceItems) break;
    }
    return labels.count ? [labels componentsJoinedByString:@", "] : nil;
}

@implementation YTABCatalogProvider

- (instancetype)initWithBundle:(NSBundle *)bundle youtubeVersion:(NSString *)youtubeVersion {
    self = [super init];
    if (!self) return nil;

    _metadataByKey = @{};
    NSString *currentVersion = YTABCatalogString(youtubeVersion);
    NSString *path = [bundle pathForResource:YTABCatalogResourceName ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data || !currentVersion) return self;

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![object isKindOfClass:NSDictionary.class]) return self;
    NSDictionary *document = object;
    NSNumber *schemaVersion = document[@"schemaVersion"];
    NSString *catalogVersion = YTABCatalogString(document[@"youtubeVersion"]);
    NSArray *records = [document[@"records"] isKindOfClass:NSArray.class] ? document[@"records"] : nil;
    if (!YTABCatalogSchemaVersionIsSupported(schemaVersion) ||
        ![catalogVersion isEqualToString:currentVersion] ||
        !records) {
        return self;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *metadata = [NSMutableDictionary dictionary];
    for (id candidate in records) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *record = candidate;
        NSString *sourceClass = YTABCatalogString(record[@"class"]);
        NSString *selector = YTABCatalogString(record[@"selector"]);
        if (!YTABCatalogClassIsSupported(sourceClass) || !selector) continue;

        NSString *key = [NSString stringWithFormat:@"%@.%@", sourceClass, selector];
        if (metadata[key]) continue;

        NSString *declaredStatus = YTABCatalogStatus(record[@"status"]);
        BOOL versionVerified = YTABCatalogVersionIsVerified(record[@"verifiedVersions"], currentVersion);
        BOOL verified = [declaredStatus isEqualToString:@"Verified"] && versionVerified;
        NSString *status = verified ? @"Verified" :
            ([declaredStatus isEqualToString:@"Inferred"] ? @"Inferred" : @"Unknown");
        NSString *summary = verified ? YTABCatalogString(record[@"summary"]) : nil;

        NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary dictionary];
        NSString *title = YTABCatalogString(record[@"title"]);
        NSString *category = YTABCatalogString(record[@"category"]);
        NSString *risk = YTABCatalogRisk(record[@"risk"]);
        NSString *evidence = YTABCatalogEvidenceText(record[@"evidence"]);
        if (title) entry[YTABLabMetadataTitleKey] = title;
        if (category) entry[YTABLabMetadataCategoryKey] = category;
        if (risk) entry[YTABLabMetadataRiskKey] = risk;
        if (evidence) entry[YTABLabMetadataEvidenceKey] = evidence;
        entry[YTABLabMetadataStatusKey] = status;
        entry[YTABLabMetadataDocumentedKey] = @(summary.length > 0);
        if (summary.length > 0) entry[YTABLabMetadataDescriptionKey] = summary;
        metadata[key] = entry.copy;
    }
    _metadataByKey = metadata.copy;
    return self;
}

- (NSDictionary<NSString *, id> *)metadataForSelector:(NSString *)selector
                                           sourceClass:(NSString *)sourceClass {
    if (selector.length == 0 || sourceClass.length == 0) return nil;
    return self.metadataByKey[[NSString stringWithFormat:@"%@.%@", sourceClass, selector]];
}

@end
