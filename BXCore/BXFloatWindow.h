//
//  BXFloatWindow.h —— 悬浮层 window + 悬浮球 + 展开面板
//
//  关键点(对齐原版行为):
//    1. UIWindow 层级高于游戏内容, 但 hitTest 只在自己可见的子视图上应答
//       —— 否则整个游戏都点不动。
//    2. 悬浮球可拖拽, 松手后吸附左右边缘, 位置持久化。
//    3. 单击展开/收起菜单面板。
//    4. 面板内部滚动, 不超出安全区。
//

#import <UIKit/UIKit.h>

@class BXFloatMenuController;

@interface BXFloatWindow : UIWindow

+ (instancetype)shared;

/// 在当前 keyWindow 所在 scene 上挂载
- (void)attach;
- (void)detach;

@property (nonatomic, strong, readonly) UIButton *bubble;
@property (nonatomic, strong, readonly) BXFloatMenuController *menu;

/// 有系统弹窗/选择器时置 YES：否则它们落在面板区域外会被 hitTest 穿透，表现为“点了没反应”
@property (nonatomic, assign) BOOL allowAllTouches;

/// 是否允许悬浮层接收触摸(展开时 YES，收起时只有球体区域 YES)
- (BOOL)shouldReceiveTouch;

@end
