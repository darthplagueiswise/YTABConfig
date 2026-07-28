#import "YTABRuntimeBrowserModern.h"
#import <objc/message.h>
#import <objc/runtime.h>

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

static void YTABModernSetModeForKey(YTABModernPatchMode mode, NSString *patchKey) {
    if (!patchKey.length) return;
    NSMutableDictionary<NSString *, NSNumber *> *overrides =
        [YTABModernStoredOverrides() mutableCopy];
    switch (mode) {
        case YTABModernPatchModeForceOff:
            overrides[patchKey] = @NO;
            break;
        case YTABModernPatchModeForceOn:
            overrides[patchKey] = @YES;
            break;
        case YTABModernPatchModeSystem:
        default:
            [overrides removeObjectForKey:patchKey];
            break;
    }
    [[NSUserDefaults standardUserDefaults] setObject:overrides.copy
                                              forKey:YTABModernOverridesKey];
    // Refreshes the engine cache and installs only newly persisted selectors.
    // Removing a key makes an existing wrapper pass through the original value.
    YTABRuntimeBrowserReinstallPersistedHooks();
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
        _selectorLabel.font = [UIFont monospacedSystemFontOfSize:15.0
                                                        weight:UIFontWeightMedium];
    } else {
        _selectorLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    }

    _ownerLabel = [UILabel new];
    _ownerLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _ownerLabel.textColor = UIColor.secondaryLabelColor;
    _ownerLabel.numberOfLines = 2;
    _ownerLabel.lineBreakMode = NSLineBreakByCharWrapping;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 2;

    _encodingLabel = [UILabel new];
    if (@available(iOS 13.0, *)) {
        _encodingLabel.font = [UIFont monospacedSystemFontOfSize:10.5
                                                         weight:UIFontWeightRegular];
    } else {
        _encodingLabel.font = [UIFont systemFontOfSize:10.5];
    }
    _encodingLabel.textColor = UIColor.tertiaryLabelColor;
    _encodingLabel.numberOfLines = 2;
    _encodingLabel.lineBreakMode = NSLineBreakByCharWrapping;

    _modeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"System", @"Force OFF", @"Force ON"]];
    _modeControl.apportionsSegmentWidthsByContent = NO;
    _modeControl.accessibilityLabel = @"Runtime patch mode";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _selectorLabel, _ownerLabel, _statusLabel, _encodingLabel, _modeControl
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.isLayoutMarginsRelativeArrangement = YES;
    stack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(11.0, 16.0, 11.0, 16.0);
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

@interface YTABRuntimeBrowserModernViewController ()
@property(nonatomic, strong) UIView *scopeHeaderView;
@property(nonatomic, strong) UILabel *scopeHeaderLabel;
@end

@implementation YTABRuntimeBrowserModernViewController

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
    self.tableView.estimatedRowHeight = 132.0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 8.0;

    UISearchController *searchController = self.navigationItem.searchController;
    searchController.hidesNavigationBarDuringPresentation = NO;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (@available(iOS 16.0, *)) {
        self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }
    SEL toolbarIntegration = NSSelectorFromString(@"setSearchBarPlacementAllowsToolbarIntegration:");
    if ([self.navigationItem respondsToSelector:toolbarIntegration]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.navigationItem, toolbarIntegration, NO);
    }
    SEL externalIntegration = NSSelectorFromString(@"setSearchBarPlacementAllowsExternalIntegration:");
    if ([self.navigationItem respondsToSelector:externalIntegration]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.navigationItem, externalIntegration, NO);
    }

    UISegmentedControl *scopeControl = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scopeControl = value;
    } @catch (__unused NSException *exception) {}

    [scopeControl removeFromSuperview];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 70.0)];
    header.backgroundColor = UIColor.clearColor;

    UILabel *scopeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    scopeLabel.text = @"Source image";
    scopeLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    scopeLabel.textColor = UIColor.secondaryLabelColor;
    [header addSubview:scopeLabel];
    if (scopeControl) [header addSubview:scopeControl];

    self.scopeHeaderView = header;
    self.scopeHeaderLabel = scopeLabel;
    self.tableView.tableHeaderView = header;

    UIImage *trashImage = nil;
    if (@available(iOS 13.0, *)) trashImage = [UIImage systemImageNamed:@"trash"];
    self.navigationItem.rightBarButtonItem = trashImage
        ? [[UIBarButtonItem alloc] initWithImage:trashImage
                                          style:UIBarButtonItemStylePlain
                                         target:self
                                         action:@selector(clearOverrides)]
        : [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                          style:UIBarButtonItemStylePlain
                                         target:self
                                         action:@selector(clearOverrides)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Clear saved runtime patches";
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.scopeHeaderView;
    if (!header) return;

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    header.frame = CGRectMake(0.0, 0.0, width, 70.0);
    self.scopeHeaderLabel.frame = CGRectMake(20.0, 6.0, MAX(0.0, width - 40.0), 18.0);

    UISegmentedControl *scopeControl = nil;
    @try {
        id value = [self valueForKey:@"scopeControl"];
        if ([value isKindOfClass:UISegmentedControl.class]) scopeControl = value;
    } @catch (__unused NSException *exception) {}
    scopeControl.frame = CGRectMake(16.0, 28.0, MAX(0.0, width - 32.0), 32.0);

    if (self.tableView.tableHeaderView != header) self.tableView.tableHeaderView = header;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [NSString stringWithFormat:@"%lu methods · %lu saved patches",
            (unsigned long)[self ytab_visibleMethods].count,
            (unsigned long)YTABRuntimeBrowserPersistedOverrideCount()];
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
    cell.statusLabel.text = engineStatus.length ? engineStatus : @"native —";
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

    YTABModernSetModeForKey((YTABModernPatchMode)sender.selectedSegmentIndex, patchKey);
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
