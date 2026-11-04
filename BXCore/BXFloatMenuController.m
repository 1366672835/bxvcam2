//
//  BXFloatMenuController.m —— 面板（结构、控件、交互对照百相 0.20.33）
//
//  首页：
//    标题 + 蓝色圆形 X
//    状态条（连接状态 / 地址）
//    「替换来源」关闭 / 本地视频 / RTSP 拉流   ← 三个 UISwitch，互斥
//    [ 预览 ]                                  ← 整宽按钮
//    「快捷调整」镜像 / 旋转 / 声音来源          ← 三块磁贴，点击循环
//    [ 首页 ][ 我的 ]                           ← 两个 tab
//
//  我的：流地址 / 选择视频 / 运行状态
//
//  稳定性约定：不用 UIScrollView，全部固定 frame；弹窗统一从悬浮窗 rootViewController 出；
//  弹窗前把悬浮窗 hitTest 全放行，否则系统弹窗点不动。
//

#import "BXFloatMenuController.h"
#import "BXFloatStore.h"
#import "BXCaptureBridge.h"
#import "BXPreviewWindow.h"
#import "BXLog.h"
#import "BXConfig.h"

static UIColor *C_BG(void)     { return [UIColor whiteColor]; }
static UIColor *C_TEXT(void)   { return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1]; }
static UIColor *C_SUB(void)    { return [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1]; }
static UIColor *C_CARD(void)   { return [UIColor colorWithRed:0.95 green:0.96 blue:0.97 alpha:1]; }
static UIColor *C_BLUE(void)   { return [UIColor colorWithRed:0.08 green:0.48 blue:0.92 alpha:0.96]; }
static UIColor *C_BLUEBG(void) { return [UIColor colorWithRed:0.08 green:0.48 blue:0.92 alpha:0.10]; }
static UIColor *C_GREEN(void)  { return [UIColor colorWithRed:0.20 green:0.72 blue:0.42 alpha:1]; }
static UIColor *C_LINE(void)   { return [UIColor colorWithRed:0.90 green:0.91 blue:0.92 alpha:1]; }

@interface BXFloatMenuController () <UIDocumentPickerDelegate>

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;

@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UILabel *statusIcon;
@property (nonatomic, strong) UILabel *statusTitle;
@property (nonatomic, strong) UILabel *statusDetail;
@property (nonatomic, strong) UIButton *btnAddr;

@property (nonatomic, strong) UIView *pageHome;
@property (nonatomic, strong) UIView *pageMine;

@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UISwitch *swNone;
@property (nonatomic, strong) UISwitch *swLocal;
@property (nonatomic, strong) UISwitch *swRTSP;
@property (nonatomic, strong) UIView *line1;
@property (nonatomic, strong) UIView *line2;

@property (nonatomic, strong) UIButton *btnPreview;
@property (nonatomic, strong) UILabel *quickLabel;
@property (nonatomic, strong) UIView *tileMirror;
@property (nonatomic, strong) UIView *tileRotate;
@property (nonatomic, strong) UIView *tileAudio;
@property (nonatomic, strong) UIView *tileQuality;

@property (nonatomic, strong) UILabel *addrRowValue;
@property (nonatomic, strong) UILabel *localRowValue;

@property (nonatomic, strong) UIButton *tabHome;
@property (nonatomic, strong) UIButton *tabMine;
@property (nonatomic, assign) NSInteger page;

@property (nonatomic, assign) NSInteger source;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL syncingSwitch;

@end

@implementation BXFloatMenuController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.view.frame.size.width < 100) {
        self.view.frame = CGRectMake(0, 0, 320, 430);
    }
    self.view.backgroundColor = C_BG();
    self.view.layer.cornerRadius = 17;
    self.view.layer.masksToBounds = YES;
    [self buildUI];
    [self refresh];
}

- (CGFloat)W { return self.view.bounds.size.width; }

#pragma mark - 建 UI

