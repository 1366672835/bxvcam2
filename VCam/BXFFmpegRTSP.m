//      av_read_frame → 视频包送 VideoToolbox → 音频包解码+重采样 → 循环
//
//  断流（0x33191c）：av_seek_frame 回起点 + flush + 清音频缓冲（不重连）
//  音频：48kHz / float32 / 限幅 / 384000 帧环形缓冲（0x331cf0~0x331e34）
//  视频：只保留最新帧，无队列
//

#import "BXFFmpegRTSP.h"
#import "BXConfig.h"
#import "BXColorSpace.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>   // os_unfair_lock（原版 0x4a80e0 的转换锁）

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/rational.h>
#include <libavutil/time.h>   // av_gettime_relative
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <arpa/inet.h>
#include <unistd.h>

static NSString *BXFFErr(int code) {
    char buf[256] = {0};
    av_strerror(code, buf, sizeof(buf));
    return [NSString stringWithFormat:@"%s(%d)", buf, code];
}

@interface BXFFmpegRTSP () {
    AVFormatContext *_fmt;
    AVCodecContext  *_dec;
    struct SwsContext *_sws;
    int             _streamIndex;
    int             _srcW, _srcH;
    enum AVPixelFormat _srcFmt;
    int             _srcW2, _srcH2;      // sws 输出尺寸（当前 = 源尺寸）
    int             _dstPix;             // sws 目标像素格式（原版 0x1c）
    BOOL            _usingSWDecode;      // 走的是软件解码
    BOOL            _usingFFmpegVT;      // 走的是 FFmpeg 的 videotoolbox 解码

    CVPixelBufferRef _latest;      // 已变换、可直接上屏
    CVPixelBufferRef _rawSlot;     // VT 刚解出来的原始帧
    CVPixelBufferRef _lastServed;   // 上一次交给采集端的帧（槽空时复用）
    BOOL            _swrDirty;          // 采样率/声道变了，等解码线程重建
    NSRecursiveLock *_swrLock;      // swr 专用锁（解码线程与采集线程都会碰）
    // PTS → 宿主时钟映射（原版按媒体时间播放，我们之前用的是到达时间）
    double _swsMsAcc, _vtMsAcc;
    double _lastVideoPublishHost;   // 上一帧交付时刻（节流用，照抄原版 0x337adc）
    // 画面「换帧间隔」统计：判断播放节奏是否均匀
    double _lastSlotHost;           // 最后一次写槽的主机时间（判死流用）
    CGSize _wantSize;   // 采集侧期望尺寸（消费者写入，变换队列读取）
    NSUInteger _slotFill, _slotFillFPS;
    NSTimeInterval _slotFillMark;
    NSLock          *_lock;
    dispatch_queue_t _decodeQueue;
    BOOL            _stopRequested;
    BOOL            _loopActive;
    CIContext       *_ci;
    CVPixelBufferPoolRef _pool;
    CVPixelBufferPoolRef _srcPool;   // 软解输出的池
    CGSize _srcPoolSize;
    CGSize          _poolSize;
    uint8_t         *_bgra;
    size_t          _bgraSize;
    // 这些字符串会被后台线程写、主线程读，必须 atomic
    
    uint64_t        _generation;

    VTDecompressionSessionRef _vtSession;
    CMVideoFormatDescriptionRef _vtFmt;
    uint8_t         _sps[512];
    size_t          _spsLen;
    uint8_t         _pps[512];
    size_t          _ppsLen;
    NSUInteger      _vtErrors;
    double          _vtDecodeMs;
    OSType          _camFmt;
    size_t          _camW, _camH;

    int             _aStreamIndex;
    AVCodecContext *_aDec;
    struct SwrContext *_swr;
    float          *_aRing;
    size_t          _aRingFrames;
    size_t          _aFillFrames;
    uint64_t        _aWriteIdx;          // 环形缓冲绝对写位置（原版 0x4a8300）
    uint64_t        _aReadIdx;           // 消费者绝对读位置（原版 16 段读指针表，我们单消费者单段）
    uint64_t        _aDropped;           // 因落后被跳过的帧
    uint64_t        _audioPaceWaits;     // 原版 audio pace waits
    uint64_t        _audioPaceUs;        // 原版 audio pace wait_us
    float          *_aTmp;
    size_t          _aTmpCap;
    int             _aOutRate;
    int             _aOutCh;
    BOOL            _audioTrackFound;
    BOOL            _audioDecoderOK;
    NSUInteger      _audioDecoded;
    NSUInteger      _audioUnderruns;        // 缓冲不够填满一帧的次数
    NSUInteger      _audioUnderrunFrames;   // 累计缺多少帧
    

    double          _streamFPS;
    NSUInteger      _fpsPkt, _pktCount;
    NSTimeInterval  _pktMark;
    NSUInteger      _fpsEnq, _fpsCount;
    NSTimeInterval  _fpsMark;
    NSUInteger      _readStalls;
    NSUInteger      _seekCount, _reconnectCount, _eagainCount, _errCount;
    int             _eagainStreak;      // 连续 EAGAIN 次数（退避用）
    int             _errLogged;
    double          _readMsAcc, _decMsAcc, _loopMsAcc;   // 每秒累计耗时
    double          _feedMsAcc, _audMsAcc;               // 写槽 / 音频
    NSUInteger      _readMsSec, _feedMsSec, _audMsSec, _otherMsSec;
    CFTimeInterval  _iterStart;              // 上一轮循环起点
    NSUInteger      _loopMsWin;
    NSUInteger      _readMsWin, _decMsWin;   // 每秒平均值（毫秒）
    NSUInteger      _pktWin;                 // 每秒包数（与 fps 同窗口）
    NSUInteger      _gapStalls, _gapStallsWin;   // 单次间隔 >200ms 的次数
    double          _gapAvgMs, _gapMaxMs;   // 视频包到达间隔
    double          _gapSumMs;              // 窗口内累计间隔
    NSUInteger      _gapCount;              // 窗口内样本数
    NSUInteger      _gapMaxWin;             // 上一窗口最大间隔（面板读这个）
    NSTimeInterval  _lastPktTime;
    
    CMTime          _latestPTS;    int64_t _deadlineUs;
    // 抖动缓冲：解码出的帧先排队，按「PTS + 缓冲量」的节奏放出去。
    // 手机侧实测网络抖动 max 350ms，不缓冲就无法均匀（VLC 默认缓冲 1s 才顺）。
    CVPixelBufferRef _qBuf[6];
    double _pushPts;            // 待入队帧的流时间戳(秒)
    double _qPts[16];
    int _qHead, _qCount, _qDrops;
    int _qStarted;
    double _qBasePts;
    int64_t _qBaseHost;
    AVRational _streamTB;
    AVRational _aStreamTB;           // 音频流时间基（音频节流用）            // 视频流时间基（算包时长用）
}


- (int64_t)deadlineUs;
- (void)armDeadlineUs:(int64_t)us;
- (void)clearDeadline;
- (BOOL)interruptRequested;   // 供 C 中断回调读取取消标志
- (void)decodeLoop;
- (void)noteParameterSet:(const uint8_t *)p length:(size_t)len type:(int)type;
- (void)feedHardware:(AVPacket *)pkt;
- (BOOL)tryBuildFormatFromPacket:(AVPacket *)pkt;
- (void)publishHardwareFrame:(CVImageBufferRef)buffer;
- (void)enqueueFrame:(CVImageBufferRef)buffer pts:(CMTime)pts;
- (void)publishFrame:(AVFrame *)frame;
- (void)setupVideoToolboxForParameters:(AVCodecParameters *)par;
- (void)recreateVTSession;
- (BOOL)rebuildSwr;
- (void)appendAudioFrame:(AVFrame *)af;
- (void)paceAudioProducerFill:(size_t)fill ch:(int)ch;
- (CVPixelBufferRef)scaleOnce:(CVPixelBufferRef)src toSize:(CGSize)size CF_RETURNS_RETAINED;
- (CVPixelBufferRef)transformBuffer:(CVPixelBufferRef)src toSize:(CGSize)targetSize CF_RETURNS_RETAINED;
- (BOOL)transferFrom:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst dedicated:(BOOL)dedicated;
- (BOOL)transferFrom:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst;
- (CVPixelBufferPoolRef)poolForSize:(CGSize)size format:(OSType)fmt;
- (CVPixelBufferPoolRef)srcPoolForSize:(CGSize)size format:(OSType)fmt;

@property (atomic, copy) NSString *lastReasonText;
@property (atomic, copy) NSString *codecNameText;
@property (atomic, copy) NSString *transportText;
@property (atomic, assign) BOOL running;
@property (atomic, copy)   NSString *urlString;
@property (atomic, assign) CGSize size;
@property (atomic, assign) NSUInteger decodedFrames;
@property (atomic, assign) NSUInteger droppedFrames;

@end

// 阻塞在 av_read_frame / avformat_open_input 时，只有中断回调能把它叫醒。
// 返回非 0 会让 FFmpeg 立刻放弃当前阻塞操作（AVERROR_EXIT）。
static int BXInterruptCB(void *opaque) {
    BXFFmpegRTSP *me = (__bridge BXFFmpegRTSP *)opaque;
    if (!me) return 0;
    if ([me interruptRequested]) return 1;                 // 显式停止
    int64_t dl = [me deadlineUs];
    if (dl > 0 && av_gettime_relative() > dl) return 1;    // 原版：6s 超时自动中断
    return 0;
}

// 用来判断 stop 是否正跑在解码队列上（是的话不能 dispatch_sync，否则死锁）
static void *kBXDecodeQueueKey = &kBXDecodeQueueKey;

