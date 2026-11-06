//
//  BXSimplePanel.m — 精简面板 v2（好用的版本）
//
//  v1 的问题：面板太小、键盘挡住按钮、没有关闭按钮、不能拖动、状态字太小。
//  v2：340×460 卡片、标题栏可拖动、右上角关闭、地址框带粘贴/清空、
//      44pt 大按钮、状态大字+颜色点、点空白收键盘。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "BXFloatMenuController.h"
#import "BXCaptureBridge.h"
#import "BXFloatStore.h"
#import "BXLog.h"

extern NSString *BXStallSampleText(void);

#define C_BG()     [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1.0]
#define C_CARD()   [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1.0]
#define C_TEXT()   [UIColor whiteColor]
#define C_SUB()    [UIColor colorWithRed:0.60 green:0.60 blue:0.64 alpha:1.0]
#define C_BLUE()   [UIColor colorWithRed:0.16 green:0.52 blue:1.00 alpha:1.0]
#define C_GREEN()  [UIColor colorWithRed:0.16 green:0.76 blue:0.44 alpha:1.0]
#define C_RED()    [UIColor colorWithRed:0.92 green:0.28 blue:0.26 alpha:1.0]
#define C_GRAY()   [UIColor colorWithRed:0.26 green:0.26 blue:0.29 alpha:1.0]

static const CGFloat kPanelW = 340.0;
static const CGFloat kPanelH = 460.0;

@interface BXFloatMenuController ()
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UILabel     *stateLabel;
@property (nonatomic, strong) UILabel     *detailLabel;
@property (nonatomic, strong) UIView      *dot;
@property (nonatomic, strong) NSTimer     *tick;
@end

@implementation BXFloatMenuController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = C_BG();
    self.view.layer.cornerRadius = 16;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    self.view.clipsToBounds = YES;
    [self buildUI];
    [self refresh];
    __weak typeof(self) ws = self;
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(ws) s = ws;
        if (s && s.view.window) [s refresh];
    }];
}

- (void)dealloc { [_tick invalidate]; _tick = nil; }

#pragma mark - 布局

- (void)buildUI {
    CGFloat pad = 16;

    // 标题栏（可拖动）
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, 48)];
    bar.backgroundColor = C_CARD();
    [self.view addSubview:bar];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [bar addGestureRecognizer:pan];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 14, 220, 20)];
    title.text = @"百相 VCam";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = C_TEXT();
    [bar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(kPanelW - 44, 8, 36, 32);
    close.backgroundColor = C_GRAY();
    close.layer.cornerRadius = 8;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:C_SUB() forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    // 地址框
    _urlField = [[UITextField alloc] initWithFrame:CGRectMake(pad, 60, kPanelW - pad * 2, 44)];
    _urlField.backgroundColor = C_CARD();
    _urlField.layer.cornerRadius = 10;
    _urlField.textColor = C_TEXT();
    _urlField.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _urlField.placeholder = @"rtsp://192.168.1.4:8554/live/123";
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.keyboardType = UIKeyboardTypeURL;
    _urlField.returnKeyType = UIReturnKeyDone;
    _urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _urlField.text = [[BXFloatStore shared] objectForKey:@"rtsp_url"] ?: @"";
    _urlField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _urlField.leftViewMode = UITextFieldViewModeAlways;
    [self.view addSubview:_urlField];

    CGFloat halfW = (kPanelW - pad * 2 - 10) / 2.0;
    [self addButton:@"粘贴" x:pad              y:112 w:halfW h:34 color:C_GRAY() action:@selector(onPaste)];
    [self addButton:@"清空" x:pad + halfW + 10 y:112 w:halfW h:34 color:C_GRAY() action:@selector(onClear)];

    CGFloat bw = (kPanelW - pad * 2 - 20) / 3.0;
    [self addButton:@"连接" x:pad                 y:158 w:bw h:46 color:C_BLUE() action:@selector(onConnect)];
    [self addButton:@"重连" x:pad + bw + 10       y:158 w:bw h:46 color:C_GRAY() action:@selector(onReconnect)];
    [self addButton:@"断开" x:pad + (bw + 10) * 2 y:158 w:bw h:46 color:C_RED()  action:@selector(onDisconnect)];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 220, kPanelW - pad * 2, 130)];
    card.backgroundColor = C_CARD();
    card.layer.cornerRadius = 12;
    [self.view addSubview:card];

    _dot = [[UIView alloc] initWithFrame:CGRectMake(14, 16, 10, 10)];
    _dot.layer.cornerRadius = 5;
    _dot.backgroundColor = C_RED();
    [card addSubview:_dot];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 11, card.bounds.size.width - 44, 20)];
    _stateLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _stateLabel.textColor = C_TEXT();
    _stateLabel.text = @"未连接";
    [card addSubview:_stateLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 38, card.bounds.size.width - 28, 84)];
    _detailLabel.numberOfLines = 5;
    _detailLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    _detailLabel.textColor = C_SUB();
    [card addSubview:_detailLabel];

    CGFloat btmW = (kPanelW - pad * 2 - 10) / 2.0;
    [self addButton:@"复制日志" x:pad                   y:364 w:btmW h:38 color:C_GRAY() action:@selector(onCopyLog)];
    [self addButton:@"关闭面板" x:pad + btmW + 10        y:364 w:btmW h:38 color:C_GRAY() action:@selector(onClose)];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKbd)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)addButton:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h
            color:(UIColor *)color action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT() forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

