#import "PSImageProbe.h"

NS_ASSUME_NONNULL_BEGIN

@interface PSVideoProbe : NSObject

/// 触点是否落在正在播放 mp4 或 mov 的原生播放器上。网页里的视频不算。
+ (BOOL)containsVideoAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

+ (void)resolveAtPoint:(CGPoint)point
              inWindow:(UIWindow *)window
            completion:(void (^)(PSImageSource *_Nullable source))completion;

@end

NS_ASSUME_NONNULL_END
