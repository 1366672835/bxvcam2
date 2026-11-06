//
//  BXStallSampler.m — 主线程卡死采样器（v2：带镜像名 + 偏移）
//
//  后台线程每 2 秒向主线程发 SIGPROF；信号处理函数在主线程上下文执行，
//  backtrace() 得到主线程当前栈，再用 dladdr() 标出每帧属于哪张镜像、偏移多少。
//
//  输出 /tmp/bxstall.txt，例如：
//    #00 BXFloatVCam +0x1a3c4
//    #05 Douyin +0x8c1b4
//    #11 UIKitCore +0x2f6b4
//
//  这样"卡在谁身上"一目了然。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BXLog.h"
#include <signal.h>
#include <execinfo.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>

static pthread_t gMainThread;
static int gStallFD = -1;
static int gSampleSeq = 0;

static const char *BXBaseName(const char *path) {
    if (!path) return "?";
    const char *p = strrchr(path, '/');
    return p ? p + 1 : path;
}

static void BXSigProfHandler(int sig, siginfo_t *info, void *ctx) {
    (void)sig; (void)info; (void)ctx;
    if (gStallFD < 0) return;

    void *frames[48];
    int n = backtrace(frames, 48);
    if (n <= 0) return;

    gSampleSeq++;
    lseek(gStallFD, 0, SEEK_END);   // 追加，保留历史
    char hdr[160];
    int hn = snprintf(hdr, sizeof(hdr), "=== sample #%d pid=%d t=%.1f app=%d frames=%d ===\n",
                      gSampleSeq, (int)getpid(), (double)CACurrentMediaTime(),
                      (int)[UIApplication sharedApplication].applicationState, n);
    write(gStallFD, hdr, (size_t)hn);

    for (int i = 0; i < n; i++) {
        Dl_info di;
        memset(&di, 0, sizeof(di));
        char line[320];
        int ln;
        if (dladdr(frames[i], &di) && di.dli_fname) {
            long off = (long)((char *)frames[i] - (char *)di.dli_fbase);
            if (di.dli_sname) {
                ln = snprintf(line, sizeof(line), "  #%02d %-16s +0x%lx  %s\n",
                              i, BXBaseName(di.dli_fname), off, di.dli_sname);
            } else {
                ln = snprintf(line, sizeof(line), "  #%02d %-16s +0x%lx\n",
                              i, BXBaseName(di.dli_fname), off);
            }
        } else {
            ln = snprintf(line, sizeof(line), "  #%02d %p (no image)\n", i, frames[i]);
        }
        if (ln > 0) write(gStallFD, line, (size_t)ln);
    }

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
    gStallFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);  // 追加，绝不清空	
    if (gStallFD < 0) return;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = BXSigProfHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, NULL);

    gMainThread = pthread_self();
    pthread_t th;
    pthread_create(&th, NULL, BXSamplerThread, NULL);
    pthread_detach(th);

    // 顺带记下镜像基址，便于离线核对
    Dl_info di;
    if (dladdr((void *)&BXStartMainThreadSampler, &di)) {
        BXLogWrite(@"[BXFloat][sampler] dylib=%s base=%p", BXBaseName(di.dli_fname), di.dli_fbase);
    }
}

NSString *BXStallSampleText(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bxstall.txt"];
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s.length ? s : @"(无采样)";
}