- (void)buildUI {
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = [NSString stringWithFormat:@"%@ %@", kBXMenuTitle, kBXVersion];
    _titleLabel.font = [UIFont boldSystemFontOfSize:17];
    _titleLabel.textColor = C_TEXT();
    [self.view addSubview:_titleLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.backgroundColor = C_BLUE();
    _closeButton.layer.cornerRadius = 16;
    [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    _closeButton.tintColor = [UIColor whiteColor];
    _closeButton.imageEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];

    _statusCard = [[UIView alloc] initWithFrame:CGRectZero];
    _statusCard.backgroundColor = C_CARD();
    _statusCard.layer.cornerRadius = 10;
    [self.view addSubview:_statusCard];

    _statusIcon = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusIcon.font = [UIFont boldSystemFontOfSize:17];
    _statusIcon.textAlignment = NSTextAlignmentCenter;
    [_statusCard addSubview:_statusIcon];

    _statusTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _statusTitle.textColor = C_TEXT();
    [_statusCard addSubview:_statusTitle];

    _statusDetail = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusDetail.font = [UIFont systemFontOfSize:10];
    _statusDetail.textColor = C_SUB();
    _statusDetail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_statusCard addSubview:_statusDetail];

    _btnAddr = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnAddr.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [_btnAddr setTitle:@"地址" forState:UIControlStateNormal];
    [_btnAddr setTitleColor:C_BLUE() forState:UIControlStateNormal];
    [_btnAddr addTarget:self action:@selector(urlTapped) forControlEvents:UIControlEventTouchUpInside];
    [_statusCard addSubview:_btnAddr];

    _pageHome = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_pageHome];
    _pageMine = [[UIView alloc] initWithFrame:CGRectZero];
    _pageMine.hidden = YES;
    [self.view addSubview:_pageMine];

    [self buildHome];
    [self buildMine];

    _tabHome = [UIButton buttonWithType:UIButtonTypeSystem];
    [_tabHome setTitle:@"首页" forState:UIControlStateNormal];
    _tabHome.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [_tabHome addTarget:self action:@selector(tabHomeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_tabHome];

    _tabMine = [UIButton buttonWithType:UIButtonTypeSystem];
    [_tabMine setTitle:@"我的" forState:UIControlStateNormal];
    _tabMine.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [_tabMine addTarget:self action:@selector(tabMineTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_tabMine];
}

- (void)buildHome {
    _sourceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sourceLabel.text = @"替换来源";
    _sourceLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _sourceLabel.textColor = C_SUB();
    [_pageHome addSubview:_sourceLabel];

    _swNone = [self switchRow:@"已关闭" sub:@"不替换摄像头" tag:0];
    _line1 = [self lineView];
    [_pageHome addSubview:_line1];
    _swLocal = [self switchRow:@"本地视频" sub:@"用相册里的视频替换" tag:1];
    _line2 = [self lineView];
    [_pageHome addSubview:_line2];
    _swRTSP = [self switchRow:@"RTSP 拉流" sub:@"用你自己的流替换" tag:2];

    _btnPreview = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnPreview.backgroundColor = C_BLUEBG();
    _btnPreview.layer.cornerRadius = 10;
    _btnPreview.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_btnPreview setTitle:@"预览" forState:UIControlStateNormal];
    [_btnPreview setTitleColor:C_BLUE() forState:UIControlStateNormal];
    [_btnPreview addTarget:self action:@selector(previewTapped) forControlEvents:UIControlEventTouchUpInside];
    [_pageHome addSubview:_btnPreview];

    _quickLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _quickLabel.text = @"快捷调整";
    _quickLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _quickLabel.textColor = C_SUB();
    [_pageHome addSubview:_quickLabel];

    _tileMirror = [self tileWithIcon:@"arrow.left.and.right.square" title:@"镜像"];
    _tileRotate = [self tileWithIcon:@"rotate.right" title:@"旋转"];
    _tileAudio  = [self tileWithIcon:@"speaker.wave.2.fill" title:@"视频原声"];
    _tileMirror.tag = 20;
    _tileRotate.tag = 21;
    _tileAudio.tag  = 22;
    // 磁贴用 UIButton 自己的 target-action，不再加手势
}

- (void)buildMine {
    UIView *r1 = [self rowWithTitle:@"流地址" action:@selector(urlTapped)];
    r1.tag = 31;
    [_pageMine addSubview:r1];

    UIView *r2 = [self rowWithTitle:@"选择视频" action:@selector(pickTapped)];
    r2.tag = 32;
    [_pageMine addSubview:r2];

    UIView *r3 = [self rowWithTitle:@"运行状态" action:@selector(statusTapped)];
    r3.tag = 33;
    [_pageMine addSubview:r3];

    UIView *r4 = [self rowWithTitle:@"传输方式" action:@selector(transportTapped)];
    r4.tag = 34;
    [_pageMine addSubview:r4];

    UIView *r5 = [self rowWithTitle:@"导出诊断" action:@selector(exportDiagnostics)];
    r5.tag = 35;
    [_pageMine addSubview:r5];

    UIView *r5b = [self rowWithTitle:@"日志" action:@selector(logTapped)];
    r5b.tag = 36;
    [_pageMine addSubview:r5b];

    UIView *r6 = [self rowWithTitle:@"对齐摄像头帧率" action:@selector(alignCamTapped)];
    r6.tag = 36;
    [_pageMine addSubview:r6];





}

- (UIView *)lineView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.backgroundColor = C_LINE();
    return v;
}

- (UISwitch *)switchRow:(NSString *)title sub:(NSString *)sub tag:(NSInteger)tag {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    t.textColor = C_TEXT();
    t.tag = 40 + tag;
    [_pageHome addSubview:t];

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectZero];
    s.text = sub;
    s.font = [UIFont systemFontOfSize:10];
    s.textColor = C_SUB();
    s.tag = 50 + tag;
    [_pageHome addSubview:s];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.tag = 60 + tag;
    sw.onTintColor = C_BLUE();
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [_pageHome addSubview:sw];
    return sw;
}


// 用 UIButton 做整行，不用手势——手势在穿透 UIWindow 里容易被吞掉
- (UIView *)rowWithTitle:(NSString *)title action:(SEL)action {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.backgroundColor = C_CARD();
    row.layer.cornerRadius = 10;
    row.userInteractionEnabled = YES;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = title;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    l.textColor = C_TEXT();
    l.tag = 70;
    l.userInteractionEnabled = NO;
    [row addSubview:l];

    UILabel *v = [[UILabel alloc] initWithFrame:CGRectZero];
    v.font = [UIFont systemFontOfSize:10];
    v.textColor = C_SUB();
    v.textAlignment = NSTextAlignmentRight;
    v.lineBreakMode = NSLineBreakByTruncatingMiddle;
    v.tag = 71;
    v.userInteractionEnabled = NO;
    [row addSubview:v];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
    iv.image = [UIImage systemImageNamed:@"chevron.right"];
    iv.tintColor = C_SUB();
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tag = 72;
    iv.userInteractionEnabled = NO;
    [row addSubview:iv];
    return row;
}