// 按协议给参数：
//   rtsp:// → rtsp_transport / timeout / rw_timeout / buffer_size（照抄原版四个）
//   rtmp:// → 只用 rw_timeout + rtmp_live=live（RTSP 那套对 RTMP 没意义）
//   其它    → rw_timeout + timeout
static AVDictionary *BXBuildOpenOptions(NSString *url, BOOL preferUDP) {
    AVDictionary *opts = NULL;
    NSString *lower = url.lowercaseString;

    if ([lower hasPrefix:@"rtsp://"]) {
        av_dict_set(&opts, "rtsp_transport", preferUDP ? "udp" : "tcp", 0);
        av_dict_set(&opts, "timeout", "5000000", 0);
        av_dict_set(&opts, "rw_timeout", "5000000", 0);
        av_dict_set(&opts, "buffer_size", "1048576", 0);
    } else if ([lower hasPrefix:@"rtmp://"] || [lower hasPrefix:@"rtmps://"]) {
        av_dict_set(&opts, "rw_timeout", "5000000", 0);
        av_dict_set(&opts, "rtmp_live", "live", 0);     // 直播模式：少缓冲、跟实时
    } else {
        av_dict_set(&opts, "timeout", "5000000", 0);
        av_dict_set(&opts, "rw_timeout", "5000000", 0);
    }
    return opts;
}

// 时钟基准：原版用 av_gettime_relative + av_usleep 让整条解码循环按 PTS 走（没有音频 FIFO）。
// 我们在读包后按同一模型节流，音画就自然同步、画面卡住时声音也停。
static int64_t gPaceBaseUs = 0;

@implementation BXFFmpegRTSP {
    NSTimeInterval _bxSkipUntil;
    CVPixelBufferRef _camLast;          // 摄像头路径上一次成功写出的帧（源帧率低于摄像头时复用，避免直通闪烁）
    CVPixelBufferRef _slot;             // 单槽：最新解出的帧（对应原版 0x4a80d8）
    double            _slotPts;
    CVPixelBufferPoolRef _camPool;      // 样本替换专用池（与预览池分开，避免互相释放）
    CGSize            _camPoolSize;
    OSType            _camPoolFmt;
}

- (int64_t)deadlineUs { return _deadlineUs; }
- (void)armDeadlineUs:(int64_t)us { _deadlineUs = av_gettime_relative() + us; }
- (void)clearDeadline { _deadlineUs = 0; }


#pragma mark - VT 回调

static void bx_vt_output(void *refCon, void *frameRefCon, OSStatus status,
                         VTDecodeInfoFlags flags, CVImageBufferRef imageBuffer,
                         CMTime pts, CMTime duration) {
    if (status != noErr || imageBuffer == NULL) return;
    BXFFmpegRTSP *me = (__bridge BXFFmpegRTSP *)refCon;
    [me publishHardwareFrame:imageBuffer];
}

#pragma mark - 生命周期

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _preferUDP = NO;          // 默认 TCP：手机侧实测 UDP 丢包严重（读取 1fps）
        _decodeQueue = dispatch_queue_create("bx.rtsp.decode", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_decodeQueue, kBXDecodeQueueKey, (__bridge void *)self, NULL);
        _ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _streamIndex = -1;
        _lastVideoPublishHost = 0;
        // 原版：只用 avcodec_find_decoder（软件解码），无后端切换
        _aStreamIndex = -1;
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)hasAudio { return _aRing != NULL; }
- (int)audioChannels { return (_aOutCh > 0) ? _aOutCh : 2; }
- (NSString *)lastReason { return self.lastReasonText ?: @"-"; }
- (NSUInteger)decodeFPS { return _fpsEnq; }
- (NSUInteger)readFPS { return _fpsPkt; }
- (NSUInteger)slotFillFPS { return _slotFillFPS; }
- (NSUInteger)readBlockMs { return _readMsWin; }
- (NSUInteger)decodeBlockMs { return _decMsWin; }
- (NSUInteger)gapStalls { return _gapStallsWin; }
- (NSUInteger)gapMaxWindow { return _gapMaxWin; }
- (NSUInteger)loopCostMs { return _loopMsWin; }
- (NSUInteger)readMsSec { return _readMsSec; }
- (NSUInteger)feedMsSec { return _feedMsSec; }
- (NSUInteger)audioMsSec { return _audMsSec; }
- (NSUInteger)otherMsSec { return _otherMsSec; }
- (NSUInteger)seekCount { return _seekCount; }
- (NSUInteger)reconnectCount { return _reconnectCount; }
- (NSUInteger)eagainCount { return _eagainCount; }
- (NSUInteger)readErrCount { return _errCount; }
- (NSUInteger)vtErrorCount { return _vtErrors; }
- (double)vtDecodeMs { return _vtDecodeMs; }
- (NSString *)decodeBackend {
    // 以运行时真实状态为准：VT 会话存在才是硬解
    if (_vtSession) return @"硬解(VT)";
    if (_dec) return @"软解(原版)";
    return @"未开流";
}

- (NSString *)decodeMode { return (_usingSWDecode || (!_usingFFmpegVT && !_vtSession && _dec)) ? @"软解" : @"硬解"; }
- (NSString *)transport { return self.transportText ?: @"?"; }
- (double)streamDeclaredFPS { return _streamFPS; }
- (NSString *)audioCodecName { return self.codecNameText ?: @"?"; }
- (BOOL)audioTrackFound { return _audioTrackFound; }
- (BOOL)audioDecoderReady { return _audioDecoderOK; }
- (NSUInteger)audioDecodedFrames { return _audioDecoded; }
- (BOOL)interruptRequested { return _stopRequested; }

// 【照原版 0x330cb0】采集会话停止时：清音频环形缓冲索引 + 让写帧闸门关闭，
// 直到解码线程重新产出新帧。原版不关 RTSP 连接，只复位状态。
static NSTimeInterval gLastDecodeTick;   // 前置声明（定义在文件后部）

- (void)resetForSessionStop {
    // 【B85】只关视频写帧闸门，不清音频环：
    // 拍摄页里 stop/start 很频繁，每清一次环声音就断一拍（实测"一会有一会没"）。
    [_lock lock];
    _slotPts = 0;
    gLastDecodeTick = 0;
    size_t keep = _aFillFrames;
    [_lock unlock];
    BXLog(@"[BXRTSP] 会话停止：关写帧闸门（音频环保留 %zu 帧）", keep);
}
- (void)resetTimeline { [_lock lock]; _latestPTS = kCMTimeInvalid; [_lock unlock]; }
- (NSUInteger)audioUnderruns { return _audioUnderruns; }
- (NSUInteger)audioUnderrunFrames { return _audioUnderrunFrames; }
- (NSUInteger)readStalls { return _readStalls; }
- (double)gapAvgMs { return _gapAvgMs; }
- (double)gapMaxMs { return _gapMaxMs; }
- (double)probeReadFPS { return 0; }

- (NSString *)diagnosis {
    if (_streamFPS > 1 && (double)_fpsPkt < _streamFPS * 0.7) {
        return [NSString stringWithFormat:@"网络不足：只收到 %.0f / 声明 %.0f fps（建议把推流降到 30fps 或换 5GHz/有线）",
                (double)_fpsPkt, _streamFPS];
    }
    if (_streamFPS > 1 && (double)_fpsPkt < _streamFPS * 0.85) {
        return [NSString stringWithFormat:@"读取 %.0f 低于声明 %.0f", (double)_fpsPkt, _streamFPS];
    }
    return [NSString stringWithFormat:@"正常（读取 %.0f / 声明 %.0f）", (double)_fpsPkt, _streamFPS];
}

#pragma mark - 启动

- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error {
    [self stop];
    for (int i = 0; i < 120 && _loopActive; i++) usleep(50 * 1000);
    _generation++;

    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"地址为空"}];
        return NO;
    }

    avformat_network_init();
    // 必须在 open 之前清掉：中断回调读的就是它，
    // 如果等到 open 成功后才清，open 一开始就会被判定为「已取消」而立刻返回。
    _stopRequested = NO;
    _vtErrors = 0; _readStalls = 0; _audioDecoded = 0;
    _seekCount = 0; _reconnectCount = 0; _eagainCount = 0; _errCount = 0; _errLogged = 0;
    _audioUnderruns = 0; _audioUnderrunFrames = 0;
    _pktCount = 0; _fpsPkt = 0; _fpsCount = 0; _fpsEnq = 0;
    _pktMark = 0; _fpsMark = 0;

    NSString *tp = self.preferUDP ? @"udp" : @"tcp";
    AVDictionary *opts = BXBuildOpenOptions(urlString, self.preferUDP);

    // 自己分配 context，先装中断回调：对端不回 SDP 时 open 会一直阻塞，
    // 只有 interrupt_callback 能在 stop 时把它叫醒。
    _fmt = avformat_alloc_context();
    if (!_fmt) {
        av_dict_free(&opts);
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: @"分配 context 失败"}];
        return NO;
    }
    _fmt->interrupt_callback.callback = BXInterruptCB;
    _fmt->interrupt_callback.opaque = (__bridge void *)self;

    [self armDeadlineUs:6000000];   // 原版 0x5b8d80 = 6s
    int ret = avformat_open_input(&_fmt, urlString.UTF8String, NULL, &opts);
    av_dict_free(&opts);
    self.transportText = [urlString.lowercaseString hasPrefix:@"rtmp"] ? @"rtmp" : tp;
    if (ret < 0 || !_fmt) {
        // AVERROR_EXIT(-1414092869) 表示中断回调被触发（我们主动打断），
        // ETIMEDOUT / ECONNREFUSED 才是网络或地址问题。
        BXLog(@"[BXRTSP] open 失败 ret=%d (%s) url=%@", ret, av_err2str(ret), urlString);
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"打开流失败 %@", BXFFErr(ret)]}];
        return NO;
    }

    [self armDeadlineUs:6000000];   // 原版：find_stream_info 前也设 6s
    ret = avformat_find_stream_info(_fmt, NULL);
    if (ret < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"读取流信息失败 %@", BXFFErr(ret)]}];
        [self stop];
        return NO;
    }

    _streamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_streamIndex < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:_streamIndex
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有视频流"}];
        [self stop];
        return NO;
    }

    {
        AVStream *vs = _fmt->streams[_streamIndex];
        _srcW = vs->codecpar->width;
        _srcH = vs->codecpar->height;
        // 声明帧率：mediamtx 的 avg_frame_rate 常是 90000/1 这种时间基垃圾值。
        // 优先 r_frame_rate，>240 一律当无效；再退 av_guess_frame_rate；仍无效置 0。
        // 原版 0x33216c 用的是 av_guess_frame_rate 的结果，我们也以它为准，
        // 取不到再退 r_frame_rate（>240 视为时间基垃圾值，丢弃）。
        AVRational g = av_guess_frame_rate(_fmt, vs, NULL);
        double fps = (g.den > 0 && g.num > 0) ? (double)g.num / (double)g.den : 0;
        if (fps <= 0 || fps > 240) {
            AVRational cand = vs->r_frame_rate;
            fps = (cand.den > 0 && cand.num > 0) ? (double)cand.num / (double)cand.den : 0;
        }
        if (fps > 240) fps = 0;
        _streamFPS = fps;
        _streamTB = vs->time_base;

        // 原版路线：直接用 FFmpeg 的 h264_videotoolbox 解码器。
        // 反汇编证据：VTDecompressionSessionDecodeFrame 只被 0x241f90 调用，
        // 那是 FFmpeg 的 vtdec，不在百相自己的代码区 —— 说明它没有自建 VT 会话。
        // 好处：SPS/PPS、重排、异步线程都由 FFmpeg 管，读包循环不被解码阻塞。
        // 原版用的是 avcodec_find_decoder（0x332c5c）—— 即该 codec 的默认解码器，
        // 不是 h264_videotoolbox，也没有任何 hwaccel 相关调用。
        // 完整 API 清单（0x33xxxx 区内）里只有：
        //   avcodec_find_decoder / alloc_context3 / parameters_to_context / open2
        //   send_packet / receive_frame / flush_buffers
        //   sws_getContext / sws_scale（缩放）、swr_*（音频）
        // 所以这里也先走软件解码，保持同一路线。
        const AVCodec *swdec = avcodec_find_decoder(vs->codecpar->codec_id);
        if (swdec) {
            _dec = avcodec_alloc_context3(swdec);
            if (_dec) {
                avcodec_parameters_to_context(_dec, vs->codecpar);
                if (avcodec_open2(_dec, swdec, NULL) == 0) {
                    _usingSWDecode = YES;
                    BXLog(@"[BXRTSP] 解码器：%s（软件，与百相同一路线）", swdec->name);
                } else {
                    avcodec_free_context(&_dec);
                }
            }
        }

        if (NO) {
            const AVCodec *vtdec = avcodec_find_decoder_by_name("h264_videotoolbox");
            if (vtdec) {
                _dec = avcodec_alloc_context3(vtdec);
                if (_dec) {
                    avcodec_parameters_to_context(_dec, vs->codecpar);
                    _dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
                    if (avcodec_open2(_dec, vtdec, NULL) == 0) {
                        _usingFFmpegVT = YES;
                        BXLog(@"[BXRTSP] 解码器：h264_videotoolbox（与百相同一路线）");
                    } else {
                        avcodec_free_context(&_dec);
                    }
                }
            }
            if (!_usingFFmpegVT) {
                [self setupVideoToolboxForParameters:vs->codecpar];   // 兜底：自建会话
            }
        }
        if (NO) {
            // 指定 FFmpeg-VT 但拿不到：退回软解，别让用户没画面
            const AVCodec *fb = avcodec_find_decoder(vs->codecpar->codec_id);
            if (fb) {
                _dec = avcodec_alloc_context3(fb);
                avcodec_parameters_to_context(_dec, vs->codecpar);
                if (avcodec_open2(_dec, fb, NULL) == 0) {
                    _usingSWDecode = YES;
                    BXLog(@"[BXRTSP] 指定 VT 不可用，退回软解");
                } else {
                    avcodec_free_context(&_dec);
                }
            }
        }
        if (!_vtSession && !_dec) {
            const AVCodec *codec = avcodec_find_decoder(vs->codecpar->codec_id);
            if (!codec) {
                if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"没有可用解码器"}];
                [self stop];
                return NO;
            }
            _dec = avcodec_alloc_context3(codec);
            avcodec_parameters_to_context(_dec, vs->codecpar);
            _dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
            if (avcodec_open2(_dec, codec, NULL) < 0) {
                if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"解码器初始化失败"}];
                [self stop];
                return NO;
            }
        }
    }

    _aStreamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (_aStreamIndex >= 0 && _aStreamIndex < (int)_fmt->nb_streams) {
        _aStreamTB = _fmt->streams[_aStreamIndex]->time_base;
    }
    _audioTrackFound = (_aStreamIndex >= 0);
    if (_aStreamIndex >= 0) {
        AVStream *ast = _fmt->streams[_aStreamIndex];
        self.codecNameText = [NSString stringWithUTF8String:avcodec_get_name(ast->codecpar->codec_id)];
        const AVCodec *acodec = avcodec_find_decoder(ast->codecpar->codec_id);
        if (acodec) {
            _aDec = avcodec_alloc_context3(acodec);
            avcodec_parameters_to_context(_aDec, ast->codecpar);
            if (avcodec_open2(_aDec, acodec, NULL) >= 0) {
                _audioDecoderOK = YES;
                _aOutRate = 48000;
                _aOutCh = 2;
                _aRingFrames = 384000;              // 照抄：约 8 秒 @48k
                _aRing = (float *)calloc(_aRingFrames * 2, sizeof(float));
    _aFillFrames = 0; _aWriteIdx = 0; _aReadIdx = 0; _aDropped = 0;
                [self rebuildSwr];
            }
        }
    }

    self.urlString = urlString;
    self.running = YES;
    _stopRequested = NO;
    _loopActive = YES;
    self.size = CGSizeMake(_srcW, _srcH);

    BXLog(@"[BXRTSP] 已连接 %@ %dx%d %.1ffps 解码=%@ 音频=%@(%@)",
          urlString, _srcW, _srcH, _streamFPS,
          _vtSession ? @"VT" : @"sw", _audioTrackFound ? @"有" : @"无", self.codecNameText ?: @"-");

    __weak typeof(self) weakSelf = self;
    dispatch_async(_decodeQueue, ^{ [weakSelf decodeLoop]; });
    return YES;
}

#pragma mark - VideoToolbox

- (void)setupVideoToolboxForParameters:(AVCodecParameters *)par {
    const uint8_t *ed = par->extradata;
    int edSize = par->extradata_size;
    CMFormatDescriptionRef desc = NULL;
    OSStatus st = (OSStatus)-1;

    if (ed && edSize > 7 && ed[0] == 1) {
        int numSPS = ed[5] & 0x1F;
        int idx = 6;
        const uint8_t *params[16] = {0};
        size_t sizes[16] = {0};
        int count = 0;
        for (int i = 0; i < numSPS && idx + 2 <= edSize && count < 16; i++) {
            int len = (ed[idx] << 8) | ed[idx + 1];
            idx += 2;
            if (idx + len > edSize) break;
            params[count] = ed + idx; sizes[count] = (size_t)len; count++; idx += len;
        }
        if (idx + 1 <= edSize) {
            int numPPS = ed[idx]; idx += 1;
            for (int i = 0; i < numPPS && idx + 2 <= edSize && count < 16; i++) {
                int len = (ed[idx] << 8) | ed[idx + 1];
                idx += 2;
                if (idx + len > edSize) break;
                params[count] = ed + idx; sizes[count] = (size_t)len; count++; idx += len;
            }
        }
        if (count >= 2) {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count,
                                                                     params, sizes, 4, &desc);
        }
    }

    if (st != noErr || !desc) return;      // 等码流里的 SPS/PPS
    _vtFmt = desc;
    [self recreateVTSession];
}

