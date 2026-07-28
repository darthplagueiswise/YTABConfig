#import "YTABRuntimeBrowser.h"
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>

static const NSInteger YTABRuntimeBrowserCategory = 405;

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
    NSArray<NSNumber *> *categories = %orig;
    if (self.type != 1 || [categories containsObject:@(YTABRuntimeBrowserCategory)]) {
        return categories;
    }
    NSMutableArray<NSNumber *> *updated = categories.mutableCopy;
    NSUInteger featureLabIndex = [updated indexOfObject:@(404)];
    NSUInteger insertion = featureLabIndex == NSNotFound ? 0 : featureLabIndex + 1;
    [updated insertObject:@(YTABRuntimeBrowserCategory) atIndex:MIN(insertion, updated.count)];
    return updated.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray<NSNumber *> *categories = %orig;
    if ([categories containsObject:@(YTABRuntimeBrowserCategory)]) return categories;
    NSMutableArray<NSNumber *> *updated = categories.mutableCopy;
    NSUInteger featureLabIndex = [updated indexOfObject:@(404)];
    NSUInteger insertion = featureLabIndex == NSNotFound ? 0 : featureLabIndex + 1;
    [updated insertObject:@(YTABRuntimeBrowserCategory) atIndex:MIN(insertion, updated.count)];
    return updated.copy;
}

%end

%hook YTSettingsSectionItemManager

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category != YTABRuntimeBrowserCategory) {
        %orig;
        return;
    }
    (void)entry;

    YTSettingsViewController *settingsViewController = nil;
    id dataDelegate = nil;
    @try {
        settingsViewController = [self valueForKey:@"_settingsViewControllerDelegate"];
        dataDelegate = [self valueForKey:@"_dataDelegate"];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig RuntimeBrowser] settings KVC drift: %@", exception.reason);
    }
    if (!settingsViewController || !dataDelegate) return;

    YTSettingsSectionItem *open = [%c(YTSettingsSectionItem)
        itemWithTitle:@"Open Runtime Patch Browser"
        titleDescription:[NSString stringWithFormat:
            @"Patch BOOL methods from YouTube and Module_Framework · %lu saved",
            (unsigned long)YTABRuntimeBrowserPersistedOverrideCount()]
        accessibilityIdentifier:@"YTABC_RUNTIME_PATCH_BROWSER"
        detailTextBlock:nil
        selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger argument) {
            (void)cell;
            (void)argument;
            YTABRuntimeBrowserViewController *browser = [YTABRuntimeBrowserViewController new];
            [settingsViewController pushViewController:browser];
            return YES;
        }];

    NSMutableArray<YTSettingsSectionItem *> *items = [NSMutableArray arrayWithObject:open];
    NSString *title = @"Runtime Patches";
    if ([dataDelegate respondsToSelector:
         @selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
        [dataDelegate setSectionItems:items
                         forCategory:YTABRuntimeBrowserCategory
                               title:title
                    titleDescription:@"On-demand Objective-C runtime browser"
                        headerHidden:NO];
    } else {
        NSLog(@"[YTABConfig RuntimeBrowser] data delegate selector unavailable");
    }
}

%end
