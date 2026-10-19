#import "DownloadProgressView.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "DownloadLog.h"

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

@interface YTKACEDownloadProgressItem : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *stage;
@property(nonatomic, strong, nullable) NSURL *thumbnailURL;
@property(nonatomic, strong, nullable) UIImage *thumbnail;
@property(nonatomic, assign) double progress;
@property(nonatomic, assign) int64_t downloadedBytes;
@property(nonatomic, assign) int64_t totalBytes;
@property(nonatomic, assign) BOOL failed;
@property(nonatomic, copy, nullable) NSString *detail;
@end

NSNotificationName const YTKACEDownloadJobsDidChangeNotification = @"YTKACEDownloadJobsDidChangeNotification";

@implementation YTKACEDownloadProgressItem
@end

@interface YTKACEDownloadProgressView () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIImageView *thumbnailView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEDownloadProgressItem *> *items;
@property(nonatomic, strong) NSMutableArray<NSString *> *activeIdentifiers;
@property(nonatomic, copy, nullable) NSString *visibleIdentifier;
@property(nonatomic, copy, nullable) NSString *renderedIdentifier;
@property(nonatomic, strong) NSTimer *positionTimer;
@property(nonatomic, assign) BOOL userHidden;
@property(nonatomic, assign) BOOL dragging;
@end

@implementation YTKACEDownloadProgressView

- (void)applyTheme {
    UITraitCollection *traits = self.keyWindow.traitCollection ?:
        UIScreen.mainScreen.traitCollection;
    BOOL oled = YTKACEOLEDActive(traits);
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    self.card.backgroundColor = oled ? UIColor.blackColor :
        (dark ? YTKACEInterfaceSurfaceColor(traits) : UIColor.systemBackgroundColor);
    self.thumbnailView.backgroundColor = YTKACEInterfaceSurfaceColor(traits);
    self.titleLabel.textColor = UIColor.labelColor;
    self.detailLabel.textColor = UIColor.tertiaryLabelColor;
    self.percentLabel.textColor = UIColor.labelColor;
    self.cancelButton.tintColor = UIColor.tertiaryLabelColor;
    self.retryButton.tintColor = UIColor.systemRedColor;
    self.progressView.trackTintColor = oled
        ? [UIColor colorWithWhite:0.18 alpha:1.0]
        : UIColor.systemGray4Color;
    self.card.layer.borderWidth = dark ? 0.0 : 0.5;
    self.card.layer.borderColor = UIColor.separatorColor.CGColor;
    if (YTKACEApplyGlassBackground(self.card, NO)) {
        self.card.layer.borderWidth = 0.0;
        self.card.clipsToBounds = YES;
    } else {
        self.card.clipsToBounds = NO;
        self.card.layer.shadowOpacity = 0.24;
    }
    [self layoutCard];
}

+ (instancetype)sharedView {
    static YTKACEDownloadProgressView *view;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ view = [YTKACEDownloadProgressView new]; });
    return view;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableDictionary dictionary];
        _activeIdentifiers = [NSMutableArray array];
        [self makeUI];
    }
    return self;
}

- (void)makeUI {
    self.card = [[UIView alloc] initWithFrame:CGRectMake(12.0, 0.0, 360.0, 72.0)];
    self.card.layer.cornerRadius = 12.0;
    self.card.layer.shadowColor = UIColor.blackColor.CGColor;
    self.card.layer.shadowOpacity = 0.24;
    self.card.layer.shadowRadius = 12.0;
    self.card.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    self.card.alpha = 0.0;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(cycleTapped)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.card addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(cardPanned:)];
    pan.delegate = self;
    [self.card addGestureRecognizer:pan];

    self.thumbnailView = [UIImageView new];
    self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbnailView.clipsToBounds = YES;
    self.thumbnailView.layer.cornerRadius = 8.0;
    [self.card addSubview:self.thumbnailView];

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.card addSubview:self.titleLabel];

    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.minimumScaleFactor = 0.75;
    [self.card addSubview:self.statusLabel];

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.detailLabel.adjustsFontSizeToFitWidth = YES;
    self.detailLabel.minimumScaleFactor = 0.8;
    [self.card addSubview:self.detailLabel];

    self.percentLabel = [UILabel new];
    self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    [self.card addSubview:self.percentLabel];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *close = [UIImage systemImageNamed:@"xmark.circle.fill"];
    [self.cancelButton setImage:close forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancelTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.cancelButton];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setImage:[UIImage systemImageNamed:@"arrow.clockwise.circle.fill"] forState:UIControlStateNormal];
    self.retryButton.hidden = YES;
    [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.retryButton];

    self.progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = UIColor.systemBlueColor;
    self.progressView.transform = CGAffineTransformMakeScale(1.0, 2.4);
    [self.card addSubview:self.progressView];
    [self applyTheme];
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

