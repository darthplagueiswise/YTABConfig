#import "YTABLabUI.h"
#import "RuntimeFlagRegistry.h"

extern NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *YTABCopyRuntimeValues(void);
extern NSDictionary<NSString *, NSNumber *> *YTABCopyOverrideValues(void);
extern BOOL YTABResetRuntimeOverride(NSString *sourceClass, NSString *selector, BOOL nativeValue);
extern BOOL YTABResetAllRuntimeOverrides(NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *nativeValues);

#define YTAB_STRINGIFY_INNER(value) #value
#define YTAB_STRINGIFY(value) YTAB_STRINGIFY_INNER(value)
#ifndef TWEAK_VERSION
#define TWEAK_VERSION unknown
#endif

NSString * const YTABLabMetadataTitleKey = @"title";
NSString * const YTABLabMetadataDescriptionKey = @"description";
NSString * const YTABLabMetadataStatusKey = @"status";
NSString * const YTABLabMetadataCategoryKey = @"category";
NSString * const YTABLabMetadataRiskKey = @"risk";
NSString * const YTABLabMetadataEvidenceKey = @"evidence";
NSString * const YTABLabMetadataDocumentedKey = @"documented";

static NSString * const YTABPreferencePrefix = @"YTABC.";
static NSString * const YTABUnknownStatus = @"Unknown / Needs Research";
static NSString * const YTABUnknownDescription = @"No verified description is available. This flag needs research before we make claims about its behavior.";
static NSString * const YTABUnknownEvidence = @"No verified evidence is linked yet.";
static NSString * const YTABLabExportErrorDomain = @"com.afterglow-labs.ytabconfig.runtime-export";
static const NSUInteger YTABLabMaximumExportStringLength = 1024;

typedef NS_ENUM(NSUInteger, YTABLabListMode) {
    YTABLabListModeAll,
    YTABLabListModeDocumented,
    YTABLabListModeModified,
    YTABLabListModeNeedsReview,
};

static NSString *YTABBooleanText(BOOL value) {
    return value ? @"On" : @"Off";
}

static NSNumber *YTABValidOverrideNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    double number = [value doubleValue];
    return (number == 0.0 || number == 1.0) ? @([value boolValue]) : nil;
}

static BOOL YTABExportClassIsSupported(NSString *sourceClass) {
    static NSSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classes = [NSSet setWithArray:@[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"]];
    });
    return [classes containsObject:sourceClass];
}

static BOOL YTABParseRuntimeKey(
    NSString *runtimeKey,
    NSString **sourceClass,
    NSString **selector
) {
    NSRange separator = [runtimeKey rangeOfString:@"."];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location + 1 >= runtimeKey.length) {
        return NO;
    }
    NSString *parsedClass = [runtimeKey substringToIndex:separator.location];
    if (!YTABExportClassIsSupported(parsedClass)) return NO;
    if (sourceClass) *sourceClass = parsedClass;
    if (selector) *selector = [runtimeKey substringFromIndex:separator.location + 1];
    return YES;
}

static NSString *YTABBoundedExportString(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return fallback;
    if (trimmed.length > YTABLabMaximumExportStringLength) {
        trimmed = [trimmed substringToIndex:YTABLabMaximumExportStringLength];
    }
    return trimmed;
}

static NSString *YTABExportStatus(NSString *status) {
    if ([status isEqualToString:@"Verified"] ||
        [status isEqualToString:@"Inferred"] ||
        [status isEqualToString:@"Unknown"]) {
        return status;
    }
    return @"Unknown";
}

static NSString *YTABExportRisk(NSString *risk) {
    if ([risk isEqualToString:@"Low"] ||
        [risk isEqualToString:@"Medium"] ||
        [risk isEqualToString:@"High"] ||
        [risk isEqualToString:@"Unknown"]) {
        return risk;
    }
    return @"Unknown";
}

static NSError *YTABExportError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:YTABLabExportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Runtime export failed."}];
}

static NSString *YTABExportTimestamp(void) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:NSDate.date];
}

static void YTABConfigureSelfSizingTable(UITableView *tableView) {
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 76.0;
}

