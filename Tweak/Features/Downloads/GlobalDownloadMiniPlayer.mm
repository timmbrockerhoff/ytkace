#import "GlobalDownloadMiniPlayer.h"
#import "../../YTKACE.h"
#import "MediaArtwork.h"
#import "YTKACEAudioPlayerController.h"
#import "YTKACEDownloadPlayerController.h"
#import "../../Runtime/Preferences.h"
#import "../SponsorBlock/SponsorPreferences.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static NSString * const YTKACEMiniSizeKey = @"YTKACE.Library.MiniPlayerSize";
static NSString * const YTKACEMiniCornerKey = @"YTKACE.Library.MiniPlayerCorner";


@interface YTKACEMiniProgressView : UIView
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *segments;
@property(nonatomic, assign) NSTimeInterval duration;
@end

@implementation YTKACEMiniProgressView

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    [[UIColor colorWithWhite:1.0 alpha:0.3] setFill];
    UIRectFill(self.bounds);
    CGFloat playedWidth = width * MAX(0.0, MIN(1.0, self.progress));
    if (playedWidth > 0.0) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSaveGState(context);
        UIRectClip(CGRectMake(0.0, 0.0, playedWidth, height));
        [YTKACEProgressFillImage(width, height) drawInRect:CGRectMake(0.0, 0.0, width, height)];
        CGContextRestoreGState(context);
    }
    if (!isfinite(self.duration) || self.duration <= 0.0 || !YTKACESponsorBlockEnabled()) {
        return;
    }
    for (NSDictionary<NSString *, id> *segment in self.segments) {
        NSString *category = segment[@"category"];
        if (YTKACESponsorCategoryBehavior(category) == 2) continue;
        CGFloat start = (CGFloat)([segment[@"start"] doubleValue] / self.duration) * width;
        CGFloat end = (CGFloat)([segment[@"end"] doubleValue] / self.duration) * width;
        start = MAX(0.0, MIN(width, start));
        end = MAX(start + 1.0, MIN(width, end));
        [YTKACESponsorCategoryColor(category) setFill];
        UIRectFill(CGRectMake(start, 0.0, end - start, height));
    }
}

@end

static UIWindow *YTKACEGlobalWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0.0) return window;
        }
    }
    return nil;
}

static UIViewController *YTKACEGlobalPresenter(void) {
    UIViewController *controller = YTKACEGlobalWindow().rootViewController;
    while (controller != nil) {
        if (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return controller;
}

static BOOL YTKACEIsFullPlayer(UIViewController *controller) {
    return [controller isKindOfClass:YTKACEDownloadPlayerController.class] ||
        [controller isKindOfClass:YTKACEAudioPlayerController.class];
}

static BOOL YTKACEGlobalFullPlayerVisible(void) {
    UIViewController *controller = YTKACEGlobalWindow().rootViewController;
    while (controller != nil) {
        if (YTKACEIsFullPlayer(controller)) return YES;
        if (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            UINavigationController *navigation = (UINavigationController *)controller;
            for (UIViewController *child in navigation.viewControllers) {
                if (YTKACEIsFullPlayer(child)) return YES;
            }
            controller = navigation.visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return NO;
}

static BOOL YTKACEGlobalTabCandidate(UIView *view, UIWindow *window, CGFloat *minY) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    BOOL tab = [view isKindOfClass:UITabBar.class] ||
        [name containsString:@"pivotbar"];
    if (!tab || CGRectGetHeight(view.bounds) < 35.0) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    if (CGRectGetMinY(frame) <= CGRectGetHeight(window.bounds) * 0.55) return NO;
    *minY = CGRectGetMinY(frame);
    return YES;
}

static BOOL YTKACEGlobalViewVisibleInWindow(UIView *view, UIWindow *window) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.05) return NO;
        if (current == window) return YES;
    }
    return NO;
}

