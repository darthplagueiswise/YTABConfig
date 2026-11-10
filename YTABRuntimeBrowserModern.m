#import "YTABRuntimeBrowserModern.h"
#import <objc/message.h>
#import <objc/runtime.h>

// State is owned by the runtime hook engine, never duplicated in a UI cache.
extern BOOL YTABRuntimeBrowserApplyMode(NSString *patchKey, NSInteger mode);
extern NSNumber *YTABRuntimeBrowserNativeSample(NSString *patchKey);
extern BOOL YTABRuntimeBrowserPatchInstalled(NSString *patchKey);
extern BOOL YTABRuntimeBrowserObserveKey(NSString *patchKey);
extern NSNumber *YTABRuntimeBrowserOverrideValue(NSString *patchKey);
extern NSString * const YTABRuntimeNativeSampleChangedNotification;

// The runtime engine implements the filter; the UI only chooses where its
// search field is hosted.
@interface YTABRuntimeBrowserViewController (YTABModernFiltering)
- (void)applyFilter;
- (NSString *)ytab_currentSearchText;
- (UISearchController *)ytab_ownedSearchController;
@end

static NSString * const YTABModernOverridesKey = @"YTABCRuntimeBrowserOverrides";
static const void *YTABModernPatchKeyAssociation = &YTABModernPatchKeyAssociation;

typedef NS_ENUM(NSInteger, YTABModernPatchMode) {
    YTABModernPatchModeSystem = 0,
    YTABModernPatchModeForceOff = 1,
    YTABModernPatchModeForceOn = 2,
};

static YTABModernPatchMode YTABModernModeForKey(NSString *patchKey) {
    // A captured config getter uses the existing YTABC.* pref/key engine,
    // whereas generic Runtime methods use YTABCRuntimeBrowserOverrides.
    // Both modes are read from the SAME engine that applies them.
    NSNumber *override = YTABRuntimeBrowserOverrideValue(patchKey);
    if (!override) return YTABModernPatchModeSystem;
    return override.boolValue ? YTABModernPatchModeForceOn : YTABModernPatchModeForceOff;
}

static BOOL YTABModernSetModeForKey(YTABModernPatchMode mode, NSString *patchKey) {
    return YTABRuntimeBrowserApplyMode(patchKey, mode);
}

static NSString *YTABModernStringValue(id object, NSString *key) {
    if (!object || !key.length) return @"";
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSString.class] ? value : @"";
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

