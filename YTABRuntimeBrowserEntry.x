#import "YTABRuntimeBrowserModern.h"
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <objc/runtime.h>
#import <substrate.h>

static const NSInteger YTABCFeatureLabCategory = 404;
static __weak YTSettingsViewController *sYTABRuntimeBrowserSettingsViewController;
static Class sYTABRuntimeBrowserHookedDelegateClass;
static IMP sYTABSetItemsWithIconOriginal;
static IMP sYTABSetItemsOriginal;

static NSString *YTABAccessibilityIdentifier(id item) {
    if (!item) return nil;
    @try {
        id value = [item valueForKey:@"accessibilityIdentifier"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSMutableArray<YTSettingsSectionItem *> *YTABItemsByAddingRuntimeBrowser(NSArray *items) {
    NSMutableArray<YTSettingsSectionItem *> *updated =
        [items isKindOfClass:NSArray.class] ? [items mutableCopy] : [NSMutableArray array];

    NSUInteger featureLabIndex = NSNotFound;
    for (NSUInteger index = 0; index < updated.count; index++) {
        NSString *identifier = YTABAccessibilityIdentifier(updated[index]);
        if ([identifier isEqualToString:@"YTABC_RUNTIME_PATCH_BROWSER"]) return updated;
        if ([identifier isEqualToString:@"YTABC_FEATURE_LAB"]) featureLabIndex = index;
    }

    YTSettingsSectionItem *open = [%c(YTSettingsSectionItem)
        itemWithTitle:@"Open Runtime Patch Browser"
        titleDescription:[NSString stringWithFormat:
            @"Readable live BOOL patches · %lu saved",
            (unsigned long)YTABRuntimeBrowserPersistedOverrideCount()]
        accessibilityIdentifier:@"YTABC_RUNTIME_PATCH_BROWSER"
        detailTextBlock:nil
        selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger argument) {
            (void)cell;
            (void)argument;
            YTSettingsViewController *settingsViewController =
                sYTABRuntimeBrowserSettingsViewController;
            if (!settingsViewController) {
                NSLog(@"[YTABConfig RuntimeBrowser] settings controller unavailable");
                return NO;
            }
            YTABRuntimeBrowserModernViewController *browser =
                [YTABRuntimeBrowserModernViewController new];
            [settingsViewController pushViewController:browser];
            return YES;
        }];

    NSUInteger insertion = featureLabIndex == NSNotFound
        ? 0
        : MIN(featureLabIndex + 1, updated.count);
    [updated insertObject:open atIndex:insertion];
    return updated;
}

static void YTABSetItemsWithIcon(id receiver, SEL selector,
                                 NSMutableArray<YTSettingsSectionItem *> *items,
                                 NSInteger category, NSString *title, id icon,
                                 NSString *titleDescription, BOOL headerHidden) {
    NSMutableArray<YTSettingsSectionItem *> *effectiveItems = items;
    if (category == YTABCFeatureLabCategory) {
        effectiveItems = YTABItemsByAddingRuntimeBrowser(items);
    }
    ((void (*)(id, SEL, NSMutableArray *, NSInteger, NSString *, id, NSString *, BOOL))
        sYTABSetItemsWithIconOriginal)(receiver, selector, effectiveItems, category,
                                      title, icon, titleDescription, headerHidden);
}

static void YTABSetItems(id receiver, SEL selector,
                         NSMutableArray<YTSettingsSectionItem *> *items,
                         NSInteger category, NSString *title,
                         NSString *titleDescription, BOOL headerHidden) {
    NSMutableArray<YTSettingsSectionItem *> *effectiveItems = items;
    if (category == YTABCFeatureLabCategory) {
        effectiveItems = YTABItemsByAddingRuntimeBrowser(items);
    }
    ((void (*)(id, SEL, NSMutableArray *, NSInteger, NSString *, NSString *, BOOL))
        sYTABSetItemsOriginal)(receiver, selector, effectiveItems, category,
                              title, titleDescription, headerHidden);
}

static void YTABInstallFeatureLabDelegateHookIfNeeded(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    @synchronized([YTABRuntimeBrowserViewController class]) {
        if (sYTABRuntimeBrowserHookedDelegateClass == cls) return;
        if (sYTABRuntimeBrowserHookedDelegateClass) return;

        SEL withIcon = NSSelectorFromString(
            @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        Method withIconMethod = class_getInstanceMethod(cls, withIcon);
        if (withIconMethod && method_getNumberOfArguments(withIconMethod) == 8) {
            MSHookMessageEx(cls, withIcon, (IMP)YTABSetItemsWithIcon,
                            &sYTABSetItemsWithIconOriginal);
            sYTABRuntimeBrowserHookedDelegateClass = cls;
            return;
        }

        SEL withoutIcon = NSSelectorFromString(
            @"setSectionItems:forCategory:title:titleDescription:headerHidden:");
        Method withoutIconMethod = class_getInstanceMethod(cls, withoutIcon);
        if (withoutIconMethod && method_getNumberOfArguments(withoutIconMethod) == 7) {
            MSHookMessageEx(cls, withoutIcon, (IMP)YTABSetItems,
                            &sYTABSetItemsOriginal);
            sYTABRuntimeBrowserHookedDelegateClass = cls;
            return;
        }

        NSLog(@"[YTABConfig RuntimeBrowser] Feature Lab data delegate ABI unavailable");
    }
}

%hook YTSettingsSectionItemManager

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == YTABCFeatureLabCategory) {
        id dataDelegate = nil;
        @try {
            dataDelegate = [self valueForKey:@"_dataDelegate"];
            sYTABRuntimeBrowserSettingsViewController =
                [self valueForKey:@"_settingsViewControllerDelegate"];
        } @catch (NSException *exception) {
            NSLog(@"[YTABConfig RuntimeBrowser] Feature Lab KVC drift: %@",
                  exception.reason);
        }
        YTABInstallFeatureLabDelegateHookIfNeeded(dataDelegate);
    }
    %orig(category, entry);
}

%end
