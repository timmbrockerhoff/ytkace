#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalTopMoveToWindow;
static IMP OriginalTopMoveToSuperview;
static IMP OriginalHeaderLayout;
static IMP OriginalMultiSearchLayout;
static IMP OriginalSettingsLayout;
static IMP OriginalSetHidesShared;
static IMP OriginalSetLeftItems;
static IMP OriginalSetRightItems;
static IMP OriginalSetLeftItem;
static IMP OriginalSetRightItem;
static IMP OriginalMultiSearchMoveToWindow;
static IMP OriginalHeaderMoveToWindow;

static const void *YTKACETopGlassAssociation = &YTKACETopGlassAssociation;
static const void *YTKACESearchBoxGlassAssociation = &YTKACESearchBoxGlassAssociation;
static const void *YTKACESearchBarGlassAssociation = &YTKACESearchBarGlassAssociation;
static const void *YTKACESearchBackGlassAssociation = &YTKACESearchBackGlassAssociation;
static const void *YTKACEHeaderGlassAssociation = &YTKACEHeaderGlassAssociation;
static const void *YTKACEHeaderTouchedAssociation = &YTKACEHeaderTouchedAssociation;
static const void *YTKACESettingsTouchedAssociation = &YTKACESettingsTouchedAssociation;
static const void *YTKACEPillGlassAssociation = &YTKACEPillGlassAssociation;
static const void *YTKACELeftGlassAssociation = &YTKACELeftGlassAssociation;
static const void *YTKACEWrapGlassAssociation = &YTKACEWrapGlassAssociation;
static const void *YTKACESideGlassAssociation = &YTKACESideGlassAssociation;
static const void *YTKACESideButtonsAssociation = &YTKACESideButtonsAssociation;




static BOOL YTKACEGlassChromeEnabled(void) {
    return YTKACELiquidGlassAvailable() && YTKACEFeatureEnabled(@"YTKACE.Preference.Glass.TopBar");
}

static UIVisualEffectView *YTKACEChromeGlass(UIView *owner, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    if (glass != nil) return glass;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
    glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.backgroundColor = UIColor.clearColor;
    glass.clipsToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    objc_setAssociatedObject(owner, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return glass;
}

static const void *YTKACETouchesMovedAssociation = &YTKACETouchesMovedAssociation;


static void YTKACERemoveChromeGlass(UIView *owner, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    [glass removeFromSuperview];
}

static void YTKACEPlaceBehind(UIVisualEffectView *glass, UIView *view, CGRect frame) {
    UIView *host = view.superview;
    if (host == nil) return;
    if (glass.superview != host) {
        [glass removeFromSuperview];
        [host insertSubview:glass belowSubview:view];
    } else {
        NSUInteger glassIndex = [host.subviews indexOfObjectIdenticalTo:glass];
        NSUInteger viewIndex = [host.subviews indexOfObjectIdenticalTo:view];
        if (glassIndex == NSNotFound || viewIndex == NSNotFound || glassIndex + 1 != viewIndex) {
            [host insertSubview:glass belowSubview:view];
        }
    }
    glass.frame = frame;
    glass.layer.cornerRadius = MIN(CGRectGetHeight(frame) * 0.5, 24.0);
}

static void YTKACECollectControls(UIView *view, NSMutableArray<UIView *> *controls) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIControl.class]) {
            [controls addObject:subview];
            continue;
        }
        YTKACECollectControls(subview, controls);
    }
}

@interface YTKACETapProbe : NSObject
+ (instancetype)shared;
@end

@implementation YTKACETapProbe
+ (instancetype)shared {
    static YTKACETapProbe *probe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ probe = [YTKACETapProbe new]; });
    return probe;
}
- (void)forward:(UITapGestureRecognizer *)recognizer {
    UIView *glass = recognizer.view;
    UIControl *control = (UIControl *)glass.superview;
    if (![control isKindOfClass:UIControl.class] || !control.enabled) {
        return;
    }
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@end

static BOOL YTKACENativeButtons(void) {
    id value = YTKACEPreferenceObject(@"YTKACE.Preference.Glass.NativeButtons");
    return value == nil || [value boolValue];
}

static void YTKACERestoreButtonsForKey(UIView *container, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(container, key);
    if (glass.superview != container) return;
    for (UIView *subview in glass.contentView.subviews.copy) [container addSubview:subview];
}

static void YTKACERestoreButtons(UIView *container) {
    YTKACERestoreButtonsForKey(container, YTKACETopGlassAssociation);
}

static void YTKACEQuietButtonsIn(UIView *view);

static CGFloat YTKACEResultsSearchHeight(UIView *container) {
    UIView *header = container.superview;
    while (header != nil && ![NSStringFromClass(header.class) isEqualToString:@"YTHeaderView"]) header = header.superview;
    if (header == nil) return 0.0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
    NSUInteger visited = 0;
    while (queue.count != 0 && visited < 200) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([NSStringFromClass(node.class) isEqualToString:@"YTSearchBarView"]) {
            return node.hidden || node.window == nil ? 0.0 : CGRectGetHeight(node.bounds);
        }
        [queue addObjectsFromArray:node.subviews];
    }
    return 0.0;
}

