#import "DirectDownloader.h"
#import "StreamResolver.h"
#import "DownloadLog.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>

NSString * const YTKACEDownloadMethodKey = @"YTKACE.Preference.Downloads.Method";

static NSString * const YTKACEDirectUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";
static NSString * const YTKACEDirectVisitorKey = @"YTKACE.Cache.DirectVisitor";
static const NSTimeInterval YTKACEDirectVisitorLifetime = 7.0 * 24.0 * 60.0 * 60.0;
static const int64_t YTKACEDirectChunkSize = 8 * 1024 * 1024;
static const NSInteger YTKACEDirectChunkAttempts = 4;

static NSInteger YTKACEDownloadMethod(void) {
    id stored = YTKACEPreferenceObject(YTKACEDownloadMethodKey);
    if ([stored respondsToSelector:@selector(integerValue)]) return [stored integerValue];
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.TVClient") ? 2 : 0;
}

BOOL YTKACEDirectDownloadsEnabled(void) {
    return YTKACEDownloadMethod() == 1;
}

BOOL YTKACETVDownloadsEnabled(void) {
    return YTKACEDownloadMethod() == 2;
}

@interface YTKACEDirectTask ()
@property(atomic, assign) BOOL cancelled;
@property(nonatomic, strong) NSMutableSet<NSURLSessionTask *> *runningTasks;
- (void)addRunningTask:(NSURLSessionTask *)task;
- (void)removeRunningTask:(NSURLSessionTask *)task;
@end

@implementation YTKACEDirectTask

- (instancetype)init {
    self = [super init];
    if (self != nil) _runningTasks = [NSMutableSet set];
    return self;
}

- (void)cancel {
    self.cancelled = YES;
    NSArray<NSURLSessionTask *> *running = nil;
    @synchronized (self) {
        running = self.runningTasks.allObjects;
    }
    for (NSURLSessionTask *task in running) [task cancel];
}

// Video and audio download concurrently, so more than one request can be in flight.
- (void)addRunningTask:(NSURLSessionTask *)task {
    if (task == nil) return;
    @synchronized (self) {
        [self.runningTasks addObject:task];
    }
    if (self.cancelled) [task cancel];
}

- (void)removeRunningTask:(NSURLSessionTask *)task {
    if (task == nil) return;
    @synchronized (self) {
        [self.runningTasks removeObject:task];
    }
}

@end

static NSError *YTKACEDirectError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTKACEDirect" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *YTKACEDirectCancelledError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
}

BOOL YTKACEDownloadHasFreeSpace(int64_t requiredBytes) {
    if (requiredBytes <= 0) return YES;
    NSURL *scratch = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSNumber *available = nil;
    if (![scratch getResourceValue:&available
                            forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] ||
        ![available isKindOfClass:NSNumber.class] || available.longLongValue <= 0) {
        return YES;
    }
    return available.longLongValue >= requiredBytes + 16LL * 1024 * 1024;
}

NSError *YTKACEDownloadStorageError(NSError *underlying) {
    NSString *message = underlying != nil
        ? [NSString stringWithFormat:@"The download could not be written to storage (%@). "
              "Free up space and try again.", underlying.localizedDescription]
        : @"Not enough free storage for this download. Free up space and try again.";
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message
                                                                   forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:@"YTKACEStorage" code:1 userInfo:info];
}

NSTimeInterval YTKACEDownloadRetryDelay(NSInteger attempt, NSTimeInterval base,
                                        NSTimeInterval cap, NSTimeInterval retryAfter) {
    NSTimeInterval delay = MIN(base * pow(2.0, (double)MAX(attempt - 1, 0)), cap);
    delay *= 0.75 + 0.5 * ((double)arc4random_uniform(1001) / 1000.0);
    if (retryAfter > 0.0) delay = MAX(delay, MIN(retryAfter, 60.0));
    return delay;
}

static NSTimeInterval YTKACEDirectRetryAfter(NSURLResponse *response) {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return 0.0;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (http.statusCode != 429 && http.statusCode != 503) return 0.0;
    id value = http.allHeaderFields[@"Retry-After"];
    return [value isKindOfClass:NSString.class] ? MAX([value doubleValue], 0.0) : 0.0;
}

