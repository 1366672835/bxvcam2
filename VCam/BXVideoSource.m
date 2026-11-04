//
//  BXVideoSource.m
//

#import "BXVideoSource.h"
#import "BXConfig.h"
#import "BXColorSpace.h"
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>

static void *kBXPoolKey = &kBXPoolKey;

@interface BXVideoSource ()
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) CVPixelBufferPoolRef pool;
@property (nonatomic, assign) CVPixelBufferRef lastFrame;   // 保留上一帧做冻结/缩放源
@end

@implementation BXVideoSource {
    CGSize _size;
    BOOL _loaded;
    CGFloat _duration;
    NSString *_path;

    // 按 PTS 选帧用的状态
    CVPixelBufferRef _pending;      // 已解码、还没到播放时间的一帧
    double _pendingPTS;
    double _firstPTS;
    CFTimeInterval _startHost;
    BOOL _hasPTS;
    double _camBasePTS;             // 摄像头 PTS 基准

    // 摄像头格式对齐（解码直接出 NV12）
    OSType _camFmt;
    size_t _camW, _camH;
    OSType _readerFmt;              // 当前 reader 实际使用的格式

    // 像素缓冲池
    CVPixelBufferPoolRef _pool;
    OSType _poolFmt;
    size_t _poolW, _poolH;

    // 单槽交接：解码线程写、采集线程取，永不排队
    CVPixelBufferRef _slot;
    CVPixelBufferRef _lastShown;
    CGSize _targetSize;
    BOOL _slotDirty;
    double _cameraPTS;
    BOOL _cameraPTSValid;
    NSUInteger _shownFrames;
    NSThread *_decodeThread;
    BOOL _decodeThreadAlive;
    BOOL _stopRequested;
}

@synthesize loaded = _loaded;
@synthesize duration = _duration;
@synthesize path = _path;

- (instancetype)init {
    if (self = [super init]) {
        _lock = [NSLock new];
        _loop = YES;
        _mirror = NO;
        _rotation = 0;
    }
    return self;
}

- (void)dealloc {
    [self unload];
}

#pragma mark - 加载

- (void)resetTimeline {
    [self.lock lock];
    // 中断前解码好、还没上屏的那帧要一起丢掉：
    // PTS 一重置它就立刻"到期"，会先闪一下中断前的旧画面。
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    _hasPTS = NO;
    _firstPTS = 0;
    _pendingPTS = 0;
    _camBasePTS = 0;
    _startHost = 0;
    [self.lock unlock];
}

- (void)prepareForCameraFormat:(OSType)fmt width:(size_t)w height:(size_t)h {
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return;
    BOOL changed = (_camFmt != fmt || _camW != w || _camH != h);
    _camFmt = fmt; _camW = w; _camH = h;
    // reader 已按别的格式开着 → 重开一次，让解码直接出摄像头格式。
    // 这行日志用来确认「切前后摄到底会不会触发重建」：
    // 多数 iPhone 的相机输出恒为 420f，尺寸也不变，那样根本不会进这个分支。
    if (changed && self.loaded && _readerFmt != fmt) {
        BXLog(@"[BXFloat][vsrc] 重建 reader 格式 %08x -> %08x 尺寸 %zux%zu",
              (unsigned)_readerFmt, (unsigned)fmt, w, h);
        NSString *path = _path;
        if (path.length) {
            NSError *e = nil;
            [self loadURL:[NSURL fileURLWithPath:path] error:&e];
        }
    }
}

