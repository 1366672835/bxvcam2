//
//  BXPreviewWindow.h —— 独立预览悬浮窗（对齐百相「预览」）
//
//  不依赖摄像头是否已创建采集，自己拉一路流解码显示，
//  用来在进拍摄页之前先确认「地址对不对、流通不通」。
//

#import <UIKit/UIKit.h>

@interface BXPreviewWindow : UIWindow

+ (instancetype)shared;

/// 用指定地址开预览（rtsp:// 走 FFmpeg，http 走 AVPlayer）
- (void)showWithURL:(NSString *)url;

/// 关闭预览并断开连接
- (void)hidePreview;

@property (nonatomic, readonly, getter=isPreviewing) BOOL previewing;

@end
