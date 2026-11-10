// Audited in the original YouTube 21.43.5 ARM64 Mach-O.
// Layout XREFs:
// YTSettingsExperimentStudyHeader -resetLayout (0x10143197c) loads
//    settings_experiments_study_header.flexb (CFString 0x10bb485c0).
// YTSettingsExperimentStudyItemCell -resetLayout (0x10143243c) loads
//    settings_experiments_study_item_cell.flexb (CFString 0x10bb485e0),
//    choosing "shortCell" (0x10bb48600) vs "regularCell" (0x10bb48620).
// The native study controller owns didToggleSwitch and join-confirmation.
// All hooks call their original. No synthetic eligibility or opt-in.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <string.h>

static NSUInteger sHeaderLayoutCount;
static NSUInteger sCellLayoutCount;
static NSUInteger sEntryBindCount;
static NSUInteger sSectionEntryUpdates;
static NSUInteger sHeaderUpdates;
static NSUInteger sNativeToggleCalls;
static NSUInteger sJoinConfirmations;
static NSUInteger sLastSectionEntryCount;
static BOOL sLatestBadgePresent;
static BOOL sLatestBadgeVisible;
static BOOL sLatestOptInControlPresent;
static BOOL sLatestOptInControlVisible;
static BOOL sLatestOptInControlEnabled;
static BOOL sLatestOptInControlOn;
static NSString *sLatestEntryClass;
static NSMutableSet<NSString *> *sInstalledStudyHooks;