// reviewer 指出的关键点：循环时 _restartReaderLocked 也必须用同一套格式，
// 否则第一遍 NV12（零拷贝），循环后变 BGRA（多吃一次 CIContext 转换）→ 变卡、颜色偏。
- (NSDictionary *)_readerSettings {
    // 摄像头格式优先：_readerFmt 只是「当前实际用了什么」的记录，
    // 拿它当首选会导致 prepareForCameraFormat 切格式时重建出来的 reader 还是旧格式，
    // 于是桥里又要用 CIContext 全画幅转换一次（慢路径复活）。
    OSType pf = _camFmt ? _camFmt
                        : (_readerFmt ? _readerFmt : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (pf != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        pf != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        pf = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;   // 只支持这两种
    }
    _readerFmt = pf;
    return @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pf),
        @"EnableHardwareAcceleratedVideoDecoder": @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
}

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error {
    if (!url) return NO;
    [self unload];

    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"BXVideoSource" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有视频轨"}];
        return NO;
    }
    AVAssetTrack *track = tracks.firstObject;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        if (error) *error = err;
        return NO;
    }

    // 直接按摄像头格式解码（420f/420v）：AVAssetReader 走硬解就能直接出 NV12，
    // 省掉「BGRA 解码 → CIContext 转 420f」那一次全画幅转换。
    NSDictionary *settings = [self _readerSettings];
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) {
        if (error) *error = [NSError errorWithDomain:@"BXVideoSource" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法添加输出"}];
        return NO;
    }
    [reader addOutput:out];

    if (![reader startReading]) {
        if (error) *error = reader.error;
        return NO;
    }

    self.asset = asset;
    self.reader = reader;
    self.output = out;

    // 启动后台解码线程（每个源一个，随 unload 退出）
    _stopRequested = NO;
    if (!_decodeThread && !_decodeThreadAlive) {
        _decodeThread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(_decodeThreadMain)
                                                  object:nil];
        _decodeThread.name = @"bx.vsrc.decode";
        _decodeThread.qualityOfService = NSQualityOfServiceUserInitiated;
        [_decodeThread start];
    }
    _size = track.naturalSize;
    _duration = CMTimeGetSeconds(asset.duration);
    _path = url.path;
    _loaded = YES;

    BXLog(@"[BXFloat][vcam] 已加载视频 %@ %.0fx%.0f 时长 %.1fs",
          url.lastPathComponent, _size.width, _size.height, _duration);
    return YES;
}

- (void)unload {
    // 顺序很关键：先让解码线程停下，再动 reader/output，
    // 否则线程可能正卡在 copyNextSampleBuffer 里，我们却把它用的对象释放了。
    [self.lock lock];
    _stopRequested = YES;
    [self.lock unlock];

    for (int i = 0; i < 50 && _decodeThreadAlive; i++) usleep(10 * 1000);   // 最多等 500ms

    [self.lock lock];
    _decodeThread = nil;

    if (self.reader) { [self.reader cancelReading]; }
    self.output = nil;
    self.reader = nil;
    self.asset = nil;

    if (_slot) { CVPixelBufferRelease(_slot); _slot = NULL; }
    if (_lastShown) { CVPixelBufferRelease(_lastShown); _lastShown = NULL; }
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; _poolFmt = 0; _poolW = _poolH = 0; }

    _hasPTS = NO;
    _firstPTS = 0;
    _pendingPTS = 0;
    _camBasePTS = 0;
    _startHost = 0;
    _cameraPTSValid = NO;
    _cameraPTS = 0;
    _slotDirty = YES;
    _shownFrames = 0;
    _loaded = NO;
    [self.lock unlock];
}

- (BOOL)loaded { return _loaded; }
- (CGSize)size { return _size; }
- (CGFloat)duration { return _duration; }
- (NSString *)path { return _path; }

- (void)rewind {
    [self.lock lock];
    [self _restartReaderLocked];
    [self.lock unlock];
}

- (void)_restartReaderLocked {
    if (!self.asset) return;
    if (self.reader) {
        [self.reader cancelReading];
    }
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:&err];
    if (!reader) { BXLog(@"[BXFloat][vcam] 重建 reader 失败 %@", err); return; }

    NSArray<AVAssetTrack *> *tracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return;

    NSDictionary *settings = [self _readerSettings];
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) return;
    [reader addOutput:out];
    if (![reader startReading]) return;

    self.reader = reader;
    self.output = out;
}

#pragma mark - 取帧

#pragma mark - 取帧（消费者：只取槽里的帧，绝不等待）

