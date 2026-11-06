#import "PSDownloadCard.h"
#import "PSDownloader.h"
#import "PSImageProbe.h"

#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *kPSLongPressKey = &kPSLongPressKey;

static NSString *PSCalloutScriptSource(void) {
    return @"(function(){"
           @"var id='picsave-callout';"
           @"if(document.getElementById(id))return;"
           @"var style=document.createElement('style');"
           @"style.id=id;"
           @"style.textContent='img,picture,video{-webkit-touch-callout:none!important;}';"
           @"(document.head||document.documentElement).appendChild(style);"
           @"})();";
}

static void PSAddCalloutUserScript(WKUserContentController *controller) {
    if (![controller isKindOfClass:[WKUserContentController class]]) {
        return;
    }
    NSString *source = PSCalloutScriptSource();
    for (WKUserScript *existing in controller.userScripts) {
        if ([existing.source isEqualToString:source]) {
            return;
        }
    }
    WKUserScript *script = [[WKUserScript alloc] initWithSource:source
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:NO];
    [controller addUserScript:script];
}

static void PSApplyCalloutInView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) {
        return;
    }
    if ([view isKindOfClass:[WKWebView class]]) {
        [(WKWebView *)view evaluateJavaScript:PSCalloutScriptSource() completionHandler:nil];
    }
    for (UIView *subview in view.subviews) {
        PSApplyCalloutInView(subview);
    }
}

@interface WKWebView (PSCallout)
- (instancetype)initWithFrame_ps:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration;
@end

@implementation WKWebView (PSCallout)

- (instancetype)initWithFrame_ps:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (configuration) {
        PSAddCalloutUserScript(configuration.userContentController);
    }
    return [self initWithFrame_ps:frame configuration:configuration];
}

@end

static void PSInstallWebCallout(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      Method original = class_getInstanceMethod([WKWebView class], @selector(initWithFrame:configuration:));
      Method swizzled = class_getInstanceMethod([WKWebView class], @selector(initWithFrame_ps:configuration:));
      if (original && swizzled) {
          method_exchangeImplementations(original, swizzled);
      }
    });
}

@interface PSInstaller : NSObject <UIGestureRecognizerDelegate>
@end

@implementation PSInstaller

+ (instancetype)sharedInstaller {
    static PSInstaller *installer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      installer = [[PSInstaller alloc] init];
    });
    return installer;
}

- (void)attachToWindow:(UIWindow *)window {
    if (![window isKindOfClass:[UIWindow class]]) {
        return;
    }
    if (objc_getAssociatedObject(window, kPSLongPressKey)) {
        return;
    }

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    gesture.minimumPressDuration = 0.5;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    gesture.delegate = self;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, kPSLongPressKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PSApplyCalloutInView(window);
}

- (void)attachToExistingWindows {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    for (UIWindow *window in windows) {
        [self attachToWindow:window];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self attachToExistingWindows];
}

- (void)windowDidBecomeVisible:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self windowDidBecomeVisible:notification];
        });
        return;
    }
    [self attachToWindow:notification.object];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if ([PSDownloader sharedDownloader].isBusy || [PSDownloadCard isVisible]) {
        return;
    }

    UIView *view = gesture.view;
    UIWindow *window = [view isKindOfClass:[UIWindow class]] ? (UIWindow *)view : view.window;
    if (!window) {
        return;
    }

    CGPoint point = [gesture locationInView:window];
    [PSImageProbe resolveAtPoint:point
                        inWindow:window
                      completion:^(PSImageSource *source) {
                        if (!source) {
                            return;
                        }
                        if ([PSDownloader sharedDownloader].isBusy || [PSDownloadCard isVisible]) {
                            return;
                        }
                        [PSDownloadCard showInWindow:window source:source];
                      }];
}

- (BOOL)gesture:(UIGestureRecognizer *)gesture shouldOverrideMenuGesture:(UIGestureRecognizer *)other {
    if (gesture == other || ![other isKindOfClass:[UIGestureRecognizer class]]) {
        return NO;
    }
    BOOL longPress = [other isKindOfClass:[UILongPressGestureRecognizer class]];
    BOOL contextMenu = [NSStringFromClass(other.class) rangeOfString:@"ContextMenu"].location != NSNotFound;
    if (!longPress && !contextMenu) {
        return NO;
    }
    UIView *view = gesture.view;
    UIWindow *window = [view isKindOfClass:[UIWindow class]] ? (UIWindow *)view : view.window;
    if (!window) {
        return NO;
    }
    CGPoint point = [gesture locationInView:window];
    return [PSImageProbe containsLargeImageViewAtPoint:point inWindow:window];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return ![self gesture:gestureRecognizer shouldOverrideMenuGesture:otherGestureRecognizer];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return [self gesture:gestureRecognizer shouldOverrideMenuGesture:otherGestureRecognizer];
}

@end

__attribute__((constructor)) static void PSLoad(void) {
    @autoreleasepool {
        PSInstallWebCallout();
        PSInstaller *installer = [PSInstaller sharedInstaller];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:installer selector:@selector(applicationDidFinishLaunching:) name:UIApplicationDidFinishLaunchingNotification object:nil];
        [center addObserver:installer selector:@selector(windowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          [installer attachToExistingWindows];
        });
    }
}