// The mini player's position timer asks for this every 0.35 s. Walking YouTube's whole view
// tree each time is expensive, so remember the tab bar views found by the last full walk and
// reuse them while they are all still visible in the same window; otherwise walk again (at most
// once per second while no tab bar is on screen).
static CGFloat YTKACEGlobalTabTop(UIWindow *window) {
    static __weak UIWindow *cachedWindow;
    static CGRect cachedBounds;
    static NSHashTable<UIView *> *cachedViews;
    static CFTimeInterval lastWalk;
    CGFloat top = CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL sameWindow = window == cachedWindow &&
        CGRectEqualToRect(window.bounds, cachedBounds) && cachedViews != nil;
    if (sameWindow) {
        NSArray<UIView *> *views = cachedViews.allObjects;
        if (views.count == 0 && now - lastWalk < 1.0) return top;
        BOOL valid = views.count != 0;
        CGFloat cachedTop = top;
        for (UIView *view in views) {
            CGFloat minY = 0.0;
            if (!YTKACEGlobalViewVisibleInWindow(view, window) ||
                !YTKACEGlobalTabCandidate(view, window, &minY)) {
                valid = NO;
                break;
            }
            cachedTop = MIN(cachedTop, minY);
        }
        if (valid) return cachedTop;
    }
    NSHashTable<UIView *> *found = [NSHashTable weakObjectsHashTable];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.05) continue;
        CGFloat minY = 0.0;
        if (YTKACEGlobalTabCandidate(view, window, &minY)) {
            top = MIN(top, minY);
            [found addObject:view];
        }
        [stack addObjectsFromArray:view.subviews];
    }
    cachedWindow = window;
    cachedBounds = window.bounds;
    cachedViews = found;
    lastWalk = now;
    return top;
}

static UIButton *YTKACEMiniButton(NSString *symbol, CGFloat size, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightBold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.45;
    button.layer.shadowRadius = 3.0;
    button.layer.shadowOffset = CGSizeZero;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@interface YTKACEGlobalDownloadMiniPlayer : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *content;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) CAGradientLayer *shade;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) YTKACEMiniProgressView *progressView;
@property(nonatomic, strong) NSTimer *positionTimer;
@property(nonatomic, assign) BOOL interacting;
@property(nonatomic, assign) BOOL dismissing;
@property(nonatomic, assign) BOOL audio;
@property(nonatomic, assign) BOOL videoAttached;
@property(nonatomic, assign) BOOL fullPlayerHiding;
@property(nonatomic, assign) CGFloat baseSize;
@property(nonatomic, assign) CGFloat pinchStartSize;
@property(nonatomic, assign) NSInteger corner;
@property(nonatomic, assign) CGPoint panStartCenter;
@property(nonatomic, copy) NSURL *artworkURL;
@end

@implementation YTKACEGlobalDownloadMiniPlayer

+ (instancetype)sharedPlayer {
    static YTKACEGlobalDownloadMiniPlayer *player;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ player = [YTKACEGlobalDownloadMiniPlayer new]; });
    return player;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.baseSize = [defaults doubleForKey:YTKACEMiniSizeKey];
    self.corner = [defaults objectForKey:YTKACEMiniCornerKey] != nil
        ? MAX(0, MIN([defaults integerForKey:YTKACEMiniCornerKey], 3)) : 3;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidStopNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACELibraryPiPDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(fullPlayerWillShow:)
        name:YTKACELibraryFullPlayerWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(fullPlayerWillHide:)
        name:YTKACELibraryFullPlayerWillHideNotification object:nil];
    __weak YTKACEGlobalDownloadMiniPlayer *weakSelf = self;
    [YTKACELibraryPiP sharedPiP].restoreHandler = ^(UIView *owner) {
        YTKACEGlobalDownloadMiniPlayer *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        (void)owner;
        if (YTKACELibraryVideoView().superview == strongSelf.content) {
            dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refresh]; });
            return;
        }
        [strongSelf openPlayer];
    };
    return self;
}

- (void)buildUI {
    if (self.card != nil) return;
    self.card = [UIView new];
    self.card.layer.shadowColor = UIColor.blackColor.CGColor;
    self.card.layer.shadowOpacity = 0.35;
    self.card.layer.shadowRadius = 12.0;
    self.card.layer.shadowOffset = CGSizeMake(0.0, 4.0);

    self.content = [UIView new];
    self.content.backgroundColor = UIColor.blackColor;
    self.content.layer.cornerRadius = 12.0;
    self.content.clipsToBounds = YES;
    self.content.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.card addSubview:self.content];


    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.content addSubview:self.artworkView];

    self.shade = [CAGradientLayer layer];
    self.shade.colors = @[
        (id)[UIColor colorWithWhite:0.0 alpha:0.45].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.55].CGColor
    ];
    self.shade.locations = @[@0.0, @0.35, @0.6, @1.0];
    [self.content.layer addSublayer:self.shade];

    self.playButton = YTKACEMiniButton(@"pause.fill", 15.0, self, @selector(togglePlayback));
    [self.content addSubview:self.playButton];
    self.closeButton = YTKACEMiniButton(@"xmark", 14.0, self, @selector(closePlayback));
    [self.content addSubview:self.closeButton];

    self.progressView = [YTKACEMiniProgressView new];
    self.progressView.backgroundColor = UIColor.clearColor;
    self.progressView.userInteractionEnabled = NO;
    [self.content addSubview:self.progressView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openPlayer)];
    tap.delegate = self;
    [self.card addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [self.card addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePinch:)];
    pinch.delegate = self;
    [self.card addGestureRecognizer:pinch];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return ![touch.view isKindOfClass:UIControl.class];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [gestureRecognizer isKindOfClass:UIPinchGestureRecognizer.class] ||
        [other isKindOfClass:UIPinchGestureRecognizer.class];
}