- (void)recreateVTSession {
    if (_vtSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_vtSession);
        VTDecompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (!_vtFmt) return;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(_camFmt ? _camFmt : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey: @(_srcW > 0 ? _srcW : 720),
        (id)kCVPixelBufferHeightKey: @(_srcH > 0 ? _srcH : 1280),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = bx_vt_output;
    cb.decompressionOutputRefCon = (__bridge void *)self;

    OSStatus cs = VTDecompressionSessionCreate(kCFAllocatorDefault, _vtFmt, NULL,
                                               (__bridge CFDictionaryRef)attrs, &cb, &_vtSession);
    if (cs != noErr || !_vtSession) {
        _vtSession = NULL;
        if (_vtFmt) { CFRelease(_vtFmt); _vtFmt = NULL; }
        return;
    }
    VTSessionSetProperty(_vtSession, kVTDecompressionPropertyKey_RealTime, (__bridge CFTypeRef)@YES);
}

- (void)prepareForCameraFormat:(OSType)fmt width:(size_t)w height:(size_t)h {
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return;
    if (_camFmt == fmt && _camW == w && _camH == h) return;
    _camFmt = fmt; _camW = w; _camH = h;

    // 【FIX-2 连续拍摄卡顿】重建 VT 会话要 WaitForAsynchronousFrames + Create，
    // 实测 10~50ms。本方法是在 AVCaptureVideoDataOutput 的 delegate 队列上被调用的
    // （BXCaptureBridge processBuffer:output: -> prepareForCameraFormat:），
    // 在这里同步重建 = 采集侧直接丢帧，用户感受就是「每按一次拍摄就卡一下」。
    // 改成丢到解码队列串行重建：期间旧会话仍然可用，画面不会黑。
      // 【关键修复】不能丢到 _decodeQueue：那个队列被 decodeLoop 长期占着
      // （只在 stop 时退出，中间还有 av_usleep 节流），dispatch 上去的 block 永远排不到。
      // 录制会改变摄像头格式，VT 会话必须及时重建，否则写帧用旧会话 → 卡死。
      static dispatch_queue_t vtQ = NULL;
      static dispatch_once_t vtOnce;
      dispatch_once(&vtOnce, ^{
          vtQ = dispatch_queue_create("bx.vt.rebuild", DISPATCH_QUEUE_SERIAL);
      });
      __weak typeof(self) ws = self;
      dispatch_async(vtQ, ^{
          __strong typeof(ws) s = ws;
          if (!s) return;
          [s recreateVTSession];
      });
}

#pragma mark - 解码循环（单线程顺序）

- (void)decodeLoop {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    NSString *url = self.urlString;
    uint64_t myGen = _generation;

    while (!_stopRequested && _fmt && pkt) {
        CFTimeInterval _t0 = CACurrentMediaTime();
        // 上一轮从起点到现在的总时长 = 循环体耗时（含所有 continue 分支）
        if (_iterStart > 0) _loopMsAcc += (_t0 - _iterStart) * 1000.0;
        _iterStart = _t0;

        // 只在「上一轮成功读到包」时重新武装 6 秒截止；
        // EAGAIN 期间保持原截止，6 秒后中断回调会返回 1，循环才能退出。
        if (_eagainStreak == 0) [self armDeadlineUs:6000000];
        int ret = av_read_frame(_fmt, pkt);
        if (ret >= 0) _eagainStreak = 0;
        _readMsAcc += (CACurrentMediaTime() - _t0) * 1000.0;
          // 按 PTS 节流（对齐原版：av_rescale_q + av_gettime_relative + av_usleep）
          if (ret >= 0 && pkt->pts != AV_NOPTS_VALUE && _fmt && pkt->stream_index < (int)_fmt->nb_streams) {
              AVStream *pst = _fmt->streams[pkt->stream_index];
              if (pst && pst->time_base.den > 0) {
                  int64_t us = (int64_t)(pkt->pts * av_q2d(pst->time_base) * 1000000.0);
                  if (gPaceBaseUs == 0) gPaceBaseUs = av_gettime_relative() - us;
                  int64_t waitUs = (gPaceBaseUs + us) - av_gettime_relative();
                  if (waitUs > 2000) {
                      if (waitUs > 200000) { gPaceBaseUs -= (waitUs - 200000); waitUs = 200000; }
                      av_usleep((unsigned)waitUs);
                  }
              }
          }
        if (ret < 0) {
            _readStalls++; _errCount++;
            if (ret == AVERROR(EAGAIN)) _eagainCount++;

            // 与原版 0x331848 一致：除「EOF + 循环」外，任何错误都直接退出循环。
            // （原版对 EAGAIN 也不 continue，所以断流时不会空转打满 CPU）
            if (ret != AVERROR_EOF) {
                if (_errLogged < 5) {
                    _errLogged++;
                    BXLog(@"[BXRTSP] 读包错误 ret=%d (%s)", ret, av_err2str(ret));
                }
                BXLog(@"[BXRTSP] read stopped decoder_error=1");
                break;
            }

            // EOF 且没开循环：结束
            if (!self.loopPlayback) {
                BXLog(@"[BXRTSP] EOF, loop=NO, 结束");
                break;
            }

            // EOF + 循环：回到开头（0x33193c），不重连
            if (!_stopRequested && _fmt &&
                av_seek_frame(_fmt, -1, 0, AVSEEK_FLAG_BACKWARD) >= 0) {
                _seekCount++;
                [_lock lock];
                [_lock unlock];
                if (_dec) avcodec_flush_buffers(_dec);
                if (_aDec) avcodec_flush_buffers(_aDec);
                [self rebuildSwr];
                [_lock lock];
    _aFillFrames = 0; _aWriteIdx = 0; _aReadIdx = 0; _aDropped = 0;
                [_lock unlock];
                continue;
            }

            BXLog(@"[BXRTSP] EOF 且无法回到开头，结束本轮流");
            break;
        }

        if (pkt->stream_index == _aStreamIndex && _aDec) {
            CFTimeInterval _ta = CACurrentMediaTime();
            if (avcodec_send_packet(_aDec, pkt) == 0) {
                AVFrame *af = av_frame_alloc();
                while (avcodec_receive_frame(_aDec, af) == 0) {
                    [self appendAudioFrame:af];
                    av_frame_unref(af);
                }
                av_frame_free(&af);
            }
            _audMsAcc += (CACurrentMediaTime() - _ta) * 1000.0;
            av_packet_unref(pkt);
            continue;
        }

        if (pkt->stream_index == _streamIndex) {
            _pktCount++;
            NSTimeInterval now = CACurrentMediaTime();
            if (_lastPktTime > 0) {
                double gap = (now - _lastPktTime) * 1000.0;
                _gapSumMs += gap;
                _gapCount++;
                if (gap > _gapMaxMs) _gapMaxMs = gap;
                if (gap > 200.0) _gapStalls++;      // 明显停顿
            }
            _lastPktTime = now;
            if (_pktMark == 0) _pktMark = now;
            if (now - _pktMark >= 1.0) {
                double span = now - _pktMark;
                _fpsPkt = (NSUInteger)(_pktCount / span);
                _pktWin = _pktCount;
                // 读包/解码耗时换算成「每秒平均每包毫秒」
                _readMsWin = (_pktCount > 0) ? (NSUInteger)(_readMsAcc / _pktCount) : 0;
                _loopMsWin = (_pktCount > 0) ? (NSUInteger)(_loopMsAcc / _pktCount) : 0;
                _loopMsAcc = 0;
                _decMsWin = (_pktCount > 0) ? (NSUInteger)(_decMsAcc / _pktCount) : 0;
                _readMsAcc = 0;
                _decMsAcc = 0;
                _pktCount = 0;
                _pktMark = now;
                _gapMaxWin = (NSUInteger)_gapMaxMs;   // 先存，供面板读
                _gapMaxMs = 0;
                _gapStallsWin = _gapStalls;
                _gapStalls = 0;
                // 与读取fps 同一窗口的算术平均：avg × fps 应 ≈ 1000
                // 拆解：四项都是「每秒毫秒数」，相加≈循环总量
                _readMsSec = (NSUInteger)_readMsAcc;
                _feedMsSec = (NSUInteger)_feedMsAcc;
                _audMsSec = (NSUInteger)_audMsAcc;
                double other = _loopMsAcc - _readMsAcc - _feedMsAcc - _audMsAcc;
                if (other < 0) other = 0;
                if (other > 1000) other = 1000;
                _otherMsSec = (NSUInteger)other;
                _feedMsAcc = 0;
                _audMsAcc = 0;

                _gapAvgMs = (_gapCount > 0) ? (_gapSumMs / _gapCount) : 0;
                _gapSumMs = 0;
                _gapCount = 0;

            }

            if (kBXEnableHardwareDecode && !_vtSession) [self tryBuildFormatFromPacket:pkt];

            CFTimeInterval _tf = CACurrentMediaTime();
            if (kBXEnableHardwareDecode && _vtSession) {
                [self feedHardware:pkt];
            } else if (_dec) {
                if (avcodec_send_packet(_dec, pkt) == 0) {
                    while (avcodec_receive_frame(_dec, frame) == 0) {
                        [self publishFrame:frame];
                        av_frame_unref(frame);
                    }
                }
            }
            _feedMsAcc += (CACurrentMediaTime() - _tf) * 1000.0;
        }
        av_packet_unref(pkt);
    }

    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);

    if (myGen == _generation) {
        if (_vtSession) {
            VTDecompressionSessionWaitForAsynchronousFrames(_vtSession);
            VTDecompressionSessionInvalidate(_vtSession);
            CFRelease(_vtSession);
            _vtSession = NULL;
        }
        if (_vtFmt) { CFRelease(_vtFmt); _vtFmt = NULL; }
        [_lock lock];
        if (_sws) { sws_freeContext(_sws); _sws = NULL; }
        if (_bgra) { free(_bgra); _bgra = NULL; _bgraSize = 0; }
        if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    if (_slot)   { CVPixelBufferRelease(_slot);   _slot = NULL; }
    if (_camLast){ CVPixelBufferRelease(_camLast); _camLast = NULL; }
        if (_lastServed) { CVPixelBufferRelease(_lastServed); _lastServed = NULL; }
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        [_lock unlock];
        if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
        if (_aDec) { avcodec_free_context(&_aDec); _aDec = NULL; }
        if (_swr) { swr_free(&_swr); _swr = NULL; }
        if (_aRing) { free(_aRing); _aRing = NULL; }
        if (_aTmp) { free(_aTmp); _aTmp = NULL; _aTmpCap = 0; }
    _aFillFrames = 0; _aWriteIdx = 0; _aReadIdx = 0; _aDropped = 0;
        if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
        _loopActive = NO;
    }
}

// 与原版一致：纯软件解码。VT 代码保留作参考，但运行时永不进入。
// 之前这里没堵住，SPS+PPS 一到就会惰性切到 VT 硬解并释放软解上下文。
static const BOOL kBXEnableHardwareDecode = NO;

