#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <string.h>



static IMP OriginalCommentNodeDidLoad;
static IMP OriginalCommentViewSetNode;
static IMP OriginalCommentUIViewDidMove;
static IMP OriginalCommentNodeSetFrame;
static const void *YTKACEStoredCommentAssociation = &YTKACEStoredCommentAssociation;
static const void *YTKACECommentTextAssociation = &YTKACECommentTextAssociation;
static const void *YTKACECommentNodeAssociation = &YTKACECommentNodeAssociation;
static const void *YTKACECommentGestureAssociation = &YTKACECommentGestureAssociation;

// Holds the comment node without retaining it: the node owns its view, so a
// strong view -> node association would form a retain cycle and leak every
// comment cell.
@interface YTKACEWeakCommentNode : NSObject
@property (nonatomic, weak) id node;
@end

@implementation YTKACEWeakCommentNode
@end

static id YTKACEAssociatedCommentNode(id view) {
    YTKACEWeakCommentNode *box =
        objc_getAssociatedObject(view, YTKACECommentNodeAssociation);
    return [box isKindOfClass:YTKACEWeakCommentNode.class] ? box.node : nil;
}

static id YTKACEObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static NSString *YTKACECleanCommentText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *cleaned = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return cleaned.length == 0 ? nil : cleaned;
}

static BOOL YTKACEIsCommentToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment"] ||
           [lower containsString:@"id_ui_comment_cell"];
}

static BOOL YTKACEIsCommentTextToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment_content"] ||
           [lower containsString:@"comment_text"] ||
           [lower containsString:@"comment_body"];
}

static NSString *YTKACECommentTextInNode(id node, NSUInteger depth) {
    if (node == nil || depth > 16) {
        return nil;
    }
    NSString *stored = YTKACECleanCommentText(
        objc_getAssociatedObject(node, YTKACECommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    id attributedText = YTKACEObjectMessage(node, @"attributedText");
    NSString *text = YTKACECleanCommentText(
        YTKACEObjectMessage(attributedText, @"string")
    );
    if (text.length != 0) {
        NSString *identifier = YTKACEObjectMessage(node, @"accessibilityIdentifier");
        NSString *description = [node description];
        if (YTKACEIsCommentTextToken([NSString stringWithFormat:@"%@ %@",
                identifier ?: @"", description ?: @""])) {
            return text;
        }
    }
    NSArray *children = YTKACEObjectMessage(node, @"subnodes");
    if (![children isKindOfClass:NSArray.class]) {
        children = YTKACEObjectMessage(node, @"children");
    }
    for (id child in children) {
        NSString *candidate = YTKACECommentTextInNode(child, depth + 1);
        if (candidate.length != 0) {
            return candidate;
        }
    }
    return nil;
}

static NSString *YTKACETextFromView(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return YTKACECleanCommentText(((UILabel *)view).text);
    }
    if ([view isKindOfClass:UITextView.class]) {
        return YTKACECleanCommentText(((UITextView *)view).text);
    }
    NSString *label = YTKACECleanCommentText(view.accessibilityLabel);
    return [view isKindOfClass:UIControl.class] ? nil : label;
}

static NSString *YTKACECommentTextInView(UIView *view, BOOL exact,
                                         NSUInteger depth) {
    if (view == nil || depth > 16) {
        return nil;
    }
    NSString *stored = YTKACECleanCommentText(
        objc_getAssociatedObject(view, YTKACECommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"",
        NSStringFromClass(view.class) ?: @"",
        [view description] ?: @""];
    NSString *ownText = YTKACETextFromView(view);
    if (ownText.length != 0 && (!exact || YTKACEIsCommentTextToken(token))) {
        return ownText;
    }
    id node = YTKACEAssociatedCommentNode(view);
    if (node == nil) {
        node = YTKACEObjectMessage(view, @"keepalive_node");
    }
    NSString *nodeText = YTKACECommentTextInNode(node, 0);
    if (nodeText.length != 0) {
        return nodeText;
    }
    NSString *best = nil;
    for (UIView *subview in view.subviews) {
        NSString *candidate = YTKACECommentTextInView(subview, exact, depth + 1);
        if (candidate.length > best.length) {
            best = candidate;
        }
    }
    NSArray *elements = view.accessibilityElements;
    for (id element in elements) {
        NSString *identifier = YTKACEObjectMessage(element, @"accessibilityIdentifier");
        NSString *label = YTKACECleanCommentText(
            YTKACEObjectMessage(element, @"accessibilityLabel")
        );
        if (label.length != 0 &&
            (!exact || YTKACEIsCommentTextToken(identifier ?: @"")) &&
            label.length > best.length) {
            best = label;
        }
    }
    return best;
}

static UIViewController *YTKACEControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    UIViewController *controller = view.window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static NSString *YTKACEStoredCommentForView(UIView *view) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        NSString *direct = objc_getAssociatedObject(
            candidate, YTKACEStoredCommentAssociation);
        if ([direct isKindOfClass:NSString.class] && direct.length != 0) {
            return direct;
        }
        id node = YTKACEAssociatedCommentNode(candidate);
        if (node == nil) node = YTKACEObjectMessage(candidate, @"keepalive_node");
        for (NSUInteger depth = 0; node != nil && depth < 14; depth++) {
            NSString *stored = objc_getAssociatedObject(
                node, YTKACEStoredCommentAssociation);
            if ([stored isKindOfClass:NSString.class] && stored.length != 0) {
                return stored;
            }
            node = YTKACEObjectMessage(node, @"supernode");
        }
    }
    return nil;
}

