#import "YTABRuntimeBrowserModern.h"
#import <objc/message.h>
#import <objc/runtime.h>

// State is owned by the runtime hook engine, never duplicated in a UI cache.
extern BOOL YTABRuntimeBrowserApplyMode(NSString *patchKey, NSInteger mode);
extern NSNumber *YTABRuntimeBrowserNativeSample(NSString *patchKey);
extern BOOL YTABRuntimeBrowserPatchInstalled(NSString *patchKey);

// The runtime engine implements the filter; the UI only chooses where its
// search field is hosted.
@interface YTABRuntimeBrowserViewController (YTABModernFiltering)
- (void)applyFilter;
- (NSString *)ytab_currentSearchText;
@end

static NSString * const YTABModernOverridesKey = @"YTABCRuntimeBrowserOverrides";
static const void *YTABModernPatchKeyAssociation = &YTABModernPatchKeyAssociation;

typedef NS_ENUM(NSInteger, YTABModernPatchMode) {
    YTABModernPatchModeSystem = 0,
    YTABModernPatchModeForceOff = 1,
    YTABModernPatchModeForceOn = 2,
};

static NSDictionary<NSString *, NSNumber *> *YTABModernStoredOverrides(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:YTABModernOverridesKey];
    if (![stored isKindOfClass:NSDictionary.class]) return @{};

    NSMutableDictionary<NSString *, NSNumber *> *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class]) {
            clean[key] = @([(NSNumber *)value boolValue]);
        }
    }];
    return clean.copy;
}

static YTABModernPatchMode YTABModernModeForKey(NSString *patchKey) {
    NSNumber *override = YTABModernStoredOverrides()[patchKey];
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
    _selectorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _selectorLabel.adjustsFontForContentSizeCategory = YES;
    _selectorLabel.numberOfLines = 1;
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
    _overrideSwitch.accessibilityLabel = @"Force this selector's result";
    [_overrideSwitch setContentHuggingPriority:UILayoutPriorityRequired
                                      forAxis:UILayoutConstraintAxisHorizontal];

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

    UIStackView *headline = [[UIStackView alloc] initWithArrangedSubviews:@[
        _selectorLabel, _overrideSwitch
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
    stack.spacing = 4.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9],
        [_overrideSwitch.widthAnchor constraintGreaterThanOrEqualToConstant:49],
        [_modeButton.heightAnchor constraintGreaterThanOrEqualToConstant:30],
    ]];
    return self;
}
@end

@interface YTABRuntimeBrowserModernViewController () <UISearchBarDelegate>
@property(nonatomic, strong) UIView *scopeHeaderView;
@property(nonatomic, strong) UILabel *scopeHeaderLabel;
@property(nonatomic, strong) UISearchBar *pinnedSearchBar;
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
    self.tableView.estimatedRowHeight = 86.0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.definesPresentationContext = YES;

    // Always-visible native search. YouTube's navigation wrapper can collapse
    // the UINavigationItem-integrated search field, so retain the native
    // UISearchBar but present it in a pinned *plain table section header*.
    // Do NOT detach a UISearchController-owned searchBar. UIKit can reclaim
    // or hide it while a custom navigation controller changes presentation.
    // Keep the engine's search controller retained for legacy compatibility,
    // but give this pinned header its own native UISearchBar and filter source.
    self.navigationItem.searchController = nil;
    UISearchBar *search = [[UISearchBar alloc] initWithFrame:CGRectZero];
    search.delegate = self;
    search.placeholder = @"Class or selector";
    search.searchBarStyle = UISearchBarStyleMinimal;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.pinnedSearchBar = search;

    UISegmentedControl *scope = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scope = value;
    } @catch (__unused NSException *exception) {}
    [scope removeFromSuperview];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 102)];
    header.backgroundColor = [UIColor systemBackgroundColor];
    [header addSubview:search];

    UILabel *sourceLabel = [UILabel new];
    sourceLabel.text = @"SOURCE";
    sourceLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    sourceLabel.textColor = [UIColor secondaryLabelColor];
    sourceLabel.adjustsFontForContentSizeCategory = YES;
    [header addSubview:sourceLabel];
    if (scope) [header addSubview:scope];
    self.scopeHeaderView = header;
    self.scopeHeaderLabel = sourceLabel;
    // Do not set tableHeaderView: it would scroll the search out of sight.
    self.tableView.tableHeaderView = nil;

    UIImage *trash = nil;
    if (@available(iOS 13.0, *)) trash = [UIImage systemImageNamed:@"trash"];
    self.navigationItem.rightBarButtonItem = trash
        ? [[UIBarButtonItem alloc] initWithImage:trash
                                          style:UIBarButtonItemStylePlain
                                         target:self action:@selector(clearOverrides)]
        : [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                          style:UIBarButtonItemStylePlain
                                         target:self action:@selector(clearOverrides)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Clear saved runtime patches";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Preserve UIKit's system navigation material; never install a custom
    // translucent/blur overlay that hides the toolbar or clips search.
    self.navigationItem.titleView = nil;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.scopeHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    header.frame = CGRectMake(0, 0, width, 102);
    self.pinnedSearchBar.frame = CGRectMake(8, 0, MAX(0, width - 16), 52);
    self.scopeHeaderLabel.frame = CGRectMake(20, 52, MAX(0, width - 40), 14);
    UISegmentedControl *scope = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scope = value;
    } @catch (__unused NSException *exception) {}
    scope.frame = CGRectMake(16, 66, MAX(0, width - 32), 31);
}