static NSString *YTABReadableTitle(NSString *selector) {
    if (selector.length == 0) return @"Untitled Flag";
    NSMutableString *result = [NSMutableString stringWithCapacity:selector.length + 8];
    unichar previous = 0;
    for (NSUInteger index = 0; index < selector.length; index++) {
        unichar character = [selector characterAtIndex:index];
        BOOL isUppercase = [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:character];
        BOOL previousIsLowercase = previous && [[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:previous];
        if ((character == '_' || character == '-') && result.length > 0) {
            [result appendString:@" "];
        } else {
            if (isUppercase && previousIsLowercase) [result appendString:@" "];
            [result appendFormat:@"%C", character];
        }
        previous = character;
    }
    NSString *trimmed = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return selector;
    return [trimmed stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                            withString:[[trimmed substringToIndex:1] uppercaseString]];
}

@interface YTABLabFlag ()
@property(nonatomic, copy, readwrite) NSString *readableTitle;
@property(nonatomic, copy, readwrite) NSString *rawSelector;
@property(nonatomic, copy, readwrite) NSString *sourceClass;
@property(nonatomic, copy, readwrite) NSString *flagDescription;
@property(nonatomic, copy, readwrite) NSString *status;
@property(nonatomic, copy, readwrite) NSString *category;
@property(nonatomic, copy, readwrite) NSString *risk;
@property(nonatomic, copy, readwrite) NSString *evidence;
@property(nonatomic, assign, readwrite) BOOL nativeValue;
@property(nonatomic, assign, readwrite) BOOL effectiveValue;
@property(nonatomic, assign, readwrite) BOOL hasNativeValue;
@property(nonatomic, assign, readwrite) BOOL hasEffectiveValue;
@property(nonatomic, assign, readwrite) BOOL hasOverride;
@property(nonatomic, assign, readwrite) BOOL documented;
@property(nonatomic, assign, readwrite) BOOL removed;
@end

@implementation YTABLabFlag
@end

@interface YTABLegacyRuntimeAdapter ()
@property(nonatomic, strong) id<YTABLabCatalogProviding> catalog;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *nativeValues;
@end

@implementation YTABLegacyRuntimeAdapter

- (instancetype)initWithCatalog:(id<YTABLabCatalogProviding>)catalog {
    self = [super init];
    if (self) {
        _catalog = catalog;
        _nativeValues = [YTABCopyRuntimeValues() copy] ?: @{};
    }
    return self;
}

- (YTABLabFlag *)flagForSelector:(NSString *)selector
                     sourceClass:(NSString *)sourceClass
                     nativeValue:(NSNumber *)nativeNumber
                    overrideValue:(NSNumber *)overrideNumber
                         removed:(BOOL)removed {
    NSDictionary<NSString *, id> *metadata = [self.catalog metadataForSelector:selector sourceClass:sourceClass] ?: @{};
    YTABLabFlag *flag = [YTABLabFlag new];
    flag.rawSelector = selector ?: @"";
    flag.sourceClass = sourceClass ?: @"Unknown source";
    flag.readableTitle = metadata[YTABLabMetadataTitleKey] ?: YTABReadableTitle(flag.rawSelector);
    flag.flagDescription = metadata[YTABLabMetadataDescriptionKey] ?: YTABUnknownDescription;
    flag.status = removed ? @"Removed" : (metadata[YTABLabMetadataStatusKey] ?: YTABUnknownStatus);
    flag.category = metadata[YTABLabMetadataCategoryKey] ?: @"Uncatalogued";
    flag.risk = metadata[YTABLabMetadataRiskKey] ?: @"Risk unknown";
    flag.evidence = metadata[YTABLabMetadataEvidenceKey] ?: YTABUnknownEvidence;
    flag.hasNativeValue = nativeNumber != nil;
    flag.nativeValue = nativeNumber.boolValue;
    flag.hasOverride = overrideNumber != nil;
    flag.hasEffectiveValue = !removed && nativeNumber != nil;
    flag.effectiveValue = overrideNumber ? overrideNumber.boolValue : nativeNumber.boolValue;
    flag.documented = [metadata[YTABLabMetadataDocumentedKey] boolValue];
    flag.removed = removed;
    return flag;
}

- (NSArray<YTABLabFlag *> *)allFlags {
    NSDictionary *runtime = self.nativeValues ?: @{};
    NSDictionary *overrides = YTABCopyOverrideValues() ?: @{};
    NSMutableArray<YTABLabFlag *> *flags = [NSMutableArray array];
    NSMutableSet<NSString *> *runtimeKeys = [NSMutableSet set];

    NSArray *classes = [[runtime allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *sourceClass in classes) {
        NSDictionary *methods = runtime[sourceClass];
        NSArray *selectors = [[methods allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *selector in selectors) {
            NSString *fullKey = [NSString stringWithFormat:@"%@.%@", sourceClass, selector];
            [runtimeKeys addObject:fullKey];
            NSNumber *override = YTABValidOverrideNumber(overrides[[YTABPreferencePrefix stringByAppendingString:fullKey]]);
            [flags addObject:[self flagForSelector:selector
                                      sourceClass:sourceClass
                                      nativeValue:methods[selector]
                                     overrideValue:override
                                          removed:NO]];
        }
    }

    for (NSString *preferenceKey in overrides) {
        if (![preferenceKey hasPrefix:YTABPreferencePrefix]) continue;
        NSString *runtimeKey = [preferenceKey substringFromIndex:YTABPreferencePrefix.length];
        if ([runtimeKeys containsObject:runtimeKey]) continue;
        NSRange separator = [runtimeKey rangeOfString:@"."];
        NSString *sourceClass = separator.location == NSNotFound ? @"Unknown source" : [runtimeKey substringToIndex:separator.location];
        NSString *selector = separator.location == NSNotFound ? runtimeKey : [runtimeKey substringFromIndex:separator.location + 1];
        NSNumber *override = YTABValidOverrideNumber(overrides[preferenceKey]);
        if (!override) continue;
        [flags addObject:[self flagForSelector:selector
                                  sourceClass:sourceClass
                                  nativeValue:nil
                                 overrideValue:override
                                      removed:YES]];
    }

    [flags sortUsingComparator:^NSComparisonResult(YTABLabFlag *left, YTABLabFlag *right) {
        return [left.readableTitle localizedCaseInsensitiveCompare:right.readableTitle];
    }];
    return flags;
}

- (BOOL)setOverrideValue:(BOOL)value forFlag:(YTABLabFlag *)flag {
    if (flag.removed) return NO;
    return YTABCSetOverride(flag.sourceClass, flag.rawSelector, value);
}

- (BOOL)resetOverrideForFlag:(YTABLabFlag *)flag {
    if (!flag.hasOverride) return YES;
    if (flag.removed) {
        return YTABResetRuntimeOverride(flag.sourceClass, flag.rawSelector, flag.nativeValue);
    }
    return YTABCClearOverride(flag.sourceClass, flag.rawSelector);
}

- (BOOL)resetAllOverrides {
    return YTABResetAllRuntimeOverrides(self.nativeValues ?: @{});
}

- (YTABLabFlag *)refreshedFlagMatchingFlag:(YTABLabFlag *)flag {
    if (!flag) return nil;
    NSNumber *native = self.nativeValues[flag.sourceClass][flag.rawSelector];
    NSString *preferenceKey = [YTABPreferencePrefix stringByAppendingFormat:@"%@.%@", flag.sourceClass, flag.rawSelector];
    NSNumber *override = native
        ? YTABCOverrideValue(flag.sourceClass, flag.rawSelector)
        : YTABValidOverrideNumber(YTABCopyOverrideValues()[preferenceKey]);
    if (!native && !override) return nil;
    return [self flagForSelector:flag.rawSelector
                    sourceClass:flag.sourceClass
                    nativeValue:native
                   overrideValue:override
                        removed:native == nil];
}

- (NSString *)exportText {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObjects:
        @"YTABConfig / Afterglow Labs Feature Lab",
        @"Included classes: YTGlobalConfig, YTColdConfig, YTHotConfig",
        nil];
    for (YTABLabFlag *flag in [self allFlags]) {
        if (flag.removed) continue;
        [lines addObject:[NSString stringWithFormat:@"%@.%@: %d",
            flag.sourceClass, flag.rawSelector, flag.effectiveValue]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSDictionary<NSString *, id> *)runtimeExportDocumentWithRuntimeSnapshot:
        (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)runtimeSnapshot
    preferenceOverrides:(NSDictionary<NSString *, NSNumber *> *)preferenceOverrides
             exportedAt:(NSString *)exportedAt {
    NSMutableSet<NSString *> *runtimeKeys =
        [NSMutableSet setWithArray:runtimeSnapshot.allKeys ?: @[]];
    for (NSString *preferenceKey in preferenceOverrides) {
        if (![preferenceKey hasPrefix:YTABPreferencePrefix]) continue;
        NSString *runtimeKey = [preferenceKey substringFromIndex:YTABPreferencePrefix.length];
        NSString *sourceClass = nil;
        NSString *selector = nil;
        if (YTABParseRuntimeKey(runtimeKey, &sourceClass, &selector)) {
            [runtimeKeys addObject:runtimeKey];
        }
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *records =
        [NSMutableArray arrayWithCapacity:runtimeKeys.count];
    for (NSString *runtimeKey in runtimeKeys) {
        NSString *sourceClass = nil;
        NSString *selector = nil;
        if (!YTABParseRuntimeKey(runtimeKey, &sourceClass, &selector)) continue;

        NSDictionary<NSString *, id> *runtimeState = runtimeSnapshot[runtimeKey];
        BOOL removed = runtimeState == nil;
        NSNumber *native = removed ? nil : YTABValidOverrideNumber(runtimeState[@"native"]);
        NSString *nativeCapturedAt =
            [runtimeState[@"nativeCapturedAt"] isKindOfClass:NSString.class]
                ? runtimeState[@"nativeCapturedAt"]
                : nil;
        if (!nativeCapturedAt) native = nil;

        NSNumber *override = removed
            ? YTABValidOverrideNumber(
                preferenceOverrides[[YTABPreferencePrefix stringByAppendingString:runtimeKey]])
            : YTABValidOverrideNumber(runtimeState[@"override"]);
        if (removed && !override) continue;

        NSNumber *effective = override ?: native;
        YTABLabFlag *flag = [self flagForSelector:selector
                                      sourceClass:sourceClass
                                      nativeValue:native
                                     overrideValue:override
                                          removed:removed];
        id summary = flag.documented
            ? YTABBoundedExportString(flag.flagDescription, nil)
            : nil;

        [records addObject:@{
            @"class": YTABBoundedExportString(sourceClass, @"YTGlobalConfig"),
            @"selector": YTABBoundedExportString(selector, @"unknownSelector"),
            @"native": @{
                @"value": native ?: NSNull.null,
                @"source": native ? @"runtime" : @"unavailable",
                @"capturedAt": native ? nativeCapturedAt : NSNull.null,
            },
            @"override": @{
                @"mode": override ? (override.boolValue ? @"force-on" : @"force-off") : @"inherit",
                @"value": override ?: NSNull.null,
            },
            @"effective": @{
                @"value": effective ?: NSNull.null,
                @"source": override ? @"override" : (native ? @"native" : @"unavailable"),
            },
            @"title": YTABBoundedExportString(flag.readableTitle, @"Untitled Flag"),
            @"summary": summary ?: NSNull.null,
            @"category": YTABBoundedExportString(flag.category, @"Uncatalogued"),
            @"risk": YTABExportRisk(flag.risk),
            @"status": YTABExportStatus(flag.status),
        }];
    }
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSArray<NSString *> *leftValues = @[left[@"category"], left[@"title"], left[@"class"], left[@"selector"]];
        NSArray<NSString *> *rightValues = @[right[@"category"], right[@"title"], right[@"class"], right[@"selector"]];
        for (NSUInteger index = 0; index < leftValues.count; index++) {
            NSComparisonResult result = [leftValues[index] localizedCaseInsensitiveCompare:rightValues[index]];
            if (result != NSOrderedSame) return result;
        }
        return NSOrderedSame;
    }];

    NSBundle *mainBundle = NSBundle.mainBundle;
    NSString *youtubeVersion = YTABBoundedExportString(
        [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], @"Unknown");
    NSString *bundleIdentifier = YTABBoundedExportString(mainBundle.bundleIdentifier, @"Unknown");
    NSString *osVersion = YTABBoundedExportString(UIDevice.currentDevice.systemVersion, @"Unknown");
    NSString *tweakVersion = YTABBoundedExportString(
        [NSString stringWithUTF8String:YTAB_STRINGIFY(TWEAK_VERSION)], @"Unknown");
    return @{
        @"schemaVersion": @1,
        @"exportedAt": exportedAt,
        @"youtubeVersion": youtubeVersion,
        @"tweakVersion": tweakVersion,
        @"context": @{
            @"applicationIdentifier": bundleIdentifier,
            @"platform": @"iOS",
            @"osVersion": osVersion,
            @"recordCount": @(records.count),
        },
        @"records": records,
    };
}

- (void)writeJSONExportWithCompletion:(YTABLabJSONExportCompletion)completion {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *exportedAt = YTABExportTimestamp();
            NSDictionary *runtimeSnapshot = YTABCRuntimeSnapshot() ?: @{};
            NSDictionary *preferenceOverrides = YTABCopyOverrideValues() ?: @{};
            NSDictionary *document = [self
                runtimeExportDocumentWithRuntimeSnapshot:runtimeSnapshot
                preferenceOverrides:preferenceOverrides
                exportedAt:exportedAt];
            NSError *error = nil;
            NSData *data = nil;
            if ([NSJSONSerialization isValidJSONObject:document]) {
                data = [NSJSONSerialization dataWithJSONObject:document
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&error];
            } else {
                error = YTABExportError(1, @"Runtime state contains a value that cannot be encoded as JSON.");
            }

            NSURL *fileURL = nil;
            if (data && !error) {
                NSString *filename = [NSString stringWithFormat:@"YTABConfig-runtime-%@.json", NSUUID.UUID.UUIDString];
                fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
                if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) fileURL = nil;
            }
            if (!fileURL && !error) error = YTABExportError(2, @"The runtime JSON file could not be written.");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(fileURL, error);
            });
        }
    });
}

