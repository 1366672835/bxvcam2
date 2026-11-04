//
//  BXSwizzle.h —— 不依赖 CydiaSubstrate 的方法交换
//
//  TrollStore 环境里没有 libsubstrate，MSHookMessageEx 不可用。
//  这里用 objc/runtime 的 method_setImplementation 做等价交换，
//  对普通 Objective-C 方法足够用；不触碰 C++ 函数（那个需要 inline hook）。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 交换实例方法。返回原实现，直接塞给静态变量保存。
IMP BXSwizzleInstanceMethod(Class cls, SEL sel, IMP newIMP);

/// 交换类方法。
IMP BXSwizzleClassMethod(Class cls, SEL sel, IMP newIMP);

/// 便利宏：声明"原实现"静态指针 + 一行安装函数。
///
///   BX_SWIZZLE(UIApplication, applicationDidBecomeActive:, BXOnAppDidBecomeActive)
///
/// 展开成:
///   static IMP BXOnAppDidBecomeActive_orig = NULL;
///   static inline void BXInstall_BXOnAppDidBecomeActive(void) {
///       BXOnAppDidBecomeActive_orig = BXSwizzleInstanceMethod(
///           objc_getClass("UIApplication"),
///           @selector(applicationDidBecomeActive:),
///           (IMP)BXOnAppDidBecomeActive);
///   }
///
/// 用法: 自己写同签名的函数，第一行调回原实现
///   BXCallOrig(BXOnAppDidBecomeActive_orig, self, _cmd, app);
/// 再干活。
#define BX_SWIZZLE(clsname, selname, funcname)                                \
    static IMP funcname##_orig = NULL;                                        \
    static inline void BXInstall_##funcname(void) {                           \
        funcname##_orig = BXSwizzleInstanceMethod(                            \
            objc_getClass(#clsname), @selector(selname), (IMP)funcname);       \
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type"

/// 调用原实现，固定签名 (id, SEL, id) -> void
static inline void BXCallOrig(IMP imp, id self, SEL _cmd, id arg) {
    if (!imp) return;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))imp;
    fn(self, _cmd, arg);
}

/// 调用原实现，无参数 (id, SEL) -> void
static inline void BXCallOrig0(IMP imp, id self, SEL _cmd) {
    if (!imp) return;
    void (*fn)(id, SEL) = (void (*)(id, SEL))imp;
    fn(self, _cmd);
}

#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif
