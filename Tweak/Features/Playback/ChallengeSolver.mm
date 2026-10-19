#import "../../YTKACE.h"
#import "../../UI/Assets.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

static NSString *YTKACEChallengeScript(NSString *name) {
    NSString *path = [YTKACEAssetsBundle() pathForResource:name ofType:@"js" inDirectory:@"ejs"];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}

static NSURL *YTKACEChallengeCacheDirectory(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

static NSURL *YTKACEChallengeCacheURL(NSString *playerID) {
    return [YTKACEChallengeCacheDirectory() URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTKACE-player-%@.js", playerID]];
}

// Each player version leaves a multi-MB preprocessed script in Caches; keep
// only the two most recently written ones.
static void YTKACEPruneChallengeCache(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *directory = YTKACEChallengeCacheDirectory();
        if (directory == nil) return;
        NSArray<NSURL *> *contents =
            [manager contentsOfDirectoryAtURL:directory
                   includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                        error:nil];
        NSMutableArray<NSURL *> *players = [NSMutableArray array];
        NSMutableDictionary<NSURL *, NSDate *> *dates = [NSMutableDictionary dictionary];
        for (NSURL *file in contents) {
            NSString *name = file.lastPathComponent;
            if (![name hasPrefix:@"YTKACE-player-"] || ![name hasSuffix:@".js"]) continue;
            NSDate *date = nil;
            [file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
            dates[file] = [date isKindOfClass:NSDate.class] ? date : NSDate.distantPast;
            [players addObject:file];
        }
        if (players.count <= 2) return;
        [players sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
            return [dates[right] compare:dates[left]];
        }];
        for (NSUInteger index = 2; index < players.count; index++) {
            [manager removeItemAtURL:players[index] error:nil];
        }
    }});
}

// Mirrors the tail of yt-dlp ejs `jsc()`: running the preprocessed player
// fills `_result` with the n/sig functions. jsc() recompiles and reruns the
// whole multi-MB script on every call; here it runs once per player version
// and the extracted functions stay in the context.
static NSString * const YTKACESolverHelpers =
    @"var __ytkaceSolvers = null;\n"
    @"function __ytkacePrepare(source) {\n"
    @"  __ytkaceSolvers = null;\n"
    @"  var solvers = {n: null, sig: null};\n"
    @"  Function('_result', source)(solvers);\n"
    @"  __ytkaceSolvers = solvers;\n"
    @"  return true;\n"
    @"}\n"
    @"function __ytkaceSolve(type, challenges) {\n"
    @"  if (type !== 'n' && type !== 'sig') return {type: 'error', error: 'Unknown request type: ' + type};\n"
    @"  var solver = __ytkaceSolvers ? __ytkaceSolvers[type] : null;\n"
    @"  if (!solver) return {type: 'error', error: 'Failed to extract ' + type + ' function'};\n"
    @"  try {\n"
    @"    var data = {};\n"
    @"    for (var i = 0; i < challenges.length; i++) data[challenges[i]] = solver(challenges[i]);\n"
    @"    return {type: 'result', data: data};\n"
    @"  } catch (e) {\n"
    @"    return {type: 'error', error: (e instanceof Error) ? e.message + '\\n' + e.stack : String(e)};\n"
    @"  }\n"
    @"}\n";

static NSDictionary<NSString *, NSString *> *YTKACEStringPairs(id data) {
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary<NSString *, NSString *> *pairs = [NSMutableDictionary dictionary];
    [(NSDictionary *)data enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) {
            pairs[key] = value;
        }
    }];
    return pairs;
}