- (NSUInteger)importText:(NSString *)text {
    if (text.length == 0) return 0;
    NSMutableDictionary<NSString *, YTABLabFlag *> *flagsByKey = [NSMutableDictionary dictionary];
    for (YTABLabFlag *flag in [self allFlags]) {
        if (!flag.removed) flagsByKey[[NSString stringWithFormat:@"%@.%@", flag.sourceClass, flag.rawSelector]] = flag;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(YT.*Config\\..*):\\s*([01])\\s*$"
                                                                           options:0
                                                                             error:nil];
    NSMutableDictionary<NSString *, NSNumber *> *pendingValues = [NSMutableDictionary dictionary];
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!match || match.numberOfRanges < 3) return;
        NSString *key = [line substringWithRange:[match rangeAtIndex:1]];
        if (!flagsByKey[key]) return;
        pendingValues[key] = @([[line substringWithRange:[match rangeAtIndex:2]] boolValue]);
    }];

    NSUInteger imported = 0;
    for (NSString *key in pendingValues) {
        YTABLabFlag *flag = flagsByKey[key];
        BOOL value = pendingValues[key].boolValue;
        if ((!flag.hasOverride && flag.nativeValue == value) ||
            (flag.hasOverride && flag.effectiveValue == value)) continue;
        if ([self setOverrideValue:value forFlag:flag]) imported++;
    }
    return imported;
}

