#ifndef BXFISHHOOK_H
#define BXFISHHOOK_H

#ifdef __cplusplus
extern "C" {
#endif

/// 按符号名重绑（fishhook 同算法）。返回命中的指针个数。
int BXRebindSymbols(const char *name, void *replacement, void **replaced);

#ifdef __cplusplus
}
#endif

#endif
