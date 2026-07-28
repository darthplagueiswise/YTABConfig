#import "YTABRuntimeBrowser.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>

static NSString * const YTABRuntimeBrowserOverridesKey = @"YTABCRuntimeBrowserOverrides";

typedef NS_ENUM(NSInteger, YTABRuntimeImageScope) {
    YTABRuntimeImageScopeYouTube = 0,
    YTABRuntimeImageScopeModule = 1,
    YTABRuntimeImageScopeAll = 2,
};

typedef NS_ENUM(NSInteger, YTABRuntimeArgumentKind) {
    YTABRuntimeArgumentKindNone = 0,
    YTABRuntimeArgumentKindObject = 1,
    YTABRuntimeArgumentKindInteger = 2,
    YTABRuntimeArgumentKindUnsupported = -1,
};

@interface YTABRuntimeMethod : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeEncoding;
@property(nonatomic, copy) NSString *imageName;
@property(nonatomic) BOOL classMethod;
@property(nonatomic) YTABRuntimeArgumentKind argumentKind;
@property(nonatomic, readonly) NSString *patchKey;
@end

@implementation YTABRuntimeMethod
- (NSString *)patchKey {
    return [NSString stringWithFormat:@"%@%@#%@",
            self.classMethod ? @"+" : @"", self.className, self.selectorName];
}
@end

static NSDictionary<NSString *, NSNumber *> *sYTABRuntimeOverrideCache;
static NSMutableSet<NSString *> *sYTABRuntimeInstalledKeys;
static NSMutableDictionary<NSString *, NSNumber *> *sYTABRuntimeObservedNative;

static NSDictionary<NSString *, NSNumber *> *YTABRuntimeStoredOverrides(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTABRuntimeBrowserOverridesKey];
    if (![value isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![object isKindOfClass:[NSNumber class]]) return;
        clean[key] = @([(NSNumber *)object boolValue]);
    }];
    return clean.copy;
}

static void YTABRuntimeRefreshOverrideCache(void) {
    sYTABRuntimeOverrideCache = YTABRuntimeStoredOverrides();
}

