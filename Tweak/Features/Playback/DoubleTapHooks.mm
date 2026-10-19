#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSValue *> *YTKACEDoubleTapOriginals;
static const void *YTKACETapSeekHelperKey = &YTKACETapSeekHelperKey;

static BOOL YTKACECommitTapSeek(UIResponder *first, double time) {
    for (UIResponder *responder = first; responder != nil;
         responder = responder.nextResponder) {
        SEL detailed = NSSelectorFromString(@"seekToTime:seekSource:");
        SEL simple = NSSelectorFromString(@"seekToTime:");
        SEL legacy = NSSelectorFromString(
            @"didSeekToTime:toleranceBefore:toleranceAfter:");
        if ([responder respondsToSelector:detailed]) {
            ((void (*)(id, SEL, double, NSInteger))objc_msgSend)(
                responder, detailed, time, 0);
            return YES;
        }
        if ([responder respondsToSelector:simple]) {
            ((void (*)(id, SEL, double))objc_msgSend)(responder, simple, time);
            return YES;
        }
        if ([responder respondsToSelector:legacy]) {
            ((void (*)(id, SEL, double, double, double))objc_msgSend)(
                responder, legacy, time, 0.0, 0.0);
            return YES;
        }
    }
    return NO;
}

static double YTKACEMaximumSeekableTime(UIResponder *responder,
                                        NSString **providerName) {
    SEL selector = NSSelectorFromString(@"maximumSeekableTime");
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        Method method = class_getInstanceMethod(responder.class, selector);
        if (method != NULL) {
            char returnType[16] = {};
            method_getReturnType(method, returnType, sizeof(returnType));
            double value = 0.0;
            if (strcmp(returnType, @encode(double)) == 0) {
                value = ((double (*)(id, SEL))objc_msgSend)(responder,
                                                             selector);
            } else if (strcmp(returnType, @encode(float)) == 0) {
                value = ((float (*)(id, SEL))objc_msgSend)(responder,
                                                            selector);
            }
            if (isfinite(value) && value > 0.0) {
                if (providerName != NULL) {
                    *providerName = NSStringFromClass(responder.class);
                }
                return value;
            }
        }
        responder = responder.nextResponder;
    }
    return 0.0;
}

