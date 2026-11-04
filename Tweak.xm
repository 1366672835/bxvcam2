//
//  Tweak.xm — 虚拟摄像头注入入口（TrollStore / 裸 dylib）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "BXConfig.h"
#import "BXFloatWindow.h"
#import "BXFloatMenuController.h"
#import "BXFloatModule.h"
#import "BXFloatStore.h"
#import "BXVolumeShortcut.h"
#import "BXAudioUnitHook.h"
#import "BXSwizzle.h"
#import "BXCaptureBridge.h"

extern "C" void BXRegisterBuiltinModules(void);

static void BXAttachIfNeeded(void);
static void BXOnAppDidBecomeActive(id self, SEL _cmd, id app);

BX_SWIZZLE(UIApplication, applicationDidBecomeActive:, BXOnAppDidBecomeActive)

#pragma mark - 挂载判定

static BOOL BXShouldAttach(void) {
    if (kBXAttachEverywhere) return YES;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (int i = 0; i < kBXTargetBundleIDCount; i++) {
        if ([bundle isEqualToString:kBXTargetBundleIDs[i]]) return YES;
    }
    return NO;
}

static void BXAttachIfNeeded(void) {
    if (!BXShouldAttach()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[BXFloatWindow shared] attach];
    });
}

static void BXOnAppDidBecomeActive(id self, SEL _cmd, id app) {
    BXCallOrig(BXOnAppDidBecomeActive_orig, self, _cmd, app);
    BXAttachIfNeeded();
}

#pragma mark - 启动

__attribute__((constructor))
static void BXFloatVCamInit(void) {
    @autoreleasepool {
        NSLog(@"[BXFloat][vcam] init bundle=%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");

        // 1. 先装采集桥 —— 必须早于 App 创建 AVCaptureSession
        @try {
            [[BXCaptureBridge shared] install];
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] install 异常: %@", e);
        }

        // 2. 注册 UI 模块
        @try {
            BXRegisterBuiltinModules();
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] 注册模块异常: %@", e);
        }

        // 3. 恢复上次状态
        @try {
            [[BXFloatRegistry shared] restoreAll];

            // 4. 恢复上次选的视频
            NSString *path = [[BXFloatStore shared] objectForKey:@"bx.vcam.path"];
            if (path.length) {
                NSError *e = nil;
                if (![[BXCaptureBridge shared] useVideoAtPath:path error:&e]) {
                    NSLog(@"[BXFloat][vcam] 恢复视频失败: %@", e);
                }
            }

            // 5. 开关与画面选项
            BXFloatStore *st = [BXFloatStore shared];
            NSNumber *en = [st objectForKey:@"bx.vcam.enabled"];
            [BXCaptureBridge shared].enabled = en ? en.boolValue : NO;

            NSNumber *lo = [st objectForKey:@"bx.vcam.loop"];
            [BXCaptureBridge shared].loop = lo ? lo.boolValue : YES;

            NSNumber *mi = [st objectForKey:@"bx.vcam.mirror"];
            [BXCaptureBridge shared].mirror = mi ? mi.boolValue : NO;

            NSNumber *ro = [st objectForKey:@"bx.vcam.rotation"];
            [BXCaptureBridge shared].rotation = ro ? ro.integerValue * 90 : 0;
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] 恢复状态异常: %@", e);
        }

        // 6. 音量键快捷键
        @try {
            [[BXVolumeShortcut shared] startWithHandler:^(BOOL isVolumeUp, NSInteger taps) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!isVolumeUp) return;
                    if (!BXShouldAttach()) return;
                    BXFloatWindow *w = [BXFloatWindow shared];
                    if (w.hidden) [w attach];
                    [w.bubble sendActionsForControlEvents:UIControlEventTouchUpInside];
                });
            }];
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] 音量键异常: %@", e);
        }

        // 7. hook 生命周期
        @try {
            static dispatch_once_t once;
            dispatch_once(&once, ^{ BXInstall_BXOnAppDidBecomeActive(); });
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] hook 异常: %@", e);
        }

        // 反复尝试挂载：某些场景（冷启动、切后台回来）第一秒拿不到 windowScene，
        // 只试一次就会「插件不见了」。这里持续重试，直到挂上为止。
        __block int tries = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(1.5 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(timer, ^{
            tries++;
            UIApplication *app = [UIApplication sharedApplication];
            BOOL active = (app.applicationState == UIApplicationStateActive);
            if (active && BXShouldAttach()) {
                [[BXFloatWindow shared] attach];
            }
            if (tries >= 40) dispatch_source_cancel(timer);   // 60 秒后放弃
        });
        dispatch_resume(timer);
    }
}