NSDictionary<NSString *, NSString *> *YTKACESolveChallenges(NSString *playerID, NSString *playerJS,
                                                            NSString *type, NSArray<NSString *> *challenges) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ytkace.challenge", DISPATCH_QUEUE_SERIAL);
        YTKACEPruneChallengeCache();
    });
    __block NSDictionary *result = nil;
    dispatch_sync(queue, ^{ @autoreleasepool {
        static JSContext *context;
        static NSString *failure;
        static NSString *preparedID;
        static NSString *preparedPlayer;
        static NSString *readyID;
        static NSString *unpreparableID;
        if (challenges.count == 0 || type.length == 0) return;
        if (context == nil) {
            NSString *library = YTKACEChallengeScript(@"yt.solver.lib.min");
            NSString *core = YTKACEChallengeScript(@"yt.solver.core.min");
            if (library.length == 0 || core.length == 0) {
                YTKACEDownloadLog(@"nsolver", @"missing solver files lib=%lu core=%lu",
                                  (unsigned long)library.length, (unsigned long)core.length);
                return;
            }
            context = [JSContext new];
            context.exceptionHandler = ^(__unused JSContext *ctx, JSValue *exception) {
                failure = exception.toString;
            };
            [context evaluateScript:library];
            [context evaluateScript:@"var meriyah = lib.meriyah, astring = lib.astring;"];
            [context evaluateScript:core];
            [context evaluateScript:YTKACESolverHelpers];
        }
        failure = nil;
        const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSURL *cacheURL = playerID.length ? YTKACEChallengeCacheURL(playerID) : nil;
        BOOL ready = playerID.length != 0 && [readyID isEqualToString:playerID];
        NSString *prepared = nil;
        if (!ready) {
            if (playerID.length != 0 && [preparedID isEqualToString:playerID]) {
                prepared = preparedPlayer;
            } else if (cacheURL != nil) {
                prepared = [NSString stringWithContentsOfURL:cacheURL encoding:NSUTF8StringEncoding error:nil];
                if (prepared.length != 0) {
                    preparedID = playerID;
                    preparedPlayer = prepared;
                }
            }
            if (prepared.length != 0 && ![unpreparableID isEqualToString:playerID]) {
                // Hand the preprocessed player to JS once; later calls only
                // pass the challenges.
                readyID = nil;
                JSValue *prepare = [context[@"__ytkacePrepare"] callWithArguments:@[prepared]];
                if (failure == nil && prepare.toBool) {
                    readyID = playerID;
                    ready = YES;
                    preparedID = nil;
                    preparedPlayer = nil;
                } else {
                    unpreparableID = playerID;
                    failure = nil;
                }
            }
        }
        NSDictionary *response = nil;
        if (ready) {
            JSValue *output = [context[@"__ytkaceSolve"] callWithArguments:@[type, challenges]];
            response = output.toDictionary;
        } else {
            if (prepared.length == 0 && playerJS.length == 0) return;
            NSDictionary *input = prepared.length
                ? @{@"type": @"preprocessed", @"preprocessed_player": prepared,
                    @"requests": @[@{@"type": type, @"challenges": challenges}]}
                : @{@"type": @"player", @"player": playerJS, @"output_preprocessed": @YES,
                    @"requests": @[@{@"type": type, @"challenges": challenges}]};
            JSValue *output = [context[@"jsc"] callWithArguments:@[input]];
            NSDictionary *value = output.toDictionary;
            id preprocessed = value[@"preprocessed_player"];
            if ([preprocessed isKindOfClass:NSString.class] && [preprocessed length] != 0 &&
                cacheURL != nil) {
                [(NSString *)preprocessed writeToURL:cacheURL atomically:YES
                                            encoding:NSUTF8StringEncoding error:nil];
                preparedID = playerID;
                preparedPlayer = preprocessed;
                YTKACEPruneChallengeCache();
            }
            id responses = value[@"responses"];
            response = [responses isKindOfClass:NSArray.class] ? [responses firstObject] : nil;
        }
        if (![response isKindOfClass:NSDictionary.class]) response = nil;
        if ([response[@"type"] isEqual:@"result"]) result = YTKACEStringPairs(response[@"data"]);
        id responseError = response[@"error"];
        YTKACEDownloadLog(@"nsolver", @"%@ solved=%lu/%lu cached=%d ms=%.0f error=%@", type,
                          (unsigned long)result.count, (unsigned long)challenges.count,
                          ready || prepared.length != 0,
                          (CFAbsoluteTimeGetCurrent() - start) * 1000.0,
                          failure ?: responseError ?: @"none");
    }});
    return result;
}

NSString *YTKACESolveURLParameterN(NSString *playerID, NSString *playerJS, NSString *URLString) {
    if (URLString.length == 0) return URLString;
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"([?&])n=([^&]+)"
                                                            options:0 error:nil];
    });
    NSTextCheckingResult *match = [pattern firstMatchInString:URLString options:0
                                                        range:NSMakeRange(0, URLString.length)];
    if (match == nil) return URLString;
    NSString *challenge = [URLString substringWithRange:[match rangeAtIndex:2]].stringByRemovingPercentEncoding;
    if (challenge.length == 0) return URLString;
    NSString *solved = YTKACESolveChallenges(playerID, playerJS, @"n", @[challenge])[challenge];
    if (solved.length == 0) return URLString;
    NSString *encoded = [solved stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet];
    if (encoded.length == 0) return URLString;
    return [URLString stringByReplacingCharactersInRange:[match rangeAtIndex:2] withString:encoded];
}
