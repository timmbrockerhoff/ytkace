#import "MediaArtwork.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import <math.h>

NSData *YTKACEMediaArtworkData(NSURL *URL) {
    NSURL *base = URL.URLByDeletingPathExtension;
    for (NSString *extension in @[@"jpg", @"png"]) {
        NSData *data = [NSData dataWithContentsOfURL:
            [base URLByAppendingPathExtension:extension]];
        if (data.length != 0) return data;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
    NSArray<AVMetadataItem *> *items = [AVMetadataItem
        metadataItemsFromArray:asset.commonMetadata
        filteredByIdentifier:AVMetadataCommonIdentifierArtwork];
    id value = items.firstObject.value;
    if ([value isKindOfClass:NSData.class]) return value;
    if ([value respondsToSelector:@selector(dataValue)]) return [value dataValue];
    return nil;
}

// Decoded artwork keyed by URL and pixel size. Callers (now-playing info, the mini player, the
// audio player) ask for the same file over and over; without this every call re-read the file or
// asset metadata and decoded the full image on the main thread.
static NSCache<NSString *, NSArray *> *YTKACEMediaArtworkCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.name = @"com.ytkace.media-artwork";
        cache.totalCostLimit = 24 * 1024 * 1024;
        cache.countLimit = 64;
    });
    return cache;
}

// Cheap identity of the media file and its artwork sidecars (three stat calls), so a cached entry
// is dropped when artwork gets embedded into the file or a sidecar image appears or changes.
static NSString *YTKACEMediaArtworkSignature(NSURL *URL) {
    if (!URL.isFileURL) return @"";
    NSURL *base = URL.URLByDeletingPathExtension;
    NSMutableString *signature = [NSMutableString string];
    for (NSURL *candidate in @[URL,
                               [base URLByAppendingPathExtension:@"jpg"],
                               [base URLByAppendingPathExtension:@"png"]]) {
        const char *path = candidate.fileSystemRepresentation;
        struct stat info;
        if (path != NULL && stat(path, &info) == 0) {
            [signature appendFormat:@"%lld.%ld:%lld|",
                (long long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec,
                (long long)info.st_size];
        } else {
            [signature appendString:@"-|"];
        }
    }
    return signature;
}

static UIImage *YTKACEDownsampledArtwork(NSData *data, NSUInteger maxPixelSize) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (source == NULL) return nil;
    NSUInteger limit = maxPixelSize;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    if (width != 0 && height != 0) limit = MIN(limit, MAX(width, height));
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(limit, (NSUInteger)1))
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0,
        (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (image == NULL) return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

UIImage *YTKACEMediaArtworkImageWithMaxPixelSize(NSURL *URL, CGFloat maxPixelSize) {
    if (URL == nil) return nil;
    NSUInteger pixels = isfinite(maxPixelSize) && maxPixelSize > 1.0
        ? (NSUInteger)ceil(maxPixelSize) : 1;
    NSString *key = [NSString stringWithFormat:@"%lu|%@",
        (unsigned long)pixels, URL.absoluteString];
    NSString *signature = YTKACEMediaArtworkSignature(URL);
    NSCache<NSString *, NSArray *> *cache = YTKACEMediaArtworkCache();
    NSArray *entry = [cache objectForKey:key];
    if (entry.count == 2 && [entry[0] isEqualToString:signature]) {
        id cached = entry[1];
        return [cached isKindOfClass:UIImage.class] ? cached : nil;
    }
    NSData *data = YTKACEMediaArtworkData(URL);
    UIImage *image = nil;
    if (data.length != 0) {
        image = YTKACEDownsampledArtwork(data, pixels);
        if (image == nil) image = [UIImage imageWithData:data];
    }
    CGImageRef cgImage = image.CGImage;
    NSUInteger cost = cgImage != NULL
        ? CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage) : 64;
    [cache setObject:@[signature, image ?: (id)NSNull.null] forKey:key cost:cost];
    return image;
}

UIImage *YTKACEMediaArtworkImage(NSURL *URL) {
    return YTKACEMediaArtworkImageWithMaxPixelSize(URL, 1280.0);
}
