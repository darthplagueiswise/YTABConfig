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
- (void)scopeChanged:(UISegmentedControl *)sender;
- (void)ytab_setCategoryFilter:(NSString *)category;
- (NSArray<NSString *> *)ytab_availableCategories;
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
@end

@implementation YTABRuntimePatchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    // The selector is content, not a headline. Avoid fixed 15pt monospaced
    // fonts and long technical type encodings in the primary row.
    _selectorLabel = [UILabel new];
    _selectorLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]];
    _selectorLabel.adjustsFontForContentSizeCategory = YES;
    _selectorLabel.numberOfLines = 3;
    _selectorLabel.lineBreakMode = NSLineBreakByWordWrapping;
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

    // Pin every UISwitch to one fixed trailing edge and one fixed top
    // inset. A long selector only changes its own label height; it can
    // never push the switch left or right.
    for (UIView *view in @[_selectorLabel, _ownerLabel,
                            _statusLabel, _overrideSwitch]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_overrideSwitch.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_overrideSwitch.topAnchor
            constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_selectorLabel.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_selectorLabel.trailingAnchor
            constraintLessThanOrEqualToAnchor:_overrideSwitch.leadingAnchor constant:-12],
        [_selectorLabel.topAnchor
            constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_ownerLabel.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_ownerLabel.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_ownerLabel.topAnchor
            constraintEqualToAnchor:_selectorLabel.bottomAnchor constant:8],
        [_statusLabel.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_statusLabel.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_statusLabel.topAnchor
            constraintEqualToAnchor:_ownerLabel.bottomAnchor constant:4],
        [_statusLabel.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
    ]];
    return self;
}
@end

@interface YTABRuntimeBrowserModernViewController () <UISearchBarDelegate, UIContextMenuInteractionDelegate>
@property(nonatomic, strong) UIView *scopeHeaderView;
@property(nonatomic, strong) UIScrollView *categoryScroller;
@property(nonatomic, strong) UIStackView *categoryStack;
@property(nonatomic, copy) NSArray<NSString *> *renderedCategories;
@property(nonatomic, copy) NSString *selectedCategory;
@property(nonatomic, strong) UISearchBar *pinnedSearchBar;
@property(nonatomic) BOOL usesNativeSearchPlacement;
@property(nonatomic) NSInteger ytab_initialScope;
@end

@implementation YTABRuntimeBrowserModernViewController