static void YTKACEApplyNativeGlass(UIView *container, const void *key) {
    UIVisualEffectView *glass = YTKACEChromeGlass(container, key);
    if (glass.superview != container) {
        [glass removeFromSuperview];
        UIVisualEffect *effect = glass.effect;
        SEL interactive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:interactive]) {
            UIVisualEffect *copy = [effect copy];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, interactive, YES);
            glass.effect = copy;
        }
        [container insertSubview:glass atIndex:0];
    }
    glass.userInteractionEnabled = YES;
    glass.clipsToBounds = NO;
    CGRect target = container.bounds;
    CGFloat compact = YTKACEResultsSearchHeight(container);
    if (compact > 20.0 && compact < CGRectGetHeight(target) - 1.0) {
        CGFloat inset = (CGRectGetHeight(target) - compact) * 0.5;
        target = CGRectInset(target, inset, inset);
    }
    for (UIView *subview in container.subviews.copy) {
        if (subview == glass) continue;
        CGRect frame = subview.frame;
        [glass.contentView addSubview:subview];
        subview.frame = frame;
    }
    glass.frame = target;
    glass.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    CGRect content = glass.contentView.bounds;
    if (!CGPointEqualToPoint(content.origin, target.origin)) {
        content.origin = target.origin;
        glass.contentView.bounds = content;
    }
    CGFloat rowHeight = CGRectGetHeight(container.bounds);
    for (UIView *subview in glass.contentView.subviews) {
        CGRect frame = subview.frame;
        CGFloat centeredY = (rowHeight - CGRectGetHeight(frame)) * 0.5;
        if (CGRectGetHeight(frame) < rowHeight && fabs(CGRectGetMinY(frame) - centeredY) > 0.5) {
            frame.origin.y = centeredY;
            subview.frame = frame;
        }
    }
    container.backgroundColor = UIColor.clearColor;
    YTKACEQuietButtonsIn(glass.contentView);
}

static void YTKACEApplyNativeTopGlass(UIView *container) {
    YTKACEApplyNativeGlass(container, YTKACETopGlassAssociation);
}

UIView *YTKACEMakeSettingsGlass(void) {
    if (!YTKACELiquidGlassAvailable() || !YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.Glass")) return nil;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.clipsToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return glass;
}

void YTKACEApplyTopNavigationGlass(UIView *container) {
    if (!YTKACEGlassChromeEnabled() || container.window == nil || container.superview == nil ||
        CGRectIsEmpty(container.bounds)) {
        YTKACERestoreButtons(container);
        YTKACERemoveChromeGlass(container, YTKACETopGlassAssociation);
        return;
    }
    NSMutableArray<UIView *> *controls = [NSMutableArray array];
    YTKACECollectControls(container, controls);
    CGRect area = controls.count != 0 ? container.bounds : CGRectNull;
    if (CGRectIsNull(area)) {
        YTKACERemoveChromeGlass(container, YTKACETopGlassAssociation);
        return;
    }
    if (YTKACENativeButtons()) {
        YTKACEApplyNativeTopGlass(container);
        return;
    }
    area = CGRectInset(area, -6.0, -4.0);
    area = CGRectIntersection(area, container.bounds);
    CGFloat height = MAX(44.0, CGRectGetHeight(area));
    CGFloat width = MAX(height, CGRectGetWidth(area));
    CGRect local = CGRectMake(CGRectGetMidX(area) - width * 0.5, CGRectGetMidY(area) - height * 0.5,
                              width, height);
    UIVisualEffectView *glass = YTKACEChromeGlass(container, YTKACETopGlassAssociation);
    if (CGAffineTransformIsIdentity(glass.transform)) {
        YTKACEPlaceBehind(glass, container, [container convertRect:local toView:container.superview]);
    }
    UIView *screen = container.superview;
    while (screen != nil && ![screen.nextResponder isKindOfClass:UIViewController.class]) screen = screen.superview;
    container.backgroundColor = UIColor.clearColor;
}












static void YTKACEPlaceCircle(UIView *owner, const void *key, UIView *button, UIView *host) {
    UIVisualEffectView *glass = YTKACEChromeGlass(owner, key);
    if (glass.superview != host) {
        [glass removeFromSuperview];
        UIView *branch = button;
        while (branch.superview != nil && branch.superview != host) branch = branch.superview;
        if (branch.superview == host) [host insertSubview:glass belowSubview:branch];
        else [host insertSubview:glass atIndex:0];
    }
    CGRect buttonFrame = [button convertRect:button.bounds toView:host];
    CGFloat side = 36.0;
    CGRect frame = CGRectMake(CGRectGetMidX(buttonFrame) - side * 0.5,
                              CGRectGetMidY(buttonFrame) - side * 0.5, side, side);
    if (host == owner) {
        CGRect safe = UIEdgeInsetsInsetRect(host.bounds, host.safeAreaInsets);
        if (!CGRectIsEmpty(safe) && CGRectGetMinY(frame) < CGRectGetMinY(safe)) {
            frame.origin.y = CGRectGetMinY(safe);
        }
    }
    glass.hidden = NO;
    if (CGAffineTransformIsIdentity(glass.transform)) {
        glass.frame = frame;
        glass.layer.cornerRadius = side * 0.5;
    }
    if (button.superview == host) [host insertSubview:glass belowSubview:button];
}




static BOOL YTKACEButtonHasContent(UIButton *button) {
    if (button.hidden || button.alpha <= 0.01) return NO;
    if (button.currentImage != nil || button.currentTitle.length != 0 || button.currentBackgroundImage != nil) {
        return YES;
    }
    for (UIView *subview in button.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIImageView.class]) {
            if (((UIImageView *)subview).image != nil) return YES;
            continue;
        }
        if ([subview isKindOfClass:UILabel.class]) {
            if (((UILabel *)subview).text.length != 0) return YES;
            continue;
        }
        return YES;
    }
    return NO;
}

static void YTKACECollectHeaderButtons(UIView *view, NSMutableArray<UIButton *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        CGSize size = subview.bounds.size;
        if ([subview isKindOfClass:UIButton.class] && size.width <= 64.0 && size.height <= 64.0 &&
            YTKACEButtonHasContent((UIButton *)subview)) {
            [buttons addObject:(UIButton *)subview];
            continue;
        }
        YTKACECollectHeaderButtons(subview, buttons);
    }
}

static void YTKACEUpdateHeader(UIView *header) {
    UIVisualEffectView *existing = objc_getAssociatedObject(header, YTKACEHeaderGlassAssociation);
    if (!YTKACEGlassChromeEnabled() || header.window == nil || CGRectIsEmpty(header.bounds)) {
        if (objc_getAssociatedObject(header, YTKACEHeaderTouchedAssociation) == nil) return;
        objc_setAssociatedObject(header, YTKACEHeaderTouchedAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [existing removeFromSuperview];
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
        while (queue.count != 0) {
            UIView *node = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(node.class) isEqualToString:@"YTLeftNavigationButtons"]) [rows addObject:node];
            else [queue addObjectsFromArray:node.subviews];
        }
        for (UIView *row in rows) {
            YTKACERestoreButtonsForKey(row, YTKACELeftGlassAssociation);
            YTKACERemoveChromeGlass(row, YTKACELeftGlassAssociation);
        }
        return;
    }
    objc_setAssociatedObject(header, YTKACEHeaderTouchedAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    YTKACECollectHeaderButtons(header, buttons);
    CGFloat width = CGRectGetWidth(header.bounds);
    UIButton *best = nil;
    CGFloat bestMinX = CGFLOAT_MAX;
    for (UIButton *button in buttons) {
        CGRect frame = [header convertRect:button.bounds fromView:button];
        if (CGRectGetMidX(frame) >= width * 0.5 || CGRectGetMinX(frame) > width * 0.28) continue;
        if (CGRectGetMinX(frame) < bestMinX) {
            bestMinX = CGRectGetMinX(frame);
            best = button;
        }
    }
    if (best == nil) {
        existing.hidden = YES;
        return;
    }
    UIView *row = best.superview;
    while (row != nil && row != header && ![NSStringFromClass(row.class) isEqualToString:@"YTLeftNavigationButtons"]) {
        row = row.superview;
    }
    if (YTKACENativeButtons() && row != nil && row != header) {
        [existing removeFromSuperview];
        YTKACEApplyNativeGlass(row, YTKACELeftGlassAssociation);
        return;
    }
    YTKACEPlaceCircle(header, YTKACEHeaderGlassAssociation, best, header);
}

