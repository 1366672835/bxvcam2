//
//  BXFloatWindow.m
//

#import "BXFloatWindow.h"
#import "BXFloatMenuController.h"
#import "BXFloatStore.h"

static NSString *const kBubbleXKey     = @"bx.ui.bubble.x";
static NSString *const kBubbleYKey     = @"bx.ui.bubble.y";
static NSString *const kBubbleSideKey  = @"bx.ui.bubble.side";   // 0 左 1 右
static NSString *const kBubbleSize     = @"bx.ui.bubble.size";

@interface BXFloatWindow () <UIGestureRecognizerDelegate>
@end

@implementation BXFloatWindow {
    CGPoint _dragStart;
    CGRect _bubbleStartFrame;
    BOOL _dragging;
}

+ (instancetype)shared {
    static BXFloatWindow *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[BXFloatWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.windowLevel = UIWindowLevelAlert + 100;   // 压在游戏之上
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];
        self.hidden = YES;
        [self _buildBubble];
    }
    return self;
}

#pragma mark - 悬浮球

- (void)_buildBubble {
    CGFloat size = [[BXFloatStore shared] objectForKey:kBubbleSize]
                     ? [(NSNumber *)[[BXFloatStore shared] objectForKey:kBubbleSize] doubleValue] : 46.0;
    if (size < 30) size = 46;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, size, size);
    b.layer.cornerRadius = size / 2.0;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    b.backgroundColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.95 alpha:0.55];
    b.clipsToBounds = YES;
    b.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    [b setTitle:@"BX" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:@selector(_bubbleTapped) forControlEvents:UIControlEventTouchUpInside];

    // 拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handlePan:)];
    pan.delegate = self;
    [b addGestureRecognizer:pan];

    [self.rootViewController.view addSubview:b];
    _bubble = b;
    [self _restoreBubblePosition];
}

- (void)_restoreBubblePosition {
    BXFloatStore *s = [BXFloatStore shared];
    NSNumber *x = [s objectForKey:kBubbleXKey];
    NSNumber *y = [s objectForKey:kBubbleYKey];
    NSNumber *side = [s objectForKey:kBubbleSideKey];

    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat size = _bubble.bounds.size.width;
    CGFloat margin = 10;

    CGRect f = _bubble.frame;
    if (x && y) {
        f.origin = CGPointMake(x.doubleValue, y.doubleValue);
    } else {
        f.origin = CGPointMake(scr.width - size - margin, scr.height * 0.35);
    }
    // 贴边
    if (side.integerValue == 0) f.origin.x = margin;
    else if (side.integerValue == 1) f.origin.x = scr.width - size - margin;

    f.origin.y = MAX(margin, MIN(f.origin.y, scr.height - size - margin));
    _bubble.frame = f;
}

- (void)_saveBubblePosition {
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat size = _bubble.bounds.size.width;
    CGFloat midX = CGRectGetMidX(_bubble.frame);
    NSInteger side = (midX < scr.width / 2.0) ? 0 : 1;
    BXFloatStore *s = [BXFloatStore shared];
    [s setObject:@(_bubble.frame.origin.x) forKey:kBubbleXKey];
    [s setObject:@(_bubble.frame.origin.y) forKey:kBubbleYKey];
    [s setObject:@(side) forKey:kBubbleSideKey];
    [s synchronize];
}

#pragma mark - 拖拽

- (void)_handlePan:(UIPanGestureRecognizer *)pan {
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat size = _bubble.bounds.size.width;
    CGFloat margin = 10;

    CGPoint t = [pan translationInView:self.rootViewController.view];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _dragging = YES;
            _bubbleStartFrame = _bubble.frame;
            break;
        case UIGestureRecognizerStateChanged: {
            CGRect f = _bubbleStartFrame;
            f.origin.x += t.x;
            f.origin.y += t.y;
            f.origin.x = MAX(margin, MIN(f.origin.x, scr.width - size - margin));
            f.origin.y = MAX(margin, MIN(f.origin.y, scr.height - size - margin));
            _bubble.frame = f;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            _dragging = NO;
            CGRect f = _bubble.frame;
            CGFloat midX = CGRectGetMidX(f);
            // 吸附
            [UIView animateWithDuration:0.22
                                  delay:0
                 usingSpringWithDamping:0.85
                  initialSpringVelocity:0.4
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                CGRect n = f;
                n.origin.x = (midX < scr.width / 2.0) ? margin : (scr.width - size - margin);
                self->_bubble.frame = n;
            } completion:^(BOOL done) {
                [self _saveBubblePosition];
            }];
            break;
        }
        default: break;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