static NSNumber *YTABRuntimeCachedOverride(NSString *key) {
    id value = sYTABRuntimeOverrideCache[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static void YTABRuntimeRememberNative(NSString *key, BOOL value) {
    if (!key.length) return;
    @synchronized([YTABRuntimeMethod class]) {
        if (!sYTABRuntimeObservedNative) sYTABRuntimeObservedNative = [NSMutableDictionary dictionary];
        sYTABRuntimeObservedNative[key] = @(value);
    }
}

static NSNumber *YTABRuntimeObservedNative(NSString *key) {
    @synchronized([YTABRuntimeMethod class]) {
        return sYTABRuntimeObservedNative[key];
    }
}

static YTABRuntimeArgumentKind YTABRuntimeArgumentKindForMethod(Method method) {
    if (!method) return YTABRuntimeArgumentKindUnsupported;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return YTABRuntimeArgumentKindNone;
    if (count != 3) return YTABRuntimeArgumentKindUnsupported;

    char type[32] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    const char *cursor = type;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor == '@' || *cursor == '#' || *cursor == ':') {
        return YTABRuntimeArgumentKindObject;
    }
    if (*cursor && strchr("BcCsSiIlLqQ^*", *cursor)) {
        return YTABRuntimeArgumentKindInteger;
    }
    return YTABRuntimeArgumentKindUnsupported;
}

static BOOL YTABRuntimeMethodSupported(Method method) {
    if (!method) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (!(returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C')) return NO;
    return YTABRuntimeArgumentKindForMethod(method) != YTABRuntimeArgumentKindUnsupported;
}

static BOOL YTABRuntimeSelectorAllowed(Method method) {
    if (!YTABRuntimeMethodSupported(method)) return NO;
    const char *name = sel_getName(method_getName(method));
    if (!name || !*name) return NO;
    if (!strncmp(name, "set", 3) || !strncmp(name, "init", 4)) return NO;
    static const char *blocked[] = {
        "isEqual:", "respondsToSelector:", "conformsToProtocol:",
        "isKindOfClass:", "isMemberOfClass:"
    };
    for (NSUInteger index = 0; index < sizeof(blocked) / sizeof(blocked[0]); index++) {
        if (!strcmp(name, blocked[index])) return NO;
    }
    return YES;
}

static BOOL YTABRuntimeParsePatchKey(NSString *key,
                                     NSString **className,
                                     NSString **selectorName,
                                     BOOL *classMethod) {
    if (!key.length) return NO;
    BOOL isClassMethod = [key hasPrefix:@"+"];
    NSString *body = isClassMethod ? [key substringFromIndex:1] : key;
    NSRange separator = [body rangeOfString:@"#"];
    if (separator.location == NSNotFound || separator.location == 0 ||
        NSMaxRange(separator) >= body.length) return NO;
    if (className) *className = [body substringToIndex:separator.location];
    if (selectorName) *selectorName = [body substringFromIndex:NSMaxRange(separator)];
    if (classMethod) *classMethod = isClassMethod;
    return YES;
}

static BOOL YTABRuntimeInstallPatchKey(NSString *key) {
    if (!key.length) return NO;
    @synchronized([YTABRuntimeMethod class]) {
        if (!sYTABRuntimeInstalledKeys) sYTABRuntimeInstalledKeys = [NSMutableSet set];
        if ([sYTABRuntimeInstalledKeys containsObject:key]) return YES;
    }

    NSString *className = nil;
    NSString *selectorName = nil;
    BOOL classMethod = NO;
    if (!YTABRuntimeParsePatchKey(key, &className, &selectorName, &classMethod)) return NO;

    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !selector) return NO;

    Class hookClass = classMethod ? object_getClass(cls) : cls;
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    if (!hookClass || !YTABRuntimeMethodSupported(method)) return NO;

    YTABRuntimeArgumentKind argumentKind = YTABRuntimeArgumentKindForMethod(method);
    NSString *capturedKey = key.copy;
    SEL capturedSelector = selector;
    __block IMP original = NULL;
    IMP replacement = NULL;

    if (argumentKind == YTABRuntimeArgumentKindNone) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            return override ? override.boolValue : nativeValue;
        });
    } else if (argumentKind == YTABRuntimeArgumentKindObject) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL, id))original)(receiver, capturedSelector, argument)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            return override ? override.boolValue : nativeValue;
        });
    } else if (argumentKind == YTABRuntimeArgumentKindInteger) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, uint64_t argument) {
            BOOL nativeValue = original
                ? ((BOOL (*)(id, SEL, uint64_t))original)(receiver, capturedSelector, argument)
                : NO;
            YTABRuntimeRememberNative(capturedKey, nativeValue);
            NSNumber *override = YTABRuntimeCachedOverride(capturedKey);
            return override ? override.boolValue : nativeValue;
        });
    }

    if (!replacement) return NO;
    MSHookMessageEx(hookClass, selector, replacement, &original);
    if (!original) return NO;

    @synchronized([YTABRuntimeMethod class]) {
        [sYTABRuntimeInstalledKeys addObject:key];
    }
    return YES;
}

static NSNumber *YTABRuntimeOverrideForKey(NSString *key) {
    id value = YTABRuntimeStoredOverrides()[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static BOOL YTABRuntimeSetOverride(NSNumber *value, NSString *key) {
    if (!key.length) return NO;
    NSMutableDictionary *overrides = [YTABRuntimeStoredOverrides() mutableCopy];
    if (value) overrides[key] = @(value.boolValue);
    else [overrides removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:overrides.copy
                                              forKey:YTABRuntimeBrowserOverridesKey];
    YTABRuntimeRefreshOverrideCache();
    return value ? YTABRuntimeInstallPatchKey(key) : YES;
}

static void YTABRuntimeClearOverrides(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTABRuntimeBrowserOverridesKey];
    YTABRuntimeRefreshOverrideCache();
}

void YTABRuntimeBrowserReinstallPersistedHooks(void) {
    YTABRuntimeRefreshOverrideCache();
    for (NSString *key in sYTABRuntimeOverrideCache) {
        YTABRuntimeInstallPatchKey(key);
    }
}

NSUInteger YTABRuntimeBrowserPersistedOverrideCount(void) {
    return YTABRuntimeStoredOverrides().count;
}

static BOOL YTABRuntimeClassExcluded(NSString *className) {
    static NSSet<NSString *> *excluded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[@"YTGlobalConfig", @"YTColdConfig", @"YTHotConfig"]];
    });
    return [excluded containsObject:className];
}

