#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPostImageSaveKey = @"YTKACE.Preference.Posts.SaveImage";

static IMP OriginalZoomNodeVisible;
static __weak id YTKACECurrentZoomNode;
static const void *YTKACEPostSaveButtonKey = &YTKACEPostSaveButtonKey;

static void YTKACEWriteImageDataToPhotos(NSData *data) {
    void (^save)(void) = ^{
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            PHAssetCreationRequest *request =
                [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:data
                                 options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    YTKACEShowNotice(YTKACELocalized(@"Saved to Photos"));
                } else {
                    YTKACEShowNotice(error.localizedDescription ?:
                        YTKACELocalized(@"The image could not be saved."));
                }
            });
        }];
    };

    void (^afterAuthorization)(PHAuthorizationStatus) = ^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized ||
            status == PHAuthorizationStatusLimited) {
            save();
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEShowNotice(
                YTKACELocalized(@"YouTube needs permission to add to Photos."));
        });
    };

    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                   handler:afterAuthorization];
    } else {
        [PHPhotoLibrary requestAuthorization:afterAuthorization];
    }
}

static NSURL *YTKACEOriginalImageURL(NSURL *url) {
    NSString *text = url.absoluteString;
    const NSRange crop = [text rangeOfString:@"c-fcrop"];
    if (crop.location != NSNotFound) {
        NSString *upgraded = [[text substringToIndex:crop.location]
            stringByAppendingString:@"nd-v1"];
        return [NSURL URLWithString:upgraded] ?: url;
    }
    const NSRange slash = [text rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return url;
    NSRange options = [text rangeOfString:@"=" options:NSBackwardsSearch
                                    range:NSMakeRange(slash.location,
                                          text.length - slash.location)];
    if (options.location == NSNotFound) return url;
    NSString *upgraded = [[text substringToIndex:options.location]
        stringByAppendingString:@"=s0"];
    return [NSURL URLWithString:upgraded] ?: url;
}

@interface YTKACEPostImageSaveTarget : NSObject
+ (instancetype)sharedTarget;
- (void)saveTapped:(UIButton *)sender;
@end

@implementation YTKACEPostImageSaveTarget

+ (instancetype)sharedTarget {
    static YTKACEPostImageSaveTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEPostImageSaveTarget new]; });
    return target;
}

- (void)saveTapped:(UIButton *)sender {
    id node = YTKACECurrentZoomNode;
    if (node == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image could not be saved."));
        return;
    }

    SEL urlGetter = NSSelectorFromString(@"URL");
    NSURL *url = [node respondsToSelector:urlGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, urlGetter)
        : nil;
    if (url == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image is still loading."));
        return;
    }

    NSURL *original = YTKACEOriginalImageURL(url);
    sender.enabled = NO;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:original
      completionHandler:^(NSData *data, NSURLResponse *response,
                          __unused NSError *error) {
        (void)response;
        dispatch_async(dispatch_get_main_queue(), ^{ sender.enabled = YES; });
        if (data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                YTKACEShowNotice(YTKACELocalized(@"The image could not be saved."));
            });
            return;
        }
        YTKACEWriteImageDataToPhotos(data);
    }];
    [task resume];
}

@end

static UIImage *YTKACEPostSaveIcon(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                           weight:UIImageSymbolWeightSemibold];
        return [UIImage systemImageNamed:@"square.and.arrow.down"
                       withConfiguration:configuration];
    }
    return nil;
}

static void YTKACEAttachSaveButton(UIView *container) {
    UIButton *existing = objc_getAssociatedObject(container, YTKACEPostSaveButtonKey);
    if (existing != nil && existing.superview == container) {
        existing.hidden = NO;
        [container bringSubviewToFront:existing];
        return;
    }
    [existing removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:YTKACEPostSaveIcon() forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = YTKACELocalized(@"Save to Photos");
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.5f;
    button.layer.shadowRadius = 3.0f;
    button.layer.shadowOffset = CGSizeZero;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:[YTKACEPostImageSaveTarget sharedTarget]
               action:@selector(saveTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(container, YTKACEPostSaveButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                            constant:12.0],
        [button.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor
                                        constant:8.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0]
    ]];
}

static UIViewController *YTKACEOwningController(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static void YTKACEZoomNodeDidEnterVisibleState(id receiver, SEL selector) {
    if (OriginalZoomNodeVisible != NULL) {
        ((void (*)(id, SEL))OriginalZoomNodeVisible)(receiver, selector);
    }
    if (!YTKACEFeatureEnabled(YTKACEPostImageSaveKey)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL viewGetter = NSSelectorFromString(@"view");
        if (![receiver respondsToSelector:viewGetter]) return;
        UIView *view = ((id (*)(id, SEL))objc_msgSend)(receiver, viewGetter);
        if (view.window == nil) return;
        UIViewController *owner = YTKACEOwningController(view);
        if (owner.view == nil) return;

        Class viewerClass =
            NSClassFromString(@"YTInterstitialElementsViewControllerImpl");
        if (viewerClass == Nil || ![owner isKindOfClass:viewerClass]) return;
        YTKACECurrentZoomNode = receiver;
        YTKACEAttachSaveButton(owner.view);
    });
}

