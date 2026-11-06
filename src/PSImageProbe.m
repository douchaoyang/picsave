#import "PSImageProbe.h"

#import <WebKit/WebKit.h>
#import <objc/message.h>

static const CGFloat kPSMinimumImageSide = 80.0;
static const NSInteger kPSMaxAncestorHops = 8;
static const NSInteger kPSMaxSearchDepth = 16;

@implementation PSImageSource
@end

static BOOL PSViewIsOnScreen(UIView *view) {
    for (UIView *current = view; current; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) {
            return NO;
        }
    }
    return YES;
}

static NSURL *PSURLForSelector(id object, SEL selector) {
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id value = send(object, selector);
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return [NSURL URLWithString:(NSString *)value];
    }
    return nil;
}

/// SDWebImage / YYWebImage 会把地址挂在视图上。沿父视图找几层，按钮自己持有地址时也能取到。
static NSURL *PSRemoteURLNearView(UIView *view) {
    UIView *current = view;
    for (NSInteger hop = 0; current && hop < 6; hop++) {
        NSURL *url = PSURLForSelector(current, @selector(sd_imageURL));
        if (!PSIsHTTPURL(url)) {
            url = PSURLForSelector(current, @selector(yy_imageURL));
        }
        if (PSIsHTTPURL(url)) {
            return url;
        }
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        current = current.superview;
    }
    return nil;
}

static BOOL PSIsOwnOverlay(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"PSDownloadCard"] || [name isEqualToString:@"PSProgressHUD"];
}

@implementation PSImageProbe

+ (void)collectImageViewsInView:(UIView *)view
                          depth:(NSInteger)depth
                          point:(CGPoint)point
                         window:(UIWindow *)window
                           best:(UIImageView *__strong *)best
                       bestArea:(CGFloat *)bestArea {
    if (!view || depth > kPSMaxSearchDepth || view.hidden || view.alpha < 0.01) {
        return;
    }
    if ([view isKindOfClass:[WKWebView class]] || PSIsOwnOverlay(view)) {
        return;
    }

    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        if (imageView.image && PSViewIsOnScreen(imageView)) {
            CGRect rect = [imageView convertRect:imageView.bounds toView:window];
            if (CGRectContainsPoint(rect, point)) {
                CGFloat width = CGRectGetWidth(rect);
                CGFloat height = CGRectGetHeight(rect);
                CGFloat shortSide = MIN(width, height);
                if (shortSide >= kPSMinimumImageSide) {
                    CGFloat area = width * height;
                    if (area > 0 && area < *bestArea) {
                        *bestArea = area;
                        *best = imageView;
                    }
                }
            }
        }
    }

    for (UIView *subview in view.subviews) {
        [self collectImageViewsInView:subview depth:depth + 1 point:point window:window best:best bestArea:bestArea];
    }
}

+ (UIImageView *)imageViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window hit:(UIView *)hit {
    UIView *container = hit;
    for (NSInteger hop = 0; container && hop < kPSMaxAncestorHops; hop++) {
        if ([container isKindOfClass:[UIWindow class]]) {
            break;
        }
        UIImageView *levelBest = nil;
        CGFloat levelArea = CGFLOAT_MAX;
        [self collectImageViewsInView:container depth:0 point:point window:window best:&levelBest bestArea:&levelArea];
        if (levelBest) {
            return levelBest;
        }
        container = container.superview;
    }
    return nil;
}

