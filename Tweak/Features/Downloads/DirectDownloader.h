#import <Foundation/Foundation.h>
#import "SABRDownloader.h"

@class YTKACEStreamOption;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTKACEDownloadMethodKey;
FOUNDATION_EXPORT BOOL YTKACEDirectDownloadsEnabled(void);
FOUNDATION_EXPORT BOOL YTKACETVDownloadsEnabled(void);
// YES when the scratch volume has room for `requiredBytes` (or its capacity is unknown).
FOUNDATION_EXPORT BOOL YTKACEDownloadHasFreeSpace(int64_t requiredBytes);
// Error for a full disk / failed write; `underlying` is the write error, nil for a pre-check.
FOUNDATION_EXPORT NSError *YTKACEDownloadStorageError(NSError * _Nullable underlying);
// Exponential backoff (base * 2^(attempt-1), capped) with +/-25% jitter, raised to
// Retry-After (capped at 60 s) when the server sent one.
FOUNDATION_EXPORT NSTimeInterval YTKACEDownloadRetryDelay(NSInteger attempt, NSTimeInterval base,
                                                          NSTimeInterval cap,
                                                          NSTimeInterval retryAfter);

@interface YTKACEDirectTask : NSObject
- (void)cancel;
@end

@interface YTKACEDirectDownloader : NSObject

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<YTKACEStreamOption *> *options))completion;
+ (NSString *)codecNameForOption:(YTKACEStreamOption *)option;

+ (YTKACEDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(nullable YTKACEStreamOption *)videoOption
                          audioOption:(YTKACEStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(nullable YTKACESABRProgress)progress
                           completion:(YTKACESABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END