- (void)layoutCard {
    UIWindow *window = [self keyWindow];
    if (window == nil || self.card.superview == nil) return;
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 24.0, 400.0);
    CGFloat height = 64.0;
    CGFloat bottom = window.safeAreaInsets.bottom + 52.0;
    CGFloat x = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? 12.0 : (CGRectGetWidth(window.bounds) - width) * 0.5;
    CGRect target = CGRectMake(x, CGRectGetHeight(window.bounds) - bottom - height - 8.0, width, height);
    self.card.bounds = CGRectMake(0.0, 0.0, width, height);
    self.card.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    self.thumbnailView.frame = CGRectMake(8.0, 8.0, 85.0, 48.0);
    self.thumbnailView.layer.cornerRadius = 7.0;
    self.cancelButton.frame = CGRectMake(width - 32.0, 19.0, 26.0, 26.0);
    self.retryButton.frame = CGRectMake(width - 60.0, 19.0, 26.0, 26.0);
    CGFloat textX = 103.0;
    CGFloat rightEdge = self.retryButton.hidden ? width - 38.0 : width - 66.0;
    self.percentLabel.frame = CGRectMake(rightEdge - 44.0, 9.0, 42.0, 18.0);
    CGFloat titleRight = self.percentLabel.hidden ? rightEdge : rightEdge - 48.0;
    self.titleLabel.frame = CGRectMake(textX, 9.0, MAX(40.0, titleRight - textX), 18.0);
    self.statusLabel.frame = CGRectMake(textX, 29.0, MAX(40.0, rightEdge - textX), 15.0);
    self.detailLabel.hidden = YES;
    self.progressView.frame = CGRectMake(textX, 50.0, MAX(0.0, rightEdge - textX), 3.0);
    self.progressView.layer.cornerRadius = 1.5;
    self.progressView.clipsToBounds = YES;
}

- (void)hideCardAnimated {
    [self.positionTimer invalidate];
    self.positionTimer = nil;
    [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.card.alpha = 0.0;
        self.card.transform = CGAffineTransformMakeTranslation(0.0, 40.0);
    } completion:^(BOOL finished) {
        (void)finished;
        if (self.card.alpha > 0.01) return;
        [self.card removeFromSuperview];
        self.card.transform = CGAffineTransformIdentity;
    }];
}

- (void)setSuppressed:(BOOL)suppressed {
    if (_suppressed == suppressed) return;
    _suppressed = suppressed;
    if (suppressed) {
        [self hideCardAnimated];
    } else if (self.items.count != 0 && !self.userHidden) {
        [self renderItem:self.items[self.visibleIdentifier] ?: self.items[self.activeIdentifiers.firstObject]];
    }
}

- (void)cardPanned:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:self.card.superview].y;
    if (pan.state == UIGestureRecognizerStateBegan) self.dragging = YES;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        self.card.transform = CGAffineTransformMakeTranslation(0.0, MAX(0.0, dy));
        self.card.alpha = 1.0 - MIN(0.6, MAX(0.0, dy) / 120.0);
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
    self.dragging = NO;
    if (dy > 40.0 || [pan velocityInView:self.card.superview].y > 500.0) {
        self.userHidden = YES;
        YTKACEDownloadLog(@"progress", @"card hidden by swipe active=%lu", (unsigned long)self.items.count);
        [self hideCardAnimated];
        return;
    }
    [UIView animateWithDuration:0.25 animations:^{
        self.card.alpha = 1.0;
        self.card.transform = CGAffineTransformIdentity;
    }];
}

