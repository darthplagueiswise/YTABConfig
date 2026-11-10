// Native YouTube 21.43.5 UI entry points. No hooks or symbols from injected
// third-party dylibs are used as evidence for this catalog.
//
// This is a LOCAL navigation/diagnostic hub. It never supplies server identity,
// replaces tokens, fabricates a responder, or assumes that an Objective-C class
// can be shown just because its name exists in the Mach-O.
#import "YTABCNativeMenus.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdlib.h>
extern NSDictionary<NSString *, id> *YTABCCopyNativeExperimentsHealth(void);
extern NSDictionary<NSString *, id> *YTABCCopyNativeDiagnostics(void);
extern BOOL YTABCRetryNativeExperimentsSelectedTab(void);
extern void YTABCInstallNativeStudyControlsHooks(void);
extern NSDictionary<NSString *, id> *YTABCCopyNativeStudyControls(void);

static __weak id sYTABCObservedPlaybackOverlay;
static void (*sYTABCOriginalInstallGesture)(id, SEL);

static void YTABCObservedInstallGesture(id self, SEL cmd) {
    // Capture ONLY an instance created by YouTube's own playback lifecycle.
    sYTABCObservedPlaybackOverlay = self;
    if (sYTABCOriginalInstallGesture) sYTABCOriginalInstallGesture(self, cmd);
}

void YTABCInstallNativeMenuObservationHooks(void) {
    static BOOL installed = NO;
    @synchronized([NSObject class]) {
        if (installed) return;
        Class cls = objc_getClass("YTPlaybackDebugOverlayController");
        SEL sel = NSSelectorFromString(@"installGestureRecognizer");
        Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!method || method_getNumberOfArguments(method) != 2) return;
        char *type = method_copyReturnType(method);
        BOOL isVoid = type && type[0] == 'v';
        if (type) free(type);
        if (!isVoid) {
            NSLog(@"[YTABC NativeMenus] Playback gesture ABI mismatch; not hooking");
            return;
        }
        MSHookMessageEx(cls, sel, (IMP)YTABCObservedInstallGesture,
                        (IMP *)&sYTABCOriginalInstallGesture);
        installed = YES;
    }
}