- (CGRect)allowedAreaInWindow:(UIWindow *)window {
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat margin = 10.0;
    CGFloat top = safe.top + margin;
    CGFloat bottom = MIN(CGRectGetHeight(window.bounds) - safe.bottom,
                         YTKACEGlobalTabTop(window)) - margin;
    CGFloat left = safe.left + margin;
    CGFloat right = CGRectGetWidth(window.bounds) - safe.right - margin;
    return CGRectMake(left, top, MAX(0.0, right - left), MAX(0.0, bottom - top));
}

- (CGFloat)aspectRatio {
    if (self.audio) return 1.0;
    CGSize size = YTKACEDownloadPlaybackSession.sharedSession.player.currentItem.presentationSize;
    CGFloat aspect = size.width > 0.0 && size.height > 0.0
        ? size.width / size.height : 16.0 / 9.0;
    return MAX(9.0 / 16.0, MIN(aspect, 16.0 / 9.0));
}

- (CGFloat)clampedSize:(CGFloat)size inArea:(CGRect)area {
    CGFloat aspect = [self aspectRatio];
    CGFloat maxWidth = CGRectGetWidth(area);
    CGFloat maxHeight = CGRectGetHeight(area) * 0.6;
    CGFloat limit = aspect >= 1.0 ? MIN(maxWidth, maxHeight * aspect)
                                  : MIN(maxHeight, maxWidth / aspect);
    CGFloat minimum = MIN(150.0, limit);
    return MAX(minimum, MIN(size, limit));
}

- (CGSize)cardSizeInArea:(CGRect)area {
    CGFloat base = self.baseSize > 0.0 ? self.baseSize :
        (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 340.0 : 220.0);
    base = [self clampedSize:base inArea:area];
    CGFloat aspect = [self aspectRatio];
    if (aspect >= 1.0) return CGSizeMake(round(base), round(base / aspect));
    return CGSizeMake(round(base * aspect), round(base));
}

- (CGRect)frameForCorner:(NSInteger)corner size:(CGSize)size area:(CGRect)area {
    CGFloat x = (corner == 0 || corner == 2) ? CGRectGetMinX(area)
                                             : CGRectGetMaxX(area) - size.width;
    CGFloat y = (corner == 0 || corner == 1) ? CGRectGetMinY(area)
                                             : CGRectGetMaxY(area) - size.height;
    return CGRectMake(x, y, size.width, size.height);
}

- (void)applyFrame:(CGRect)frame {
    self.card.bounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
    self.card.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.content.frame = self.card.bounds;
    self.card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.card.bounds
                                                            cornerRadius:12.0].CGPath;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.shade.frame = self.content.bounds;
    [CATransaction commit];
    CGFloat width = frame.size.width;
    CGFloat height = frame.size.height;
    self.closeButton.frame = CGRectMake(width - 38.0, 2.0, 36.0, 36.0);
    self.playButton.frame = CGRectMake(2.0, height - 40.0, 38.0, 36.0);
    self.progressView.frame = CGRectMake(0.0, height - 3.0, width, 3.0);
    [self updateProgress];
}

