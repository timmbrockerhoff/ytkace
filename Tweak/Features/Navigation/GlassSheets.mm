#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSheetLayout;
static IMP OriginalSheetAppear;
static IMP OriginalContextualAppear;
static IMP OriginalSheetWillAppear;
static IMP OriginalModalShow;
static IMP OriginalModalReposition;
static IMP OriginalContextualWillAppear;
static IMP OriginalContextualLayout;

static const void *YTKACESheetGlassAssociation = &YTKACESheetGlassAssociation;
static const void *YTKACESheetGlassPendingAssociation = &YTKACESheetGlassPendingAssociation;

static BOOL YTKACESheetGlassEnabled(void) {
    return YTKACELiquidGlassAvailable() && YTKACEFeatureEnabled(@"YTKACE.Preference.Glass.Menus");
}

static UIView *YTKACEFindViewOfClass(UIView *root, NSString *name) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count != 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static BOOL YTKACEColorIsSolid(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    return color != nil && [color getRed:&red green:&green blue:&blue alpha:&alpha] && alpha > 0.3;
}

static BOOL YTKACEIsSheetContainer(UIView *view) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"YTDraggableView", @"YTDialogContainerScrollView", @"GOODialogView",
                                      @"YTContextualWrapView", @"YTActionSheetHeaderView", @"UIScrollView",
                                      @"GOODialogContentView", @"YTMinimumWidthDialogView"]];
    });
    return [names containsObject:NSStringFromClass(view.class)];
}

static BOOL YTKACEIsELMRoot(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"ELMView"];
}

static BOOL YTKACEIsELMView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return YTKACEIsELMRoot(view) || [name hasPrefix:@"_AS"] || [name hasPrefix:@"AS"];
}

static void YTKACEClearELMBackground(UIView *view, UIView *sheet, NSInteger depth) {
    if (depth > 4) return;
    for (UIView *subview in view.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"_ASDisplayView"]) continue;
        if (YTKACEColorIsSolid(subview.backgroundColor) &&
            CGRectGetWidth(subview.bounds) >= CGRectGetWidth(sheet.bounds) * 0.9 &&
            CGRectGetHeight(subview.bounds) >= 40.0) {
            id node = nil;
            @try { node = [subview valueForKey:@"asyncdisplaykit_node"]; } @catch (__unused NSException *exception) {}
            if ([node respondsToSelector:@selector(setBackgroundColor:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setBackgroundColor:), UIColor.clearColor);
            } else {
                subview.backgroundColor = UIColor.clearColor;
            }
        }
        YTKACEClearELMBackground(subview, sheet, depth + 1);
    }
}

static void YTKACEClearSheetBackgrounds(UIView *view, UIView *sheet, UIView *glass, NSInteger depth) {
    if (depth > 10) return;
    for (UIView *subview in view.subviews) {
        if (subview == glass) continue;
        if (YTKACEIsELMRoot(subview)) {
            YTKACEClearELMBackground(subview, sheet, 0);
            continue;
        }
        if (YTKACEIsELMView(subview)) continue;
        if (YTKACEIsSheetContainer(subview) && YTKACEColorIsSolid(subview.backgroundColor)) {
            subview.backgroundColor = UIColor.clearColor;
        }
        YTKACEClearSheetBackgrounds(subview, sheet, glass, depth + 1);
    }
}

static UIVisualEffect *YTKACESheetGlassEffect(void) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    return [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
}

static void YTKACEClearShadows(UIView *view, UIView *stop) {
    for (UIView *current = view; current != nil && current != stop; current = current.superview) {
        if (current.layer.shadowOpacity > 0.0) current.layer.shadowOpacity = 0.0;
    }
}

static void YTKACEApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius);

static void YTKACEApplySheetGlass(UIViewController *controller) {
    if (!YTKACESheetGlassEnabled() || !controller.isViewLoaded) return;
    UIView *sheet = YTKACEFindViewOfClass(controller.view, @"YTDraggableView");
    if (sheet == nil) {
        sheet = YTKACEFindViewOfClass(controller.view, @"YTContextualWrapView");
        if (sheet != nil) {
            YTKACEClearShadows(sheet, controller.view.window);
            for (UIView *current = sheet; current != nil; current = current.superview) {
                SEL shadow = NSSelectorFromString(@"shadowLayer");
                if ([NSStringFromClass(current.class) isEqualToString:@"YTContextualSheetView"] &&
                    [current respondsToSelector:shadow]) {
                    CALayer *layer = ((id (*)(id, SEL))objc_msgSend)(current, shadow);
                    layer.shadowOpacity = 0.0;
                    layer.shadowPath = NULL;
                    current.layer.shadowOpacity = 0.0;
                    break;
                }
            }
        }
    }
    if (sheet == nil || CGRectIsEmpty(sheet.bounds)) return;
    YTKACEApplyPanelGlass(sheet, 24.0);
}

static void YTKACEApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius) {
    UIVisualEffectView *glass = objc_getAssociatedObject(sheet, YTKACESheetGlassAssociation);
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTKACESheetGlassEffect()];
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(sheet, YTKACESheetGlassAssociation, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != sheet) [sheet insertSubview:glass atIndex:0];
    else if (sheet.subviews.firstObject != glass) [sheet sendSubviewToBack:glass];
    glass.frame = sheet.bounds;
    CGFloat radius = sheet.layer.cornerRadius > 0.0 ? sheet.layer.cornerRadius : fallbackRadius;
    glass.layer.cornerRadius = radius;
    glass.layer.maskedCorners = sheet.layer.cornerRadius > 0.0 ? sheet.layer.maskedCorners
        : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    sheet.backgroundColor = UIColor.clearColor;
    YTKACEClearSheetBackgrounds(sheet, sheet, glass, 0);
}

static void YTKACEApplySheetGlassLater(UIViewController *controller) {
    if (!YTKACESheetGlassEnabled()) return;
    __weak UIViewController *weakController = controller;
    for (NSNumber *delay in @[@0.05, @0.15, @0.3, @0.5, @0.8, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strong = weakController;
            if (strong == nil || strong.view.window == nil) return;
            YTKACEApplySheetGlass(strong);
        });
    }
}

// viewWillLayoutSubviews can fire many times per run loop turn; one deferred
// application after the layout pass covers all of them.
static void YTKACEApplySheetGlassAsync(UIViewController *receiver) {
    if (objc_getAssociatedObject(receiver, YTKACESheetGlassPendingAssociation) != nil) return;
    objc_setAssociatedObject(receiver, YTKACESheetGlassPendingAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller == nil) return;
        objc_setAssociatedObject(controller, YTKACESheetGlassPendingAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACEApplySheetGlass(controller);
    });
}

static void YTKACESheetLayout(UIViewController *receiver, SEL selector) {
    if (OriginalSheetLayout != NULL) ((void (*)(id, SEL))OriginalSheetLayout)(receiver, selector);
    if (!YTKACESheetGlassEnabled()) return;
    YTKACEApplySheetGlassAsync(receiver);
}

static void YTKACESheetWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetWillAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetWillAppear)(receiver, selector, animated);
    if (!YTKACESheetGlassEnabled()) return;
    [receiver.view layoutIfNeeded];
    YTKACEApplySheetGlass(receiver);
}

static void YTKACEApplyModalGlass(UIView *modal) {
    if (!YTKACESheetGlassEnabled() || modal.window == nil) return;
    UIView *dialog = nil;
    @try { dialog = [modal valueForKey:@"_dialogView"]; } @catch (__unused NSException *exception) {}
    if (![dialog isKindOfClass:UIView.class] || CGRectIsEmpty(dialog.bounds)) return;
    YTKACEClearShadows(dialog, modal.superview);
    dialog.layer.shadowOpacity = 0.0;
    YTKACEApplyPanelGlass(dialog, 28.0);
    UIVisualEffectView *glass = objc_getAssociatedObject(dialog, YTKACESheetGlassAssociation);
    glass.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
        kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    if (dialog.layer.cornerRadius < 12.0) {
        dialog.layer.cornerRadius = 28.0;
        dialog.layer.cornerCurve = kCACornerCurveContinuous;
    }
    dialog.clipsToBounds = YES;
}

static IMP OriginalAlertLayout;
static IMP OriginalAlertReveal;
static IMP OriginalYTAlertLayout;
static IMP OriginalReportLayout;
static IMP OriginalReportReveal;
static IMP OriginalContextualBegin;
static IMP OriginalContextualContainerLayout;

static void YTKACEAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalAlertLayout != NULL) ((void (*)(id, SEL))OriginalAlertLayout)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEAlertReveal(UIView *receiver, SEL selector) {
    if (OriginalAlertReveal != NULL) ((void (*)(id, SEL))OriginalAlertReveal)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEYTAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalYTAlertLayout != NULL) ((void (*)(id, SEL))OriginalYTAlertLayout)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEReportLayout(UIView *receiver, SEL selector) {
    if (OriginalReportLayout != NULL) ((void (*)(id, SEL))OriginalReportLayout)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEReportReveal(UIView *receiver, SEL selector) {
    if (OriginalReportReveal != NULL) ((void (*)(id, SEL))OriginalReportReveal)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEContextualBegin(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualBegin != NULL) ((void (*)(id, SEL))OriginalContextualBegin)(receiver, selector);
    UIViewController *presented = receiver.presentedViewController;
    [presented.view layoutIfNeeded];
    YTKACEApplySheetGlass(presented);
}

static void YTKACEContextualContainerLayout(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalContextualContainerLayout)(receiver, selector);
    }
    YTKACEApplySheetGlass(receiver.presentedViewController);
}