- (void)attach {
    UIWindow *window = [self keyWindow];
    if (window == nil || self.suppressed || self.userHidden) return;
    if (self.card.superview != window) {
        [self.card removeFromSuperview];
        [window addSubview:self.card];
    }
    [window bringSubviewToFront:self.card];
    // renderItem (the only caller) applies the theme right after this, so it is not repeated here.
    [self layoutCard];
    if (!self.positionTimer.isValid) {
        // Created once while the card is shown instead of being torn down and rescheduled on
        // every progress update.
        __weak YTKACEDownloadProgressView *weakSelf = self;
        self.positionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
            block:^(NSTimer *timer) {
                (void)timer;
                [weakSelf layoutCard];
            }];
    }
    if (self.card.alpha < 1.0 && !self.dragging) {
        self.card.transform = CGAffineTransformMakeTranslation(0.0, 18.0);
        [UIView animateWithDuration:0.32 delay:0.0
            usingSpringWithDamping:0.82 initialSpringVelocity:0.2
            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                self.card.alpha = 1.0;
                self.card.transform = CGAffineTransformIdentity;
            } completion:nil];
    }
}

- (void)renderItem:(YTKACEDownloadProgressItem *)item {
    if (item == nil) return;
    [self attach];
    [self applyTheme];
    self.titleLabel.text = item.title;
    NSString *count = @"";
    if (self.activeIdentifiers.count > 1) {
        NSUInteger failed = 0;
        for (NSString *identifier in self.activeIdentifiers) {
            if (self.items[identifier].failed) failed++;
        }
        NSUInteger running = self.activeIdentifiers.count - failed;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (running != 0) [parts addObject:[NSString stringWithFormat:YTKACELocalized(@"%lu downloading"), (unsigned long)running]];
        if (failed != 0) [parts addObject:[NSString stringWithFormat:YTKACELocalized(@"%lu failed"), (unsigned long)failed]];
        count = [@"  •  " stringByAppendingString:[parts componentsJoinedByString:@" · "]];
    }
    NSString *bytes = @"";
    if (item.downloadedBytes > 0) {
        NSString *done = [NSByteCountFormatter stringFromByteCount:item.downloadedBytes
            countStyle:NSByteCountFormatterCountStyleFile];
        if (item.totalBytes > 0) {
            NSString *total = [NSByteCountFormatter stringFromByteCount:item.totalBytes
                countStyle:NSByteCountFormatterCountStyleFile];
            bytes = [NSString stringWithFormat:@"  •  %@ / %@", done, total];
        } else {
            bytes = [NSString stringWithFormat:@"  •  %@", done];
        }
    }
    if (item.failed) bytes = @"";
    NSString *stageText = item.failed && item.detail.length != 0
        ? [NSString stringWithFormat:@"%@ · %@", item.stage, item.detail] : item.stage;
    self.statusLabel.textColor = item.failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    NSString *detail = [bytes stringByReplacingOccurrencesOfString:@"  •  " withString:@""];
    NSString *summary = [count stringByReplacingOccurrencesOfString:@"  •  " withString:@""];
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (detail.length != 0) [details addObject:detail];
    if (summary.length != 0) [details addObject:summary];
    [details insertObject:stageText ?: @"" atIndex:0];
    self.statusLabel.text = [details componentsJoinedByString:@" · "];
    self.retryButton.hidden = !item.failed || self.retryHandler == nil;
    self.percentLabel.hidden = item.failed;
    [self layoutCard];
    double progress = isfinite(item.progress)
        ? MIN(MAX(item.progress, 0.0), 1.0) : 0.0;
    self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100.0];
    BOOL sameItem = [self.renderedIdentifier isEqualToString:item.identifier];
    if (sameItem && progress > self.progressView.progress) {
        [UIView animateWithDuration:0.35 delay:0.0
                            options:UIViewAnimationOptionCurveLinear |
                                    UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self.progressView setProgress:(float)progress animated:NO];
            [self.progressView layoutIfNeeded];
        } completion:nil];
    } else {
        [self.progressView setProgress:(float)progress animated:NO];
    }
    self.renderedIdentifier = [item.identifier copy];
    self.thumbnailView.image = item.thumbnail;
    self.cancelButton.hidden = !item.failed && ([item.stage isEqualToString:YTKACELocalized(@"Merging")] ||
        [item.stage isEqualToString:YTKACELocalized(@"Complete")] ||
        [item.stage isEqualToString:YTKACELocalized(@"Cancelled")]);
    if ([item.stage isEqualToString:YTKACELocalized(@"Downloading audio")]) {
        self.progressView.progressTintColor = UIColor.systemPurpleColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Downloading video")]) {
        self.progressView.progressTintColor = UIColor.systemBlueColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Merging")]) {
        self.progressView.progressTintColor = UIColor.systemOrangeColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Complete")]) {
        self.progressView.progressTintColor = UIColor.systemGreenColor;
    }
    if (item.failed) self.progressView.progressTintColor = UIColor.systemRedColor;
}

