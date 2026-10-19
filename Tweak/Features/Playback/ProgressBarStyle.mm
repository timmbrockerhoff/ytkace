#import "../Downloads/DownloadLog.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTKACEProgressStyleKey = @"YTKACE.Preference.Progress.Style";
static NSString * const YTKACEProgressMainColorKey = @"YTKACE.Preference.Progress.MainColor";
static NSString * const YTKACEProgressGradientColorKey = @"YTKACE.Preference.Progress.HighlightColor";
static NSString * const YTKACEProgressScrubberColorKey = @"YTKACE.Preference.Progress.ScrubberColor";

static IMP OriginalDecorationViewColor;
static IMP OriginalDecorationControllerColor;
static IMP OriginalContainerQuietColor;
static IMP OriginalScrubberDotColorV1;
static IMP OriginalScrubberDotColorV2;
static IMP OriginalSetScrubberDotColor;
static IMP OriginalSetScrubberDotColorV1;
static IMP OriginalSetScrubberDotColorV2;

static UIColor *YTKACEProgressColorFromHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:NSString.class]) return fallback;
    NSString *value = [[hex stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (value.length != 6) return fallback;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&rgb]) return fallback;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSInteger YTKACEStyleCache = -1;
static NSMutableDictionary<NSString *, UIColor *> *YTKACEPatternCache = nil;
static NSMutableDictionary<NSString *, UIImage *> *YTKACEStripCache = nil;
static NSMutableDictionary<NSString *, UIColor *> *YTKACEColorCache = nil;
static NSUInteger YTKACEProgressGeneration = 0;
static NSUInteger YTKACECachedGeneration = NSUIntegerMax;

// The thumbnail setImage: hook runs on Texture's image queues while the
// layout hooks run on main, and both read and write these caches. Unlocked
// NSMutableDictionary access from two threads crashes, so every cache access
// goes through these helpers.
static NSObject *YTKACEProgressCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static id YTKACECacheGet(NSMutableDictionary *__strong *cache, NSString *key) {
    if (key == nil) return nil;
    @synchronized (YTKACEProgressCacheLock()) {
        return (*cache)[key];
    }
}

static void YTKACECacheSet(NSMutableDictionary *__strong *cache, NSString *key,
                           id value, NSUInteger limit) {
    if (key == nil || value == nil) return;
    @synchronized (YTKACEProgressCacheLock()) {
        if (*cache == nil) *cache = [NSMutableDictionary dictionary];
        if ((*cache).count > limit) [*cache removeAllObjects];
        (*cache)[key] = value;
    }
}

static void YTKACERelayoutBars(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 14) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"PlayerBar"] ||
        [name containsString:@"MiniplayerProgressBar"] ||
        [name isEqualToString:@"YTBrandGradientView"] ||
        [name isEqualToString:@"YTGridVideoCell"]) {
        [view setNeedsLayout];
        [view setNeedsDisplay];
    }
    for (UIView *subview in view.subviews) {
        YTKACERelayoutBars(subview, depth + 1);
    }
}

static void YTKACEProgressSyncGeneration(void) {
    static dispatch_once_t observerToken;
    dispatch_once(&observerToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:YTKACEPreferencesDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            NSString *key = note.userInfo[@"key"];
            if (![key hasPrefix:@"YTKACE.Preference.Progress."]) return;
            YTKACEProgressGeneration++;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    YTKACERelayoutBars(window, 0);
                }
            }
        }];
    });
    @synchronized (YTKACEProgressCacheLock()) {
        if (YTKACECachedGeneration == YTKACEProgressGeneration) return;
        YTKACECachedGeneration = YTKACEProgressGeneration;
        YTKACEStyleCache = -1;
        YTKACEColorCache = nil;
        YTKACEPatternCache = nil;
        YTKACEStripCache = nil;
    }
}