- (UIView *)tileWithIcon:(NSString *)icon title:(NSString *)title {
    UIButton *t = [UIButton buttonWithType:UIButtonTypeCustom];
    t.backgroundColor = C_BLUEBG();
    t.layer.cornerRadius = 10;
    t.userInteractionEnabled = YES;
    [t addTarget:self action:@selector(tileButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_pageHome addSubview:t];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
    iv.image = [UIImage systemImageNamed:icon];
    iv.tintColor = C_BLUE();
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tag = 101;
    iv.userInteractionEnabled = NO;
    [t addSubview:iv];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = title;
    name.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    name.textColor = C_TEXT();
    name.tag = 102;
    name.userInteractionEnabled = NO;
    [t addSubview:name];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectZero];
    val.font = [UIFont systemFontOfSize:10];
    val.textColor = C_SUB();
    val.tag = 103;
    val.userInteractionEnabled = NO;
    [t addSubview:val];
    return t;
}

- (void)tileButtonTapped:(UIButton *)b {
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] init];
    [self tileTappedByTag:b.tag];
    (void)g;
}

- (void)tileTappedByTag:(NSInteger)tag {
    BXCaptureBridge *b = self.bridge;
    BXFloatStore *st = [BXFloatStore shared];
    if (tag == 20) {
        b.mirror = !b.mirror;
        [st setObject:@(b.mirror) forKey:@"rtsp.mirror"];
    } else if (tag == 21) {
        NSInteger r = (b.rotation + 90) % 360;
        b.rotation = r;
        [st setObject:@(r / 90) forKey:@"rtsp.rotation"];
    } else if (tag == 22) {
        b.audioReplace = !b.audioReplace;
        [st setObject:@(b.audioReplace ? 1 : 0) forKey:@"rtsp.audio_mode"];
    }
    [self refresh];
}


#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = [self W];
    if (w < 100) return;

    CGFloat pad = 14;
    CGFloat cw = w - pad * 2;
    CGFloat y = 10;

    _titleLabel.frame = CGRectMake(pad, y, cw - 44, 24);
    _closeButton.frame = CGRectMake(w - pad - 30, y - 2, 30, 30);
    y += 32;

    _statusCard.frame = CGRectMake(pad, y, cw, 44);
    _statusIcon.frame = CGRectMake(10, 12, 20, 20);
    _statusTitle.frame = CGRectMake(36, 7, cw - 106, 16);
    _statusDetail.frame = CGRectMake(36, 23, cw - 106, 14);
    _btnAddr.frame = CGRectMake(cw - 58, 7, 48, 30);
    y += 52;

    _pageHome.frame = CGRectMake(0, y, w, 340);
    _pageMine.frame = CGRectMake(0, y, w, 340);

    CGFloat hy = 0;
    _sourceLabel.frame = CGRectMake(pad, hy, cw, 13);
    hy += 18;

    NSArray *sws = @[_swNone, _swLocal, _swRTSP];
    for (NSInteger i = 0; i < 3; i++) {
        UILabel *t = [_pageHome viewWithTag:40 + i];
        UILabel *s = [_pageHome viewWithTag:50 + i];
        UISwitch *sw = sws[i];
        t.frame = CGRectMake(pad, hy + 2, cw - 70, 17);
        s.frame = CGRectMake(pad, hy + 19, cw - 70, 12);
        sw.frame = CGRectMake(w - pad - 51, hy + 6, 51, 31);
        hy += 40;
        if (i < 2) {
            UIView *ln = (i == 0) ? _line1 : _line2;
            ln.frame = CGRectMake(pad + 2, hy - 4, cw - 4, 1);
        }
    }

    hy += 6;
    _btnPreview.frame = CGRectMake(pad, hy, cw, 40);
    hy += 48;

    _quickLabel.frame = CGRectMake(pad, hy, cw, 13);
    hy += 18;

    CGFloat gap = 8;
    CGFloat tw = (cw - gap * 3) / 4.0;
    NSMutableArray *tiles = [NSMutableArray array];
    for (UIView *tv in @[_tileMirror, _tileRotate, _tileAudio]) {
        if (tv) [tiles addObject:tv];
    }
    for (NSInteger i = 0; i < (NSInteger)tiles.count; i++) {
        UIView *t = tiles[i];
        t.frame = CGRectMake(pad + i * (tw + gap), hy, tw, 58);
        UIImageView *iv = [t viewWithTag:101];
        UILabel *name = [t viewWithTag:102];
        UILabel *val = [t viewWithTag:103];
        iv.frame = CGRectMake(8, 7, 16, 16);
        name.frame = CGRectMake(8, 26, tw - 16, 13);
        val.frame = CGRectMake(8, 40, tw - 16, 12);
    }

    CGFloat my = 0;
    // 注意：@[ ... ] 字面量里只要有 nil 就会直接崩，
    // 这里必须逐个判空后再用（viewWithTag 找不到时返回 nil）。
    NSMutableArray *rows = [NSMutableArray array];
    for (NSInteger t = 31; t <= 36; t++) {
        UIView *row = [_pageMine viewWithTag:t];
        if (row) [rows addObject:row];
    }
    for (UIView *row in rows) {
        row.frame = CGRectMake(pad, my, cw, 46);
        UILabel *l = [row viewWithTag:70];
        UILabel *v = [row viewWithTag:71];
        UIImageView *iv = [row viewWithTag:72];
        l.frame = CGRectMake(12, 8, 90, 16);
        v.frame = CGRectMake(104, 8, cw - 140, 16);
        iv.frame = CGRectMake(cw - 26, 15, 12, 16);
        my += 52;
    }
    _addrRowValue = (UILabel *)[[_pageMine viewWithTag:31] viewWithTag:71];
    _localRowValue = (UILabel *)[[_pageMine viewWithTag:32] viewWithTag:71];

    CGFloat tabY = self.view.bounds.size.height - 44;
    _tabHome.frame = CGRectMake(pad, tabY, cw / 2.0 - 4, 34);
    _tabMine.frame = CGRectMake(pad + cw / 2.0 + 4, tabY, cw / 2.0 - 4, 34);
}

#pragma mark - 动作