static void YTKACEDirectSleep(NSTimeInterval seconds, YTKACEDirectTask *task) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while (!task.cancelled) {
        CFAbsoluteTime remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) break;
        [NSThread sleepForTimeInterval:MIN(remaining, 0.25)];
    }
}

static NSDictionary *YTKACEDirectContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": @"VISIONOS", @"clientVersion": @"1.02",
        @"osName": @"visionOS", @"osVersion": @"26.5.23O471",
        @"deviceMake": @"Apple", @"deviceModel": @"RealityDevice17,1",
        @"userAgent": YTKACEDirectUserAgent,
        @"hl": @"en", @"gl": @"US"} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSData *YTKACEDirectFetch(NSURLRequest *request, YTKACEDirectTask *task,
                                 NSInteger *status, NSError **error) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            result = data;
            failure = taskError;
            code = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            dispatch_semaphore_signal(done);
        }];
    [task addRunningTask:dataTask];
    [dataTask resume];
    BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(90 * NSEC_PER_SEC))) != 0;
    BOOL completed = !timedOut;
    if (timedOut) {
        [dataTask cancel];
        // Let the cancellation land so the handler is not still writing the results below.
        completed = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(5 * NSEC_PER_SEC))) == 0;
    }
    [task removeRunningTask:dataTask];
    if (status != NULL) *status = completed && !timedOut ? code : 0;
    if (error != NULL) {
        *error = timedOut ? YTKACEDirectError(2, @"request timed out") : failure;
    }
    return completed && !timedOut ? result : nil;
}

@interface YTKACEDirectChunkReceiver : NSObject <NSURLSessionDataDelegate>
@property(atomic, strong) NSMutableData *data;
@property(atomic, assign) NSInteger status;
@property(atomic, assign) NSTimeInterval retryAfter;
@property(atomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, copy) void (^received)(int64_t bytes);
@property(nonatomic, assign) CFAbsoluteTime lastReport;
@property(atomic, assign) CFAbsoluteTime lastActivity;
@end

@implementation YTKACEDirectChunkReceiver

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    (void)dataTask;
    self.status = [response isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)response).statusCode : 0;
    self.retryAfter = YTKACEDirectRetryAfter(response);
    self.lastActivity = CFAbsoluteTimeGetCurrent();
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    (void)dataTask;
    NSMutableData *buffer = self.data;
    [buffer appendData:data];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    self.lastActivity = now;
    if (self.received != nil && now - self.lastReport >= 0.1) {
        self.lastReport = now;
        self.received((int64_t)buffer.length);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session;
    (void)task;
    self.error = error;
    dispatch_semaphore_signal(self.done);
}

@end

static NSData *YTKACEDirectFetchChunk(NSURLRequest *request, YTKACEDirectTask *task,
                                      NSUInteger expectedLength,
                                      void (^received)(int64_t bytes),
                                      NSInteger *status, NSTimeInterval *retryAfter,
                                      NSError **error) {
    YTKACEDirectChunkReceiver *receiver = [YTKACEDirectChunkReceiver new];
    receiver.data = [NSMutableData dataWithCapacity:expectedLength];
    receiver.done = dispatch_semaphore_create(0);
    receiver.received = received;
    receiver.lastActivity = CFAbsoluteTimeGetCurrent();
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request];
    dataTask.delegate = receiver;
    [task addRunningTask:dataTask];
    [dataTask resume];
    // Idle watchdog: a slow but moving transfer is not cut off, a silent one is.
    BOOL timedOut = NO;
    while (dispatch_semaphore_wait(receiver.done, dispatch_time(DISPATCH_TIME_NOW,
               (int64_t)(2 * NSEC_PER_SEC))) != 0) {
        if (CFAbsoluteTimeGetCurrent() - receiver.lastActivity >= 90.0) {
            timedOut = YES;
            [dataTask cancel];
            dispatch_semaphore_wait(receiver.done, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(5 * NSEC_PER_SEC)));
            break;
        }
    }
    [task removeRunningTask:dataTask];
    NSError *failure = timedOut ? YTKACEDirectError(2, @"request timed out") : receiver.error;
    if (status != NULL) *status = receiver.status;
    if (retryAfter != NULL) *retryAfter = receiver.retryAfter;
    if (error != NULL) *error = failure;
    return failure == nil ? receiver.data : nil;
}

