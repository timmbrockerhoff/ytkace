#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <os/lock.h>

static NSString * const YTKACESponsorServer = @"https://sponsor.ajay.app";
// Videos with no segments (the common case) are re-checked after this long;
// videos with segments stay cached for the session, as before.
static const NSTimeInterval YTKACESponsorEmptyTTL = 30 * 60;
static const NSUInteger YTKACESponsorMaxResponse = 2 * 1024 * 1024;

typedef void (^YTKACESponsorWaiter)(NSArray *segments);

@interface YTKACESponsorEntry : NSObject
@property(nonatomic, copy) NSArray *segments;
@property(nonatomic) NSTimeInterval expiry; // 0 = no expiry
@end

@implementation YTKACESponsorEntry
@end

@interface YTKACESponsorClient () {
    os_unfair_lock _lock;
}
@property(nonatomic, strong) NSCache<NSString *, YTKACESponsorEntry *> *cache;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *waiters;
@end

// Every known category. The client always fetches all of them once per video
// and filters per caller, so the player (enabled categories) and downloads
// (all categories) share one request and one cache entry.
static NSArray<NSString *> *YTKACESponsorAllCategories(void) {
    static NSArray<NSString *> *categories;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
            id identifier = definition[@"id"];
            if ([identifier isKindOfClass:NSString.class]) [all addObject:identifier];
        }
        categories = [all copy];
    });
    return categories;
}

// First 4 hex characters of sha256(videoID), for the k-anonymity endpoint.
static NSString *YTKACESponsorHashPrefix(NSString *videoID) {
    NSData *data = [videoID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%02x%02x", digest[0], digest[1]];
}

static NSArray *YTKACESponsorParseSegments(id items) {
    if (![items isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *segments = [NSMutableArray array];
    for (id item in (NSArray *)items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id category = item[@"category"];
        id values = item[@"segment"];
        id actionType = item[@"actionType"];
        if (![category isKindOfClass:NSString.class] ||
            ([actionType isKindOfClass:NSString.class] &&
             ![actionType isEqualToString:@"skip"]) ||
            ![values isKindOfClass:NSArray.class] ||
            [values count] != 2) {
            continue;
        }
        id startValue = values[0];
        id endValue = values[1];
        if (![startValue isKindOfClass:NSNumber.class] ||
            ![endValue isKindOfClass:NSNumber.class]) {
            continue;
        }
        double start = [startValue doubleValue];
        double end = [endValue doubleValue];
        if (!isfinite(start) || !isfinite(end) || start < 0.0 || end <= start) {
            continue;
        }
        [segments addObject:@{@"start": @(start), @"end": @(end),
                              @"category": category}];
    }
    return [segments sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"start"] compare:right[@"start"]];
        }];
}

static NSArray *YTKACESponsorFilter(NSArray *segments, NSArray<NSString *> *categories) {
    if (segments.count == 0) return @[];
    NSSet<NSString *> *allowed = [NSSet setWithArray:categories];
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:segments.count];
    for (NSDictionary *segment in segments) {
        if ([allowed containsObject:segment[@"category"]]) [filtered addObject:segment];
    }
    return filtered;
}

static NSString *YTKACESponsorCategoryJSON(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:YTKACESponsorAllCategories()
                                                   options:0 error:nil];
    NSString *json = data == nil ? nil :
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return json ?: @"[]";
}

@implementation YTKACESponsorClient

+ (instancetype)sharedClient {
    static YTKACESponsorClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [YTKACESponsorClient new];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _cache = [NSCache new];
        _cache.countLimit = 256;
        _waiters = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 15.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)segmentsForVideoID:(NSString *)videoID
                completion:(YTKACESponsorCompletion)completion {
    if (videoID.length == 0) {
        completion(@[]);
        return;
    }

    [self segmentsForVideoID:videoID categories:YTKACESponsorEnabledCategories()
                  completion:completion];
}

// Caller must hold _lock.
- (NSArray *)cachedSegmentsLocked:(NSString *)videoID {
    YTKACESponsorEntry *entry = [self.cache objectForKey:videoID];
    if (entry == nil) return nil;
    if (entry.expiry > 0 && NSDate.date.timeIntervalSince1970 >= entry.expiry) {
        [self.cache removeObjectForKey:videoID];
        return nil;
    }
    return entry.segments;
}

- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(YTKACESponsorCompletion)completion {
    if (videoID.length == 0 || categories.count == 0) {
        completion(@[]);
        return;
    }
    NSString *key = [videoID copy];
    NSArray<NSString *> *wanted = [categories copy];

    os_unfair_lock_lock(&_lock);
    NSArray *cached = [self cachedSegmentsLocked:key];
    BOOL start = NO;
    if (cached == nil) {
        // Coalesce: one network request per video, any number of completions.
        NSMutableArray *waiters = self.waiters[key];
        if (waiters == nil) {
            waiters = [NSMutableArray array];
            self.waiters[key] = waiters;
            start = YES;
        }
        YTKACESponsorWaiter waiter = ^(NSArray *segments) {
            completion(YTKACESponsorFilter(segments, wanted));
        };
        [waiters addObject:[waiter copy]];
    }
    os_unfair_lock_unlock(&_lock);

    if (cached != nil) {
        completion(YTKACESponsorFilter(cached, wanted));
        return;
    }
    if (start) [self fetchVideoID:key legacy:NO];
}

- (void)finishVideoID:(NSString *)videoID segments:(NSArray *)segments
            cacheable:(BOOL)cacheable {
    NSArray *result = segments ?: @[];
    os_unfair_lock_lock(&_lock);
    if (cacheable) {
        YTKACESponsorEntry *entry = [YTKACESponsorEntry new];
        entry.segments = result;
        entry.expiry = result.count == 0
            ? NSDate.date.timeIntervalSince1970 + YTKACESponsorEmptyTTL : 0;
        [self.cache setObject:entry forKey:videoID];
    }
    NSArray *waiters = [self.waiters[videoID] copy];
    [self.waiters removeObjectForKey:videoID];
    os_unfair_lock_unlock(&_lock);

    dispatch_async(dispatch_get_main_queue(), ^{
        for (YTKACESponsorWaiter waiter in waiters) {
            waiter(result);
        }
    });
}

- (void)fetchVideoID:(NSString *)videoID legacy:(BOOL)legacy {
    // Default: privacy-preserving hash-prefix lookup, so the server never
    // sees which video is being watched. Legacy (full video ID) is only used
    // as a fallback if the prefix endpoint rejects the request or returns an
    // unexpected format.
    NSString *path = legacy
        ? @"/api/skipSegments"
        : [@"/api/skipSegments/" stringByAppendingString:YTKACESponsorHashPrefix(videoID)];
    NSURLComponents *components =
        [NSURLComponents componentsWithString:[YTKACESponsorServer stringByAppendingString:path]];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    if (legacy) [items addObject:[NSURLQueryItem queryItemWithName:@"videoID" value:videoID]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"categories"
                                                 value:YTKACESponsorCategoryJSON()]];
    components.queryItems = items;
    NSURL *url = components.URL;
    if (url == nil) {
        [self finishVideoID:videoID segments:@[] cacheable:NO];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak YTKACESponsorClient *weakSelf = self;
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        YTKACESponsorClient *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        NSHTTPURLResponse *http =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response
                : nil;
        NSInteger status = error == nil ? http.statusCode : 0;

        // 404 = no segments for this video (or for any video with this prefix).
        if (status == 404) {
            [strongSelf finishVideoID:videoID segments:@[] cacheable:YES];
            return;
        }
        id json = nil;
        if (status == 200 && data.length != 0 && data.length <= YTKACESponsorMaxResponse) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        if (legacy) {
            if ([json isKindOfClass:NSArray.class]) {
                [strongSelf finishVideoID:videoID
                                 segments:YTKACESponsorParseSegments(json)
                                cacheable:YES];
            } else {
                [strongSelf finishVideoID:videoID segments:@[] cacheable:NO];
            }
            return;
        }
        if ([json isKindOfClass:NSArray.class]) {
            id match = nil;
            for (id entry in (NSArray *)json) {
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                id entryID = entry[@"videoID"];
                if ([entryID isKindOfClass:NSString.class] &&
                    [entryID isEqualToString:videoID]) {
                    match = entry[@"segments"];
                    break;
                }
            }
            [strongSelf finishVideoID:videoID
                             segments:YTKACESponsorParseSegments(match)
                            cacheable:YES];
            return;
        }
        if (status == 400 || (status == 200 && data.length != 0 &&
                              data.length <= YTKACESponsorMaxResponse)) {
            [strongSelf fetchVideoID:videoID legacy:YES];
            return;
        }
        // Network error, rate limit, server error: report nothing, don't cache.
        [strongSelf finishVideoID:videoID segments:@[] cacheable:NO];
    }];
    [task resume];
}

@end