static NSInteger YTKACEProgressStyle(void) {
    YTKACEProgressSyncGeneration();
    if (YTKACEStyleCache >= 0) return YTKACEStyleCache;
    id value = YTKACEPreferenceObject(YTKACEProgressStyleKey);
    YTKACEStyleCache =
        [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    return YTKACEStyleCache;
}

static UIColor *YTKACEStoredColor(NSString *key, UIColor *fallback) {
    YTKACEProgressSyncGeneration();
    UIColor *hit = YTKACECacheGet(&YTKACEColorCache, key);
    if (hit != nil) return hit;
    UIColor *value = YTKACEProgressColorFromHex(YTKACEPreferenceObject(key), fallback);
    YTKACECacheSet(&YTKACEColorCache, key, value, 64);
    return value;
}

static UIColor *YTKACEMainColor(void) {
    return YTKACEStoredColor(YTKACEProgressMainColorKey, UIColor.systemRedColor);
}

static UIColor *YTKACEPlayedColor(void) {
    UIColor *main = YTKACEMainColor();
    if (YTKACEProgressStyle() != 2) return main;
    UIColor *highlight = YTKACEStoredColor(YTKACEProgressGradientColorKey, main);
    static UIImage *cached = nil;
    static NSString *cachedKey = nil;
    NSString *key = [NSString stringWithFormat:@"%@|%@", main, highlight];
    if (cached == nil || ![key isEqualToString:cachedKey]) {
        CGSize size = CGSizeMake(CGRectGetWidth(UIScreen.mainScreen.bounds), 6.0);
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:size];
        cached = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
            CGFloat locations[] = {0.0, 1.0};
            CGGradientRef gradient = CGGradientCreateWithColors(
                space, (__bridge CFArrayRef)colors, locations);
            CGContextDrawLinearGradient(context.CGContext, gradient,
                                        CGPointZero, CGPointMake(size.width, 0.0), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        cachedKey = key;
    }
    return [UIColor colorWithPatternImage:cached];
}

static UIImage *YTKACEGradientStrip(CGFloat width, CGFloat height) {
    UIColor *main = YTKACEMainColor();
    UIColor *highlight = YTKACEStoredColor(YTKACEProgressGradientColorKey, main);
    NSString *stripKey = [NSString stringWithFormat:@"%.0f|%.0f|%@|%@",
                          width, height, main, highlight];
    UIImage *cachedStrip = YTKACECacheGet(&YTKACEStripCache, stripKey);
    if (cachedStrip != nil) return cachedStrip;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *strip = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient,
                                    CGPointZero, CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    YTKACECacheSet(&YTKACEStripCache, stripKey, strip, 24);
    return strip;
}

UIImage *YTKACEProgressFillImage(CGFloat width, CGFloat height) {
    if (!isfinite(width) || width <= 0.0) width = 1.0;
    if (!isfinite(height) || height <= 0.0) height = 1.0;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    NSInteger style = YTKACEProgressStyle();
    UIColor *start = nil;
    UIColor *end = nil;
    if (style == 1) {
        start = YTKACEMainColor();
        end = start;
    } else if (style == 2) {
        start = YTKACEMainColor();
        end = YTKACEStoredColor(YTKACEProgressGradientColorKey, start);
    } else {
        start = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        end = [UIColor colorWithRed:1.0 green:0.29 blue:0.16 alpha:1.0];
    }
    NSString *key = [NSString stringWithFormat:@"fill|%.0f|%.0f|%ld|%@|%@",
                     size.width, size.height, (long)style, start, end];
    UIImage *cached = YTKACECacheGet(&YTKACEStripCache, key);
    if (cached != nil) return cached;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)start.CGColor, (id)end.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero,
                                    CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    YTKACECacheSet(&YTKACEStripCache, key, image, 40);
    return image;
}

static UIView *YTKACEBarAncestor(UIView *view) {
    UIView *node = view;
    while (node != nil) {
        NSString *name = NSStringFromClass(node.class);
        if ([name isEqualToString:@"YTModularPlayerBarView"] ||
            [name isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            return node;
        }
        node = node.superview;
    }
    return view.superview ?: view;
}

static UIColor *YTKACEPlayedColorForView(id receiver) {
    if (YTKACEProgressStyle() != 2) return YTKACEMainColor();
    if (![receiver isKindOfClass:UIView.class]) return YTKACEPlayedColor();
    UIView *view = (UIView *)receiver;
    UIView *bar = YTKACEBarAncestor(view);
    CGFloat barWidth = CGRectGetWidth(bar.bounds);
    CGFloat viewWidth = CGRectGetWidth(view.bounds);
    CGFloat height = MAX(CGRectGetHeight(view.bounds), 2.0);
    if (barWidth < 2.0 || viewWidth < 1.0) return YTKACEPlayedColor();
    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0) offset = 0.0;
    if (barWidth - offset < viewWidth) barWidth = offset + viewWidth;

    NSString *patternKey = [NSString stringWithFormat:@"%.0f|%.0f|%.0f|%.0f",
                            offset, viewWidth, height, barWidth];
    UIColor *cachedPattern = YTKACECacheGet(&YTKACEPatternCache, patternKey);
    if (cachedPattern != nil) return cachedPattern;
    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *full = YTKACEGradientStrip(barWidth, height);
    CGRect crop = CGRectMake(offset * scale, 0.0,
                             viewWidth * scale, height * scale);
    CGImageRef slice = CGImageCreateWithImageInRect(full.CGImage, crop);
    if (slice == NULL) return YTKACEPlayedColor();
    UIImage *tile = [UIImage imageWithCGImage:slice
                                        scale:scale
                                  orientation:UIImageOrientationUp];
    CGImageRelease(slice);
    UIColor *pattern = [UIColor colorWithPatternImage:tile];
    YTKACECacheSet(&YTKACEPatternCache, patternKey, pattern, 96);
    return pattern;
}

static UIColor *YTKACEScrubberColor(void) {
    return YTKACEStoredColor(YTKACEProgressScrubberColorKey, YTKACEMainColor());
}

UIColor *YTKACEProgressScrubberTint(void) {
    UIColor *tint = YTKACEProgressStyle() != 0 ? YTKACEScrubberColor()
        : [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
    static NSString *logged;
    NSString *state = [NSString stringWithFormat:@"style=%ld main=%@ highlight=%@ scrubber=%@",
                       (long)YTKACEProgressStyle(), YTKACEPreferenceObject(YTKACEProgressMainColorKey),
                       YTKACEPreferenceObject(YTKACEProgressGradientColorKey),
                       YTKACEPreferenceObject(YTKACEProgressScrubberColorKey)];
    if (![state isEqualToString:logged]) {
        logged = state;
    }
    return tint;
}


static id YTKACEDecorationViewColor(id receiver, SEL selector) {
    if (YTKACEProgressStyle() != 0) return YTKACEPlayedColorForView(receiver);
    return OriginalDecorationViewColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationViewColor)(receiver, selector);
}

