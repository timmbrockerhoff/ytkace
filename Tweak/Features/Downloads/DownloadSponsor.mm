#import "DownloadSponsor.h"
#import "../../Runtime/Preferences.h"
#import "../SponsorBlock/SponsorClient.h"
#import "../SponsorBlock/SponsorPreferences.h"

#import <sys/xattr.h>

static const char *YTKACESponsorAttribute = "com.ytkace.sponsorblock";

NSNotificationName const YTKACEDownloadInfoDidChangeNotification =
    @"YTKACEDownloadInfoDidChangeNotification";

static NSArray<NSString *> *YTKACEAllSponsorCategories(void) {
    NSMutableArray<NSString *> *categories = [NSMutableArray array];
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        if ([definition[@"id"] isKindOfClass:NSString.class]) {
            [categories addObject:definition[@"id"]];
        }
    }
    return categories;
}

static NSDictionary *YTKACEReadSponsorRecord(NSURL *fileURL) {
    const char *path = fileURL.fileSystemRepresentation;
    if (path == NULL) return nil;
    ssize_t length = getxattr(path, YTKACESponsorAttribute, NULL, 0, 0, 0);
    if (length <= 0 || length > 256 * 1024) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    if (getxattr(path, YTKACESponsorAttribute, data.mutableBytes,
                 (size_t)length, 0, 0) != length) {
        return nil;
    }
    id record = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}

static void YTKACEWriteSponsorRecord(NSURL *fileURL, NSString *videoID,
                                     NSString *author, NSArray *segments) {
    const char *path = fileURL.fileSystemRepresentation;
    if (path == NULL || videoID.length == 0) return;
    NSMutableDictionary *record = [@{@"id": videoID, @"segments": segments ?: @[]} mutableCopy];
    if (author.length != 0) record[@"author"] = author;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (data.length == 0) return;
    setxattr(path, YTKACESponsorAttribute, data.bytes, data.length, 0, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTKACEDownloadInfoDidChangeNotification object:fileURL];
    });
}

static NSArray *YTKACEValidSegments(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *segments = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id start = item[@"start"];
        id end = item[@"end"];
        id category = item[@"category"];
        if (![start isKindOfClass:NSNumber.class] || ![end isKindOfClass:NSNumber.class] ||
            ![category isKindOfClass:NSString.class] ||
            [end doubleValue] <= [start doubleValue]) {
            continue;
        }
        [segments addObject:@{@"start": start, @"end": end, @"category": category}];
    }
    return segments;
}

void YTKACEAttachSponsorSegments(NSURL *fileURL, NSString *videoID, NSString *author) {
    if (fileURL == nil || videoID.length == 0) return;
    NSURL *target = fileURL.copy;
    NSString *channel = author.copy;
    YTKACEWriteSponsorRecord(target, videoID, channel, @[]);
    if (!YTKACESponsorBlockEnabled()) return;
    [YTKACESponsorClient.sharedClient segmentsForVideoID:videoID
        categories:YTKACEAllSponsorCategories()
        completion:^(NSArray<NSDictionary<NSString *, id> *> *segments) {
            YTKACEWriteSponsorRecord(target, videoID, channel, segments);
        }];
}

NSString *YTKACEStoredChannelName(NSURL *fileURL) {
    if (fileURL == nil) return nil;
    id author = YTKACEReadSponsorRecord(fileURL)[@"author"];
    return [author isKindOfClass:NSString.class] && [author length] != 0 ? author : nil;
}

NSArray<NSDictionary<NSString *, id> *> *YTKACEStoredSponsorSegments(NSURL *fileURL) {
    if (fileURL == nil) return @[];
    return YTKACEValidSegments(YTKACEReadSponsorRecord(fileURL)[@"segments"]);
}

void YTKACERefreshSponsorSegments(
    NSURL *fileURL, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *segments)) {
    NSDictionary *record = fileURL == nil ? nil : YTKACEReadSponsorRecord(fileURL);
    NSString *videoID = [record[@"id"] isKindOfClass:NSString.class] ? record[@"id"] : nil;
    NSString *author = [record[@"author"] isKindOfClass:NSString.class] ? record[@"author"] : nil;
    if (videoID.length == 0 || !YTKACESponsorBlockEnabled()) return;
    NSURL *target = fileURL.copy;
    [YTKACESponsorClient.sharedClient segmentsForVideoID:videoID
        categories:YTKACEAllSponsorCategories()
        completion:^(NSArray<NSDictionary<NSString *, id> *> *segments) {
            if (segments.count == 0) return;
            YTKACEWriteSponsorRecord(target, videoID, author, segments);
            if (completion != nil) completion(YTKACEValidSegments(segments));
        }];
}
