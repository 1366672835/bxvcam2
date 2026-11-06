
//
//  BXCaptureBridge.m
//

#import "BXCaptureBridge.h"
#import "BXAudioUnitHook.h"
#import "BXConfig.h"
#import "BXColorSpace.h"
#import "BXVideoSource.h"
#import "BXFFmpegRTSP.h"
#import "BXLocalAudio.h"
#import "BXPreviewWindow.h"   // 后台停流时判断预览是否开着
#import "BXFloatStore.h"
#import <UIKit/UIKit.h>        // UIApplication 前后台通知
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime
#import "BXSwizzle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreImage/CoreImage.h>   // CIContext / CIImage（像素格式转换要用）

static const void *kBXOrigQueueKey    = &kBXOrigQueueKey;

// 前置声明（install 里先用到）
@interface BXCaptureBridge (Process)
- (CMSampleBufferRef)processBuffer:(CMSampleBufferRef)sampleBuffer output:(id)output;
@end

// YES = 完全旁路：所有钩子只透传，不接管（用于确认相机本身是否正常）
static const void *kBXProxyKey = &kBXProxyKey;
static void BXSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue);

// AVCaptureSession 三个钩子（原版 0x32590c-0x325a18 同款）
static NSMutableDictionary *gSessionOrig;
static void BXAddOutput(id self, SEL _cmd, id output);
static void BXSessionStart(id self, SEL _cmd);
static void BXSessionStop(id self, SEL _cmd);

// 照抄百相：hook delegate 对象自己的 captureOutput 方法，
// 处理完再直接调用原 IMP（它不 objc_msgSend 那个选择器，说明是存 IMP 直调）。
// 照原版 0x32aa90：处理 delegate 对象——把它类里的 captureOutput: 换掉。
// 去重键是「类名字符串」，并且再比对一次 IMP 是否已是我们的函数。
static NSMutableDictionary *gDelegatePrev;
static NSMutableArray *gSeenOutputs;
static NSMutableArray *gSessionOutputsAtStart;   // 探针：startRunning 时会话里的 output      // probe: output classes seen   // 类名 -> NSValue(IMP)

static void BXDelegateCapture(id self, SEL _cmd, id output,
                              CMSampleBufferRef sbuf, id connection);

static void BXProcessDelegate(id delegate) {
    if (!delegate) return;
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    if (![delegate respondsToSelector:sel]) return;

    Class cls = [delegate class];
    NSString *name = NSStringFromClass(cls);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP prev = method_getImplementation(m);
    @synchronized ([BXCaptureBridge class]) {
        if (!gDelegatePrev) gDelegatePrev = [NSMutableDictionary dictionary];
        if (gDelegatePrev[name]) return;                       // 该类已处理过
        if (prev == (IMP)BXDelegateCapture) return;            // 已经是我们的
        gDelegatePrev[name] = [NSValue valueWithPointer:prev];
    }
    method_setImplementation(m, (IMP)BXDelegateCapture);
    [BXCaptureBridge shared].delegateHooked += 1;
    BXLog(@"[BXFloat][vcam] hook delegate 类 %@ prev=%p", name, (void *)prev);
}

// 沿父类链找"真正的原实现"：绝不返回我们自己的函数，避免无限递归把主线程锁死。
static IMP BXOrigDelegateIMP(id obj) {
    if (!obj) return NULL;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        NSString *n = NSStringFromClass(c);
        if (!n) continue;
        @synchronized ([BXCaptureBridge class]) {
            NSValue *v = gDelegatePrev[n];
            if (v) {
                IMP imp = (IMP)[v pointerValue];
                if (imp && imp != (IMP)BXDelegateCapture) return imp;
            }
        }
    }
    return NULL;
}

static void BXDelegateCapture(id self, SEL _cmd, id output,
                              CMSampleBufferRef sbuf, id connection) {
    // 递归保护：同一线程内再次进入说明转发链成环，直接原样返回，绝不递归。
    static __thread int depth = 0;
    if (depth > 0) return;
    depth++;

    CMSampleBufferRef rep = sbuf;
    @try {
        rep = [[BXCaptureBridge shared] processBuffer:sbuf output:output];
    } @catch (NSException *e) {
        rep = sbuf;
    }

    IMP prev = BXOrigDelegateIMP(self);
    if (prev) {
        ((void (*)(id, SEL, id, CMSampleBufferRef, id))prev)(self, _cmd, output, rep ?: sbuf, connection);
    }
    // rep 是我们新建的样本（+1 持有），转发完释放；原样本不动
    if (rep && rep != sbuf) CFRelease(rep);
    depth--;
}