static id YTKACEDecorationControllerColor(id receiver, SEL selector) {
    if (YTKACEProgressStyle() != 0) return YTKACEPlayedColor();
    return OriginalDecorationControllerColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationControllerColor)(receiver, selector);
}

static id YTKACEContainerQuietColor(id receiver, SEL selector) {
    if (YTKACEProgressStyle() != 0) return YTKACEPlayedColor();
    return OriginalContainerQuietColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalContainerQuietColor)(receiver, selector);
}


static id YTKACEDotColorV1(id receiver, SEL selector) {
    if (YTKACEProgressStyle() != 0) return YTKACEScrubberColor();
    return OriginalScrubberDotColorV1 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV1)(receiver, selector);
}

static id YTKACEDotColorV2(id receiver, SEL selector) {
    if (YTKACEProgressStyle() != 0) return YTKACEScrubberColor();
    return OriginalScrubberDotColorV2 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV2)(receiver, selector);
}

static void YTKACESetDotColor(id receiver, SEL selector, id color) {
    id replacement = YTKACEProgressStyle() != 0 ? YTKACEScrubberColor() : color;
    if (OriginalSetScrubberDotColor != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColor)(receiver, selector, replacement);
    }
}

static void YTKACESetDotColorV1(id receiver, SEL selector, id color) {
    id replacement = YTKACEProgressStyle() != 0 ? YTKACEScrubberColor() : color;
    if (OriginalSetScrubberDotColorV1 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV1)(receiver, selector, replacement);
    }
}

static void YTKACESetDotColorV2(id receiver, SEL selector, id color) {
    id replacement = YTKACEProgressStyle() != 0 ? YTKACEScrubberColor() : color;
    if (OriginalSetScrubberDotColorV2 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV2)(receiver, selector, replacement);
    }
}

static IMP OriginalModularBarLayout;
static IMP OriginalDrawProgressRectWithColor;
static IMP OriginalDecorationDrawRect;
static IMP OriginalDrawProgressRect;
static IMP OriginalDrawRectDecorationProgress;
static IMP OriginalDrawRectDecoration;
static IMP OriginalSegmentedLayout;

static UIImage *YTKACEThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth);

static BOOL YTKACEColorIsYouTubeRed(CGColorRef color) {
    if (color == NULL) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    if (components == NULL || CGColorGetNumberOfComponents(color) < 3) return NO;
    return components[0] > 0.6 && components[1] < 0.4 && components[2] < 0.4;
}

static void YTKACEApplyLayerFill(CALayer *layer, UIColor *colour,
                                 CGFloat width, CGFloat height) {
    if (colour == nil) return;
    CGColorRef reference = colour.CGColor;
    if (CGColorGetPattern(reference) == NULL) {
        layer.backgroundColor = reference;
        return;
    }
    CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
    if (track < width) track = width;
    UIImage *fill = YTKACEThumbBarImage(width, height, track);
    layer.backgroundColor = YTKACEMainColor().CGColor;
    if (fill.CGImage != NULL) {
        layer.contents = (__bridge id)fill.CGImage;
        layer.contentsScale = fill.scale;
        layer.contentsGravity = kCAGravityResize;
    }
}

static void YTKACEPaintLayers(CALayer *layer, UIColor *played, UIColor *dot,
                              NSUInteger depth) {
    if (layer == nil || depth > 7) return;
    CGRect bounds = layer.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width > 0.0 && height > 0.0 && YTKACEColorIsYouTubeRed(layer.backgroundColor)) {
        YTKACEApplyLayerFill(layer, (width <= height + 2.0) ? dot : played,
                             width, height);
    }
    for (CALayer *sublayer in layer.sublayers) {
        YTKACEPaintLayers(sublayer, played, dot, depth + 1);
    }
}

static void YTKACEModularBarLayout(UIView *receiver, SEL selector) {
    if (OriginalModularBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalModularBarLayout)(receiver, selector);
    }
    if (YTKACEProgressStyle() == 0) return;
    YTKACEPaintLayers(receiver.layer, YTKACEPlayedColor(), YTKACEScrubberColor(), 0);
    UIView *node = receiver;
    while (node != nil) {
        if ([NSStringFromClass(node.class)
                isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
            if ([node respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, setter, YTKACEPlayedColor());
            }
            YTKACEPaintLayers(node.layer, YTKACEPlayedColor(), YTKACEScrubberColor(), 0);
            break;
        }
        node = node.superview;
    }
}