- (NSString *)ytab_currentSearchText {
    return self.pinnedSearchBar.text ?: @"";
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
    return 102.0;
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
    return @"System passes through the original result. Force OFF/ON is saved and restored in %ctor. Removing an override is immediate; an already installed wrapper remains pass-through until restart.";
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

    cell.selectorLabel.text = [NSString stringWithFormat:@"%@ %@",
                               isClassMethod ? @"+" : @"-", selectorName];
    cell.ownerLabel.text = imageName.length
        ? [NSString stringWithFormat:@"%@ · %@", className, imageName]
        : className;

    YTABModernPatchMode mode = YTABModernModeForKey(key);
    NSNumber *native = YTABRuntimeBrowserNativeSample(key);
    BOOL installed = YTABRuntimeBrowserPatchInstalled(key);
    NSString *nativeText = native ? (native.boolValue ? @"ON" : @"OFF") : @"not sampled";
    NSString *effectiveText = mode == YTABModernPatchModeSystem
        ? nativeText
        : (installed ? (mode == YTABModernPatchModeForceOn ? @"ON" : @"OFF")
                     : @"pending");
    cell.statusLabel.text = [NSString stringWithFormat:@"Native %@ · Effective %@",
                             nativeText, effectiveText];

    [cell.overrideSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    BOOL effectiveBool = mode == YTABModernPatchModeSystem
        ? (native ? native.boolValue : NO)
        : mode == YTABModernPatchModeForceOn;
    [cell.overrideSwitch setOn:effectiveBool animated:NO];
    cell.overrideSwitch.accessibilityValue = [NSString stringWithFormat:
        @"%@, current mode %@. Native %@",
        effectiveText,
        mode == YTABModernPatchModeSystem ? @"System"
        : (mode == YTABModernPatchModeForceOn ? @"Force ON" : @"Force OFF"),
        nativeText];
    objc_setAssociatedObject(cell.overrideSwitch, YTABModernPatchKeyAssociation,
                             key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [cell.overrideSwitch addTarget:self action:@selector(overrideSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];

    NSString *modeLabel = mode == YTABModernPatchModeSystem ? @"System"
        : (mode == YTABModernPatchModeForceOn ? @"Force ON" : @"Force OFF");
    UIButtonConfiguration *configuration = cell.modeButton.configuration;
    if (configuration) {
        configuration.title = modeLabel;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(2, 8, 2, 8);
        cell.modeButton.configuration = configuration;
    } else {
        [cell.modeButton setTitle:modeLabel forState:UIControlStateNormal];
    }
    cell.modeButton.menu = [self ytab_modeMenuForKey:key];
    cell.modeButton.accessibilityValue = modeLabel;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, native %@",
                               selectorName, modeLabel, nativeText];
    cell.accessibilityHint = @"Tap for full Objective-C signature and patch key.";
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
        alertControllerWithTitle:@"Clear saved runtime patches?"
        message:@"Every selector returns to System immediately. Wrappers already installed in this process remain transparent pass-through hooks until restart."
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
