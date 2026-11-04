#import "BXLog.h"

// 环形缓冲：保留最近 400 行，避免无限增长
static NSMutableArray<NSString *> *gLines;
static NSLock *gLogLock;

static void BXLogInitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLines = [NSMutableArray array];
        gLogLock = [NSLock new];
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