static BOOL YTABModernBoolValue(id object, NSString *key) {
    if (!object || !key.length) return NO;
    @try {
        id value = [object valueForKey:key];
        return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}


@interface YTABRuntimePatchCell : UITableViewCell
@property(nonatomic, strong) UILabel *selectorLabel;
@property(nonatomic, strong) UILabel *ownerLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UISwitch *overrideSwitch;
@property(nonatomic, strong) UILabel *unknownLabel;
@property(nonatomic, strong) UIButton *modeButton;
@end

@implementation YTABRuntimePatchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    // The selector is content, not a headline. Avoid fixed 15pt monospaced
    // fonts and long technical type encodings in the primary row.
    _selectorLabel = [UILabel new];
    _selectorLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium]];
    _selectorLabel.adjustsFontForContentSizeCategory = YES;
    _selectorLabel.numberOfLines = 2;
    _selectorLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_selectorLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisHorizontal];

    _ownerLabel = [UILabel new];
    _ownerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _ownerLabel.textColor = UIColor.secondaryLabelColor;
    _ownerLabel.numberOfLines = 1;
    _ownerLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _ownerLabel.adjustsFontForContentSizeCategory = YES;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 1;
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    [_statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    _overrideSwitch = [UISwitch new];
    _overrideSwitch.accessibilityLabel = @"Native boolean or effective override";
    [_overrideSwitch setContentHuggingPriority:UILayoutPriorityRequired
                                      forAxis:UILayoutConstraintAxisHorizontal];

    // Do not paint a never-observed System getter as OFF. The receiver and
    // arguments may be unavailable, and invoking arbitrary getters can
    // change app state. Render a neutral question mark until it executes.
    _unknownLabel = [UILabel new];
    _unknownLabel.text = @"—";
    _unknownLabel.textAlignment = NSTextAlignmentCenter;
    _unknownLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _unknownLabel.textColor = UIColor.tertiaryLabelColor;
    _unknownLabel.accessibilityLabel = @"Native result not observed; use Observe native calls from the context menu";
    _unknownLabel.hidden = YES;

    _modeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *))
        _modeButton.configuration = [UIButtonConfiguration glassButtonConfiguration];
    else if (@available(iOS 15.0, *))
        _modeButton.configuration = [UIButtonConfiguration tintedButtonConfiguration];
    _modeButton.showsMenuAsPrimaryAction = YES;
    _modeButton.accessibilityLabel = @"Choose System, Force OFF or Force ON";
    _modeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    [_modeButton setContentHuggingPriority:UILayoutPriorityRequired
                                  forAxis:UILayoutConstraintAxisHorizontal];

    // Hide the switch without letting UIStackView apply conflicting
    // "UISV-hiding" zero-width constraints against its intrinsic size.
    UIView *valueSlot = [UIView new];
    _overrideSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _unknownLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [valueSlot addSubview:_overrideSwitch];
    [valueSlot addSubview:_unknownLabel];
    [NSLayoutConstraint activateConstraints:@[
        [valueSlot.widthAnchor constraintGreaterThanOrEqualToConstant:58],
        [valueSlot.heightAnchor constraintGreaterThanOrEqualToConstant:32],
        [_overrideSwitch.centerXAnchor constraintEqualToAnchor:valueSlot.centerXAnchor],
        [_overrideSwitch.centerYAnchor constraintEqualToAnchor:valueSlot.centerYAnchor],
        [_unknownLabel.centerXAnchor constraintEqualToAnchor:valueSlot.centerXAnchor],
        [_unknownLabel.centerYAnchor constraintEqualToAnchor:valueSlot.centerYAnchor],
    ]];

    UIStackView *headline = [[UIStackView alloc] initWithArrangedSubviews:@[
        _selectorLabel, valueSlot
    ]];
    headline.axis = UILayoutConstraintAxisHorizontal;
    headline.alignment = UIStackViewAlignmentCenter;
    headline.spacing = 12.0;

    UIStackView *stateRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        _statusLabel, _modeButton
    ]];
    stateRow.axis = UILayoutConstraintAxisHorizontal;
    stateRow.alignment = UIStackViewAlignmentCenter;
    stateRow.spacing = 8.0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        headline, _ownerLabel, stateRow
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [_modeButton.heightAnchor constraintGreaterThanOrEqualToConstant:26],
    ]];
    return self;
}
@end

@interface YTABRuntimeBrowserModernViewController () <UISearchBarDelegate, UIContextMenuInteractionDelegate>
@property(nonatomic, strong) UIView *scopeHeaderView;
@property(nonatomic, strong) UILabel *scopeHeaderLabel;
@property(nonatomic, strong) UISearchBar *pinnedSearchBar;
@property(nonatomic) BOOL usesNativeSearchToolbar;
@property(nonatomic) BOOL priorToolbarHidden;
@property(nonatomic) BOOL capturedPriorToolbarHidden;
@end

@implementation YTABRuntimeBrowserModernViewController

// Plain tables keep the section header pinned when the method list scrolls.
// Inset-grouped headers and iOS 26's automatic toolbar search can disappear
// behind YouTube's custom settings navigation container.
- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (NSArray *)ytab_visibleMethods {
    @try {
        id value = [self valueForKey:@"visibleMethods"];
        return [value isKindOfClass:NSArray.class] ? value : @[];
    } @catch (__unused NSException *exception) {
        return @[];
    }
}