- (BXCaptureBridge *)bridge { return [BXCaptureBridge shared]; }

- (NSString *)savedURL {
    NSString *u = [[BXFloatStore shared] objectForKey:@"rtsp_url"];
    return u.length ? u : kBXDefaultStreamURL;
}

- (UIViewController *)hostVC {
    Class wc = NSClassFromString(@"BXFloatWindow");
    if (wc && [wc respondsToSelector:NSSelectorFromString(@"shared")]) {
        id win = [wc performSelector:NSSelectorFromString(@"shared")];
        if ([win isKindOfClass:[UIWindow class]]) {
            UIViewController *vc = [(UIWindow *)win rootViewController];
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (vc) return vc;
        }
    }
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) {
                UIViewController *vc = w.rootViewController;
                while (vc.presentedViewController) vc = vc.presentedViewController;
                return vc;
            }
        }
    }
    return nil;
}

- (void)setModalTouch:(BOOL)allow {
    @try {
        Class wc = NSClassFromString(@"BXFloatWindow");
        if (!wc) return;
        id win = [wc performSelector:NSSelectorFromString(@"shared")];
        if ([win respondsToSelector:@selector(setAllowAllTouches:)]) {
            [win setValue:@(allow) forKey:@"allowAllTouches"];
        }
    } @catch (NSException *e) {
    }
}

// 面板内嵌文本视图：完全不碰 UIAlertController / present，
// 状态页和诊断导出都走这里，避免「一点就崩」。
- (void)markStep:(NSString *)step {
    // 崩溃时 Console 拿不到，就把"最后走到哪一步"落到 UserDefaults，
    // 下次打开面板「我的」页那一行会直接显示出来。
    [[NSUserDefaults standardUserDefaults] setObject:step forKey:@"bx.diag.laststep"];
}

- (void)clearStep {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"bx.diag.laststep"];
}

- (void)showInlineText:(NSString *)title body:(NSString *)body {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setModalTouch:YES];

        UIView *sheet = [self.view viewWithTag:9001];
        if (!sheet) {
            sheet = [[UIView alloc] initWithFrame:CGRectMake(8, 60, self.view.bounds.size.width - 16, 300)];
            sheet.tag = 9001;
            sheet.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.97];
            sheet.layer.cornerRadius = 10;
            sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, sheet.bounds.size.width - 24, 20)];
            t.tag = 9002;
            t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            [sheet addSubview:t];

            UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(8, 32, sheet.bounds.size.width - 16,
                                                                        sheet.bounds.size.height - 76)];
            tv.tag = 9003;
            tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
            tv.editable = NO;
            tv.backgroundColor = [UIColor clearColor];
            tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [sheet addSubview:tv];

            UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
            copy.frame = CGRectMake(8, sheet.bounds.size.height - 38, 90, 30);
            copy.tag = 9004;
            copy.titleLabel.font = [UIFont systemFontOfSize:12];
            [copy setTitle:@"复制全文" forState:UIControlStateNormal];
            [copy addTarget:self action:@selector(copyInlineText) forControlEvents:UIControlEventTouchUpInside];
            [sheet addSubview:copy];

            UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
            close.frame = CGRectMake(sheet.bounds.size.width - 78, sheet.bounds.size.height - 38, 70, 30);
            close.titleLabel.font = [UIFont systemFontOfSize:12];
            [close setTitle:@"已关闭" forState:UIControlStateNormal];
            [close addTarget:self action:@selector(closeInlineText) forControlEvents:UIControlEventTouchUpInside];
            [sheet addSubview:close];

            [self.view addSubview:sheet];
        }

        UILabel *t = (UILabel *)[sheet viewWithTag:9002];
        UITextView *tv = (UITextView *)[sheet viewWithTag:9003];
        t.text = title;
        tv.text = body ?: @"";
        sheet.hidden = NO;
        [self.view bringSubviewToFront:sheet];
        BXLog(@"[BXFloat][panel] 内嵌文本 len=%lu title=%@", (unsigned long)(body.length), title);
    });
}

- (void)copyInlineText {
    UIView *sheet = [self.view viewWithTag:9001];
    UITextView *tv = (UITextView *)[sheet viewWithTag:9003];
    if (tv.text.length) {
        UIPasteboard.generalPasteboard.string = tv.text;
        BXLog(@"[BXFloat][panel] 已复制 %lu 字节", (unsigned long)tv.text.length);
    }
}

- (void)closeInlineText {
    UIView *sheet = [self.view viewWithTag:9001];
    sheet.hidden = YES;
    [self setModalTouch:NO];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = [self hostVC];
        if (!host) {
            BXLog(@"[BXFloat][panel] 无 presenter: %@ %@", title, msg);
            return;
        }
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction *a) { [self setModalTouch:NO]; }]];
        [self setModalTouch:YES];
        @try {
            [host presentViewController:ac animated:YES completion:nil];
        } @catch (NSException *e) {
            BXLog(@"[BXFloat][panel] 弹窗异常 %@", e);
            [self setModalTouch:NO];
        }
    });
}

