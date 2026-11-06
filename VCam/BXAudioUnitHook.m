//
//  BXAudioUnitHook.m
//  与原版同路：用「符号指针重绑」接管 AudioUnitRender 的输入总线，
//  把麦克风 PCM 换成 RTSP 流音频。
//
//  原版日志（0x3336e8）：
    BXLogWrite(@"[BXFloat][au] audio unit hook installed render=%d setprop=%d", n, n2);
//     adaptive_asbd=initialize_setproperty fallback_rate=44100"
//
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <string.h>

#import "BXAudioUnitHook.h"
#import "BXLog.h"
#import "BXFishhook.h"
#import "BXLog.h"
#import "BXCaptureBridge.h"
#import "BXLog.h"

typedef OSStatus (*BXRenderFn)(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *ioData);

#import <pthread.h>

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BXRenderFn gOrigRender = NULL;
static BOOL gInstalled = NO;
static volatile int gAUFills = 0;   // 成功替换音频的次数

#pragma mark - 指针重绑

// 在所有镜像的 __DATA / __DATA_CONST 里找「值等于 target」的指针，替换成 replacement。
// 兼容 chained fixups：dyld 已经把真实地址写进数据段，直接按值扫描即可。

#pragma mark - 重采样与格式写入

static float   *sSrc = NULL;      // 源（48k 交错立体声 float32）
static size_t   sSrcCap = 0;      // 容量（帧）
static size_t   sSrcLen = 0;      // 已有帧数
static double   sPos = 0.0;       // 读取位置（帧，带小数）
static double   sSrcRate = 48000.0;

static void BXAUEnsureSrc(size_t frames) {
    if (sSrcCap >= frames) return;
    size_t cap = frames < 2048 ? 2048 : frames * 2;
    float *nb = realloc(sSrc, cap * 2 * sizeof(float));
    if (!nb) return;
    sSrc = nb;
    sSrcCap = cap;
}

static void BXAUConsume(size_t n) {
    if (n >= sSrcLen) { sSrcLen = 0; return; }
    memmove(sSrc, sSrc + n * 2, (sSrcLen - n) * 2 * sizeof(float));
    sSrcLen -= n;
}

// 需要多少源帧才能产出 outFrames 个目标帧
static size_t BXAUEnsureNeeded(size_t outFrames, double dstRate) {
    double ratio = sSrcRate / (dstRate > 0 ? dstRate : 44100.0);
    size_t need = (size_t)((double)outFrames * ratio) + 4;
    return need;
}

static void BXAUReadMore(size_t wantFrames) {
    BXAUEnsureSrc(sSrcLen + wantFrames);
    if (!sSrc) return;
    if (sSrcLen >= sSrcCap) return;          // 防止无符号下溢
    size_t room = sSrcCap - sSrcLen;
    if (room == 0) return;
    NSUInteger got = [[BXCaptureBridge shared] pullAudioFloat:(sSrc + sSrcLen * 2)
                                                    maxFrames:room];
    sSrcLen += got;
}

#pragma mark - 渲染钩子

// 实际填充（调用方持锁）
// 【照原版】原版重绑了三个 AudioUnit 函数：Render / Initialize / SetProperty。
// Initialize 与 SetProperty 用来抓真实音频格式，Render 里才有正确参数可用。
typedef OSStatus (*BXSetPropFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                               AudioUnitElement, const void *, UInt32);
static BXSetPropFn gOrigSetProp = NULL;
static AudioStreamBasicDescription gCapturedASBD;
static volatile int gCapturedValid = 0;
static AudioUnit gCapturedUnit = NULL;

