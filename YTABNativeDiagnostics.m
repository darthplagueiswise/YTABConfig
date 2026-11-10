// Native YouTube 21.43.5 Phenotype / InnerTube experiment diagnostics.
// Audited against Payload/YouTube.app/YouTube, never injected tweak dylibs.
// Transparent ABI-checked hooks; no token, request, or server-role modification.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <string.h>

static __weak id lastSyncer;
static __weak id lastExperimentService;
static NSUInteger syncCalls, configurationCalls, searchCalls, optInCalls, optOutCalls;
static BOOL sawGooglerCheck, lastNativeGoogler, sawInternalCheck, lastNativeInternal;
static NSMutableSet<NSString *> *installedMethods;

static BOOL YTABNativeTrace(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

static void (*originalSync)(id,SEL,id);
static void YTABSync(id target, SEL selector, id completion) {
    @synchronized([NSProcessInfo processInfo]) { lastSyncer = target; syncCalls++; }
    if (YTABNativeTrace(@"YTABCTracePhenotype"))
        NSLog(@"[YTABC Phenotype] native syncWithCallback on %@", NSStringFromClass([target class]));
    if (originalSync) originalSync(target, selector, completion);
}

static void (*originalConfigurationSync)(id,SEL,id,id,id);
static void YTABConfigurationSync(id target, SEL selector, id syncer, id after, id callback) {
    @synchronized([NSProcessInfo processInfo]) {
        configurationCalls++;
        if (syncer && [syncer respondsToSelector:NSSelectorFromString(@"syncWithCallback:")])
            lastSyncer = syncer;
    }
    if (YTABNativeTrace(@"YTABCTracePhenotype"))
        NSLog(@"[YTABC Phenotype] native config sync, syncer=%@", syncer ? NSStringFromClass([syncer class]) : @"nil");
    if (originalConfigurationSync) originalConfigurationSync(target, selector, syncer, after, callback);
}

// Each selector has a separate, default-off local override. Native results are
// recorded separately from effective results, so diagnostics stay meaningful.
static BOOL (*originalGooglerForAccount)(id,SEL,id);
static BOOL YTABGooglerForAccount(id target, SEL selector, id account) {
    BOOL nativeValue = originalGooglerForAccount ? originalGooglerForAccount(target,selector,account) : NO;
    BOOL forced = YTABNativeTrace(@"YTABCForceIsGooglerAccount");
    if (YTABNativeTrace(@"YTABCTracePhenotype"))
        NSLog(@"[YTABC Phenotype] isGooglerAccount: native=%@ effective=%@",
              nativeValue ? @"YES" : @"NO", (forced || nativeValue) ? @"YES" : @"NO");
    return forced ? YES : nativeValue;
}

static BOOL (*originalGoogler)(id,SEL);
static BOOL YTABGoogler(id target, SEL selector) {
    BOOL nativeValue = originalGoogler ? originalGoogler(target,selector) : NO;
    BOOL forced = YTABNativeTrace(@"YTABCForceHasGooglerAccount");
    @synchronized([NSProcessInfo processInfo]) {
        sawGooglerCheck = YES;
        lastNativeGoogler = nativeValue;
    }
    if (YTABNativeTrace(@"YTABCTracePhenotype"))
        NSLog(@"[YTABC Phenotype] hasGooglerAccount native=%@ effective=%@",
              nativeValue ? @"YES" : @"NO", (forced || nativeValue) ? @"YES" : @"NO");
    return forced ? YES : nativeValue;
}

static BOOL (*originalInternal)(id,SEL);
static BOOL YTABInternal(id target, SEL selector) {
    BOOL nativeValue = originalInternal ? originalInternal(target,selector) : NO;
    BOOL forced = YTABNativeTrace(@"YTABCForceStandardInternalSyncer");
    @synchronized([NSProcessInfo processInfo]) {
        sawInternalCheck = YES;
        lastNativeInternal = nativeValue;
    }
    if (YTABNativeTrace(@"YTABCTracePhenotype"))
        NSLog(@"[YTABC Phenotype] isInternalHeterodyneSyncer native=%@ effective=%@",
              nativeValue ? @"YES" : @"NO", (forced || nativeValue) ? @"YES" : @"NO");
    return forced ? YES : nativeValue;
}

static void (*originalSearch)(id,SEL,id,id,id);
static void YTABSearch(id target, SEL selector, id query, id response, id failure) {
    @synchronized([NSProcessInfo processInfo]) { lastExperimentService = target; searchCalls++; }
    if (YTABNativeTrace(@"YTABCTraceExperimentsSearch"))
        NSLog(@"[YTABC InnerTube] native experiment search observed (request data suppressed)");
    if (originalSearch) originalSearch(target,selector,query,response,failure);
}

static void (*originalOptIn)(id,SEL,id,id,id);
static void YTABOptIn(id target, SEL selector, id params, id response, id failure) {
    @synchronized([NSProcessInfo processInfo]) { lastExperimentService = target; optInCalls++; }
    if (YTABNativeTrace(@"YTABCTraceExperimentsOptIn"))
        NSLog(@"[YTABC InnerTube] native experiment opt-in observed (request data suppressed)");
    if (originalOptIn) originalOptIn(target,selector,params,response,failure);
}

static void (*originalOptOut)(id,SEL,id,id,id);
static void YTABOptOut(id target, SEL selector, id params, id response, id failure) {
    @synchronized([NSProcessInfo processInfo]) { lastExperimentService = target; optOutCalls++; }
    if (YTABNativeTrace(@"YTABCTraceExperimentsOptOut"))
        NSLog(@"[YTABC InnerTube] native experiment opt-out observed (request data suppressed)");
    if (originalOptOut) originalOptOut(target,selector,params,response,failure);
}

static BOOL YTABInstallChecked(Class cls, NSString *name, const char *encoding, IMP replacement, IMP *original) {
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls,selector);
    if (!method || !method_getTypeEncoding(method) || strcmp(method_getTypeEncoding(method),encoding)) {
        NSLog(@"[YTABC Native] selector/ABI unavailable: %@.%@", NSStringFromClass(cls), name);
        return NO;
    }
    @synchronized([NSProcessInfo processInfo]) {
        NSString *key = [NSString stringWithFormat:@"%@#%@",NSStringFromClass(cls),name];
        if ([installedMethods containsObject:key]) return YES;
        MSHookMessageEx(cls,selector,replacement,original);
        [installedMethods addObject:key];
    }
    return YES;
}