// 采集线程调这里：只做三件事——记下摄像头 PTS、取走槽里的帧、没有就复用上一帧。
// 解码、缩放、镜像、旋转全部在后台线程完成，采集线程不会被任何 IO 阻塞。
- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS
                                 scaledTo:(CGSize)targetSize {
    if (!self.loaded) {
        [self.lock lock];
        CVPixelBufferRef keep = _lastShown ? CVPixelBufferRetain(_lastShown) : NULL;
        [self.lock unlock];
        return keep;
    }

    // 目标尺寸变了：告诉解码线程（它自己会重建变换结果）
    if (targetSize.width >= 2 && targetSize.height >= 2) {
        [self.lock lock];
        BOOL changed = !CGSizeEqualToSize(_targetSize, targetSize);
        if (changed) {
            _targetSize = targetSize;
            _slotDirty = YES;          // 必须在锁内写，解码线程也会读它
        }
        [self.lock unlock];
    }

    // 摄像头 PTS 交给解码线程做节奏控制
    if (CMTIME_IS_VALID(cameraPTS)) {
        double sec = CMTimeGetSeconds(cameraPTS);
        [self.lock lock];
        _cameraPTS = sec;
        _cameraPTSValid = YES;
        [self.lock unlock];
    }

    CVPixelBufferRef out = NULL;
    [self.lock lock];
    if (_slot) {                       // 有新帧：取走（槽位清空，永不排队）
        out = _slot;
        _slot = NULL;
        if (_lastShown) CVPixelBufferRelease(_lastShown);
        _lastShown = CVPixelBufferRetain(out);
    } else if (_lastShown) {           // 没新帧：复用上一帧，绝不返回 NULL
        out = CVPixelBufferRetain(_lastShown);
    }
    [self.lock unlock];
    return out;
}

#pragma mark - 解码线程

- (BOOL)_stopRequestedLocked {
    [self.lock lock];
    BOOL stop = _stopRequested;
    [self.lock unlock];
    return stop;
}

- (void)_decodeThreadMain {
    [self.lock lock];
    _decodeThreadAlive = YES;
    [self.lock unlock];

    // 节奏：只按摄像头 PTS 走。超前就等，落后就丢，取不到就沿用上一帧。
    while (![self _stopRequestedLocked]) {
        @autoreleasepool {
            [self _decodeOneStep];
        }
        usleep(2000);   // 2ms 一轮：足够跟 30/60fps，又不至于空转烧 CPU
    }

    // 必须复位：否则换片时会把「线程已退出」误判成「还在跑」
    [self.lock lock];
    _decodeThreadAlive = NO;
    [self.lock unlock];
}

- (void)_decodeOneStep {
    // 第一件事：把要用的东西在锁内拷成局部变量，然后立刻放锁。
    // copyNextSampleBuffer 是真解码（5~15ms），必须在锁外调用 ——
    // 否则采集线程照样排在这把锁后面等解码，等于没解决卡顿。
    [self.lock lock];
    BOOL loaded = self.loaded;
    BOOL dirty = _slotDirty;
    CGSize target = _targetSize;
    double camPTS = _cameraPTS;
    BOOL camValid = _cameraPTSValid;
    BOOL needDecode = (_pending == NULL);
    AVAssetReaderTrackOutput *out = self.output;      // 局部强引用，锁外使用安全
    BOOL loopFlag = self.loop;
    [self.lock unlock];

    if (!loaded || !out) return;

    if (dirty) {
        [self.lock lock];
        _slotDirty = NO;
        _hasPTS = NO;
        _firstPTS = 0;
        _pendingPTS = 0;
        _camBasePTS = camValid ? camPTS : 0;
        _startHost = 0;
        [self.lock unlock];
    }

    // ── 锁外解码 ──
    if (needDecode) {
        CMSampleBufferRef sb = [out copyNextSampleBuffer];
        if (!sb) {
            if (loopFlag) {
                [self.lock lock];
                if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
                [self _restartReaderLocked];
                _hasPTS = NO;
                _firstPTS = 0;
                _pendingPTS = 0;
                _camBasePTS = camValid ? camPTS : 0;
                _startHost = 0;
                [self.lock unlock];
            }
            return;
        }
        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));

        [self.lock lock];
        if (!_hasPTS) { _firstPTS = pts; _hasPTS = YES; }
        if (img) {
            if (_pending) CVPixelBufferRelease(_pending);
            _pending = (CVPixelBufferRef)CVBufferRetain(img);
            _pendingPTS = pts - _firstPTS;
        }
        [self.lock unlock];
        CFRelease(sb);
    }

    [self.lock lock];
    // 必须 retain：解锁之后 unload（主线程）可能把 _pending 释放掉，
    // 我们手里只剩野指针，崩在 _transformAny 里。
    CVPixelBufferRef pending = _pending ? CVPixelBufferRetain(_pending) : NULL;
    double pendingPTS = _pendingPTS;
    BOOL hasBase = (camValid && _camBasePTS > 0);
    double base = _camBasePTS;
    [self.lock unlock];

    if (!pending) return;

    // ── 节奏：只用摄像头 PTS ──
    double elapsed;
    if (hasBase) {
        elapsed = camPTS - base;
        if (elapsed < -0.5) elapsed = 0;           // PTS 跳变：按 0 处理
    } else {
        // 摄像头 PTS 不可用时退回主机时钟。
        // 绝不能用 pendingPTS 当 elapsed —— 那等于「永远到点」，
        // 每 2ms 解一帧，视频几秒钟就播完。
        if (_startHost == 0) _startHost = CACurrentMediaTime();
        elapsed = CACurrentMediaTime() - _startHost;
    }

    if (pendingPTS > elapsed + 0.005) {            // 还没到时间：槽里保持不动
        CVPixelBufferRelease(pending);
        return;
    }

    if (pendingPTS < elapsed - 0.5) {              // 落后太多：丢掉，不追
        [self.lock lock];
        if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
        [self.lock unlock];
        CVPixelBufferRelease(pending);
        return;
    }

    // 到点：变换也在锁外做（缩放/镜像/旋转都是重活）
    CVPixelBufferRef shown = [self _transformAny:pending toSize:target];
    CVPixelBufferRelease(pending);                 // 本地引用用完即还

    [self.lock lock];
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    if (shown) {
        if (_slot) CVPixelBufferRelease(_slot);
        _slot = shown;
        _shownFrames++;
    }
    [self.lock unlock];
}

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize {
    return [self copyFrameForCameraPTS:kCMTimeInvalid scaledTo:targetSize];
}

