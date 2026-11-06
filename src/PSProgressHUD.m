#import "PSProgressHUD.h"

static const CGFloat kPSHUDHeight = 36.0;
static const CGFloat kPSHUDCircle = 24.0;
static const CGFloat kPSHUDGap = 12.0;
static const CGFloat kPSHUDPad = 14.0;

@interface PSProgressHUD ()

@property(nonatomic, strong) UIView *containerView;
@property(nonatomic, strong) UIView *progressView;
@property(nonatomic, strong) CAShapeLayer *trackLayer;
@property(nonatomic, strong) CAShapeLayer *progressLayer;
@property(nonatomic, strong) CAShapeLayer *fillLayer;
@property(nonatomic, strong) CAShapeLayer *checkLayer;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, copy, nullable) void (^cancelHandler)(void);
@property(nonatomic, copy, nullable) void (^dismissHandler)(void);
@property(nonatomic, assign) BOOL closing;

@end

@implementation PSProgressHUD

+ (instancetype)showInWindow:(UIWindow *)window
               cancelHandler:(void (^)(void))cancelHandler
              dismissHandler:(void (^)(void))dismissHandler {
    PSProgressHUD *hud = [[PSProgressHUD alloc] initWithFrame:window.bounds];
    hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    hud.cancelHandler = cancelHandler;
    hud.dismissHandler = dismissHandler;
    hud.alpha = 1;
    [window addSubview:hud];
    [hud layoutIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{
      [hud setNeedsLayout];
      [hud layoutIfNeeded];
    });
    return hud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        [self buildContainer];
        [self applyColors];
    }
    return self;
}

- (void)buildContainer {
    _containerView = [[UIView alloc] initWithFrame:CGRectZero];
    _containerView.backgroundColor = [UIColor blackColor];
    _containerView.layer.cornerRadius = kPSHUDHeight / 2.0;
    _containerView.layer.borderWidth = 1.0;
    _containerView.layer.borderColor = [self borderColor].CGColor;
    _containerView.clipsToBounds = YES;
    _containerView.opaque = YES;
    [self addSubview:_containerView];

    _progressView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPSHUDCircle, kPSHUDCircle)];
    [_containerView addSubview:_progressView];

    CGFloat lineWidth = 1.5;
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(kPSHUDCircle / 2.0, kPSHUDCircle / 2.0)
                                                          radius:kPSHUDCircle / 2.0 - lineWidth / 2.0
                                                      startAngle:-M_PI_2
                                                        endAngle:3.0 * M_PI_2
                                                       clockwise:YES];

    _trackLayer = [CAShapeLayer layer];
    _trackLayer.path = circle.CGPath;
    _trackLayer.fillColor = [UIColor clearColor].CGColor;
    _trackLayer.lineWidth = lineWidth;
    _trackLayer.lineCap = kCALineCapRound;
    [_progressView.layer addSublayer:_trackLayer];

    _progressLayer = [CAShapeLayer layer];
    _progressLayer.path = circle.CGPath;
    _progressLayer.fillColor = [UIColor clearColor].CGColor;
    _progressLayer.lineWidth = lineWidth;
    _progressLayer.lineCap = kCALineCapRound;
    _progressLayer.strokeEnd = 0;
    [_progressView.layer addSublayer:_progressLayer];

    _fillLayer = [CAShapeLayer layer];
    _fillLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, kPSHUDCircle, kPSHUDCircle)].CGPath;
    _fillLayer.hidden = YES;
    [_progressView.layer addSublayer:_fillLayer];

    UIBezierPath *check = [UIBezierPath bezierPath];
    [check moveToPoint:CGPointMake(6.6, 12.4)];
    [check addLineToPoint:CGPointMake(10.5, 16.3)];
    [check addLineToPoint:CGPointMake(17.5, 8.4)];
    _checkLayer = [CAShapeLayer layer];
    _checkLayer.path = check.CGPath;
    _checkLayer.fillColor = [UIColor clearColor].CGColor;
    _checkLayer.lineWidth = 2.0;
    _checkLayer.lineCap = kCALineCapRound;
    _checkLayer.lineJoin = kCALineJoinRound;
    _checkLayer.hidden = YES;
    [_progressView.layer addSublayer:_checkLayer];

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.font = [UIFont systemFontOfSize:15];
    _percentLabel.textAlignment = NSTextAlignmentLeft;
    _percentLabel.text = @"0%";
    [_containerView addSubview:_percentLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [_containerView addGestureRecognizer:tap];
}

- (UIColor *)borderColor {
    return [UIColor colorWithRed:204.0 / 255.0 green:204.0 / 255.0 blue:204.0 / 255.0 alpha:1];
}

