#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSData * _Nullable YTKACEMediaArtworkData(NSURL *URL);
// Artwork downsampled to at most 1280 px on the long side. Results are cached per file and
// revalidated against the file's and sidecars' modification times, so repeated calls are cheap.
// Safe to call from any thread.
FOUNDATION_EXPORT UIImage * _Nullable YTKACEMediaArtworkImage(NSURL *URL);
FOUNDATION_EXPORT UIImage * _Nullable YTKACEMediaArtworkImageWithMaxPixelSize(
    NSURL *URL, CGFloat maxPixelSize);

NS_ASSUME_NONNULL_END
