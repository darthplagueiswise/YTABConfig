// YouTube 21.43.5 / iOS 27 startup CoreData compatibility guard.
//
// 2026-11-10 crash reports (three identical SIGABRTs):
// YTPingStoreImpl.init -> YTInnerTubeCoreDataContext.init
// -> YTCoreDataContext.initWithModelName:... -> NSManagedObjectModel.initWithContentsOfURL:
// The native context supplies "DataLibDataModel" (ARM64 VA 0x100343378).
// A valid compiled .mom is included in the supplied IPA alongside the .omo.
//
// We only retry a failed load of this particular model, using the ORIGINAL
// NSManagedObjectModel initializer on its VersionInfo-selected .mom. This does
// not hook any flag, identity, request, database migration, or global model.
// No empty schema is fabricated. Missing or corrupt model resources still
// fail in the original CoreData path, with a diagnostic log.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>

static id (*sYTABCOriginalModelInit)(id, SEL, NSURL *);
static BOOL sYTABCRecoveryInstalled;

static BOOL YTABIsDataLibModelURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return NO;
    NSString *path = url.path ?: @"";
    return [path.lastPathComponent isEqualToString:@"DataLibDataModel.momd"] ||
           [path containsString:@"/DataLibDataModel.momd/"];
}

static NSURL *YTABCDataLibUnoptimizedModelURL(NSURL *source) {
    NSString *path = source.path ?: @"";
    NSString *directory = nil;
    NSRange range = [path rangeOfString:@"/DataLibDataModel.momd"];
    if (range.location != NSNotFound) {
        directory = [path substringToIndex:NSMaxRange(range)];
    } else {
        directory = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"DataLibDataModel.momd"];
    }
    BOOL isDir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directory isDirectory:&isDir] || !isDir) return nil;

    NSString *infoPath = [directory stringByAppendingPathComponent:@"VersionInfo.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSString *version = [info objectForKey:@"NSManagedObjectModel_CurrentVersionName"];
    if (![version isKindOfClass:NSString.class] || !version.length) return nil;
    NSString *mom = [directory stringByAppendingPathComponent:
                     [version stringByAppendingPathExtension:@"mom"]];
    if (![fm isReadableFileAtPath:mom]) return nil;
    return [NSURL fileURLWithPath:mom isDirectory:NO];
}

static id YTABCoreDataInitCompatibility(id receiver, SEL selector, NSURL *url) {
    if (!sYTABCOriginalModelInit) return nil;
    if (!YTABIsDataLibModelURL(url)) {
        return sYTABCOriginalModelInit(receiver, selector, url);
    }
    NSException *sourceException = nil;
    @try {
        id model = sYTABCOriginalModelInit(receiver, selector, url);
        if (model) return model;
    } @catch (NSException *e) {
        sourceException = e;
        NSLog(@"[YTABC CoreData] DataLibDataModel original CoreData exception: %@ — %@",
              e.name, e.reason);
    }

    NSURL *momURL = YTABCDataLibUnoptimizedModelURL(url);
    if (momURL && ![url isEqual:momURL]) {
        NSLog(@"[YTABC CoreData] Retrying the same DataLibDataModel version via %@", momURL.lastPathComponent);
        @try {
            // The first initializer may have partially initialized receiver.
            // Start the fallback on a fresh object and use the original IMP.
            id allocated = [NSManagedObjectModel alloc];
            id model = sYTABCOriginalModelInit(allocated, selector, momURL);
            if (model) {
                NSLog(@"[YTABC CoreData] DataLibDataModel fallback .mom loaded");
                return model;
            }
            NSLog(@"[YTABC CoreData] Fallback returned nil");
        } @catch (NSException *e) {
            NSLog(@"[YTABC CoreData] DataLibDataModel fallback failed: %@ — %@",
                  e.name, e.reason);
        }
    } else {
        NSLog(@"[YTABC CoreData] DataLibDataModel .mom unavailable in installed IPA; "
              @"verify the full .momd directory was retained by the sideload packager");
    }
    // Never return an invented or empty managed object model.
    if (sourceException) @throw sourceException;
    return nil;
}

void YTABCInstallCoreDataModelCompatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"NSManagedObjectModel");
        SEL selector = NSSelectorFromString(@"initWithContentsOfURL:");
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method || method_getNumberOfArguments(method) != 3) {
            NSLog(@"[YTABC CoreData] Missing CoreData initializer; recovery not installed");
            return;
        }
        // ABI: an ObjC object return and one ObjC object parameter. Accept
        // Apple type qualifiers/SDK offset changes only when the types match.
        char *ret = method_copyReturnType(method);
        char *arg = method_copyArgumentType(method, 2);
        BOOL valid = ret && arg && ret[0] == '@' && arg[0] == '@';
        if (ret) free(ret);
        if (arg) free(arg);
        if (!valid) {
            NSLog(@"[YTABC CoreData] Unexpected CoreData initializer ABI");
            return;
        }
        MSHookMessageEx(cls, selector, (IMP)YTABCoreDataInitCompatibility,
                        (IMP *)&sYTABCOriginalModelInit);
        sYTABCRecoveryInstalled = sYTABCOriginalModelInit != NULL;
        if (!sYTABCRecoveryInstalled)
            NSLog(@"[YTABC CoreData] Hook did not return original implementation");
    });
}
