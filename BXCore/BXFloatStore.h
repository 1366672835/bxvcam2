//
//  BXFloatStore.h —— 极薄的持久化层
//  TrollStore 版: 落盘在 App 沙盒的 NSUserDefaults 里
//  (越狱版才写 /var/mobile/Library/Preferences)
//

#import <Foundation/Foundation.h>

@interface BXFloatStore : NSObject

+ (instancetype)shared;

- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (void)synchronize;

/// 所有 key（调试用）
- (NSDictionary *)allValues;

@end
