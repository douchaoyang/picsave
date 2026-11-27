#import "PSVideoProbe.h"

#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

static const CGFloat kPSMinimumVideoSide = 80.0;

static BOOL PSIsOwnOverlay(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"PSDownloadCard"] || [name isEqualToString:@"PSProgressHUD"];
}

static BOOL PSHitTouchesOwnOverlay(UIView *hit) {
    for (UIView *view = hit; view; view = view.superview) {
        if (PSIsOwnOverlay(view)) {
            return YES;
        }
    }
    return NO;
}

static WKWebView *PSWebViewContainingHit(UIView *hit) {
    for (UIView *view = hit; view; view = view.superview) {
        if ([view isKindOfClass:[WKWebView class]]) {
            return (WKWebView *)view;
        }
        if ([view isKindOfClass:[UIWindow class]]) {
            break;
        }
    }
    return nil;
}

static BOOL PSLayerBacksSubview(CALayer *layer, UIView *view) {
    for (UIView *subview in view.subviews) {
        if (subview.layer == layer) {
            return YES;
        }
    }
    return NO;
}

static BOOL PSPlayerLayerContainsPoint(CALayer *layer, UIView *host, CGPoint point, UIWindow *window) {
    if (layer.hidden || layer.opacity < 0.01) {
        return NO;
    }
    CGRect inHost = [host.layer convertRect:layer.bounds fromLayer:layer];
    CGRect inWindow = [host convertRect:inHost toView:window];
    if (!CGRectContainsPoint(inWindow, point)) {
        return NO;
    }
    return MIN(CGRectGetWidth(inWindow), CGRectGetHeight(inWindow)) >= kPSMinimumVideoSide;
}

static NSURL *PSURLFromPlayerLayer(CALayer *layer) {
    @try {
        id player = [layer valueForKey:@"player"];
        if (!player) {
            return nil;
        }
        id item = [player valueForKey:@"currentItem"];
        if (!item) {
            return nil;
        }
        id asset = [item valueForKey:@"asset"];
        if (!asset) {
            return nil;
        }
        id value = [asset valueForKey:@"URL"];
        if ([value isKindOfClass:[NSURL class]]) {
            return value;
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

/// 只看这个视图自己贴上的播放层，不进入旁边子视图的图层。
static NSURL *PSVideoURLInLayer(CALayer *layer, UIView *host, CGPoint point, UIWindow *window, NSInteger depth) {
    if (!layer || depth > 8 || layer.hidden || layer.opacity < 0.01) {
        return nil;
    }
    Class playerClass = NSClassFromString(@"AVPlayerLayer");
    if (playerClass && [layer isKindOfClass:playerClass]) {
        if (!PSPlayerLayerContainsPoint(layer, host, point, window)) {
            return nil;
        }
        NSURL *url = PSURLFromPlayerLayer(layer);
        return PSVideoFileExtension(url) ? url : nil;
    }
    if (depth > 0 && PSLayerBacksSubview(layer, host)) {
        return nil;
    }
    for (CALayer *sublayer in layer.sublayers) {
        NSURL *url = PSVideoURLInLayer(sublayer, host, point, window, depth + 1);
        if (url) {
            return url;
        }
    }
    return nil;
}

static NSURL *PSNativeVideoURL(UIView *hit, CGPoint point, UIWindow *window) {
    if (PSWebViewContainingHit(hit)) {
        return nil;
    }
    for (UIView *view = hit; view; view = view.superview) {
        if ([view isKindOfClass:[UIWindow class]]) {
            break;
        }
        NSURL *url = PSVideoURLInLayer(view.layer, view, point, window, 0);
        if (url) {
            return url;
        }
    }
    return nil;
}

static PSImageSource *PSVideoSource(NSURL *url) {
    if (!PSVideoFileExtension(url)) {
        return nil;
    }
    PSImageSource *source = [[PSImageSource alloc] init];
    source.kind = PSMediaKindVideo;
    source.remoteURL = url;
    return source;
}

@implementation PSVideoProbe

+ (BOOL)containsVideoAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (!window) {
        return NO;
    }
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit || PSHitTouchesOwnOverlay(hit)) {
        return NO;
    }
    return PSNativeVideoURL(hit, point, window) != nil;
}

+ (NSString *)webVideoScriptAtPoint:(CGPoint)point {
    // 只传入坐标和最小边长，脚本里没有其他格式化占位符。
    NSString *script =
        @"(function(){"
        @"var x=%f,y=%f,minSide=%f;"
        @"function absURL(u){try{return new URL(u,document.baseURI).href;}catch(e){return '';}}"
        @"function isHTTP(u){return /^https?:/i.test(u||'');}"
        @"function isBig(n){"
        @"if(!n||!n.getBoundingClientRect)return false;"
        @"var r=n.getBoundingClientRect();"
        @"return Math.min(r.width,r.height)>=minSide&&x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom;}"
        @"function isVideoFile(u){"
        @"try{var path=new URL(u,document.baseURI).pathname.toLowerCase();return path.endsWith('.mp4')||path.endsWith('.mov');}"
        @"catch(e){return false;}}"
        @"function fromVideo(n){"
        @"if(!n||String(n.tagName)!=='VIDEO'||!isBig(n))return '';"
        @"var current=absURL(n.currentSrc||n.src||'');"
        @"if(current){return (isHTTP(current)&&isVideoFile(current))?current:'';}"
        @"var sources=n.querySelectorAll?n.querySelectorAll('source'):[];"
        @"for(var i=0;i<sources.length;i++){var abs=absURL(sources[i].src||'');if(isHTTP(abs)&&isVideoFile(abs))return abs;}"
        @"return '';}"
        @"var node=document.elementFromPoint(x,y);"
        @"if(!node)return '';"
        @"var found=fromVideo(node);if(found)return found;"
        @"if(node.parentElement)return fromVideo(node.parentElement);"
        @"return '';})()";
    return [NSString stringWithFormat:script, point.x, point.y, kPSMinimumVideoSide];
}

+ (void)resolveWebView:(WKWebView *)webView
               atPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion {
    CGPoint local = [webView convertPoint:point fromView:window];
    if (!CGRectContainsPoint(webView.bounds, local)) {
        completion(nil);
        return;
    }
    CGFloat zoom = webView.scrollView.zoomScale;
    if (zoom > 0.01 && fabs(zoom - 1.0) > 0.01) {
        local.x /= zoom;
        local.y /= zoom;
    }

    NSString *script = [self webVideoScriptAtPoint:local];
    [webView evaluateJavaScript:script
              completionHandler:^(id result, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (error || ![result isKindOfClass:[NSString class]]) {
                      completion(nil);
                      return;
                  }
                  completion(PSVideoSource([NSURL URLWithString:(NSString *)result]));
                });
              }];
}

+ (void)resolveAtPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion {
    if (!window) {
        completion(nil);
        return;
    }
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit || PSHitTouchesOwnOverlay(hit)) {
        completion(nil);
        return;
    }

    WKWebView *webView = PSWebViewContainingHit(hit);
    if (webView) {
        [self resolveWebView:webView atPoint:point inWindow:window completion:completion];
        return;
    }
    completion(PSVideoSource(PSNativeVideoURL(hit, point, window)));
}

@end
