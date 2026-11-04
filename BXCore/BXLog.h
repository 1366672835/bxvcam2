//
//  BXLog.h
//  日志缓冲：BXLog 宏写进来的每一行都同时进内存环形缓冲，面板可查看/复制。
//  取日志的方式：面板 →「我的」→「日志」→ 复制全文
//
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void BXLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *BXLogText(void);      // 取全部（最多保留最近 N 行）
void BXLogClear(void);

#ifdef __cplusplus
}
#endif