// ─────────────────────────────────────────────────────────────
//  把 BGRA 帧转成摄像头使用的像素格式。
//  抖音的采集管线是按摄像头的 420f(全范围)/420v(视频范围) 建的，
//  直接塞 BGRA 即使格式描述写对了，后面处理链也可能不认。
// ─────────────────────────────────────────────────────────────
static CVPixelBufferRef BXConvertPixelBuffer(CVPixelBufferRef src, OSType dstFmt) CF_RETURNS_RETAINED {
    if (!src) return NULL;
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    if (srcFmt == dstFmt) return (CVPixelBufferRef)CFRetain(src);

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    if (w == 0 || h == 0) return NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(dstFmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, dstFmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    [ctx render:img toCVPixelBuffer:dst
           bounds:CGRectMake(0, 0, w, h)
       colorSpace:BXColorSpaceRGB()];
    return dst;
}


// ─────────────────────────────────────────────────────────────
//  照着百相的做法：不造新的 CMSampleBuffer，
//  直接把我们的帧「写进摄像头那一帧的 CVPixelBuffer」。
//  好处：像素格式、attachments、时间戳、格式描述全部天然一致，
//        不会出现 InvalidMediaFormat(-12743)，也不会 CFRelease(NULL)。
//  前提：src 与 dst 的尺寸、像素格式一致（调用方负责转换）。
// ─────────────────────────────────────────────────────────────
static BOOL BXBlitInto(CVPixelBufferRef dst, CVPixelBufferRef src) {
    if (!dst || !src) return NO;

    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
    if (dw != sw || dh != sh) return NO;
    if (CVPixelBufferGetPixelFormatType(dst) != CVPixelBufferGetPixelFormatType(src)) return NO;

    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return NO;
    }

    BOOL ok = YES;
    size_t planes = CVPixelBufferIsPlanar(dst) ? CVPixelBufferGetPlaneCount(dst) : 1;

    for (size_t pl = 0; pl < planes; pl++) {
        uint8_t *db = CVPixelBufferIsPlanar(dst)
                    ? (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, pl)
                    : (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        uint8_t *sb = CVPixelBufferIsPlanar(src)
                    ? (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, pl)
                    : (uint8_t *)CVPixelBufferGetBaseAddress(src);
        if (!db || !sb) { ok = NO; break; }

        size_t dbpr = CVPixelBufferIsPlanar(dst)
                    ? CVPixelBufferGetBytesPerRowOfPlane(dst, pl)
                    : CVPixelBufferGetBytesPerRow(dst);
        size_t sbpr = CVPixelBufferIsPlanar(src)
                    ? CVPixelBufferGetBytesPerRowOfPlane(src, pl)
                    : CVPixelBufferGetBytesPerRow(src);

        size_t rows = dh;
        size_t rowBytes = MIN(dbpr, sbpr);
        if (CVPixelBufferIsPlanar(dst) && pl > 0) {
            // 色度平面：高度是亮度的一半
            rows = (dh + 1) / 2;
            rowBytes = MIN(dbpr, sbpr);
        }

        for (size_t y = 0; y < rows; y++) {
            memcpy(db + y * dbpr, sb + y * sbpr, rowBytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return ok;
}


// ─────────────────────────────────────────────────────────────
//  音频替换：和视频一样，直接写进摄像头那一帧的 PCM，不造新的 sample buffer。
//  AVCaptureAudioDataOutput 给的是 LPCM（常见 48k / Float32 / 单或双声道），
//  我们把 RTSP 的音频重采样成 S16/48k/立体声，再按目标格式落进去。
// ─────────────────────────────────────────────────────────────
// 音频替换 —— 照抄百相（0x333138 处的调用序列）：
//   CMSampleBufferCreate（原版 0x333110 之后即它）
//   不复制附件（原版没有这一步）
//   然后把「新的 sample buffer」交给 App，而不是改原始内存。
// （原版还有 AudioUnitGetProperty/AudioComponentGetDescription，用于查音频单元参数，
//   我们从传入帧的 ASBD 直接取，等价。）
static CMSampleBufferRef BXMakeAudioBuffer(CMSampleBufferRef in,
                                           BXFFmpegRTSP *src,
                                           BXLocalAudio *localAudio,
                                           NSString **reasonOut) {
    if (!in) { if (reasonOut) *reasonOut = @"无 sampleBuffer"; return NULL; }

    BOOL useRTSP = (src && [src hasAudio]);
    BOOL useLocal = (!useRTSP && localAudio && [localAudio isLoaded]);
    if (!useRTSP && !useLocal) {
        if (reasonOut) *reasonOut = [NSString stringWithFormat:@"无音频源(rtsp=%d local=%d)",
                                     src ? [src hasAudio] : 0, localAudio ? [localAudio isLoaded] : 0];
        return NULL;
    }

    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(in);
    if (!fd) { if (reasonOut) *reasonOut = @"无格式描述"; return NULL; }
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!asbd || asbd->mSampleRate < 1) { if (reasonOut) *reasonOut = @"无 ASBD"; return NULL; }

    if (asbd->mBytesPerFrame == 0 || asbd->mChannelsPerFrame == 0 || asbd->mChannelsPerFrame > 8) {
        if (reasonOut) *reasonOut = @"ASBD 异常（ch/bpf 非法）";
        return NULL;
    }
    // 诊断：App 侧音频格式（预览与录制可能不同），只在变化时打一次
    {
        static double sRate = 0;
        static UInt32 sCh = 0, sBpf = 0, sFlags = 0;
        if (sRate != asbd->mSampleRate || sCh != asbd->mChannelsPerFrame ||
            sBpf != asbd->mBytesPerFrame || sFlags != asbd->mFormatFlags) {
            sRate = asbd->mSampleRate; sCh = asbd->mChannelsPerFrame;
            sBpf = asbd->mBytesPerFrame; sFlags = asbd->mFormatFlags;
            BXLog(@"[BXFloat][vcam] app 音频格式 rate=%.0f ch=%u bpf=%u flags=0x%x",
                  asbd->mSampleRate, (unsigned)sCh, (unsigned)sBpf, (unsigned)sFlags);
        }
    }

    UInt32 ch = asbd->mChannelsPerFrame ? asbd->mChannelsPerFrame : 1;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL nonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bytesPerSample = isFloat ? 4 : 2;

    // 防御：我们对 ASBD 的理解如果和实际不符，按错误的尺寸写就是越界。
    // 交错时每个样本占 bytesPerSample×声道；非交错时每平面占 bytesPerSample。
    // 不一致就放弃替换（交回原始缓冲），避免写坏内存。
    if (asbd->mBytesPerFrame != 0) {
        UInt32 expectBpf = nonInterleaved ? bytesPerSample : (bytesPerSample * ch);
        if (asbd->mBytesPerFrame != expectBpf) {
            if (reasonOut) *reasonOut = [NSString stringWithFormat:
                @"ASBD 不一致 bpf=%u 期望=%u inter=%d",
                (unsigned)asbd->mBytesPerFrame, (unsigned)expectBpf, (int)nonInterleaved];
            return NULL;
        }
    }

    // 用摄像头真实 ASBD 校准输出格式。
    // 缓存必须带「数据源」维度：RTSP 和本地切换时采样率可能相同，
    // 只比 rate/ch 会跳过重配，导致新源沿用旧源格式。
    static double sLastRate = 0;
    static int sLastCh = 0;
    static int sLastKind = -1;                 // 0 = RTSP，1 = 本地
    int kind = useRTSP ? 0 : 1;
    if (sLastRate != asbd->mSampleRate || sLastCh != (int)ch || sLastKind != kind) {
        if (useRTSP) [src configureAudioSampleRate:asbd->mSampleRate channels:(int)ch];
        else         [localAudio configureSampleRate:asbd->mSampleRate channels:(int)ch];
        sLastRate = asbd->mSampleRate;
        sLastCh = (int)ch;
        sLastKind = kind;
    }

    CMItemCount numSamples = CMSampleBufferGetNumSamples(in);
    if (numSamples > 16384) {           // 48k 下 16384 帧≈341ms，真实音频缓冲不会这么大
        if (reasonOut) *reasonOut = @"样本数异常";
        return NULL;
    }
    if (numSamples <= 0) { if (reasonOut) *reasonOut = @"帧数为0"; return NULL; }

    // 按摄像头格式组织 PCM（交错/非交错都支持）

size_t perPlane = (size_t)numSamples * bytesPerSample;
    size_t total = perPlane * ch;
    uint8_t *raw = (uint8_t *)calloc(1, total);
    if (!raw) { if (reasonOut) *reasonOut = @"内存不足"; return NULL; }

    int outCh = useRTSP ? (int)[src audioChannels] : 2;   // 本地音频固定双声道
    if (outCh < 1 || outCh > 8) outCh = 1;
    // 原版全程 float32：App 要 float 且源是 RTSP 时，直接拷浮点，不做 S16 往返
    BOOL directFloat = (useRTSP && isFloat);

    int16_t *pcm = directFloat ? NULL
                               : (int16_t *)calloc((size_t)numSamples * outCh, sizeof(int16_t));
    float *flt = directFloat ? (float *)calloc((size_t)numSamples * outCh, sizeof(float)) : NULL;
    if ((!pcm && !directFloat) || (directFloat && !flt)) {
        free(raw); free(pcm); free(flt);
        if (reasonOut) *reasonOut = @"内存不足";
        return NULL;
    }

    UInt32 got = 0;
    if (directFloat)  got = (UInt32)[src copyAudioFloat:flt maxFrames:(NSUInteger)numSamples];
    else if (useRTSP) got = (UInt32)[src copyAudioS16:pcm maxFrames:(NSUInteger)numSamples];
    else              got = (UInt32)[localAudio readS16:pcm maxFrames:(NSUInteger)numSamples];
    (void)got;

    for (CMItemCount f = 0; f < numSamples; f++) {
        float fl = directFloat ? flt[f * outCh] : (pcm[f * outCh] / 32768.0f);
        float fr = directFloat ? ((outCh > 1) ? flt[f * outCh + 1] : fl)
                               : ((outCh > 1) ? (pcm[f * outCh + 1] / 32768.0f) : fl);
        for (UInt32 c = 0; c < ch; c++) {
            float v = (c == 0) ? fl : (c == 1 ? fr : 0.0f);
            uint8_t *dst = nonInterleaved
                ? raw + (size_t)c * perPlane + (size_t)f * bytesPerSample
                : raw + ((size_t)f * ch + c) * bytesPerSample;
            if (isFloat) ((float *)dst)[0] = v;
            else {
                float t = v;
                if (t > 1.0f) t = 1.0f; else if (t < -1.0f) t = -1.0f;
                ((int16_t *)dst)[0] = (int16_t)(t * 32767.0f);
            }
        }
    }
    free(pcm);
    free(flt);

    // 包成 CMBlockBuffer
    CMBlockBufferRef block = NULL;
    OSStatus bs = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, total,
                                                     kCFAllocatorDefault, NULL, 0, total,
                                                     kCMBlockBufferAssureMemoryNowFlag, &block);
    if (bs != noErr || !block) {
        free(raw);
        if (reasonOut) *reasonOut = [NSString stringWithFormat:@"造block失败 st=%d", (int)bs];
        return NULL;
    }
    // 原版 0x333010-0x33304c：GetDataPointer 后先 bzero 再填（防御性清零）
    {
        char *dst = NULL;
        size_t lenAtOffset = 0, totalLen = 0;
        if (CMBlockBufferGetDataPointer(block, 0, &lenAtOffset, &totalLen, &dst) == noErr && dst) {
            if (totalLen >= total) bzero(dst, total);
        }
    }
    CMBlockBufferReplaceDataBytes(raw, block, 0, total);
    free(raw);

    // 造新的音频 sample buffer（照抄原版这一步）
    // 原版 0x3330b0-0x3330f4：先 GetPresentationTimeStamp，flags 无效再取
    // GetOutputPresentationTimeStamp；仍然无效就放弃替换（返回 NULL）。
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(in);
    if (!CMTIME_IS_VALID(pts)) pts = CMSampleBufferGetOutputPresentationTimeStamp(in);
    if (!CMTIME_IS_VALID(pts)) {
        if (reasonOut) *reasonOut = @"输入时间戳无效（原版此处也放弃替换）";
        CFRelease(block);      // raw 已在上面释放，不能再 free
        return NULL;
    }
    // 原版 0x33312c–0x333138：用 Ready API 建缓冲（packetDescriptions = NULL）
    CMSampleBufferRef outBuf = NULL;
    OSStatus st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        kCFAllocatorDefault, block, fd, numSamples, pts, NULL, &outBuf);
    CFRelease(block);
    if (st != noErr || !outBuf) {
        if (reasonOut) *reasonOut = [NSString stringWithFormat:@"重建缓冲失败 st=%d", (int)st];
        return NULL;
    }

    // 原版 0x33315c–0x333188：复制输入缓冲的附件到新缓冲。
    // 缺这一步时，抖音在直播/录制路径会丢弃该缓冲 → 没有源声音。
    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, in,
                                                        kCMAttachmentMode_ShouldPropagate);
    if (atts) {
        CMSetAttachments(outBuf, atts, kCMAttachmentMode_ShouldPropagate);
        CFRelease(atts);
    }

    return outBuf;
}