- (CVPixelBufferRef)copyCurrentFrameScaledTo:(CGSize)targetSize {
    [self.lock lock];
    CVPixelBufferRef src = _lastShown ? CVPixelBufferRetain(_lastShown) : NULL;
    [self.lock unlock];
    if (!src) return NULL;
    CVPixelBufferRef out = [self _transformAny:src toSize:targetSize];
    CVPixelBufferRelease(src);
    return out;
}

#pragma mark - 缩放 / 镜像 / 旋转

#pragma mark - 变换分派

- (CVPixelBufferRef)_transformAny:(CVPixelBufferRef)src toSize:(CGSize)targetSize {
    if (!src) return NULL;
    if (CVPixelBufferIsPlanar(src)) return [self _transformNV12:src toSize:targetSize];
    return [self _transformBGRA:src toSize:targetSize];
}

#pragma mark - NV12（420f / 420v）

// 每帧 CVPixelBufferCreate 会每秒分配/释放 30 个 IOSurface，跑一小时必然掉帧。
// 这里按 (尺寸, 格式) 缓存一个池，复用同一批 surface。
- (CVPixelBufferPoolRef)_poolForFormat:(OSType)fmt width:(size_t)w height:(size_t)h {
    if (_pool && _poolFmt == fmt && _poolW == w && _poolH == h) return _pool;
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
    _poolFmt = fmt; _poolW = w; _poolH = h;
    return _pool;
}

- (CVPixelBufferRef)_newNV12Width:(size_t)w height:(size_t)h format:(OSType)fmt {
    CVPixelBufferPoolRef pool = [self _poolForFormat:fmt width:w height:h];
    if (!pool) return NULL;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) != kCVReturnSuccess || !pb) {
        return NULL;
    }
    return pb;
}

