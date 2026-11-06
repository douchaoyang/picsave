#import <UIKit/UIKit.h>

@class PSImageSource;

NS_ASSUME_NONNULL_BEGIN

@interface PSDownloadCard : UIView

+ (BOOL)isVisible;
+ (void)showInWindow:(UIWindow *)window source:(PSImageSource *)source;

@end

NS_ASSUME_NONNULL_END
