// YouTube 21.43.5 / iOS 27 startup CoreData compatibility guard.
//
// 2026-11-10 crash reports (three identical SIGABRTs):
// YTPingStoreImpl.init -> YTInnerTubeCoreDataContext.init
// -> YTCoreDataContext.initWithModelName:... -> NSManagedObjectModel.initWithContentsOfURL:
// The native context supplies "DataLibDataModel" (ARM64 VA 0x100343378).
// A valid compiled .mom is included in the supplied IPA alongside the .omo.
//
// We prefer the verified VersionInfo-selected .mom BEFORE the original .momd
// path, avoiding the startup abort caused by attempting the optimized model.
// Both loads still use the ORIGINAL NSManagedObjectModel initializer. This does
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
    if (!YTABIsDataLibModelURL(url))
        return sYTABCOriginalModelInit(receiver, selector, url);

    // Earlier recovery tried the original .momd first and only then the
    // unoptimized .mom after an exception. The 2026-11-10 10:17 IPS still
    // aborts inside that original CoreData initializer with this hook in the
    // stack. Prefer the actual VersionInfo-selected .mom BEFORE invoking
    // the optimized .momd loader; otherwise the app may already terminate.
    NSURL *momURL = YTABCDataLibUnoptimizedModelURL(url);
    if (momURL && ![momURL isEqual:url]) {
        NSData *contents = [NSData dataWithContentsOfURL:momURL
                                                 options:NSDataReadingMappedIfSafe
                                                   error:nil];
        BOOL plistHeader = contents.length >= 8 &&
            memcmp(contents.bytes, "bplist00", 8) == 0;
        if (plistHeader) {
            NSLog(@"[YTABC CoreData] Loading VersionInfo-selected %@ before optimized .momd",
                  momURL.lastPathComponent);
            @try {
                id model = sYTABCOriginalModelInit(receiver, selector, momURL);
                if (model) return model;
            } @catch (NSException *e) {
                NSLog(@"[YTABC CoreData] Preferred model load failed: %@ / %@",
                      e.name, e.reason);
            }
        } else {
            NSLog(@"[YTABC CoreData] Selected .mom missing/invalid. Falling back to native path.");
        }
    } else {
        NSLog(@"[YTABC CoreData] No readable VersionInfo-selected .mom available.");
    }

    // Last resort: preserve the YouTube-native .momd loading behavior.
    // Do not fabricate a model or swallow an unrelated exception.
    return sYTABCOriginalModelInit([NSManagedObjectModel alloc], selector, url);
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
