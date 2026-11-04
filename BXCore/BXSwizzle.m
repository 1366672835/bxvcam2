//
//  BXSwizzle.m
//

#import "BXSwizzle.h"

IMP BXSwizzleInstanceMethod(Class cls, SEL sel, IMP newIMP) {
    if (!cls || !sel || !newIMP) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[BXSwizzle] 找不到方法 -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    return method_setImplementation(m, newIMP);
}

IMP BXSwizzleClassMethod(Class cls, SEL sel, IMP newIMP) {
    if (!cls || !sel || !newIMP) return NULL;
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        NSLog(@"[BXSwizzle] 找不到类方法 +[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    return method_setImplementation(m, newIMP);
}