static NSString *YTKACECommentTextForView(UIView *view) {
    NSString *stored = YTKACEStoredCommentForView(view);
    if (stored.length != 0) return stored;
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate != nil && depth < 8; depth++) {
        NSString *text = YTKACECommentTextInView(candidate, YES, 0);
        if (text.length != 0) {
            return text;
        }
        candidate = candidate.superview;
    }
    return nil;
}

@interface YTKACECopyCommentTarget : NSObject
+ (instancetype)sharedTarget;
- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture;
@end

@implementation YTKACECopyCommentTarget
+ (instancetype)sharedTarget {
    static YTKACECopyCommentTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACECopyCommentTarget new]; });
    return target;
}

- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !YTKACEMasterEnabled()) {
        return;
    }
    UIView *view = gesture.view;
    NSString *text = YTKACECommentTextForView(view);
    if (text.length == 0) {
        return;
    }
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Copy Comment")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            UINotificationFeedbackGenerator *confirmation =
                [UINotificationFeedbackGenerator new];
            [confirmation notificationOccurred:UINotificationFeedbackTypeSuccess];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = view;
    menu.popoverPresentationController.sourceRect = view.bounds;
    UIViewController *controller = YTKACEControllerForView(view);
    if (controller.presentedViewController == nil) {
        [controller presentViewController:menu animated:YES completion:nil];
    }
}
@end

