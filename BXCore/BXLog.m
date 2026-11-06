#import "BXLog.h"

// 环形缓冲（内存）+ 落盘（跨进程保留）。
// 冻结或崩溃后重启，还能读到上一轮的最后 200 行 —— 用来定位"哪个子系统先停"。

static NSMutableArray<NSString *> *gLines;
static NSLock *gLogLock;
static NSString *gLogPath;
static NSUInteger gAppendCount;

static void BXLogInitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLines = [NSMutableArray array];
        gLogLock = [NSLock new];
        gLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bxlog.txt"];

        // 读回上一次会话的尾部
        NSString *old = [NSString stringWithContentsOfFile:gLogPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (old.length) {
            NSArray *arr = [old componentsSeparatedByString:@"\n"];
            NSUInteger start = arr.count > 200 ? arr.count - 200 : 0;
            for (NSUInteger i = start; i < arr.count; i++) {
                NSString *l = arr[i];
                if (l.length) [gLines addObject:[@"[上次] " stringByAppendingString:l]];
            }
        }
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

void BXLogWrite(NSString *format, ...) {
    if (!format) return;
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    if (!msg) return;

    NSLog(@"%@", msg);

    BXLogInitIfNeeded();
    [gLogLock lock];
    [gLines addObject:msg];
    if (gLines.count > 400) {
        [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - 400)];
    }

    // 每 8 行落一次盘，避免频繁 IO 拖慢采集线程
    gAppendCount++;
    if (gAppendCount % 8 == 0 && gLogPath) {
        NSMutableString *tail = [NSMutableString string];
        NSUInteger from = gLines.count > 60 ? gLines.count - 60 : 0;
        for (NSUInteger i = from; i < gLines.count; i++) {
            [tail appendString:gLines[i]];
            [tail appendString:@"\n"];
        }
        [tail writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    [gLogLock unlock];
}

NSString *BXLogText(void) {
    BXLogInitIfNeeded();
    [gLogLock lock];
    NSString *s = [gLines componentsJoinedByString:@"\n"];
    [gLogLock unlock];
    return s.length ? s : @"(还没有日志)";
}

void BXLogClear(void) {
    BXLogInitIfNeeded();
    [gLogLock lock];
    [gLines removeAllObjects];
    [gLogLock unlock];
}