static void YTKACEModalShow(UIView *receiver, SEL selector) {
    if (OriginalModalShow != NULL) ((void (*)(id, SEL))OriginalModalShow)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACEModalReposition(UIView *receiver, SEL selector) {
    if (OriginalModalReposition != NULL) ((void (*)(id, SEL))OriginalModalReposition)(receiver, selector);
    YTKACEApplyModalGlass(receiver);
}

static void YTKACESheetAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetAppear)(receiver, selector, animated);
    YTKACEApplySheetGlass(receiver);
    YTKACEApplySheetGlassLater(receiver);
}

static void YTKACEContextualAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalContextualAppear)(receiver, selector, animated);
    YTKACEApplySheetGlass(receiver);
    YTKACEApplySheetGlassLater(receiver);
}

static void YTKACEContextualWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualWillAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalContextualWillAppear)(receiver, selector, animated);
    }
    [receiver.view layoutIfNeeded];
    YTKACEApplySheetGlass(receiver);
}

static void YTKACEContextualLayout(UIViewController *receiver, SEL selector) {
    if (OriginalContextualLayout != NULL) ((void (*)(id, SEL))OriginalContextualLayout)(receiver, selector);
    if (!YTKACESheetGlassEnabled()) return;
    YTKACEApplySheetGlassAsync(receiver);
}

__attribute__((constructor)) static void YTKACEInstallGlassSheets(void) {
    if (!YTKACELiquidGlassAvailable()) return;
    YTKACEInstallInstanceHook(@"YTBottomSheetController", @"viewWillLayoutSubviews",
                              (IMP)YTKACESheetLayout, &OriginalSheetLayout);
    YTKACEInstallInstanceHook(@"YTBottomSheetController", @"viewDidAppear:",
                              (IMP)YTKACESheetAppear, &OriginalSheetAppear);
    YTKACEInstallInstanceHook(@"YTBottomSheetController", @"viewWillAppear:",
                              (IMP)YTKACESheetWillAppear, &OriginalSheetWillAppear);
    YTKACEInstallInstanceHook(@"GOOAlertView", @"layoutSubviews",
                              (IMP)YTKACEAlertLayout, &OriginalAlertLayout);
    YTKACEInstallInstanceHook(@"GOOAlertView", @"revealDialog",
                              (IMP)YTKACEAlertReveal, &OriginalAlertReveal);
    YTKACEInstallInstanceHook(@"YTAlertView", @"layoutSubviews",
                              (IMP)YTKACEYTAlertLayout, &OriginalYTAlertLayout);
    YTKACEInstallInstanceHook(@"YTReportFormModalAlertView", @"layoutSubviews",
                              (IMP)YTKACEReportLayout, &OriginalReportLayout);
    YTKACEInstallInstanceHook(@"YTReportFormModalAlertView", @"revealDialog",
                              (IMP)YTKACEReportReveal, &OriginalReportReveal);
    YTKACEInstallInstanceHook(@"YTContextualSheetPresentationController", @"presentationTransitionWillBegin",
                              (IMP)YTKACEContextualBegin, &OriginalContextualBegin);
    YTKACEInstallInstanceHook(@"YTContextualSheetPresentationController", @"containerViewDidLayoutSubviews",
                              (IMP)YTKACEContextualContainerLayout, &OriginalContextualContainerLayout);
    YTKACEInstallInstanceHook(@"GOOModalView", @"show",
                              (IMP)YTKACEModalShow, &OriginalModalShow);
    YTKACEInstallInstanceHook(@"GOOModalView", @"reposition",
                              (IMP)YTKACEModalReposition, &OriginalModalReposition);
    YTKACEInstallInstanceHook(@"YTContextualSheetViewController", @"viewDidAppear:",
                              (IMP)YTKACEContextualAppear, &OriginalContextualAppear);
    YTKACEInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillAppear:",
                              (IMP)YTKACEContextualWillAppear, &OriginalContextualWillAppear);
    YTKACEInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillLayoutSubviews",
                              (IMP)YTKACEContextualLayout, &OriginalContextualLayout);
}