static YTABRuntimeImageScope YTABRuntimeScopeForImageName(NSString *imageName) {
    if (!imageName.length) return -1;
    NSString *mainExecutable = [NSBundle mainBundle].executablePath;
    if ([imageName isEqualToString:mainExecutable] ||
        [imageName.lastPathComponent isEqualToString:mainExecutable.lastPathComponent]) {
        return YTABRuntimeImageScopeYouTube;
    }
    if ([imageName containsString:@"/Module_Framework.framework/"] ||
        [imageName.lastPathComponent isEqualToString:@"Module_Framework"]) {
        return YTABRuntimeImageScopeModule;
    }
    return -1;
}

static BOOL YTABRuntimeScopeMatches(YTABRuntimeImageScope requested,
                                    YTABRuntimeImageScope actual) {
    return requested == YTABRuntimeImageScopeAll || requested == actual;
}

static NSArray<YTABRuntimeMethod *> *YTABRuntimeDiscoverMethods(YTABRuntimeImageScope scope) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return @[];

    NSMutableArray<YTABRuntimeMethod *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
        Class cls = classes[classIndex];
        const char *imageCString = class_getImageName(cls);
        if (!imageCString) continue;
        NSString *imageName = [NSString stringWithUTF8String:imageCString];
        YTABRuntimeImageScope imageScope = YTABRuntimeScopeForImageName(imageName);
        if (imageScope < 0 || !YTABRuntimeScopeMatches(scope, imageScope)) continue;

        NSString *className = NSStringFromClass(cls);
        if (!className.length || YTABRuntimeClassExcluded(className)) continue;

        for (NSUInteger pass = 0; pass < 2; pass++) {
            BOOL classMethod = pass == 1;
            Class owner = classMethod ? object_getClass(cls) : cls;
            if (!owner) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            for (unsigned int methodIndex = 0; methods && methodIndex < methodCount; methodIndex++) {
                Method method = methods[methodIndex];
                if (!YTABRuntimeSelectorAllowed(method)) continue;
                NSString *selectorName = NSStringFromSelector(method_getName(method));
                NSString *patchKey = [NSString stringWithFormat:@"%@%@#%@",
                                      classMethod ? @"+" : @"", className, selectorName];
                if ([seen containsObject:patchKey]) continue;
                [seen addObject:patchKey];

                YTABRuntimeMethod *entry = [YTABRuntimeMethod new];
                entry.className = className;
                entry.selectorName = selectorName;
                entry.classMethod = classMethod;
                entry.argumentKind = YTABRuntimeArgumentKindForMethod(method);
                entry.typeEncoding = [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""];
                entry.imageName = imageName.lastPathComponent ?: imageName;
                [results addObject:entry];
            }
            if (methods) free(methods);
        }
    }
    free(classes);

    [results sortUsingComparator:^NSComparisonResult(YTABRuntimeMethod *left,
                                                      YTABRuntimeMethod *right) {
        NSComparisonResult classResult = [left.className localizedCaseInsensitiveCompare:right.className];
        if (classResult != NSOrderedSame) return classResult;
        if (left.classMethod != right.classMethod) return left.classMethod ? NSOrderedAscending : NSOrderedDescending;
        return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
    }];
    return results.copy;
}

static NSArray<NSString *> *YTABRuntimeSearchTokens(NSString *query) {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *component in [query componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        NSString *token = [component stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (token.length) [tokens addObject:token];
    }
    return tokens.copy;
}

@interface YTABRuntimeBrowserViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<YTABRuntimeMethod *> *allMethods;
@property(nonatomic, strong) NSArray<YTABRuntimeMethod *> *visibleMethods;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UISegmentedControl *scopeControl;
@property(nonatomic) NSUInteger scanGeneration;
@end

@implementation YTABRuntimeBrowserViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Patches";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = 58.0;
    self.tableView.estimatedRowHeight = 58.0;

    self.scopeControl = [[UISegmentedControl alloc] initWithItems:@[@"YouTube", @"Module", @"All"]];
    self.scopeControl.selectedSegmentIndex = YTABRuntimeImageScopeYouTube;
    [self.scopeControl addTarget:self action:@selector(scopeChanged:)
                forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.scopeControl;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Class, selector or encoding";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Clear"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(clearOverrides)];

    [self loadMethods];
}