- (void)switchChanged:(UISwitch *)sw {
    if (self.syncingSwitch) return;
    if (self.busy) {
        [self refresh];
        return;
    }

    NSInteger tag = sw.tag - 60;

    if (!sw.isOn) {
        [self stopEverything];
        self.source = 0;
        [self persist];
        [self refresh];
        return;
    }

    if (tag == 0) {
        [self stopEverything];
        self.source = 0;
        [self persist];
        [self refresh];
        return;
    }

    if (tag == 1) {
        [self stopNetwork];
        self.source = 1;
        [self persist];
        if (!self.bridge.sourcePath.length) {
            [self refresh];
            [self presentPicker];
            return;
        }
        self.bridge.enabled = YES;
        [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
        [self refresh];
        return;
    }

    [self startRTSP];
}

- (void)tabHomeTapped { self.page = 0; [self refresh]; }
- (void)tabMineTapped { self.page = 1; [self refresh]; }

- (void)tileTapped:(UITapGestureRecognizer *)g {
    BXCaptureBridge *b = self.bridge;
    BXFloatStore *st = [BXFloatStore shared];

    if (g.view.tag == 20) {
        b.mirror = !b.mirror;
        [st setObject:@(b.mirror) forKey:@"rtsp.mirror"];
    } else if (g.view.tag == 21) {
        NSInteger r = (b.rotation + 90) % 360;
        b.rotation = r;
        [st setObject:@(r / 90) forKey:@"rtsp.rotation"];
    } else if (g.view.tag == 22) {
        b.audioReplace = !b.audioReplace;
        [st setObject:@(b.audioReplace ? 1 : 0) forKey:@"rtsp.audio_mode"];
    } 
    [self refresh];
}

- (void)startRTSP {
    if (self.busy) return;
    NSString *url = [self savedURL];
    if (!url.length) {
        [self promptURL];
        return;
    }

    self.busy = YES;
    [self refresh];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSError *err = nil;
        BOOL ok = NO;
        @try {
            ok = [url hasPrefix:@"rtsp://"]
                ? [s.bridge useRTSPURLString:url error:&err]
                : [s.bridge useStreamURLString:url error:&err];
        } @catch (NSException *e) {
            err = [NSError errorWithDomain:@"BX" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"异常"}];
        }
        BXLog(@"[BXFloat][panel] 连流 ok=%d err=%@", (int)ok, err);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            s2.busy = NO;
            if (ok) {
                s2.bridge.enabled = YES;
                s2.source = 2;
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
                [[BXFloatStore shared] setObject:@(YES) forKey:@"rtsp.enabled"];
                [[BXFloatStore shared] setObject:url forKey:@"rtsp_url"];
            } else {
                s2.source = 0;
                [[BXFloatStore shared] setObject:@(NO) forKey:@"rtsp.enabled"];
                [s2 alert:@"连接失败" message:err.localizedDescription ?: @"无法连接该地址"];
            }
            [s2 persist];
            [s2 refresh];
        });
    });
}

- (void)promptURL {
    UIViewController *host = [self hostVC];
    if (!host) {
        [self alert:@"打不开输入框" message:@"没有可用的控制器"];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"流地址"
                                                               message:@"rtsp://ip:554/路径"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    NSString *cur = [self savedURL];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = @"rtsp://192.168.1.4:8554/live/123";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a) { [self setModalTouch:NO]; }]];

    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存并连接" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [self setModalTouch:NO];
        NSString *u = ac.textFields.firstObject.text ?: @"";
        u = [u stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!u.length) return;
        // 没写 scheme 的自动补 rtsp://，凭据（user:pass@）原样保留
        if ([u rangeOfString:@"://"].location == NSNotFound) {
            u = [@"rtsp://" stringByAppendingString:u];
        }
        [[BXFloatStore shared] setObject:u forKey:@"rtsp_url"];
        [weakSelf startRTSP];
    }]];

    [self setModalTouch:YES];
    @try {
        [host presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 输入框异常 %@", e);
        [self setModalTouch:NO];
    }
}

- (void)presentPicker {
    UIViewController *host = [self hostVC];
    if (!host) {
        [self alert:@"视频选择器暂时不可用" message:@"没有可用的控制器"];
        return;
    }
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                             inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self setModalTouch:YES];
    @try {
        [host presentViewController:p animated:YES completion:nil];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 选择器异常 %@", e);
        [self setModalTouch:NO];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {
    [self setModalTouch:NO];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self setModalTouch:NO];
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSError *e = nil;
    BOOL ok = [self.bridge useVideoAtPath:u.path error:&e];
    if (ok) {
        [[BXFloatStore shared] setObject:u.path forKey:@"bx.vcam.path"];
        [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
        self.bridge.enabled = YES;
        self.source = 1;
        [self persist];
    } else {
        [self alert:@"视频导入失败，请重新选择" message:e.localizedDescription ?: @"未知"];
    }
    [self refresh];
}

// rtsp://user:pass@host/path → rtsp://***@host/path
// 诊断信息经常被贴到群里，凭据不能带出去。
static NSString *BXMaskURL(NSString *url) {
    if (!url.length) return @"-";
    NSRange scheme = [url rangeOfString:@"://"];
    if (scheme.location == NSNotFound) return url;
    NSUInteger start = scheme.location + scheme.length;
    if (start >= url.length) return url;

    // 权限段结束于第一个 / ? #
    NSRange tail = [url rangeOfCharacterFromSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"/?#"]
                                         options:0
                                           range:NSMakeRange(start, url.length - start)];
    NSUInteger authEnd = (tail.location == NSNotFound) ? url.length : tail.location;

    // 取权限段里「最后一个」@：userinfo 本身可能含 @（如 a:b@c@host）
    NSRange authRange = NSMakeRange(start, authEnd - start);
    NSRange at = [url rangeOfString:@"@" options:NSBackwardsSearch range:authRange];
    if (at.location == NSNotFound) return url;

    return [url stringByReplacingCharactersInRange:NSMakeRange(start, at.location - start)
                                        withString:@"***"];
}

- (void)alignCamTapped {
    BXCaptureBridge *b = self.bridge;
    [self refresh];
}

