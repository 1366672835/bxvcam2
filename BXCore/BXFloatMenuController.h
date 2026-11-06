//
//  BXFloatMenuController.h
//

#import <UIKit/UIKit.h>

@interface BXFloatMenuController : UIViewController

/// 重建行数据（模块可能被运行时增删）
- (void)reload;

/// 点面板右上角 ✕ 时回调（窗口用来收起面板）
@property (nonatomic, copy) void (^onRequestClose)(void);

@end