// 旋转：Y 用 Planar8，色度按 16 位元素转（Cb/Cr 成对，不能拆）
- (CVPixelBufferRef)_rotateNV12:(CVPixelBufferRef)src rotation:(NSInteger)rot {
    size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    BOOL swap = (rot == 90 || rot == 270);
    size_t dw = swap ? h : w, dh = swap ? w : h;

    CVPixelBufferRef dst = [self _newNV12Width:dw height:dh format:fmt];
    if (!dst) return NULL;

    uint8_t rotConst = (rot == 90) ? kRotate90DegreesClockwise
                     : (rot == 180) ? kRotate180DegreesClockwise
                                    : kRotate270DegreesClockwise;

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    vImage_Buffer yin = { .data = CVPixelBufferGetBaseAddressOfPlane(src, 0),
                          .height = h, .width = w,
                          .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(src, 0) };
    vImage_Buffer yout = { .data = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                           .height = dh, .width = dw,
                           .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 0) };
    vImage_Error e1 = vImageRotate90_Planar8(&yin, &yout, rotConst, 0, kvImageNoFlags);

    vImage_Buffer cin = { .data = CVPixelBufferGetBaseAddressOfPlane(src, 1),
                          .height = (h + 1) / 2, .width = (w + 1) / 2,
                          .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(src, 1) };
    vImage_Buffer cout = { .data = CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                           .height = (dh + 1) / 2, .width = (dw + 1) / 2,
                           .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 1) };
    vImage_Error e2 = vImageRotate90_Planar16U(&cin, &cout, rotConst, 0, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    if (e1 != kvImageNoError || e2 != kvImageNoError) {
        BXLog(@"[BXFloat][vsrc] NV12 旋转失败 %ld/%ld", (long)e1, (long)e2);
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// 缩放：交给 VTPixelTransferSession（硬件，和 RTSP 路径同一套）
- (CVPixelBufferRef)_scaleNV12:(CVPixelBufferRef)src toWidth:(size_t)w height:(size_t)h {
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    CVPixelBufferRef dst = [self _newNV12Width:w height:h format:fmt];
    if (!dst) return NULL;

    static VTPixelTransferSessionRef sT = NULL;
    static NSLock *sTLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTLock = [NSLock new];
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &sT) == noErr && sT) {
            // 注意：这是「裁切填充」，不是留黑边。4:3 视频塞进 16:9 会裁掉上下，
            // 与原版 RTSP 路径同一个缩放模式（保持一致）。
            VTSessionSetProperty(sT, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_CropSourceToCleanAperture);
        }
    });
    BOOL ok = NO;
    if (sT) {
        // VTPixelTransferSession 不保证线程安全：预览和采集可能同时调到这里
        [sTLock lock];
        ok = (VTPixelTransferSessionTransferImage(sT, src, dst) == noErr);
        [sTLock unlock];
    }
    if (!ok) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// 镜像：在自家 buffer 上原地反射（Y 用 Planar8，色度用 CbCr8）
- (void)_mirrorNV12InPlace:(CVPixelBufferRef)pb {
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    vImage_Buffer y = { .data = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                        .height = h, .width = w,
                        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) };
    vImageHorizontalReflect_Planar8(&y, &y, kvImageNoFlags);

    if (CVPixelBufferGetPlaneCount(pb) > 1) {
        vImage_Buffer c = { .data = CVPixelBufferGetBaseAddressOfPlane(pb, 1),
                            .height = (h + 1) / 2, .width = (w + 1) / 2,
                            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) };
        vImageHorizontalReflect_Planar16U(&c, &c, kvImageNoFlags);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