static id YTABCStudyProperty(id obj, SEL selector) {
    if (!obj || ![obj respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, selector);
}

static void (*sOriginalHeaderLayout)(id, SEL);
static void YTABCStudyHeaderLayout(id instance, SEL selector) {
    if (sOriginalHeaderLayout) sOriginalHeaderLayout(instance, selector);
    @synchronized([NSProcessInfo processInfo]) { sHeaderLayoutCount++; }
}

static void (*sOriginalCellLayout)(id, SEL);
static void YTABCStudyCellLayout(id instance, SEL selector) {
    if (sOriginalCellLayout) sOriginalCellLayout(instance, selector);
    @synchronized([NSProcessInfo processInfo]) { sCellLayoutCount++; }
}

static void (*sOriginalSetEntry)(id, SEL, id);
static void YTABCStudySetEntry(id instance, SEL selector, id entry) {
    if (sOriginalSetEntry) sOriginalSetEntry(instance, selector, entry);
    id badge = YTABCStudyProperty(instance, @selector(studyIneligibleBadge));
    id optIn = YTABCStudyProperty(instance, @selector(optInButton));
    BOOL badgePresent = [badge isKindOfClass:[UIView class]];
    BOOL optInPresent = [optIn isKindOfClass:[UIView class]];
    BOOL badgeVisible = badgePresent && ![(UIView *)badge isHidden];
    BOOL optInVisible = optInPresent && ![(UIView *)optIn isHidden];
    BOOL optInEnabled = optInPresent && [optIn isKindOfClass:[UIControl class]]
        ? [(UIControl *)optIn isEnabled] : NO;
    BOOL optInOn = optIn && [optIn respondsToSelector:@selector(isOn)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(optIn, @selector(isOn)) : NO;
    @synchronized([NSProcessInfo processInfo]) {
        sEntryBindCount++;
        sLatestBadgePresent = badgePresent;
        sLatestBadgeVisible = badgeVisible;
        sLatestOptInControlPresent = optInPresent;
        sLatestOptInControlVisible = optInVisible;
        sLatestOptInControlEnabled = optInEnabled;
        sLatestOptInControlOn = optInOn;
        sLatestEntryClass = entry ? NSStringFromClass([entry class]) : @"nil";
    }
}

static void (*sOriginalHandleEntries)(id, SEL, id);
static void YTABCStudyHandleEntries(id instance, SEL selector, id entries) {
    @synchronized([NSProcessInfo processInfo]) {
        sSectionEntryUpdates++;
        sLastSectionEntryCount = [entries isKindOfClass:[NSArray class]]
            ? [(NSArray *)entries count] : 0;
    }
    if (sOriginalHandleEntries) sOriginalHandleEntries(instance, selector, entries);
}

static void (*sOriginalUpdateHeader)(id, SEL, id);
static void YTABCStudyUpdateHeader(id instance, SEL selector, id header) {
    if (sOriginalUpdateHeader) sOriginalUpdateHeader(instance, selector, header);
    @synchronized([NSProcessInfo processInfo]) { sHeaderUpdates++; }
}

static void (*sOriginalDidToggle)(id, SEL);
static void YTABCStudyDidToggle(id instance, SEL selector) {
    @synchronized([NSProcessInfo processInfo]) { sNativeToggleCalls++; }
    if (sOriginalDidToggle) sOriginalDidToggle(instance, selector);
}

static void (*sOriginalJoinAlert)(id, SEL);
static void YTABCStudyJoinAlert(id instance, SEL selector) {
    @synchronized([NSProcessInfo processInfo]) { sJoinConfirmations++; }
    if (sOriginalJoinAlert) sOriginalJoinAlert(instance, selector);
}

static BOOL YTABCStudyHook(const char *clsName, const char *selName, const char *encoding,
                          IMP replacement, IMP *original) {
    Class cls = objc_lookUpClass(clsName);
    if (!cls) return NO;
    SEL selector = sel_registerName(selName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !method_getTypeEncoding(method) ||
        strcmp(method_getTypeEncoding(method), encoding) != 0) {
        NSLog(@"[YTABC Studies] method ABI mismatch: %s %s", clsName, selName);
        return NO;
    }
    NSString *key = [NSString stringWithFormat:@"%s#%s", clsName, selName];
    @synchronized([NSProcessInfo processInfo]) {
        if ([sInstalledStudyHooks containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, replacement, original);
        if (!*original) return NO;
        [sInstalledStudyHooks addObject:key];
        return YES;
    }
}

void YTABCInstallNativeStudyControlsHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sInstalledStudyHooks = [NSMutableSet set]; });
    YTABCStudyHook("YTSettingsExperimentStudyHeader", "resetLayout", "v16@0:8",
                  (IMP)YTABCStudyHeaderLayout, (IMP *)&sOriginalHeaderLayout);
    YTABCStudyHook("YTSettingsExperimentStudyItemCell", "resetLayout", "v16@0:8",
                  (IMP)YTABCStudyCellLayout, (IMP *)&sOriginalCellLayout);
    YTABCStudyHook("YTSettingsExperimentStudyItemCell", "setEntry:", "v24@0:8@16",
                  (IMP)YTABCStudySetEntry, (IMP *)&sOriginalSetEntry);
    YTABCStudyHook("YTSettingsExperimentStudySectionController", "handleEntries:", "v24@0:8@16",
                  (IMP)YTABCStudyHandleEntries, (IMP *)&sOriginalHandleEntries);
    YTABCStudyHook("YTSettingsExperimentStudySectionController", "updateHeader:", "v24@0:8@16",
                  (IMP)YTABCStudyUpdateHeader, (IMP *)&sOriginalUpdateHeader);
    YTABCStudyHook("YTSettingsExperimentStudyItemCellController", "didToggleSwitch", "v16@0:8",
                  (IMP)YTABCStudyDidToggle, (IMP *)&sOriginalDidToggle);
    YTABCStudyHook("YTSettingsExperimentStudyItemCellController", "showAlertForJoiningExperiment", "v16@0:8",
                  (IMP)YTABCStudyJoinAlert, (IMP *)&sOriginalJoinAlert);
}

NSDictionary<NSString *, id> *YTABCCopyNativeStudyControls(void) {
    @synchronized([NSProcessInfo processInfo]) {
        return @{
            @"studyHeaderLayoutCalls": @(sHeaderLayoutCount),
            @"studyCellLayoutCalls": @(sCellLayoutCount),
            @"studyCellEntryBindings": @(sEntryBindCount),
            @"studySectionEntryUpdates": @(sSectionEntryUpdates),
            @"lastStudySectionEntryCount": @(sLastSectionEntryCount),
            @"studyHeaderUpdates": @(sHeaderUpdates),
            @"nativeOptInSwitchCallbacks": @(sNativeToggleCalls),
            @"nativeJoinAlertCallbacks": @(sJoinConfirmations),
            @"lastEntryClass": sLatestEntryClass ?: @"not observed",
            @"badgeViewPresent": @(sLatestBadgePresent),
            @"badgeViewVisible": @(sLatestBadgeVisible),
            @"optInViewPresent": @(sLatestOptInControlPresent),
            @"optInViewVisible": @(sLatestOptInControlVisible),
            @"optInViewEnabled": @(sLatestOptInControlEnabled),
            @"optInSwitchOn": @(sLatestOptInControlOn),
            @"installedStudyHooks": @(sInstalledStudyHooks.count)
        };
    }
}