static void YTKACEHeaderLayout(UIView *receiver, SEL selector) {
    if (OriginalHeaderLayout != NULL) ((void (*)(id, SEL))OriginalHeaderLayout)(receiver, selector);
    YTKACEUpdateHeader(receiver);
}

static void YTKACEHeaderMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalHeaderMoveToWindow != NULL) ((void (*)(id, SEL))OriginalHeaderMoveToWindow)(receiver, selector);
    if (receiver.window != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTKACEUpdateHeader(receiver); });
    }
}

static const void *YTKACEInsideGlassAssociation = &YTKACEInsideGlassAssociation;
static const void *YTKACEMirrorAssociation = &YTKACEMirrorAssociation;
static const void *YTKACEMirroredIconAssociation = &YTKACEMirroredIconAssociation;

static UIImageView *YTKACEFindIcon(UIView *view, UIView *skip) {
    for (UIView *subview in view.subviews) {
        if (subview == skip || subview.hidden) continue;
        if ([subview isKindOfClass:UIImageView.class] && ((UIImageView *)subview).image != nil &&
            !CGRectIsEmpty(subview.bounds)) {
            return (UIImageView *)subview;
        }
        UIImageView *found = YTKACEFindIcon(subview, skip);
        if (found != nil) return found;
    }
    return nil;
}

// The mirrored icon used to be stored with OBJC_ASSOCIATION_ASSIGN. Once
// YouTube released that image view, the next read handed ARC a dangling
// pointer and crashed. Keep a real weak reference instead.
@interface YTKACEGlassIconBox : NSObject
@property (nonatomic, weak) UIImageView *icon;
@end

@implementation YTKACEGlassIconBox
@end

static UIImageView *YTKACEMirroredIcon(UIView *button) {
    YTKACEGlassIconBox *box = objc_getAssociatedObject(button, YTKACEMirroredIconAssociation);
    return [box isKindOfClass:YTKACEGlassIconBox.class] ? box.icon : nil;
}

static void YTKACESetMirroredIcon(UIView *button, UIImageView *icon) {
    YTKACEGlassIconBox *box = nil;
    if (icon != nil) {
        box = [YTKACEGlassIconBox new];
        box.icon = icon;
    }
    objc_setAssociatedObject(button, YTKACEMirroredIconAssociation, box,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL YTKACEMirrorIcon(UIView *button, UIVisualEffectView *glass) {
    UIImageView *icon = YTKACEMirroredIcon(button);
    if (icon == nil || icon.superview == nil || ![icon isDescendantOfView:button]) {
        icon = YTKACEFindIcon(button, glass);
        YTKACESetMirroredIcon(button, icon);
    }
    UIImageView *mirror = objc_getAssociatedObject(button, YTKACEMirrorAssociation);
    if (icon == nil) {
        [mirror removeFromSuperview];
        return NO;
    }
    if (mirror == nil) {
        mirror = [UIImageView new];
        mirror.userInteractionEnabled = NO;
        objc_setAssociatedObject(button, YTKACEMirrorAssociation, mirror, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (mirror.superview != glass.contentView) [glass.contentView addSubview:mirror];
    mirror.image = icon.image;
    mirror.tintColor = icon.tintColor;
    mirror.contentMode = icon.contentMode;
    mirror.frame = [icon convertRect:icon.bounds toView:glass.contentView];
    icon.alpha = 0.0;
    return YES;
}

static const void *YTKACEQuietButtonAssociation = &YTKACEQuietButtonAssociation;
static IMP OriginalQTMSetBackground;
static IMP OriginalQTMTouchesBegan;

static BOOL YTKACEButtonIsQuiet(UIView *button) {
    return YTKACEGlassChromeEnabled() && objc_getAssociatedObject(button, YTKACEQuietButtonAssociation) != nil;
}

static void YTKACEHideButtonFeedback(UIView *button) {
    for (NSString *key in @[@"_touchFeedbackView", @"_inkView", @"_hitTargetBorderView"]) {
        id view = nil;
        @try { view = [button valueForKey:key]; } @catch (__unused NSException *exception) {}
        if ([view isKindOfClass:UIView.class]) {
            ((UIView *)view).hidden = YES;
            ((UIView *)view).alpha = 0.0;
        }
    }
}

static void YTKACEQuietSystemButton(UIView *button) {
    if (![button isKindOfClass:UIButton.class]) return;
    for (UIView *subview in button.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"_UISystemBackgroundView"]) continue;
        subview.hidden = NO;
        subview.alpha = 1.0;
        for (UIView *fill in subview.subviews) {
            CGFloat alpha = fill.backgroundColor != nil ? CGColorGetAlpha(fill.backgroundColor.CGColor) : 0.0;
            if (alpha > 0.0 || fill.layer.borderWidth > 0.0) fill.alpha = 0.0;
        }
    }
}

static void YTKACEQuietButton(UIView *button) {
    static Class qtmClass;
    if (qtmClass == Nil) qtmClass = NSClassFromString(@"YTLightweightQTMButton");
    YTKACEQuietSystemButton(button);
    if (qtmClass == Nil || ![button isKindOfClass:qtmClass]) return;
    objc_setAssociatedObject(button, YTKACEQuietButtonAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEHideButtonFeedback(button);
    SEL enabled = NSSelectorFromString(@"setEnabledBackgroundColor:");
    if ([button respondsToSelector:enabled]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, enabled, UIColor.clearColor);
    }
    button.backgroundColor = UIColor.clearColor;
    button.layer.backgroundColor = UIColor.clearColor.CGColor;
}

static void YTKACEQuietButtonsIn(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIButton.class]) YTKACEQuietButton(subview);
        YTKACEQuietButtonsIn(subview);
    }
}

