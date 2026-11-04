//
//  BXFloatStore.m  —— TrollStore 版
//
//  与越狱版的差异:
//    越狱版直接写 /var/mobile/Library/Preferences/xxx.plist（全设备共享）。
//    TrollStore 是沙盒环境，只能写 App 自己的沙盒，
//    所以这里改用 NSUserDefaults（自动落到 App 的 Library/Preferences）。
//
//    好处: TrollStore / 越狱 两种环境都能跑；坏处: 每个 App 一份配置。
//

#import "BXFloatStore.h"

@implementation BXFloatStore {
    NSMutableDictionary *_cache;
    NSUserDefaults *_defaults;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static BXFloatStore *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [BXFloatStore new]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.jh.bxfloat.store", DISPATCH_QUEUE_SERIAL);

        // TrollStore 沙盒: 用 standardUserDefaults，跟着 App 走
        _defaults = [NSUserDefaults standardUserDefaults];

        // 内存缓存，避免每次读盘
        _cache = [NSMutableDictionary dictionary];
        for (NSString *key in [_defaults dictionaryRepresentation]) {
            if ([key hasPrefix:@"bx."]) {
                id v = [_defaults objectForKey:key];
                if (v) _cache[key] = v;
            }
        }
    }
    return self;
}

- (id)objectForKey:(NSString *)key {
    if (!key) return nil;
    __block id v;
    dispatch_sync(_queue, ^{ v = self->_cache[key]; });
    return v;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    dispatch_async(_queue, ^{
        if (value) self->_cache[key] = value;
        else [self->_cache removeObjectForKey:key];

        if (value) [self->_defaults setObject:value forKey:key];
        else [self->_defaults removeObjectForKey:key];
    });
}

- (void)removeObjectForKey:(NSString *)key {
    [self setObject:nil forKey:key];
}

- (void)synchronize {
    dispatch_sync(_queue, ^{ [self->_defaults synchronize]; });
}

- (NSDictionary *)allValues {
    __block NSDictionary *d;
    dispatch_sync(_queue, ^{ d = [self->_cache copy]; });
    return d;
}

@end