- (void)exportDiagnostics {
    [self markStep:@"diag1"];
    @try {
        [self.bridge rebuildSnapshot];          // 现场重建，否则读到的是会话启动那一刻的旧值
    NSDictionary *d = self.bridge.snapshot;
        if (!d) {
            [self showInlineText:@"诊断" body:@"快照还没生成（等一秒后再点）"];
            [self clearStep];
            return;
        }
        #define S(key, def) (d[key] ?: def)
        // 布尔取值：显式走 NSNumber，避免依赖外部宏签名
        #define SBOOLK(key) ([(NSNumber *)S(key, @0) boolValue])

        NSMutableString *m = [NSMutableString stringWithString:@"baixiang-diagnostics-v1:"];
        [m appendFormat:@"\noutputs=%@", S(@"outputs", @"?")];
        [m appendFormat:@"\nsessionOut=%@", S(@"sessionOut", @"?")];
        [m appendFormat:@"\nver=%@ dev=%@ ios=%@", kBXVersion,
         [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];
        [m appendFormat:@"\nhook=%@ enabled=%@ captured=%@ hooked=%@ setterV=%@ setterA=%@ dhooked=%@",
         S(@"installed", @0), S(@"enabled", @0), S(@"captured", @0), S(@"hooked", @0),
         S(@"setterV", @0), S(@"setterA", @0), S(@"dhooked", @0)];
        [m appendFormat:@"\ntransport=%@ decode=%@",
         S(@"transport", @"?"), S(@"decodeMode", @"?")];
        [m appendFormat:@"\nfps read=%@ decode=%@ replace=%@ slot=%@ declared=%@",
         S(@"readFPS", @0), S(@"decodeFPS", @0), S(@"replaceFPS", @0),
         S(@"slotFillFPS", @0), S(@"declaredFPS", @0)];
        [m appendFormat:@"\nframes decoded=%@ replaced=%@ passthrough=%@ gate=%@ noframe=%@ blitfail=%@",
         S(@"decodedFrames", @0), S(@"replaced", @0), S(@"passthrough", @0),
         S(@"passGate", @0), S(@"passNoFrame", @0), S(@"passBlitFail", @0)];
        [m appendFormat:@"\nreadMs=%@ decodeBlkMs=%@", S(@"readMs", @0), S(@"decodeBlockMs", @0)];
        [m appendFormat:@"\nswsMs=%@ vtMs=%@", S(@"swsMs", @0), S(@"vtMs", @0)];
        [m appendFormat:@"\nvt errors=%@ decodeMs=%@ transformMs=%@ gapAvg=%@ gapMax=%@ latency=%@",
         S(@"vtErrors", @0), S(@"vtDecodeMs", @0), S(@"transformMs", @0),
         S(@"gapAvg", @0), S(@"gapMax", @0), S(@"latency", @0)];
        [m appendFormat:@"\naudio track=%@ codec=%@ dec=%@ reason=%@",
         S(@"audioTrack", @0), S(@"audioCodec", @"?"), S(@"audioDec", @0), S(@"audioWhy", @"-")];
        [m appendFormat:@"\naudio cb=%@ decoded=%@ blitOK=%@ underruns=%@/%@ audioReplace=%@ loop=%@",
         S(@"audioCb", @0), S(@"audioDecoded", @0), S(@"audioBlitOK", @0),
         S(@"underruns", @0), S(@"underFrames", @0),
         S(@"audioReplace", @0), S(@"loop", @0)];
        [m appendFormat:@"\nreason=%@ / frame=%@ / build=%@", S(@"gateReason", @"-"),
         S(@"frameReason", @"-"), S(@"buildError", @"-")];
        [m appendFormat:@"\nurl=%@", BXMaskURL(S(@"url", @"-"))];
        #undef S
        #undef SBOOLK

        UIPasteboard.generalPasteboard.string = m;
        [self markStep:@"diag2"];
        [self clearStep];
        [self showInlineText:@"诊断（可长按选择或点复制）" body:m];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 诊断异常 %@ %@", e.name, e.reason);
        [self showInlineText:@"诊断出错" body:[NSString stringWithFormat:@"%@: %@", e.name, e.reason]];
    }
}

- (void)transportTapped {
    BXCaptureBridge *b = self.bridge;
    b.preferUDP = !b.preferUDP;
    [[BXFloatStore shared] setObject:@(!b.preferUDP) forKey:@"prefer_tcp"];
    BXLog(@"[BXFloat][panel] 传输方式 -> %@", b.preferUDP ? @"udp" : @"tcp");
    // 切换后按当前地址重连，立刻生效
    if (b.rtspURL.length) {
        [self stopNetwork];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self startRTSP]; });
    }
    [self refresh];
}

- (void)pickTapped { [self presentPicker]; }
- (void)urlTapped  { [self promptURL]; }

- (void)logTapped {
    NSString *text = BXLogText();
    UIPasteboard.generalPasteboard.string = text;
    [self showInlineText:@"日志（已复制，可粘贴发送）" body:text];
}

- (void)previewTapped {
    NSString *url = self.bridge.rtspURL.length ? self.bridge.rtspURL : [self savedURL];
    @try {
        [[BXPreviewWindow shared] showWithURL:url];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 预览异常 %@", e);
    }
}