static void YTABCShowNotice(UIViewController *owner, NSString *title, NSString *message) {
    NSLog(@"[YTABC NativeMenus] %@: %@", title, message);
    if (!owner) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static NSString *YTABCClassReport(NSArray<NSString *> *classes) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        [lines addObject:[NSString stringWithFormat:@"%@: %@",
                          name, cls ? @"present" : @"absent"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@interface YTABCNativeMenusViewController : UITableViewController
@property(nonatomic, weak) id settingsOwner;
@property(nonatomic, strong) NSArray<NSDictionary *> *sections;
- (instancetype)initWithSettingsOwner:(id)owner;
@end

@implementation YTABCNativeMenusViewController

- (instancetype)initWithSettingsOwner:(id)owner {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (!self) return nil;
    _settingsOwner = owner;
    self.title = @"YouTube Native Tools";
    _sections = @[
        @{
            @"title": @"Native experiment screens",
            @"rows": @[
                @{@"title": @"Why is native experiments blank?",
                  @"subtitle": @"Inspect parentResponder, native tab count, search calls and results received",
                  @"kind": @"experimentsHealth"},
                @{@"title": @"Retry current native experiments tab",
                  @"subtitle": @"Ask the real view controller to reload its selected tab",
                  @"kind": @"experimentsRetry"},
                @{@"title": @"Study layout, badge & opt-in state",
                  @"subtitle": @"Real native .flexb layout calls, study rows, ineligible badge, and opt-in switch callbacks",
                  @"kind": @"studyControlsHealth"},
                @{@"title": @"Studies (original navigation)",
                  @"subtitle": @"YTSettingsExperimentsTopViewController, via the existing native opener",
                  @"kind": @"studies",
                  @"class": @"YTSettingsExperimentsTopViewController"},
                // Verified from the 21.43.5 ARM64 disassembly:
                // -[YTSettingsExperimentsViewController initWithParentResponder:]
                // constructs YTSettingsExperimentsResultsViewController itself
                // (classref 0x10cbdada8, instruction VA 0x101434748).
                // Results/Study cells are child views, not standalone menu roots.
                @{@"title": @"Native experiments: search, tabs and results",
                  @"subtitle": @"Open the original experiments root. It constructs its own results controllers, study sections and opt-in cells.",
                  @"kind": @"controller",
                  @"class": @"YTSettingsExperimentsViewController"},
                @{@"title": @"Studies (modal)",
                  @"subtitle": @"Native controller in a dismissible navigation sheet",
                  @"kind": @"studiesModal",
                  @"class": @"YTSettingsExperimentsTopViewController"}
            ]
        },
        @{
            @"title": @"Playback and creation diagnostics",
            @"rows": @[
                @{@"title": @"Toggle playback debug overlay",
                  @"subtitle": @"Requires an overlay previously created by the real player",
                  @"kind": @"playback",
                  @"class": @"YTPlaybackDebugOverlayController"},
                @{@"title": @"Toggle creation timeline console",
                  @"subtitle": @"Calls the native shared console only on explicit tap",
                  @"kind": @"creation",
                  @"class": @"YTCreationTimelineDebugConsole"},
                @{@"title": @"Watch debug overlay — inspect",
                  @"subtitle": @"Service/controller existence; no validated menu initializer",
                  @"kind": @"watch",
                  @"class": @"YTWatchDebugOverlayController"},
                @{@"title": @"Lens debug provider — inspect",
                  @"subtitle": @"Check provider presence; Disabled provider is not a menu",
                  @"kind": @"lens",
                  @"class": @"LNSDebugMenuSettingProvider"}
            ]
        },
        @{
            @"title": @"Configuration infrastructure",
            @"rows": @[
                @{@"title": @"Phenotype / Heterodyne inventory",
                  @"subtitle": @"Presence of configuration, snapshot and sync classes (read only)",
                  @"kind": @"phenotype"},
                @{@"title": @"Developer / QA inventory",
                  @"subtitle": @"Check settings and command entry points (read only)",
                  @"kind": @"developer"},
                @{@"title": @"YouTube config inventory",
                  @"subtitle": @"Cold, Hot, Global and flag-ID infrastructure (read only)",
                  @"kind": @"config"}
            ]
        }
    ];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    self.tableView.accessibilityIdentifier = @"YTABC_NATIVE_TOOLS";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return [self.sections[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return self.sections[(NSUInteger)section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *entry = self.sections[(NSUInteger)indexPath.section][@"rows"]
                                        [(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.text = entry[@"title"];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.text = entry[@"subtitle"];
    cell.detailTextLabel.numberOfLines = 3;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    NSString *className = entry[@"class"];
    if (className && !NSClassFromString(className)) {
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ — class absent in this build",
                                       entry[@"subtitle"]];
        if (@available(iOS 13.0, *)) {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        } else {
            cell.textLabel.textColor = [UIColor grayColor];
        }
    }
    return cell;
}

- (BOOL)pushNativeController:(NSString *)className {
    Class cls = NSClassFromString(className);
    if (!cls || ![cls isSubclassOfClass:[UIViewController class]]) {
        YTABCShowNotice(self, @"Native screen unavailable",
                        [NSString stringWithFormat:@"%@ is not a UIViewController in this build.",
                                                   className]);
        return NO;
    }
    SEL initializer = NSSelectorFromString(@"initWithParentResponder:");
    if (!class_getInstanceMethod(cls, initializer)) {
        YTABCShowNotice(self, @"Initializer unavailable",
                        [NSString stringWithFormat:@"%@ lacks initWithParentResponder:.",
                                                   className]);
        return NO;
    }
    id owner = self.settingsOwner;
    Class settingsClass = NSClassFromString(@"YTSettingsViewController");
    if (!owner || (settingsClass && ![owner isKindOfClass:settingsClass])) {
        YTABCShowNotice(self, @"Missing native context",
                        @"The original YouTube settings controller is no longer available.");
        return NO;
    }
    // The native experiments root is a sibling of YTSettingsViewController
    // under YTStyledViewController. Use the live Settings VC itself as
    // parentResponder; NOT Settings.parentResponder (which skips the VC).
    id responder = owner;
    @try {
        id controller = ((id (*)(id, SEL, id))objc_msgSend)(
            [cls alloc], initializer, responder);
        if (![controller isKindOfClass:[UIViewController class]]) {
            YTABCShowNotice(self, @"Invalid native controller",
                            [NSString stringWithFormat:@"%@ failed to construct.", className]);
            return NO;
        }
        if (self.navigationController) {
            [self.navigationController pushViewController:controller animated:YES];
            return YES;
        }
        SEL push = NSSelectorFromString(@"pushViewController:");
        if (owner && [owner respondsToSelector:push]) {
            ((void (*)(id, SEL, UIViewController *))objc_msgSend)(owner, push, controller);
            return YES;
        }
        YTABCShowNotice(self, @"Navigation unavailable",
                        @"No native settings navigator is active.");
        return NO;
    } @catch (NSException *e) {
        YTABCShowNotice(self, @"Native screen failed",
                        [NSString stringWithFormat:@"%@: %@", className, e.reason]);
        return NO;
    }
}

- (void)togglePlaybackOverlay {
    id overlay = sYTABCObservedPlaybackOverlay;
    SEL read = NSSelectorFromString(@"debugOverlayVisible");
    SEL write = NSSelectorFromString(@"setDebugOverlayVisible:");
    Method getterMethod = overlay ? class_getInstanceMethod([overlay class], read) : NULL;
    Method setterMethod = overlay ? class_getInstanceMethod([overlay class], write) : NULL;
    if (!overlay || !getterMethod || !setterMethod ||
        method_getNumberOfArguments(getterMethod) != 2 ||
        method_getNumberOfArguments(setterMethod) != 3) {
        YTABCShowNotice(self, @"Playback overlay not active",
                        @"YouTube has not invoked installGestureRecognizer on a live "
                        @"YTPlaybackDebugOverlayController. Open a video first. "
                        @"No overlay object will be fabricated.");
        return;
    }
    @try {
        BOOL wasVisible = ((BOOL (*)(id, SEL))objc_msgSend)(overlay, read);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(overlay, write, !wasVisible);
        YTABCShowNotice(self, @"Playback overlay",
                        !wasVisible ? @"Native debug overlay enabled."
                                    : @"Native debug overlay disabled.");
    } @catch (NSException *e) {
        YTABCShowNotice(self, @"Playback overlay error", e.reason);
    }
}

- (void)toggleCreationConsole {
    Class cls = NSClassFromString(@"YTCreationTimelineDebugConsole");
    SEL shared = NSSelectorFromString(@"shared");
    SEL toggle = NSSelectorFromString(@"toggleDebugMode");
    Method factory = cls ? class_getClassMethod(cls, shared) : NULL;
    Method toggleMethod = cls ? class_getInstanceMethod(cls, toggle) : NULL;
    if (!factory || !toggleMethod ||
        method_getNumberOfArguments(factory) != 2 ||
        method_getNumberOfArguments(toggleMethod) != 2) {
        YTABCShowNotice(self, @"Creation console unavailable",
                        @"No usable YTCreationTimelineDebugConsole.shared class method.");
        return;
    }
    @try {
        id console = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        if (!console || ![console respondsToSelector:toggle]) {
            YTABCShowNotice(self, @"Creation console unavailable",
                            @"The native console is not initialized or does not expose toggleDebugMode.");
            return;
        }
        ((void (*)(id, SEL))objc_msgSend)(console, toggle);
        YTABCShowNotice(self, @"Creation console",
                        @"Called the native toggleDebugMode selector. "
                        @"A visible console depends on YouTube's editor lifecycle.");
    } @catch (NSException *e) {
        YTABCShowNotice(self, @"Creation console error", e.reason);
    }
}

- (void)showNativeStudyControls {
    NSDictionary<NSString *, id> *snapshot = YTABCCopyNativeStudyControls() ?: @{};
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *key in [[snapshot allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, snapshot[key]]];
    [lines addObject:@"\nBadge and opt-in state are read from the most recently bound native study cell. No study rows means these values are not evidence of eligibility."];
    YTABCShowNotice(self, @"Native study layout and controls", [lines componentsJoinedByString:@"\n"]);
}

- (void)showExperimentsHealth {
    NSDictionary *ui = YTABCCopyNativeExperimentsHealth() ?: @{};
    NSDictionary *network = YTABCCopyNativeDiagnostics() ?: @{};
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        @"NATIVE VIEW CONTROLLER"];
    for (NSString *key in [[ui allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, ui[key]]];
    }
    [lines addObject:@"\nNATIVE EXPERIMENT SERVICE"];
    for (NSString *key in @[@"nativeExperimentsServiceObserved", @"nativeSearchCalls",
                             @"nativeOptInCalls", @"nativeOptOutCalls",
                             @"nativeHasGooglerAccount", @"nativeIsInternalSyncer"]) {
        if (network[key])
            [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, network[key]]];
    }
    [lines addObject:@"\nAn empty result does not identify a specific server gate. Check whether search ran and whether result sections arrived."];
    YTABCShowNotice(self, @"Experiments initialization", [lines componentsJoinedByString:@"\n"]);
}

- (void)showInventory:(NSString *)kind {
    NSArray<NSString *> *classes = @[];
    NSString *title = @"Runtime inventory";
    if ([kind isEqualToString:@"phenotype"]) {
        title = @"Phenotype / Heterodyne";
        classes = @[@"PHTPhenotype", @"PHTFlatFilePhenotype",
                    @"PHTPhenotypeFlags", @"PHTPhenotypeFlagsSnapshot",
                    @"PHTPhenotypeConfiguration", @"PHTHeterodyneSyncer",
                    @"PHTInternalHeterodyneSyncer", @"PHTURL"];
    } else if ([kind isEqualToString:@"developer"]) {
        title = @"Developer / QA";
        classes = @[@"YTSettingsGroupData", @"YTSettingsViewController",
                    @"YTSettingsSectionItemManager", @"YTExperimentsEndpointCommandImpl",
                    @"YTClientSideExperimentsController", @"PlayDeveloperConsole"];
    } else if ([kind isEqualToString:@"config"]) {
        title = @"YouTube configuration";
        classes = @[@"YTColdConfig", @"YTHotConfig", @"YTGlobalConfig",
                    @"YTColdConfigStorage", @"YTExperimentFlagIDBasedConfigImpl",
                    @"YTExperimentsServiceImpl"];
    } else if ([kind isEqualToString:@"lens"]) {
        title = @"Lens debug provider";
        classes = @[@"LNSDebugMenuSettingProvider",
                    @"DisabledDebugMenuSettingProvider"];
    } else if ([kind isEqualToString:@"watch"]) {
        title = @"Watch debug";
        classes = @[@"YTWatchDebugOverlayController",
                    @"YTPlaybackDebugOverlayController"];
    }
    YTABCShowNotice(self, title,
                    [NSString stringWithFormat:@"%@\n\n"
                        @"Presence does not establish a launchable menu or permission.",
                        YTABCClassReport(classes)]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.sections[(NSUInteger)indexPath.section][@"rows"]
                                        [(NSUInteger)indexPath.row];
    NSString *kind = entry[@"kind"];
    id owner = self.settingsOwner;
    if ([kind isEqualToString:@"experimentsHealth"]) {
        [self showExperimentsHealth];
    } else if ([kind isEqualToString:@"studyControlsHealth"]) {
        [self showNativeStudyControls];
    } else if ([kind isEqualToString:@"experimentsRetry"]) {
        BOOL queued = YTABCRetryNativeExperimentsSelectedTab();
        YTABCShowNotice(self, @"Native experiments reload", queued
            ? @"Called updateDataForTab: on the existing native selected tab. Check Health for changes."
            : @"No live experiments root with a valid selected tab; use the original launcher first.");
    } else if ([kind isEqualToString:@"studies"]) {
        extern BOOL YTABCPushNativeExperiments(id);
        if (!YTABCPushNativeExperiments(owner)) {
            YTABCShowNotice(self, @"Native studies unavailable",
                            @"The existing studies push opener could not launch the native screen.");
        }
    } else if ([kind isEqualToString:@"studiesModal"]) {
        extern BOOL YTABCPresentNativeExperiments(id);
        if (!YTABCPresentNativeExperiments(owner)) {
            YTABCShowNotice(self, @"Native studies unavailable",
                            @"The existing modal opener could not launch the native screen.");
        }
    } else if ([kind isEqualToString:@"controller"]) {
        [self pushNativeController:entry[@"class"]];
    } else if ([kind isEqualToString:@"playback"]) {
        [self togglePlaybackOverlay];
    } else if ([kind isEqualToString:@"creation"]) {
        [self toggleCreationConsole];
    } else {
        [self showInventory:kind];
    }
}

@end

BOOL YTABCPushNativeMenuHub(id settingsViewController) {
    if (![NSThread isMainThread]) {
        NSLog(@"[YTABC NativeMenus] Refusing off-main UIKit navigation");
        return NO;
    }
    YTABCInstallNativeMenuObservationHooks();
    if (!settingsViewController) return NO;
    // Keep study hooks out of %ctor / cold start.
    YTABCInstallNativeStudyControlsHooks();
    YTABCNativeMenusViewController *menu =
        [[YTABCNativeMenusViewController alloc] initWithSettingsOwner:settingsViewController];
    SEL push = NSSelectorFromString(@"pushViewController:");
    @try {
        if ([settingsViewController respondsToSelector:push]) {
            ((void (*)(id, SEL, UIViewController *))objc_msgSend)(
                settingsViewController, push, menu);
            return YES;
        }
        if ([settingsViewController isKindOfClass:[UIViewController class]]) {
            UINavigationController *nav =
                [(UIViewController *)settingsViewController navigationController];
            if (nav) {
                [nav pushViewController:menu animated:YES];
                return YES;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[YTABC NativeMenus] Navigation failed: %@", e.reason);
    }
    return NO;
}