// Plain rows and a transparent category scroller preserve true native
// controls. UIKit owns glass button appearance and navigation edge effects.
- (instancetype)init {
    return [self initWithInitialScope:0];
}
- (instancetype)initWithInitialScope:(NSInteger)scope {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _ytab_initialScope = scope == 0 ? 0 : 1;
        _selectedCategory = @"Runtime";
    }
    return self;
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
    self.title = @"Boolean Controls";
    self.navigationItem.titleView = nil;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82.0;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 18, 0);
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 18, 0, 18);
    self.tableView.separatorColor = UIColor.separatorColor;
    // This navigation item's transparent appearance replaces the opaque
    // YouTube-hosted bar strip without changing other Settings controllers.
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *clearAppearance = [UINavigationBarAppearance new];
        [clearAppearance configureWithTransparentBackground];
        clearAppearance.shadowColor = UIColor.clearColor;
        self.navigationItem.standardAppearance = clearAppearance;
        self.navigationItem.scrollEdgeAppearance = clearAppearance;
        self.navigationItem.compactAppearance = clearAppearance;
    }
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.definesPresentationContext = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(ytab_nativeSampleDidChange:)
        name:YTABRuntimeNativeSampleChangedNotification object:nil];

    // iOS 26/27: morphing Liquid Glass search stays in the navigation bar.
    // YouTube's custom toolbar otherwise floats the lens over runtime rows.
    // Pre-iOS 26 uses the standalone, pinned section search bar.
    self.usesNativeSearchPlacement = NO;
    UISearchController *nativeSearch = [self ytab_ownedSearchController];
    if (@available(iOS 26.0, *)) {
        if (nativeSearch && self.navigationController) {
            self.usesNativeSearchPlacement = YES;
            self.navigationItem.searchController = nativeSearch;
            self.navigationItem.hidesSearchBarWhenScrolling = NO;
            self.navigationItem.preferredSearchBarPlacement =
                UINavigationItemSearchBarPlacementIntegratedButton;
            self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO;
            nativeSearch.searchBar.placeholder = @"Class or selector";
            nativeSearch.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
            nativeSearch.searchBar.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            // Keep the system morphing search, without a bottom toolbar item.
            self.toolbarItems = nil;
        }
    }
    if (!self.usesNativeSearchPlacement) {
        self.navigationItem.searchController = nil;
        UISearchBar *search = [[UISearchBar alloc] initWithFrame:CGRectZero];
        search.delegate = self;
        search.placeholder = @"Class or selector";
        search.searchBarStyle = UISearchBarStyleMinimal;
        search.autocorrectionType = UITextAutocorrectionTypeNo;
        search.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.pinnedSearchBar = search;
    }

    // Keep the original inventory engine but remove its large gray
    // two-segment control. Class-family glass pills filter that one inventory.
    UISegmentedControl *legacyScope = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) legacyScope = value;
    } @catch (__unused NSException *exception) {}
    [legacyScope removeFromSuperview];
    if (legacyScope && self.ytab_initialScope != 0) {
        legacyScope.selectedSegmentIndex = 1;
        [self scopeChanged:legacyScope];
    }

    CGFloat headerHeight = self.usesNativeSearchPlacement ? 54.0 : 106.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, headerHeight)];
    header.backgroundColor = UIColor.clearColor;
    header.opaque = NO;
    if (self.pinnedSearchBar) [header addSubview:self.pinnedSearchBar];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.backgroundColor = UIColor.clearColor;
    scroll.opaque = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    UIStackView *categories = [UIStackView new];
    categories.axis = UILayoutConstraintAxisHorizontal;
    categories.alignment = UIStackViewAlignmentCenter;
    categories.spacing = 8;
    categories.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:categories];
    [NSLayoutConstraint activateConstraints:@[
        [categories.leadingAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [categories.trailingAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [categories.centerYAnchor
            constraintEqualToAnchor:scroll.frameLayoutGuide.centerYAnchor],
        [categories.heightAnchor constraintEqualToConstant:40]
    ]];
    [header addSubview:scroll];
    self.categoryScroller = scroll;
    self.categoryStack = categories;
    self.scopeHeaderView = header;
    [self ytab_refreshCategoryChips];
    // Do not set tableHeaderView: it would scroll the search out of sight.
    self.tableView.tableHeaderView = nil;
    // No custom floating search overlays the list; respect UIKit safe area.
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 18.0, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;

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

- (void)ytab_refreshCategoryChips {
    if (!self.categoryStack) return;
    NSArray<NSString *> *categories = [self ytab_availableCategories];
    if ([self.renderedCategories isEqualToArray:categories]) return;
    self.renderedCategories = categories.copy;
    for (UIView *button in self.categoryStack.arrangedSubviews) {
        [self.categoryStack removeArrangedSubview:button];
        [button removeFromSuperview];
    }
    for (NSString *category in categories) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        BOOL selected = [category isEqualToString:self.selectedCategory];
        UIButtonConfiguration *config = nil;
        if (@available(iOS 26.0, *)) {
            config = selected ? [UIButtonConfiguration glassButtonConfiguration]
                              : [UIButtonConfiguration clearGlassButtonConfiguration];
        } else if (@available(iOS 15.0, *)) {
            config = selected ? [UIButtonConfiguration tintedButtonConfiguration]
                              : [UIButtonConfiguration plainButtonConfiguration];
        }
        config.title = category;
        config.baseForegroundColor = selected ? UIColor.labelColor
                                               : UIColor.secondaryLabelColor;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
        button.configuration = config;
        button.accessibilityIdentifier =
            [@"YTABC_CATEGORY_" stringByAppendingString:category];
        button.accessibilityLabel = [NSString stringWithFormat:@"%@ Boolean category",
                                      category];
        button.accessibilityTraits = selected
            ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected)
            : UIAccessibilityTraitButton;
        objc_setAssociatedObject(button, YTABModernPatchKeyAssociation,
                                 category, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [button addTarget:self action:@selector(ytab_categoryTapped:)
              forControlEvents:UIControlEventTouchUpInside];
        [self.categoryStack addArrangedSubview:button];
    }
}

- (void)ytab_categoryTapped:(UIButton *)button {
    NSString *category = objc_getAssociatedObject(button, YTABModernPatchKeyAssociation);
    if (!category.length || [category isEqualToString:self.selectedCategory]) return;
    self.selectedCategory = category;
    // The Native Tools legacy 'overrides' shortcut can still open this view.
    // As soon as a user chooses a category, use the full Boolean catalog.
    UISegmentedControl *legacy = nil;
    @try { legacy = [self valueForKey:@"scopeControl"]; }
    @catch (__unused NSException *exception) {}
    if ([legacy isKindOfClass:UISegmentedControl.class] &&
        legacy.selectedSegmentIndex != 0) {
        legacy.selectedSegmentIndex = 0;
        [self scopeChanged:legacy];
    }
    [self ytab_setCategoryFilter:category];
    self.renderedCategories = nil;
    [self ytab_refreshCategoryChips];
    [self.categoryScroller scrollRectToVisible:
        [button convertRect:button.bounds toView:self.categoryScroller]
                                  animated:YES];
}

- (void)applyFilter {
    [super applyFilter];
    [self ytab_refreshCategoryChips];
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
    // Do not change the YouTube container toolbar's visibility.
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.scopeHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat searchHeight = self.usesNativeSearchPlacement ? 0.0 : 52.0;
    header.frame = CGRectMake(0, 0, width, searchHeight + 54.0);
    if (self.pinnedSearchBar)
        self.pinnedSearchBar.frame = CGRectMake(8, 0, MAX(0, width - 16), 52);
    self.categoryScroller.frame = CGRectMake(0, searchHeight,
                                              width, 54.0);
}

- (NSString *)ytab_currentSearchText {
    return self.usesNativeSearchPlacement
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
    return self.usesNativeSearchPlacement ? 54.0 : 106.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.scopeHeaderView;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return nil; // translucent glass category buttons have no background strip
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    // Explanations belong in detail views, not tall table footers.
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTABRuntimeGlassPatchCell";
    YTABRuntimePatchCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[YTABRuntimePatchCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:identifier];
    cell.backgroundColor = UIColor.clearColor;
    if (@available(iOS 14.0, *))
        cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];

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
            : @"Native not sampled · Switch forces ON");

    [cell.overrideSwitch removeTarget:nil action:NULL
                        forControlEvents:UIControlEventValueChanged];
    [cell.overrideSwitch setOn:(effectiveKnown && effectiveOn) animated:NO];
    cell.overrideSwitch.hidden = NO;
    cell.overrideSwitch.enabled = YES;
    cell.overrideSwitch.accessibilityValue = [NSString stringWithFormat:
        @"%@; %@; native %@",
        effectiveKnown ? (effectiveOn ? @"ON" : @"OFF") : @"not sampled",
        hasOverride ? @"local override" : @"system", nativeText];
    cell.overrideSwitch.accessibilityHint = nativeKnown
        ? @"Change to force a local value. Long press to restore System."
        : @"Native value not sampled. Switching ON creates a local override; long press for System or Force OFF.";
    objc_setAssociatedObject(cell.overrideSwitch, YTABModernPatchKeyAssociation,
                             key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [cell.overrideSwitch addTarget:self action:@selector(overrideSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];
    if (@available(iOS 13.0, *)) {
        BOOL attached = NO;
        for (id interaction in cell.overrideSwitch.interactions)
            if ([interaction isKindOfClass:UIContextMenuInteraction.class]) attached = YES;
        if (!attached)
            [cell.overrideSwitch addInteraction:
                [[UIContextMenuInteraction alloc] initWithDelegate:self]];
    }
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@; %@; native %@",
        selectorName, hasOverride ? @"override" : @"System", nativeText];
    cell.accessibilityHint = @"Tap for details or long press for System, Force ON and Force OFF.";
    return cell;
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
