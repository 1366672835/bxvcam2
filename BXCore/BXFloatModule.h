//
//  BXFloatModule.h
//  BXFloat —— 悬浮菜单框架
//
//  一个"模块"= 菜单里的一行。可以是开关、滑杆、按钮组。
//  真正的游戏逻辑放在 BXModules/ 里，通过 -applyValue: 落地。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, BXModuleKind) {
    BXModuleKindToggle = 0,   // 开关
    BXModuleKindSlider,       // 数值滑杆
    BXModuleKindButton,       // 一次性动作
    BXModuleKindPicker,       // 多选一
};

@class BXFloatModule;

/// 模块被切换/滑动时回调，value 为 NSNumber(BOOL) 或 NSNumber(double)
typedef void (^BXModuleHandler)(BXFloatModule *module, id value);

@interface BXFloatModule : NSObject

@property (nonatomic, copy, readonly) NSString *key;         // 唯一 id，用于持久化
@property (nonatomic, copy, readonly) NSString *title;       // 显示名
@property (nonatomic, copy) NSString *subtitle;              // 副标题 / 当前值文案
@property (nonatomic, assign) BXModuleKind kind;

@property (nonatomic, assign) BOOL on;                       // 开关态
@property (nonatomic, assign) double value;                  // 滑杆值
@property (nonatomic, assign) double minValue;
@property (nonatomic, assign) double maxValue;
@property (nonatomic, assign) double step;
@property (nonatomic, copy) NSArray<NSString *> *options;    // Picker 选项
@property (nonatomic, assign) NSInteger selectedIndex;

@property (nonatomic, copy) BXModuleHandler handler;
@property (nonatomic, weak) id target;                       // handler 为 nil 时用 target/action

@property (nonatomic, assign) BOOL advanced;                 // 标记为高级模块（仅用于分组显示）

+ (instancetype)toggleWithKey:(NSString *)key
                        title:(NSString *)title
                       action:(BXModuleHandler)handler;

+ (instancetype)sliderWithKey:(NSString *)key
                        title:(NSString *)title
                          min:(double)min
                          max:(double)max
                         step:(double)step
                       action:(BXModuleHandler)handler;

+ (instancetype)buttonWithKey:(NSString *)key
                        title:(NSString *)title
                       action:(BXModuleHandler)handler;

+ (instancetype)pickerWithKey:(NSString *)key
                        title:(NSString *)title
                      options:(NSArray<NSString *> *)options
                       action:(BXModuleHandler)handler;

/// 触发一次 handler
- (void)fire;

/// 供 UI 显示的右侧文案
- (NSString *)displayValue;

@end

/// 全局模块注册表。菜单从这里取数据。
@interface BXFloatRegistry : NSObject

+ (instancetype)shared;

- (void)registerModule:(BXFloatModule *)module;
- (void)registerModules:(NSArray<BXFloatModule *> *)modules;
- (NSArray<BXFloatModule *> *)modules;
- (BXFloatModule *)moduleForKey:(NSString *)key;

/// 从持久化恢复所有模块状态
- (void)restoreAll;
/// 把所有模块状态写回持久化
- (void)persistAll;

@end
