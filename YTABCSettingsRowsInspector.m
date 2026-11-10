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

static NSString *YTABCReadTitle(id obj) {
    id value = YTABCSafeObject(obj, "title");
    return [value isKindOfClass:NSString.class] && [value length]
        ? value : NSStringFromClass([obj class]) ?: @"Unnamed";
}

@interface YTABCSettingsRowsInspector : UITableViewController
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *rows;
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *details;
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

    // Enumerate only actual section controllers and the app's own declared
    // Settings category order. A declared but not loaded section is NOT
    // presented as a hidden item or a loadable menu.
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
        NSString *name = section ? YTABCReadTitle(section)
                                 : [NSString stringWithFormat:@"Category %@", number];
        NSString *subtitle = section
            ? [NSString stringWithFormat:@"ID %@ · %lu rows · header %@ · %@",
                number, (unsigned long)([items isKindOfClass:NSArray.class]
                                    ? [items count] : 0),
                hiddenKnown ? (hidden ? @"hidden" : @"visible") : @"unknown",
                disabledKnown ? (disabled ? @"disabled" : @"enabled") : @"unknown"]
            : @"Declared in native order; not loaded by current Settings model";
        [rows addObject:@{@"title": name ?: @"Settings",
                          @"subtitle": subtitle,
                          @"category": number,
                          @"section": section ?: NSNull.null,
                          @"loaded": @(section != nil)}];
    }
    _rows = rows.copy;
    return self;
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)(self.details ?: self.rows).count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *entry = (self.details ?: self.rows)[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = entry[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = entry[@"subtitle"];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryType = self.details || ![entry[@"loaded"] boolValue]
        ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.details) return;
    NSDictionary *entry = self.rows[(NSUInteger)indexPath.row];
    if (![entry[@"loaded"] boolValue]) return;
    [self.navigationController pushViewController:
        [[YTABCSettingsRowsInspector alloc] initWithCategory:entry] animated:YES];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.details
        ? @"These are the original section-item models. Rows suppressed by server logic are not synthesized or unlocked."
        : @"Only loaded native Settings sections can be inspected. Header-hidden does not mean account-ineligible. An absent declared section is not an unlocked menu.";
}
@end

UIViewController *YTABCCreateSettingsRowsInspector(id settingsOwner) {
    return [[YTABCSettingsRowsInspector alloc] initWithSettingsOwner:settingsOwner];
}