static BOOL YTKACEDrawGradientInRect(id receiver, CGRect rect) {
    if (YTKACEProgressStyle() != 2) return NO;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL || ![receiver isKindOfClass:UIView.class]) return NO;
    CGFloat height = CGRectGetHeight(rect);
    if (height < 0.5 || CGRectGetWidth(rect) < 0.5) return NO;

    UIView *view = (UIView *)receiver;
    UIView *bar = YTKACEBarAncestor(view);
    CGFloat track = CGRectGetWidth(bar.bounds);
    CGFloat own = CGRectGetWidth(view.bounds);
    if (track < own) track = own;
    if (track < 2.0) return NO;

    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0 || offset > track) offset = 0.0;

    UIImage *strip = YTKACEGradientStrip(track, height);
    if (strip == nil) return NO;

    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    [strip drawInRect:CGRectMake(-offset, CGRectGetMinY(rect), track, height)];
    CGContextRestoreGState(context);
    return YES;
}

static void YTKACEDrawProgressRectWithColor(id receiver, SEL selector,
                                            CGRect rect, id color) {
    if (YTKACEDrawGradientInRect(receiver, rect)) return;
    id replacement = YTKACEProgressStyle() != 0 ? YTKACEMainColor() : color;
    if (OriginalDrawProgressRectWithColor != NULL) {
        ((void (*)(id, SEL, CGRect, id))OriginalDrawProgressRectWithColor)(
            receiver, selector, rect, replacement);
    }
}

static void YTKACEForceBarColor(id receiver) {
    if (YTKACEProgressStyle() == 0) return;
    SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
    if (![receiver respondsToSelector:setter]) return;
    UIColor *colour = YTKACEPlayedColorForView(receiver);
    if (CGColorGetPattern(colour.CGColor) != NULL) {
        colour = YTKACEMainColor();
    }
    ((void (*)(id, SEL, id))objc_msgSend)(receiver, setter, colour);
}

static void YTKACEDecorationDrawRect(id receiver, SEL selector, CGRect rect) {
    YTKACEForceBarColor(receiver);
    if (OriginalDecorationDrawRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDecorationDrawRect)(receiver, selector, rect);
    }
}

static void YTKACERecolorSegments(id receiver) {
    if (YTKACEProgressStyle() == 0) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    YTKACEPaintLayers(((UIView *)receiver).layer,
                      YTKACEPlayedColor(), YTKACEScrubberColor(), 0);
    SEL segments = NSSelectorFromString(@"segmentViews");
    if (![receiver respondsToSelector:segments]) return;
    NSArray *views = ((id (*)(id, SEL))objc_msgSend)(receiver, segments);
    if (![views isKindOfClass:NSArray.class]) return;
    for (id view in views) {
        if ([view isKindOfClass:UIView.class]) {
            YTKACEPaintLayers(((UIView *)view).layer,
                              YTKACEPlayedColor(), YTKACEScrubberColor(), 0);
        }
    }
}


static void YTKACESegmentedLayout(id receiver, SEL selector) {
    if (OriginalSegmentedLayout != NULL) {
        ((void (*)(id, SEL))OriginalSegmentedLayout)(receiver, selector);
    }
    YTKACERecolorSegments(receiver);
}


static void YTKACEDrawProgressRect(id receiver, SEL selector, CGRect rect) {
    if (YTKACEDrawGradientInRect(receiver, rect)) return;
    YTKACEForceBarColor(receiver);
    if (OriginalDrawProgressRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawProgressRect)(receiver, selector, rect);
    }
}

static void YTKACEDrawRectDecorationProgress(id receiver, SEL selector, CGRect rect) {
    YTKACEForceBarColor(receiver);
    if (OriginalDrawRectDecorationProgress != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecorationProgress)(
            receiver, selector, rect);
    }
}

static void YTKACEDrawRectDecoration(id receiver, SEL selector, CGRect rect) {
    YTKACEForceBarColor(receiver);
    if (OriginalDrawRectDecoration != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecoration)(receiver, selector, rect);
    }
}