void YTABCInstallNativeDiagnostics(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installedMethods = [NSMutableSet set]; });
    Class pht = objc_lookUpClass("PHTHeterodyneSyncer");
    Class flat = objc_lookUpClass("PHTFlatFilePhenotype");
    Class ex = objc_lookUpClass("YTExperimentsServiceImpl");
    YTABInstallChecked(pht, @"syncWithCallback:", "v24@0:8@?16", (IMP)YTABSync, (IMP *)&originalSync);
    YTABInstallChecked(pht, @"isGooglerAccount:", "B24@0:8@16", (IMP)YTABGooglerForAccount, (IMP *)&originalGooglerForAccount);
    YTABInstallChecked(pht, @"hasGooglerAccount", "B16@0:8", (IMP)YTABGoogler, (IMP *)&originalGoogler);
    YTABInstallChecked(pht, @"isInternalHeterodyneSyncer", "B16@0:8", (IMP)YTABInternal, (IMP *)&originalInternal);
    YTABInstallChecked(flat, @"syncExperimentsWithServerInternal:syncAfterConfiguration:callback:",
                       "v40@0:8@16@24@?32", (IMP)YTABConfigurationSync, (IMP *)&originalConfigurationSync);
    YTABInstallChecked(ex, @"makeRequestWithSearchQuery:responseBlock:errorBlock:",
                       "v40@0:8@16@?24@?32", (IMP)YTABSearch, (IMP *)&originalSearch);
    YTABInstallChecked(ex, @"makeOptInRequestWithParams:responseBlock:errorBlock:",
                       "v40@0:8@16@?24@?32", (IMP)YTABOptIn, (IMP *)&originalOptIn);
    YTABInstallChecked(ex, @"makeOptOutRequestWithParams:responseBlock:errorBlock:",
                       "v40@0:8@16@?24@?32", (IMP)YTABOptOut, (IMP *)&originalOptOut);
}

BOOL YTABCRunPhenotypeResync(void) {
    id syncer = nil;
    @synchronized([NSProcessInfo processInfo]) { syncer = lastSyncer; }
    SEL selector = NSSelectorFromString(@"syncWithCallback:");
    Method method = syncer ? class_getInstanceMethod([syncer class], selector) : NULL;
    if (!method || !method_getTypeEncoding(method) ||
        strcmp(method_getTypeEncoding(method),"v24@0:8@?16")) return NO;
    // Issuing a native request does not guarantee server acceptance.
    @try {
        id completion = ^{ NSLog(@"[YTABC Phenotype] manual native resync callback received"); };
        ((void (*)(id,SEL,id))objc_msgSend)(syncer,selector,completion);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[YTABC Phenotype] resync exception: %@", e.reason);
        return NO;
    }
}

BOOL YTABCClearNativeExperimentsCaches(void) {
    id service = nil;
    @synchronized([NSProcessInfo processInfo]) { service = lastExperimentService; }
    SEL selector = NSSelectorFromString(@"clearCaches");
    Method method = service ? class_getInstanceMethod([service class], selector) : NULL;
    if (!method || !method_getTypeEncoding(method) ||
        strcmp(method_getTypeEncoding(method),"v16@0:8")) return NO;
    @try {
        ((void (*)(id,SEL))objc_msgSend)(service,selector);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[YTABC InnerTube] clearCaches exception: %@", e.reason);
        return NO;
    }
}

NSDictionary<NSString *, id> *YTABCCopyNativeDiagnostics(void) {
    @synchronized([NSProcessInfo processInfo]) {
        return @{
            @"nativeSyncerObserved": @(lastSyncer != nil),
            @"nativeExperimentsServiceObserved": @(lastExperimentService != nil),
            @"nativeSyncCalls": @(syncCalls),
            @"phenotypeConfigurationCalls": @(configurationCalls),
            @"nativeSearchCalls": @(searchCalls),
            @"nativeOptInCalls": @(optInCalls),
            @"nativeOptOutCalls": @(optOutCalls),
            @"nativeGooglerCheckObserved": @(sawGooglerCheck),
            @"nativeHasGooglerAccount": sawGooglerCheck ? @(lastNativeGoogler) : [NSNull null],
            @"forceIsGooglerAccount": @(YTABNativeTrace(@"YTABCForceIsGooglerAccount")),
            @"forceHasGooglerAccount": @(YTABNativeTrace(@"YTABCForceHasGooglerAccount")),
            @"nativeInternalCheckObserved": @(sawInternalCheck),
            @"nativeIsInternalSyncer": sawInternalCheck ? @(lastNativeInternal) : [NSNull null],
            @"forceStandardInternalSyncer": @(YTABNativeTrace(@"YTABCForceStandardInternalSyncer")),
            @"installedNativeHooks": @(installedMethods.count)
        };
    }
}