static UIView *YTKACEScrubberDot(UIView *view) {
    SEL selector = NSSelectorFromString(@"scrubberDot");
    if ([view respondsToSelector:selector]) {
        id dot = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if ([dot isKindOfClass:UIView.class]) return dot;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    while (queue.count != 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
            NSStringFromClass(candidate.class).lowercaseString,
            candidate.accessibilityIdentifier.lowercaseString ?: @"",
            candidate.accessibilityLabel.lowercaseString ?: @""];
        if ([token containsString:@"scrubber"] &&
            CGRectGetWidth(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) <= 64.0) {
            return candidate;
        }
        [queue addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL YTKACETapHitsScrubber(UIView *view, CGPoint point,
                                  CGFloat *trackY) {
    UIView *dot = YTKACEScrubberDot(view);
    CGFloat centerY = MAX(CGRectGetMinY(view.bounds),
                          CGRectGetMaxY(view.bounds) - 2.0);
    if (dot != nil && dot.superview != nil) {
        centerY = [dot.superview convertPoint:dot.center toView:view].y;
    }
    if (trackY != NULL) *trackY = centerY;
    return fabs(point.y - centerY) <= 14.0;
}

static BOOL YTKACETapHitsOverlayControl(UIView *view, CGPoint point,
                                        NSString **controlName) {
    UIView *candidate = [view hitTest:point withEvent:nil];
    while (candidate != nil && candidate != view) {
        if ([candidate isKindOfClass:UIControl.class]) {
            NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                NSStringFromClass(candidate.class).lowercaseString,
                candidate.accessibilityIdentifier.lowercaseString ?: @"",
                candidate.accessibilityLabel.lowercaseString ?: @""];
            BOOL scrubberControl = [token containsString:@"scrub"] ||
                                   [token containsString:@"progress"] ||
                                   [token containsString:@"playerbar"];
            if (!scrubberControl) {
                if (controlName != NULL) *controlName = token;
                return YES;
            }
        }
        candidate = candidate.superview;
    }
    return NO;
}

@interface YTKACETapSeekTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *view;
@end

@implementation YTKACETapSeekTarget
- (void)tap:(UITapGestureRecognizer *)recognizer {
    UIView *view = self.view;
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek") || view == nil ||
        CGRectGetWidth(view.bounds) <= 1.0) return;
    CGPoint point = [recognizer locationInView:view];
    if (YTKACETapHitsOverlayControl(view, point, NULL)) {
        return;
    }
    if (!YTKACETapHitsScrubber(view, point, NULL)) {
        return;
    }
    double x = point.x;
    SEL rangeSelector = NSSelectorFromString(@"scrubRangeForScrubX:");
    SEL nativeSeek = NSSelectorFromString(@"fineScrubberDidSeekToTime:");
    if (![view respondsToSelector:rangeSelector]) {
        return;
    }
    double ratio = ((double (*)(id, SEL, double))objc_msgSend)(
        view, rangeSelector, x);
    if (!isfinite(ratio)) return;
    ratio = MIN(1.0, MAX(0.0, ratio));
    double duration = YTKACEMaximumSeekableTime(view, NULL);
    if (!isfinite(duration) || duration <= 0.0) {
        return;
    }
    double time = ratio * duration;
    BOOL committed = YTKACECommitTapSeek(view, time);
    if (!committed && [view respondsToSelector:nativeSeek]) {
        ((void (*)(id, SEL, double))objc_msgSend)(view, nativeSeek, time);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek");
}
@end

void YTKACEConfigureTapToSeek(UIView *receiver) {
    if (receiver == nil) return;
    YTKACETapSeekTarget *target = objc_getAssociatedObject(
        receiver, YTKACETapSeekHelperKey);
    if (target == nil) {
        target = [YTKACETapSeekTarget new];
        target.view = receiver;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:target action:@selector(tap:)];
        tap.cancelsTouchesInView = NO;
        tap.delegate = target;
        [receiver addGestureRecognizer:tap];
        objc_setAssociatedObject(receiver, YTKACETapSeekHelperKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSValue *YTKACEDoubleTapValueForIMP(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP YTKACEDoubleTapIMPFromValue(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static double YTKACEDoubleTapValue(void) {
    double value = [NSUserDefaults.standardUserDefaults
        doubleForKey:@"YTKACE.Preference.Playback.DoubleTapSeconds"];
    return MIN(60.0, MAX(5.0, value > 0.0 ? value : 10.0));
}

static NSString *YTKACEDoubleTapKey(Class cls,
                                    BOOL classMethod,
                                    SEL selector) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            NSStringFromClass(cls),
            classMethod ? @"+" : @"-",
            NSStringFromSelector(selector)];
}

static IMP YTKACEDoubleTapOriginal(id receiver, SEL selector, NSUInteger skip) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? (Class)receiver : [receiver class];
    while (cls != Nil) {
        NSValue *value =
            YTKACEDoubleTapOriginals[YTKACEDoubleTapKey(cls, classMethod, selector)];
        if (value != nil) {
            if (skip == 0) return YTKACEDoubleTapIMPFromValue(value);
            skip--;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static double YTKACEDoubleTapDoubleNoArg(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return YTKACEDoubleTapValue();
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float YTKACEDoubleTapFloatNoArg(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (float)YTKACEDoubleTapValue();
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger YTKACEDoubleTapIntegerNoArg(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(YTKACEDoubleTapValue());
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static double YTKACEDoubleTapDouble(id receiver,
                                    SEL selector,
                                    id __unsafe_unretained config) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return YTKACEDoubleTapValue();
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL, id))original)(receiver, selector, config);
}

static float YTKACEDoubleTapFloat(id receiver,
                                  SEL selector,
                                  id __unsafe_unretained config) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (float)YTKACEDoubleTapValue();
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL, id))original)(receiver, selector, config);
}

static NSInteger YTKACEDoubleTapInteger(id receiver,
                                        SEL selector,
                                        id __unsafe_unretained config) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(YTKACEDoubleTapValue());
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL, id))original)(receiver, selector, config);
}