static UIView *YTKACEFindProgressView(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return nil;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTProgressView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = YTKACEFindProgressView(subview, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

void YTKACEStyleProgressLayer(CALayer *layer, CGFloat trackWidth) {
    if (layer == nil) return;
    if (YTKACEProgressStyle() == 0) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (width < 1.0 || height < 1.0) return;
    if (trackWidth < width) trackWidth = width;
    if (YTKACEProgressStyle() == 2) {
        UIImage *fill = YTKACEThumbBarImage(width, height, trackWidth);
        layer.backgroundColor = YTKACEMainColor().CGColor;
        if (fill.CGImage != NULL) {
            layer.contents = (__bridge id)fill.CGImage;
            layer.contentsScale = fill.scale;
            layer.contentsGravity = kCAGravityResize;
        }
    } else {
        layer.contents = nil;
        layer.backgroundColor = YTKACEMainColor().CGColor;
    }
}

void YTKACEApplyProgressStyleToBar(UIView *bar) {
    if (YTKACEProgressStyle() == 0 || ![bar isKindOfClass:UIView.class]) return;
    UIView *progress = YTKACEFindProgressView(bar, 0);
    if (progress == nil) return;

    SEL brand = NSSelectorFromString(@"setBrandGradientEnabled:");
    if ([progress respondsToSelector:brand]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(progress, brand, NO);
    }

    UIColor *color = YTKACEMainColor();
    CGFloat width = CGRectGetWidth(bar.bounds);
    CGFloat height = MAX(CGRectGetHeight(progress.bounds), 2.0);
    if (YTKACEProgressStyle() == 2 && width > 2.0) {
        color = [UIColor colorWithPatternImage:YTKACEGradientStrip(width, height)];
    }
    SEL setter = NSSelectorFromString(@"setProgressBarColor:");
    if ([progress respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(progress, setter, color);
    }
    YTKACEPaintLayers(progress.layer, color, YTKACEScrubberColor(), 0);
}

static IMP OriginalThumbBarLayout;
static IMP OriginalThumbContainerLayout;
static const void *YTKACEThumbBarFillAssociation = &YTKACEThumbBarFillAssociation;
static const void *YTKACEThumbBarGenerationAssociation =
    &YTKACEThumbBarGenerationAssociation;

static const void *YTKACEThumbGeneratedAssociation =
    &YTKACEThumbGeneratedAssociation;
static const void *YTKACEBarTouchedAssociation = &YTKACEBarTouchedAssociation;

static CGFloat YTKACEThumbTrackWidth(id node, CGFloat fillWidth,
                                     CGFloat fillHeight) {
    CGFloat track = fillWidth;
    SEL supernode = NSSelectorFromString(@"supernode");
    id parent = node;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        if (![parent respondsToSelector:supernode]) break;
        parent = ((id (*)(id, SEL))objc_msgSend)(parent, supernode);
        if (parent == nil) break;
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            parent, NSSelectorFromString(@"bounds"));
        if (fabs(CGRectGetHeight(bounds) - fillHeight) > 1.5) continue;
        if (CGRectGetWidth(bounds) > track) track = CGRectGetWidth(bounds);
    }
    return track;
}

static UIImage *YTKACEThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth) {
    if (YTKACEProgressStyle() == 2) {
        if (trackWidth <= width + 1.0) return YTKACEGradientStrip(width, height);
        NSString *sliceKey = [NSString stringWithFormat:@"thumb|%.0f|%.0f|%.0f|%@|%@",
                              width, height, trackWidth, YTKACEMainColor(),
                              YTKACEStoredColor(YTKACEProgressGradientColorKey,
                                                YTKACEMainColor())];
        UIImage *cachedSlice = YTKACECacheGet(&YTKACEStripCache, sliceKey);
        if (cachedSlice != nil) return cachedSlice;
        UIImage *full = YTKACEGradientStrip(trackWidth, height);
        CGFloat scale = full.scale;
        CGImageRef cropped = CGImageCreateWithImageInRect(
            full.CGImage, CGRectMake(0.0, 0.0, width * scale, height * scale));
        if (cropped == NULL) return YTKACEGradientStrip(width, height);
        UIImage *slice = [UIImage imageWithCGImage:cropped
                                             scale:scale
                                       orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        objc_setAssociatedObject(slice, YTKACEThumbGeneratedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACECacheSet(&YTKACEStripCache, sliceKey, slice, 24);
        return slice;
    }
    UIColor *main = YTKACEMainColor();
    NSString *key = [NSString stringWithFormat:@"solid|%.0f|%.0f|%@",
                     width, height, main];
    UIImage *cached = YTKACECacheGet(&YTKACEStripCache, key);
    if (cached != nil) return cached;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        [main setFill];
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        [[UIBezierPath bezierPathWithRoundedRect:rect
                                    cornerRadius:size.height / 2.0] fill];
        (void)context;
    }];
    objc_setAssociatedObject(image, YTKACEThumbGeneratedAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACECacheSet(&YTKACEStripCache, key, image, 24);
    return image;
}

static void YTKACEThumbBarApply(id node) {
    if (YTKACEProgressStyle() == 0) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
        node, NSSelectorFromString(@"bounds"));
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    NSString *name = NSStringFromClass([node class]);
    SEL imageGetter = NSSelectorFromString(@"image");
    SEL imageSetter = NSSelectorFromString(@"setImage:");
    UIImage *current = [node respondsToSelector:imageGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, imageGetter) : nil;

    if (height < 1.0 || height > 4.0 || width < 8.0) return;
    if (![name isEqualToString:@"ELMImageNode"]) return;
    if (![node respondsToSelector:imageSetter]) return;
    if (current == nil) return;

    BOOL ours = objc_getAssociatedObject(
        current, YTKACEThumbGeneratedAssociation) != nil;
    NSNumber *appliedWidth = objc_getAssociatedObject(
        node, YTKACEThumbBarFillAssociation);
    NSNumber *applied = objc_getAssociatedObject(
        node, YTKACEThumbBarGenerationAssociation);
    if (ours && applied != nil &&
        applied.unsignedIntegerValue == YTKACEProgressGeneration &&
        appliedWidth != nil &&
        fabs(appliedWidth.doubleValue - width) < 1.0) return;

    UIImage *replacement = YTKACEThumbBarImage(
        width, height, YTKACEThumbTrackWidth(node, width, height));
    if (current == replacement) return;

    SEL modifier = NSSelectorFromString(@"imageModificationBlock");
    SEL setModifier = NSSelectorFromString(@"setImageModificationBlock:");
    BOOL hadModifier = NO;
    if ([node respondsToSelector:modifier]) {
        hadModifier = ((id (*)(id, SEL))objc_msgSend)(node, modifier) != nil;
    }
    if (hadModifier && [node respondsToSelector:setModifier]) {
        ((void (*)(id, SEL, id))objc_msgSend)(node, setModifier, nil);
    }
    SEL setTint = NSSelectorFromString(@"setTintColor:");
    if ([node respondsToSelector:NSSelectorFromString(@"tintColor")] &&
        [node respondsToSelector:setTint]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            node, setTint, YTKACEProgressStyle() == 2
                ? YTKACEStoredColor(YTKACEProgressGradientColorKey,
                                    YTKACEMainColor())
                : YTKACEMainColor());
    }

    ((void (*)(id, SEL, id))objc_msgSend)(node, imageSetter, replacement);
    SEL redisplay = NSSelectorFromString(@"setNeedsDisplay");
    if ([node respondsToSelector:redisplay]) {
        __weak id weakNode = node;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongNode = weakNode;
            if (strongNode == nil) return;
            UIImage *shown = ((id (*)(id, SEL))objc_msgSend)(
                strongNode, NSSelectorFromString(@"image"));
            if (objc_getAssociatedObject(
                    shown, YTKACEThumbGeneratedAssociation) == nil) return;
            ((void (*)(id, SEL))objc_msgSend)(strongNode, redisplay);
        });
    }
    objc_setAssociatedObject(node, YTKACEThumbBarFillAssociation, @(width),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, YTKACEThumbBarGenerationAssociation,
                             @(YTKACEProgressGeneration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

}

static void YTKACEThumbBarLayout(id node, SEL selector) {
    if (OriginalThumbBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbBarLayout)(node, selector);
    }
    YTKACEThumbBarApply(node);
}