@interface BXCaptureBridge () <AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) BXVideoSource *source;
@property (nonatomic, strong) BXFFmpegRTSP *rtsp;
@property (nonatomic, strong) BXLocalAudio *localAudio;
@property (atomic, strong) NSDictionary *snapshot;
@property (atomic, assign) BOOL installed;
@property (atomic, assign) NSUInteger hookedCount;
@property (atomic, assign) NSUInteger replacedFrames;
@property (atomic, assign) NSUInteger passthroughFrames;
@property (atomic, assign) NSUInteger capturedOutputs;
// 摄像头回调里我们自己的耗时（毫秒，累计）与转换次数
@property (atomic, assign) double passWorkMs;
@property (atomic, assign) NSUInteger convCount;

@property (nonatomic, assign) NSUInteger attemptFrames;
@property (nonatomic, assign) NSUInteger audioReplaced;
@property (atomic, assign) NSUInteger replaceFPS;
@property (atomic, assign) double latencyMs;   // 端到端延迟（毫秒）
@property (atomic, assign) NSUInteger audioCallbacks;
@property (atomic, copy) NSString *audioFailReason;
@property (atomic, assign) NSUInteger audioBlitOK;
@property (atomic, assign) NSUInteger passBlitFail;
@property (atomic, assign) NSUInteger passNoFrame;
@property (atomic, assign) NSUInteger passGate;
@property (atomic, copy) NSString *gateReason;
@property (atomic, copy) NSString *buildError;
@end

// ── 采集中断 / App 前后台 ──
// 来电、闹钟、其它 App 抢摄像头时会发 AVCaptureSessionWasInterrupted；
// 此时采集已经停了，我们还继续往旧帧里写就是白烧 CPU（严重时被系统杀掉）。
static BOOL gBXCaptureInterrupted = NO;

// 统一地址格式：
//   - 去掉首尾空白/换行（从别处粘贴常带）
//   - 没写 scheme 的补 rtsp://（"user:pass@192.168.1.4:8554/live/1" 也能用）
//   - 凭据（user:pass@）原样交给 FFmpeg，它会自己做 Basic/Digest 认证
static NSString *BXNormalizeRTSPURL(NSString *raw) {
    if (!raw.length) return nil;
    NSString *u = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!u.length) return nil;
    if ([u rangeOfString:@"://"].location == NSNotFound) {
        u = [@"rtsp://" stringByAppendingString:u];
    }
    return u;
}