@end

@interface YTABLabDetailViewController : UITableViewController
@property(nonatomic, strong) id<YTABLabRuntimeProviding> provider;
@property(nonatomic, strong) YTABLabFlag *flag;
- (instancetype)initWithFlag:(YTABLabFlag *)flag provider:(id<YTABLabRuntimeProviding>)provider;
@end

@interface YTABLabListViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) id<YTABLabRuntimeProviding> provider;
@property(nonatomic, assign) YTABLabListMode mode;
@property(nonatomic, copy) NSArray<YTABLabFlag *> *flags;
@property(nonatomic, copy) NSArray<YTABLabFlag *> *visibleFlags;
@property(nonatomic, strong) UISearchController *searchController;
- (instancetype)initWithProvider:(id<YTABLabRuntimeProviding>)provider
                            mode:(YTABLabListMode)mode
                           title:(NSString *)title
                     beginSearch:(BOOL)beginSearch;
@end

static YTABLabFlag *YTABRefreshedFlag(id<YTABLabRuntimeProviding> provider, YTABLabFlag *flag) {
    if ([provider respondsToSelector:@selector(refreshedFlagMatchingFlag:)]) {
        return [provider refreshedFlagMatchingFlag:flag] ?: flag;
    }
    for (YTABLabFlag *candidate in [provider allFlags]) {
        if ([candidate.sourceClass isEqualToString:flag.sourceClass] &&
            [candidate.rawSelector isEqualToString:flag.rawSelector]) {
            return candidate;
        }
    }
    return flag;
}

