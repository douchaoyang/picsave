#import <UIKit/UIKit.h>

@class PSImageSource;

NS_ASSUME_NONNULL_BEGIN

@interface PSDownloader : NSObject

+ (instancetype)sharedDownloader;

@property(nonatomic, readonly, getter=isBusy) BOOL busy;

- (void)startWithSource:(PSImageSource *)source inWindow:(nullable UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