- (void)postChange {
    [NSNotificationCenter.defaultCenter postNotificationName:YTKACEDownloadJobsDidChangeNotification object:self];
}

- (NSArray<NSDictionary *> *)jobSnapshot {
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    for (NSString *identifier in self.activeIdentifiers) {
        YTKACEDownloadProgressItem *item = self.items[identifier];
        if (item == nil) continue;
        [jobs addObject:@{
            @"identifier": item.identifier,
            @"title": item.title ?: @"",
            @"stage": item.stage ?: @"",
            @"progress": @(item.progress),
            @"downloadedBytes": @(item.downloadedBytes),
            @"totalBytes": @(item.totalBytes),
            @"failed": @(item.failed),
            @"detail": item.detail ?: @"",
            @"thumbnail": item.thumbnail ?: (id)NSNull.null
        }];
    }
    return jobs;
}

- (void)removeItem:(NSString *)identifier {
    if (self.items[identifier] == nil) return;
    NSUInteger removedIndex = [self.activeIdentifiers indexOfObject:identifier];
    [self.items removeObjectForKey:identifier];
    [self.activeIdentifiers removeObject:identifier];
    [self postChange];
    if (self.items.count != 0) {
        if ([self.visibleIdentifier isEqualToString:identifier] ||
            self.items[self.visibleIdentifier] == nil) {
            NSUInteger nextIndex = removedIndex == NSNotFound ? 0 :
                MIN(removedIndex, self.activeIdentifiers.count - 1);
            self.visibleIdentifier = self.activeIdentifiers[nextIndex];
        }
        [self renderItem:self.items[self.visibleIdentifier]];
        [self layoutCard];
        return;
    }
    self.visibleIdentifier = nil;
    self.userHidden = NO;
    [self.positionTimer invalidate];
    self.positionTimer = nil;
    [UIView animateWithDuration:0.22 animations:^{
        self.card.alpha = 0.0;
        self.card.transform = CGAffineTransformMakeTranslation(0.0, 14.0);
    } completion:^(BOOL finished) {
        (void)finished;
        if (self.items.count != 0) return;
        [self.card removeFromSuperview];
        self.card.transform = CGAffineTransformIdentity;
    }];
}

- (void)cancelOrDismissJob:(NSString *)identifier {
    YTKACEDownloadProgressItem *item = self.items[identifier];
    if (item == nil) return;
    YTKACEDownloadLog(identifier, @"user %@ stage=%@", item.failed ? @"dismissed" : @"cancelled", item.stage);
    if (item.failed) {
        [self removeItem:identifier];
    } else if (self.cancelHandler != nil) {
        self.cancelHandler(identifier);
    }
}

- (void)retryJob:(NSString *)identifier {
    YTKACEDownloadProgressItem *item = self.items[identifier];
    if (item == nil || !item.failed || self.retryHandler == nil) return;
    [self removeItem:identifier];
    self.retryHandler(identifier);
}

static UIImage *YTKACEDownsampledThumbnail(NSData *data, NSUInteger maxPixelSize) {
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

- (void)loadThumbnailForItem:(YTKACEDownloadProgressItem *)item {
    if (item.thumbnailURL == nil) return;
    NSString *identifier = item.identifier;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:item.thumbnailURL completionHandler:^(NSData *data,
            NSURLResponse *response, NSError *error) {
        (void)response;
        if (error != nil || data.length == 0) return;
        // Shown at 85x48 pt here and 142x80 pt in the library's job rows; decode a downsampled
        // bitmap off the main thread instead of keeping the full-size thumbnail.
        UIImage *image = YTKACEDownsampledThumbnail(data, 480);
        if (image == nil) image = [UIImage imageWithData:data];
        if (image == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEDownloadProgressItem *current = self.items[identifier];
            current.thumbnail = image;
            if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:current];
            [self postChange];
        });
    }];
    [task resume];
}