@implementation YTABLabListViewController

- (instancetype)initWithProvider:(id<YTABLabRuntimeProviding>)provider
                            mode:(YTABLabListMode)mode
                           title:(NSString *)title
                     beginSearch:(BOOL)beginSearch {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _provider = provider;
        _mode = mode;
        self.title = title;
        _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        _searchController.searchResultsUpdater = self;
        _searchController.obscuresBackgroundDuringPresentation = NO;
        _searchController.searchBar.placeholder = @"Readable title or raw selector";
        self.navigationItem.searchController = _searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = !beginSearch;
        self.definesPresentationContext = YES;
        if (beginSearch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.searchController.active = YES;
                [self.searchController.searchBar becomeFirstResponder];
            });
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    YTABConfigureSelfSizingTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFlags];
}

- (void)reloadFlags {
    NSArray *allFlags = [self.provider allFlags];
    NSPredicate *predicate = nil;
    switch (self.mode) {
        case YTABLabListModeDocumented:
            predicate = [NSPredicate predicateWithBlock:^BOOL(YTABLabFlag *flag, NSDictionary *bindings) {
                return flag.documented && !flag.removed;
            }];
            break;
        case YTABLabListModeModified:
            predicate = [NSPredicate predicateWithBlock:^BOOL(YTABLabFlag *flag, NSDictionary *bindings) {
                return flag.hasOverride;
            }];
            break;
        case YTABLabListModeNeedsReview:
            predicate = [NSPredicate predicateWithBlock:^BOOL(YTABLabFlag *flag, NSDictionary *bindings) {
                return !flag.documented || flag.removed;
            }];
            break;
        case YTABLabListModeAll:
            break;
    }
    self.flags = predicate ? [allFlags filteredArrayUsingPredicate:predicate] : allFlags;
    [self applySearchText:self.searchController.searchBar.text];
}

