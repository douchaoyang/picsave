#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PSMediaKind) {
    PSMediaKindImage = 0,
    PSMediaKindVideo,
};

/// 长按命中的图片或视频。视频只有远程地址。图片有地址时优先下载原文件，否则保存 image。
@interface PSImageSource : NSObject

@property(nonatomic, assign) PSMediaKind kind;
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

/// 远程地址的路径扩展名是 mp4 或 mov 时返回小写扩展名，否则返回 nil。
NS_INLINE NSString *_Nullable PSVideoFileExtension(NSURL *_Nullable url) {
    if (!PSIsHTTPURL(url)) {
        return nil;
    }
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) {
        return extension;
    }
    return nil;
}

@interface PSImageProbe : NSObject

/// 这个点是否落在短边至少 80pt 的 UIImageView 上。网页里的图不算。
+ (BOOL)containsLargeImageViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

+ (void)resolveAtPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion;

@end

NS_ASSUME_NONNULL_END
