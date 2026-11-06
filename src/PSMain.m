#import "PSDownloadCard.h"
#import "PSDownloader.h"
#import "PSImageProbe.h"

#import <objc/runtime.h>

static const void *kPSLongPressKey = &kPSLongPressKey;

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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

__attribute__((constructor)) static void PSLoad(void) {
    @autoreleasepool {
        PSInstaller *installer = [PSInstaller sharedInstaller];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:installer selector:@selector(applicationDidFinishLaunching:) name:UIApplicationDidFinishLaunchingNotification object:nil];
        [center addObserver:installer selector:@selector(windowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          [installer attachToExistingWindows];
        });
    }
}