- (id)ytab_methodAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *methods = [self ytab_visibleMethods];
    if ((NSUInteger)indexPath.row >= methods.count) return nil;
    return methods[(NSUInteger)indexPath.row];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Patches";
    self.navigationItem.titleView = nil;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74.0;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 18, 0);
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.definesPresentationContext = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(ytab_nativeSampleDidChange:)
        name:YTABRuntimeNativeSampleChangedNotification object:nil];

    // Use real UIKit toolbar placement. IntegratedButton keeps the search
    // collapsed until tapped and supplies the native Liquid Glass transition.
    // Only pre-26 builds use the separate fixed header search field.
    self.usesNativeSearchToolbar = NO;
    UISearchController *nativeSearch = [self ytab_ownedSearchController];
    if (@available(iOS 26.0, *)) {
        if (nativeSearch && self.navigationController) {
            self.usesNativeSearchToolbar = YES;
            self.navigationItem.searchController = nativeSearch;
            self.navigationItem.hidesSearchBarWhenScrolling = NO;
            self.navigationItem.preferredSearchBarPlacement =
                UINavigationItemSearchBarPlacementIntegratedButton;
            self.navigationItem.searchBarPlacementAllowsToolbarIntegration = YES;
            nativeSearch.searchBar.placeholder = @"Class or selector";
            nativeSearch.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
            nativeSearch.searchBar.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            UIBarButtonItem *searchItem =
                self.navigationItem.searchBarPlacementBarButtonItem;
            // Apple requires this placement item in toolbarItems, not a
            // navigation bar button group (which throws an exception).
            if (searchItem) self.toolbarItems = @[searchItem];
        }
    }
    if (!self.usesNativeSearchToolbar) {
        self.navigationItem.searchController = nil;
        UISearchBar *search = [[UISearchBar alloc] initWithFrame:CGRectZero];
        search.delegate = self;
        search.placeholder = @"Class or selector";
        search.searchBarStyle = UISearchBarStyleMinimal;
        search.autocorrectionType = UITextAutocorrectionTypeNo;
        search.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.pinnedSearchBar = search;
    }

    UISegmentedControl *scope = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scope = value;
    } @catch (__unused NSException *exception) {}
    [scope removeFromSuperview];

    CGFloat headerHeight = self.usesNativeSearchToolbar ? 50.0 : 102.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, headerHeight)];
    header.backgroundColor = [UIColor clearColor];
    if (self.pinnedSearchBar) [header addSubview:self.pinnedSearchBar];

    UILabel *sourceLabel = [UILabel new];
    sourceLabel.text = @"VIEW";
    sourceLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    sourceLabel.textColor = [UIColor secondaryLabelColor];
    sourceLabel.adjustsFontForContentSizeCategory = YES;
    [header addSubview:sourceLabel];
    if (scope) [header addSubview:scope];
    self.scopeHeaderView = header;
    self.scopeHeaderLabel = sourceLabel;
    // Do not set tableHeaderView: it would scroll the search out of sight.
    self.tableView.tableHeaderView = nil;
    // The iOS 26/27 floating glass search button is owned by YouTube's
    // navigation container. Reserve scrollable space beneath the last row.
    CGFloat searchClearance = self.usesNativeSearchToolbar ? 96.0 : 22.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, searchClearance, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, searchClearance, 0);

    UIImage *trash = nil;
    if (@available(iOS 13.0, *)) trash = [UIImage systemImageNamed:@"trash"];
    self.navigationItem.rightBarButtonItem = trash
        ? [[UIBarButtonItem alloc] initWithImage:trash
                                          style:UIBarButtonItemStylePlain
                                         target:self action:@selector(clearOverrides)]
        : [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                          style:UIBarButtonItemStylePlain
                                         target:self action:@selector(clearOverrides)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Clear only generic runtime method overrides";
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:YTABRuntimeNativeSampleChangedNotification object:nil];
}

