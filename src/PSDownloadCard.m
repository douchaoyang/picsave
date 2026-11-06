#import "PSDownloadCard.h"

#import "PSDownloader.h"
#import "PSImageProbe.h"

static const CGFloat kPSCardRowHeight = 56.0;
static const CGFloat kPSCardDividerHeight = 8.0;
static const CGFloat kPSCardCornerRadius = 12.0;

static __weak PSDownloadCard *ps_visibleCard;

@interface PSDownloadCard ()

@property(nonatomic, strong) PSImageSource *source;
@property(nonatomic, strong) UIView *dimmingView;
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UIButton *downloadButton;
@property(nonatomic, strong) UIView *dividerView;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, assign) BOOL dismissing;

@end

@implementation PSDownloadCard

+ (BOOL)isVisible {
    return ps_visibleCard != nil;
}

+ (void)showInWindow:(UIWindow *)window source:(PSImageSource *)source {
    if (ps_visibleCard || !window || !source) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self showInWindow:window source:source];
        });
        return;
    }

    PSDownloadCard *card = [[PSDownloadCard alloc] initWithSource:source];
    card.frame = window.bounds;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:card];
    ps_visibleCard = card;
    [card layoutIfNeeded];
    [card presentAnimated];
}

- (instancetype)initWithSource:(PSImageSource *)source {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _source = source;
        self.backgroundColor = [UIColor clearColor];
        [self buildSubviews];
    }
    return self;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:18];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildSubviews {
    _dimmingView = [[UIView alloc] init];
    _dimmingView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _dimmingView.alpha = 0;
    [self addSubview:_dimmingView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDimmingTap)];
    [_dimmingView addGestureRecognizer:tap];

    _cardView = [[UIView alloc] init];
    _cardView.backgroundColor = [UIColor systemBackgroundColor];
    _cardView.layer.cornerRadius = kPSCardCornerRadius;
    _cardView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _cardView.clipsToBounds = YES;
    [self addSubview:_cardView];

    _downloadButton = [self actionButtonWithTitle:@"下载" action:@selector(handleDownloadTap)];
    [_cardView addSubview:_downloadButton];

    _dividerView = [[UIView alloc] init];
    _dividerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [_cardView addSubview:_dividerView];

    _cancelButton = [self actionButtonWithTitle:@"取消" action:@selector(handleCancelTap)];
    [_cardView addSubview:_cancelButton];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.dimmingView.frame = self.bounds;

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) {
        bottomInset = self.safeAreaInsets.bottom;
    }
    CGFloat cardHeight = kPSCardRowHeight + kPSCardDividerHeight + kPSCardRowHeight + bottomInset;
    CGRect cardFrame = CGRectMake(0, height - cardHeight, width, cardHeight);

    CGAffineTransform active = self.cardView.transform;
    self.cardView.transform = CGAffineTransformIdentity;
    self.cardView.frame = cardFrame;
    self.cardView.transform = active;

    self.downloadButton.frame = CGRectMake(0, 0, width, kPSCardRowHeight);
    self.dividerView.frame = CGRectMake(0, kPSCardRowHeight, width, kPSCardDividerHeight);
    self.cancelButton.frame = CGRectMake(0, kPSCardRowHeight + kPSCardDividerHeight, width, kPSCardRowHeight);
}

- (CGFloat)slideOffset {
    CGFloat height = CGRectGetHeight(self.cardView.bounds);
    if (height < 1) {
        height = CGRectGetHeight(self.bounds);
    }
    return MAX(height, 1);
}

- (void)presentAnimated {
    self.cardView.transform = CGAffineTransformMakeTranslation(0, [self slideOffset]);
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.16 : 0.28;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                       self.dimmingView.alpha = 1;
                       self.cardView.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)dismissAnimated:(void (^)(void))completion {
    if (self.dismissing) {
        return;
    }
    self.dismissing = YES;
    self.userInteractionEnabled = NO;

    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.12 : 0.22;
    CGFloat offset = [self slideOffset];
    [UIView animateWithDuration:duration
        delay:0
        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          self.dimmingView.alpha = 0;
          self.cardView.transform = CGAffineTransformMakeTranslation(0, offset);
        }
        completion:^(BOOL finished) {
          [self removeFromSuperview];
          if (completion) {
              completion();
          }
        }];
}

- (void)handleDimmingTap {
    [self dismissAnimated:nil];
}

- (void)handleCancelTap {
    [self dismissAnimated:nil];
}

- (void)handleDownloadTap {
    PSImageSource *source = self.source;
    UIWindow *window = self.window;
    [self dismissAnimated:^{
      [[PSDownloader sharedDownloader] startWithSource:source inWindow:window];
    }];
}

@end