static IMP OriginalThumbVisible;
static IMP OriginalThumbDisplayWillStart;

static void YTKACEThumbDisplayWillStart(id node, SEL selector) {
    if (OriginalThumbDisplayWillStart != NULL) {
        ((void (*)(id, SEL))OriginalThumbDisplayWillStart)(node, selector);
    }
    YTKACEThumbBarApply(node);
}

static void YTKACEThumbDidEnterVisible(id node, SEL selector) {
    if (OriginalThumbVisible != NULL) {
        ((void (*)(id, SEL))OriginalThumbVisible)(node, selector);
    }
    YTKACEThumbBarApply(node);
}

static void YTKACEThumbContainerLayout(id node, SEL selector) {
    if (OriginalThumbContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbContainerLayout)(node, selector);
    }
    YTKACEThumbBarApply(node);
}

static IMP OriginalInlineScrubberLayout;
static IMP OriginalInlinePostScrubberLayout;

static void YTKACETintInlineSliders(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return;
    if ([view isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)view;
        UIColor *dot = YTKACEScrubberColor();
        UIImage *thumb = [slider thumbImageForState:UIControlStateNormal];
        if (thumb == nil) {
            if (CGColorGetPattern(dot.CGColor) == NULL) slider.thumbTintColor = dot;
        } else {
            if (thumb.renderingMode != UIImageRenderingModeAlwaysTemplate) {
                [slider setThumbImage:
                    [thumb imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                             forState:UIControlStateNormal];
            }
            slider.tintColor = dot;
        }
        UIColor *played = YTKACEMainColor();
        if (CGColorGetPattern(played.CGColor) == NULL) {
            slider.minimumTrackTintColor = played;
        }
    }
    for (UIView *subview in view.subviews) {
        YTKACETintInlineSliders(subview, depth + 1);
    }
}

static void YTKACEInlineScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlineScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlineScrubberLayout)(receiver, selector);
    }
    if (YTKACEProgressStyle() == 0) return;
    YTKACETintInlineSliders(receiver, 0);
}

static void YTKACEInlinePostScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlinePostScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlinePostScrubberLayout)(receiver, selector);
    }
    if (YTKACEProgressStyle() == 0) return;
    YTKACETintInlineSliders(receiver, 0);
}