- (void)cancelPendingDismiss {
    if (self.suppressed || self.dragging) return;
    [self.card.layer removeAllAnimations];
    self.card.alpha = 1.0;
    self.card.transform = CGAffineTransformIdentity;
}

- (void)beginJob:(NSString *)identifier
           title:(NSString *)title
    thumbnailURL:(NSURL *)thumbnailURL {
    if (identifier.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = [YTKACEDownloadProgressItem new];
        item.identifier = identifier;
        item.title = title.length != 0 ? title : YTKACELocalized(@"YouTube Download");
        item.stage = YTKACELocalized(@"Preparing");
        item.thumbnailURL = thumbnailURL;
        self.items[identifier] = item;
        [self.activeIdentifiers removeObject:identifier];
        [self.activeIdentifiers addObject:identifier];
        self.visibleIdentifier = identifier;
        self.userHidden = NO;
        [self cancelPendingDismiss];
        [self renderItem:item];
        [self layoutCard];
        [self loadThumbnailForItem:item];
        [self postChange];
    });
}

- (void)updateJob:(NSString *)identifier
            stage:(NSString *)stage
         progress:(double)progress
  downloadedBytes:(int64_t)downloadedBytes
       totalBytes:(int64_t)totalBytes {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = self.items[identifier];
        if (item == nil) return;
        BOOL sameStage = [item.stage isEqualToString:stage];
        item.stage = stage;
        double nextProgress = isfinite(progress)
            ? MIN(MAX(progress, 0.0), 1.0) : 0.0;
        int64_t nextBytes = MAX(downloadedBytes, 0);
        item.progress = sameStage ? MAX(item.progress, nextProgress) : nextProgress;
        item.downloadedBytes = sameStage ? MAX(item.downloadedBytes, nextBytes) : nextBytes;
        item.totalBytes = MAX(totalBytes, 0);
        if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:item];
        [self postChange];
    });
}

- (void)finishJob:(NSString *)identifier
          success:(BOOL)success
          message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = self.items[identifier];
        if (item == nil) return;
        BOOL cancelled = !success && [message isEqualToString:YTKACELocalized(@"Cancelled")];
        item.stage = success ? YTKACELocalized(@"Complete")
            : (cancelled ? YTKACELocalized(@"Cancelled") : YTKACELocalized(@"Failed"));
        item.failed = !success && !cancelled;
        if (item.failed && message.length != 0 && ![message isEqualToString:YTKACELocalized(@"Failed")]) item.detail = message;
        item.progress = success ? 1.0 : item.progress;
        if (item.failed) {
            YTKACEDownloadLog(identifier, @"kept failed job on card detail=%@", item.detail ?: @"");
            self.visibleIdentifier = identifier;
            self.userHidden = NO;
            [self renderItem:item];
            [self postChange];
            return;
        }
        if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:item];
        [self postChange];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (self.items[identifier] == item) [self removeItem:identifier];
        });
    });
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.card];
    return velocity.y > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return ![touch.view isDescendantOfView:self.cancelButton] &&
        ![touch.view isDescendantOfView:self.retryButton];
}

- (void)cycleTapped {
    if (self.activeIdentifiers.count < 2) return;
    NSUInteger index = [self.activeIdentifiers indexOfObject:self.visibleIdentifier];
    NSUInteger nextIndex = index == NSNotFound ? 0 :
        (index + 1) % self.activeIdentifiers.count;
    self.visibleIdentifier = self.activeIdentifiers[nextIndex];
    [self renderItem:self.items[self.visibleIdentifier]];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (void)cancelTapped {
    NSString *identifier = self.visibleIdentifier;
    if (identifier.length != 0) [self cancelOrDismissJob:identifier];
}

- (void)retryTapped {
    NSString *identifier = self.visibleIdentifier;
    if (identifier.length != 0) [self retryJob:identifier];
}

@end