- (BOOL)tryBuildFormatFromPacket:(AVPacket *)pkt {
    if (!kBXEnableHardwareDecode) return NO;

    if (_vtSession || _vtFmt) return YES;
    const uint8_t *d = pkt->data;
    int size = pkt->size;
    if (!d || size < 8) return NO;

    int i = 0;
    while (i + 3 < size) {
        int sc = 0;
        if (d[i] == 0 && d[i+1] == 0 && d[i+2] == 1) sc = 3;
        else if (i + 4 < size && d[i] == 0 && d[i+1] == 0 && d[i+2] == 0 && d[i+3] == 1) sc = 4;
        if (sc == 0) { i++; continue; }

        int body = i + sc;
        int next = size;
        for (int j = body + 1; j + 3 < size; j++) {
            if ((d[j] == 0 && d[j+1] == 0 && d[j+2] == 1) ||
                (j + 4 < size && d[j] == 0 && d[j+1] == 0 && d[j+2] == 0 && d[j+3] == 1)) {
                next = j; break;
            }
        }
        int len = next - body;
        if (len > 0) {
            int t = d[body] & 0x1F;
            if (t == 7 && _spsLen == 0 && len <= (int)sizeof(_sps)) {
                memcpy(_sps, d + body, (size_t)len); _spsLen = (size_t)len;
            } else if (t == 8 && _ppsLen == 0 && len <= (int)sizeof(_pps)) {
                memcpy(_pps, d + body, (size_t)len); _ppsLen = (size_t)len;
            }
        }
        i = next;
        if (next <= body) i = body;
    }

    if (_spsLen == 0 || _ppsLen == 0) return NO;

    const uint8_t *params[2] = { _sps, _pps };
    size_t sizes[2] = { _spsLen, _ppsLen };
    CMFormatDescriptionRef desc = NULL;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, params,
                                                            sizes, 4, &desc) != noErr || !desc) {
        return NO;
    }
    _vtFmt = desc;
    if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
    [self recreateVTSession];
    return _vtSession != NULL;
}

- (void)noteParameterSet:(const uint8_t *)p length:(size_t)len type:(int)type {
    if (!p || len == 0 || len > 512) return;
    uint8_t *store = (type == 7) ? _sps : _pps;
    size_t *storeLen = (type == 7) ? &_spsLen : &_ppsLen;

    if (*storeLen == len && memcmp(store, p, len) == 0) return;   // 没变
    memcpy(store, p, len);
    *storeLen = len;

    // 两个都齐了才重建
    if (_spsLen == 0 || _ppsLen == 0) return;
    const uint8_t *params[2] = { _sps, _pps };
    size_t sizes[2] = { _spsLen, _ppsLen };
    CMFormatDescriptionRef desc = NULL;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, params,
                                                            sizes, 4, &desc) == noErr && desc) {
        if (_vtFmt) { CFRelease(_vtFmt); _vtFmt = NULL; }
        _vtFmt = desc;
        [self recreateVTSession];
        BXLog(@"[BXRTSP] SPS/PPS 变化，已重建解码会话（%d）", type);
    }
}

- (void)feedHardware:(AVPacket *)pkt {
    const uint8_t *data = pkt->data;
    int size = pkt->size;
    if (!data || size < 5 || !_vtFmt) return;

    BOOL annexB = (data[0] == 0 && data[1] == 0 &&
                   (data[2] == 1 || (data[2] == 0 && data[3] == 1)));

    NSMutableData *avcc = [NSMutableData dataWithCapacity:(NSUInteger)size + 16];
    if (annexB) {
        int i = 0;
        while (i + 3 < size) {
            int sc = 0, nalStart = -1;
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) { nalStart = i + 3; sc = 3; }
            else if (i + 4 < size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) { nalStart = i + 4; sc = 4; }
            if (nalStart < 0) { i++; continue; }

            int next = size;
            for (int j = nalStart + 1; j + 3 < size; j++) {
                if ((data[j] == 0 && data[j+1] == 0 && data[j+2] == 1) ||
                    (j + 4 < size && data[j] == 0 && data[j+1] == 0 && data[j+2] == 0 && data[j+3] == 1)) {
                    next = j; break;
                }
            }
            int len = next - nalStart;
            int t = (len > 0) ? (data[nalStart] & 0x1F) : -1;

            // SPS(7)/PPS(8) 不再一律丢弃：与已存的比较，变了就重建格式描述。
            // 否则推流端重新发参数集之后，后续帧会在 VT 里报 -12909（BadData），
            // 表现就是「每秒掉几帧」。
            if (len > 0 && (t == 7 || t == 8)) {
                [self noteParameterSet:data + nalStart length:(size_t)len type:t];
            }

            if (len > 0 && t != 7 && t != 8) {
                uint32_t be = htonl((uint32_t)len);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:data + nalStart length:(NSUInteger)len];
            }
            i = next;
            if (next <= nalStart) i = nalStart;
        }
    } else {
        [avcc appendBytes:data length:(NSUInteger)size];
    }

    if (avcc.length == 0) return;

    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length,
                                           kCFAllocatorDefault, NULL, 0, avcc.length,
                                           kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || !block) {
        return;
    }
    CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);

    CMSampleTimingInfo timing = { .duration = CMTimeMake(1, 30),
                                  .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
                                  .decodeTimeStamp = kCMTimeInvalid };
    CMSampleBufferRef sbuf = NULL;
    size_t sampleSize = avcc.length;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _vtFmt, 1, 1,
                                            &timing, 1, &sampleSize, &sbuf);
    CFRelease(block);
    if (st != noErr || !sbuf) {
        static int logged = 0;
        if (logged++ < 5) BXLog(@"[BXRTSP] 造 sample buffer 失败 st=%d", (int)st);
        return;
    }

    CFTimeInterval t0 = CACurrentMediaTime();
    VTDecodeInfoFlags info = 0;
    // 异步解码（原版做法）：DecodeFrame 立即返回，VT 在内部线程解，
    // 读包循环不用等解码 —— 这是「原版读得更快」的直接原因。
    // 关掉异步（同步）只在调试时用：每帧阻塞 3~30ms，读取会被拖慢。
            VTDecodeFrameFlags flags = 0;
    OSStatus ds = VTDecompressionSessionDecodeFrame(_vtSession, sbuf, flags, NULL, &info);
    double ms = (CACurrentMediaTime() - t0) * 1000.0;
    _decMsAcc += ms;
    _vtDecodeMs = (_vtDecodeMs == 0) ? ms : (_vtDecodeMs * 0.8 + ms * 0.2);
    if (ds != noErr) {
        _vtErrors++;
        static int e5 = 0;
        if (e5++ < 5) BXLog(@"[BXRTSP] VT 解码失败 st=%d", (int)ds);
    }
    CFRelease(sbuf);
}

#pragma mark - 软解回退



// 入队：解码线程调用
- (void)pushPending:(CVPixelBufferRef)buf pts:(double)pts {
    if (!buf) return;
    CVPixelBufferRef keep = (CVPixelBufferRef)CVBufferRetain(buf);

    // 【单槽】照原版 0x4a80d8：只有一个槽位，新帧直接覆盖旧帧。
    // 不排队、不追帧、不做 fps 匹配——原版就是这样，也因此没有跨线程积压。
    [_lock lock];
    if (_slot) CVPixelBufferRelease(_slot);
    _slot = keep;
    _slotPts = pts;
    [_lock unlock];
}

// 出队：摄像头线程每拍调用，把「到点」的帧推进 _latest
// 每次摄像头回调取走 1 帧（先进先出）。
// 源 24 帧/秒 < 取帧 30 次/秒 → 不会积压、不会慢放；每帧都会被取走 → 不丢帧。
- (void)releaseDueFrames {
    CVPixelBufferRef take = NULL;

    [_lock lock];
    if (_qCount > 0) {
        take = _qBuf[_qHead];
        _qBuf[_qHead] = NULL;
        _qHead = (_qHead + 1) % 6;
        _qCount--;
    }
    [_lock unlock];

    if (!take) return;                   // 队列空：继续用上一帧

    [_lock lock];
    if (_latest) CVPixelBufferRelease(_latest);
    _latest = take;
    [_lock unlock];
}


