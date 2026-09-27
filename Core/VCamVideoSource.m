//
//  VCamVideoSource.m
//  VCam
//

#import "VCamVideoSource.h"
#import "VCamConfig.h"
#import <os/lock.h>
#import <AudioToolbox/AudioToolbox.h>

/// 音频管线只跑在 mediaserverd / App 内部，用固定采样率输出 PCM
static const Float64 kVCamPCMOutSampleRate = 48000.0;
static const UInt32  kVCamPCMOutChannels   = 2;

@implementation VCamVideoSource {
    NSString *_path;
    AVPlayer *_player;
    AVPlayerItem *_item;
    AVPlayerItemVideoOutput *_videoOutput;
    id _endObserver;

    dispatch_source_t _pollTimer;      ///< 以 display 频率轮询新帧
    dispatch_queue_t _audioQueue;
    dispatch_source_t _audioTimer;     ///< 音频定时补充（防 underrun）
    BOOL _audioRunning;

    AVAsset *_asset;
    double _duration;
    BOOL _hasAudio;
    os_unfair_lock _lock;
}

- (instancetype)initWithVideoPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _loop = YES;
        _audioGain = 1.0f;
        _lock = OS_UNFAIR_LOCK_INIT;
        _targetFPS = 30;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (NSString *)statusText {
    CGSize s = self.targetSize;
    NSString *audio = _hasAudio ? (self.audioHandler ? @"有声" : @"静音") : @"无音轨";
    return [NSString stringWithFormat:@"视频 · %.0fx%.0f · %ldfps · %@%@",
            s.width, s.height, (long)self.targetFPS, audio, self.loop ? @" · 循环" : @""];
}

- (BOOL)isReady { return _item != nil && _player != nil; }
- (BOOL)hasAudioTrack { return _hasAudio; }

- (double)currentSeconds {
    CMTime t = _player.currentTime;
    return CMTIME_IS_NUMERIC(t) ? CMTimeGetSeconds(t) : 0.0;
}

- (double)durationSeconds { return _duration; }

#pragma mark - 启动

- (BOOL)start {
    if (_path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:_path]) {
        self.lastError = [NSString stringWithFormat:@"视频文件不存在: %@", _path ?: @"(空)"];
        VCamLog(@"[vid] %@", self.lastError);
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:_path];
    _asset = [AVURLAsset URLAssetWithURL:url options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @(YES),
    }];
    _duration = CMTIME_IS_NUMERIC(_asset.duration) ? CMTimeGetSeconds(_asset.duration) : 0.0;
    if (_duration <= 0 || isnan(_duration) || isinf(_duration)) {
        // 某些 MOV 的 moov 在文件尾部，duration 可能拿不到；给一个保守值
        _duration = 0;
    }
    _hasAudio = ([_asset tracksWithMediaType:AVMediaTypeAudio].count > 0);

    // ---- 视频：AVPlayerItemVideoOutput ----
    // pixelFormat 要 420f（bi-planar full range），与摄像头原生输出一致。
    // 如果这里写 RGBA，下游 VideoToolbox 编码前还要再转一次，白掉性能。
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:outputSettings];
    _videoOutput.suppressesPlayerRendering = YES;   // 不要它自己渲染，我们只要 buffer

    _item = [AVPlayerItem playerItemWithAsset:_asset];
    [_item addOutput:_videoOutput];

    // 循环：AVPlayer 的 actionAtItemEnd 只有 none/pause，循环要自己处理
    _item.forwardPlaybackEndTime = kCMTimeInvalid;   // 不截断，播到末尾由通知处理
    _player = [AVPlayer playerWithPlayerItem:_item];
    _player.muted = YES;                 // 声音走我们自己的音频管线，不要外放
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    _player.volume = 0.0;

    __weak typeof(self) weakSelf = self;
    _endObserver = [NSNotificationCenter.defaultCenter
                    addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                object:_item
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.loop) {
            // seek 到 0 并继续；用 toleranceBefore/After = 0 保证时间轴准确
            [self->_player seekToTime:kCMTimeZero
                      toleranceBefore:kCMTimeZero
                       toleranceAfter:kCMTimeZero
                    completionHandler:^(BOOL finished) {
                if (finished) [self->_player play];
            }];
            // 音频管线重启，保证与视频从头对齐（唇形同步）
            [self _restartAudioPipeline];
        } else {
            [self->_player pause];
        }
    }];

    [_player play];

    // ---- 帧轮询 ----
    // 不依赖 CADisplayLink（daemon 进程里拿不到 screen），
    // 用 1/targetFPS*2 的频率轮询，hasNewPixelBufferForItemTime 会自然去重。
    if (_pollTimer) dispatch_source_cancel(_pollTimer);
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    NSInteger fps = MAX(1, self.targetFPS);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / (uint64_t)MIN(60, fps * 2));
    dispatch_source_set_timer(_pollTimer, DISPATCH_TIME_NOW, interval, interval / 4);
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _pollFrame];
    });
    dispatch_resume(_pollTimer);

    // ---- 音频管线 ----
    if (_hasAudio && self.audioHandler) {
        _audioQueue = dispatch_queue_create("com.quite85.vcam.video.audio", DISPATCH_QUEUE_SERIAL);
        [self _startAudioPipeline];
    }

    VCamLog(@"[vid] 启动 %@ 时长=%.2fs 音轨=%d", _path.lastPathComponent, _duration, _hasAudio);
    return YES;
}

