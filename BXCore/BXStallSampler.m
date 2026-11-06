//
//  BXStallSampler.m — 主线程卡死采样器
//
//  原理（poor man's profiler）：
//    后台线程每 2 秒向"主线程"发 SIGPROF；
//    信号处理函数在主线程上下文里执行，此时 backtrace() 拿到的就是主线程当前调用栈；
//    把栈顶若干帧写到 /tmp/bxstall.txt（每次覆盖），于是文件里永远是"最近一次采样"。
//
//  冻结后再重启，读这个文件就知道主线程卡在哪个函数里 —— 不需要越狱、不需要 Xcode。
//

#import <Foundation/Foundation.h>
#include <signal.h>
#include <execinfo.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>

static pthread_t gMainThread;
static int gStallFD = -1;

static void BXSigProfHandler(int sig, siginfo_t *info, void *ctx) {
    (void)sig; (void)info; (void)ctx;
    if (gStallFD < 0) return;

    void *frames[64];
    int n = backtrace(frames, 64);
    if (n <= 0) return;

    // 覆盖写：只保留最近一次采样的栈
    lseek(gStallFD, 0, SEEK_SET);
    char hdr[64];
    int hn = snprintf(hdr, sizeof(hdr), "=== sample (frames=%d) ===\n", n);
    write(gStallFD, hdr, (size_t)hn);

    for (int i = 0; i < n; i++) {
        char line[256];
        // 只写地址：符号化交给 backtrace_symbols 不稳定（非 async-signal-safe）
        int ln = snprintf(line, sizeof(line), "  #%02d %p\n", i, frames[i]);
        write(gStallFD, line, (size_t)ln);
    }
    ftruncate(gStallFD, (off_t)(hn + n * 20 + 32));
}

static void *BXSamplerThread(void *arg) {
    (void)arg;
    while (1) {
        sleep(2);
        if (gMainThread) pthread_kill(gMainThread, SIGPROF);
    }
    return NULL;
}

void BXStartMainThreadSampler(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bxstall.txt"];
    gStallFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (gStallFD < 0) return;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = BXSigProfHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, NULL);

    gMainThread = pthread_self();   // 本函数在主线程调用
    pthread_t th;
    pthread_create(&th, NULL, BXSamplerThread, NULL);
    pthread_detach(th);
}

/// 读取最近一次采样（给面板"复制日志"用）
NSString *BXStallSampleText(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bxstall.txt"];
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s.length ? s : @"(无采样)";
}