// 原版 0x4a836c：「首个会话生效」闩锁，自动开流只做一次。
static BOOL gAutoStartDone = NO;


@implementation BXCaptureBridge

+ (void)load { }

- (void)bxInstallLifecycleObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:@"AVCaptureSessionWasInterruptedNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        gBXCaptureInterrupted = YES;
        BXLog(@"[BXFloat][vcam] 采集中断：%@", n.userInfo ?: @{});
    }];

    [nc addObserverForName:@"AVCaptureSessionInterruptionEndedNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        gBXCaptureInterrupted = NO;
        // 恢复后 PTS 会跳变，两个源都要重新对时，否则会快进/卡住
        [self.rtsp resetTimeline];
        [self.source resetTimeline];
        BXLog(@"[BXFloat][vcam] 采集中断结束，已重置时间基准");
    }];

    // 【已移除】退后台停流 / 回前台自动重开流 这两个监听。
    // 原版没有任何 App 生命周期代码：它既不在后台停流，也不在回到前台时重开。
    // 我们这套"后台停、前台开"会与采集会话重建撞在一起（实测就是"退出再进来卡死"）。
    // 现在拉流只在两处发生：面板手动连流、以及会话首个生效时的那一次自动开流。


}
+ (instancetype)shared {
    static BXCaptureBridge *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [BXCaptureBridge new]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        [self bxInstallLifecycleObservers];
        _source = [BXVideoSource new];
        _rtsp = [BXFFmpegRTSP new];
        _localAudio = [BXLocalAudio new];
        _enabled = NO;
        _audioReplace = YES;  // 与百相一致
        _installed = NO;
    }
    return self;
}

#pragma mark - 视频源

- (NSString *)sourcePath { return self.source.path; }

- (BOOL)loop   { return self.source.loop; }
- (void)setLoop:(BOOL)v { self.source.loop = v; }
- (BOOL)mirror { return self.rtsp.isRunning ? self.rtsp.mirror : self.source.mirror; }
- (void)setMirror:(BOOL)v { self.source.mirror = v; self.rtsp.mirror = v; }
- (NSInteger)rotation { return self.rtsp.isRunning ? self.rtsp.rotation : self.source.rotation; }
- (void)setRotation:(NSInteger)v { self.source.rotation = v; self.rtsp.rotation = v; }

// 让摄像头按源的帧率出帧，消除 24-on-30 的 33/66 抖动。
// 关掉时恢复系统默认（1/30 ~ 1/60）。失败就静默放弃，绝不打断采集。
- (void)resetStats {
    self.replacedFrames = 0;
    self.passthroughFrames = 0;
    self.attemptFrames = 0;
    self.replaceFPS = 0;
    self.passGate = 0;
    self.passNoFrame = 0;
    self.passBlitFail = 0;
    self.replacedFrames = 0;
    self.audioReplaced = 0;
}

- (BOOL)useRTSPURLString:(NSString *)urlString error:(NSError **)error {
    // 【B81】不安装 AudioUnitRender 钩子：原版从不碰这个函数（只导入 AudioUnitGetProperty/AudioComponent*），
    // 我们用 fishhook 改了它，每 ~10ms 被调一次且一直 audio=0（占了路径没产出）。
    BXAudioUnitHookInstall();   // B83：照原版重绑 Render + SetProperty，抓真实格式后再填数据
    // 原版 0x330aa0 捕获的布尔就是 loop（见 0x33166c 的日志 "stream opened ... loop=%d"）
    id lp = [[BXFloatStore shared] objectForKey:@"rtsp.loop"];
    self.rtsp.loopPlayback = [lp isKindOfClass:[NSNumber class]] ? [lp boolValue] : YES;

    NSString *u = BXNormalizeRTSPURL(urlString);
    if (!u.length) return NO;
    urlString = u;
    [self resetStats];
    BOOL ok = [self.rtsp startWithURLString:urlString error:error];
    if (ok) BXLog(@"[BXFloat][vcam] RTSP 已连接 %@", urlString);
    return ok;
}

// 【照原版 0x330aa0 的语义】会话重启（回前台重建、delegate 重设）后：
//   流没在跑 → 重新开流；流还在跑 → 什么都不做。
// 原版靠 0x4a836c 闩锁 + url/flag 判断；我们这里用「流是否在跑」判断，
// 效果一致：断了才重连，没断不动。
- (void)ensureStreamAfterSessionEvent {
    if (self.rtsp.isRunning) return;
    NSString *url = [[BXFloatStore shared] objectForKey:@"rtsp_url"];
    NSNumber *en  = [[BXFloatStore shared] objectForKey:@"rtsp.enabled"];
    if (en && !en.boolValue) return;
    if (![url isKindOfClass:[NSString class]] || !url.length) return;
    NSString *u = [url copy];
    self.enabled = YES;
    // 延后 0.4s：会话刚重建时相机还在起，立刻开流会抢资源
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        [self useRTSPURLString:u error:&e];
        BXLog(@"[BXFloat][vcam] 会话重建后自动开流 → %@ %@", @(self.rtsp.isRunning), e ?: @"ok");
    });
}
- (BOOL)isStreaming { return self.rtsp.isRunning; }

- (NSString *)rtspURL { return self.rtsp.urlString; }