static void YTKACEAttachCommentGesture(UIView *view, id node) {
    if (view == nil) {
        return;
    }
    if (node != nil) {
        YTKACEWeakCommentNode *box =
            objc_getAssociatedObject(view, YTKACECommentNodeAssociation);
        if (![box isKindOfClass:YTKACEWeakCommentNode.class]) {
            box = [YTKACEWeakCommentNode new];
            objc_setAssociatedObject(view, YTKACECommentNodeAssociation,
                                     box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        box.node = node;
    }
    if (objc_getAssociatedObject(view, YTKACECommentGestureAssociation) != nil) {
        return;
    }
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:YTKACECopyCommentTarget.sharedTarget
                action:@selector(handleCopyComment:)];
    gesture.minimumPressDuration = 0.25;
    gesture.cancelsTouchesInView = NO;
    [view addGestureRecognizer:gesture];
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view, YTKACECommentGestureAssociation,
                             gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL YTKACEIsCommentContainer(id node) {
    NSString *description = [node description];
    return [description containsString:@"id.ui.comment_cell"] ||
           [description containsString:@"id.ui.comment_thread"] ||
           [description containsString:@"comment_reply"];
}

// Per-class facts for the ASDisplayNode setFrame: hook, which runs on every
// layout pass of every node (possibly off the main thread).
enum {
    YTKACECommentClassKnown = 1 << 0,
    YTKACECommentClassHasText = 1 << 1,
    YTKACECommentClassNoKVCIdentifier = 1 << 2,
};
static os_unfair_lock YTKACECommentClassLock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef YTKACECommentClassFlags;

static uintptr_t YTKACECommentFlagsForClass(Class cls) {
    os_unfair_lock_lock(&YTKACECommentClassLock);
    uintptr_t flags = YTKACECommentClassFlags == NULL ? 0 :
        (uintptr_t)CFDictionaryGetValue(YTKACECommentClassFlags, (__bridge void *)cls);
    os_unfair_lock_unlock(&YTKACECommentClassLock);
    if (flags != 0) return flags;
    flags = YTKACECommentClassKnown;
    if ([cls instancesRespondToSelector:@selector(attributedText)]) {
        flags |= YTKACECommentClassHasText;
    }
    os_unfair_lock_lock(&YTKACECommentClassLock);
    if (YTKACECommentClassFlags == NULL) {
        YTKACECommentClassFlags = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, NULL, NULL);
    }
    CFDictionarySetValue(YTKACECommentClassFlags, (__bridge void *)cls, (void *)flags);
    os_unfair_lock_unlock(&YTKACECommentClassLock);
    return flags;
}

static void YTKACEMarkCommentClassFlag(Class cls, uintptr_t flag) {
    uintptr_t flags = YTKACECommentFlagsForClass(cls) | flag;
    os_unfair_lock_lock(&YTKACECommentClassLock);
    CFDictionarySetValue(YTKACECommentClassFlags, (__bridge void *)cls, (void *)flags);
    os_unfair_lock_unlock(&YTKACECommentClassLock);
}

static NSString *YTKACENodeIdentifier(id node, uintptr_t classFlags) {
    NSString *identifier = YTKACEObjectMessage(node, @"accessibilityIdentifier");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0) {
        return identifier;
    }
    // valueForKey: on a class without the key throws; remember such classes
    // instead of throwing (and catching) an exception on every layout pass.
    if (classFlags & YTKACECommentClassNoKVCIdentifier) return nil;
    @try {
        id value = [node valueForKey:@"_accessibilityIdentifier"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        YTKACEMarkCommentClassFlag(object_getClass(node),
                                   YTKACECommentClassNoKVCIdentifier);
        return nil;
    }
}

static void YTKACEStoreCommentOnContainers(id node, NSString *text) {
    id supernodes = YTKACEObjectMessage(node, @"supernodes");
    NSArray *all = nil;
    if ([supernodes respondsToSelector:@selector(allObjects)]) {
        all = [supernodes allObjects];
    } else if ([supernodes isKindOfClass:NSArray.class]) {
        all = supernodes;
    }
    for (id container in all) {
        if (!YTKACEIsCommentContainer(container)) continue;
        objc_setAssociatedObject(container, YTKACEStoredCommentAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        UIView *rendered = YTKACEObjectMessage(container, @"view");
        if ([rendered isKindOfClass:UIView.class]) {
            objc_setAssociatedObject(rendered, YTKACEStoredCommentAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        return;
    }
}

static void YTKACECommentNodeSetFrame(id receiver, SEL selector, CGRect frame) {
    if (OriginalCommentNodeSetFrame != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalCommentNodeSetFrame)(receiver, selector,
                                                                 frame);
    }
    // Only text nodes can carry the comment text; skip everything else before
    // looking at identifiers.
    uintptr_t classFlags = YTKACECommentFlagsForClass(object_getClass(receiver));
    if (!(classFlags & YTKACECommentClassHasText)) return;
    NSString *identifier = YTKACENodeIdentifier(receiver, classFlags);
    if (identifier.length == 0) return;
    if (![identifier isEqualToString:@"id.comment.content.label"]) return;
    id attributed = YTKACEObjectMessage(receiver, @"attributedText");
    NSString *text = YTKACECleanCommentText(
        YTKACEObjectMessage(attributed, @"string"));
    if (text.length == 0) return;
    YTKACEStoreCommentOnContainers(receiver, text);
}

static void YTKACECommentNodeDidLoad(id receiver, SEL selector) {
    if (OriginalCommentNodeDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalCommentNodeDidLoad)(receiver, selector);
    }
    // Read the text first: it is cheap and empty for most nodes, while the
    // node description is expensive to build.
    id attributedText = YTKACEObjectMessage(receiver, @"attributedText");
    NSString *text = YTKACECleanCommentText(
        YTKACEObjectMessage(attributedText, @"string")
    );
    if (text.length == 0) {
        return;
    }
    NSString *identifier = YTKACEObjectMessage(receiver, @"accessibilityIdentifier");
    NSString *token = [NSString stringWithFormat:@"%@ %@",
        identifier ?: @"", [receiver description] ?: @""];
    if (!YTKACEIsCommentTextToken(token)) {
        return;
    }
    objc_setAssociatedObject(receiver, YTKACECommentTextAssociation,
                             text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIView *renderedView = YTKACEObjectMessage(receiver, @"view");
    if ([renderedView isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(renderedView, YTKACECommentTextAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        YTKACEAttachCommentGesture(renderedView, receiver);
    }
    id parent = YTKACEObjectMessage(receiver, @"yogaParent");
    for (NSUInteger depth = 0; parent != nil && depth < 16; depth++) {
        if (YTKACEIsCommentToken([parent description])) {
            objc_setAssociatedObject(parent, YTKACECommentTextAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        parent = YTKACEObjectMessage(parent, @"yogaParent");
    }
}

static void YTKACECommentViewSetNode(UIView *receiver, SEL selector, id node) {
    if (OriginalCommentViewSetNode != NULL) {
        ((void (*)(id, SEL, id))OriginalCommentViewSetNode)(receiver, selector, node);
    }
    YTKACEProfileConsiderDisplayView(receiver, node);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class) ?: @"",
        [receiver description] ?: @"", [node description] ?: @""];
    // The subtree text search is only needed when the token did not match.
    if (YTKACEIsCommentToken(token) || YTKACECommentTextInNode(node, 0).length != 0) {
        YTKACEAttachCommentGesture(receiver, node);
    }
}

static void YTKACECommentUIViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalCommentUIViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalCommentUIViewDidMove)(receiver, selector);
    }
    // Runs for every view entering or leaving a window: match the class name
    // and accessibility identifier directly instead of formatting and
    // lowercasing the full view description. Texture views are covered by the
    // setKeepalive_node: hook, which still inspects the node description.
    const char *className = class_getName([receiver class]);
    NSString *identifier = receiver.accessibilityIdentifier;
    if ((className != NULL && strcasestr(className, "comment") != NULL) ||
        (identifier.length != 0 &&
         [identifier rangeOfString:@"comment"
                           options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        YTKACEAttachCommentGesture(receiver,
            YTKACEObjectMessage(receiver, @"keepalive_node"));
    }
}

void YTKACEInstallCopyCommentHooks(void) {
    YTKACEInstallInstanceHook(@"ASDisplayNode", @"didLoad",
        (IMP)YTKACECommentNodeDidLoad, &OriginalCommentNodeDidLoad);
    YTKACEInstallInstanceHook(@"_ASDisplayView", @"setKeepalive_node:",
        (IMP)YTKACECommentViewSetNode, &OriginalCommentViewSetNode);
    YTKACEInstallInstanceHook(@"UIView", @"didMoveToWindow",
        (IMP)YTKACECommentUIViewDidMove, &OriginalCommentUIViewDidMove);
    YTKACEInstallInstanceHook(@"ASDisplayNode", @"setFrame:",
        (IMP)YTKACECommentNodeSetFrame, &OriginalCommentNodeSetFrame);
}