static NSString *const YTKACEPostCopyTextKey = @"YTKACE.Preference.Posts.CopyText";
static const void *YTKACEPostCopyGestureKey = &YTKACEPostCopyGestureKey;

static id YTKACENodeValue(id node, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [node respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(node, selector) : nil;
}

static id YTKACEFindExpandableText(id node, NSUInteger depth) {
    if (node == nil || depth > 12) return nil;
    if ([NSStringFromClass([node class]) isEqualToString:@"ELMExpandableTextNode"]) return node;
    for (id child in YTKACENodeValue(node, @"subnodes")) {
        id found = YTKACEFindExpandableText(child, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static NSString *YTKACENodeText(id node, NSUInteger depth) {
    if (node == nil || depth > 4) return nil;
    NSString *text = [YTKACENodeValue(node, @"attributedText") string];
    if (text.length != 0) return text;
    for (id child in YTKACENodeValue(node, @"subnodes")) {
        text = YTKACENodeText(child, depth + 1);
        if (text.length != 0) return text;
    }
    return nil;
}

@interface YTKACEPostCopyHandler : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTKACEPostCopyHandler
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!YTKACEMasterEnabled() || ![YTKACEPreferenceObject(YTKACEPostCopyTextKey) boolValue]) return NO;
    UIView *window = gesture.view;
    UIView *cell = [window hitTest:[gesture locationInView:window] withEvent:nil];
    while (cell != nil && ![NSStringFromClass(cell.class) isEqualToString:@"_ASCollectionViewCell"]) cell = cell.superview;
    return [NSStringFromClass([YTKACENodeValue(cell, @"node") class]) isEqualToString:@"YTCommentNode"];
}

- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIView *window = gesture.view;
    CGPoint point = [gesture locationInView:window];
    UIView *cell = [window hitTest:point withEvent:nil];
    while (cell != nil && ![NSStringFromClass(cell.class) isEqualToString:@"_ASCollectionViewCell"]) cell = cell.superview;
    id cellNode = YTKACENodeValue(cell, @"node");
    if (![NSStringFromClass([cellNode class]) isEqualToString:@"YTCommentNode"]) return;
    id textNode = YTKACEFindExpandableText(cellNode, 0);
    UIView *cellView = YTKACENodeValue(cellNode, @"view");
    SEL boundsSel = NSSelectorFromString(@"bounds");
    SEL convertSel = NSSelectorFromString(@"convertRect:toNode:");
    if (textNode == nil || cellView == nil || ![textNode respondsToSelector:convertSel]) return;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(textNode, boundsSel);
    CGRect frame = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(textNode, convertSel, bounds, cellNode);
    frame = [cellView convertRect:CGRectInset(frame, -8.0, -8.0) toView:window];
    if (!CGRectContainsPoint(frame, point)) return;
    NSString *text = YTKACENodeText(textNode, 0);
    if (text.length == 0) return;
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Copy Text") style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = text;
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = window;
    menu.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1.0, 1.0);
    UIViewController *controller = ((UIWindow *)window).rootViewController;
    while (controller.presentedViewController != nil) controller = controller.presentedViewController;
    [controller presentViewController:menu animated:YES completion:nil];
}
@end

static YTKACEPostCopyHandler *YTKACEPostCopy;

static void YTKACEAttachPostCopyGestures(void) {
    if (!YTKACEMasterEnabled() || ![YTKACEPreferenceObject(YTKACEPostCopyTextKey) boolValue]) return;
    if (YTKACEPostCopy == nil) YTKACEPostCopy = [YTKACEPostCopyHandler new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (objc_getAssociatedObject(window, YTKACEPostCopyGestureKey) != nil) continue;
            UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
                initWithTarget:YTKACEPostCopy action:@selector(pressed:)];
            press.minimumPressDuration = 0.5;
            press.delegate = YTKACEPostCopy;
            [window addGestureRecognizer:press];
            objc_setAssociatedObject(window, YTKACEPostCopyGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void YTKACEInstallPostImageSaverHooks(void) {
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, YTKACEPreferencesDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            // Only the copy-text preference affects the window gestures.
            if ([note.name isEqualToString:YTKACEPreferencesDidChangeNotification] &&
                ![note.userInfo[@"key"] isEqual:YTKACEPostCopyTextKey]) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                           ^{ YTKACEAttachPostCopyGestures(); });
        }];
    }
    YTKACEInstallInstanceHook(
        @"YTImageZoomNode", @"didEnterVisibleState",
        (IMP)YTKACEZoomNodeDidEnterVisibleState, &OriginalZoomNodeVisible);
}