// 每秒重建一次快照：所有跨线程会变的值都在这里"拷一份"。
// 面板只读这个不可变字典，不再直接访问 gateReason / audioFailReason 这类活对象。
- (void)rebuildSnapshot {
    static NSTimeInterval lastBuild = 0;
    NSTimeInterval now = CACurrentMediaTime();
    if (lastBuild > 0 && now - lastBuild < 1.0) return;
    lastBuild = now;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"outputs"]     = self.seenOutputsText ?: @"?";
    d[@"sessionOut"]  = self.sessionOutputsText ?: @"?";
    d[@"readFPS"]      = @((unsigned long)self.readFPS);
    d[@"decodeFPS"]    = @((unsigned long)self.decodeFPS);
    d[@"replaceFPS"]   = @((unsigned long)self.replaceFPS);
    d[@"slotFillFPS"]  = @((unsigned long)self.slotFillFPS);
    d[@"declaredFPS"]  = @((double)self.streamDeclaredFPS);
    d[@"readMs"]       = @((unsigned long)self.readBlockMs);
    d[@"gapStalls"]    = @((unsigned long)self.gapStalls);
    d[@"loopMs"]       = @((unsigned long)self.loopCostMs);
    d[@"seekN"]        = @((unsigned long)self.seekCount);
    d[@"reconnN"]      = @((unsigned long)self.reconnectCount);
    d[@"eagainN"]      = @((unsigned long)self.eagainCount);
    d[@"errN"]         = @((unsigned long)self.readErrCount);
    d[@"readSec"]      = @((unsigned long)self.readMsSec);
    d[@"feedSec"]      = @((unsigned long)self.feedMsSec);
    d[@"audioSec"]     = @((unsigned long)self.audioMsSec);
    d[@"otherSec"]     = @((unsigned long)self.otherMsSec);
    d[@"decodeBlockMs"] = @((unsigned long)self.decodeBlockMs);
    d[@"gapAvg"]       = @((long)self.gapAvgMs);
    d[@"gapMax"]       = @((long)self.gapMaxWindow);   // 用窗口快照，不是会被清零的那个
    d[@"latency"]      = @((long)self.latencyMs);
    d[@"vtErrors"]     = @((unsigned long)self.vtErrorCount);
    d[@"vtDecodeMs"]   = @((double)self.vtDecodeMs);
    d[@"swsMs"]        = @(self.rtsp.swsMsTotal);
    d[@"vtMs"]         = @(self.rtsp.vtMsTotal);
    d[@"transformMs"]  = @((double)self.lastTransformMs);
    d[@"decodeMode"]   = self.decodeMode ?: @"?";
    d[@"backend"]      = self.decodeBackend ?: @"?";
    d[@"transport"]    = self.transport ?: @"?";
    d[@"decodedFrames"] = @((unsigned long)self.decodedFrames);
    d[@"attemptFrames"] = @((unsigned long)self.attemptFrames);
    d[@"replaced"]     = @((unsigned long)self.replacedFrames);
    d[@"passthrough"]  = @((unsigned long)self.passthroughFrames);
    d[@"passGate"]     = @((unsigned long)self.passGate);
    d[@"passNoFrame"]  = @((unsigned long)self.passNoFrame);
    d[@"passBlitFail"] = @((unsigned long)self.passBlitFail);
    d[@"audioTrack"]   = @(self.audioTrackFound);
    d[@"audioCodec"]   = self.audioCodecName ?: @"?";
    d[@"audioDec"]     = @(self.audioDecoderReady);
    d[@"audioWhy"]     = self.audioFailReason ?: @"-";
    d[@"audioCb"]      = @((unsigned long)self.audioCallbacksCount);
    d[@"audioDecoded"] = @((unsigned long)self.audioDecodedFrames);
    d[@"audioBlitOK"]  = @((unsigned long)self.audioBlitOKCount);
    d[@"underruns"]    = @((unsigned long)self.audioUnderruns);
    d[@"underFrames"]  = @((unsigned long)self.audioUnderrunFrames);
    d[@"mirror"]       = @(self.mirror);
    d[@"rotation"]     = @((long)self.rotation);
    d[@"audioReplace"] = @(self.audioReplace);
    d[@"loop"]         = @(self.loop);
    d[@"installed"]    = @(self.installed);
    d[@"enabled"]      = @(self.enabled);
    d[@"captured"]     = @((unsigned long)self.capturedOutputs);
    d[@"passWorkMs"]   = @(self.passWorkMs);
    d[@"convCount"]    = @((unsigned long)self.convCount);
    d[@"setterV"]      = @((unsigned long)self.setterVideoCalls);
    d[@"setterA"]      = @((unsigned long)self.setterAudioCalls);
    d[@"dhooked"]      = @((unsigned long)self.delegateHooked);
    d[@"hooked"]       = @((unsigned long)self.hookedCount);
    d[@"gateReason"]   = self.gateReason ?: @"-";
    d[@"frameReason"]  = self.streamFrameReason ?: @"-";
    d[@"buildError"]   = self.buildError ?: @"-";
    d[@"diagnosis"]    = self.diagnosis ?: @"-";
    d[@"url"]          = self.rtspURL ?: (self.sourcePath ?: @"-");

    self.snapshot = [d copy];      // 原子替换：读到的永远是完整字典
}

- (NSUInteger)tickReplace {
    static NSTimeInterval mark = 0;
    static NSUInteger count = 0;
    count++;
    NSTimeInterval now = CACurrentMediaTime();
    if (mark == 0) { mark = now; return 0; }
    if (now - mark >= 1.0) {
        NSUInteger v = (NSUInteger)(count / (now - mark));
        count = 0;
        mark = now;
        return v;
    }
    return self.replaceFPS;
}

- (NSUInteger)decodeFPS { return self.rtsp.decodeFPS; }
- (NSUInteger)readFPS { return self.rtsp.readFPS; }
- (NSUInteger)slotFillFPS { return self.rtsp.slotFillFPS; }
- (NSUInteger)readBlockMs { return self.rtsp.readBlockMs; }

- (NSUInteger)copyReplacementAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;
    if (!self.audioReplace) return 0;

    if (self.rtsp.isRunning && self.rtsp.hasAudio) {
        return [self.rtsp copyAudioS16:dst maxFrames:maxFrames];
    }
    if (self.source.loaded && [self.localAudio isLoaded]) {
        return [self.localAudio readS16:dst maxFrames:maxFrames];
    }
    return 0;
}

- (NSUInteger)gapStalls { return self.rtsp.gapStalls; }
- (NSUInteger)gapMaxWindow { return self.rtsp.gapMaxWindow; }
- (NSUInteger)loopCostMs { return self.rtsp.loopCostMs; }
- (NSUInteger)seekCount { return self.rtsp.seekCount; }
- (NSUInteger)reconnectCount { return self.rtsp.reconnectCount; }
- (NSUInteger)eagainCount { return self.rtsp.eagainCount; }
- (NSUInteger)readErrCount { return self.rtsp.readErrCount; }
- (NSUInteger)readMsSec { return self.rtsp.readMsSec; }
- (NSUInteger)feedMsSec { return self.rtsp.feedMsSec; }
- (NSUInteger)audioMsSec { return self.rtsp.audioMsSec; }
- (NSUInteger)otherMsSec { return self.rtsp.otherMsSec; }
- (NSUInteger)decodeBlockMs { return self.rtsp.decodeBlockMs; }
- (NSUInteger)audioCallbacksCount { return self.audioCallbacks; }
- (NSUInteger)audioBlitOKCount { return self.audioBlitOK; }
- (NSString *)audioFailReason { return _audioFailReason ?: @"(音频回调尚未发生)"; }
- (NSUInteger)audioDecodedFrames { return self.rtsp.audioDecodedFrames; }
- (NSUInteger)audioUnderruns { return self.rtsp.audioUnderruns; }
- (NSUInteger)audioUnderrunFrames { return self.rtsp.audioUnderrunFrames; }
- (NSUInteger)readStalls { return self.rtsp.readStalls; }
- (double)gapAvgMs { return self.rtsp.gapAvgMs; }
- (double)gapMaxMs { return self.rtsp.gapMaxMs; }
- (double)vtDecodeMs { return self.rtsp.vtDecodeMs; }
- (NSString *)decodeMode { return self.rtsp.decodeMode; }
- (NSString *)decodeBackend { return self.rtsp.decodeBackend; }
- (double)probeReadFPS { return self.rtsp.probeReadFPS; }
- (NSString *)diagnosis { return [self.rtsp diagnosis]; }
- (NSString *)transport { return self.rtsp.transport; }
- (void)setPreferUDP:(BOOL)v { self.rtsp.preferUDP = v; }
- (BOOL)preferUDP { return self.rtsp.preferUDP; }
- (BOOL)audioTrackFound { return self.rtsp.audioTrackFound; }
- (BOOL)audioDecoderReady { return self.rtsp.audioDecoderReady; }
- (double)streamDeclaredFPS { return self.rtsp.streamDeclaredFPS; }
- (NSString *)audioCodecName { return self.rtsp.audioCodecName; }
- (NSUInteger)vtErrorCount { return self.rtsp.vtErrorCount; }
- (double)lastTransformMs { return self.rtsp.lastTransformMs; }
- (BOOL)hardwareDecoding { return self.rtsp.hardwareDecoding; }

