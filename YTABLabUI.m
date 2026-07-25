#import "YTABLabUI.h"

extern NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *YTABCopyRuntimeValues(void);
extern NSDictionary<NSString *, NSNumber *> *YTABCopyOverrideValues(void);
extern void YTABSetRuntimeOverride(NSString *sourceClass, NSString *selector, BOOL value);
extern void YTABResetRuntimeOverride(NSString *sourceClass, NSString *selector, BOOL nativeValue);
extern void YTABResetAllRuntimeOverrides(NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *nativeValues);

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

typedef NS_ENUM(NSUInteger, YTABLabListMode) {
    YTABLabListModeAll,
    YTABLabListModeDocumented,
    YTABLabListModeModified,
    YTABLabListModeNeedsReview,
};

static NSString *YTABBooleanText(BOOL value) {
    return value ? @"On" : @"Off";
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
            NSNumber *override = overrides[[YTABPreferencePrefix stringByAppendingString:fullKey]];
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
        [flags addObject:[self flagForSelector:selector
                                  sourceClass:sourceClass
                                  nativeValue:nil
                                 overrideValue:overrides[preferenceKey]
                                      removed:YES]];
    }

    [flags sortUsingComparator:^NSComparisonResult(YTABLabFlag *left, YTABLabFlag *right) {
        return [left.readableTitle localizedCaseInsensitiveCompare:right.readableTitle];
    }];
    return flags;
}

- (void)setOverrideValue:(BOOL)value forFlag:(YTABLabFlag *)flag {
    if (flag.removed) return;
    YTABSetRuntimeOverride(flag.sourceClass, flag.rawSelector, value);
}

- (void)resetOverrideForFlag:(YTABLabFlag *)flag {
    YTABResetRuntimeOverride(flag.sourceClass, flag.rawSelector, flag.nativeValue);
}

- (void)resetAllOverrides {
    YTABResetAllRuntimeOverrides(self.nativeValues ?: @{});
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

- (NSUInteger)importText:(NSString *)text {
    if (text.length == 0) return 0;
    NSMutableDictionary<NSString *, YTABLabFlag *> *flagsByKey = [NSMutableDictionary dictionary];
    for (YTABLabFlag *flag in [self allFlags]) {
        if (!flag.removed) flagsByKey[[NSString stringWithFormat:@"%@.%@", flag.sourceClass, flag.rawSelector]] = flag;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(YT.*Config\\..*):\\s*([01])\\s*$"
                                                                           options:0
                                                                             error:nil];
    __block NSUInteger imported = 0;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!match || match.numberOfRanges < 3) return;
        NSString *key = [line substringWithRange:[match rangeAtIndex:1]];
        YTABLabFlag *flag = flagsByKey[key];
        if (!flag) return;
        BOOL value = [[line substringWithRange:[match rangeAtIndex:2]] boolValue];
        if ((!flag.hasOverride && flag.nativeValue == value) ||
            (flag.hasOverride && flag.effectiveValue == value)) return;
        [self setOverrideValue:value forFlag:flag];
        imported++;
    }];
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
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@ / %@\n%@ · Effective %@",
        flag.status, flag.category, flag.risk, native, YTABBooleanText(flag.effectiveValue)];
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 122, 32)];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(0, 0, 58, 32);
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    reset.enabled = flag.hasOverride;
    reset.alpha = flag.hasOverride ? 1.0 : 0.35;
    [reset addTarget:self action:@selector(resetTapped:) forControlEvents:UIControlEventTouchUpInside];
    [accessory addSubview:reset];
    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectMake(64, 0, 58, 32)];
    toggle.on = flag.effectiveValue;
    toggle.enabled = !flag.removed;
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
    [self.provider resetOverrideForFlag:self.visibleFlags[indexPath.row]];
    [self reloadFlags];
}

- (void)toggleChanged:(UISwitch *)sender {
    NSIndexPath *indexPath = [self indexPathForControl:sender];
    if (!indexPath || indexPath.row >= self.visibleFlags.count) return;
    [self.provider setOverrideValue:sender.on forFlag:self.visibleFlags[indexPath.row]];
    [self reloadFlags];
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
            [toggle addTarget:self action:@selector(detailToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            return cell;
        }
        return [self detailCellWithTitle:@"Effective value" value:YTABBooleanText(flag.effectiveValue)];
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
    [self.provider setOverrideValue:sender.on forFlag:self.flag];
    self.flag = YTABRefreshedFlag(self.provider, self.flag);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 3) return;
    if (indexPath.row == 0 && self.flag.hasOverride) {
        [self.provider resetOverrideForFlag:self.flag];
        self.flag = YTABRefreshedFlag(self.provider, self.flag);
        [self.tableView reloadData];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.flags = [self.provider allFlags];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray<NSNumber *> *rowCounts = @[@1, @3, @1, @1, @3];
    return rowCounts[section].integerValue;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Discover", @"Collections", @"Presets", @"Experimental", @"Clipboard & Recovery"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Search checks readable titles and raw selectors.";
    if (section == 2) return @"Presets only change overrides. The native app values remain the source of truth.";
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
        return [self navigationCellWithTitle:@"Needs Review · New · Removed"
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

    NSArray *titles = @[@"Export Current Settings", @"Import Overrides from Clipboard", @"Reset All Overrides"];
    NSArray *subtitles = @[@"Copy the compatible Class.selector: 0/1 format",
                           @"Apply recognized runtime flags only",
                           @"Remove overrides without changing native values"];
    UITableViewCell *cell = [self navigationCellWithTitle:titles[indexPath.row] subtitle:subtitles[indexPath.row]];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.row == 2) cell.textLabel.textColor = [UIColor redColor];
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
        [self.provider resetAllOverrides];
        self.flags = [self.provider allFlags];
        [self.tableView reloadData];
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
        [UIPasteboard generalPasteboard].string = [self.provider exportText];
        [self showMessage:@"Current settings copied to the clipboard."];
    } else if (indexPath.row == 1) {
        NSUInteger count = [self.provider importText:[UIPasteboard generalPasteboard].string ?: @""];
        self.flags = [self.provider allFlags];
        [self.tableView reloadData];
        [self showMessage:count ? [NSString stringWithFormat:@"Imported %lu recognized overrides.", (unsigned long)count]
                                : @"No recognized runtime overrides were found."];
    } else {
        [self confirmResetWithTitle:@"Reset All Overrides?"];
    }
}

@end