- (void)publishFrame:(AVFrame *)frame {
    if (!frame) return;

    // 记录本帧的流时间戳，_xformStep 入队时要用
    if (frame->pts != AV_NOPTS_VALUE && _streamTB.den > 0) {
        _pushPts = (double)frame->pts * av_q2d(_streamTB);
    }


    // FFmpeg 的 videotoolbox 解码器输出 AV_PIX_FMT_VIDEOTOOLBOX，
    // data[3] 就是 CVPixelBufferRef —— 直接复用，省掉一次全画幅转换。
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3]) {
        CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3];
        if (pb) {
            [self enqueueFrame:pb pts:CMClockGetTime(CMClockGetHostTimeClock())];
            return;
        }
    }

    if (frame->width <= 0) return;

    // 目标像素格式：跟着摄像头走（原版就是这么做的 —— sws 直接输出摄像头格式，
    // 后面不需要再转一次；我们是 BGRA 再 CoreImage 转，多花 2~4ms/帧）。

    // 照抄原版 0x332300-0x332320 的调用：
    //   sws_getContext(srcW, srcH, srcFmt, srcW, srcH, AV_PIX_FMT_RGBA, SWS_BILINEAR, 0,0,0)
    //   即：不缩放（输出=源尺寸），颜色转 RGBA；缩放留给下游 VT 转换。
    OSType camFmt = (OSType)_camFmt;
    // 原版 0x332314：dstFormat = 0x1c
    enum AVPixelFormat dstPix = (enum AVPixelFormat)0x1c;
    BOOL biplanar = NO;

    int dstW = (int)frame->width;      // 原版 dstW = srcW
    int dstH = (int)frame->height;     // 原版 dstH = srcH

    if (!_sws || frame->width != _srcW || frame->height != _srcH ||
        dstW != _srcW2 || dstH != _srcH2 || _dstPix != (int)dstPix) {
        if (_sws) { sws_freeContext(_sws); _sws = NULL; }
        _srcW = frame->width; _srcH = frame->height;
        _srcW2 = dstW; _srcH2 = dstH;
        _srcFmt = (enum AVPixelFormat)frame->format;
        _dstPix = (int)dstPix;
        _sws = sws_getContext(_srcW, _srcH, _srcFmt, dstW, dstH, dstPix,
                              SWS_BILINEAR, NULL, NULL, NULL);
        BXLog(@"[BXRTSP] sws: %dx%d fmt=%d -> %dx%d fmt=%d", _srcW, _srcH, _srcFmt,
              dstW, dstH, (int)dstPix);
    }
    if (!_sws) return;

    // 原版路线：从 CVPixelBufferPool 取一块，sws_scale 直接写进去。
    // 之前我们是 sws_scale → malloc 缓冲 → 逐行 memcpy 进 CVPixelBuffer，
    // 一帧要拷两遍 8MB，48fps 就是 768MB/s 的额外内存带宽。
    // 原版池格式就是 32BGRA（0x332398 处 movk #0x4247 → 'BGRA'）
    OSType outFmt = (OSType)kCVPixelFormatType_32BGRA;
    CVPixelBufferPoolRef pool = [self srcPoolForSize:CGSizeMake(dstW, dstH) format:outFmt];
    CVPixelBufferRef px = NULL;
    if (pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &px);
    }
    if (!px) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(_srcW),
            (id)kCVPixelBufferHeightKey: @(_srcH),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferCreate(kCFAllocatorDefault, (size_t)_srcW, (size_t)_srcH,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &px);
    }
    if (!px) return;

    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *dst[4] = { NULL, NULL, NULL, NULL };
    int dstStride[4] = { 0, 0, 0, 0 };
    if (biplanar) {
        dst[0] = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(px, 0);
        dst[1] = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(px, 1);
        dstStride[0] = (int)CVPixelBufferGetBytesPerRowOfPlane(px, 0);
        dstStride[1] = (int)CVPixelBufferGetBytesPerRowOfPlane(px, 1);
    } else {
        dst[0] = (uint8_t *)CVPixelBufferGetBaseAddress(px);
        dstStride[0] = (int)CVPixelBufferGetBytesPerRow(px);
    }
    CFTimeInterval _tsws = CACurrentMediaTime();
    sws_scale(_sws, (const uint8_t *const *)frame->data, frame->linesize, 0, _srcH, dst, dstStride);
    CVPixelBufferUnlockBaseAddress(px, 0);
    _swsMsAcc += (CACurrentMediaTime() - _tsws) * 1000.0;

    self.lastReasonText = @"软解ok";

    // 统一进播放环（和硬解同一条下游），否则播放缓冲对软解失效
    [self enqueueFrame:px pts:CMClockGetTime(CMClockGetHostTimeClock())];
    CVPixelBufferRelease(px);

}

#pragma mark - 入队 / 取帧

- (void)publishHardwareFrame:(CVImageBufferRef)buffer {
    [self enqueueFrame:buffer pts:CMClockGetTime(CMClockGetHostTimeClock())];
}

- (void)enqueueFrame:(CVImageBufferRef)buffer pts:(CMTime)pts {
    gLastDecodeTick = CACurrentMediaTime();   // 新的一帧解出来了
    if (!buffer) return;

    // VT 回调线程上只做一件事：把最新原始帧放进槽。
    // 变换（CIContext / 池）会卡住 VT 内部队列，反过来拖慢解码 —— 必须挪到别的队列。
    [_lock lock];
    if (_rawSlot) CVPixelBufferRelease(_rawSlot);
    _rawSlot = (CVPixelBufferRef)CVBufferRetain(buffer);
    _latestPTS = pts;
    [_lock unlock];

    self.decodedFrames = self.decodedFrames + 1;

    // 原版在解码线程里同步完成「转换 + 写槽」，节流才有意义。
    // 之前我们丢到 _xformQueue 异步做，节流睡完写槽仍按异步队列节奏走，等于没节流。
    [self _xformStep];

    _fpsCount++;
    NSTimeInterval now = CACurrentMediaTime();
    if (_fpsMark == 0) _fpsMark = now;
    if (now - _fpsMark >= 1.0) {
        _fpsEnq = (NSUInteger)(_fpsCount / (now - _fpsMark));
        _fpsCount = 0;
        _fpsMark = now;
    }
}

- (void)_xformStep {
    CVPixelBufferRef raw = NULL;
    CGSize want = CGSizeZero;

    [_lock lock];
    raw = _rawSlot;
    _rawSlot = NULL;
    want = _wantSize;
    if (want.width < 2 || want.height < 2) want = CGSizeMake((CGFloat)_camW, (CGFloat)_camH);
    [_lock unlock];

    if (raw) {
        CVPixelBufferRef ready = raw;
        BOOL owned = NO;
        // 尺寸未知（进页面第一帧，采集侧还没上报）时直接入槽原始帧：
        // transformBuffer:toSize:{0,0} 会建 0×0 缓冲，VT transfer 必失败并刷日志。
        if (want.width >= 2 && want.height >= 2) {
            CGFloat w = CVPixelBufferGetWidth(raw);
            CGFloat h = CVPixelBufferGetHeight(raw);
            // 原版：槽里就是 sws 出来的 BGRA，不做第二次转换；
            // 格式转换由消费侧的 VT（写进摄像头缓冲时）一次完成。
            // 之前这里加了 fmtDiff 判断，导致每帧多做一次整帧 VT。
            BOOL need = (fabs(w - want.width) > 1.0 || fabs(h - want.height) > 1.0 ||
                         _mirror || ((_rotation % 360) != 0));
            if (need) {
                CVPixelBufferRef t = [self transformBuffer:raw toSize:want];
                if (t) { ready = t; owned = YES; }
            }
        }

        // 不直接写槽：先进抖动缓冲，由摄像头线程按节奏放出
        [self pushPending:ready pts:_pushPts];
        _lastSlotHost = CACurrentMediaTime();


        // 原版是单槽：这里只保留 _latest，不排队、不加延迟。
        self.lastReasonText = @"硬解ok";

        // 入槽计数：这是「真实出帧率」。
        // 替换fps 恒等于摄像头帧率（消费者不清槽），只有这个数能反映源/xform 是否跟不上。
        _slotFill++;
        NSTimeInterval now2 = CACurrentMediaTime();
        if (_slotFillMark <= 0) {
            _slotFillMark = now2;
        } else if (now2 - _slotFillMark >= 1.0) {
            _slotFillFPS = (NSUInteger)((double)_slotFill / (now2 - _slotFillMark));
            _slotFill = 0;
            _slotFillMark = now2;
        }
        CGSize sz = CGSizeMake(CVPixelBufferGetWidth(ready), CVPixelBufferGetHeight(ready));
        if (sz.width > 0) self.size = sz;

        if (owned) CVPixelBufferRelease(ready);
        CVPixelBufferRelease(raw);
    }

    // 期间可能又来了新帧：再跑一轮，保证槽里始终是最新的
    [_lock lock];
    BOOL again = (_rawSlot != NULL);
    [_lock unlock];

    // 【FIX-1 播久必卡】不再递归重跑。
    // 新帧到达时 enqueueFrame: 会自己再调一次 _xformStep；这里再递归的话，在
    // 「源帧率 ≥ 消费帧率」的场景会一路递归、永不返回 —— 而调用线程正是
    // VideoToolbox 的输出回调线程，它被占死之后解码器队列开始积压，
    // 表现就是：刚开始正常，播几分钟后越来越卡、gapMax 一路涨。
    (void)again;
}

// 把槽位里最新的 BGRA 帧用 VT 直接写进目标缓冲（摄像头帧），省掉一次整帧 memcpy。
// 原版 0x330000 的 transfer 也是直接写目标缓冲，没有中间拷贝。
// 原版预览路径 0x329b14：自建一块 BGRA，把槽位帧 VT 复制进去，再交给 CoreImage。
- (CVPixelBufferRef)copyPreviewFrameBGRA CF_RETURNS_RETAINED {
    // 单槽：预览直接读槽位
    CVPixelBufferRef src = NULL;
    [_lock lock];
    if (_slot) src = (CVPixelBufferRef)CVBufferRetain(_slot);
    [_lock unlock];
    if (!src) return NULL;

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);

    // 【FIX-3 播久必卡】预览每帧都 CVPixelBufferCreate 一块整帧 BGRA
    // （1080p = 8MB），30fps 就是每秒 240MB 的分配/释放 —— 分配器碎片 + 内存带宽
    // 会把解码线程顶住。改成走已有的 poolForSize:format:（尺寸/格式不对才重建）。
    CVPixelBufferRef dst = NULL;
    CVPixelBufferPoolRef pool = [self poolForSize:CGSizeMake((CGFloat)w, (CGFloat)h)
                                           format:(OSType)kCVPixelFormatType_32BGRA];
    if (pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst);
    }
    if (!dst) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
            CVPixelBufferRelease(src);
            return NULL;
        }
    }

    if (![self transferFrom:src to:dst]) {
        CVPixelBufferRelease(dst);
        dst = NULL;
    }
    CVPixelBufferRelease(src);
    return dst;
}

static NSTimeInterval gLastDecodeTick = 0;
- (NSTimeInterval)lastDecodeTick { return gLastDecodeTick; }


// 造一帧"摄像头格式"的样本还回去 —— 完全不碰 app 的像素缓冲。
// 这是架构层面的改动：app 那边再也不会出现我们写入的缓冲，也就不存在互等。



- (BOOL)renderLatestInto:(CVPixelBufferRef)dst {
    if (!dst) return NO;
    // 【回前台保护】切后台再回来时，抖音会重建采集会话，而槽位里还是旧帧。
    // 拿旧帧往新缓冲里写很容易把重建过程拖死，所以"解出来的帧太旧"时先直通。
    // lastDecodeTick 是解码线程每解出一帧就打的时间戳。
    {
        NSTimeInterval tick = [self lastDecodeTick];
        if (tick > 0 && (CACurrentMediaTime() - tick) > 1.5) {
            return NO;   // 帧过期：让真实摄像头顶上，等新帧到了再接管
        }
    }


    // 原版 0x32ff78：锁A 取槽位帧 + retain → 解锁A → 锁B + VT 搬运 → 解锁B。
    // 单槽没有"队列空了要复用上一帧"的问题：槽里的帧一直在，直到被新帧覆盖。
    CVPixelBufferRef src = NULL;
    [_lock lock];
    if (_slot) src = (CVPixelBufferRef)CVBufferRetain(_slot);
    [_lock unlock];
    if (!src) return NO;

    BOOL ok = [self transferFrom:src to:dst dedicated:YES];
    CVPixelBufferRelease(src);
    return ok;
}

- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS
                                 scaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    (void)cameraPTS;
    // 采集线程只做两件事：记下期望尺寸、取走最新帧。
    // 变换一律在 _xformQueue 里完成 —— 之前在这里 transformBuffer 是 RTSP 卡顿的根因。
    [_lock lock];
    if (targetSize.width >= 2 && targetSize.height >= 2) _wantSize = targetSize;

    CVPixelBufferRef f = NULL;
    // 原版语义（0x3350f8/0x3350fc）：单槽，取走即清空；槽空则返回 NULL，
    // 由上层保持上一帧画面（不做任何队列、不计延迟）。
    // 原版 0x32ffe4-0x32fff0：delegate 路径只 retain，**不清空**
    //   x20 = [0x4a80d8]; CVPixelBufferRetain(x20); unlock
    // 槽位由生产者覆盖（覆盖时释放旧的）。
    // 这样每个摄像头 tick 都能拿到最新帧（重复上一帧），不会出现空槽回落摄像头。
    if (_slot) {
        f = (CVPixelBufferRef)CVBufferRetain(_slot);
    }

    [_lock unlock];

    return f;
}

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    return [self copyFrameForCameraPTS:kCMTimeInvalid scaledTo:targetSize];
}

#pragma mark - 缩放

// 软解专用的池：与下游变换池分开，避免两边尺寸/格式不同导致每帧重建池
- (CVPixelBufferPoolRef)srcPoolForSize:(CGSize)size format:(OSType)fmt {
    @synchronized (self) {
        if (_srcPool && CGSizeEqualToSize(_srcPoolSize, size)) {
            NSDictionary *a = (__bridge NSDictionary *)CVPixelBufferPoolGetPixelBufferAttributes(_srcPool);
            if ([a[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue] == fmt) return _srcPool;
        }
        if (_srcPool) { CVPixelBufferPoolRelease(_srcPool); _srcPool = NULL; }
        // 原版池属性只有四项（0x3317a4-0x3317dc：Width/Height/PixelFormatType/IOSurface）
        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_srcPool);
        _srcPoolSize = size;
        return _srcPool;
    }
}

- (CVPixelBufferPoolRef)poolForSize:(CGSize)size format:(OSType)fmt {
    @synchronized (self) {
        if (_pool && CGSizeEqualToSize(_poolSize, size)) {
            NSDictionary *a = (__bridge NSDictionary *)CVPixelBufferPoolGetPixelBufferAttributes(_pool);
            OSType cur = [a[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
            if (cur == fmt) return _pool;
        }
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
        _poolSize = size;
        return _pool;
    }
}

// 摄像头路径与预览路径各用一套会话，互不阻塞。
// 原版只有一套 + 一把锁；但原版预览很少开，我们预览窗口会一直刷新，
// 共用会话时预览的 10-20ms 转换会把摄像头线程拖住。
- (BOOL)transferFrom:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst dedicated:(BOOL)dedicated {
    static VTPixelTransferSessionRef sCam = NULL;     // 摄像头路径
    static VTPixelTransferSessionRef sAux = NULL;     // 预览/其它
    static BOOL sCamMode = NO, sAuxMode = NO;
    static os_unfair_lock sCamLock = OS_UNFAIR_LOCK_INIT;
    static os_unfair_lock sAuxLock = OS_UNFAIR_LOCK_INIT;

    if (!src || !dst) return NO;

    // 【照原版】只有宽高比一致才写：原版用 CropSourceToCleanAperture，不重采样，
    // 前提就是源/目标同比例（720x1280 → 1080x1920 都是 9:16）。
    // 比例不一致时直接放行真实摄像头，避免 VT 内部临时建转换器（会阻塞）。
    {
        size_t sw = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
        size_t dw = CVPixelBufferGetWidth(dst),  dh = CVPixelBufferGetHeight(dst);
        if (sw && sh && dw && dh) {
            double sa = (double)sw / (double)sh;
            double da = (double)dw / (double)dh;
            if (fabs(sa - da) > 0.01) {
                static int sSkip = 0;
                if (sSkip++ < 3) {
                    BXLog(@"[BXRTSP] 比例不一致，跳过写帧 %zux%zu -> %zux%zu", sw, sh, dw, dh);
                }
                return NO;
            }
        }
    }

    VTPixelTransferSessionRef *slot = dedicated ? &sCam : &sAux;
    BOOL *modeSet = dedicated ? &sCamMode : &sAuxMode;
    os_unfair_lock *lk = dedicated ? &sCamLock : &sAuxLock;

    os_unfair_lock_lock(lk);

    if (!*slot) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, slot) != noErr || !*slot) {
            os_unfair_lock_unlock(lk);
            return NO;
        }
        *modeSet = NO;
    }

    // 原版只有一个设置：kVTScalingMode_CropSourceToCleanAperture
    // 属性只在会话创建后设一次（每帧 set 会拖慢单帧、并可能让 VT 失败）
    if (!*modeSet) {
        VTSessionSetProperty(*slot, kVTPixelTransferPropertyKey_ScalingMode,
                             kVTScalingMode_CropSourceToCleanAperture);   // 原版 0x33006c
        *modeSet = YES;
    }
    OSStatus st = VTPixelTransferSessionTransferImage(*slot, src, dst);
    if (st != noErr) {
        static int sFail = 0;
        if (sFail++ < 5) {
            BXLog(@"[BXRTSP] VT 写帧失败 st=%d（%zu x %zu -> %zu x %zu）", (int)st,
                  (size_t)CVPixelBufferGetWidth(src), (size_t)CVPixelBufferGetHeight(src),
                  (size_t)CVPixelBufferGetWidth(dst), (size_t)CVPixelBufferGetHeight(dst));
        }
    }
    os_unfair_lock_unlock(lk);
    return st == noErr;
}

// 兼容旧调用（预览/变换队列）：用非摄像头的会话
- (BOOL)transferFrom:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst {
    return [self transferFrom:src to:dst dedicated:NO];
}

- (CVPixelBufferRef)scaleOnce:(CVPixelBufferRef)src toSize:(CGSize)size CF_RETURNS_RETAINED {
    if (!src || size.width < 2 || size.height < 2) return NULL;
    OSType pf = self.targetFormat ? self.targetFormat : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    CVPixelBufferPoolRef pool = [self poolForSize:size format:pf];
    if (!pool) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) != kCVReturnSuccess || !dst) return NULL;
    if ([self transferFrom:src to:dst]) return dst;
    CVPixelBufferRelease(dst);
    return NULL;
}

- (CVPixelBufferRef)transformBuffer:(CVPixelBufferRef)src
                             toSize:(CGSize)targetSize CF_RETURNS_RETAINED {
    if (!src) return NULL;

    BOOL needRotate = (_rotation % 360) != 0;
    BOOL needMirror = _mirror;
    CGFloat sw = (CGFloat)CVPixelBufferGetWidth(src);
    CGFloat sh = (CGFloat)CVPixelBufferGetHeight(src);
    BOOL needScale = !CGSizeEqualToSize(targetSize, CGSizeZero) &&
                     (fabs(targetSize.width - sw) > 1.0 || fabs(targetSize.height - sh) > 1.0);

    // 像素格式也要对齐：软解出来是 BGRA，摄像头缓冲是 420f/420v。
    // 之前这里只看尺寸，格式不同的帧被原样返回，写进 420f 缓冲就是全黑。
    OSType targetPF = self.targetFormat;
    BOOL fmtOK = (targetPF == 0) ||
                 (CVPixelBufferGetPixelFormatType(src) == targetPF);

    if (!needRotate && !needMirror && !needScale && fmtOK) {
        return (CVPixelBufferRef)CFRetain(src);
    }

    // 只需要「缩放 + 转格式」时走 VTPixelTransferSession（硬件），
    // 不要用 CoreImage：1080p 每帧 render 一次会把整机拖卡。
    // 原版同样是 VT transfer（0x335874 处 VTPixelTransferSessionCreate/TransferImage）。
    if (!needRotate && !needMirror) {
        CGSize outSize = needScale ? targetSize : CGSizeMake(sw, sh);
        CVPixelBufferRef out = [self scaleOnce:src toSize:outSize];
        if (out) return out;
    }

    OSType pf = self.targetFormat ? self.targetFormat : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    CGSize outSize = needScale ? targetSize : CGSizeMake(sw, sh);
    if (_rotation == 90 || _rotation == 270) outSize = CGSizeMake(outSize.height, outSize.width);
    if (outSize.width < 2 || outSize.height < 2) return NULL;

    CVPixelBufferPoolRef pool = [self poolForSize:outSize format:pf];
    if (!pool) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) != kCVReturnSuccess || !dst) return NULL;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    if (needScale) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(targetSize.width / sw,
                                                                      targetSize.height / sh)];
    }
    if (needMirror) {
        CGFloat width = needScale ? targetSize.width : sw;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(width, 0)];
    }
    if (needRotate) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation((CGFloat)(_rotation * M_PI / 180.0))];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
            img.extent.origin.x < 0 ? -img.extent.origin.x : 0,
            img.extent.origin.y < 0 ? -img.extent.origin.y : 0)];
    }
    [_ci render:img toCVPixelBuffer:dst
           bounds:CGRectMake(0, 0, outSize.width, outSize.height)
       colorSpace:BXColorSpaceRGB()];
    return dst;
}