- (BOOL)hasOwnAudio { return self.rtsp.hasAudio || self.localAudio.isLoaded; }

- (NSUInteger)decodedFrames { return self.rtsp.decodedFrames; }
- (NSString *)streamFrameReason { return self.rtsp.lastReason ?: @"-"; }

// 供 AudioUnit 钩子拉取：float32 交错立体声（源 48k）
// 音频闸门用：最后一帧「新解出」的时刻（转发给 RTSP 的解码打点）。
// 之前还原文件时把实现删了、头文件声明还在 → 音频判定恒为静音，表现就是"没声音"。
- (NSTimeInterval)lastVideoTick {
    return [self.rtsp lastDecodeTick];
}

- (NSUInteger)pullAudioFloat:(float *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;
    BXFFmpegRTSP *r = self.rtsp;
    if (!r || !r.isRunning) return 0;
    return [r copyAudioFloat:dst maxFrames:maxFrames];
}

- (CVPixelBufferRef)copyPreviewFrameBGRA CF_RETURNS_RETAINED {
    return [self.rtsp copyPreviewFrameBGRA];
}

- (CVPixelBufferRef)copyLatestStreamFrame CF_RETURNS_RETAINED {
    if (self.rtsp.isRunning) return [self.rtsp copyNextFrameScaledTo:CGSizeZero];
    return NULL;
}

- (void)stopNetworkSources {
    [self.rtsp stop];
    BXLog(@"[BXFloat][vcam] 网络源已停止");
}

- (BOOL)useStreamURLString:(NSString *)urlString error:(NSError **)error {
    if (!urlString.length) return NO;
    BOOL ok = [self.rtsp startWithURLString:urlString error:error];
    if (ok) BXLog(@"[BXFloat][vcam] 流媒体源已启动 %@", urlString);
    return ok;
}

- (BOOL)useVideoAtPath:(NSString *)path error:(NSError **)error {
    if (!path.length) return NO;
    // 音轨一起载入：否则本地视频只有画面、声音还是麦克风
    @try {
        [self.localAudio loadURL:[NSURL fileURLWithPath:path] error:NULL];
    } @catch (NSException *e) {
        BXLog(@"[BXFloat][vcam] 音轨载入异常 %@", e);
    }
    return [self.source loadURL:[NSURL fileURLWithPath:path] error:error];
}

#pragma mark - 安装 hook（照原版 0x3258c4-0x325a18）

// 原版把 5 个原始 IMP 存进固定槽位，钩子里直接 blr 调用，不做任何查表。
static IMP gOrigVideoSetter  = NULL;   // 0x4a8068
static IMP gOrigAudioSetter  = NULL;   // 0x4a8070
static IMP gOrigAddOutput    = NULL;   // 0x4a8078
static IMP gOrigStartRunning = NULL;   // 0x4a8080
static IMP gOrigStopRunning  = NULL;   // 0x4a8088


static void BXDelegateCapture(id self, SEL _cmd, id output,
                              CMSampleBufferRef sbuf, id connection);


// 视频输出 setter 钩子（原版 0x32a498）：日志 → 处理 delegate → 原样传回
static void BXVideoSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    [BXCaptureBridge shared].setterVideoCalls += 1;
    BXLog(@"[BXFloat][vcam] capture video delegate output=%@ delegate=%@ queue=%p",
          NSStringFromClass([self class]),
          delegate ? NSStringFromClass([delegate class]) : @"<nil>", (__bridge void *)queue);
    BXProcessDelegate(delegate);
    if (gOrigVideoSetter) {
        ((void (*)(id, SEL, id, dispatch_queue_t))gOrigVideoSetter)(self, _cmd, delegate, queue);
    }
    // 【照原版 0x32fbb0 → 0x330aa0】抖音重设采集 delegate 时（回前台重建会话就会重设）
    // 原版会再评估一次开流；我们之前只认第一次，导致回前台后流断了也不重连。
    [[BXCaptureBridge shared] ensureStreamAfterSessionEvent];
}

// 音频输出 setter 钩子（原版 0x32a674）
static void BXAudioSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    [BXCaptureBridge shared].setterAudioCalls += 1;
    BXLog(@"[BXFloat][vcam] capture audio delegate output=%@ delegate=%@ queue=%p",
          NSStringFromClass([self class]),
          delegate ? NSStringFromClass([delegate class]) : @"<nil>", (__bridge void *)queue);
    BXProcessDelegate(delegate);
    if (gOrigAudioSetter) {
        ((void (*)(id, SEL, id, dispatch_queue_t))gOrigAudioSetter)(self, _cmd, delegate, queue);
    }
}

// 原版 0x32a7b8
// 原版 0x32a7f0：日志 → 原实现。除此之外没有任何动作。


static void BXAddOutput(id self, SEL _cmd, id output) {
    {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gSeenOutputs = [NSMutableArray array]; });
        NSString *cls = output ? NSStringFromClass([output class]) : @"<nil>";
        @synchronized (gSeenOutputs) {
            if (cls && ![gSeenOutputs containsObject:cls]) [gSeenOutputs addObject:cls];
        }
    }
    BXLog(@"[BXFloat][vcam] capture session add output=%@ session=%@",
          output ? NSStringFromClass([output class]) : @"<nil>",
          NSStringFromClass([self class]));

    if (gOrigAddOutput) ((void (*)(id, SEL, id))gOrigAddOutput)(self, _cmd, output);

}