- (void)applySearchText:(NSString *)text {
    NSString *query = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.visibleFlags = self.flags;
    } else {
        self.visibleFlags = [self.flags filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(YTABLabFlag *flag, NSDictionary *bindings) {
            return [flag.readableTitle rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [flag.rawSelector rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [flag.sourceClass rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        }]];
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applySearchText:searchController.searchBar.text];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleFlags.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%lu flags", (unsigned long)self.visibleFlags.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mode == YTABLabListModeAll)
        return @"Raw Lab is the complete runtime list. Uncatalogued flags stay explicitly unknown until verified.";
    if (self.visibleFlags.count == 0)
        return @"Nothing matches this collection yet.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTABLabFlagCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    YTABLabFlag *flag = self.visibleFlags[indexPath.row];
    cell.textLabel.text = flag.readableTitle;
    cell.textLabel.numberOfLines = 2;
    NSString *native = flag.hasNativeValue ? [NSString stringWithFormat:@"Native %@", YTABBooleanText(flag.nativeValue)] : @"Native unavailable";
    NSString *effective = flag.hasEffectiveValue
        ? [NSString stringWithFormat:@"Effective %@", YTABBooleanText(flag.effectiveValue)]
        : @"Effective unavailable";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@ / %@\n%@ · %@",
        flag.status, flag.category, flag.risk, native, effective];
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 122, 32)];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(0, 0, 58, 32);
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    reset.enabled = flag.hasOverride;
    reset.alpha = flag.hasOverride ? 1.0 : 0.35;
    reset.accessibilityLabel = [NSString stringWithFormat:@"Reset override for %@", flag.readableTitle];
    reset.accessibilityHint = flag.removed
        ? [NSString stringWithFormat:@"Removes the stored override for the removed selector %@.%@",
            flag.sourceClass, flag.rawSelector]
        : [NSString stringWithFormat:@"Restores the native value for %@.%@",
            flag.sourceClass, flag.rawSelector];
    [reset addTarget:self action:@selector(resetTapped:) forControlEvents:UIControlEventTouchUpInside];
    [accessory addSubview:reset];
    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectMake(64, 0, 58, 32)];
    toggle.on = flag.effectiveValue;
    toggle.enabled = !flag.removed;
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Override %@", flag.readableTitle];
    toggle.accessibilityValue = flag.hasEffectiveValue ? YTABBooleanText(flag.effectiveValue) : @"Unavailable";
    toggle.accessibilityHint = [NSString stringWithFormat:@"Changes %@.%@", flag.sourceClass, flag.rawSelector];
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [accessory addSubview:toggle];
    cell.accessoryView = accessory;
    return cell;
}

- (NSIndexPath *)indexPathForControl:(UIView *)control {
    CGPoint point = [control convertPoint:CGPointZero toView:self.tableView];
    return [self.tableView indexPathForRowAtPoint:point];
}

- (void)resetTapped:(UIButton *)sender {
    NSIndexPath *indexPath = [self indexPathForControl:sender];
    if (!indexPath || indexPath.row >= self.visibleFlags.count) return;
    if ([self.provider resetOverrideForFlag:self.visibleFlags[indexPath.row]]) [self reloadFlags];
}

