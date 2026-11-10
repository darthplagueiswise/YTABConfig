// YouTube 21.43.5: inspect the REAL settings category/row objects
// exposed by YTSettingsViewController. Does not fabricate server rows or
// bypass account eligibility. Original ARM64 method encodings:
// YTSettingsViewController -settingsSectionControllers @16@0:8
// YTAppSettingsPresentationData +settingsCategoryOrder @16@0:8
// YTSettingsSectionController -items/@title @16@0:8
// -isHeaderHidden/-isDisabled B16@0:8
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
extern id YTABCLiveSettingsSectionItemManager(void);

static id YTABCSafeObject(id object, const char *name) {
    if (!object || !name) return nil;
    SEL sel = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), sel);
    // Inherited methods are allowed. Require the ObjC ABI of an object getter.
    if (!method || strcmp(method_getTypeEncoding(method) ?: "", "@16@0:8") != 0)
        return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, sel); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL YTABCSafeBoolean(id object, const char *name, BOOL *known) {
    if (known) *known = NO;
    if (!object || !name) return NO;
    SEL sel = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), sel);
    if (!method || strcmp(method_getTypeEncoding(method) ?: "", "B16@0:8") != 0)
        return NO;
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
        if (known) *known = YES;
        return value;
    } @catch (__unused NSException *exception) { return NO; }
}

static const void *YTABCRevealCategoryAssociation = &YTABCRevealCategoryAssociation;

static void YTABCShowInspectorNotice(UIViewController *owner, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Native Settings"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static NSString *YTABCReadTitle(id obj) {
    id value = YTABCSafeObject(obj, "title");
    return [value isKindOfClass:NSString.class] && [value length]
        ? value : NSStringFromClass([obj class]) ?: @"Unnamed";
}

@interface YTABCSettingsRowsInspector : UITableViewController
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *rows;
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *details;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary<NSString *, id> *> *> *groupedRows;
@property(nonatomic, strong) NSArray<NSString *> *groupTitles;
@property(nonatomic, weak) id settingsOwner;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *originalHidden;
- (void)refreshLiveCategories;
- (void)ytabc_revealButtonTapped:(UIButton *)sender;
- (instancetype)initWithSettingsOwner:(id)owner;
- (instancetype)initWithCategory:(NSDictionary<NSString *, id> *)category;
@end

@implementation YTABCSettingsRowsInspector

- (instancetype)initWithSettingsOwner:(id)owner {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.title = @"Native Settings Rows";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54;

    _settingsOwner = owner;
    _originalHidden = [NSMutableDictionary dictionary];
    [self refreshLiveCategories];
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.details) {
        [self refreshLiveCategories];
        [self.tableView reloadData];
    }
}

// Enumerate only actually loaded categories; never fabricate rows missing
// from the server model. A header is a presentation property, not eligibility.
- (void)refreshLiveCategories {
    id owner = self.settingsOwner;
    NSMutableDictionary<NSNumber *, id> *live = [NSMutableDictionary dictionary];
    id controllers = YTABCSafeObject(owner, "settingsSectionControllers");
    if ([controllers isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)controllers enumerateKeysAndObjectsUsingBlock:
            ^(id key, id object, __unused BOOL *stop) {
            if ([key isKindOfClass:NSNumber.class] && object)
                live[key] = object;
        }];
    }
    Class presentation = NSClassFromString(@"YTAppSettingsPresentationData");
    id declared = nil;
    Method m = presentation
        ? class_getClassMethod(presentation, @selector(settingsCategoryOrder)) : NULL;
    if (m && strcmp(method_getTypeEncoding(m) ?: "", "@16@0:8") == 0)
        @try { declared = ((id (*)(id, SEL))objc_msgSend)(
            presentation, @selector(settingsCategoryOrder)); }
        @catch (__unused NSException *e) { declared = nil; }

    NSMutableOrderedSet<NSNumber *> *ids = [NSMutableOrderedSet orderedSet];
    if ([declared isKindOfClass:NSArray.class])
        for (id value in (NSArray *)declared)
            if ([value isKindOfClass:NSNumber.class]) [ids addObject:value];
    for (NSNumber *key in live) [ids addObject:key];

    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    for (NSNumber *number in ids) {
        id section = live[number];
        id items = YTABCSafeObject(section, "items");
        BOOL hiddenKnown = NO, disabledKnown = NO;
        BOOL hidden = YTABCSafeBoolean(section, "isHeaderHidden", &hiddenKnown);
        BOOL disabled = YTABCSafeBoolean(section, "isDisabled", &disabledKnown);
        NSUInteger count = [items isKindOfClass:NSArray.class] ? [(NSArray *)items count] : 0;
        NSString *name = section ? YTABCReadTitle(section)
                                 : [NSString stringWithFormat:@"Category %@", number];
        BOOL changedHere = self.originalHidden[number] != nil;
        NSString *subtitle = section
            ? [NSString stringWithFormat:@"ID %@ · %lu loaded items · header %@%@ · %@",
                number, (unsigned long)count,
                hiddenKnown ? (hidden ? @"hidden" : @"visible") : @"unknown",
                changedHere ? @" (local)" : @"",
                disabledKnown ? (disabled ? @"disabled" : @"enabled") : @"unknown"]
            : @"Declared in native order; not loaded by current Settings model";
        [rows addObject:@{@"title": name ?: @"Settings", @"subtitle": subtitle,
            @"category": number, @"section": section ?: NSNull.null,
            @"loaded": @(section != nil), @"hidden": @(hidden),
            @"hiddenKnown": @(hiddenKnown), @"disabled": @(disabled),
            @"itemCount": @(count), @"localOverride": @(changedHere),
            @"owner": owner ?: NSNull.null}];
    }
    // Categories 30/37 are the user's primary inspection targets.
    // Group by the *actual loaded state* instead of mixing unavailable
    // declarations among the actionable section controllers.
    NSMutableArray *priority = [NSMutableArray array];
    NSMutableArray *available = [NSMutableArray array];
    NSMutableArray *unavailable = [NSMutableArray array];
    for (NSDictionary *entry in rows) {
        NSUInteger category = [entry[@"category"] unsignedIntegerValue];
        if (category == 30 || category == 37) [priority addObject:entry];
        else if ([entry[@"loaded"] boolValue]) [available addObject:entry];
        else [unavailable addObject:entry];
    }
    NSMutableArray *groups = [NSMutableArray array], *titles = [NSMutableArray array];
    if (priority.count) {
        [groups addObject:priority.copy];
        [titles addObject:@"Navigation categories · 30 / 37"];
    }
    if (available.count) {
        [groups addObject:available.copy];
        [titles addObject:@"Loaded native sections"];
    }
    if (unavailable.count) {
        [groups addObject:unavailable.copy];
        [titles addObject:@"Declared but not loaded"];
    }
    self.rows = rows.copy;
    self.groupedRows = groups.copy;
    self.groupTitles = titles.copy;
}

