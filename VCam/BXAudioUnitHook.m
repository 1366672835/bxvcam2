//
//  BXAudioUnitHook.m
//  与原版同路：用「符号指针重绑」接管 AudioUnitRender 的输入总线，
//  把麦克风 PCM 换成 RTSP 流音频。
//
//  原版日志（0x3336e8）：
//    "audio unit hook installed backend=symbol_rebinding result=%d input_bus=1
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
#import "BXFishhook.h"
#import "BXCaptureBridge.h"

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
static void BXFillAudioBuffers(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData, OSStatus *outSt) {
    static AudioStreamBasicDescription sASBD;
    static AudioUnit sASBDUnit = NULL;
    static int sASBDFailed = 0;

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

    pthread_mutex_lock(&gLock);
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

    NSLog(@"[BXFloat][au] audio unit hook installed backend=symbol_rebinding result=%d input_bus=1 fallback_rate=44100", n);
}
