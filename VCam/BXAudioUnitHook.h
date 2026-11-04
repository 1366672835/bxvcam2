#import <Foundation/Foundation.h>

/// 安装 AudioUnit 输入总线钩子（把麦克风 PCM 换成 RTSP 流音频）。
/// 与原版 0x3336e8 的 "audio unit hook installed" 同路。
/// Tweak.xm 是 Objective-C++，必须用 extern "C" 关闭名字修饰，
/// 否则链接器找不到纯 C 编译出来的 _BXAudioUnitHookInstall。
#ifdef __cplusplus
extern "C" {
#endif

void BXAudioUnitHookInstall(void);

#ifdef __cplusplus
}
#endif
