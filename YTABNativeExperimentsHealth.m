// YouTube 21.43.5: original native experiments view lifecycle diagnostics.
// Method encodings and call ownership were read from the supplied executable.
// Does not synthesize an account, touch request authorization or fabricate data.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <string.h>

static __weak id sNativeExperimentsRoot;
static NSUInteger sRootInitializations, sRootAppearances, sTabRefreshes;
static NSUInteger sSearchRequests, sResultSectionUpdates, sLastResultSections;
static BOOL sHadParentResponder;
static NSString *sParentResponderClass;
static NSMutableSet<NSString *> *sInstalledExperimentsHooks;

static id (*sOriginalInit)(id, SEL, id);
static id YTABNativeExperimentsInit(id receiver, SEL selector, id parentResponder) {
    id viewController = sOriginalInit ? sOriginalInit(receiver, selector, parentResponder) : nil;
    @synchronized([NSProcessInfo processInfo]) {
        sRootInitializations++;
        sHadParentResponder = parentResponder != nil;
        sParentResponderClass = parentResponder
            ? NSStringFromClass([parentResponder class]) : @"nil";
        if (viewController) sNativeExperimentsRoot = viewController;
    }
    return viewController;
}

static void (*sOriginalAppear)(id, SEL, BOOL);
static void YTABNativeExperimentsAppear(id receiver, SEL selector, BOOL animated) {
    if (sOriginalAppear) sOriginalAppear(receiver, selector, animated);
    @synchronized([NSProcessInfo processInfo]) {
        sNativeExperimentsRoot = receiver;
        sRootAppearances++;
    }
}

static void (*sOriginalUpdateTab)(id, SEL, NSUInteger);
static void YTABNativeExperimentsUpdateTab(id receiver, SEL selector, NSUInteger index) {
    @synchronized([NSProcessInfo processInfo]) {
        sNativeExperimentsRoot = receiver;
        sTabRefreshes++;
    }
    if (sOriginalUpdateTab) sOriginalUpdateTab(receiver, selector, index);
}

static void (*sOriginalSearch)(id, SEL, id, NSUInteger);
static void YTABNativeExperimentsSearch(id receiver, SEL selector, id query, NSUInteger index) {
    @synchronized([NSProcessInfo processInfo]) {
        sNativeExperimentsRoot = receiver;
        sSearchRequests++;
    }
    // Do not log typed search strings, account IDs, or other personal data.
    if (sOriginalSearch) sOriginalSearch(receiver, selector, query, index);
}

static void (*sOriginalResultSections)(id, SEL, id);
static void YTABNativeExperimentResults(id receiver, SEL selector, id sections) {
    @synchronized([NSProcessInfo processInfo]) {
        sResultSectionUpdates++;
        sLastResultSections = [sections isKindOfClass:[NSArray class]]
            ? [(NSArray *)sections count] : 0;
    }
    if (sOriginalResultSections) sOriginalResultSections(receiver, selector, sections);
}

static BOOL YTABNativeExperimentHook(Class cls, const char *selectorName,
                                     const char *typeEncoding, IMP replacement, IMP *original) {
    if (!cls) return NO;
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !method_getTypeEncoding(method) ||
        strcmp(method_getTypeEncoding(method), typeEncoding)) {
        NSLog(@"[YTABC Experiments] ABI unavailable: %@ %s", NSStringFromClass(cls), selectorName);
        return NO;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%s", NSStringFromClass(cls), selectorName];
    @synchronized([NSProcessInfo processInfo]) {
        if ([sInstalledExperimentsHooks containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, replacement, original);
        if (!*original) {
            NSLog(@"[YTABC Experiments] Missing original IMP for %@", key);
            return NO;
        }
        [sInstalledExperimentsHooks addObject:key];
        return YES;
    }
}

void YTABCInstallNativeExperimentsHealthHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstalledExperimentsHooks = [NSMutableSet set];
    });
    Class root = objc_lookUpClass("YTSettingsExperimentsViewController");
    Class results = objc_lookUpClass("YTSettingsExperimentsResultsViewController");
    YTABNativeExperimentHook(root, "initWithParentResponder:", "@24@0:8@16",
                             (IMP)YTABNativeExperimentsInit, (IMP *)&sOriginalInit);
    YTABNativeExperimentHook(root, "viewWillAppear:", "v20@0:8B16",
                             (IMP)YTABNativeExperimentsAppear, (IMP *)&sOriginalAppear);
    YTABNativeExperimentHook(root, "updateDataForTab:", "v24@0:8Q16",
                             (IMP)YTABNativeExperimentsUpdateTab, (IMP *)&sOriginalUpdateTab);
    YTABNativeExperimentHook(root, "makeSearchWithQuery:forTabIndex:", "v32@0:8@16Q24",
                             (IMP)YTABNativeExperimentsSearch, (IMP *)&sOriginalSearch);
    YTABNativeExperimentHook(results, "addSectionsFromArray:", "v24@0:8@16",
                             (IMP)YTABNativeExperimentResults, (IMP *)&sOriginalResultSections);
}