- (void)scopeChanged:(UISegmentedControl *)sender {
    (void)sender;
    [self loadMethods];
}

- (void)loadMethods {
    NSUInteger generation = ++self.scanGeneration;
    self.allMethods = @[];
    self.visibleMethods = @[];
    [self.tableView reloadData];

    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.tableView.backgroundView = indicator;

    YTABRuntimeImageScope scope = (YTABRuntimeImageScope)self.scopeControl.selectedSegmentIndex;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<YTABRuntimeMethod *> *methods = YTABRuntimeDiscoverMethods(scope);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.scanGeneration) return;
            strongSelf.tableView.backgroundView = nil;
            strongSelf.allMethods = methods;
            [strongSelf applyFilter];
        });
    });
}

- (void)applyFilter {
    NSArray<NSString *> *tokens = YTABRuntimeSearchTokens(self.searchController.searchBar.text ?: @"");
    if (!tokens.count) {
        self.visibleMethods = self.allMethods ?: @[];
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (YTABRuntimeMethod *method in self.allMethods) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                                  method.className, method.selectorName,
                                  method.typeEncoding, method.patchKey].lowercaseString;
            BOOL matchesAll = YES;
            for (NSString *token in tokens) {
                if (![haystack containsString:token]) {
                    matchesAll = NO;
                    break;
                }
            }
            if (matchesAll) [matches addObject:method];
        }
        self.visibleMethods = matches.copy;
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self applyFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleMethods.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%lu patchable BOOL methods",
            (unsigned long)self.visibleMethods.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Tap a method to choose System, Force OFF, or Force ON. Only saved patch keys are reinstalled at launch; discovery runs only while this browser is open. Keep the older fixed employee-test switches off while using this browser.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTABRuntimeMethodCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.detailTextLabel.numberOfLines = 1;
        cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }

    YTABRuntimeMethod *method = self.visibleMethods[indexPath.row];
    NSNumber *override = YTABRuntimeOverrideForKey(method.patchKey);
    NSNumber *native = YTABRuntimeObservedNative(method.patchKey);
    NSString *state = override ? (override.boolValue ? @"Force ON" : @"Force OFF") : @"System";
    NSString *nativeText = native ? (native.boolValue ? @"1" : @"0") : @"—";
    NSString *methodKind = method.classMethod ? @"class" : @"instance";

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
                           method.classMethod ? @"+ " : @"- ", method.selectorName];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · native %@",
                                 method.className, methodKind, state, nativeText];
    cell.detailTextLabel.textColor = override ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTABRuntimeMethod *method = self.visibleMethods[indexPath.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:method.selectorName
        message:[NSString stringWithFormat:@"%@\n%@\n%@",
                 method.className, method.typeEncoding, method.patchKey]
        preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    void (^applyValue)(NSNumber *) = ^(NSNumber *value) {
        BOOL success = YTABRuntimeSetOverride(value, method.patchKey);
        [weakSelf.tableView reloadData];
        if (!success) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"Patch unavailable"
                message:@"The class or method is no longer loaded, or its Objective-C ABI changed."
                preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:error animated:YES completion:nil];
        }
    };

    [sheet addAction:[UIAlertAction actionWithTitle:@"System"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(nil); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force OFF"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(@NO); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force ON"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { applyValue(@YES); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy patch key"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = method.patchKey;
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        popover.sourceView = cell ?: self.view;
        popover.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)clearOverrides {
    if (!YTABRuntimeBrowserPersistedOverrideCount()) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear runtime patches?"
        message:@"Installed hooks remain pass-through until restart, but every saved override returns to System immediately."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            YTABRuntimeClearOverrides();
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
