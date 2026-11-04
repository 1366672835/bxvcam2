//
//  BXLocalAudio.h —— 本地视频的音轨 → PCM（S16 / 48k / 立体声）
//
//  为什么需要它：本地视频替换只换了画面，声音还是麦克风。
//  这里用 AVAssetReader 把 mp4/mov 的音轨解成 PCM，再由采集桥写进摄像头的音频帧。
//

#import <Foundation/Foundation.h>

@interface BXLocalAudio : NSObject

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error;
- (void)unload;

@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property (nonatomic, readonly) NSString *path;

/// 是否循环
@property (nonatomic, assign) BOOL loop;

/// 读出最多 maxFrames 帧（S16 交错、48k、立体声）。返回实际帧数，0 表示暂时没有。
- (NSUInteger)readS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames;
/// 让本地音频按摄像头真实采样率/声道数输出（否则会变调/声道错位）
- (void)configureSampleRate:(double)rate channels:(int)channels;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) int channels;

@end
