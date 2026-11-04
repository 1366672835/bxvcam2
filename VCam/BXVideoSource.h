//
//  BXVideoSource.h —— 本地视频 → 逐帧 CVPixelBuffer
//
//  用 AVAssetReader 把 mp4/mov 解码成 BGRA 像素缓冲，供采集桥替换摄像头帧。
//  支持: 循环、镜像、旋转 90/180/270、缩放到目标尺寸。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@interface BXVideoSource : NSObject

/// 加载视频文件。失败返回 NO。
- (BOOL)loadURL:(NSURL *)url error:(NSError **)error;

/// 卸载
- (void)unload;

@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, readonly) CGSize size;
@property (nonatomic, readonly) CGFloat duration;
@property (nonatomic, readonly) NSString *path;

/// 播放控制
@property (nonatomic, assign) BOOL loop;          // 循环，默认 YES
@property (nonatomic, assign) BOOL mirror;        // 水平镜像
@property (nonatomic, assign) NSInteger rotation; // 0/90/180/270

/// 回到第一帧
- (void)rewind;

/// 取下一帧（已应用镜像/旋转/缩放）。调用方负责 CFRelease。
/// targetSize 传 CGSizeZero 表示不缩放，用视频原始分辨率。
/// 让解码输出直接对齐摄像头格式（420f/420v），省掉一次 BGRA 转换
/// 采集被打断恢复后重新对时（PTS 会跳变）
- (void)resetTimeline;
- (void)prepareForCameraFormat:(OSType)fmt width:(size_t)w height:(size_t)h;

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;
/// 按摄像头这一帧的 PTS 选帧（和 RTSP 路径统一基准）
- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS scaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

/// 当前帧（不前进），用于暂停/冻结
- (CVPixelBufferRef)copyCurrentFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