// Re-publish the exact already loaded section items through YouTube's existing
// Settings presentation entry point, changing ONLY headerHidden. This does not
// synthesize server items, enable isDisabled, or change account eligibility.
- (BOOL)ytabc_setHeaderHidden:(BOOL)hidden category:(NSDictionary *)entry {
    if (![NSThread isMainThread]) return NO;
    id owner = self.settingsOwner;
    id section = entry[@"section"];
    if (!owner || section == NSNull.null) return NO;
    // YTSettingsSectionItemManager (not the view controller) publishes
    // items through its original _dataDelegate. Validate the exact live
    // Settings VC owning the manager before changing a presentation header.
    id manager = YTABCLiveSettingsSectionItemManager();
    if (!manager) return NO;
    id managerOwner = nil, dataDelegate = nil;
    @try {
        managerOwner = [manager valueForKey:@"_settingsViewControllerDelegate"];
        dataDelegate = [manager valueForKey:@"_dataDelegate"];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (managerOwner != owner || !dataDelegate) return NO;
    id items = YTABCSafeObject(section, "items");
    if (![items isKindOfClass:NSArray.class] || ![(NSArray *)items count]) return NO;
    NSNumber *number = entry[@"category"];
    if (![number isKindOfClass:NSNumber.class]) return NO;
    NSString *title = YTABCReadTitle(section);
    id icon = YTABCSafeObject(section, "icon");
    id desc = YTABCSafeObject(section, "titleDescription");
    NSMutableArray *existing = [(NSArray *)items mutableCopy];

    SEL withIcon = NSSelectorFromString(
        @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL withoutIcon = NSSelectorFromString(
        @"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    Method method = class_getInstanceMethod(object_getClass(dataDelegate), withIcon);
    SEL selector = withIcon;
    NSUInteger expectedArgs = 8;
    if (!method || method_getNumberOfArguments(method) != expectedArgs) {
        selector = withoutIcon;
        method = class_getInstanceMethod(object_getClass(dataDelegate), withoutIcon);
        expectedArgs = 7;
    }
    if (!method || method_getNumberOfArguments(method) != expectedArgs) return NO;
    char returnType[16] = {0}, lastArg[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, (unsigned int)(expectedArgs - 1), lastArg, sizeof(lastArg));
    if (returnType[0] != 'v' || !(lastArg[0] == 'B' || lastArg[0] == 'c')) return NO;
    @try {
        if (expectedArgs == 8)
            ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(
                dataDelegate, selector, existing, number.unsignedIntegerValue,
                title, icon, desc, hidden);
        else
            ((void (*)(id, SEL, id, NSUInteger, id, id, BOOL))objc_msgSend)(
                dataDelegate, selector, existing, number.unsignedIntegerValue,
                title, desc, hidden);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[YTABC SettingsRows] native presentation failed: %@", exception.reason);
        return NO;
    }
}

- (void)ytabc_revealButtonTapped:(UIButton *)sender {
    NSNumber *category = objc_getAssociatedObject(sender, YTABCRevealCategoryAssociation);
    if (!category) return;
    NSDictionary *entry = nil;
    for (NSDictionary *candidate in self.rows)
        if ([candidate[@"category"] isEqual:category]) { entry = candidate; break; }
    if (!entry || ![entry[@"loaded"] boolValue] ||
        [entry[@"itemCount"] unsignedIntegerValue] == 0 ||
        ![entry[@"hiddenKnown"] boolValue]) return;

    NSNumber *prior = self.originalHidden[category];
    BOOL restoring = prior != nil;
    BOOL originalHidden = restoring ? prior.boolValue : [entry[@"hidden"] boolValue];
    BOOL newHidden = restoring ? originalHidden : NO;
    if (![self ytabc_setHeaderHidden:newHidden category:entry]) {
        YTABCShowInspectorNotice(self,
            @"A matching live Settings section-item manager was not available or the native presentation ABI did not match. Nothing was changed.");
        return;
    }
    if (restoring) [self.originalHidden removeObjectForKey:category];
    else self.originalHidden[category] = @(originalHidden);
    [self refreshLiveCategories];
    [self.tableView reloadData];
}

- (instancetype)initWithCategory:(NSDictionary<NSString *, id> *)category {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.title = category[@"title"] ?: @"Native Rows";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    id section = category[@"section"];
    if (section == NSNull.null) section = nil;
    id nativeItems = YTABCSafeObject(section, "items");
    NSMutableArray *details = [NSMutableArray array];
    if ([nativeItems isKindOfClass:NSArray.class]) {
        NSUInteger idx = 0;
        for (id item in nativeItems) {
            NSString *itemTitle = YTABCReadTitle(item);
            [details addObject:@{@"title": itemTitle,
                @"subtitle": [NSString stringWithFormat:
                    @"Native row %lu · %@ · rendered visibility may depend on collection layout",
                    (unsigned long)idx++, NSStringFromClass([item class])]}];
        }
    }
    _details = details.copy;
    return self;
}
- (NSArray<NSDictionary<NSString *, id> *> *)ytabc_entriesInSection:(NSInteger)section {
    if (self.details) return self.details;
    return (section >= 0 && section < (NSInteger)self.groupedRows.count)
        ? self.groupedRows[(NSUInteger)section] : @[];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.details ? 1 : (NSInteger)self.groupedRows.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)[self ytabc_entriesInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return self.details ? nil : self.groupTitles[(NSUInteger)section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *entry = [self ytabc_entriesInSection:indexPath.section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = entry[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = entry[@"subtitle"];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryType = self.details || ![entry[@"loaded"] boolValue]
        ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    if (!self.details && [entry[@"loaded"] boolValue] &&
        [entry[@"hiddenKnown"] boolValue] && [entry[@"itemCount"] unsignedIntegerValue] > 0) {
        BOOL modified = [entry[@"localOverride"] boolValue];
        BOOL hidden = [entry[@"hidden"] boolValue];
        if (modified || hidden) {
            UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
            if (@available(iOS 26.0, *))
                action.configuration = [UIButtonConfiguration glassButtonConfiguration];
            else if (@available(iOS 15.0, *))
                action.configuration = [UIButtonConfiguration tintedButtonConfiguration];
            [action setTitle:modified ? @"Restore" : @"Reveal" forState:UIControlStateNormal];
            action.accessibilityLabel = modified ? @"Restore native header state"
                : @"Reveal this loaded section in original Settings";
            objc_setAssociatedObject(action, YTABCRevealCategoryAssociation,
                entry[@"category"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [action sizeToFit];
            CGRect frame = action.frame;
            frame.size.width = MAX(frame.size.width, 74);
            frame.size.height = MAX(frame.size.height, 36);
            action.frame = frame;
            [action addTarget:self action:@selector(ytabc_revealButtonTapped:)
                forControlEvents:UIControlEventTouchUpInside];
            cell.accessoryView = action;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.details) return;
    NSDictionary *entry = [self ytabc_entriesInSection:indexPath.section][(NSUInteger)indexPath.row];
    if (![entry[@"loaded"] boolValue]) {
        NSUInteger categoryID = [entry[@"category"] unsignedIntegerValue];
        YTABCShowInspectorNotice(self, [NSString stringWithFormat:
            @"Category %lu is declared by YouTube but has no loaded section controller or row models. Revealing a header cannot create it. Open Eligibility Diagnostics in Native Tools to inspect native update calls and experiment service errors.",
            (unsigned long)categoryID]);
        return;
    }
    [self.navigationController pushViewController:
        [[YTABCSettingsRowsInspector alloc] initWithCategory:entry] animated:YES];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (self.details)
        return @"These are the original section-item models. Rows suppressed by server logic are not synthesized or unlocked.";
    if (section != (NSInteger)self.groupedRows.count - 1) return nil;
    return @"Reveal and Restore affect only loaded section headers. Unloaded categories cannot be created by a local visibility override.";
}
@end

UIViewController *YTABCCreateSettingsRowsInspector(id settingsOwner) {
    return [[YTABCSettingsRowsInspector alloc] initWithSettingsOwner:settingsOwner];
}