- (UIColor *)progressGreen {
    return [UIColor colorWithRed:0.18 green:0.78 blue:0.35 alpha:1];
}

- (void)applyColors {
    self.containerView.backgroundColor = [UIColor blackColor];
    self.containerView.layer.borderColor = [self borderColor].CGColor;
    self.trackLayer.strokeColor = [UIColor colorWithWhite:0.55 alpha:1].CGColor;
    self.progressLayer.strokeColor = [self progressGreen].CGColor;
    self.fillLayer.fillColor = [self progressGreen].CGColor;
    self.checkLayer.strokeColor = [UIColor whiteColor].CGColor;
    self.percentLabel.textColor = [UIColor whiteColor];
}

- (void)showSuccessMark {
    self.trackLayer.hidden = YES;
    self.progressLayer.hidden = YES;
    self.fillLayer.hidden = NO;
    self.checkLayer.hidden = NO;
}

- (CGFloat)topInset {
    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) {
        inset = self.safeAreaInsets.top;
        CGFloat windowInset = self.window.safeAreaInsets.top;
        if (windowInset > inset) {
            inset = windowInset;
        }
        CGFloat rootInset = self.window.rootViewController.view.safeAreaInsets.top;
        if (rootInset > inset) {
            inset = rootInset;
        }
    }
    if (inset < 20.0) {
        inset = 54.0;
    }
    return inset;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize textSize = [self.percentLabel sizeThatFits:CGSizeMake(220, kPSHUDHeight)];
    CGFloat textWidth = ceil(textSize.width);
    CGFloat width = kPSHUDPad + kPSHUDCircle + kPSHUDGap + textWidth + kPSHUDPad;
    CGFloat top = [self topInset] + 8.0;
    self.containerView.layer.cornerRadius = kPSHUDHeight / 2.0;
    self.containerView.frame = CGRectMake((CGRectGetWidth(self.bounds) - width) / 2.0, top, width, kPSHUDHeight);
    self.progressView.frame = CGRectMake(kPSHUDPad, (kPSHUDHeight - kPSHUDCircle) / 2.0, kPSHUDCircle, kPSHUDCircle);
    self.percentLabel.frame = CGRectMake(kPSHUDPad + kPSHUDCircle + kPSHUDGap, 0, textWidth, kPSHUDHeight);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyColors];
    [self setNeedsLayout];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self applyColors];
        }
    }
}

- (void)setProgress:(float)progress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setProgress:progress];
        });
        return;
    }
    if (self.closing) {
        return;
    }
    progress = MAX(0.0f, MIN(1.0f, progress));
    self.progressLayer.strokeEnd = progress;
    self.percentLabel.text = [NSString stringWithFormat:@"%d%%", (int)lrint(progress * 100.0)];
    [self setNeedsLayout];
}

- (void)setIndeterminate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setIndeterminate];
        });
        return;
    }
    if (self.closing) {
        return;
    }
    self.progressLayer.strokeEnd = 0;
    self.percentLabel.text = @"下载";
    [self setNeedsLayout];
}

- (void)completeAndDismiss {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self completeAndDismiss];
        });
        return;
    }
    if (self.closing) {
        return;
    }
    [self.layer removeAllAnimations];
    self.alpha = 1;
    [self showSuccessMark];
    self.percentLabel.text = @"完成";
    [self setNeedsLayout];
    [self fadeOutAfter:1.5];
}

- (void)failAndDismiss {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self failAndDismiss];
        });
        return;
    }
    if (self.closing) {
        return;
    }
    self.percentLabel.text = @"下载失败";
    [self setNeedsLayout];
    [self fadeOutAfter:1.0];
}

- (void)fadeOutAfter:(NSTimeInterval)delay {
    if (self.closing) {
        return;
    }
    self.closing = YES;
    self.cancelHandler = nil;
    [UIView animateWithDuration:0.5
        delay:delay
        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          self.alpha = 0;
        }
        completion:^(BOOL finished) {
          [self removeFromSuperview];
          void (^handler)(void) = self.dismissHandler;
          self.dismissHandler = nil;
          if (handler) {
              handler();
          }
        }];
}

- (void)handleTap {
    if (self.closing) {
        return;
    }
    void (^cancel)(void) = self.cancelHandler;
    self.cancelHandler = nil;
    if (cancel) {
        cancel();
    }
    [self fadeOutAfter:0];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) {
        return nil;
    }
    CGPoint local = [self.containerView convertPoint:point fromView:self];
    if ([self.containerView pointInside:local withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }
    return nil;
}

@end
