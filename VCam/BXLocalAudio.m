//
//  BXLocalAudio.m
//
//  AVAssetReader 解音轨 → PCM S16 48k 立体声，交给采集桥写进摄像头音频帧。
//  循环播放由 loop 控制（读到结尾重新开始）。
//

#import "BXLocalAudio.h"
#import <AVFoundation/AVFoundation.h>

@interface BXLocalAudio ()
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation BXLocalAudio {
    double _outRate;
    int _outCh;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _loop = YES;
    }
    return self;
}

- (NSString *)path { return self.url.path; }

- (void)unload {
    [_lock lock];
    [self.reader cancelReading];
    self.reader = nil;
    self.output = nil;
    self.asset = nil;
    self.url = nil;
    self.loaded = NO;
    [_lock unlock];
}

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error {
    [self unload];
    if (!url) return NO;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) {
        NSLog(@"[BXFloat][audio] 该视频没有音轨: %@", url.lastPathComponent);
        return NO;
    }

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(_outRate > 0 ? _outRate : 48000),
        AVNumberOfChannelsKey: @(_outCh > 0 ? _outCh : 2),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        if (error) *error = err;
        return NO;
    }

    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                  outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) {
        if (error) *error = [NSError errorWithDomain:@"BXAudio" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法添加音频输出"}];
        return NO;
    }
    [reader addOutput:out];
    [reader startReading];

    [_lock lock];
    self.asset = asset;
    self.reader = reader;
    self.output = out;
    self.url = url;
    self.loaded = YES;
    [_lock unlock];

    NSLog(@"[BXFloat][audio] 本地音轨已载入: %@", url.lastPathComponent);
    return YES;
}

- (void)configureSampleRate:(double)rate channels:(int)channels {
    if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8) return;
    int r = (int)llround(rate);
    if ((int)_outRate == r && _outCh == channels) return;
    _outRate = rate;
    _outCh = channels;
    // 已加载就按新格式重开一次 reader，readS16 出来的就是摄像头要的规格
    if (self.loaded && self.url) {
        NSError *e = nil;
        [self loadURL:self.url error:&e];
    }
}

- (double)sampleRate { return _outRate > 0 ? _outRate : 48000; }
- (int)channels { return _outCh > 0 ? _outCh : 2; }

- (NSUInteger)readS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;

    [_lock lock];
    if (!self.loaded || !self.reader) {
        [_lock unlock];
        return 0;
    }

    NSUInteger written = 0;

    while (written < maxFrames) {
        if (self.reader.status != AVAssetReaderStatusReading) {
            if (self.loop && self.reader.status == AVAssetReaderStatusCompleted) {
                // 循环：重建 reader
                NSError *err = nil;
                AVAssetReader *r = [AVAssetReader assetReaderWithAsset:self.asset error:&err];
                if (!r) break;
                if (![r canAddOutput:self.output]) break;
                self.output = [AVAssetReaderTrackOutput
                               assetReaderTrackOutputWithTrack:[[self.asset tracksWithMediaType:AVMediaTypeAudio] firstObject]
                                               outputSettings:self.output.outputSettings];
                self.output.alwaysCopiesSampleData = NO;
                [r addOutput:self.output];
                [r startReading];
                self.reader = r;
                continue;
            }
            break;
        }

        CMSampleBufferRef sb = [self.output copyNextSampleBuffer];
        if (!sb) break;

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sb);
        if (block) {
            size_t len = 0;
            char *ptr = NULL;
            if (CMBlockBufferGetDataPointer(block, 0, NULL, &len, &ptr) == kCMBlockBufferNoErr && ptr) {
                size_t frames = len / (2 * sizeof(int16_t));      // 立体声 S16
                size_t copy = MIN(frames, maxFrames - written);
                memcpy(dst + written * 2, ptr, copy * 2 * sizeof(int16_t));
                written += copy;
            }
        }
        CFRelease(sb);
        if (written >= maxFrames) break;
    }

    [_lock unlock];
    return written;
}

@end