static BOOL YTKACETapToSeekDisabled(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek")) {
        return NO;
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTKACETapToSeekEnabled(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek")) {
        return YES;
    }
    YTKACEOriginalScope originalScope(receiver, selector);
    IMP original = YTKACEDoubleTapOriginal(receiver, selector, originalScope.depth());
    return original != NULL &&
        ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTKACEInstallTapToSeekHook(NSString *className,
                                       NSString *selectorName,
                                       IMP replacement,
                                       BOOL classMethod) {
    SEL selector = NSSelectorFromString(selectorName);
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(target, selector);
    if (method == NULL) return NO;
    IMP original = NULL;
    BOOL installed = classMethod
        ? YTKACEInstallClassHook(className, selectorName,
                                 replacement, &original)
        : YTKACEInstallInstanceHook(className, selectorName,
                                    replacement, &original);
    if (installed && original != NULL) {
        NSString *key = YTKACEDoubleTapKey(cls, classMethod, selector);
        if (YTKACEDoubleTapOriginals[key] == nil) {
            YTKACEDoubleTapOriginals[key] =
                YTKACEDoubleTapValueForIMP(original);
        }
    }
    return installed;
}

static void YTKACEInstallDoubleTapHook(NSString *className,
                                      NSString *selectorName,
                                      BOOL classMethod) {
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(
        target,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }

    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    BOOL takesArgument = [selectorName containsString:@":"];
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(double)) == 0) {
        replacement = takesArgument
            ? (IMP)YTKACEDoubleTapDouble
            : (IMP)YTKACEDoubleTapDoubleNoArg;
    } else if (strcmp(returnType, @encode(float)) == 0) {
        replacement = takesArgument
            ? (IMP)YTKACEDoubleTapFloat
            : (IMP)YTKACEDoubleTapFloatNoArg;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = takesArgument
            ? (IMP)YTKACEDoubleTapInteger
            : (IMP)YTKACEDoubleTapIntegerNoArg;
    }
    if (replacement == NULL) {
        return;
    }

    IMP original = NULL;
    BOOL installed = classMethod
        ? YTKACEInstallClassHook(className, selectorName, replacement, &original)
        : YTKACEInstallInstanceHook(className, selectorName, replacement, &original);
    if (installed && original != NULL) {
        NSString *key =
            YTKACEDoubleTapKey(cls, classMethod, NSSelectorFromString(selectorName));
        if (YTKACEDoubleTapOriginals[key] == nil) {
            YTKACEDoubleTapOriginals[key] =
                YTKACEDoubleTapValueForIMP(original);
        }
    }
}

void YTKACEInstallDoubleTapHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEDoubleTapOriginals = [NSMutableDictionary dictionary];
    });

    YTKACEInstallDoubleTapHook(@"YTSettings", @"doubleTapSeekDuration", NO);
    YTKACEInstallDoubleTapHook(@"YTUserDefaults", @"doubleTapSeekDuration", NO);
    for (NSString *selector in @[
        @"doubleTapSeekDurationForVideoPlayerOverlayConfig:",
        @"doubleTapSeekIntervalForVideoPlayerOverlayConfig:"
    ]) {
        YTKACEInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            NO
        );
        YTKACEInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            YES
        );
    }
    for (NSString *className in @[
        @"YTHotConfig",
        @"YTColdConfig",
        @"YTGlobalConfig",
        @"YTSettings"
    ]) {
        for (NSNumber *classMethodValue in @[@NO, @YES]) {
            BOOL classMethod = classMethodValue.boolValue;
            YTKACEInstallTapToSeekHook(
                className, @"androidDisableTimeBarTapToSeek",
                (IMP)YTKACETapToSeekDisabled, classMethod);
            YTKACEInstallTapToSeekHook(
                className, @"iosEnableVideoPlayerScrubber",
                (IMP)YTKACETapToSeekEnabled, classMethod);
        }
    }
}