- (void)ytab_nativeSampleDidChange:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytab_nativeSampleDidChange:notification];
        });
        return;
    }
    if (self.isViewLoaded && self.view.window) {
        // The getter ran for real. Update the visible switches without
        // re-invoking any YouTube method or changing the current filter.
        [self.tableView reloadData];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationItem.titleView = nil;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (self.usesNativeSearchToolbar && self.navigationController) {
        // Preserve this across child screens and subsequent reappearances.
        if (!self.capturedPriorToolbarHidden) {
            self.priorToolbarHidden = self.navigationController.isToolbarHidden;
            self.capturedPriorToolbarHidden = YES;
        }
        [self.navigationController setToolbarHidden:NO animated:animated];
    }
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.usesNativeSearchToolbar && self.navigationController &&
        (self.isMovingFromParentViewController || self.isBeingDismissed)) {
        [self.navigationController setToolbarHidden:self.priorToolbarHidden
                                          animated:animated];
        self.capturedPriorToolbarHidden = NO;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.scopeHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat searchHeight = self.usesNativeSearchToolbar ? 0.0 : 52.0;
    header.frame = CGRectMake(0, 0, width, searchHeight + 50.0);
    if (self.pinnedSearchBar)
        self.pinnedSearchBar.frame = CGRectMake(8, 0, MAX(0, width - 16), 52);
    self.scopeHeaderLabel.frame = CGRectMake(20, searchHeight + 1, MAX(0, width - 40), 14);
    UISegmentedControl *scope = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scope = value;
    } @catch (__unused NSException *exception) {}
    scope.frame = CGRectMake(16, searchHeight + 15, MAX(0, width - 32), 31);
}