static void YTKACEQTMSetBackground(UIView *receiver, SEL selector, UIColor *color) {
    if (YTKACEButtonIsQuiet(receiver)) color = UIColor.clearColor;
    if (OriginalQTMSetBackground != NULL) ((void (*)(id, SEL, id))OriginalQTMSetBackground)(receiver, selector, color);
}

static void YTKACEQTMTouchesBegan(UIView *receiver, SEL selector, NSSet *touches, UIEvent *event) {
    if (OriginalQTMTouchesBegan != NULL) {
        ((void (*)(id, SEL, id, id))OriginalQTMTouchesBegan)(receiver, selector, touches, event);
    }
    if (YTKACEButtonIsQuiet(receiver)) YTKACEHideButtonFeedback(receiver);
}

static BOOL YTKACEInsideGlassView(UIView *view, UIView *stop) {
    for (UIView *current = view.superview; current != nil && current != stop; current = current.superview) {
        if ([current isKindOfClass:UIVisualEffectView.class]) return YES;
    }
    return NO;
}

static void YTKACEGlassInsideButton(UIView *button, CGFloat side) {
    YTKACEQuietButton(button);
    if ([button.superview isKindOfClass:NSClassFromString(@"_UIVisualEffectContentView")]) {
        return;
    }
    UIVisualEffectView *glass = objc_getAssociatedObject(button, YTKACEInsideGlassAssociation);
    if (glass == nil) {
        glass = YTKACEChromeGlass(button, YTKACEInsideGlassAssociation);
        UIVisualEffect *effect = glass.effect;
        SEL interactive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:interactive]) {
            UIVisualEffect *copy = [effect copy];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, interactive, YES);
            glass.effect = copy;
        }
        glass.userInteractionEnabled = YES;
        glass.clipsToBounds = YES;
        if ([button isKindOfClass:UIControl.class]) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:YTKACETapProbe.shared
                                                                                  action:@selector(forward:)];
            tap.cancelsTouchesInView = NO;
            [glass addGestureRecognizer:tap];
        }
    }
    if (glass.superview != button) [button insertSubview:glass atIndex:0];
    else [button sendSubviewToBack:glass];
    CGRect bounds = button.bounds;
    glass.frame = CGRectMake(CGRectGetMidX(bounds) - side * 0.5, CGRectGetMidY(bounds) - side * 0.5, side, side);
    glass.layer.cornerRadius = side * 0.5;
    glass.hidden = NO;
    button.clipsToBounds = NO;
    YTKACEMirrorIcon(button, glass);
}

static void YTKACEClearInsideGlass(UIView *button) {
    UIView *glass = objc_getAssociatedObject(button, YTKACEInsideGlassAssociation);
    [glass removeFromSuperview];
    UIImageView *icon = YTKACEMirroredIcon(button);
    icon.alpha = 1.0;
}

static void YTKACECollectButtons(UIView *view, NSMutableArray<UIView *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIButton.class]) {
            [buttons addObject:subview];
            continue;
        }
        YTKACECollectButtons(subview, buttons);
    }
}