// 原版 0x32a910
// 原版调用链（已解析到底）：
//   0x32a908 startRunning 钩子
//     → 日志 "capture session start running=%@"
//     → 原实现
//     → 0x330a04：若(flag 0x4a80a8==1 && queue 0x4a80b0) dispatch_async
//         → 0x330a30「会话开始」：活动会话计数 +1
//            · 计数非法 0→1 时打印 "capture lifecycle active sessions=%u"
//            · 且置位 0x4a80cc
//         → 0x330aa0「首个会话生效」：
//            · 已处理过(0x4a836c) → 返回
//            · 控制器为空 / 配置字符串长度为 0 → 返回
//            · (enabled 0x4a80cc || 0x4a80d0) 为真时：
//                置已处理位，复制配置字符串，取 QOS 0x19 全局队列，
//                把 {字符串, 控制器, 标志} 装进栈 block 异步执行
//            → 也就是「会话一启动就自动开始拉流」
static void BXSessionStart(id self, SEL _cmd) {
    BXLog(@"[BXFloat][vcam] capture session start running=%@", NSStringFromClass([self class]));   // 原版 0x32a908 同位置
    if (gOrigStartRunning) ((void (*)(id, SEL))gOrigStartRunning)(self, _cmd);
    // 原版 0x330a04/0x330aa0 紧随其后：状态刷新 + 首个会话生效自动开流

    // 原版 0x330aa0「首个会话生效」：闩锁只做一次，之后即使会话反复重建也不再开流。
    if (!gAutoStartDone) {
        gAutoStartDone = YES;
        BXCaptureBridge *br = [BXCaptureBridge shared];
        BXFloatStore *st = [BXFloatStore shared];
        NSString *url = [st objectForKey:@"rtsp_url"];
        NSNumber *en  = [st objectForKey:@"rtsp.enabled"];
        BOOL want = en ? en.boolValue : YES;
        if (want && [url isKindOfClass:[NSString class]] && url.length && !br.rtsp.isRunning) {
            NSString *u = [url copy];
            // 延后 1.5s：会话刚 start 时相机还在起来，立刻开流会抢资源（实测帧率掉到 0）。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [br useRTSPURLString:u error:nil];
            });
        }
    }
}

static void BXSessionStop(id self, SEL _cmd) {
    BXLog(@"[BXFloat][vcam] capture session stop running=%@", NSStringFromClass([self class]));   // 原版 0x32a9d4 同位置
    if (gOrigStopRunning) ((void (*)(id, SEL))gOrigStopRunning)(self, _cmd);
    // 【照原版 0x330c00 / 0x330cb0】会话停止：复位缓冲索引，关闭写帧闸门直到有新帧
    [[BXCaptureBridge shared].rtsp resetForSessionStop];
}

// 原版 0x32a9d4
// 原版 0x32a9cc：日志 → 原实现 → 0x330bd4（与 0x330a04 同形）


// 一次性迁移：旧键（bx.* 前缀）→ 原版键名。用户已存的地址/开关不会丢。
static void BXMigrateOldKeys(void) {
    BXFloatStore *st = [BXFloatStore shared];
    if ([[st objectForKey:@"bx.migrated.v2"] boolValue]) return;

    NSArray *pairs = @[
        @[@"bx.rtsp.url",      @"rtsp_url"],
        @[@"bx.rtsp.enabled",  @"rtsp.enabled"],
        @[@"bx.vcam.loop",     @"rtsp.loop"],
        @[@"bx.vcam.mirror",   @"rtsp.mirror"],
        @[@"bx.vcam.rotation", @"rtsp.rotation"],
        @[@"bx.vcam.audio",    @"rtsp.audio_mode"],
    ];
    for (NSArray *pair in pairs) {
        id v = [st objectForKey:pair[0]];
        if (v && ![st objectForKey:pair[1]]) [st setObject:v forKey:pair[1]];
    }
    // 旧键 bx.rtsp.udp（优先 UDP）与新键 prefer_tcp 语义相反
    id udp = [st objectForKey:@"bx.rtsp.udp"];
    if (udp && ![st objectForKey:@"prefer_tcp"]) {
        [st setObject:@(![udp boolValue]) forKey:@"prefer_tcp"];
    }
    [st setObject:@(YES) forKey:@"bx.migrated.v2"];
    BXLog(@"[BXFloat][vcam] 旧设置已迁移 url=%@", [st objectForKey:@"rtsp_url"] ?: @"<nil>");
}

- (NSString *)sessionOutputsText {
    if (!gSessionOutputsAtStart) return @"(no session yet)";
    @synchronized (gSessionOutputsAtStart) {
        return [gSessionOutputsAtStart componentsJoinedByString:@", "];
    }
}

- (NSString *)seenOutputsText {
    if (!gSeenOutputs) return @"(none yet)";
    @synchronized (gSeenOutputs) {
        return [gSeenOutputs componentsJoinedByString:@", "];
    }
}

#pragma mark - 看门狗（原版无重连，播久断流会永久卡住，这里自愈）

static NSTimer *gWatchdog;
static NSUInteger gWdogLastFrames;
static NSTimeInterval gWdogLastChange;
static NSTimeInterval gWdogLastRestart;

- (void)watchdogTick {
    if (!self.enabled) { gWdogLastFrames = 0; gWdogLastChange = 0; return; }
    NSString *url = self.rtspURL;
    if (!url.length) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSUInteger frames = self.rtsp.decodedFrames;

    if (frames != gWdogLastFrames) {          // 有新帧：健康
        gWdogLastFrames = frames;
        gWdogLastChange = now;
        return;
    }
    if (gWdogLastChange == 0) { gWdogLastChange = now; return; }

    BOOL dead = !self.rtsp.isRunning;
    BOOL stalled = (now - gWdogLastChange) > 8.0;

        if (dead || stalled) {
            BXLog(@"[BXFloat][wd] 拉流异常 dead=%d stalled=%d（已停用自动重开，请手动点「重新连接」）", (int)dead, (int)stalled);
        }
          // 【已停用自动重开】原版没有这条看门狗。
          // 我们版本里它会在旧连接未收干净时再开一条流，实测导致：
          //   · 录制结束再点录制无响应（两条连接抢 FFmpeg 上下文）
          //   · 预览/拉流互相打断
          // 现在只记录，不重开；断流后由用户在面板手动重连，行为可预测。
}

- (void)startWatchdog {
    if (gWatchdog) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWatchdog) return;
        __weak typeof(self) weakSelf = self;
        gWatchdog = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                   repeats:YES
                                                     block:^(NSTimer *t) {
            __strong typeof(weakSelf) s = weakSelf;
            if (s) [s watchdogTick];
        }];
    });
}