static NSMutableURLRequest *YTKACEDirectAPIRequest(NSString *path, NSDictionary *body,
                                                   NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:
        [@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:YTKACEDirectUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *YTKACEDirectVisitor(BOOL refresh, YTKACEDirectTask *task) {
    NSDictionary *cached = YTKACEPreferenceObject(YTKACEDirectVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            [time isKindOfClass:NSNumber.class] &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < YTKACEDirectVisitorLifetime) {
            return value;
        }
    }
    NSString *visitor = nil;
    for (NSInteger attempt = 0; attempt < 3 && visitor.length == 0 && !task.cancelled; attempt++) {
        if (attempt > 0) YTKACEDirectSleep(YTKACEDownloadRetryDelay(attempt, 0.4, 2.0, 0.0), task);
        NSData *data = YTKACEDirectFetch(YTKACEDirectAPIRequest(
            @"guide?prettyPrint=false&fields=responseContext.visitorData",
            @{@"context": YTKACEDirectContext(nil)}, nil), task, NULL, NULL);
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id context = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"] : nil;
        id value = [context isKindOfClass:NSDictionary.class] ? context[@"visitorData"] : nil;
        visitor = [value isKindOfClass:NSString.class] ? value : nil;
    }
    if (visitor.length == 0) return nil;
    YTKACESetPreferenceObject(YTKACEDirectVisitorKey,
        @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
    return visitor;
}

static NSArray<YTKACEStreamOption *> *YTKACEDirectOptions(NSString *videoID, YTKACEDirectTask *task,
                                                          NSString **reason) {
    Class responseClass = NSClassFromString(@"YTIPlayerResponse");
    SEL initSelector = NSSelectorFromString(@"initWithData:error:");
    if (responseClass == Nil || ![responseClass instancesRespondToSelector:initSelector]) {
        if (reason != NULL) *reason = @"player response class unavailable";
        return @[];
    }
    for (NSInteger attempt = 0; attempt < 2 && !task.cancelled; attempt++) {
        NSString *visitor = YTKACEDirectVisitor(attempt > 0, task);
        NSDictionary *body = @{@"context": YTKACEDirectContext(visitor), @"videoId": videoID,
                               @"contentCheckOk": @YES, @"racyCheckOk": @YES};
        NSInteger status = 0;
        NSData *proto = YTKACEDirectFetch(
            YTKACEDirectAPIRequest(@"player?alt=proto", body, visitor), task, &status, NULL);
        id response = proto.length != 0
            ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
                [responseClass alloc], initSelector, proto, NULL) : nil;
        NSMutableArray<YTKACEStreamOption *> *options = [NSMutableArray array];
        for (YTKACEStreamOption *option in [YTKACEStreamResolver optionsFromPlayerResponse:response]) {
            if (option.URL != nil && option.adaptive) [options addObject:option];
        }
        if (options.count != 0) return options;
        id playability = [response valueForKey:@"playabilityStatus"];
        if (reason != NULL) {
            *reason = [NSString stringWithFormat:@"no direct formats http=%ld reason=%@",
                (long)status, [playability valueForKey:@"reason"] ?: @"none"];
        }
    }
    return @[];
}

static NSString *YTKACEDirectCodec(YTKACEStreamOption *option) {
    NSString *mime = option.mimeType ?: @"";
    NSRange codecs = [mime rangeOfString:@"codecs=\""];
    if (codecs.location == NSNotFound) return mime;
    NSString *rest = [mime substringFromIndex:NSMaxRange(codecs)];
    NSRange dot = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".\""]];
    NSString *family = dot.location == NSNotFound ? rest : [rest substringToIndex:dot.location];
    NSString *container = [mime componentsSeparatedByString:@";"].firstObject ?: @"";
    return [NSString stringWithFormat:@"%@|%@", container, family];
}