- (void)toggleChanged:(UISwitch *)sender {
    NSIndexPath *indexPath = [self indexPathForControl:sender];
    if (!indexPath || indexPath.row >= self.visibleFlags.count) return;
    if ([self.provider setOverrideValue:sender.on forFlag:self.visibleFlags[indexPath.row]]) {
        [self reloadFlags];
    } else {
        [sender setOn:!sender.on animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTABLabDetailViewController *detail = [[YTABLabDetailViewController alloc] initWithFlag:self.visibleFlags[indexPath.row]
                                                                                   provider:self.provider];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

@implementation YTABLabDetailViewController

- (instancetype)initWithFlag:(YTABLabFlag *)flag provider:(id<YTABLabRuntimeProviding>)provider {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _flag = flag;
        _provider = provider;
        self.title = flag.readableTitle;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    YTABConfigureSelfSizingTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.flag = YTABRefreshedFlag(self.provider, self.flag);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 4;
    if (section == 2) return 3;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Research", @"Identity", @"Values", @"Actions"][section];
}

- (UITableViewCell *)detailCellWithTitle:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTABLabFlag *flag = self.flag;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) return [self detailCellWithTitle:@"Description" value:flag.flagDescription];
        return [self detailCellWithTitle:@"Status / evidence"
                                   value:[NSString stringWithFormat:@"%@\n%@", flag.status, flag.evidence]];
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) return [self detailCellWithTitle:@"Raw selector" value:flag.rawSelector];
        if (indexPath.row == 1) return [self detailCellWithTitle:@"Source class" value:flag.sourceClass];
        if (indexPath.row == 2) return [self detailCellWithTitle:@"Category" value:flag.category];
        return [self detailCellWithTitle:@"Risk" value:flag.risk];
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            return [self detailCellWithTitle:@"Native value"
                                      value:flag.hasNativeValue ? YTABBooleanText(flag.nativeValue) : @"Unavailable (removed)"];
        }
        if (indexPath.row == 1) {
            UITableViewCell *cell = [self detailCellWithTitle:@"Override value"
                                                       value:flag.hasOverride ? YTABBooleanText(flag.effectiveValue) : @"Not set"];
            UISwitch *toggle = [UISwitch new];
            toggle.on = flag.effectiveValue;
            toggle.enabled = !flag.removed;
            toggle.accessibilityLabel = [NSString stringWithFormat:@"Override %@", flag.readableTitle];
            toggle.accessibilityValue = flag.hasEffectiveValue ? YTABBooleanText(flag.effectiveValue) : @"Unavailable";
            toggle.accessibilityHint = [NSString stringWithFormat:@"Changes %@.%@", flag.sourceClass, flag.rawSelector];
            [toggle addTarget:self action:@selector(detailToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            return cell;
        }
        return [self detailCellWithTitle:@"Effective value"
                                   value:flag.hasEffectiveValue ? YTABBooleanText(flag.effectiveValue) : @"Unavailable"];
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Reset Override";
        cell.textLabel.textColor = flag.hasOverride ? self.view.tintColor : [UIColor grayColor];
        cell.selectionStyle = flag.hasOverride ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Copy Raw Selector";
    }
    return cell;
}

- (void)detailToggleChanged:(UISwitch *)sender {
    if ([self.provider setOverrideValue:sender.on forFlag:self.flag]) {
        self.flag = YTABRefreshedFlag(self.provider, self.flag);
        [self.tableView reloadData];
    } else {
        [sender setOn:!sender.on animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 3) return;
    if (indexPath.row == 0 && self.flag.hasOverride) {
        if ([self.provider resetOverrideForFlag:self.flag]) {
            self.flag = YTABRefreshedFlag(self.provider, self.flag);
            [self.tableView reloadData];
        }
    } else if (indexPath.row == 1) {
        [UIPasteboard generalPasteboard].string = self.flag.rawSelector;
    }
}

@end

@interface YTABLabDashboardViewController ()
@property(nonatomic, strong) id<YTABLabRuntimeProviding> provider;
@property(nonatomic, copy) NSArray<YTABLabFlag *> *flags;
@end

@implementation YTABLabDashboardViewController

- (instancetype)initWithProvider:(id<YTABLabRuntimeProviding>)provider {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _provider = provider;
        self.title = @"Feature Lab";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    YTABConfigureSelfSizingTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.flags = [self.provider allFlags];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray<NSNumber *> *rowCounts = @[@1, @3, @1, @1, @4];
    return rowCounts[section].integerValue;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Discover", @"Collections", @"Override Recovery", @"Experimental", @"Export & Recovery"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Search checks readable titles, raw selectors, and source classes.";
    if (section == 2) return @"Reset removes overrides. The native app values remain the source of truth.";
    if (section == 3) return @"Raw Lab is deliberately separated from curated features and contains the complete runtime list.";
    return nil;
}

- (NSUInteger)countForMode:(YTABLabListMode)mode {
    NSUInteger count = 0;
    for (YTABLabFlag *flag in self.flags) {
        if (mode == YTABLabListModeDocumented && flag.documented && !flag.removed) count++;
        else if (mode == YTABLabListModeModified && flag.hasOverride) count++;
        else if (mode == YTABLabListModeNeedsReview && (!flag.documented || flag.removed)) count++;
        else if (mode == YTABLabListModeAll) count++;
    }
    return count;
}

- (UITableViewCell *)navigationCellWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = subtitle;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return [self navigationCellWithTitle:@"Search"
                                   subtitle:[NSString stringWithFormat:@"Find across %lu runtime flags", (unsigned long)self.flags.count]];
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0)
            return [self navigationCellWithTitle:@"Curated / Documented"
                                       subtitle:[NSString stringWithFormat:@"%lu flags with verified catalog entries",
                                           (unsigned long)[self countForMode:YTABLabListModeDocumented]]];
        if (indexPath.row == 1)
            return [self navigationCellWithTitle:@"Modified"
                                       subtitle:[NSString stringWithFormat:@"%lu active overrides",
                                           (unsigned long)[self countForMode:YTABLabListModeModified]]];
        return [self navigationCellWithTitle:@"Needs Review · Uncatalogued · Removed"
                                   subtitle:[NSString stringWithFormat:@"%lu uncatalogued or removed flags",
                                       (unsigned long)[self countForMode:YTABLabListModeNeedsReview]]];
    }
    if (indexPath.section == 2) {
        UITableViewCell *cell = [self navigationCellWithTitle:@"Restore Native Behavior"
                                                    subtitle:@"Reset every feature override"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (indexPath.section == 3) {
        return [self navigationCellWithTitle:@"Raw Lab"
                                   subtitle:[NSString stringWithFormat:@"Complete runtime list · %lu flags",
                                       (unsigned long)[self countForMode:YTABLabListModeAll]]];
    }

    NSArray *titles = @[@"Share Runtime Report (.json)", @"Copy Legacy Text Export",
                        @"Import Overrides from Clipboard", @"Reset All Overrides"];
    NSArray *subtitles = @[@"Share structured native, override, effective, and catalog state",
                           @"Copy the compatible Class.selector: 0/1 format",
                           @"Apply recognized runtime flags only",
                           @"Remove overrides without changing native values"];
    UITableViewCell *cell = [self navigationCellWithTitle:titles[indexPath.row] subtitle:subtitles[indexPath.row]];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.row == 3) cell.textLabel.textColor = [UIColor redColor];
    return cell;
}