- (void)updateProgress {
    AVPlayer *player = YTKACEDownloadPlaybackSession.sharedSession.player;
    NSTimeInterval elapsed = CMTimeGetSeconds(player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(player.currentItem.duration);
    CGFloat ratio = isfinite(elapsed) && isfinite(duration) && duration > 0.0
        ? (CGFloat)MAX(0.0, MIN(1.0, elapsed / duration)) : 0.0;
    self.progressView.progress = ratio;
    self.progressView.duration = duration;
    self.progressView.segments = YTKACEDownloadPlaybackSession.sharedSession.sponsorSegments;
    [self.progressView setNeedsDisplay];
}

- (BOOL)shouldHideCard {
    return (YTKACEGlobalFullPlayerVisible() && !self.fullPlayerHiding) ||
        [YTKACELibraryPiP sharedPiP].active;
}

- (void)layoutCard {
    UIWindow *window = YTKACEGlobalWindow();
    if (window == nil || self.card.superview != window || self.dismissing) return;
    BOOL hidden = [self shouldHideCard];
    if (!YTKACEGlobalFullPlayerVisible()) self.fullPlayerHiding = NO;
    self.card.hidden = hidden;
    [self updateVideoAttachment:!hidden || self.fullPlayerHiding];
    if (hidden || self.interacting) return;
    CGRect area = [self allowedAreaInWindow:window];
    [self applyFrame:[self frameForCorner:self.corner
                                     size:[self cardSizeInArea:area] area:area]];
}

- (void)updateVideoAttachment:(BOOL)visible {
    UIView *video = YTKACELibraryVideoView();
    if (self.audio) {
        if (video.superview == self.content) [video removeFromSuperview];
        self.videoAttached = NO;
        return;
    }
    self.videoAttached = video.superview == self.content;
    if (!visible || self.videoAttached || self.content == nil) return;
    [video removeFromSuperview];
    video.translatesAutoresizingMaskIntoConstraints = YES;
    video.frame = self.content.bounds;
    video.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    ((AVPlayerLayer *)video.layer).videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.content insertSubview:video atIndex:0];
    self.videoAttached = YES;
    [[YTKACELibraryPiP sharedPiP] useLayer:(AVPlayerLayer *)video.layer owner:video];
}

- (CGRect)targetFrame {
    UIWindow *window = YTKACEGlobalWindow();
    NSURL *URL = YTKACEDownloadPlaybackSession.sharedSession.currentURL;
    if (window == nil || URL == nil) return CGRectNull;
    self.audio = [URL.path containsString:@"/Downloads/Audio/"];
    CGRect area = [self allowedAreaInWindow:window];
    return [self frameForCorner:self.corner size:[self cardSizeInArea:area] area:area];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = self.card.window;
    if (window == nil) return;
    CGPoint translation = [gesture translationInView:window];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.interacting = YES;
        self.panStartCenter = self.card.center;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.card.center = CGPointMake(self.panStartCenter.x + translation.x,
                                       self.panStartCenter.y + translation.y);
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    CGPoint velocity = [gesture velocityInView:window];
    CGRect area = [self allowedAreaInWindow:window];
    CGPoint projected = CGPointMake(self.card.center.x + velocity.x * 0.18,
                                    self.card.center.y + velocity.y * 0.18);
    CGFloat halfWidth = CGRectGetWidth(self.card.bounds) * 0.5;
    BOOL flungLeft = projected.x + halfWidth * 0.4 < CGRectGetMinX(area) &&
        velocity.x < -500.0;
    BOOL flungRight = projected.x - halfWidth * 0.4 > CGRectGetMaxX(area) &&
        velocity.x > 500.0;
    if (flungLeft || flungRight) {
        [self dismissTowards:flungLeft ? -1.0 : 1.0 velocity:velocity];
        return;
    }
    BOOL left = projected.x < CGRectGetMidX(area);
    BOOL top = projected.y < CGRectGetMidY(area);
    self.corner = (top ? 0 : 2) + (left ? 0 : 1);
    [NSUserDefaults.standardUserDefaults setInteger:self.corner forKey:YTKACEMiniCornerKey];
    CGRect target = [self frameForCorner:self.corner size:self.card.bounds.size area:area];
    [UIView animateWithDuration:0.45 delay:0.0 usingSpringWithDamping:0.82
          initialSpringVelocity:0.4 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.card.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    } completion:^(__unused BOOL finished) {
        self.interacting = NO;
    }];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gesture {
    UIWindow *window = self.card.window;
    if (window == nil) return;
    CGRect area = [self allowedAreaInWindow:window];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.interacting = YES;
        CGSize size = self.card.bounds.size;
        self.pinchStartSize = MAX(size.width, size.height);
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.baseSize = [self clampedSize:self.pinchStartSize * gesture.scale inArea:area];
        [self applyFrame:[self frameForCorner:self.corner
                                         size:[self cardSizeInArea:area] area:area]];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:self.baseSize forKey:YTKACEMiniSizeKey];
        self.interacting = NO;
        [self layoutCard];
    }
}

- (void)dismissTowards:(CGFloat)direction velocity:(CGPoint)velocity {
    self.dismissing = YES;
    CGFloat distance = CGRectGetWidth(self.card.window.bounds);
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.card.center = CGPointMake(self.card.center.x + direction * distance,
                                       self.card.center.y + velocity.y * 0.08);
        self.card.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self.card.alpha = 1.0;
        self.interacting = NO;
        self.dismissing = NO;
        [self closePlayback];
    }];
}

