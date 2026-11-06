#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 长按命中的一张图。有远程地址时优先下载原文件，否则保存 image。
@interface PSImageSource : NSObject

@property(nonatomic, copy, nullable) NSURL *remoteURL;
@property(nonatomic, strong, nullable) UIImage *image;

@end

NS_INLINE BOOL PSIsHTTPURL(NSURL *_Nullable url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

@interface PSImageProbe : NSObject

/// 这个点是否落在短边至少 80pt 的 UIImageView 上。网页里的图不算。
+ (BOOL)containsLargeImageViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

+ (void)resolveAtPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion;

@end

NS_ASSUME_NONNULL_END