- (void)statusTapped {
    [self markStep:@"status1"];
    @try {
        // 只读快照：所有值都是每秒拷好的副本，不会碰到会被后台线程释放的对象
        [self.bridge rebuildSnapshot];          // 现场重建，否则读到的是会话启动那一刻的旧值
    NSDictionary *d = self.bridge.snapshot;
        if (!d) {
            [self showInlineText:@"运行状态" body:@"快照还没生成（等一秒后再点）"];
            [self clearStep];
            return;
        }

        #define S(key, def) (d[key] ?: def)
        // 布尔取值：显式走 NSNumber，避免依赖外部宏签名
        #define SBOOLK(key) ([(NSNumber *)S(key, @0) boolValue])
        NSString *msg = [NSString stringWithFormat:
            @"hook：%@   启用：%@   接管采集：%@   已hook方法：%@\n"
             "读取fps：%@   解码fps：%@   替换fps：%@   入槽fps：%@\n"
             "每帧 读包 %@ ms / 解码 %@ ms / 循环 %@ ms（循环≈读包＝在等数据）\n"
             "流声明fps：%@   VT错误：%@   单帧解码：%@ ms\n"
             "包间隔 avg %@ ms / max %@ ms   停顿 %@ 次/秒\n"
             "重连 %@ 次   seek %@ 次   EAGAIN %@   读错 %@\n"
             "拆解(每秒)：读包 %@  写槽 %@  音频 %@  其它 %@ ms\n"
             "端到端延迟：%@ ms\n"
             "已解码：%@   进入造帧：%@   已替换：%@   直通：%@\n"
             "直通原因 未接管:%@ 取帧为空:%@ 写入失败:%@\n"
             "造帧：%@   错误：%@   判定：%@\n"
             "传输：%@   解码模式：%@   解码后端：%@   单帧耗时：%@ ms\n"
             "自动判定：%@\n"
             "音频轨：%@   编码：%@   解码器：%@\n"
             "音频回调：%@   解码帧：%@   写入成功：%@\n"
             "音频欠载：%@ 次 / 缺 %@ 帧   音频写入：%@\n"
             "镜像：%@   旋转：%@   声音：%@   循环：%@\n"
             "流状态：%@\n"
             "来源：%@",
            SBOOLK(@"installed") ? @"已装" : @"未装",
            SBOOLK(@"enabled") ? @"是" : @"否",
            S(@"captured", @0), S(@"hooked", @0),
            S(@"readFPS", @0), S(@"decodeFPS", @0), S(@"replaceFPS", @0), S(@"slotFillFPS", @0),
            S(@"readMs", @0), S(@"decodeBlockMs", @0), S(@"loopMs", @0),
            S(@"declaredFPS", @0), S(@"vtErrors", @0), S(@"vtDecodeMs", @0),
            S(@"gapAvg", @0), S(@"gapMax", @0), S(@"gapStalls", @0),
            S(@"reconnN", @0), S(@"seekN", @0), S(@"eagainN", @0), S(@"errN", @0),
            S(@"readSec", @0), S(@"feedSec", @0), S(@"audioSec", @0), S(@"otherSec", @0),
            S(@"latency", @0),
            S(@"decodedFrames", @0), S(@"attemptFrames", @0), S(@"replaced", @0), S(@"passthrough", @0),
            S(@"passGate", @0), S(@"passNoFrame", @0), S(@"passBlitFail", @0),
            S(@"frameReason", @"-"), S(@"buildError", @"-"), S(@"gateReason", @"-"),
            S(@"transport", @"?"), S(@"decodeMode", @"?"), S(@"backend", @"?"), S(@"transformMs", @0),
            S(@"diagnosis", @"-"),
            SBOOLK(@"audioTrack") ? @"有" : @"无", S(@"audioCodec", @"?"),
            SBOOLK(@"audioDec") ? @"就绪" : @"缺失",
            S(@"audioCb", @0), S(@"audioDecoded", @0), S(@"audioBlitOK", @0),
            S(@"underruns", @0), S(@"underFrames", @0), S(@"audioWhy", @"-"),
            SBOOLK(@"mirror") ? @"已开启" : @"已关闭",
            S(@"rotation", @0),
            SBOOLK(@"audioReplace") ? @"视频原声" : @"麦克风",
            SBOOLK(@"loop") ? @"已开启" : @"已关闭",
            SBOOLK(@"stale") ? @"已停止" : @"正常",
            S(@"url", @"-")];
        #undef S
        #undef SBOOLK

        [self markStep:@"status2"];
        [self showInlineText:@"运行状态" body:msg];
        [self clearStep];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 状态页异常 %@ %@", e.name, e.reason);
        [self showInlineText:@"状态页出错" body:[NSString stringWithFormat:@"%@: %@", e.name, e.reason]];
    }
}

- (void)closeTapped {
    SEL sel = NSSelectorFromString(@"_collapseMenu");
    Class wc = NSClassFromString(@"BXFloatWindow");
    if (wc && [wc respondsToSelector:NSSelectorFromString(@"shared")]) {
        id win = [wc performSelector:NSSelectorFromString(@"shared")];
        if (win && [win respondsToSelector:sel]) {
            [win performSelector:sel];
            return;
        }
    }
    self.view.hidden = YES;
}

#pragma mark - 状态

- (void)stopNetwork {
    @try {
        [self.bridge stopNetworkSources];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][panel] 停网络异常 %@", e);
    }
}