- (void)install {
    if (self.installed) return;
    BXMigrateOldKeys();

    SEL setSel = @selector(setSampleBufferDelegate:queue:);

    Class videoOut = NSClassFromString(@"AVCaptureVideoDataOutput");
    Class audioOut = NSClassFromString(@"AVCaptureAudioDataOutput");
    Class sessionCls = NSClassFromString(@"AVCaptureSession");

    Method mVideo = videoOut   ? class_getInstanceMethod(videoOut, setSel) : NULL;
    Method mAudio = audioOut   ? class_getInstanceMethod(audioOut, setSel) : NULL;
    Method mAdd   = sessionCls ? class_getInstanceMethod(sessionCls, @selector(addOutput:)) : NULL;
    Method mStart = sessionCls ? class_getInstanceMethod(sessionCls, @selector(startRunning)) : NULL;
    Method mStop  = sessionCls ? class_getInstanceMethod(sessionCls, @selector(stopRunning)) : NULL;

    if (!mVideo || !mAudio || !mAdd || !mStart || !mStop) {
        BXLog(@"[BXFloat][vcam] capture probe unavailable: required method missing");
        return;
    }

    gOrigVideoSetter  = method_setImplementation(mVideo, (IMP)BXVideoSetSampleBufferDelegate);
    gOrigAudioSetter  = method_setImplementation(mAudio, (IMP)BXAudioSetSampleBufferDelegate);
    // addOutput 不装（没用途）。start/stop 只用于「感知会话重建」，
    // 在那一刻暂停写帧，避免与录制编码器互等（这才是录制卡死的真正原因）。
    gOrigStartRunning = method_setImplementation(mStart, (IMP)BXSessionStart);
    gOrigStopRunning  = method_setImplementation(mStop,  (IMP)BXSessionStop);
    (void)mAdd;


    self.hookedCount = 2;   // 只装了两个 setSampleBufferDelegate
    self.installed = YES;
    BXLog(@"[BXFloat][vcam] capture probe installed video_delegate audio_delegate "
          "session_output session_start_stop audio_backend=avcapture_delegate");
    // 【诊断 B29】停用看门狗（2 秒一次的主线程定时器，之前从没被单独测过）
}

- (CMSampleBufferRef)processBuffer:(CMSampleBufferRef)sampleBuffer output:(id)output {

    BOOL isVideo = [output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")];
    BOOL hasAnySource = self.rtsp.isRunning || self.source.loaded;

    if (isVideo) {
        if (!self.enabled)       self.gateReason = @"enabled = NO";
        else if (!hasAnySource)  self.gateReason = @"没有任何可用来源";
        else                     self.gateReason = @"ok";
    }

    // 音频：拍摄页里抖音不产生音频采集回调（实测 音频回调=0），
    // 原版同样是这个架构，因此这一段只在「有音频回调」的场景（如直播）才生效。
    // 音频：照抄百相 —— 造一个新的音频 sample buffer 顶替原始帧，而不是改内存。
    CMSampleBufferRef replacedAudio = NULL;
    if (!isVideo && self.enabled && self.audioReplace &&
        (self.rtsp.isRunning || self.source.loaded)) {
        @try {
            self.audioCallbacks += 1;
            NSString *why = nil;
            CMSampleBufferRef nb = BXMakeAudioBuffer(sampleBuffer, self.rtsp, self.localAudio, &why);
            if (nb) {
                replacedAudio = nb;
                self.audioBlitOK += 1;
                self.audioReplaced += 1;
                self.audioFailReason = @"已替换音频帧";
            } else {
                self.audioFailReason = why ?: @"未知原因";
                static NSUInteger failN = 0;
                failN += 1;
                if (failN == 1 || failN % 120 == 0) {
                    BXLog(@"[BXFloat][vcam] audio replace failed #%lu: %@",
                          (unsigned long)failN, self.audioFailReason);
                }
            }
        } @catch (NSException *e) {
            BXLog(@"[BXFloat][vcam] 音频替换异常 %@", e);
        }
    }

    if (gBXCaptureInterrupted) {          // 采集已停：别再往旧帧里写
        return replacedAudio;
    }

    if (isVideo && self.enabled && hasAnySource) {
        self.attemptFrames += 1;
        CFTimeInterval _tPass = CACurrentMediaTime();

        // 百相的做法：不造新 sample buffer，直接把像素写进摄像头这一帧。
        // 这样格式/attachments/时间戳天生一致，交给 App 的仍是它自己的 buffer。
        @try {
            CVImageBufferRef camPx = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (camPx) {
                CGSize target = CGSizeMake(CVPixelBufferGetWidth(camPx),
                                           CVPixelBufferGetHeight(camPx));
                OSType camFmt = CVPixelBufferGetPixelFormatType(camPx);
                static int sCamLogged = 0;
                if (sCamLogged < 3) {
                    sCamLogged++;
                    BXLog(@"[BXFloat][vcam] 摄像头缓冲 fmt=%u %zux%zu",
                          camFmt, CVPixelBufferGetWidth(camPx), CVPixelBufferGetHeight(camPx));
                }
                // 两条来源分支都要用，声明放在分支外
                CMTime camPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

                CVPixelBufferRef mine = NULL;
                BOOL renderedDirect = NO;

                if (self.rtsp.isRunning) {
                    // 原版做法（0x32ff78）：VT 把槽位帧写进 app 的摄像头缓冲，再转发原样本。
                    // 样本替换那条路已证明会撞 -12743 InvalidMediaFormat，原版也不这么做。
                    renderedDirect = [self.rtsp renderLatestInto:camPx];
                    if (renderedDirect) {
                        self.replacedFrames += 1;
                        self.replaceFPS = [self tickReplace];
                    } else {
                        self.passNoFrame += 1;
                        self.passthroughFrames += 1;
                    }
                }

                // 【移除 CPU 兜底】VT 写不进去就直通，绝不去锁抖音的像素缓冲：
                // BXBlitInto 需要 CVPixelBufferLockBaseAddress(camPx)，而录制/会话重建时
                // 那块缓冲正被编码器持有 → 这把锁会无限等待 → 整机冻死（实测 2.5ms/帧正常，
                // 一旦 VT 失败就掉进这条死路）。
                if (!renderedDirect) {
                    self.passNoFrame += 1;
                    self.passthroughFrames += 1;
                }

                self.passWorkMs += (CACurrentMediaTime() - _tPass) * 1000.0;
            }
        } @catch (NSException *e) {
            BXLog(@"[BXFloat][vcam] 写入异常 %@", e);
            self.buildError = @"写入异常";
        }
    } else if (isVideo) {
        self.passGate += 1;
        self.passthroughFrames += 1;
    }

    // 视频是就地改像素 → 转发原始帧；音频是新建帧 → 转发替换后的帧
    return replacedAudio;
}

#pragma mark - 音频回调（直通）
// 注意: 音视频 delegate 用的是同一个 selector
// captureOutput:didOutputSampleBuffer:fromConnection:，
// 上面的实现已经同时服务两者 —— 音频帧不替换，原样转发。

#pragma mark - 造帧

@end