#pragma mark - 展开/收起

- (void)_bubbleTapped {
    if (_dragging) return;
    if (!_menu) {
        _menu = [BXFloatMenuController new];
        _menu.view.alpha = 0;
        _menu.view.transform = CGAffineTransformMakeScale(0.88, 0.88);
        [self.rootViewController.view addSubview:_menu.view];
    }
    BOOL showing = _menu.view.superview != nil && _menu.view.alpha > 0.05;
    if (showing) {
        [self _collapseMenu];
    } else {
        [self _expandMenu];
    }
}

- (void)_expandMenu {
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat w = MIN(300.0, scr.width - 40);
    CGFloat h = MIN(430.0, scr.height * 0.62);

    BOOL leftSide = CGRectGetMidX(_bubble.frame) < scr.width / 2.0;
    CGFloat x = leftSide ? (CGRectGetMaxX(_bubble.frame) + 12)
                         : (CGRectGetMinX(_bubble.frame) - w - 12);
    x = MAX(12, MIN(x, scr.width - w - 12));
    CGFloat y = MAX(60, MIN(CGRectGetMidY(_bubble.frame) - h / 2.0, scr.height - h - 60));

    // 收起时会把 menu.view 从父视图摘掉，再次展开必须重新挂回去
    if (!_menu.view.superview) {
        [self.rootViewController.view addSubview:_menu.view];
    }
    _menu.view.hidden = NO;

    _menu.view.frame = CGRectMake(x, y, w, h);
    [_menu reload];

    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_menu.view.alpha = 1;
        self->_menu.view.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)_collapseMenu {
    [UIView animateWithDuration:0.18 animations:^{
        self->_menu.view.alpha = 0;
        self->_menu.view.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL done) {
        if (self->_menu.view.alpha < 0.05) {
            // 只隐藏，保留在父视图里 —— 下次展开直接改 alpha 即可
            self->_menu.view.hidden = YES;
        }
    }];
}

#pragma mark - 挂载/卸载

- (void)attach {
    // 不要用 makeKeyAndVisible —— 那会把宿主 App 的 key window 抢走，
    // 有些 App（尤其带播放器的）会因此黑屏或异常。
    self.hidden = NO;
    self.windowLevel = UIWindowLevelAlert + 100;
    [self _restoreBubblePosition];
    [self setNeedsLayout];
}

- (void)detach {
    [_menu.view removeFromSuperview];
    self.hidden = YES;
}

#pragma mark - 触摸穿透

- (BOOL)shouldReceiveTouch {
    if (_menu && _menu.view.superview && _menu.view.alpha > 0.05) return YES;
    return YES;   // 球体本身始终可点
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 有系统弹窗 / 文件选择器时全放行：
    // 它们居中弹出，落在 bubble/menu 区域之外，否则触摸会被穿透给宿主 App，
    // 表现就是「弹窗出来了但点不动」。
    if (self.allowAllTouches) {
        UIView *v = [super hitTest:point withEvent:event];
        if (v) return v;
    }
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;   // 空白处穿透给游戏
    return v;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 弹窗期间整块都算我们的，保证弹窗可点
    if (self.allowAllTouches) return YES;
    // 只有球和展开的面板算"我的地盘"
    if (_bubble && !_bubble.hidden && CGRectContainsPoint(_bubble.frame, point)) return YES;
    if (_menu && _menu.view.superview && !_menu.view.hidden &&
        _menu.view.alpha > 0.05 &&
        CGRectContainsPoint(_menu.view.frame, point)) return YES;
    return NO;
}

@end