- (CVPixelBufferRef)_copyNV12:(CVPixelBufferRef)src {
    size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
    CVPixelBufferRef dst = [self _newNV12Width:w height:h format:CVPixelBufferGetPixelFormatType(src)];
    if (!dst) return NULL;
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    for (size_t p = 0; p < CVPixelBufferGetPlaneCount(src); p++) {
        vImage_Buffer a = { .data = CVPixelBufferGetBaseAddressOfPlane(src, p),
                            .height = (p == 0) ? h : (h + 1) / 2,
                            .width  = (p == 0) ? w : (w + 1) / 2,
                            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(src, p) };
        vImage_Buffer b = { .data = CVPixelBufferGetBaseAddressOfPlane(dst, p),
                            .height = a.height, .width = a.width,
                            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, p) };
        if (p == 0) vImageCopyBuffer(&a, &b, 1, kvImageNoFlags);
        else        vImageCopyBuffer(&a, &b, 2, kvImageNoFlags);   // 色度一个元素 2 字节
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

- (CVPixelBufferRef)_transformNV12:(CVPixelBufferRef)src toSize:(CGSize)targetSize {
    size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
    NSInteger rot = ((self.rotation % 360) + 360) % 360;
    BOOL needRot = (rot != 0);
    BOOL needMirror = self.mirror;

    size_t rw = (rot == 90 || rot == 270) ? h : w;
    size_t rh = (rot == 90 || rot == 270) ? w : h;
    size_t tw = (targetSize.width > 1)  ? (size_t)targetSize.width  : rw;
    size_t th = (targetSize.height > 1) ? (size_t)targetSize.height : rh;
    BOOL needScale = (tw != rw || th != rh);

    // 常见路径：什么都不用做 → 直接复用解码出来的那块（零拷贝）
    if (!needRot && !needMirror && !needScale) return (CVPixelBufferRef)CFRetain(src);

    CVPixelBufferRef work = (CVPixelBufferRef)CFRetain(src);

    if (needRot) {
        CVPixelBufferRef t = [self _rotateNV12:work rotation:rot];
        if (t) { CFRelease(work); work = t; }
        // 旋转失败就跳过旋转，别把画面搞没
    }

    if (needScale) {
        CVPixelBufferRef t = [self _scaleNV12:work toWidth:tw height:th];
        if (t) { CFRelease(work); work = t; }
    }

    if (needMirror) {
        if (work == src) {                      // 不能改源：先复制一份
            CVPixelBufferRef c = [self _copyNV12:src];
            if (c) { CFRelease(work); work = c; }
        }
        [self _mirrorNV12InPlace:work];
    }

    return work;
}

- (CVPixelBufferRef)_transformBGRA:(CVPixelBufferRef)src toSize:(CGSize)targetSize {
    if (!src) return NULL;

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    NSInteger rot = ((self.rotation % 360) + 360) % 360;

    size_t outW = w, outH = h;
    if (rot == 90 || rot == 270) { outW = h; outH = w; }

    if (!self.mirror && rot == 0 && (CGSizeEqualToSize(targetSize, CGSizeZero) ||
        ((size_t)targetSize.width == w && (size_t)targetSize.height == h))) {
        return CVPixelBufferRetain(src);
    }

    size_t finalW = (targetSize.width > 0)  ? (size_t)targetSize.width  : outW;
    size_t finalH = (targetSize.height > 0) ? (size_t)targetSize.height : outH;

    CVPixelBufferRef dst = [self _newBufferWidth:finalW height:finalH];
    if (!dst) return CVPixelBufferRetain(src);

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    vImage_Buffer inBuf = {
        .data = CVPixelBufferGetBaseAddress(src),
        .height = h,
        .width = w,
        .rowBytes = CVPixelBufferGetBytesPerRow(src),
    };
    vImage_Buffer dstBuf = {
        .data = CVPixelBufferGetBaseAddress(dst),
        .height = finalH,
        .width = finalW,
        .rowBytes = CVPixelBufferGetBytesPerRow(dst),
    };

    // 1) 旋转 + 镜像到中间缓冲（如需要），2) 缩放到目标尺寸
    vImage_Buffer stage = inBuf;
    CVPixelBufferRef stagePx = NULL;

    BOOL needRot = (rot != 0);
    if (needRot) {
        size_t sw = outW, sh = outH;
        stagePx = [self _newBufferWidth:sw height:sh];
        if (stagePx) {
            CVPixelBufferLockBaseAddress(stagePx, 0);
            vImage_Buffer rbuf = {
                .data = CVPixelBufferGetBaseAddress(stagePx),
                .height = sh,
                .width = sw,
                .rowBytes = CVPixelBufferGetBytesPerRow(stagePx),
            };
            if (rot == 90) {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate90DegreesClockwise, 0, 0);
            } else if (rot == 180) {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate180DegreesClockwise, 0, 0);
            } else {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate270DegreesClockwise, 0, 0);
            }
            CVPixelBufferUnlockBaseAddress(stagePx, 0);
            stage = rbuf;
        }
    }

    // 镜像：必须先落到 dst 再反射。
    // 之前写成 vImageHorizontalReflect(&stage,&stage) —— 旋转关闭时 stage 就是
    // 解码器给的那块内存（锁的还是 ReadOnly），逐帧原地反射会：
    //   ① 把源缓冲写坏（画面越用越花）  ② 污染 _lastFrame 缓存  ③ 破坏解码器缓冲池
    if (self.mirror) {
        if ((size_t)stage.width == finalW && (size_t)stage.height == finalH) {
            vImageCopyBuffer(&stage, &dstBuf, 4, 0);
        } else {
            vImageScale_ARGB8888(&stage, &dstBuf, 0, 0);
        }
        vImageHorizontalReflect_ARGB8888(&dstBuf, &dstBuf, 0);
    } else {
        if ((size_t)stage.width == finalW && (size_t)stage.height == finalH) {
            vImageCopyBuffer(&stage, &dstBuf, 4, 0);
        } else {
            vImageScale_ARGB8888(&stage, &dstBuf, 0, 0);
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (stagePx) CVPixelBufferRelease(stagePx);

    return dst;
}

- (CVPixelBufferRef)_newBufferWidth:(size_t)w height:(size_t)h {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
    };
    CVPixelBufferRef px = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &px);
    if (r != kCVReturnSuccess) {
        BXLog(@"[BXFloat][vcam] CVPixelBufferCreate 失败 %d", r);
        return NULL;
    }
    return px;
}

@end