#pragma mark - 音频

- (void)configureAudioSampleRate:(double)rate channels:(int)channels {
    if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8) return;
    if ((int)rate == _aOutRate && channels == _aOutCh) return;
    _aOutRate = (int)rate;
    _aOutCh = channels;
    // 不在采集线程重建 swr（会和解码线程竞争），只置脏，由解码线程自己重建
    _swrDirty = YES;
}

- (BOOL)rebuildSwr {
    if (!_aDec) return NO;
    int rate = (_aOutRate > 0) ? _aOutRate : 48000;
    int ch = (_aOutCh > 0) ? _aOutCh : 2;
      if (ch < 1) ch = 1;
      if (ch > 2) ch = 2;   // 环形缓冲按 2 声道分配，超出会写穿堆

    if (!_swrLock) _swrLock = [[NSRecursiveLock alloc] init];
    [_swrLock lock];
    if (_swr) { swr_free(&_swr); _swr = NULL; }
    struct SwrContext *swr = NULL;
    AVChannelLayout outLayout, inLayout;
    av_channel_layout_default(&outLayout, ch);
    av_channel_layout_copy(&inLayout, &_aDec->ch_layout);
    int rc = swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, rate,
                                 &inLayout, _aDec->sample_fmt, _aDec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&inLayout);
    av_channel_layout_uninit(&outLayout);
    BOOL ok = NO;
    if (rc == 0 && swr && swr_init(swr) >= 0) { _swr = swr; ok = YES; }
    else if (swr) swr_free(&swr);
    [_swrLock unlock];
    return ok;
}

// 【照原版 0x331b40..0x331b9c】音频生产端节奏：
//   wait = min(超前量, 0.3s)            ← 0x37e4e8 = 0.3
//   分片 av_usleep，每片 ≤10ms          ← 0x2710 = 10000
//   代次变化立即中断                    ← ldar [0x40e390]
- (void)paceAudioProducerFill:(size_t)fill ch:(int)ch {
    double ar = (_aOutRate > 0) ? (double)_aOutRate : 48000.0;
    size_t lead = (size_t)(ar * 0.20);          // 目标存量 200ms
    if (fill <= lead) return;
    double overSec = (double)(fill - lead) / ar;
    if (overSec > 0.3) overSec = 0.3;
    int64_t remainUs = (int64_t)(overSec * 1000000.0);
    uint64_t gen = _generation;
    while (remainUs > 0) {
        if (_generation != gen || _stopRequested) break;
        int64_t step = (remainUs > 10000) ? 10000 : remainUs;
        av_usleep((unsigned)step);
        remainUs -= step;
        _audioPaceWaits += 1;
        _audioPaceUs += (uint64_t)step;
    }
}

- (void)appendAudioFrame:(AVFrame *)af {
    if (!_aRing) return;
    // swr 只在解码线程重建：这里先看有没有待重建标记
    if (_swrDirty) { _swrDirty = NO; [self rebuildSwr]; }
    if (!_swr) return;
    int maxOut = swr_get_out_samples(_swr, af->nb_samples);
    if (maxOut <= 0) return;

    int ch = (_aOutCh > 0) ? _aOutCh : 2;
      if (ch < 1) ch = 1;
      if (ch > 2) ch = 2;   // 环形缓冲按 2 声道分配，超出会写穿堆
    size_t needBytes = (size_t)maxOut * ch * sizeof(float);
    if (!_aTmp || _aTmpCap < needBytes) {
        float *nb = realloc(_aTmp, needBytes);
        if (!nb) return;
        _aTmp = nb; _aTmpCap = needBytes;
    }
    uint8_t *outPtr[1] = { (uint8_t *)_aTmp };
    int got = swr_convert(_swr, outPtr, maxOut, (const uint8_t **)af->extended_data, af->nb_samples);
    if (got <= 0) return;
    _audioDecoded++;

    int total = got * ch;
    for (int k = 0; k < total; k++) {          // 限幅 ±1.0
        float v = _aTmp[k];
        if (v > 1.0f) v = 1.0f;
        else if (v < -1.0f) v = -1.0f;
        _aTmp[k] = v;
    }

    [_lock lock];
    if (_aRing) {
        size_t need = (size_t)got;
        if (need >= _aRingFrames) need = _aRingFrames;
        if (_aFillFrames + need > _aRingFrames) {
            size_t drop = _aFillFrames + need - _aRingFrames;
            if (drop > _aFillFrames) drop = _aFillFrames;
            memmove(_aRing, _aRing + drop * ch, (_aFillFrames - drop) * ch * sizeof(float));
            _aFillFrames -= drop;
        }
        memcpy(_aRing + _aFillFrames * ch, _aTmp + (got - (int)need) * ch,
               need * ch * sizeof(float));
        _aFillFrames += need;
        // 【B86】去掉 150ms 上限：原版环形缓冲没有任何延迟上限（0x331df0 写入 / 0x331da4 推进读者），
        // 我们这条上限每帧都会 memmove 丢掉最旧音频，听感就是"一会有一会没"。
        // 环容量 384000 帧（8 秒），消费端跟不上时由读者推进逻辑兜底。
    }
    size_t fillSnap = _aFillFrames;
    [_lock unlock];
    [self paceAudioProducerFill:fillSnap ch:ch];   // 照原版：写完按存量节流
}
// 原版全程 float32：环里就是 float，直接拷出去，不经过 S16 往返
- (NSUInteger)copyAudioFloat:(float *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;
    int ch = (_aOutCh > 0) ? _aOutCh : 2;
    if (ch < 1) ch = 1;
    if (ch > 2) ch = 2;
    NSUInteger n = 0;
    [_lock lock];
    if (_aRing && _aFillFrames > 0) {
        n = MIN(maxFrames, _aFillFrames);
        NSUInteger total = n * ch;
        memcpy(dst, _aRing, total * sizeof(float));
        if (n < _aFillFrames) {
            memmove(_aRing, _aRing + n * ch, (_aFillFrames - n) * ch * sizeof(float));
        }
        _aFillFrames -= n;
    }
    if (n < maxFrames) {
        _audioUnderruns++;
        _audioUnderrunFrames += (maxFrames - n);
    }
    [_lock unlock];
    return n;
}

- (NSUInteger)copyAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;
    int ch = (_aOutCh > 0) ? _aOutCh : 2;
    if (ch < 1) ch = 1;
    if (ch > 2) ch = 2;
    NSUInteger n = 0;
    [_lock lock];
    if (_aRing && _aFillFrames > 0) {
        n = MIN(maxFrames, _aFillFrames);
        for (NSUInteger k = 0; k < n * ch; k++) {
            float v = _aRing[k];
            if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
            dst[k] = (int16_t)(v * 32767.0f);
        }
        if (n < _aFillFrames) {
            memmove(_aRing, _aRing + n * ch, (_aFillFrames - n) * ch * sizeof(float));
        }
        _aFillFrames -= n;
    }
    if (n < maxFrames) {
        _audioUnderruns++;
        _audioUnderrunFrames += (maxFrames - n);
    }
    [_lock unlock];
    return n;
}

#pragma mark - 重连 / 停止

- (void)stop {
    gPaceBaseUs = 0;
    [_lock lock];
    for (int qi = 0; qi < 6; qi++) {
        if (_qBuf[qi]) { CVPixelBufferRelease(_qBuf[qi]); _qBuf[qi] = NULL; }
    }
    _qHead = 0; _qCount = 0; _qStarted = 0; _qDrops = 0;
    // 注意：不清 _latest。原版是「只 retain 不清空」，
    // 清掉会让每次会话重启时闪一下真实摄像头。
    [_lock unlock];

    [self clearDeadline];
    _stopRequested = YES;
    self.running = NO;

    // 先让阻塞中的 av_read_frame / avformat_open_input 立刻返回
    if (_fmt) {
        _fmt->interrupt_callback.callback = BXInterruptCB;
        _fmt->interrupt_callback.opaque = (__bridge void *)self;
    }

    // 等解码线程真正退出后再释放资源。
    // 如果 stop 正好跑在解码队列上（重连路径里可能），dispatch_sync 会死锁 —— 跳过。
    BOOL onDecodeQueue = (dispatch_get_specific(kBXDecodeQueueKey) == (__bridge void *)self);
    if (_decodeQueue && !onDecodeQueue) {
        dispatch_sync(_decodeQueue, ^{});
    }
    _loopActive = NO;

    // 到这里解码循环一定已经结束（或从未启动），可以安全释放。
    // 循环尾部的收尾逻辑若已释放过，这些指针都是 NULL，不会重复释放。
    if (_vtSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_vtSession);
        VTDecompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (_vtFmt) { CFRelease(_vtFmt); _vtFmt = NULL; }
    _spsLen = 0; _ppsLen = 0;

    [_lock lock];
    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_bgra) { free(_bgra); _bgra = NULL; _bgraSize = 0; }
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    if (_slot)   { CVPixelBufferRelease(_slot);   _slot = NULL; }
    if (_camLast){ CVPixelBufferRelease(_camLast); _camLast = NULL; }
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    [_lock unlock];

    if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
    if (_aDec) { avcodec_free_context(&_aDec); _aDec = NULL; }
    if (_swr) { swr_free(&_swr); _swr = NULL; }
    if (_aRing) { free(_aRing); _aRing = NULL; }
    if (_aTmp) { free(_aTmp); _aTmp = NULL; _aTmpCap = 0; }
    _aFillFrames = 0; _aWriteIdx = 0; _aReadIdx = 0; _aDropped = 0;
    if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }

    self.urlString = nil;
}

- (double)lastTransformMs { return _swsMsAcc + _vtMsAcc; }
- (double)swsMsTotal { return _swsMsAcc; }
- (double)vtMsTotal { return _vtMsAcc; }   // 原版无此统计，仅为头文件声明补齐

@end

