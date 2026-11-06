#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 顶部下载进度胶囊。只接收胶囊上的点击，用来取消下载。
@interface PSProgressHUD : UIView

+ (instancetype)showInWindow:(UIWindow *)window
               cancelHandler:(void (^_Nullable)(void))cancelHandler
              dismissHandler:(void (^_Nullable)(void))dismissHandler;

- (void)setProgress:(float)progress;
- (void)setIndeterminate;
- (void)completeAndDismiss;
- (void)failAndDismiss;

@end

NS_ASSUME_NONNULL_END