static YTKACEStreamOption *YTKACEDirectMatch(NSArray<YTKACEStreamOption *> *options,
                                             YTKACEStreamOption *wanted, BOOL audio) {
    NSMutableArray<YTKACEStreamOption *> *pool = [NSMutableArray array];
    for (YTKACEStreamOption *option in options) {
        if (option.audioOnly == audio) [pool addObject:option];
    }
    if (pool.count == 0) return nil;
    if (wanted == nil) return pool.firstObject;
    BOOL wantsTrack = audio && wanted.audioTrackID.length != 0;
    for (YTKACEStreamOption *option in pool) {
        if (option.itag == wanted.itag &&
            (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID])) {
            return option;
        }
    }
    for (YTKACEStreamOption *option in pool) {
        if (option.itag == wanted.itag) return option;
    }
    NSString *codec = YTKACEDirectCodec(wanted);
    for (YTKACEStreamOption *option in pool) {
        if (![YTKACEDirectCodec(option) isEqualToString:codec]) continue;
        if (audio) {
            if (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID]) return option;
        } else if (option.height == wanted.height) {
            return option;
        }
    }
    return nil;
}

@interface YTKACEDirectJob : NSObject
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) YTKACEDirectTask *task;
@property(atomic, copy) NSArray<YTKACEStreamOption *> *options;
@end

@implementation YTKACEDirectJob

- (BOOL)refreshOptions {
    return [self refreshOptionsReplacing:nil];
}

// Serialized: the video and audio streams may both hit an expired URL at the same time.
// When `stale` is given and the other stream already replaced it, reuse that result.
- (BOOL)refreshOptionsReplacing:(NSArray<YTKACEStreamOption *> *)stale {
    @synchronized (self) {
        NSArray<YTKACEStreamOption *> *current = self.options;
        if (stale != nil && current.count != 0 && current != stale) return YES;
        NSString *reason = nil;
        NSArray *options = YTKACEDirectOptions(self.videoID, self.task, &reason);
        if (options.count == 0) {
            YTKACEDownloadLog(self.identifier, @"direct refresh failed %@", reason ?: @"");
            return NO;
        }
        self.options = options;
        return YES;
    }
}

- (BOOL)downloadOption:(YTKACEStreamOption *)option
                 audio:(BOOL)audio
                toFile:(NSURL *)file
              progress:(void (^)(int64_t bytes))progress
                 error:(NSError **)error {
    [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:error];
    if (handle == nil) return NO;
    YTKACEStreamOption *current = option;
    NSArray<YTKACEStreamOption *> *source = self.options;
    int64_t total = MAX((int64_t)current.contentLength, 0);
    int64_t offset = 0;
    BOOL finished = NO;
    while (!finished) {
        if (self.task.cancelled) {
            [handle closeAndReturnError:nil];
            if (error != NULL) *error = YTKACEDirectCancelledError();
            return NO;
        }
        int64_t end = total > 0 ? MIN(offset + YTKACEDirectChunkSize, total) - 1
                                : offset + YTKACEDirectChunkSize - 1;
        NSData *chunk = nil;
        NSInteger status = 0;
        NSTimeInterval retryAfter = 0.0;
        for (NSInteger attempt = 0; attempt < YTKACEDirectChunkAttempts && chunk == nil; attempt++) {
            if (self.task.cancelled) break;
            if (attempt > 0) {
                YTKACEDirectSleep(YTKACEDownloadRetryDelay(attempt, 0.6, 8.0, retryAfter), self.task);
                if (self.task.cancelled) break;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:current.URL];
            [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, end]
                forHTTPHeaderField:@"Range"];
            [request setValue:YTKACEDirectUserAgent forHTTPHeaderField:@"User-Agent"];
            request.timeoutInterval = 45.0;
            NSError *fetchError = nil;
            int64_t chunkStart = offset;
            retryAfter = 0.0;
            NSData *data = YTKACEDirectFetchChunk(request, self.task, (NSUInteger)(end - offset + 1),
                ^(int64_t bytes) {
                    if (progress != nil) progress(chunkStart + bytes);
                }, &status, &retryAfter, &fetchError);
            BOOL ok = (status == 206 || status == 200) && data.length != 0 &&
                (total <= 0 || (int64_t)data.length == end - offset + 1);
            if (ok) {
                chunk = data;
                break;
            }
            YTKACEDownloadLog(self.identifier, @"direct chunk retry itag=%ld offset=%lld http=%ld error=%@",
                (long)current.itag, offset, (long)status, fetchError.localizedDescription ?: @"none");
            // Only an expired/forbidden URL needs fresh formats; other failures retry as is.
            if ((status == 403 || status == 410) && [self refreshOptionsReplacing:source]) {
                source = self.options;
                YTKACEStreamOption *renewed = YTKACEDirectMatch(source, current, audio);
                if (renewed != nil) current = renewed;
            }
        }
        if (chunk == nil) {
            [handle closeAndReturnError:nil];
            if (error != NULL) {
                *error = self.task.cancelled
                    ? YTKACEDirectCancelledError()
                    : YTKACEDirectError(3, [NSString stringWithFormat:
                        @"chunk failed at %lld http=%ld", offset, (long)status]);
            }
            return NO;
        }
        NSError *writeError = nil;
        if (![handle writeData:chunk error:&writeError]) {
            [handle closeAndReturnError:nil];
            YTKACEDownloadLog(self.identifier, @"direct write failed itag=%ld offset=%lld error=%@",
                (long)current.itag, offset, writeError.localizedDescription ?: @"unknown");
            if (error != NULL) *error = YTKACEDownloadStorageError(writeError);
            return NO;
        }
        offset += (int64_t)chunk.length;
        if (progress != nil) progress(offset);
        finished = total > 0 ? offset >= total : (int64_t)chunk.length < YTKACEDirectChunkSize;
    }
    NSError *closeError = nil;
    if (![handle closeAndReturnError:&closeError]) {
        if (error != NULL) *error = YTKACEDownloadStorageError(closeError);
        return NO;
    }
    return YES;
}

