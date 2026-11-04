//
//  BXVolumeShortcut.h —— 音量键快捷开关（双击音量+ 打开/关闭面板）
//
//  原版里对应 BXVolumeShortcutObserver 这类东西。这里用两套实现：
//    1) 私有 AVSystemController 通知（iOS 14-17，越狱环境稳定）
//    2) 降级：hook UIApplication 的 sendEvent: 观察 MPVolumeView 的滑动
//

#import <Foundation/Foundation.h>

typedef void (^BXVolumeShortcutHandler)(BOOL isVolumeUp, NSInteger tapCount);

@interface BXVolumeShortcut : NSObject

+ (instancetype)shared;

/// 开始监听。tapCount=2 表示连续两次音量+/-触发
- (void)startWithHandler:(BXVolumeShortcutHandler)handler;

- (void)stop;

@property (nonatomic, assign) NSTimeInterval maxGap;   // 连击窗口，默认 0.45s

@end