static void YTKACEUpdateMultiSearch(UIView *field) {
    UIView *pill = field.superview;
    UIView *strip = pill.superview;
    if (pill == nil || strip == nil) return;
    if (!YTKACEGlassChromeEnabled() || field.window == nil || CGRectIsEmpty(pill.bounds)) {
        YTKACERemoveChromeGlass(pill, YTKACEPillGlassAssociation);
        return;
    }
    UIVisualEffectView *glass = YTKACEChromeGlass(pill, YTKACEPillGlassAssociation);
    if (glass.superview != pill) [pill insertSubview:glass atIndex:0];
    else [pill sendSubviewToBack:glass];
    glass.frame = pill.bounds;
    glass.layer.cornerRadius = pill.layer.cornerRadius > 0.0 ? pill.layer.cornerRadius : CGRectGetHeight(pill.bounds) * 0.5;
    pill.backgroundColor = UIColor.clearColor;
    pill.layer.backgroundColor = UIColor.clearColor.CGColor;
    CGRect pillFrame = [pill convertRect:pill.bounds toView:strip];
    NSHashTable<UIView *> *known = objc_getAssociatedObject(strip, YTKACESideButtonsAssociation);
    for (UIView *button in known) {
        UIView *wrap = objc_getAssociatedObject(button, YTKACEWrapGlassAssociation);
        if (wrap != nil && !button.hidden && button.alpha > 0.01) wrap.hidden = NO;
    }
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *subview in strip.subviews) {
        if (subview == pill || subview.hidden || subview.alpha <= 0.01) continue;
        if ([subview isKindOfClass:UIButton.class]) [buttons addObject:subview];
        else YTKACECollectButtons(subview, buttons);
    }
    NSUInteger rightSide = 0;
    for (UIView *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:strip];
        if (CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0 && CGRectGetWidth(frame) <= 64.0) rightSide++;
    }
    NSHashTable<UIView *> *previous = objc_getAssociatedObject(strip, YTKACESideButtonsAssociation);
    NSHashTable<UIView *> *current = [NSHashTable weakObjectsHashTable];
    for (UIView *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:strip];
        BOOL beside = CGRectGetMaxX(frame) <= CGRectGetMinX(pillFrame) + 2.0 ||
            CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0;
        BOOL small = CGRectGetWidth(frame) <= 64.0 && CGRectGetHeight(frame) <= 64.0;
        if (!beside || !small) continue;
        BOOL grouped = CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0 && rightSide > 1;
        if (grouped || YTKACEInsideGlassView(button, strip)) {
            YTKACEClearInsideGlass(button);
            YTKACEQuietButton(button);
            continue;
        }
        YTKACEGlassInsideButton(button, CGRectGetHeight(pillFrame));
        YTKACERemoveChromeGlass(button, YTKACESideGlassAssociation);
        [current addObject:button];
    }
    for (UIView *button in previous) {
        if ([current containsObject:button]) continue;
        YTKACERemoveChromeGlass(button, YTKACESideGlassAssociation);
        UIView *wrap = objc_getAssociatedObject(button, YTKACEWrapGlassAssociation);
        wrap.hidden = YES;
    }
    objc_setAssociatedObject(strip, YTKACESideButtonsAssociation, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP OriginalSearchBarLayout;

static void YTKACESearchBarLayout(UIView *receiver, SEL selector) {
    if (OriginalSearchBarLayout != NULL) ((void (*)(id, SEL))OriginalSearchBarLayout)(receiver, selector);
    if (!YTKACEGlassChromeEnabled() || CGRectIsEmpty(receiver.bounds)) {
        YTKACERemoveChromeGlass(receiver, YTKACESearchBarGlassAssociation);
        return;
    }
    UIVisualEffectView *glass = YTKACEChromeGlass(receiver, YTKACESearchBarGlassAssociation);
    if (glass.superview != receiver) [receiver insertSubview:glass atIndex:0];
    else if (receiver.subviews.firstObject != glass) [receiver sendSubviewToBack:glass];
    glass.frame = receiver.bounds;
    glass.layer.cornerRadius = CGRectGetHeight(receiver.bounds) * 0.5;
    receiver.backgroundColor = UIColor.clearColor;
}

static void YTKACEMultiSearchLayout(UIView *receiver, SEL selector) {
    if (OriginalMultiSearchLayout != NULL) ((void (*)(id, SEL))OriginalMultiSearchLayout)(receiver, selector);
    YTKACEUpdateMultiSearch(receiver);
}

static void YTKACEMultiSearchMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalMultiSearchMoveToWindow != NULL) {
        ((void (*)(id, SEL))OriginalMultiSearchMoveToWindow)(receiver, selector);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ YTKACEUpdateMultiSearch(receiver); });
}

