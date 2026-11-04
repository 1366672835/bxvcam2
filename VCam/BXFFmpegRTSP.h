//
//  BXFFmpegRTSP.h —— RTSP 直连（FFmpeg），输出 CVPixelBuffer
//
//  与 BXVideoSource 接口对齐，采集桥可直接替换。
//  低延迟配置：TCP 传输 + nobuffer + 队列长度为 0，实测 200~600ms。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>   // CMTime（按 PTS 取帧要用）
#import <CoreGraphics/CoreGraphics.h>

@interface BXFFmpegRTSP : NSObject

/// 打开 rtsp:// 地址并在后台线程持续解码
- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error;

- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSString *urlString;
@property (nonatomic, readonly) CGSize size;

/// 统计
@property (atomic, readonly) NSString *lastReason;   // 上次取帧失败的原因
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (nonatomic, readonly) NSUInteger droppedFrames;

/// 按摄像头的实际像素格式重建解码输出（420f / 420v 差异会影响色阶）
- (void)prepareForCameraFormat:(OSType)fmt width:(size_t)w height:(size_t)h;

/// 画质：0 原画 / 1 720p / 2 540p（先降到该档再放大到摄像头尺寸）

/// 目标像素格式：设成摄像头的格式后，缩放会直接渲染成该格式，不再二次转换
@property (nonatomic, assign) OSType targetFormat;

/// 画面选项
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 诊断：解码入队帧率 / 单帧处理耗时 / 是否硬解
- (NSUInteger)decodeFPS;
- (NSUInteger)readFPS;
- (NSUInteger)slotFillFPS;
/// 每帧 av_read_frame 的平均阻塞毫秒（≈帧间隔说明卡在网络）
- (NSUInteger)readBlockMs;
/// 每帧 VT 解码的平均毫秒
- (NSUInteger)decodeBlockMs;
/// 超过 3 秒没有新帧
- (NSUInteger)gapStalls;
- (NSUInteger)gapMaxWindow;
- (NSUInteger)loopCostMs;
/// 原版开流 block 携带的 loop 参数：EOF 时是否回到开头
@property (nonatomic, assign) BOOL loopPlayback;
- (NSUInteger)seekCount;        // 断流后 seek 恢复的次数
- (NSUInteger)reconnectCount;   // 重连次数
- (NSUInteger)eagainCount;      // EAGAIN 次数
- (NSUInteger)readErrCount;
// 循环拆解（每秒毫秒数，四项之和 ≈ 循环总量）
- (NSUInteger)readMsSec;
- (NSUInteger)feedMsSec;    // 写槽（含 VT 同步解码）
- (NSUInteger)audioMsSec;   // 音频解码 + 重采样
- (NSUInteger)otherMsSec;   // 其它（未归因）     // 其它读包错误次数   // 每包循环体总耗时   // 每秒「间隔 >200ms」的停顿次数
- (BOOL)audioTrackFound;
- (BOOL)audioDecoderReady;
- (double)streamDeclaredFPS;
- (NSString *)audioCodecName;
- (NSUInteger)vtErrorCount;
- (NSUInteger)audioDecodedFrames;
/// 音频欠载：环形缓冲不够填满这一帧的次数 / 累计缺口帧数
/// 采集恢复后清掉时间映射（避免延迟指标算出天文数字）
- (void)resetTimeline;
- (NSUInteger)audioUnderruns;
- (NSUInteger)audioUnderrunFrames;
- (NSUInteger)readStalls;
- (double)gapAvgMs;
- (double)gapMaxMs;
- (double)vtDecodeMs;
- (NSString *)decodeMode;
- (NSString *)decodeBackend;   // FFmpeg-VT / 自建VT / 软解
- (double)probeReadFPS;
- (NSString *)diagnosis;
/// 端到端延迟（毫秒）：摄像头当前帧时间 − 我们这帧的时间
- (NSString *)transport;
/// YES 时用 UDP 拉流（TCP 被限速时可切换）
@property (atomic, assign) BOOL preferUDP;
- (double)lastTransformMs;
- (double)swsMsTotal;
- (double)vtMsTotal;
- (BOOL)hardwareDecoding;

/// 有没有音频轨
- (BOOL)hasAudio;

/// 按摄像头的实际参数配置重采样目标（百相的做法：先读 ASBD 再对齐）
- (void)configureAudioSampleRate:(double)rate channels:(int)channels;
/// 当前重采样输出的声道数
- (int)audioChannels;

/// 取最新音频（S16 交错，48kHz，双声道）。返回写入的帧数，0 表示暂时没有。
- (NSUInteger)copyAudioFloat:(float *)dst maxFrames:(NSUInteger)maxFrames;
- (NSUInteger)copyAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames;

/// 按摄像头 PTS 取最匹配的一帧（音画同步用）。cameraPTS 传 kCMTimeInvalid 等价于取最新帧。
- (CVPixelBufferRef)copyPreviewFrameBGRA CF_RETURNS_RETAINED;
- (BOOL)renderLatestInto:(CVPixelBufferRef)dst;
- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS
                             scaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

/// 取最新一帧（已应用镜像/旋转/缩放）。调用方 CFRelease。
- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