static OSStatus BXSetPropHook(AudioUnit unit, AudioUnitPropertyID pid, AudioUnitScope scope,
                              AudioUnitElement elem, const void *data, UInt32 size) {
    if (pid == kAudioUnitProperty_StreamFormat && data &&
        size >= (UInt32)sizeof(AudioStreamBasicDescription)) {
        AudioStreamBasicDescription asbd = *(const AudioStreamBasicDescription *)data;
        if (asbd.mSampleRate > 0 && asbd.mChannelsPerFrame > 0) {
            gCapturedASBD = asbd;
            gCapturedUnit = unit;
            gCapturedValid = 1;
            static int logged = 0;
            if (logged++ < 4) {
                BXLogWrite(@"[BXFloat][au] 抓到格式 %.0fHz %uch flags=%#x bytesPerFrame=%u",
                      asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                      (unsigned)asbd.mFormatFlags, (unsigned)asbd.mBytesPerFrame);
            }
        }
    }
    return gOrigSetProp ? gOrigSetProp(unit, pid, scope, elem, data, size) : noErr;
}


static void BXFillAudioBuffers(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData, OSStatus *outSt) {
    // 音画同一条时钟：画面超过 200ms 没有新帧（卡住/断流），就别再放音了。
    // 原版就是这个行为——画面卡住时声音也停，不会出现"声音一直在跑"的脱节感。
    {
        NSTimeInterval tick = [[BXCaptureBridge shared] lastVideoTick];
        if (tick <= 0 || (CACurrentMediaTime() - tick) > 0.20) {
            for (UInt32 bi = 0; bi < ioData->mNumberBuffers; bi++) {
                AudioBuffer *ab = &ioData->mBuffers[bi];
                if (ab->mData && ab->mDataByteSize) memset(ab->mData, 0, ab->mDataByteSize);
            }
            if (outSt) *outSt = noErr;
            return;
        }
    }
    static AudioStreamBasicDescription sASBD;
    static AudioUnit sASBDUnit = NULL;
    static int sASBDFailed = 0;

    // 优先用 SetProperty 抓到格式（原版就是这么做的），避免在回调里查属性
    if (gCapturedValid && gCapturedUnit == unit && sASBDUnit != unit) {
        sASBD = gCapturedASBD;
        sASBDUnit = unit;
        sPos = 0.0;
        sSrcLen = 0;
    }

    if (sASBDUnit != unit) {
        if (sASBDFailed) return;                 // 之前查失败：永久不干预
        AudioStreamBasicDescription asbd = {0};
        UInt32 size = sizeof(asbd);
        int ok = 0;
        if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, bus, &asbd, &size) == noErr &&
            asbd.mSampleRate > 0 && asbd.mChannelsPerFrame > 0) {
            ok = 1;
        } else {
            asbd = (AudioStreamBasicDescription){0};
            size = sizeof(asbd);
            if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input, bus, &asbd, &size) == noErr &&
                asbd.mSampleRate > 0 && asbd.mChannelsPerFrame > 0) {
                ok = 1;
            }
        }
        if (!ok) { sASBDFailed = 1; return; }
        sASBD = asbd;
        sASBDUnit = unit;
        sPos = 0.0;                              // 换 unit：重采样器复位
        sSrcLen = 0;
    }

    int dstCh = (int)sASBD.mChannelsPerFrame;
    if (dstCh <= 0) return;
    int isFloat = (sASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    int nonInterleaved = (sASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    double dstRate = sASBD.mSampleRate > 0 ? sASBD.mSampleRate : 44100.0;

    size_t need = BXAUEnsureNeeded(frames, dstRate);
    if (sSrcLen < need) BXAUReadMore(need * 2);
    if (sSrcLen == 0) return;                    // 没数据：麦克风原样

    double ratio = sSrcRate / dstRate;

    // ① 生成样本（只推进一次 sPos）
    static float *sMix = NULL;
    static size_t sMixCap = 0;
    if (sMixCap < frames) {
        float *nb = realloc(sMix, (size_t)frames * 2 * sizeof(float));
        if (!nb) return;
        sMix = nb;
        sMixCap = frames;
    }

    double pos = sPos;
    UInt32 produced = 0;
    float lastL = 0.0f, lastR = 0.0f;
    for (UInt32 f = 0; f < frames; f++) {
        size_t i0 = (size_t)pos;
        size_t i1 = i0 + 1;
        if (i1 >= sSrcLen) break;
        double frac = pos - (double)i0;
        float l = sSrc[i0 * 2] * (1.0f - (float)frac) + sSrc[i1 * 2] * (float)frac;
        float r = sSrc[i0 * 2 + 1] * (1.0f - (float)frac) + sSrc[i1 * 2 + 1] * (float)frac;
        sMix[f * 2] = l;
        sMix[f * 2 + 1] = r;
        lastL = l; lastR = r;
        produced = f + 1;
        pos += ratio;
    }
    if (produced == 0) return;
    gAUFills++;
    for (UInt32 f = produced; f < frames; f++) {
        sMix[f * 2] = lastL;
        sMix[f * 2 + 1] = lastR;
    }

    // ② 按格式铺开（不再推进 sPos）
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *ab = &ioData->mBuffers[b];
        int ch = nonInterleaved ? 1 : dstCh;
        size_t bytesPerSample = isFloat ? sizeof(float) : sizeof(int16_t);

        uint8_t *dst = (uint8_t *)ab->mData;
        size_t needBytes = (size_t)frames * ch * bytesPerSample;
        if (!dst || ab->mDataByteSize < needBytes) continue;

        for (UInt32 f = 0; f < frames; f++) {
            for (int c = 0; c < ch; c++) {
                int chIdx = nonInterleaved ? (int)b : c;
                float v = (chIdx == 0) ? sMix[f * 2]
                        : ((chIdx == 1) ? sMix[f * 2 + 1] : 0.0f);
                uint8_t *pp = dst + ((size_t)f * ch + c) * bytesPerSample;
                if (isFloat) ((float *)pp)[0] = v;
                else ((int16_t *)pp)[0] = (int16_t)(v * 32767.0f);
            }
        }
    }
    sPos = pos;

    size_t consumed = (size_t)sPos;
    if (consumed > 0) {
        BXAUConsume(consumed);
        sPos -= (double)consumed;
    }
    (void)outSt;
}