- (void)fullPlayerWillHide:(NSNotification *)notification {
    (void)notification;
    if (YTKACEDownloadPlaybackSession.sharedSession.currentURL == nil) return;
    self.fullPlayerHiding = YES;
    [self refresh];
}

- (void)fullPlayerWillShow:(NSNotification *)notification {
    (void)notification;
    self.fullPlayerHiding = NO;
    self.card.hidden = YES;
    [self updateVideoAttachment:NO];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    if (self.card == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)refresh {
    [self buildUI];
    YTKACEDownloadPlaybackSession *session =
        YTKACEDownloadPlaybackSession.sharedSession;
    NSURL *URL = session.currentURL;
    if (URL == nil) {
        self.artworkURL = nil;
        self.artworkView.image = nil;
        [self.card removeFromSuperview];
        [self.positionTimer invalidate];
        self.positionTimer = nil;
        [self updateVideoAttachment:NO];
        return;
    }
    UIWindow *window = YTKACEGlobalWindow();
    if (window == nil) return;
    if (self.card.superview != window) {
        [self.card removeFromSuperview];
        [window addSubview:self.card];
    }
    [window bringSubviewToFront:self.card];
    self.audio = [URL.path containsString:@"/Downloads/Audio/"];
    self.artworkView.hidden = !self.audio;
    // refresh runs on every playback notification; only look the artwork up again when the
    // track changes (or none was found yet, e.g. while the sidecar is still being written).
    if (!self.audio) {
        self.artworkView.image = nil;
        self.artworkURL = nil;
    } else if (![URL isEqual:self.artworkURL] || self.artworkView.image == nil) {
        self.artworkURL = URL;
        self.artworkView.image = YTKACEMediaArtworkImage(URL);
    }
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                        weight:UIImageSymbolWeightBold];
    NSString *symbol = session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
                     forState:UIControlStateNormal];
    [self layoutCard];
    if (self.positionTimer == nil) {
        __weak YTKACEGlobalDownloadMiniPlayer *weakSelf = self;
        self.positionTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
            repeats:YES block:^(__unused NSTimer *timer) {
                YTKACEGlobalDownloadMiniPlayer *strongSelf = weakSelf;
                [strongSelf layoutCard];
                [strongSelf updateProgress];
                UIWindow *activeWindow = YTKACEGlobalWindow();
                if (strongSelf.card.superview != activeWindow) [strongSelf refresh];
                [activeWindow bringSubviewToFront:strongSelf.card];
            }];
    }
}

- (void)togglePlayback {
    [YTKACEDownloadPlaybackSession.sharedSession togglePlayback];
}

- (void)closePlayback {
    [[YTKACELibraryPiP sharedPiP] stop];
    [YTKACEDownloadPlaybackSession.sharedSession stop];
}

- (void)openPlayer {
    YTKACEDownloadPlaybackSession *session =
        YTKACEDownloadPlaybackSession.sharedSession;
    if (session.currentURL == nil) return;
    UIViewController *presenter = YTKACEGlobalPresenter();
    if (presenter == nil || YTKACEGlobalFullPlayerVisible()) {
        return;
    }
    BOOL audio = [session.currentURL.path containsString:@"/Downloads/Audio/"];
    UIViewController *player = audio
        ? [[YTKACEAudioPlayerController alloc] initWithSession:session]
        : [[YTKACEDownloadPlayerController alloc] initWithSession:session];
    __weak YTKACEGlobalDownloadMiniPlayer *weakSelf = self;
    dispatch_block_t minimized = ^{ [weakSelf refresh]; };
    if (audio) {
        ((YTKACEAudioPlayerController *)player).minimizeHandler = minimized;
    } else {
        ((YTKACEDownloadPlayerController *)player).minimizeHandler = minimized;
    }
    if (!audio && self.card.superview != nil && !self.card.hidden) {
        ((YTKACEDownloadPlayerController *)player).sourceFrame =
            [self.card convertRect:self.card.bounds toView:nil];
    }
    self.card.hidden = YES;
    [self updateVideoAttachment:NO];
    [presenter presentViewController:player animated:YES completion:nil];
}

@end

void YTKACEInstallGlobalDownloadMiniPlayer(void) {
    [YTKACEGlobalDownloadMiniPlayer sharedPlayer];
}

CGRect YTKACEMiniPlayerTargetFrame(void) {
    return [[YTKACEGlobalDownloadMiniPlayer sharedPlayer] targetFrame];
}