+ (WKWebView *)webViewContainingHit:(UIView *)hit {
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

+ (NSString *)webImageScriptAtPoint:(CGPoint)point {
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
        @"function firstHTTP(list){for(var i=0;i<list.length;i++){var abs=absURL(list[i]||'');if(isHTTP(abs))return abs;}return '';}"
        @"function fromImg(n){"
        @"if(!n||String(n.tagName)!=='IMG'||!isBig(n))return '';"
        @"return firstHTTP([n.currentSrc,n.src,n.getAttribute('data-src'),n.getAttribute('data-original')]);}"
        @"function fromBackground(bg){"
        @"if(!bg||bg==='none')return '';"
        @"var start=0;"
        @"while(start<bg.length){"
        @"var i=bg.indexOf('url(',start);if(i<0)return '';"
        @"var j=i+4;var quote='';"
        @"var ch0=bg.charAt(j);if(ch0==='\"'||ch0===\"'\"){quote=ch0;j++;}"
        @"var end=j;while(end<bg.length){var ch=bg.charAt(end);if(quote){if(ch===quote)break;}else if(ch===')')break;end++;}"
        @"var abs=absURL(bg.substring(j,end).trim());if(isHTTP(abs))return abs;start=end+1;}"
        @"return '';}"
        @"var nodes=[];"
        @"if(document.elementsFromPoint){nodes=document.elementsFromPoint(x,y)||[];}"
        @"else{var one=document.elementFromPoint(x,y);if(one)nodes=[one];}"
        @"var index,node,found;"
        @"for(index=0;index<nodes.length;index++){"
        @"node=nodes[index];"
        @"while(node&&node!==document.documentElement){found=fromImg(node);if(found)return found;node=node.parentElement;}"
        @"}"
        @"for(index=0;index<nodes.length;index++){"
        @"node=nodes[index];"
        @"while(node&&node!==document.documentElement){"
        @"if(isBig(node)){found=fromBackground(getComputedStyle(node).backgroundImage);if(found)return found;}"
        @"node=node.parentElement;}"
        @"}"
        @"return '';})()";
    return [NSString stringWithFormat:script, point.x, point.y, kPSMinimumImageSide];
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

    NSString *script = [self webImageScriptAtPoint:local];
    [webView evaluateJavaScript:script
              completionHandler:^(id result, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (error || ![result isKindOfClass:[NSString class]]) {
                      completion(nil);
                      return;
                  }
                  NSURL *url = [NSURL URLWithString:(NSString *)result];
                  if (!PSIsHTTPURL(url)) {
                      completion(nil);
                      return;
                  }
                  PSImageSource *source = [[PSImageSource alloc] init];
                  source.remoteURL = url;
                  completion(source);
                });
              }];
}

+ (void)collectFrontWebViewInView:(UIView *)view
                            point:(CGPoint)point
                           window:(UIWindow *)window
                             best:(WKWebView *__strong *)best {
    if (!view || view.hidden || view.alpha < 0.01 || PSIsOwnOverlay(view)) {
        return;
    }
    if ([view isKindOfClass:[WKWebView class]]) {
        CGRect rect = [view convertRect:view.bounds toView:window];
        if (CGRectContainsPoint(rect, point)) {
            *best = (WKWebView *)view;
        }
    }
    for (UIView *subview in view.subviews) {
        [self collectFrontWebViewInView:subview point:point window:window best:best];
    }
}

+ (WKWebView *)frontmostWebViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    WKWebView *best = nil;
    [self collectFrontWebViewInView:window point:point window:window best:&best];
    return best;
}

+ (PSImageSource *)sourceForImageView:(UIImageView *)imageView {
    if (!imageView.image) {
        return nil;
    }
    PSImageSource *source = [[PSImageSource alloc] init];
    source.remoteURL = PSRemoteURLNearView(imageView);
    source.image = imageView.image;
    return source;
}

+ (BOOL)containsLargeImageViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (!window) {
        return NO;
    }
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit) {
        return NO;
    }
    for (UIView *view = hit; view; view = view.superview) {
        if (PSIsOwnOverlay(view)) {
            return NO;
        }
    }
    return [self imageViewAtPoint:point inWindow:window hit:hit] != nil;
}

+ (void)resolveAtPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion {
    if (!window) {
        completion(nil);
        return;
    }

    void (^finish)(PSImageSource *) = ^(PSImageSource *source) {
      if ([NSThread isMainThread]) {
          completion(source);
      } else {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(source);
          });
      }
    };

    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit) {
        finish(nil);
        return;
    }
    for (UIView *view = hit; view; view = view.superview) {
        if (PSIsOwnOverlay(view)) {
            finish(nil);
            return;
        }
    }

    UIImageView *imageView = hit ? [self imageViewAtPoint:point inWindow:window hit:hit] : nil;
    WKWebView *webView = hit ? [self webViewContainingHit:hit] : nil;
    if (!webView) {
        webView = [self frontmostWebViewAtPoint:point inWindow:window];
    }
    if (webView) {
        [self resolveWebView:webView
                      atPoint:point
                     inWindow:window
                   completion:^(PSImageSource *source) {
                     if (PSIsHTTPURL(source.remoteURL)) {
                         source.image = nil;
                         finish(source);
                         return;
                     }
                     finish([self sourceForImageView:imageView]);
                   }];
        return;
    }

    finish([self sourceForImageView:imageView]);
}

@end
