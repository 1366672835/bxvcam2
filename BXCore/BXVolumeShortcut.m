//
//  BXVolumeShortcut.m
//

#import "BXVolumeShortcut.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface BXVolumeShortcut ()
@property (nonatomic, copy) BXVolumeShortcutHandler handler;
@property (nonatomic, assign) NSTimeInterval lastTapTime;
@property (nonatomic, assign) NSInteger upStreak;
@property (nonatomic, assign) NSInteger downStreak;
@property (nonatomic, assign) BOOL started;
@end

/// AVSystemController 私有通知名
static NSString *const kVolumeChangedNotification = @"AVSystemController_SystemVolumeDidChangeNotification";
static NSString *const kVolumeChangeReasonKey    = @"AVSystemController_AudioVolumeChangeReasonNotificationParameter";

@implementation BXVolumeShortcut

+ (instancetype)shared {
    static BXVolumeShortcut *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [BXVolumeShortcut new]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxGap = 0.45;
        _upStreak = 0;
        _downStreak = 0;
    }
    return self;
}

- (void)startWithHandler:(BXVolumeShortcutHandler)handler {
    if (_started) return;
    _started = YES;
    self.handler = handler;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_volumeChanged:)
                                                 name:kVolumeChangedNotification
                                               object:nil];

    // 注意: 不要调用 AVSystemController 的 setAttribute:forKey:error:
    //       那是三参数私有方法，用 performSelector 只能传两个，第三参是垃圾指针会直接崩。
    //       只靠通知中心监听即可。
    Class cls = NSClassFromString(@"AVSystemController");
    if (cls) {
        NSLog(@"[BXFloat] AVSystemController 存在，仅使用通知监听");
    }

    NSLog(@"[BXFloat] 音量键监听已启动");
}

- (void)stop {
    if (!_started) return;
    _started = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_volumeChanged:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *reason = info[kVolumeChangeReasonKey];
    // 排除"用户音量调节"以外的自动变化
    if (reason && ![reason isEqualToString:@"ExplicitVolumeChange"]) return;

    float vol = [info[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
    static float lastVol = -1;
    if (lastVol < 0) { lastVol = vol; return; }

    BOOL isUp = (vol > lastVol);
    lastVol = vol;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval gap = now - self.lastTapTime;
    self.lastTapTime = now;

    if (isUp) {
        self.upStreak = (gap <= self.maxGap) ? self.upStreak + 1 : 1;
        self.downStreak = 0;
        if (self.upStreak >= 2) {
            self.upStreak = 0;
            if (self.handler) self.handler(YES, 2);
        }
    } else {
        self.downStreak = (gap <= self.maxGap) ? self.downStreak + 1 : 1;
        self.upStreak = 0;
        if (self.downStreak >= 2) {
            self.downStreak = 0;
            if (self.handler) self.handler(NO, 2);
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
