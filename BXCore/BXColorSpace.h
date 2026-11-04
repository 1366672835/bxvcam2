//
//  BXColorSpace.h —— 复用的 RGB 色彩空间
//
//  CGColorSpaceCreateDeviceRGB() 是 Create 语义，每帧调用会持续泄漏
//  （30fps 下每秒 30 个）。这里做成进程内单例。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static inline CGColorSpaceRef BXColorSpaceRGB(void) {
    static CGColorSpaceRef cs = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cs = CGColorSpaceCreateDeviceRGB();
    });
    return cs;
}