static void YTKACECollectTopButtons(UIView *view, UIView *window, NSMutableArray<UIView *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:window];
        if (CGRectGetMinY(frame) > 140.0) continue;
        BOOL isButton = [subview isKindOfClass:UIButton.class]
            ? YTKACEButtonHasContent((UIButton *)subview)
            : ([subview isKindOfClass:UIControl.class] && ![subview isKindOfClass:UITextField.class] &&
               ![subview isKindOfClass:UISearchBar.class] && subview.subviews.count != 0);
        if (isButton && CGRectGetWidth(frame) <= 64.0 && CGRectGetHeight(frame) <= 64.0 &&
            CGRectGetWidth(frame) >= 20.0) {
            [buttons addObject:subview];
            continue;
        }
        YTKACECollectTopButtons(subview, window, buttons);
    }
}

static void YTKACEShareBarItems(UINavigationItem *item) {
    if (item == nil) return;
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    [items addObjectsFromArray:item.leftBarButtonItems ?: @[]];
    [items addObjectsFromArray:item.rightBarButtonItems ?: @[]];
    if (item.backBarButtonItem != nil) [items addObject:item.backBarButtonItem];
    SEL getter = NSSelectorFromString(@"hidesSharedBackground");
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    BOOL wanted = !YTKACEGlassChromeEnabled();
    for (UIBarButtonItem *barItem in items) {
        if (![barItem respondsToSelector:getter] || ![barItem respondsToSelector:setter]) continue;
        BOOL before = ((BOOL (*)(id, SEL))objc_msgSend)(barItem, getter);
        if (before != wanted) ((void (*)(id, SEL, BOOL))objc_msgSend)(barItem, setter, wanted);
    }
}

static void YTKACEUpdateSettingsButtons(UIViewController *controller) {
    UIView *window = controller.view.window;
    if (window == nil) return;
    BOOL enabled = YTKACEGlassChromeEnabled();
    if (!enabled && objc_getAssociatedObject(controller, YTKACESettingsTouchedAssociation) == nil) return;
    objc_setAssociatedObject(controller, YTKACESettingsTouchedAssociation, enabled ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEShareBarItems(controller.navigationItem);
    UIViewController *top = controller.navigationController.topViewController;
    if (top != nil && top != controller) YTKACEShareBarItems(top.navigationItem);
    NSMutableArray<UIView *> *roots = [NSMutableArray arrayWithObject:controller.view];
    UINavigationBar *bar = controller.navigationController.navigationBar;
    if (bar != nil && !bar.hidden) [roots addObject:bar];
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *root in roots) YTKACECollectTopButtons(root, window, buttons);
    for (UIView *button in buttons) {
        BOOL inBar = bar != nil && [button isDescendantOfView:bar];
        if (enabled && inBar) {
            YTKACEClearInsideGlass(button);
            YTKACEQuietButton(button);
        } else if (enabled) {
            YTKACEGlassInsideButton(button, 36.0);
        } else {
            YTKACEClearInsideGlass(button);
        }
    }
}

static void YTKACESettingsLayout(UIViewController *receiver, SEL selector) {
    if (OriginalSettingsLayout != NULL) ((void (*)(id, SEL))OriginalSettingsLayout)(receiver, selector);
    YTKACEUpdateSettingsButtons(receiver);
}

static void YTKACEBarItemSetHidesShared(UIBarButtonItem *receiver, SEL selector, BOOL hides) {
    BOOL applied = YTKACEGlassChromeEnabled() ? NO : hides;
    if (hides && !applied) {
    }
    if (OriginalSetHidesShared != NULL) ((void (*)(id, SEL, BOOL))OriginalSetHidesShared)(receiver, selector, applied);
}

static void YTKACEShareItems(NSArray<UIBarButtonItem *> *items) {
    if (!YTKACEGlassChromeEnabled()) return;
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    for (UIBarButtonItem *item in items) {
        if ([item respondsToSelector:setter]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, NO);
    }
}

static void YTKACESetLeftItems(UINavigationItem *receiver, SEL selector, NSArray *items, BOOL animated) {
    YTKACEShareItems(items);
    if (OriginalSetLeftItems != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetLeftItems)(receiver, selector, items, animated);
}

