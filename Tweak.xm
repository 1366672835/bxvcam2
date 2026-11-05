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


#pragma mark - 启动

__attribute__((constructor))
static void BXFloatVCamInit(void) {
    @autoreleasepool {
        NSLog(@"[BXFloat][vcam] init bundle=%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");

        // 【极简版 B55】只装采集钩子，其余一律不做：
        //   不建面板、不挂浮窗、不注册模块、不启动任何定时器、不监听通知、不读本地视频。
        // 目的：判定"连点三次录制 / 退出再进卡死"是否由我们额外的 UI 与后台逻辑引起。
        // 连流：靠"会话首个生效时自动开流"（rtsp_url 已保存在配置里）。
        @try {
            [[BXCaptureBridge shared] install];
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] install 异常: %@", e);
        }
    }
}