- (NSString *)ytab_currentSearchText {
    return self.usesNativeSearchToolbar
        ? ([self ytab_ownedSearchController].searchBar.text ?: @"")
        : (self.pinnedSearchBar.text ?: @"");
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchBar != self.pinnedSearchBar) return;
    (void)searchText;
    // Parent engine filters using ytab_currentSearchText, overridden above.
    // There is no reliance on UISearchController activation or presentation.
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self applyFilter];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.usesNativeSearchToolbar ? 50.0 : 102.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.scopeHeaderView;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return nil; // pinned search + scope is the complete section header
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    // Native bottom-toolbar search can overlap long section footers.
    // Descriptions remain available through the row detail view.
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTABRuntimeGlassPatchCell";
    YTABRuntimePatchCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[YTABRuntimePatchCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:identifier];

    id method = [self ytab_methodAtIndexPath:indexPath];
    NSString *selectorName = YTABModernStringValue(method, @"selectorName");
    NSString *className = YTABModernStringValue(method, @"className");
    NSString *imageName = YTABModernStringValue(method, @"imageName");
    NSString *key = YTABModernStringValue(method, @"patchKey");
    BOOL isClassMethod = YTABModernBoolValue(method, @"classMethod");

    // Never leave a lone '-' at the beginning of a wrapped selector. The
    // owning class and method kind are already available in the subtitle.
    cell.selectorLabel.text = isClassMethod
        ? [NSString stringWithFormat:@"+ %@", selectorName]
        : selectorName;
    BOOL configFlag = YTABModernBoolValue(method, @"configFlag");
    cell.ownerLabel.text = configFlag
        ? [NSString stringWithFormat:@"%@ · captured at launch", className]
        : (imageName.length ? [NSString stringWithFormat:@"%@ · %@", className, imageName]
                            : className);

    YTABModernPatchMode mode = YTABModernModeForKey(key);
    NSNumber *native = YTABRuntimeBrowserNativeSample(key);
    BOOL installed = YTABRuntimeBrowserPatchInstalled(key);
    BOOL hasOverride = mode != YTABModernPatchModeSystem;
    BOOL nativeKnown = native != nil;
    BOOL effectiveKnown = hasOverride || nativeKnown;
    BOOL effectiveOn = hasOverride
        ? mode == YTABModernPatchModeForceOn
        : native.boolValue;
    NSString *nativeText = nativeKnown ? (native.boolValue ? @"ON" : @"OFF") : @"unknown";
    NSString *effectiveText = effectiveKnown ? (effectiveOn ? @"ON" : @"OFF") : @"unknown";

    // System true = green; true supplied by our override = blue.
    // False stays OFF in both modes; an override is still clearly labeled
    // blue, so Force OFF is never mistaken for an unmodified false.
    cell.overrideSwitch.onTintColor = hasOverride
        ? UIColor.systemBlueColor : UIColor.systemGreenColor;
    cell.statusLabel.textColor = hasOverride
        ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    cell.statusLabel.text = hasOverride
        ? [NSString stringWithFormat:@"Override %@ · Native %@%@",
            effectiveText, nativeText, !installed ? @" · Pending" : @""]
        : (nativeKnown
            ? [NSString stringWithFormat:@"System %@ · No override", nativeText]
            : @"Not observed · No override");

    [cell.overrideSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    [cell.overrideSwitch setOn:effectiveKnown && effectiveOn animated:NO];
    cell.overrideSwitch.hidden = !effectiveKnown;
    cell.unknownLabel.hidden = effectiveKnown;
    cell.overrideSwitch.accessibilityValue = [NSString stringWithFormat:
        @"Effective %@, %@. Last native %@",
        effectiveText, hasOverride ? @"override" : @"system", nativeText];
    cell.unknownLabel.accessibilityHint =
        @"The native Objective-C getter has not executed. This is not OFF or evidence of eligibility.";
    objc_setAssociatedObject(cell.overrideSwitch, YTABModernPatchKeyAssociation,
                             key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [cell.overrideSwitch addTarget:self action:@selector(overrideSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];

    // Native iOS context menu also works when long-pressing the switch.
    if (@available(iOS 13.0, *)) {
        BOOL attached = NO;
        for (id interaction in cell.overrideSwitch.interactions)
            if ([interaction isKindOfClass:[UIContextMenuInteraction class]]) attached = YES;
        if (!attached)
            [cell.overrideSwitch addInteraction:
                [[UIContextMenuInteraction alloc] initWithDelegate:self]];
    }

    NSString *modeLabel = mode == YTABModernPatchModeSystem ? @"System"
        : (mode == YTABModernPatchModeForceOn ? @"Force ON" : @"Force OFF");
    UIButtonConfiguration *configuration = cell.modeButton.configuration;
    if (configuration) {
        configuration.title = modeLabel;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(2, 8, 2, 8);
        configuration.titleTextAttributesTransformer =
            ^NSDictionary<NSAttributedStringKey, id> *
                (NSDictionary<NSAttributedStringKey, id> *incoming) {
            NSMutableDictionary<NSAttributedStringKey, id> *attributes = [incoming mutableCopy];
            attributes[NSFontAttributeName] =
                [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
                    scaledFontForFont:[UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium]];
            return attributes;
        };
        cell.modeButton.configuration = configuration;
    } else {
        [cell.modeButton setTitle:modeLabel forState:UIControlStateNormal];
    }
    cell.modeButton.menu = [self ytab_modeMenuForKey:key];
    cell.modeButton.accessibilityValue = modeLabel;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, native %@",
                               selectorName, modeLabel, nativeText];
    cell.accessibilityHint = @"Tap for details. Long press for System, Force ON, Force OFF and passive observation.";
    return cell;
}

- (UIMenu *)ytab_modeMenuForKey:(NSString *)key {
    __weak typeof(self) weakSelf = self;
    YTABModernPatchMode current = YTABModernModeForKey(key);
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"System", @"Force OFF", @"Force ON"];
    for (NSInteger index = 0; index < 3; index++) {
        YTABModernPatchMode chosen = (YTABModernPatchMode)index;
        UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)index]
                                             image:nil
                                        identifier:nil
                                           handler:^(__unused UIAction *ignored) {
            [weakSelf ytab_applyMode:chosen patchKey:key];
        }];
        action.state = chosen == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Runtime override" children:actions];
}