- (void)stopEverything {
    [self stopNetwork];
    self.bridge.enabled = NO;
    [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.vcam.enabled"];
    [[BXFloatStore shared] setObject:@(NO) forKey:@"rtsp.enabled"];

    @try {
        Class pv = NSClassFromString(@"BXPreviewWindow");
        if (pv) {
            id shared = [pv performSelector:NSSelectorFromString(@"shared")];
            SEL hide = NSSelectorFromString(@"hidePreview");
            if (shared && [shared respondsToSelector:hide]) [shared performSelector:hide];
        }
    } @catch (NSException *e) {
    }
}

- (void)persist {
    NSString *v = (self.source == 2) ? @"rtsp" : (self.source == 1 ? @"local" : @"none");
    [[BXFloatStore shared] setObject:v forKey:@"bx.vcam.source"];
}

- (void)restoreAudioOnce {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    // 恢复镜像 / 旋转 / 启用开关（这三个之前只写不读，重启后丢失）
    id mv = [[BXFloatStore shared] objectForKey:@"rtsp.mirror"];
    if ([mv isKindOfClass:[NSNumber class]]) self.bridge.mirror = [mv boolValue];

    id rv = [[BXFloatStore shared] objectForKey:@"rtsp.rotation"];
    if ([rv isKindOfClass:[NSNumber class]]) {
        NSInteger idx = [rv integerValue];
        self.bridge.rotation = (idx % 4) * 90;
    }

    id ev = [[BXFloatStore shared] objectForKey:@"rtsp.enabled"];
    if ([ev isKindOfClass:[NSNumber class]]) self.bridge.enabled = [ev boolValue];

    // 原版用 prefer_tcp 存传输方式（与我们内部的 preferUDP 相反）
    // 原版 0x3312c0：rtsp_transport 写死 "tcp"（cmp x28,#2 → 是 RTSP 就设，无条件）
    // 所以默认保持 TCP，和原版一致。
    id tcp = [[BXFloatStore shared] objectForKey:@"prefer_tcp"];
    if ([tcp isKindOfClass:[NSNumber class]]) {
        self.bridge.preferUDP = ![tcp boolValue];
    }

    id saved = [[BXFloatStore shared] objectForKey:@"rtsp.audio_mode"];
    if ([saved isKindOfClass:[NSNumber class]]) {
        self.bridge.audioReplace = ([saved integerValue] != 0);
    } else {
        self.bridge.audioReplace = YES;      // 默认视频原声
        [[BXFloatStore shared] setObject:@(1) forKey:@"rtsp.audio_mode"];
    }
}

- (void)refresh {
    [self restoreAudioOnce];
    BXCaptureBridge *b = self.bridge;
    NSString *rtsp = b.rtspURL;
    NSString *local = b.sourcePath;

    NSInteger cur = self.source;
    if (rtsp.length) cur = 2;
    else if (b.enabled && local.length) cur = 1;
    self.source = cur;

    self.syncingSwitch = YES;
    self.swNone.on = (cur == 0);
    self.swLocal.on = (cur == 1);
    self.swRTSP.on  = (cur == 2);
    self.syncingSwitch = NO;

    if (self.busy) {
        _statusIcon.text = @"⋯";
        _statusIcon.textColor = C_BLUE();
        _statusTitle.text = @"连接中...";
        _statusDetail.text = [self savedURL];
        // 断流：明确告诉用户是流断了，不是画面卡死
        _statusIcon.text = @"!";
        _statusIcon.textColor = [UIColor systemRedColor];
        _statusTitle.text = @"RTSP 预览已停止，替换功能不受影响";
        _statusTitle.textColor = [UIColor systemRedColor];
        _statusDetail.text = @"超过 3 秒没有新画面，已临时显示摄像头";
    } else if (cur == 2 && rtsp.length) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = @"RTSP 连接中，等待视频首帧...";
        _statusTitle.textColor = C_TEXT();
        _statusDetail.text = [NSString stringWithFormat:@"%@ · 已替换 %lu 帧",
                              rtsp, (unsigned long)b.replacedFrames];
    } else if (cur == 1 && local.length) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = @"本地视频";
        _statusDetail.text = local.lastPathComponent;
    } else {
        _statusIcon.text = @"○";
        _statusIcon.textColor = C_SUB();
        _statusTitle.text = @"未连接";
        _statusDetail.text = [self savedURL].length ? [self savedURL]
                                                   : @"点「地址」填一个 rtsp:// 地址";
    }

    UILabel *vm = [_tileMirror viewWithTag:103];
    UILabel *vr = [_tileRotate viewWithTag:103];
    UILabel *va = [_tileAudio viewWithTag:103];
    vm.text = b.mirror ? @"已开启" : @"已关闭";
    vr.text = [NSString stringWithFormat:@"%ld°", (long)b.rotation];

    // 声音这块不是「动作」而是「状态」：标题直接写当前值，
    // 副标题说明什么时候才有采集回调（拍摄页本来就没有音频回调）。
    UILabel *na = [_tileAudio viewWithTag:102];
    if (na) na.text = b.audioReplace ? @"视频原声" : @"麦克风";
    if (va) va.text = @"直播/连麦生效";

    _tileMirror.backgroundColor = b.mirror ? C_BLUEBG() : C_CARD();
    _tileRotate.backgroundColor = (b.rotation != 0) ? C_BLUEBG() : C_CARD();
    _tileAudio.backgroundColor  = b.audioReplace ? C_BLUEBG() : C_CARD();

    if (_addrRowValue) _addrRowValue.text = [self savedURL];
    if (_localRowValue) _localRowValue.text = local.length ? local.lastPathComponent : @"未选择";
    UILabel *dv = (UILabel *)[[_pageMine viewWithTag:38] viewWithTag:71];

    UILabel *av = (UILabel *)[[_pageMine viewWithTag:36] viewWithTag:71];

    UILabel *sv = (UILabel *)[[_pageMine viewWithTag:33] viewWithTag:71];
    if (sv) {
        NSString *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"bx.diag.laststep"];
        sv.text = last.length ? [NSString stringWithFormat:@"上次停步 %@", last] : @"点开查看";
    }

    UILabel *tv = (UILabel *)[[_pageMine viewWithTag:34] viewWithTag:71];
    if (tv) tv.text = b.preferUDP ? @"UDP（点击切 TCP）" : @"TCP（点击切 UDP）";

    _pageHome.hidden = (self.page != 0);
    _pageMine.hidden = (self.page == 0);
    [_tabHome setTitleColor:(self.page == 0 ? C_BLUE() : C_SUB()) forState:UIControlStateNormal];
    [_tabMine setTitleColor:(self.page == 1 ? C_BLUE() : C_SUB()) forState:UIControlStateNormal];
}

- (void)reload {
    [self refresh];
}

@end