static void YTKACESetRightItems(UINavigationItem *receiver, SEL selector, NSArray *items, BOOL animated) {
    YTKACEShareItems(items);
    if (OriginalSetRightItems != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetRightItems)(receiver, selector, items, animated);
}

static void YTKACESetLeftItem(UINavigationItem *receiver, SEL selector, UIBarButtonItem *item, BOOL animated) {
    if (item != nil) YTKACEShareItems(@[item]);
    if (OriginalSetLeftItem != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetLeftItem)(receiver, selector, item, animated);
}

static void YTKACESetRightItem(UINavigationItem *receiver, SEL selector, UIBarButtonItem *item, BOOL animated) {
    if (item != nil) YTKACEShareItems(@[item]);
    if (OriginalSetRightItem != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetRightItem)(receiver, selector, item, animated);
}

static void YTKACETopRefreshSoon(UIView *container) {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEApplyTopNavigationGlass(container);
    });
}

static void YTKACETopMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalTopMoveToWindow != NULL) ((void (*)(id, SEL))OriginalTopMoveToWindow)(receiver, selector);
    YTKACETopRefreshSoon(receiver);
}

static void YTKACETopMoveToSuperview(UIView *receiver, SEL selector) {
    if (OriginalTopMoveToSuperview != NULL) ((void (*)(id, SEL))OriginalTopMoveToSuperview)(receiver, selector);
    YTKACETopRefreshSoon(receiver);
}

__attribute__((constructor)) static void YTKACEInstallGlassChrome(void) {
    if (!YTKACELiquidGlassAvailable()) return;
    YTKACEInstallInstanceHook(@"YTLightweightQTMButton", @"setBackgroundColor:",
                              (IMP)YTKACEQTMSetBackground, &OriginalQTMSetBackground);
    YTKACEInstallInstanceHook(@"YTLightweightQTMButton", @"touchesBegan:withEvent:",
                              (IMP)YTKACEQTMTouchesBegan, &OriginalQTMTouchesBegan);
    YTKACEInstallInstanceHook(@"YTRightNavigationButtons", @"didMoveToWindow",
                              (IMP)YTKACETopMoveToWindow, &OriginalTopMoveToWindow);
    YTKACEInstallInstanceHook(@"YTRightNavigationButtons", @"didMoveToSuperview",
                              (IMP)YTKACETopMoveToSuperview, &OriginalTopMoveToSuperview);
    if (!YTKACEGlassChromeEnabled()) return;
    YTKACEInstallInstanceHook(@"YTMultiLineSearchBarView", @"layoutSubviews",
                                           (IMP)YTKACEMultiSearchLayout, &OriginalMultiSearchLayout);
    YTKACEInstallInstanceHook(@"YTSearchBarView", @"layoutSubviews",
                              (IMP)YTKACESearchBarLayout, &OriginalSearchBarLayout);
    YTKACEInstallInstanceHook(@"YTMultiLineSearchBarView", @"didMoveToWindow",
                              (IMP)YTKACEMultiSearchMoveToWindow, &OriginalMultiSearchMoveToWindow);
    YTKACEInstallInstanceHook(@"UIBarButtonItem", @"setHidesSharedBackground:",
                                            (IMP)YTKACEBarItemSetHidesShared, &OriginalSetHidesShared);
    YTKACEInstallInstanceHook(@"UINavigationItem", @"setLeftBarButtonItems:animated:",
                                               (IMP)YTKACESetLeftItems, &OriginalSetLeftItems);
    YTKACEInstallInstanceHook(@"UINavigationItem", @"setRightBarButtonItems:animated:",
                                                (IMP)YTKACESetRightItems, &OriginalSetRightItems);
    YTKACEInstallInstanceHook(@"UINavigationItem", @"setLeftBarButtonItem:animated:",
                                              (IMP)YTKACESetLeftItem, &OriginalSetLeftItem);
    YTKACEInstallInstanceHook(@"UINavigationItem", @"setRightBarButtonItem:animated:",
                                               (IMP)YTKACESetRightItem, &OriginalSetRightItem);
    YTKACEInstallInstanceHook(@"YTSettingsViewController", @"viewDidLayoutSubviews",
                                              (IMP)YTKACESettingsLayout, &OriginalSettingsLayout);
    YTKACEInstallInstanceHook(@"YTHeaderView", @"layoutSubviews",
                                            (IMP)YTKACEHeaderLayout, &OriginalHeaderLayout);
    YTKACEInstallInstanceHook(@"YTHeaderView", @"didMoveToWindow",
                              (IMP)YTKACEHeaderMoveToWindow, &OriginalHeaderMoveToWindow);
}
