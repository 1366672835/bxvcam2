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
#import "BXAudioUnitHook.h"
#import "BXSwizzle.h"
#import "BXCaptureBridge.h"
#import "BXLog.h"

extern "C" void BXRegisterBuiltinModules(void);
extern "C" void BXStartMainThreadSampler(void);

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


#pragma mark - 启动

__attribute__((constructor))
static void BXFloatVCamInit(void) {
    @autoreleasepool {
        BXLogWrite(@"[BXFloat][vcam] init bundle=%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");

        // 【极简版 B55】只装采集钩子，其余一律不做：
        //   不建面板、不挂浮窗、不注册模块、不启动任何定时器、不监听通知、不读本地视频。
        // 目的：判定"连点三次录制 / 退出再进卡死"是否由我们额外的 UI 与后台逻辑引起。
        // 连流：靠"会话首个生效时自动开流"（rtsp_url 已保存在配置里）。
        @try {
            [[BXCaptureBridge shared] install];
        } @catch (NSException *e) {
            BXLogWrite(@"[BXFloat][vcam] install 异常: %@", e);
        }

        // 极简版没有面板，开关无法手动打开：这里强制启用替换，并打开自动开流。
        // 强制启用替换 + 打开自动开流
        [BXCaptureBridge shared].enabled = YES;
        [[BXFloatStore shared] setObject:@(1) forKey:@"rtsp.enabled"];

        // 恢复悬浮球/面板挂载（极简版把这段也删了，导致看不到 UI）。
        // 只做挂载本身：不注册模块、不恢复本地视频、不起其它定时器。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[BXFloatWindow shared] attach];
        });
        BXStartMainThreadSampler();   // 主线程卡死采样（写到 /tmp/bxstall.txt）

        // 【心跳】每 2 秒记录一次各子系统状态，用于冻结后定位"谁先停"。
        // 关键点：主线程是否还能响应（后台线程 dispatch_async 到主线程，2 秒没执行就算 STALL）。
        static dispatch_source_t hb;   // 必须静态持有：局部变量会被 ARC 释放，定时器就不跑了
        hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(hb, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                  (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(hb, ^{
            static volatile int mainOK = 1;
            mainOK = 0;
            dispatch_async(dispatch_get_main_queue(), ^{ mainOK = 1; });
            usleep(300 * 1000);   // 给主线程 300ms 回应时间
            BXCaptureBridge *b = [BXCaptureBridge shared];
            NSTimeInterval age = 0;
            NSTimeInterval tick = [b lastVideoTick];
            if (tick > 0) age = CACurrentMediaTime() - tick;
            UIApplicationState st = [UIApplication sharedApplication].applicationState;
            BXLog(@"[HB] main=%@ app=%@ run=%@ dec=%lu age=%.1fs audio=%lu underrun=%lu",
                  mainOK ? @"OK" : @"STALL",
                  st == UIApplicationStateActive ? @"active" : (st == UIApplicationStateInactive ? @"inactive" : @"bg"),
                  b.isStreaming ? @"1" : @"0",
                  (unsigned long)b.decodedFrames,
                  age,
                  (unsigned long)b.audioReplaced,
                  (unsigned long)[b audioUnderruns]);
        });
        dispatch_resume(hb);
    }
}