// Long press on the native table row OR its switch shows a UIKit context
// menu. System reverts immediately, without restarting or re-sampling
// an arbitrary Objective-C getter.
- (UIContextMenuConfiguration *)ytab_contextMenuForKey:(NSString *)key {
    if (!key.length) return nil;
    __weak typeof(self) weakSelf = self;
    NSString *capturedKey = [key copy];
    return [UIContextMenuConfiguration configurationWithIdentifier:capturedKey
        previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        YTABModernPatchMode current = YTABModernModeForKey(capturedKey);
        if (current != YTABModernPatchModeSystem) {
            UIAction *remove = [UIAction actionWithTitle:@"Remove override (System)"
                image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                identifier:nil handler:^(__unused UIAction *action) {
                [weakSelf ytab_applyMode:YTABModernPatchModeSystem patchKey:capturedKey];
            }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        UIAction *forceOn = [UIAction actionWithTitle:@"Force ON"
            image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil
            handler:^(__unused UIAction *action) {
                [weakSelf ytab_applyMode:YTABModernPatchModeForceOn patchKey:capturedKey];
            }];
        UIAction *forceOff = [UIAction actionWithTitle:@"Force OFF"
            image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil
            handler:^(__unused UIAction *action) {
                [weakSelf ytab_applyMode:YTABModernPatchModeForceOff patchKey:capturedKey];
            }];
        [actions addObjectsFromArray:@[forceOn, forceOff]];
        if (!YTABRuntimeBrowserPatchInstalled(capturedKey)) {
            UIAction *observe = [UIAction actionWithTitle:@"Observe native calls (pass-through)"
                image:[UIImage systemImageNamed:@"waveform.path.ecg"]
                identifier:nil handler:^(__unused UIAction *action) {
                if (!YTABRuntimeBrowserObserveKey(capturedKey))
                    [weakSelf ytab_showObserverUnavailable];
                [weakSelf.tableView reloadData];
            }];
            [actions addObject:observe];
        }
        return [UIMenu menuWithTitle:@"Runtime BOOL" children:actions];
    }];
}

- (void)ytab_showObserverUnavailable {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Native observation unavailable"
        message:@"This Objective-C getter could not be instrumented in the current build."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)tableView; (void)point;
    id method = [self ytab_methodAtIndexPath:indexPath];
    return [self ytab_contextMenuForKey:YTABModernStringValue(method, @"patchKey")];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    configurationForMenuAtLocation:(CGPoint)location {
    (void)location;
    NSString *key = objc_getAssociatedObject(interaction.view, YTABModernPatchKeyAssociation);
    return [self ytab_contextMenuForKey:key];
}

- (void)ytab_applyMode:(YTABModernPatchMode)mode patchKey:(NSString *)key {
    if (!key.length) return;
    if (!YTABModernSetModeForKey(mode, key)) {
        UIAlertController *error = [UIAlertController
            alertControllerWithTitle:@"Patch unavailable"
            message:@"The target method could not be hooked. The selected mode was not saved."
            preferredStyle:UIAlertControllerStyleAlert];
        [error addAction:[UIAlertAction actionWithTitle:@"OK"
                   style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:error animated:YES completion:nil];
        [self.tableView reloadData];
        return;
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self.tableView reloadData];
}

- (void)overrideSwitchChanged:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, YTABModernPatchKeyAssociation);
    [self ytab_applyMode:sender.isOn ? YTABModernPatchModeForceOn
                                : YTABModernPatchModeForceOff patchKey:key];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id method = [self ytab_methodAtIndexPath:indexPath];
    NSString *name = YTABModernStringValue(method, @"selectorName");
    NSString *owner = YTABModernStringValue(method, @"className");
    NSString *encoding = YTABModernStringValue(method, @"typeEncoding");
    NSString *key = YTABModernStringValue(method, @"patchKey");
    NSNumber *native = YTABRuntimeBrowserNativeSample(key);
    NSString *message = [NSString stringWithFormat:
        @"Class: %@\nEncoding: %@\nPatch key: %@\nNative result: %@",
        owner, encoding, key,
        native ? (native.boolValue ? @"ON" : @"OFF") : @"not sampled"];
    UIAlertController *details = [UIAlertController
        alertControllerWithTitle:name message:message preferredStyle:UIAlertControllerStyleAlert];
    [details addAction:[UIAlertAction actionWithTitle:@"Copy patch key"
                         style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = key;
    }]];
    [details addAction:[UIAlertAction actionWithTitle:@"Close"
                         style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:details animated:YES completion:nil];
}

- (void)clearOverrides {
    if (!YTABRuntimeBrowserPersistedOverrideCount()) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear runtime method overrides?"
        message:@"Clears generic runtime method patches. Captured config flags are managed by the same YTABConfig flags cache and can be reset individually with long-press or in the Feature Lab."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTABModernOverridesKey];
        YTABRuntimeBrowserReinstallPersistedHooks();
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