- (void)pushListWithMode:(YTABLabListMode)mode title:(NSString *)title beginSearch:(BOOL)beginSearch {
    YTABLabListViewController *controller = [[YTABLabListViewController alloc] initWithProvider:self.provider
                                                                                           mode:mode
                                                                                          title:title
                                                                                    beginSearch:beginSearch];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)confirmResetWithTitle:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"This removes all Feature Lab overrides and restores native runtime behavior."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset Overrides"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        if ([self.provider resetAllOverrides]) {
            self.flags = [self.provider allFlags];
            [self.tableView reloadData];
        } else {
            [self showMessage:@"Some overrides could not be reset. Runtime state was left unchanged where the operation failed."];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Feature Lab"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareJSONExport {
    __weak typeof(self) weakSelf = self;
    [self.provider writeJSONExportWithCompletion:^(NSURL *fileURL, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!fileURL || error || ![fileURL.pathExtension.lowercaseString isEqualToString:@"json"]) {
            [strongSelf showMessage:error.localizedDescription ?: @"The runtime JSON export could not be created."];
            return;
        }

        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:@[fileURL]
            applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        if (popover) {
            popover.sourceView = strongSelf.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(strongSelf.view.bounds),
                                            CGRectGetMidY(strongSelf.view.bounds), 1.0, 1.0);
            popover.permittedArrowDirections = 0;
        }
        activity.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                                NSArray *returnedItems, NSError *activityError) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            });
        };
        [strongSelf presentViewController:activity animated:YES completion:nil];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self pushListWithMode:YTABLabListModeAll title:@"Search" beginSearch:YES];
    } else if (indexPath.section == 1) {
        NSArray *titles = @[@"Curated / Documented", @"Modified", @"Needs Review"];
        NSArray *modes = @[@(YTABLabListModeDocumented), @(YTABLabListModeModified), @(YTABLabListModeNeedsReview)];
        [self pushListWithMode:[modes[indexPath.row] unsignedIntegerValue] title:titles[indexPath.row] beginSearch:NO];
    } else if (indexPath.section == 2) {
        [self confirmResetWithTitle:@"Restore Native Behavior?"];
    } else if (indexPath.section == 3) {
        [self pushListWithMode:YTABLabListModeAll title:@"Raw Lab" beginSearch:NO];
    } else if (indexPath.row == 0) {
        [self shareJSONExport];
    } else if (indexPath.row == 1) {
        [UIPasteboard generalPasteboard].string = [self.provider exportText];
        [self showMessage:@"Legacy text export copied to the clipboard."];
    } else if (indexPath.row == 2) {
        NSUInteger count = [self.provider importText:[UIPasteboard generalPasteboard].string ?: @""];
        self.flags = [self.provider allFlags];
        [self.tableView reloadData];
        [self showMessage:count ? [NSString stringWithFormat:@"Imported %lu recognized overrides.", (unsigned long)count]
                                : @"No override changes were applied."];
    } else {
        [self confirmResetWithTitle:@"Reset All Overrides?"];
    }
}

@end