static OSStatus BXRenderHook(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *ts, UInt32 bus,
                             UInt32 frames, AudioBufferList *ioData) {
    OSStatus st = gOrigRender ? gOrigRender(unit, flags, ts, bus, frames, ioData) : -1;
    if (st != noErr || !ioData || frames == 0) return st;
    if (bus != 1) return st;                     // 只处理输入总线（麦克风）

    BXCaptureBridge *br = [BXCaptureBridge shared];
    if (!br.audioReplace) return st;

    if (pthread_mutex_trylock(&gLock) != 0) return st;   // 抢不到就放行原数据，绝不让音频线程等锁
    BXFillAudioBuffers(unit, bus, frames, ioData, &st);
    pthread_mutex_unlock(&gLock);
    return st;
}

#pragma mark - 安装

void BXAudioUnitHookInstall(void) {
    static BOOL sStarted = NO;
    if (sStarted) return;
    sStarted = YES;

    // 与原版同路：按符号名重绑 AudioUnitRender（fishhook 算法）
    void *prev = NULL;
    int n = BXRebindSymbols("AudioUnitRender", (void *)BXRenderHook, &prev);
    if (prev) gOrigRender = (BXRenderFn)prev;
    if (!gOrigRender) gOrigRender = (BXRenderFn)dlsym(RTLD_DEFAULT, "AudioUnitRender");

    // 【照原版】同时重绑 AudioUnitSetProperty，用它抓真实音频格式
    void *prevSet = NULL;
    int n2 = BXRebindSymbols("AudioUnitSetProperty", (void *)BXSetPropHook, &prevSet);
    if (prevSet) gOrigSetProp = (BXSetPropFn)prevSet;
    if (!gOrigSetProp) gOrigSetProp = (BXSetPropFn)dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");

    BXLogWrite(@"[BXFloat][au] audio unit hook installed render=%d setprop=%d", n, n2);
}