#pragma mark - 交互

- (void)onDrag:(UIPanGestureRecognizer *)g {
    UIView *v = self.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)dismissKbd { [self.view endEditing:YES]; }

- (void)onClose {
    [self.view endEditing:YES];
    self.view.hidden = YES;
    if (self.onRequestClose) self.onRequestClose();
}

- (void)onPaste {
    NSString *s = [UIPasteboard generalPasteboard].string;
    if (s.length) _urlField.text = s;
}

- (void)onClear { _urlField.text = @""; }

- (NSString *)currentURL {
    NSString *u = [_urlField.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (u.length && [u rangeOfString:@"://"].location == NSNotFound) {
        u = [@"rtsp://" stringByAppendingString:u];
    }
    return u.length ? u : nil;
}

- (void)saveURL:(NSString *)u {
    if (!u.length) return;
    [[BXFloatStore shared] setObject:u forKey:@"rtsp_url"];
    [[BXFloatStore shared] setObject:@(1) forKey:@"rtsp.enabled"];
    [BXCaptureBridge shared].enabled = YES;
    [BXCaptureBridge shared].audioReplace = YES;
}

- (void)onConnect {
    [self.view endEditing:YES];
    NSString *u = [self currentURL];
    if (!u.length) { [self toast:@"先填地址"]; return; }
    [self saveURL:u];
    [self toast:@"连接中…"];
    BXCaptureBridge *br = [BXCaptureBridge shared];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        BOOL ok = [br useRTSPURLString:u error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self toast:ok ? @"已连接" : [NSString stringWithFormat:@"失败：%@",
                                         e.localizedDescription ?: @"未知"]];
        });
    });
}

- (void)onReconnect {
    [self.view endEditing:YES];
    NSString *u = [self currentURL];
    if (!u.length) { [self toast:@"先填地址"]; return; }
    [self saveURL:u];
    [self toast:@"重连中…"];
    BXCaptureBridge *br = [BXCaptureBridge shared];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [br stopNetworkSources];
        NSError *e = nil;
        BOOL ok = [br useRTSPURLString:u error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self toast:ok ? @"已重连" : @"重连失败"];
        });
    });
}

- (void)onDisconnect {
    [[BXCaptureBridge shared] stopNetworkSources];
    [self toast:@"已断开"];
}

- (void)onCopyLog {
    NSString *all = [NSString stringWithFormat:@"=== 日志 ===\n%@\n\n=== 主线程采样 ===\n%@",
                     BXLogText(), BXStallSampleText()];
    [UIPasteboard generalPasteboard].string = all;
    [self toast:@"日志已复制，粘贴给我即可"];
}

- (void)toast:(NSString *)msg { _stateLabel.text = msg; }

#pragma mark - 状态

- (void)refresh {
    BXCaptureBridge *b = [BXCaptureBridge shared];
    BOOL running = b.isStreaming;
    _stateLabel.text = running ? @"已连接" : @"未连接";
    _dot.backgroundColor = running ? C_GREEN() : C_RED();

    _detailLabel.text = [NSString stringWithFormat:
        @"读取 %lu   入槽 %lu   替换 %lu fps\n已替换 %lu   直通 %lu\n音频欠载 %lu 次 / 缺 %lu 帧\n流地址 %@",
        (unsigned long)[b readFPS], (unsigned long)[b slotFillFPS], (unsigned long)b.replaceFPS,
        (unsigned long)b.replacedFrames, (unsigned long)b.passthroughFrames,
        (unsigned long)[b audioUnderruns], (unsigned long)[b audioUnderrunFrames],
        running ? @"在线" : @"—"];
}

- (void)reload {
    _urlField.text = [[BXFloatStore shared] objectForKey:@"rtsp_url"] ?: @"";
    [self refresh];
}

@end
