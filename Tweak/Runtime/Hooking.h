#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL YTKACEInstallInstanceHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTKACEInstallClassHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTKACEAddInstanceMethod(
    NSString *className,
    NSString *selectorName,
    IMP implementation,
    const char *typeEncoding
);

FOUNDATION_EXPORT NSUInteger YTKACEInstalledHookCount(void);

FOUNDATION_EXPORT NSArray<NSString *> *YTKACEAppClassNames(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
// Some hooks share one replacement across a class and its subclasses and find
// "their" original by walking up from the receiver's class. When a subclass's
// original calls super, the call lands in the same replacement again; without
// help the walk finds the subclass's original a second time and recurses until
// the stack overflows. Declare one of these before looking up the original:
// depth() says how many levels of this receiver+selector are already running
// on this thread, so the lookup can skip that many matching classes.
class YTKACEOriginalScope {
public:
    YTKACEOriginalScope(id _Nullable receiver, SEL _Nullable selector);
    ~YTKACEOriginalScope();
    YTKACEOriginalScope(const YTKACEOriginalScope &) = delete;
    YTKACEOriginalScope &operator=(const YTKACEOriginalScope &) = delete;
    NSUInteger depth() const { return _depth; }

private:
    const void *_Nullable _receiver;
    SEL _Nullable _selector;
    NSUInteger _depth;
};
#endif