NSDictionary<NSString *, id> *YTABCCopyNativeExperimentsHealth(void) {
    id root = nil;
    NSUInteger initCount, appearanceCount, tabRefreshCount, searchCount, updates, lastSections;
    BOOL hadResponder;
    NSString *responderClass = nil;
    NSUInteger installed;
    @synchronized([NSProcessInfo processInfo]) {
        root = sNativeExperimentsRoot;
        initCount = sRootInitializations;
        appearanceCount = sRootAppearances;
        tabRefreshCount = sTabRefreshes;
        searchCount = sSearchRequests;
        updates = sResultSectionUpdates;
        lastSections = sLastResultSections;
        hadResponder = sHadParentResponder;
        responderClass = sParentResponderClass ?: @"not observed";
        installed = sInstalledExperimentsHooks.count;
    }
    NSUInteger pages = 0, selected = NSNotFound;
    BOOL canUpdate = NO;
    if (root) {
        SEL pagesSel = NSSelectorFromString(@"contentViewControllers");
        SEL selectedSel = NSSelectorFromString(@"selectedTabIndex");
        if ([root respondsToSelector:pagesSel]) {
            id list = ((id (*)(id, SEL))objc_msgSend)(root, pagesSel);
            if ([list respondsToSelector:@selector(count)]) pages = [list count];
        }
        if ([root respondsToSelector:selectedSel])
            selected = ((NSUInteger (*)(id, SEL))objc_msgSend)(root, selectedSel);
        canUpdate = [root respondsToSelector:NSSelectorFromString(@"updateDataForTab:")];
    }
    return @{
        @"rootCurrentlyAlive": @(root != nil),
        @"rootInitializerCalls": @(initCount),
        @"rootAppearances": @(appearanceCount),
        @"parentResponderWasNonNil": @(hadResponder),
        @"parentResponderClass": responderClass,
        @"nativeTabControllerCount": @(pages),
        @"selectedTabIndex": selected == NSNotFound ? @"unavailable" : @(selected),
        @"updateDataForTabCalls": @(tabRefreshCount),
        @"makeSearchCalls": @(searchCount),
        @"resultsAddSectionsCalls": @(updates),
        @"lastResultSectionCount": @(lastSections),
        @"selectedTabCanRetry": @(canUpdate && selected != NSNotFound && selected < pages),
        @"installedLifecycleHooks": @(installed)
    };
}

BOOL YTABCRetryNativeExperimentsSelectedTab(void) {
    id root = nil;
    @synchronized([NSProcessInfo processInfo]) { root = sNativeExperimentsRoot; }
    if (!root) return NO;
    SEL selectedSel = NSSelectorFromString(@"selectedTabIndex");
    SEL refreshSel = NSSelectorFromString(@"updateDataForTab:");
    if (![root respondsToSelector:selectedSel] || ![root respondsToSelector:refreshSel]) return NO;
    Method refreshMethod = class_getInstanceMethod([root class], refreshSel);
    if (!refreshMethod || !method_getTypeEncoding(refreshMethod) ||
        strcmp(method_getTypeEncoding(refreshMethod), "v24@0:8Q16")) return NO;
    NSUInteger selected = ((NSUInteger (*)(id, SEL))objc_msgSend)(root, selectedSel);
    SEL pagesSel = NSSelectorFromString(@"contentViewControllers");
    id pages = [root respondsToSelector:pagesSel]
        ? ((id (*)(id, SEL))objc_msgSend)(root, pagesSel) : nil;
    if (![pages respondsToSelector:@selector(count)] || selected >= [pages count]) return NO;
    if (![NSThread isMainThread]) return NO;
    @try {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(root, refreshSel, selected);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[YTABC Experiments] native tab retry exception: %@", exception.reason);
        return NO;
    }
}
