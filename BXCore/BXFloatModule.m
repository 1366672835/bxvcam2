//
//  BXFloatModule.m
//

#import "BXFloatModule.h"
#import "BXFloatStore.h"

@implementation BXFloatModule

+ (instancetype)toggleWithKey:(NSString *)key title:(NSString *)title action:(BXModuleHandler)handler {
    BXFloatModule *m = [BXFloatModule new];
    m->_key = [key copy];
    m->_title = [title copy];
    m.kind = BXModuleKindToggle;
    m.handler = handler;
    m.on = NO;
    return m;
}

+ (instancetype)sliderWithKey:(NSString *)key title:(NSString *)title
                          min:(double)min max:(double)max step:(double)step
                       action:(BXModuleHandler)handler {
    BXFloatModule *m = [BXFloatModule new];
    m->_key = [key copy];
    m->_title = [title copy];
    m.kind = BXModuleKindSlider;
    m.minValue = min;
    m.maxValue = max;
    m.step = (step > 0 ? step : 1.0);
    m.value = min;
    m.handler = handler;
    return m;
}

+ (instancetype)buttonWithKey:(NSString *)key title:(NSString *)title action:(BXModuleHandler)handler {
    BXFloatModule *m = [BXFloatModule new];
    m->_key = [key copy];
    m->_title = [title copy];
    m.kind = BXModuleKindButton;
    m.handler = handler;
    return m;
}

+ (instancetype)pickerWithKey:(NSString *)key title:(NSString *)title
                      options:(NSArray<NSString *> *)options action:(BXModuleHandler)handler {
    BXFloatModule *m = [BXFloatModule new];
    m->_key = [key copy];
    m->_title = [title copy];
    m.kind = BXModuleKindPicker;
    m.options = options ?: @[];
    m.selectedIndex = 0;
    m.handler = handler;
    return m;
}

- (void)fire {
    id v = nil;
    switch (self.kind) {
        case BXModuleKindToggle:  v = @(self.on); break;
        case BXModuleKindSlider:  v = @(self.value); break;
        case BXModuleKindPicker:  v = @(self.selectedIndex); break;
        default: break;
    }
    if (self.handler) {
        self.handler(self, v);
    } else if (self.target) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([self.target respondsToSelector:@selector(bxModuleFired:value:)]) {
            [self.target performSelector:@selector(bxModuleFired:value:) withObject:self withObject:v];
        }
#pragma clang diagnostic pop
    }
    [[BXFloatStore shared] setObject:(v ?: @YES) forKey:self.key];
}

- (NSString *)displayValue {
    switch (self.kind) {
        case BXModuleKindToggle: return self.on ? @"ON" : @"OFF";
        case BXModuleKindSlider:
            if (self.step >= 1.0) {
                return [NSString stringWithFormat:@"%.0f", self.value];
            }
            return [NSString stringWithFormat:@"%.2f", self.value];
        case BXModuleKindPicker:
            if (self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.options.count) {
                return self.options[self.selectedIndex];
            }
            return @"-";
        default: return @"";
    }
}

@end


@implementation BXFloatRegistry {
    NSMutableArray<BXFloatModule *> *_modules;
    NSMutableDictionary<NSString *, BXFloatModule *> *_index;
}

+ (instancetype)shared {
    static BXFloatRegistry *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [BXFloatRegistry new]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _modules = [NSMutableArray array];
        _index = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)registerModule:(BXFloatModule *)module {
    if (!module.key.length) return;
    if (_index[module.key]) {
        NSLog(@"[BXFloat] 重复注册模块 %@，已忽略", module.key);
        return;
    }
    [_modules addObject:module];
    _index[module.key] = module;
}

- (void)registerModules:(NSArray<BXFloatModule *> *)modules {
    for (BXFloatModule *m in modules) [self registerModule:m];
}

- (NSArray<BXFloatModule *> *)modules { return [_modules copy]; }

- (BXFloatModule *)moduleForKey:(NSString *)key { return _index[key]; }

- (void)restoreAll {
    BXFloatStore *store = [BXFloatStore shared];
    for (BXFloatModule *m in _modules) {
        id saved = [store objectForKey:m.key];
        if (!saved) continue;
        switch (m.kind) {
            case BXModuleKindToggle:  m.on = [saved boolValue]; break;
            case BXModuleKindSlider:  m.value = [saved doubleValue]; break;
            case BXModuleKindPicker:  m.selectedIndex = [saved integerValue]; break;
            default: break;
        }
    }
}

- (void)persistAll {
    BXFloatStore *store = [BXFloatStore shared];
    for (BXFloatModule *m in _modules) {
        switch (m.kind) {
            case BXModuleKindToggle:  [store setObject:@(m.on) forKey:m.key]; break;
            case BXModuleKindSlider:  [store setObject:@(m.value) forKey:m.key]; break;
            case BXModuleKindPicker:  [store setObject:@(m.selectedIndex) forKey:m.key]; break;
            default: break;
        }
    }
    [store synchronize];
}

@end
