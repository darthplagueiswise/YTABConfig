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

static UITableViewCell *YTABModernEngineCell(id controller,
                                             UITableView *tableView,
                                             NSIndexPath *indexPath) {
    Class modernClass = object_getClass(controller);
    Class engineClass = class_getSuperclass(modernClass);
    SEL selector = @selector(tableView:cellForRowAtIndexPath:);
    Method method = engineClass ? class_getInstanceMethod(engineClass, selector) : NULL;
    IMP implementation = method ? method_getImplementation(method) : NULL;
    if (!implementation) return nil;
    return ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))implementation)(
        controller, selector, tableView, indexPath);
}

@interface YTABRuntimePatchCell : UITableViewCell
@property(nonatomic, strong) UILabel *selectorLabel;
@property(nonatomic, strong) UILabel *ownerLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *encodingLabel;
@property(nonatomic, strong) UISegmentedControl *modeControl;
@end

@implementation YTABRuntimePatchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _selectorLabel = [UILabel new];
    _selectorLabel.numberOfLines = 0;
    _selectorLabel.lineBreakMode = NSLineBreakByCharWrapping;
    if (@available(iOS 13.0, *)) {
        _selectorLabel.font = [UIFont monospacedSystemFontOfSize:13.0
                                                        weight:UIFontWeightRegular];
    } else {
        _selectorLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    }

    _ownerLabel = [UILabel new];
    _ownerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _ownerLabel.textColor = UIColor.secondaryLabelColor;
    _ownerLabel.numberOfLines = 2;
    _ownerLabel.lineBreakMode = NSLineBreakByCharWrapping;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 2;

    _encodingLabel = [UILabel new];
    if (@available(iOS 13.0, *)) {
        _encodingLabel.font = [UIFont monospacedSystemFontOfSize:10.0
                                                         weight:UIFontWeightRegular];
    } else {
        _encodingLabel.font = [UIFont systemFontOfSize:10.0];
    }
    _encodingLabel.textColor = UIColor.tertiaryLabelColor;
    _encodingLabel.numberOfLines = 2;
    _encodingLabel.lineBreakMode = NSLineBreakByCharWrapping;

    _selectorLabel.adjustsFontForContentSizeCategory = YES;
    _ownerLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _encodingLabel.adjustsFontForContentSizeCategory = YES;

    _modeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"System", @"Force OFF", @"Force ON"]];
    _modeControl.apportionsSegmentWidthsByContent = NO;
    _modeControl.accessibilityLabel = @"Runtime patch mode";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _selectorLabel, _ownerLabel, _statusLabel, _encodingLabel, _modeControl
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 3.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(9.0, 16.0, 9.0, 16.0);
    [self.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [_modeControl.heightAnchor constraintEqualToConstant:32.0],
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
    self.tableView.estimatedRowHeight = 104.0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.definesPresentationContext = YES;

    // Always-visible native search. YouTube's navigation wrapper can collapse
    // the UINavigationItem-integrated search field, so retain the native
    // UISearchBar but present it in a pinned *plain table section header*.
    UISearchBar *search = self.navigationItem.searchController.searchBar;
    self.navigationItem.searchController = nil;
    [search removeFromSuperview];
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

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar; (void)searchText;
    // The parent runtime engine owns filtering, and uses this exact searchBar.
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
    // Ask the engine's concrete implementation for its current native/state
    // string without relying on a private method declaration in the header.
    UITableViewCell *engineCell = YTABModernEngineCell(self, tableView, indexPath);

    static NSString *identifier = @"YTABRuntimeModernPatchCell";
    YTABRuntimePatchCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[YTABRuntimePatchCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:identifier];
    }

    id method = [self ytab_methodAtIndexPath:indexPath];
    NSString *selectorName = YTABModernStringValue(method, @"selectorName");
    NSString *className = YTABModernStringValue(method, @"className");
    NSString *imageName = YTABModernStringValue(method, @"imageName");
    NSString *typeEncoding = YTABModernStringValue(method, @"typeEncoding");
    NSString *patchKey = YTABModernStringValue(method, @"patchKey");
    BOOL classMethod = YTABModernBoolValue(method, @"classMethod");

    cell.selectorLabel.text = [NSString stringWithFormat:@"%@ %@",
                               classMethod ? @"+" : @"-", selectorName ?: @""];
    cell.ownerLabel.text = imageName.length
        ? [NSString stringWithFormat:@"%@ · %@", className, imageName]
        : className;

    NSString *engineStatus = engineCell.detailTextLabel.text ?: @"";
    NSString *classPrefix = className.length
        ? [className stringByAppendingString:@" · "]
        : @"";
    if (classPrefix.length && [engineStatus hasPrefix:classPrefix]) {
        engineStatus = [engineStatus substringFromIndex:classPrefix.length];
    }
    NSNumber *nativeSample = YTABRuntimeBrowserNativeSample(patchKey);
    NSNumber *savedOverride = YTABModernStoredOverrides()[patchKey];
    BOOL installed = YTABRuntimeBrowserPatchInstalled(patchKey);
    NSString *nativeText = nativeSample ? (nativeSample.boolValue ? @"ON" : @"OFF") : @"not sampled";
    NSString *effectiveText = savedOverride
        ? (installed ? (savedOverride.boolValue ? @"ON" : @"OFF") : @"pending / unavailable")
        : nativeText;
    cell.statusLabel.text = [NSString stringWithFormat:
        @"Native: %@  ·  Effective: %@  ·  %@",
        nativeText, effectiveText, savedOverride ? (installed ? @"Patch active" : @"Patch not installed") : @"System"];
    cell.statusLabel.textColor = savedOverride && installed
        ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    cell.encodingLabel.text = [NSString stringWithFormat:@"%@\n%@",
                               typeEncoding ?: @"", patchKey ?: @""];

    [cell.modeControl removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    cell.modeControl.selectedSegmentIndex = YTABModernModeForKey(patchKey);
    objc_setAssociatedObject(cell.modeControl, YTABModernPatchKeyAssociation,
                             patchKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [cell.modeControl addTarget:self
                         action:@selector(patchModeChanged:)
               forControlEvents:UIControlEventValueChanged];

    cell.accessibilityLabel = selectorName;
    cell.accessibilityValue = [NSString stringWithFormat:@"%@, %@",
                               cell.ownerLabel.text ?: @"", engineStatus ?: @""];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

- (void)patchModeChanged:(UISegmentedControl *)sender {
    NSString *patchKey = objc_getAssociatedObject(sender, YTABModernPatchKeyAssociation);
    if (!patchKey.length) return;

    YTABModernPatchMode requestedMode = (YTABModernPatchMode)sender.selectedSegmentIndex;
    if (!YTABModernSetModeForKey(requestedMode, patchKey)) {
        sender.selectedSegmentIndex = YTABModernModeForKey(patchKey);
        UIAlertController *error = [UIAlertController
            alertControllerWithTitle:@"Patch unavailable"
            message:@"The selected method could not be hooked in this build. The saved setting was not changed."
            preferredStyle:UIAlertControllerStyleAlert];
        [error addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:error animated:YES completion:nil];
        return;
    }
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    [self.tableView reloadData];
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