#pragma mark - 视频轮询

- (void)_pollFrame {
    if (!_videoOutput || !_item) return;
    if (![self shouldEmitNow]) return;

    CMTime itemTime = _item.currentTime;
    if (![self->_videoOutput hasNewPixelBufferForItemTime:itemTime]) {
        // 播放器卡住（例如视频末尾暂停）时，强制推进一下
        if (_loop && _player.rate == 0.0f && _player.status == AVPlayerStatusReadyToPlay) {
            [_player play];
        }
        return;
    }
    // 注意：copyPixelBufferForItemTime 返回 +1 引用，必须 release
    CVPixelBufferRef pb = [_videoOutput copyPixelBufferForItemTime:itemTime
                                                itemTimeForDisplay:NULL];
    if (!pb) return;

    // 把"播放器时间轴"换算到 host 时基。
    // 这里不用 hostTimeForStreamTime（会漂移），而是直接用 host 当前时间：
    // 视频帧的 PTS 只要单调递增即可，预览/编码器只关心"现在这一帧"。
    [self emitPixelBuffer:pb atStreamTime:CMClockGetTime(CMClockGetHostTimeClock())];
    CVPixelBufferRelease(pb);
}

- (void)restartPlayback {
    if (!_player) return;
    [_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [_player play];
    [self resetThrottle];
    [self _restartAudioPipeline];
}

#pragma mark - 音频管线

- (void)_startAudioPipeline {
    if (_audioRunning) return;
    _audioRunning = YES;
    dispatch_async(_audioQueue, ^{
        [self _audioReadLoop];
    });
}

- (void)_restartAudioPipeline {
    _audioRunning = NO;
    // 让正在跑的 read 循环在下一次检查时退出，然后重新拉起来
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   _audioQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self _startAudioPipeline];
    });
}

