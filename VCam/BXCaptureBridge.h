//
//  BXCaptureBridge.h —— 虚拟摄像头核心
//
//  原理:
//    App 创建 AVCaptureVideoDataOutput 后会调 setSampleBufferDelegate:queue:
//    我们把这个方法换掉: 保存 App 原来的 delegate, 改成注册自己。
//    等 App 的代理回调被调用时, 我们把摄像头帧换成视频帧, 再转发给 App 的 delegate。
//
//  安全性:
//    - 未开启虚拟摄像头时 100% 直通, 不影响任何行为
//    - 视频未加载时 100% 直通
//    - getter 也换成返回 App 原来的 delegate, 防止 App 自查
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface BXCaptureBridge : NSObject

+ (instancetype)shared;

/// 是否启用虚拟摄像头（未启用时完全直通）
@property (atomic, assign) BOOL enabled;

/// 画质：0 原画（直接按摄像头尺寸输出） / 1 720p / 2 540p

/// 音频替换：YES = 用流里的声音（视频原声），NO = 保留麦克风
@property (atomic, assign) BOOL audioReplace;

/// 画面选项（转发到底层视频源）
@property (atomic, assign) BOOL loop;
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 当前视频源
@property (nonatomic, readonly) NSString *sourcePath;

/// 换成 RTSP 直连（内置 FFmpeg）。优先级最高。
- (BOOL)useRTSPURLString:(NSString *)urlString error:(NSError **)error;
- (void)rebuildSnapshot;

@property (nonatomic, readonly) NSString *rtspURL;

/// 进入造帧的次数（排查用）
@property (nonatomic, readonly) NSUInteger attemptFrames;
@property (nonatomic, readonly) NSUInteger audioReplaced;

/// 解码统计（排查用）
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (atomic, readonly) NSString *streamFrameReason;
@property (atomic, readonly) NSString *gateReason;
@property (atomic, readonly) NSString *buildError;

/// 取当前 RTSP/HLS 帧（给预览窗复用，避免开第二路连接）
- (NSUInteger)pullAudioFloat:(float *)dst maxFrames:(NSUInteger)maxFrames;
- (CVPixelBufferRef)copyPreviewFrameBGRA CF_RETURNS_RETAINED;
- (CVPixelBufferRef)copyLatestStreamFrame CF_RETURNS_RETAINED;

/// 诊断：解码入队帧率 / 单帧处理耗时 / 是否硬解 / 替换帧率
- (NSUInteger)decodeFPS;
- (NSUInteger)readFPS;
- (NSUInteger)slotFillFPS;
@property (nonatomic, readonly) NSUInteger readBlockMs;
@property (nonatomic, readonly) NSUInteger gapStalls;
@property (nonatomic, readonly) NSUInteger gapMaxWindow;
/// 异步解码（与原版一致）：读包循环不等解码
@property (nonatomic, readonly) NSString *decodeBackend;
/// 让摄像头按源帧率出帧（消除 24 铺 30 的抖动）
@property (nonatomic, readonly) NSUInteger loopCostMs;
@property (nonatomic, readonly) NSUInteger seekCount;
@property (nonatomic, readonly) NSUInteger reconnectCount;
@property (nonatomic, readonly) NSUInteger eagainCount;
@property (nonatomic, readonly) NSUInteger readErrCount;
@property (nonatomic, readonly) NSUInteger readMsSec;
@property (nonatomic, readonly) NSUInteger feedMsSec;
@property (nonatomic, readonly) NSUInteger audioMsSec;
@property (nonatomic, readonly) NSUInteger otherMsSec;

/// AudioUnit 层取 PCM（S16 交错）。返回实际帧数，0 表示没有可用源。
- (NSUInteger)copyReplacementAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames;
@property (nonatomic, readonly) NSUInteger decodeBlockMs;

/// 面板只读这个：每秒重建一次的不可变副本，避免跨线程读活对象
@property (nonatomic, strong, readonly) NSDictionary *snapshot;
- (NSUInteger)audioCallbacksCount;
- (NSUInteger)audioBlitOKCount;
- (NSString *)audioFailReason;
- (NSUInteger)audioDecodedFrames;
- (NSUInteger)audioUnderruns;
- (NSUInteger)audioUnderrunFrames;
- (NSUInteger)readStalls;
- (double)gapAvgMs;
- (double)gapMaxMs;
- (double)vtDecodeMs;
- (NSString *)decodeMode;
- (double)probeReadFPS;
- (NSString *)diagnosis;
- (NSString *)transport;
@property (atomic, assign) BOOL preferUDP;
@property (nonatomic, readonly) NSString *seenOutputsText;
@property (nonatomic, readonly) NSString *sessionOutputsText;
- (NSUInteger)passBlitFail;
- (NSUInteger)passNoFrame;
- (NSUInteger)passGate;
- (BOOL)audioTrackFound;
- (BOOL)audioDecoderReady;
- (double)streamDeclaredFPS;
- (NSString *)audioCodecName;
- (NSUInteger)vtErrorCount;
- (double)lastTransformMs;
- (BOOL)hardwareDecoding;
@property (atomic, readonly) NSUInteger replaceFPS;
@property (atomic, readonly) double latencyMs;

/// 当前是否带独立音轨（本地视频或 RTSP）
@property (nonatomic, readonly) BOOL hasOwnAudio;

/// 停止 RTSP / 网络流（本地视频不受影响）
- (void)stopNetworkSources;

/// 换成网络流（HLS / HTTP MP4）。走这条路时本地视频源不生效。
- (BOOL)useStreamURLString:(NSString *)urlString error:(NSError **)error;

@property (atomic, readonly) NSString *streamURL;

/// 换成另一个视频文件
- (BOOL)useVideoAtPath:(NSString *)path error:(NSError **)error;

/// 装载 hook。constructor 里调一次即可。
- (void)install;

/// 状态
@property (nonatomic, readonly) BOOL installed;
@property (nonatomic, readonly) NSUInteger replacedFrames;
@property (nonatomic, readonly) NSUInteger passthroughFrames;

/// 有多少个采集输出被我们接管了 delegate（0 = App 还没开摄像头）
// 探针计数：三个入口被调用的次数（供诊断页显示）
@property (nonatomic, assign) NSUInteger setterVideoCalls;
@property (nonatomic, assign) NSUInteger setterAudioCalls;
@property (nonatomic, assign) NSUInteger delegateHooked;
@property (nonatomic, readonly) NSUInteger capturedOutputs;
@property (nonatomic, readonly) NSUInteger hookedCount;

@end
