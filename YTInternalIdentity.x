// YTInternalIdentity.x
//
// Independent Phenotype / Googler / InnerTube experiment tests for the native
// YouTube experiments UI. All Objective-C hooks are installed exactly once;
// each replacement consults its own NSUserDefaults switch at call time.
//
// Binary contract verified against YouTube 21.30.5 arm64:
//   PHTHeterodyneSyncer
//     -isGooglerAccount:                         B24@0:8@16
//     -hasGooglerAccount                         B16@0:8
//     -isInternalHeterodyneSyncer                B16@0:8
//     -createClientProperties                    @16@0:8
//     -experimentsAndConfigsRequestWithApplicationRequests:fetchReason:
//                                                  @28@0:8@16i24
//   PHTFlatFilePhenotype
//     -syncExperimentsWithServerInternal:syncAfterConfiguration:callback:
//                                                  v40@0:8@16@24@?32
//   YTAccountScopedInnerTubeRequestFactoryImpl
//     -requestWithProtoRequest:service:criticality:needsClickTrackingParams:
//      clickTrackingParamsOverride:skipCacheLookup:
//                                                  @52@0:8@16q24i32B36@40B48
//   YTAccountScopedInnerTubeServiceImpl
//     -performHTTPRequest:withIdentity:verifyActiveIdentity:activeIdentityScope:
//      valueHandler:completionHandler:retryEnabled:
//                                                  @64@0:8@16@24B32@36@?44@?52B60
//
// The resync action never invents a server/syncer. It captures the exact
// PHTHeterodyneSyncerProtocol object supplied by YouTube's own native sync and
// reuses that object later through PHTFlatFilePhenotype's public wrapper.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <substrate.h>
#import <string.h>

static NSString * const YTABCForceIsGooglerAccountKey = @"YTABCForceIsGooglerAccount";
static NSString * const YTABCForceHasGooglerAccountKey = @"YTABCForceHasGooglerAccount";
static NSString * const YTABCForceMaybeGooglerClientPropertyKey = @"YTABCForceMaybeGooglerClientProperty";
static NSString * const YTABCForceStandardInternalSyncerKey = @"YTABCForceStandardInternalSyncer";
static NSString * const YTABCTracePhenotypeKey = @"YTABCTracePhenotype";
static NSString * const YTABCAutoPhenotypeResyncKey = @"YTABCAutoPhenotypeResync";
static NSString * const YTABCTraceExperimentsSearchKey = @"YTABCTraceExperimentsSearch";
static NSString * const YTABCTraceExperimentsOptInKey = @"YTABCTraceExperimentsOptIn";
static NSString * const YTABCTraceExperimentsOptOutKey = @"YTABCTraceExperimentsOptOut";
static NSString * const YTABCBypassIdentitySearchKey = @"YTABCBypassIdentitySearch";
static NSString * const YTABCBypassIdentityOptInKey = @"YTABCBypassIdentityOptIn";
static NSString * const YTABCBypassIdentityOptOutKey = @"YTABCBypassIdentityOptOut";

static const NSInteger YTABCExperimentsOptInService = 49;
static const NSInteger YTABCExperimentsOptOutService = 50;
static const NSInteger YTABCExperimentsSearchService = 51;

static pthread_mutex_t YTABCInstallMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t YTABCStateMutex = PTHREAD_MUTEX_INITIALIZER;
static id YTABCLastPhenotypeSyncer = nil;
static id YTABCLastExperimentsService = nil;
static BOOL YTABCAutoResyncScheduled = NO;
static char YTABCInnerTubeServiceAssociationKey;

static BOOL YTABCTestEnabled(NSString *key) {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    return [userDefaults boolForKey:@"EnabledYTABC"] && [userDefaults boolForKey:key];
}

static BOOL YTABCEncodingMatches(Class cls, SEL selector, const char *expected) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && expected && strcmp(actual, expected) == 0;
}