/// 顺序读完整条音轨 → 送 VCamAudioHandler；结束后按 loop 决定是否重来。
/// 全程流式，不会把整个文件读进内存（AVAssetReader 内部按需解码）。
- (void)_audioReadLoop {
    while (_audioRunning) {
        @autoreleasepool {
            NSError *err = nil;
            AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:_asset error:&err];
            if (!reader) {
                VCamLog(@"[vid][audio] reader 创建失败: %@", err.localizedDescription);
                self.lastError = @"视频音轨读取失败";
                break;
            }
            AVAssetTrack *track = [_asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!track) break;

            // 输出交错 float32，采样率统一到 48k，方便直接灌给 AudioUnit
            AudioChannelLayout layout = {0};
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            NSDictionary *settings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVLinearPCMIsFloatKey: @(YES),
                AVLinearPCMIsNonInterleaved: @(NO),
                AVLinearPCMBitDepthKey: @(32),
                AVLinearPCMIsBigEndianKey: @(NO),
                AVSampleRateKey: @(kVCamPCMOutSampleRate),
                AVNumberOfChannelsKey: @(kVCamPCMOutChannels),
                AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof(layout)],
            };
            AVAssetReaderTrackOutput *out =
                [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
            out.alwaysCopiesSampleData = NO;    // 少一次拷贝
            if (![reader canAddOutput:out]) {
                VCamLog(@"[vid][audio] 无法添加输出");
                break;
            }
            [reader addOutput:out];
            if (![reader startReading]) {
                VCamLog(@"[vid][audio] startReading 失败: %@", reader.error.localizedDescription);
                break;
            }

            // 以"流时间"为锚点，把音频 PTS 映射到 host 时基
            CMTime firstPTS = kCMTimeInvalid;
            CMTime hostAnchor = CMClockGetTime(CMClockGetHostTimeClock());

            while (_audioRunning && reader.status == AVAssetReaderStatusReading) {
                CMSampleBufferRef sb = [out copyNextSampleBuffer];
                if (!sb) break;

                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
                if (!CMTIME_IS_NUMERIC(firstPTS)) firstPTS = pts;

                CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
                size_t totalLen = bb ? CMBlockBufferGetDataLength(bb) : 0;
                size_t frames = CMSampleBufferGetNumSamples(sb);

                if (bb && totalLen > 0 && frames > 0) {
                    // 用栈上小缓冲 + 分块读，避免一次 malloc 很大的块
                    const size_t chunkFrames = 4096;
                    size_t bytesPerFrame = sizeof(float) * kVCamPCMOutChannels;
                    float *scratch = (float *)malloc(chunkFrames * bytesPerFrame);
                    if (scratch) {
                        size_t byteOffset = 0;           // 在整块 PCM 中的字节偏移
                        size_t framesDone = 0;           // 已处理的帧数（算时间戳用）
                        size_t remainingFrames = frames;
                        while (remainingFrames > 0 && _audioRunning) {
                            size_t n = MIN(chunkFrames, remainingFrames);
                            size_t bytes = n * bytesPerFrame;
                            if (CMBlockBufferCopyDataBytes(bb, byteOffset, bytes, scratch) != kCMBlockBufferNoErr) break;

                            // 音量
                            float gain = self.audioGain;
                            if (gain != 1.0f) {
                                size_t count = n * kVCamPCMOutChannels;
                                for (size_t i = 0; i < count; i++) {
                                    float v = scratch[i] * gain;
                                    scratch[i] = MAX(-1.0f, MIN(1.0f, v));
                                }
                            }

                            // 时间戳：以首帧 PTS 为锚点映射到 host 时间，
                            // 再叠加块内偏移（framesDone / 采样率），保证连续无跳变。
                            CMTime rel = CMTimeSubtract(pts, firstPTS);
                            CMTime intra = CMTimeMake((int64_t)framesDone, (int32_t)kVCamPCMOutSampleRate);
                            CMTime ts = CMTimeAdd(hostAnchor, CMTimeAdd(rel, intra));

                            // 唇形同步微调：lipSyncMs > 0 表示音频延后（视频慢）
                            NSInteger lip = self.lipSyncOffsetMs;
                            if (lip != 0) {
                                ts = CMTimeAdd(ts, CMTimeMake((int64_t)lip, 1000));
                            }

                            VCamAudioHandler ah = self.audioHandler;
                            if (ah) {
                                @try { ah(scratch, n, kVCamPCMOutChannels, kVCamPCMOutSampleRate, ts); }
                                @catch (NSException *e) { VCamLog(@"[vid][audio] handler 异常 %@", e); }
                            }
                            byteOffset += bytes;
                            framesDone += n;
                            remainingFrames -= n;
                        }
                        free(scratch);
                    }
                }
                if (sb) CFRelease(sb);

                // 实时节流：音频必须按播放速度喂，否则会一次性读完导致后续 underrun
                if (_duration > 0) {
                    // 睡一小段，让读取速度 ≈ 播放速度
                    usleep(5000);
                }
            }

            AVAssetReaderStatus st = reader.status;
            [reader cancelReading];
            VCamLog(@"[vid][audio] 一轮结束 status=%ld", (long)st);

            if (!_loop || !_audioRunning) break;
            // 循环：等到视频也回到开头（避免音视频错位），再重新读
            while (_audioRunning && self.loop && _player.currentTime.seconds > 0.35) {
                usleep(10000);
            }
        }
    }
    _audioRunning = NO;
}

#pragma mark - 停止

- (void)stop {
    if (_pollTimer) { dispatch_source_cancel(_pollTimer); _pollTimer = nil; }
    _audioRunning = NO;
    if (_audioTimer) { dispatch_source_cancel(_audioTimer); _audioTimer = nil; }
    if (_endObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
        _endObserver = nil;
    }
    if (_player) { [_player pause]; [_player replaceCurrentItemWithPlayerItem:nil]; }
    if (_item && _videoOutput) { [_item removeOutput:_videoOutput]; }
    _videoOutput = nil;
    _item = nil;
    _player = nil;
    _asset = nil;
}

- (void)invalidate {
    [self stop];
    _hasAudio = NO;
    _duration = 0;
}

@end
