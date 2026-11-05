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

// 【已移除】不再 swizzle applicationDidBecomeActive：实测接管它会让"打开相机"整机卡死。
// 改用 UIApplicationDidBecomeActiveNotification 监听（见构造函数），行为等价但不碰系统方法。

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

static void BXUnusedOnBecomeActive(id self, SEL _cmd, id app) {   // 保留签名避免其它引用报错，但不再被 hook 调用
    BXCallOrig(BXOnAppDidBecomeActive_orig, self, _cmd, app);
    BXAttachIfNeeded();
}

#pragma mark - 启动

__attribute__((constructor))
static void BXFloatVCamInit(void) {
    @autoreleasepool {
          NSLog(@"[BXFloat][vcam] init bundle=%@",
                [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");

          // 【诊断 B20】只做 UI：注册模块 + 挂浮窗。
          // 不装钩子、不接音量键、不启动重试定时器、不 hook 生命周期。
          @try { BXRegisterBuiltinModules(); } @catch (NSException *e) { NSLog(@"B20 模块异常 %@", e); }
          @try { [[BXFloatRegistry shared] restoreAll]; } @catch (NSException *e) { NSLog(@"B20 恢复异常 %@", e); }
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
              [[BXFloatWindow shared] attach];
          });


          // 【诊断 B22】B21 + 1.5 秒重试定时器（每 1.5s 调一次 attach，共 40 次）
          {
              __block int tries = 0;
              dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                          dispatch_get_main_queue());
              dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                                        (uint64_t)(1.5 * NSEC_PER_SEC), 0);
              dispatch_source_set_event_handler(t, ^{
                  tries++;
                  [[BXFloatWindow shared] attach];
                  if (tries >= 40) dispatch_source_cancel(t);
              });
              dispatch_resume(t);
          }

          return;

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

              // 4.【已移除】自动恢复上次的本地视频。
              // 原来 dylib 加载（主线程）就去打开那个文件：建 reader、解首帧全在主线程，
              // 相机一启动就撞在一起 —— 表现就是「一打开相机就卡住」。
              // 本地视频已冻结，这里不再恢复；要用时在面板手动选。
              [[BXFloatStore shared] setObject:@"" forKey:@"bx.vcam.path"];

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