static NSUInteger YTKACEInstallProgressHookSet(void) {
    NSUInteger landed = 0;
    struct { const char *cls; const char *sel; IMP replacement; IMP *storage; } entries[] = {
        {"YTPlayerBarProgressDecorationView", "playedProgressBarColor",
         (IMP)YTKACEDecorationViewColor, &OriginalDecorationViewColor},
        {"YTPlayerBarProgressDecorationController", "playedProgressBarColor",
         (IMP)YTKACEDecorationControllerColor, &OriginalDecorationControllerColor},
        {"YTInlinePlayerBarContainerView", "quietProgressBarColor",
         (IMP)YTKACEContainerQuietColor, &OriginalContainerQuietColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "scrubberDotColor",
         (IMP)YTKACEDotColorV1, &OriginalScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "scrubberDotColor",
         (IMP)YTKACEDotColorV2, &OriginalScrubberDotColorV2},
        {"YTPlayerBarScrubberDotDecorationView", "setScrubberDotColor:",
         (IMP)YTKACESetDotColor, &OriginalSetScrubberDotColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "setScrubberDotColor:",
         (IMP)YTKACESetDotColorV1, &OriginalSetScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "setScrubberDotColor:",
         (IMP)YTKACESetDotColorV2, &OriginalSetScrubberDotColorV2},
        {"YTModularPlayerBarView", "layoutSubviews",
         (IMP)YTKACEModularBarLayout, &OriginalModularBarLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:withColor:",
         (IMP)YTKACEDrawProgressRectWithColor, &OriginalDrawProgressRectWithColor},
        {"YTPlayerBarProgressDecorationView", "drawRect:",
         (IMP)YTKACEDecorationDrawRect, &OriginalDecorationDrawRect},
        {"YTPlayerBarScrubberDotDecorationViewV1", "layoutSubviews",
         (IMP)YTKACESegmentedLayout, &OriginalSegmentedLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:",
         (IMP)YTKACEDrawProgressRect, &OriginalDrawProgressRect},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecorationWithProgress:",
         (IMP)YTKACEDrawRectDecorationProgress, &OriginalDrawRectDecorationProgress},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecoration:",
         (IMP)YTKACEDrawRectDecoration, &OriginalDrawRectDecoration},
        {"YTInlineMutedPlaybackScrubberView", "layoutSubviews",
         (IMP)YTKACEInlineScrubberLayout, &OriginalInlineScrubberLayout},
        {"YTInlineMutedPlaybackPostVideoScrubberView", "layoutSubviews",
         (IMP)YTKACEInlinePostScrubberLayout, &OriginalInlinePostScrubberLayout}
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        NSString *cls = @(entries[i].cls);
        NSString *sel = @(entries[i].sel);
        BOOL ok = YTKACEInstallInstanceHook(cls, sel, entries[i].replacement,
                                            entries[i].storage);
        if (ok) landed++;
    }
    return landed;
}

static BOOL YTKACECGImageIsRed(CGImageRef bitmap) {
    if (bitmap == NULL) return NO;
    size_t pixelWidth = CGImageGetWidth(bitmap);
    size_t pixelHeight = CGImageGetHeight(bitmap);
    if (pixelWidth == 0 || pixelHeight == 0) return NO;
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixel, 1, 1, 8, 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return NO;
    CGContextDrawImage(context,
                       CGRectMake(-(CGFloat)(pixelWidth / 2),
                                  -(CGFloat)(pixelHeight / 2),
                                  (CGFloat)pixelWidth, (CGFloat)pixelHeight),
                       bitmap);
    CGContextRelease(context);
    return pixel[3] > 100 && pixel[0] > 120 &&
           pixel[1] < 100 && pixel[2] < 100;
}

static BOOL YTKACEColourIsRed(CGColorRef colour) {
    if (colour == NULL) return NO;
    size_t count = CGColorGetNumberOfComponents(colour);
    const CGFloat *parts = CGColorGetComponents(colour);
    if (parts == NULL || count < 4) return NO;
    return parts[3] > 0.4 && parts[0] > 0.5 && parts[1] < 0.4 && parts[2] < 0.4;
}

