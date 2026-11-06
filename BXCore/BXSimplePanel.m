//
//  BXSimplePanel.m — 精简面板（替换原来的 BXFloatMenuController）
//
//  设计目标：
//    · 只保留 RTSP 虚拟摄像头必需的东西：地址输入、连接/断开/重连、状态显示
//    · 不读本地视频、不带诊断调试开关、不做复杂页面切换
//    · 每秒刷新一次状态（主线程，轻量）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "BXFloatMenuController.h"
#import "BXCaptureBridge.h"
#import "BXFloatStore.h"
#import "BXLog.h"

#define C_BG()     [UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1.0]
#define C_CARD()   [UIColor colorWithRed:0.19 green:0.19 blue:0.21 alpha:1.0]
#define C_TEXT()   [UIColor whiteColor]
#define C_SUB()    [UIColor colorWithRed:0.62 green:0.62 blue:0.65 alpha:1.0]
#define C_BLUE()   [UIColor colorWithRed:0.20 green:0.55 blue:1.00 alpha:1.0]
#define C_GREEN()  [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1.0]
#define C_RED()    [UIColor colorWithRed:0.92 green:0.30 blue:0.28 alpha:1.0]

extern NSString *BXStallSampleText(void);

@interface BXFloatMenuController ()
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UILabel     *stateLabel;
@property (nonatomic, strong) UILabel     *detailLabel;
@property (nonatomic, strong) NSTimer     *tick;
@end

@implementation BXFloatMenuController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = C_BG();
    self.view.layer.cornerRadius = 14;
    self.view.clipsToBounds = YES;
    [self buildUI];
    [self refresh];
    __weak typeof(self) ws = self;
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(ws) s = ws;
        if (s) [s refresh];
    }];
}

- (void)dealloc { [_tick invalidate]; _tick = nil; }

#pragma mark - 构建

- (void)buildUI {
    CGFloat w = 320, pad = 14;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 12, 200, 20)];
    title.text = @"百相 VCam";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = C_TEXT();
    [self.view addSubview:title];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(w - 110, 14, 96, 16)];
    ver.text = @"RTSP 虚拟摄像头";
    ver.font = [UIFont systemFontOfSize:10];
    ver.textColor = C_SUB();
    ver.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:ver];

    // 地址输入
    _urlField = [[UITextField alloc] initWithFrame:CGRectMake(pad, 44, w - pad * 2, 38)];
    _urlField.backgroundColor = C_CARD();
    _urlField.layer.cornerRadius = 9;
    _urlField.textColor = C_TEXT();
    _urlField.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    _urlField.placeholder = @"rtsp://192.168.1.4:8554/live/123";
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.keyboardType = UIKeyboardTypeURL;
    _urlField.returnKeyType = UIReturnKeyDone;
    _urlField.text = [[BXFloatStore shared] objectForKey:@"rtsp_url"] ?: @"";
    _urlField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    _urlField.leftViewMode = UITextFieldViewModeAlways;
    [self.view addSubview:_urlField];

    // 三个按钮
    CGFloat by = 92, bh = 40, bw = (w - pad * 2 - 16) / 3.0;
    [self addButton:@"连接"   x:pad                            y:by w:bw h:bh color:C_BLUE()  action:@selector(onConnect)];
    [self addButton:@"重连"   x:pad + bw + 8                    y:by w:bw h:bh color:C_CARD()  action:@selector(onReconnect)];
    [self addButton:@"断开"   x:pad + (bw + 8) * 2              y:by w:bw h:bh color:C_RED()   action:@selector(onDisconnect)];
    [self addButton:@"复制日志" x:pad y:by + bh + 8 w:w - pad * 2 h:30 color:C_CARD() action:@selector(onCopyLog)];

    // 状态卡
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, 180, w - pad * 2, 108)];
    card.backgroundColor = C_CARD();
    card.layer.cornerRadius = 10;
    [self.view addSubview:card];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, card.bounds.size.width - 24, 18)];
    _stateLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _stateLabel.textColor = C_TEXT();
    _stateLabel.text = @"未连接";
    [card addSubview:_stateLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, card.bounds.size.width - 24, 68)];
    _detailLabel.numberOfLines = 4;
    _detailLabel.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _detailLabel.textColor = C_SUB();
    [card addSubview:_detailLabel];

    // 说明
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(pad, 296, w - pad * 2, 32)];
    hint.numberOfLines = 2;
    hint.font = [UIFont systemFontOfSize:10];
    hint.textColor = C_SUB();
    hint.text = @"改地址后点「连接」。进相机页会自动连接一次。\n推流地址需与电脑端一致（默认 /live/123）。";
    [self.view addSubview:hint];
}

- (void)addButton:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h
            color:(UIColor *)color action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    b.backgroundColor = color;
    b.layer.cornerRadius = 9;
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT() forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

#pragma mark - 动作

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
}

- (void)onConnect {
    NSString *u = [self currentURL];
    if (!u.length) { [self toast:@"先填地址"]; return; }
    [self saveURL:u];
    [self toast:@"连接中…"];
    BXCaptureBridge *br = [BXCaptureBridge shared];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        BOOL ok = [br useRTSPURLString:u error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self toast:ok ? @"已连接" : [NSString stringWithFormat:@"失败：%@", e.localizedDescription ?: @"未知"]];
            [self refresh];
        });
    });
}

- (void)onReconnect {
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
            [self toast:ok ? @"已重连" : [NSString stringWithFormat:@"失败：%@", e.localizedDescription ?: @"未知"]];
            [self refresh];
        });
    });
}

- (void)onDisconnect {
    [[BXCaptureBridge shared] stopNetworkSources];
    [self toast:@"已断开"];
    [self refresh];
}

- (void)onCopyLog {
    NSString *all = [NSString stringWithFormat:@"=== 日志 ===\n%@\n\n=== 主线程采样 ===\n%@",
                               BXLogText(), BXStallSampleText()];
    [UIPasteboard generalPasteboard].string = all;
    [self toast:@"日志已复制，粘贴给我即可"];
}

- (void)toast:(NSString *)msg {
    _stateLabel.text = msg;
}

#pragma mark - 状态

- (void)refresh {
    BXCaptureBridge *b = [BXCaptureBridge shared];
    BOOL running = b.isStreaming;
    _stateLabel.text = running ? @"已连接" : @"未连接";
    _stateLabel.textColor = running ? C_GREEN() : C_RED();

    NSUInteger readFPS = [b readFPS];
    NSUInteger fillFPS = [b slotFillFPS];
    NSUInteger replFPS = b.replaceFPS;
    _detailLabel.text = [NSString stringWithFormat:
        @"读取 %lu fps   入槽 %lu fps   替换 %lu fps\n已替换 %lu   直通 %lu\n音频欠载 %lu 次 / 缺 %lu 帧\n地址 %@",
        (unsigned long)readFPS, (unsigned long)fillFPS, (unsigned long)replFPS,
        (unsigned long)b.replacedFrames, (unsigned long)b.passthroughFrames,
        (unsigned long)[b audioUnderruns], (unsigned long)[b audioUnderrunFrames],
        running ? @"在线" : @"—"];
}

- (void)reload {
    _urlField.text = [[BXFloatStore shared] objectForKey:@"rtsp_url"] ?: @"";
    [self refresh];
}

@end