@end

@implementation YTKACEDirectDownloader

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<YTKACEStreamOption *> *options))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reason = nil;
        NSArray *options = videoID.length == 0 ? @[] :
            YTKACEDirectOptions(videoID, [YTKACEDirectTask new], &reason);
        YTKACEDownloadLog(@"direct", @"formats video=%@ count=%lu %@", videoID,
            (unsigned long)options.count, reason ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(options); });
    });
}

+ (NSString *)codecNameForOption:(YTKACEStreamOption *)option {
    NSString *mime = option.mimeType.lowercaseString ?: @"";
    if ([mime containsString:@"avc1"]) return @"H.264";
    if ([mime containsString:@"av01"]) return @"AV1";
    if ([mime containsString:@"vp9"] || [mime containsString:@"vp09"]) return @"VP9";
    if ([mime containsString:@"opus"]) return @"Opus";
    if ([mime containsString:@"mp4a"]) return @"AAC";
    return [mime componentsSeparatedByString:@";"].firstObject ?: @"";
}

+ (YTKACEDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(YTKACEStreamOption *)videoOption
                          audioOption:(YTKACEStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(YTKACESABRProgress)progress
                           completion:(YTKACESABRCompletion)completion {
    YTKACEDirectTask *task = [YTKACEDirectTask new];
    YTKACEDirectJob *job = [YTKACEDirectJob new];
    job.videoID = videoID;
    job.identifier = identifier;
    job.task = task;
    void (^finish)(NSURL *, NSURL *, NSError *) = ^(NSURL *video, NSURL *audio, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(video, audio, error); });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (videoID.length == 0) {
            finish(nil, nil, YTKACEDirectError(1, @"missing video id"));
            return;
        }
        if (![job refreshOptions]) {
            finish(nil, nil, YTKACEDirectError(1, @"no direct formats"));
            return;
        }
        YTKACEStreamOption *video = audioOnly ? nil : YTKACEDirectMatch(job.options, videoOption, NO);
        YTKACEStreamOption *audio = YTKACEDirectMatch(job.options, audioOption, YES);
        if (audio == nil || (!audioOnly && video == nil)) {
            finish(nil, nil, YTKACEDirectError(4, @"selected format not offered directly"));
            return;
        }
        YTKACEDownloadLog(identifier, @"direct start video=%ld audio=%ld",
            (long)video.itag, (long)audio.itag);
        int64_t required = MAX((int64_t)audio.contentLength, 0) +
            (video != nil ? MAX((int64_t)video.contentLength, 0) : 0);
        if (!YTKACEDownloadHasFreeSpace(required)) {
            YTKACEDownloadLog(identifier, @"direct insufficient space required=%lld", required);
            finish(nil, nil, YTKACEDownloadStorageError(nil));
            return;
        }
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"YTKACE-%@",
                NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *(^extension)(YTKACEStreamOption *) = ^NSString *(YTKACEStreamOption *option) {
            return [option.mimeType containsString:@"webm"] ? @"webm" :
                ([option.mimeType hasPrefix:@"audio/"] ? @"m4a" : @"mp4");
        };
        NSURL *videoURL = video == nil ? nil : [directory URLByAppendingPathComponent:
            [@"video." stringByAppendingString:extension(video)]];
        NSURL *audioURL = [directory URLByAppendingPathComponent:
            [@"audio." stringByAppendingString:extension(audio)]];
        __block int64_t videoBytes = 0;
        __block int64_t audioBytes = 0;
        int64_t videoTotal = MAX((int64_t)video.contentLength, 1);
        int64_t audioTotal = MAX((int64_t)audio.contentLength, 1);
        // Video and audio are independent byte ranges; fetch them at the same time.
        NSObject *progressLock = [NSObject new];
        __block NSError *videoError = nil;
        __block NSError *audioError = nil;
        __block BOOL videoDone = video == nil;
        void (^reportProgress)(void) = ^{
            if (progress == nil) return;
            int64_t a = 0, v = 0;
            BOOL videoFinished = NO;
            @synchronized (progressLock) {
                a = audioBytes;
                v = videoBytes;
                videoFinished = videoDone;
            }
            double audioProgress = MIN(1.0, (double)a / (double)audioTotal);
            double videoProgress = MIN(1.0, (double)v / (double)videoTotal);
            NSInteger phase = videoFinished ? 1 : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(audioProgress, videoProgress, a, v, phase);
            });
        };
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t worker = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        if (video != nil) {
            dispatch_group_async(group, worker, ^{
                NSError *streamError = nil;
                BOOL ok = [job downloadOption:video audio:NO toFile:videoURL
                    progress:^(int64_t bytes) {
                        @synchronized (progressLock) { videoBytes = bytes; }
                        reportProgress();
                    } error:&streamError];
                @synchronized (progressLock) {
                    if (ok) videoDone = YES;
                    else videoError = streamError ?: YTKACEDirectError(3, @"video download failed");
                }
                if (!ok) [task cancel];
                else reportProgress();
            });
        }
        dispatch_group_async(group, worker, ^{
            NSError *streamError = nil;
            BOOL ok = [job downloadOption:audio audio:YES toFile:audioURL
                progress:^(int64_t bytes) {
                    @synchronized (progressLock) { audioBytes = bytes; }
                    reportProgress();
                } error:&streamError];
            if (!ok) {
                @synchronized (progressLock) {
                    audioError = streamError ?: YTKACEDirectError(3, @"audio download failed");
                }
                [task cancel];
            }
        });
        dispatch_group_notify(group, worker, ^{
            NSError *failedVideo = nil, *failedAudio = nil;
            @synchronized (progressLock) {
                failedVideo = videoError;
                failedAudio = audioError;
            }
            if (failedVideo != nil || failedAudio != nil) {
                // A stream that failed for real stops its sibling through the task; report the
                // real failure rather than the sibling's resulting cancellation.
                BOOL (^isCancel)(NSError *) = ^BOOL(NSError *candidate) {
                    return [candidate.domain isEqualToString:NSURLErrorDomain] &&
                        candidate.code == NSURLErrorCancelled;
                };
                NSError *error = failedVideo != nil && !isCancel(failedVideo) ? failedVideo
                    : (failedAudio != nil && !isCancel(failedAudio) ? failedAudio
                    : (failedVideo ?: failedAudio));
                [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                YTKACEDownloadLog(identifier, @"direct %@ failed %@",
                    error == failedVideo ? @"video" : @"audio", error.localizedDescription);
                finish(nil, nil, error);
                return;
            }
            YTKACEDownloadLog(identifier, @"direct complete video=%lld audio=%lld",
                videoBytes, audioBytes);
            finish(videoURL, audioURL, nil);
        });
    });
    return task;
}

@end