static void YTKACERecolourRedBars(CALayer *layer, NSUInteger depth,
                                  UIView *host, NSString *trail) {
    if (layer == nil || depth > 8) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (height >= 1.0 && height <= 6.0 && width >= 6.0) {
        BOOL redBackground = YTKACEColourIsRed(layer.backgroundColor);
        CGImageRef drawn = (__bridge CGImageRef)layer.contents;
        BOOL redContents = drawn != NULL &&
            CFGetTypeID(drawn) == CGImageGetTypeID() &&
            YTKACECGImageIsRed(drawn);
        NSNumber *touched = objc_getAssociatedObject(
            layer, YTKACEBarTouchedAssociation);
        BOOL stale = touched != nil &&
            touched.unsignedIntegerValue != YTKACEProgressGeneration;
        if (redBackground || redContents || stale) {
            CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
            if (track < width) track = width;
            UIImage *fill = YTKACEThumbBarImage(width, height, track);
            layer.backgroundColor = YTKACEMainColor().CGColor;
            layer.cornerRadius = height / 2.0;
            if (YTKACEProgressStyle() == 2 && fill.CGImage != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
                layer.contentsGravity = kCAGravityResize;
            } else if (fill.CGImage != NULL && layer.contents != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
            }
            if (host != nil && host.layer == layer) {
                host.backgroundColor = YTKACEMainColor();
            }
            objc_setAssociatedObject(layer, YTKACEBarTouchedAssociation,
                                     @(YTKACEProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (CALayer *sublayer in layer.sublayers) {
        YTKACERecolourRedBars(sublayer, depth + 1, host, trail);
    }
}

static IMP OriginalThumbSetImage;

static void YTKACEThumbSetImage(id node, SEL selector, UIImage *image) {
    UIImage *use = image;
    if (image != nil && YTKACEProgressStyle() != 0 &&
        objc_getAssociatedObject(image, YTKACEThumbGeneratedAssociation) == nil) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            node, NSSelectorFromString(@"bounds"));
        CGFloat width = CGRectGetWidth(bounds);
        CGFloat height = CGRectGetHeight(bounds);
        if (width < 1.0 || height < 1.0) {
            CGFloat scale = image.scale > 0.0 ? image.scale : 1.0;
            width = image.size.width / (scale > 1.0 ? 1.0 : 2.0);
            height = image.size.height / (scale > 1.0 ? 1.0 : 2.0);
        }
        if (height >= 1.0 && height <= 4.0 && width >= 8.0) {
            use = YTKACEThumbBarImage(
                width, height, YTKACEThumbTrackWidth(node, width, height));
        }
    }
    if (OriginalThumbSetImage != NULL) {
        ((void (*)(id, SEL, id))OriginalThumbSetImage)(node, selector, use);
    }
}

static IMP OriginalGridCellLayout;
static IMP OriginalBrandGradientDraw;

static void YTKACEBrandGradientDraw(UIView *receiver, SEL selector, CGRect rect) {
    CGRect bounds = receiver.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGContextRef context = UIGraphicsGetCurrentContext();
    BOOL eligible = YTKACEProgressStyle() != 0 && context != NULL &&
                    height >= 1.0 && height <= 6.0 && width >= 4.0;

    if (!eligible) {
        if (OriginalBrandGradientDraw != NULL) {
            ((void (*)(id, SEL, CGRect))OriginalBrandGradientDraw)(
                receiver, selector, rect);
        }
        return;
    }
    CGFloat track = width;
    UIView *ancestor = receiver.superview;
    for (NSUInteger level = 0; ancestor != nil && level < 5; level++) {
        CGFloat ancestorHeight = CGRectGetHeight(ancestor.bounds);
        CGFloat ancestorWidth = CGRectGetWidth(ancestor.bounds);
        if (ancestorHeight <= 10.0 && ancestorWidth > track) {
            track = ancestorWidth;
        }
        ancestor = ancestor.superview;
    }
    UIImage *fill = YTKACEThumbBarImage(width, height, track);
    [fill drawInRect:bounds];
}

static void YTKACERefreshBrandGradients(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        NSNumber *drawn = objc_getAssociatedObject(
            view, YTKACEBarTouchedAssociation);
        if (drawn == nil ||
            drawn.unsignedIntegerValue != YTKACEProgressGeneration) {
            objc_setAssociatedObject(view, YTKACEBarTouchedAssociation,
                                     @(YTKACEProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view setNeedsDisplay];
        }
        return;
    }
    for (UIView *subview in view.subviews) {
        YTKACERefreshBrandGradients(subview, depth + 1);
    }
}

static BOOL YTKACEHasBrandGradient(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return NO;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if (YTKACEHasBrandGradient(subview, depth + 1)) return YES;
    }
    return NO;
}

static void YTKACEGridCellLayout(UIView *receiver, SEL selector) {
    if (OriginalGridCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalGridCellLayout)(receiver, selector);
    }
    if (YTKACEProgressStyle() == 0) return;
    BOOL brand = YTKACEHasBrandGradient(receiver, 0);
    if (brand) {
        YTKACERefreshBrandGradients(receiver, 0);
        return;
    }
    YTKACERecolourRedBars(receiver.layer, 0, receiver,
                          NSStringFromClass(receiver.class));
}

void YTKACEInstallProgressBarHooks(void) {
    static dispatch_once_t sweepToken;
    dispatch_once(&sweepToken, ^{
        BOOL grid = YTKACEInstallInstanceHook(@"YTGridVideoCell", @"layoutSubviews",
                                              (IMP)YTKACEGridCellLayout,
                                              &OriginalGridCellLayout);
        BOOL brand = YTKACEInstallInstanceHook(@"YTBrandGradientView", @"drawRect:",
                                               (IMP)YTKACEBrandGradientDraw,
                                               &OriginalBrandGradientDraw);
        (void)grid;
        (void)brand;
    });
    static dispatch_once_t thumbToken;
    dispatch_once(&thumbToken, ^{
        BOOL image = YTKACEInstallInstanceHook(@"ELMImageNode", @"layoutDidFinish",
                                               (IMP)YTKACEThumbBarLayout,
                                               &OriginalThumbBarLayout);
        BOOL container = YTKACEInstallInstanceHook(@"ELMContainerNode",
                                                   @"layoutDidFinish",
                                                   (IMP)YTKACEThumbContainerLayout,
                                                   &OriginalThumbContainerLayout);
        YTKACEInstallInstanceHook(@"ELMImageNode", @"displayWillStart",
                                  (IMP)YTKACEThumbDisplayWillStart,
                                  &OriginalThumbDisplayWillStart);
        YTKACEInstallInstanceHook(@"ELMImageNode", @"didEnterVisibleState",
                                  (IMP)YTKACEThumbDidEnterVisible,
                                  &OriginalThumbVisible);
        YTKACEInstallInstanceHook(@"ELMImageNode", @"setImage:",
                                  (IMP)YTKACEThumbSetImage,
                                  &OriginalThumbSetImage);
        (void)image;
        (void)container;
    });
    static NSUInteger attempt = 0;
    NSUInteger landed = YTKACEInstallProgressHookSet();
    attempt++;
    if (landed >= 15 || attempt >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTKACEInstallProgressBarHooks();
    });
}