static void YTABCHookExact(Class cls, const char *selectorName, const char *encoding,
                           IMP replacement, IMP *original) {
    if (!cls || !selectorName || !encoding || !replacement || !original || *original) return;
    SEL selector = sel_registerName(selectorName);
    if (!YTABCEncodingMatches(cls, selector, encoding)) {
        NSLog(@"[YTABConfig EmployeeTest] ABI mismatch %@ %s (expected %s)",
              NSStringFromClass(cls), selectorName, encoding);
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

static BOOL YTABCServiceMatchesTrace(NSInteger service) {
    switch (service) {
        case YTABCExperimentsOptInService:
            return YTABCTestEnabled(YTABCTraceExperimentsOptInKey);
        case YTABCExperimentsOptOutService:
            return YTABCTestEnabled(YTABCTraceExperimentsOptOutKey);
        case YTABCExperimentsSearchService:
            return YTABCTestEnabled(YTABCTraceExperimentsSearchKey);
        default:
            return NO;
    }
}

static BOOL YTABCServiceMatchesIdentityBypass(NSInteger service) {
    switch (service) {
        case YTABCExperimentsOptInService:
            return YTABCTestEnabled(YTABCBypassIdentityOptInKey);
        case YTABCExperimentsOptOutService:
            return YTABCTestEnabled(YTABCBypassIdentityOptOutKey);
        case YTABCExperimentsSearchService:
            return YTABCTestEnabled(YTABCBypassIdentitySearchKey);
        default:
            return NO;
    }
}

static NSInteger YTABCServiceForRequest(id request) {
    NSNumber *number = request ? objc_getAssociatedObject(request, &YTABCInnerTubeServiceAssociationKey) : nil;
    return number ? number.integerValue : NSNotFound;
}

static void YTABCCapturePhenotypeSyncer(id syncer) {
    if (!syncer) return;
    pthread_mutex_lock(&YTABCStateMutex);
    YTABCLastPhenotypeSyncer = syncer;
    pthread_mutex_unlock(&YTABCStateMutex);
}

static void YTABCCaptureExperimentsService(id service) {
    if (!service) return;
    pthread_mutex_lock(&YTABCStateMutex);
    YTABCLastExperimentsService = service;
    pthread_mutex_unlock(&YTABCStateMutex);
}

BOOL YTABCRunPhenotypeResync(void) {
    pthread_mutex_lock(&YTABCStateMutex);
    id syncer = YTABCLastPhenotypeSyncer;
    pthread_mutex_unlock(&YTABCStateMutex);

    Class phenotypeClass = objc_lookUpClass("PHTFlatFilePhenotype");
    SEL sharedSelector = sel_registerName("sharedInstance");
    SEL syncSelector = sel_registerName("syncExperimentsWithServer:callback:");
    if (!syncer || !phenotypeClass || ![phenotypeClass respondsToSelector:sharedSelector]) {
        NSLog(@"[YTABConfig EmployeeTest] Phenotype resync unavailable: native syncer not captured yet");
        return NO;
    }

    id phenotype = ((id (*)(id, SEL))objc_msgSend)(phenotypeClass, sharedSelector);
    if (!phenotype || ![phenotype respondsToSelector:syncSelector]) return NO;

    void (^completion)(void) = ^{
        NSLog(@"[YTABConfig EmployeeTest] Phenotype resync callback fired");
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(phenotype, syncSelector, syncer, completion);
    NSLog(@"[YTABConfig EmployeeTest] Phenotype resync queued with captured %@",
          NSStringFromClass([syncer class]));
    return YES;
}

BOOL YTABCClearNativeExperimentsCaches(void) {
    pthread_mutex_lock(&YTABCStateMutex);
    id service = YTABCLastExperimentsService;
    pthread_mutex_unlock(&YTABCStateMutex);

    SEL selector = sel_registerName("clearCaches");
    if (!service || ![service respondsToSelector:selector]) {
        NSLog(@"[YTABConfig EmployeeTest] Experiments cache clear unavailable: service not observed yet");
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(service, selector);
    NSLog(@"[YTABConfig EmployeeTest] Native experiments caches cleared");
    return YES;
}

static void YTABCScheduleAutoResyncIfNeeded(void) {
    if (!YTABCTestEnabled(YTABCAutoPhenotypeResyncKey)) return;

    pthread_mutex_lock(&YTABCStateMutex);
    if (YTABCAutoResyncScheduled) {
        pthread_mutex_unlock(&YTABCStateMutex);
        return;
    }
    YTABCAutoResyncScheduled = YES;
    pthread_mutex_unlock(&YTABCStateMutex);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!YTABCRunPhenotypeResync()) {
            pthread_mutex_lock(&YTABCStateMutex);
            YTABCAutoResyncScheduled = NO;
            pthread_mutex_unlock(&YTABCStateMutex);
        }
    });
}

// -------------------------------------------------------------------------
// Phenotype / Googler hooks
// -------------------------------------------------------------------------

typedef BOOL (*YTABCBoolObjectFn)(id, SEL, id);
typedef BOOL (*YTABCBoolVoidFn)(id, SEL);
typedef id (*YTABCObjectVoidFn)(id, SEL);
typedef id (*YTABCObjectObjectIntFn)(id, SEL, id, int);
typedef void (*YTABCSyncInternalFn)(id, SEL, id, id, id);

static YTABCBoolObjectFn YTABCOrigIsGooglerAccount = NULL;
static YTABCBoolVoidFn YTABCOrigHasGooglerAccount = NULL;
static YTABCBoolVoidFn YTABCOrigIsInternalSyncer = NULL;
static YTABCObjectVoidFn YTABCOrigCreateClientProperties = NULL;
static YTABCObjectObjectIntFn YTABCOrigExperimentsAndConfigsRequest = NULL;
static YTABCSyncInternalFn YTABCOrigSyncExperimentsInternal = NULL;

static BOOL YTABCHookIsGooglerAccount(id self, SEL selector, id account) {
    if (YTABCTestEnabled(YTABCForceIsGooglerAccountKey)) return YES;
    return YTABCOrigIsGooglerAccount ? YTABCOrigIsGooglerAccount(self, selector, account) : NO;
}

static BOOL YTABCHookHasGooglerAccount(id self, SEL selector) {
    if (YTABCTestEnabled(YTABCForceHasGooglerAccountKey)) return YES;
    return YTABCOrigHasGooglerAccount ? YTABCOrigHasGooglerAccount(self, selector) : NO;
}

static BOOL YTABCHookIsInternalSyncer(id self, SEL selector) {
    if (YTABCTestEnabled(YTABCForceStandardInternalSyncerKey)) return YES;
    return YTABCOrigIsInternalSyncer ? YTABCOrigIsInternalSyncer(self, selector) : NO;
}

static id YTABCHookCreateClientProperties(id self, SEL selector) {
    id properties = YTABCOrigCreateClientProperties ?
        YTABCOrigCreateClientProperties(self, selector) : nil;

    if (properties && YTABCTestEnabled(YTABCForceMaybeGooglerClientPropertyKey)) {
        SEL setter = sel_registerName("setIsMaybeGooglerGmscore:");
        if ([properties respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(properties, setter, YES);
        }
    }

    if (YTABCTestEnabled(YTABCTracePhenotypeKey)) {
        BOOL maybeGoogler = NO;
        BOOL hasDogfoodToken = NO;
        SEL getter = sel_registerName("isMaybeGooglerGmscore");
        SEL tokenSelector = sel_registerName("hasDogfoodToken");
        if ([properties respondsToSelector:getter]) {
            maybeGoogler = ((BOOL (*)(id, SEL))objc_msgSend)(properties, getter);
        }
        if ([properties respondsToSelector:tokenSelector]) {
            hasDogfoodToken = ((BOOL (*)(id, SEL))objc_msgSend)(properties, tokenSelector);
        }
        NSLog(@"[YTABConfig EmployeeTest] Phenotype client properties: maybeGoogler=%d dogfoodToken=%d",
              maybeGoogler, hasDogfoodToken);
    }
    return properties;
}

static id YTABCHookExperimentsAndConfigsRequest(id self, SEL selector,
                                                id applicationRequests, int fetchReason) {
    id request = YTABCOrigExperimentsAndConfigsRequest ?
        YTABCOrigExperimentsAndConfigsRequest(self, selector, applicationRequests, fetchReason) : nil;
    if (YTABCTestEnabled(YTABCTracePhenotypeKey)) {
        NSLog(@"[YTABConfig EmployeeTest] Phenotype request: fetchReason=%d applications=%lu request=%@",
              fetchReason, (unsigned long)[applicationRequests count], NSStringFromClass([request class]));
    }
    return request;
}

static void YTABCHookSyncExperimentsInternal(id self, SEL selector, id syncer,
                                             id syncAfterConfiguration, id callback) {
    YTABCCapturePhenotypeSyncer(syncer);
    if (YTABCTestEnabled(YTABCTracePhenotypeKey)) {
        NSLog(@"[YTABConfig EmployeeTest] Native Phenotype sync: syncer=%@ afterConfig=%@",
              NSStringFromClass([syncer class]), syncAfterConfiguration);
    }
    if (YTABCOrigSyncExperimentsInternal) {
        YTABCOrigSyncExperimentsInternal(self, selector, syncer, syncAfterConfiguration, callback);
    }
    YTABCScheduleAutoResyncIfNeeded();
}

// -------------------------------------------------------------------------
// Native experiments / InnerTube hooks
// -------------------------------------------------------------------------

typedef id (*YTABCRequestFactoryFn)(id, SEL, id, long long, int, BOOL, id, BOOL);
typedef id (*YTABCPerformHTTPFn)(id, SEL, id, id, BOOL, id, id, id, BOOL);
typedef void (*YTABCProcessErrorFn)(id, SEL, id, id, id);
typedef void (*YTABCProcessProtoFn)(id, SEL, id, id, BOOL, id, unsigned long long, id);
typedef void (*YTABCExperimentsOperationFn)(id, SEL, id, id, id);

static YTABCRequestFactoryFn YTABCOrigRequestFactory = NULL;
static YTABCPerformHTTPFn YTABCOrigPerformHTTP = NULL;
static YTABCProcessErrorFn YTABCOrigProcessError = NULL;
static YTABCProcessProtoFn YTABCOrigProcessProto = NULL;
static YTABCExperimentsOperationFn YTABCOrigSearch = NULL;
static YTABCExperimentsOperationFn YTABCOrigOptIn = NULL;
static YTABCExperimentsOperationFn YTABCOrigOptOut = NULL;

static id YTABCHookRequestFactory(id self, SEL selector, id protoRequest,
                                  long long service, int criticality,
                                  BOOL needsClickTrackingParams,
                                  id clickTrackingParamsOverride,
                                  BOOL skipCacheLookup) {
    id request = YTABCOrigRequestFactory ?
        YTABCOrigRequestFactory(self, selector, protoRequest, service, criticality,
                                needsClickTrackingParams, clickTrackingParamsOverride,
                                skipCacheLookup) : nil;
    if (request && (service == YTABCExperimentsOptInService ||
                    service == YTABCExperimentsOptOutService ||
                    service == YTABCExperimentsSearchService)) {
        objc_setAssociatedObject(request, &YTABCInnerTubeServiceAssociationKey,
                                 @(service), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (YTABCServiceMatchesTrace((NSInteger)service)) {
            NSLog(@"[YTABConfig EmployeeTest] InnerTube request created: service=%lld proto=%@ request=%@ skipCache=%d",
                  service, NSStringFromClass([protoRequest class]),
                  NSStringFromClass([request class]), skipCacheLookup);
        }
    }
    return request;
}

static id YTABCHookPerformHTTP(id self, SEL selector, id request, id identity,
                               BOOL verifyActiveIdentity, id activeIdentityScope,
                               id valueHandler, id completionHandler, BOOL retryEnabled) {
    NSInteger service = YTABCServiceForRequest(request);
    BOOL effectiveVerify = verifyActiveIdentity;
    if (service != NSNotFound && YTABCServiceMatchesIdentityBypass(service)) {
        effectiveVerify = NO;
    }
    if (service != NSNotFound && YTABCServiceMatchesTrace(service)) {
        NSLog(@"[YTABConfig EmployeeTest] InnerTube send: service=%ld identity=%@ verify=%d->%d scope=%@ retry=%d",
              (long)service, NSStringFromClass([identity class]), verifyActiveIdentity,
              effectiveVerify, activeIdentityScope, retryEnabled);
    }
    return YTABCOrigPerformHTTP ?
        YTABCOrigPerformHTTP(self, selector, request, identity, effectiveVerify,
                             activeIdentityScope, valueHandler, completionHandler,
                             retryEnabled) : nil;
}

static void YTABCHookProcessError(id self, SEL selector, id requestState,
                                  NSError *error, id request) {
    NSInteger service = YTABCServiceForRequest(request);
    if (service != NSNotFound && YTABCServiceMatchesTrace(service)) {
        NSNumber *status = error.userInfo[@"HTTPStatusCode"] ?: error.userInfo[@"statusCode"];
        NSLog(@"[YTABConfig EmployeeTest] InnerTube error: service=%ld domain=%@ code=%ld HTTP=%@ info=%@",
              (long)service, error.domain, (long)error.code, status, error.userInfo);
    }
    if (YTABCOrigProcessError) YTABCOrigProcessError(self, selector, requestState, error, request);
}

static void YTABCHookProcessProto(id self, SEL selector, id request, id requestState,
                                  BOOL checkResponseForCachability, id response,
                                  unsigned long long responseSize, id responseStatistics) {
    NSInteger service = YTABCServiceForRequest(request);
    if (service != NSNotFound && YTABCServiceMatchesTrace(service)) {
        NSLog(@"[YTABConfig EmployeeTest] InnerTube response: service=%ld response=%@ bytes=%llu",
              (long)service, NSStringFromClass([response class]), responseSize);
    }
    if (YTABCOrigProcessProto) {
        YTABCOrigProcessProto(self, selector, request, requestState,
                              checkResponseForCachability, response,
                              responseSize, responseStatistics);
    }
}

static void YTABCHookSearch(id self, SEL selector, id query, id responseBlock, id errorBlock) {
    YTABCCaptureExperimentsService(self);
    if (YTABCTestEnabled(YTABCTraceExperimentsSearchKey)) {
        NSLog(@"[YTABConfig EmployeeTest] Experiments search start: query=%@", query);
    }
    if (YTABCOrigSearch) YTABCOrigSearch(self, selector, query, responseBlock, errorBlock);
}

static void YTABCHookOptIn(id self, SEL selector, id params, id responseBlock, id errorBlock) {
    YTABCCaptureExperimentsService(self);
    if (YTABCTestEnabled(YTABCTraceExperimentsOptInKey)) {
        NSLog(@"[YTABConfig EmployeeTest] Experiments opt-in start: params=%@", params);
    }
    if (YTABCOrigOptIn) YTABCOrigOptIn(self, selector, params, responseBlock, errorBlock);
}

static void YTABCHookOptOut(id self, SEL selector, id params, id responseBlock, id errorBlock) {
    YTABCCaptureExperimentsService(self);
    if (YTABCTestEnabled(YTABCTraceExperimentsOptOutKey)) {
        NSLog(@"[YTABConfig EmployeeTest] Experiments opt-out start: params=%@", params);
    }
    if (YTABCOrigOptOut) YTABCOrigOptOut(self, selector, params, responseBlock, errorBlock);
}

void YTABCInstallEmployeeExperimentHooks(void) {
    pthread_mutex_lock(&YTABCInstallMutex);

    Class heterodyne = objc_lookUpClass("PHTHeterodyneSyncer");
    YTABCHookExact(heterodyne, "isGooglerAccount:", "B24@0:8@16",
                   (IMP)YTABCHookIsGooglerAccount, (IMP *)&YTABCOrigIsGooglerAccount);
    YTABCHookExact(heterodyne, "hasGooglerAccount", "B16@0:8",
                   (IMP)YTABCHookHasGooglerAccount, (IMP *)&YTABCOrigHasGooglerAccount);
    YTABCHookExact(heterodyne, "isInternalHeterodyneSyncer", "B16@0:8",
                   (IMP)YTABCHookIsInternalSyncer, (IMP *)&YTABCOrigIsInternalSyncer);
    YTABCHookExact(heterodyne, "createClientProperties", "@16@0:8",
                   (IMP)YTABCHookCreateClientProperties, (IMP *)&YTABCOrigCreateClientProperties);
    YTABCHookExact(heterodyne,
                   "experimentsAndConfigsRequestWithApplicationRequests:fetchReason:",
                   "@28@0:8@16i24", (IMP)YTABCHookExperimentsAndConfigsRequest,
                   (IMP *)&YTABCOrigExperimentsAndConfigsRequest);

    Class flatFile = objc_lookUpClass("PHTFlatFilePhenotype");
    YTABCHookExact(flatFile,
                   "syncExperimentsWithServerInternal:syncAfterConfiguration:callback:",
                   "v40@0:8@16@24@?32", (IMP)YTABCHookSyncExperimentsInternal,
                   (IMP *)&YTABCOrigSyncExperimentsInternal);

    Class requestFactory = objc_lookUpClass("YTAccountScopedInnerTubeRequestFactoryImpl");
    YTABCHookExact(requestFactory,
                   "requestWithProtoRequest:service:criticality:needsClickTrackingParams:clickTrackingParamsOverride:skipCacheLookup:",
                   "@52@0:8@16q24i32B36@40B48", (IMP)YTABCHookRequestFactory,
                   (IMP *)&YTABCOrigRequestFactory);

    Class innerTubeService = objc_lookUpClass("YTAccountScopedInnerTubeServiceImpl");
    YTABCHookExact(innerTubeService,
                   "performHTTPRequest:withIdentity:verifyActiveIdentity:activeIdentityScope:valueHandler:completionHandler:retryEnabled:",
                   "@64@0:8@16@24B32@36@?44@?52B60", (IMP)YTABCHookPerformHTTP,
                   (IMP *)&YTABCOrigPerformHTTP);
    YTABCHookExact(innerTubeService, "processErrorResponseWithRequestState:error:request:",
                   "v40@0:8@16@24@32", (IMP)YTABCHookProcessError,
                   (IMP *)&YTABCOrigProcessError);
    YTABCHookExact(innerTubeService,
                   "processProtoResponseWithRequest:requestState:checkResponseForCachability:response:responseSize:responseStatistics:",
                   "v60@0:8@16@24B32@36Q44@52", (IMP)YTABCHookProcessProto,
                   (IMP *)&YTABCOrigProcessProto);

    Class experimentsService = objc_lookUpClass("YTExperimentsServiceImpl");
    YTABCHookExact(experimentsService, "makeRequestWithSearchQuery:responseBlock:errorBlock:",
                   "v40@0:8@16@?24@?32", (IMP)YTABCHookSearch,
                   (IMP *)&YTABCOrigSearch);
    YTABCHookExact(experimentsService, "makeOptInRequestWithParams:responseBlock:errorBlock:",
                   "v40@0:8@16@?24@?32", (IMP)YTABCHookOptIn,
                   (IMP *)&YTABCOrigOptIn);
    YTABCHookExact(experimentsService, "makeOptOutRequestWithParams:responseBlock:errorBlock:",
                   "v40@0:8@16@?24@?32", (IMP)YTABCHookOptOut,
                   (IMP *)&YTABCOrigOptOut);

    pthread_mutex_unlock(&YTABCInstallMutex);
}
