//
//  VCamOBSSource.m
//  VCam
//
//  OBS / 电脑推流源（需要 VCAM_ENABLE_OBS=1，即链接 FFmpeg）。
//  数据流：
//    OBS --MPEG-TS over UDP/TCP--> VCamTSDemuxer
//        ├─ H.264 包 --> VCamVideoToolboxDecoder --> VCamConcurrentQueue
//        │                                              │ (按 targetFPS 取最新帧)
//        │                                              └--> emitPixelBuffer --> 相机注入层
//        └─ AAC 包  --> VCamOBSAudioDecoder --> PCM --> audioHandler --> 麦克风注入层
//
//  断流处理：超过 stallTimeout 秒没有新帧，就送"最后一帧"或占位图，
//  避免预览黑屏 / 录制器超时。UI 上显示"等待 OBS"。
//

#import "VCamOBSSource.h"
#import "VCamConfig.h"
#import "VCamTSDemuxer.h"
#import "VCamVideoToolboxDecoder.h"
#import "VCamOBSAudioDecoder.h"
#import <os/lock.h>

@implementation VCamOBSSource {
    VCamTSDemuxer *_demuxer;
    VCamVideoToolboxDecoder *_videoDecoder;
    VCamOBSAudioDecoder *_audioDecoder;
    VCamConcurrentQueue *_frameQueue;
    dispatch_source_t _pullTimer;

    os_unfair_lock _lock;
    NSTimeInterval _lastFrameTime;
    CVPixelBufferRef _lastFrame;        // holdLastFrame 用
    BOOL _receiving;
    uint64_t _decoded, _dropped;
    CGSize _streamSize;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _transport = @"udp";
        _stallTimeout = 1.0;
        _holdLastFrame = YES;
        _frameQueue = [[VCamConcurrentQueue alloc] initWithCapacity:3];  // 只留 3 帧，低延迟
    }
    return self;
}

- (void)dealloc { [self invalidate]; }

- (NSString *)statusText {
    if (!self.isReady) return @"OBS · 等待推流";
    CGSize s = _streamSize.width > 0 ? _streamSize : self.targetSize;
    return [NSString stringWithFormat:@"OBS · %.0fx%.0f · %.0fkbps · 丢%llu",
            s.width, s.height, self.bitrateKbps, (unsigned long long)_dropped];
}

- (BOOL)isReady { return _decoded > 0; }
- (double)bitrateKbps { return _demuxer ? _demuxer.bitrateKbps : 0; }
- (uint64_t)decodedFrames { return _decoded; }
- (uint64_t)droppedFrames { return _dropped; }
- (BOOL)receiving {
    os_unfair_lock_lock(&_lock);
    BOOL v = _receiving && (NSDate.date.timeIntervalSince1970 - _lastFrameTime) < self.stallTimeout;
    os_unfair_lock_unlock(&_lock);
    return v;
}

#pragma mark - 启停

- (BOOL)start {
    if (_demuxer) return YES;

    NSString *url = self.urlString;
    uint16_t port = 5600;
    if (url.length == 0) {
        // 监听所有网卡：0.0.0.0
        url = [NSString stringWithFormat:@"%@://0.0.0.0:%u", self.transport, port];
    } else {
        // 从 URL 里抠出端口，给 AudioConverter / 日志用
        NSArray<NSString *> *parts = [url componentsSeparatedByString:@":"];
        if (parts.count >= 3) port = (uint16_t)parts.lastObject.intValue;
    }

    _demuxer = [[VCamTSDemuxer alloc] initWithURLString:url transport:self.transport];
    _videoDecoder = [[VCamVideoToolboxDecoder alloc] initWithDelegate:nil];
    _videoDecoder.outputQueue = _frameQueue;
    _videoDecoder.expectedSize = self.targetSize;
    [_videoDecoder start];

    _audioDecoder = [[VCamOBSAudioDecoder alloc] init];
    _audioDecoder.outputSampleRate = 48000;
    _audioDecoder.outputChannels = 2;
    _audioDecoder.gain = 1.0f;

    __weak typeof(self) weakSelf = self;
    _audioDecoder.pcmHandler = ^(const float *interleaved, size_t frames,
                                 UInt32 channels, Float64 sampleRate, CMTime ts) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        VCamAudioHandler ah = self.audioHandler;
        if (!ah) return;
        @try { ah(interleaved, frames, channels, sampleRate, ts); }
        @catch (NSException *e) { VCamLog(@"[obs] audio handler 异常 %@", e); }
    };

    _demuxer.videoHandler = ^(NSData *packet, NSData *extradata, BOOL key, int64_t ptsMs) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self->_videoDecoder feedAccessUnit:packet extradata:extradata
                                 isKeyframe:key ptsMs:ptsMs];
        os_unfair_lock_lock(&self->_lock);
        self->_lastFrameTime = NSDate.date.timeIntervalSince1970;
        self->_receiving = YES;
        os_unfair_lock_unlock(&self->_lock);
    };
    _demuxer.audioHandler = ^(NSData *packet, NSData *extradata, int sampleRate,
                              int channels, int64_t ptsMs) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self->_audioDecoder feedAACFrame:packet extradata:extradata
                               sampleRate:sampleRate channels:channels ptsMs:ptsMs];
    };

    if (![_demuxer start]) {
        self.lastError = _demuxer.lastError ?: @"OBS 接收启动失败";
        [self stop];
        return NO;
    }

    // ---- 帧拉取 ----
    // 不直接使用解码回调里的帧：解码速度与显示速度解耦，
    // 由这个 timer 按 targetFPS 从队列取"最新一帧"，天然实现丢帧防延迟累积。
    if (_pullTimer) dispatch_source_cancel(_pullTimer);
    _pullTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    NSInteger fps = MAX(1, self.targetFPS);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / (uint64_t)fps);
    dispatch_source_set_timer(_pullTimer, DISPATCH_TIME_NOW, interval, interval / 8);
    dispatch_source_set_event_handler(_pullTimer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _pullFrame];
    });
    dispatch_resume(_pullTimer);

    VCamLog(@"[obs] 已在 %@ 开始监听（端口 %u）", url, port);
    return YES;
}

- (void)_pullFrame {
    CMTime ts = kCMTimeInvalid;
    CVPixelBufferRef pb = [_frameQueue dequeueLatestPixelBufferWithTime:&ts];

    if (pb) {
        os_unfair_lock_lock(&_lock);
        if (_lastFrame) CVPixelBufferRelease(_lastFrame);
        _lastFrame = CVPixelBufferRetain(pb);
        _lastFrameTime = NSDate.date.timeIntervalSince1970;
        _streamSize = CGSizeMake(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
        _decoded++;
        os_unfair_lock_unlock(&_lock);

        [self emitPixelBuffer:pb atStreamTime:ts];
        CVPixelBufferRelease(pb);
        return;
    }

    // 队列空 = 断流或还没解出帧
    NSTimeInterval silence;
    os_unfair_lock_lock(&_lock);
    silence = NSDate.date.timeIntervalSince1970 - _lastFrameTime;
    CVPixelBufferRef last = _lastFrame ? CVPixelBufferRetain(_lastFrame) : NULL;
    os_unfair_lock_unlock(&_lock);

    if (silence < self.stallTimeout) {
        if (last) CVPixelBufferRelease(last);
        return;   // 还在正常间隔内
    }

    if (self.holdLastFrame && last) {
        // 保持最后一帧：画面不闪黑，时间戳用当前时间（否则录制器会超时）
        [self emitPixelBuffer:last atStreamTime:CMClockGetTime(CMClockGetHostTimeClock())];
    } else {
        // 占位帧：明确告诉用户"等待 OBS"。限制生成频率，别浪费 CPU。
        static uint64_t lastPlaceholderTick = 0;
        uint64_t now = mach_absolute_time();
        static mach_timebase_info_data_t tb;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mach_timebase_info(&tb); });
        uint64_t nowNs = now * tb.numer / tb.denom;
        if (nowNs - lastPlaceholderTick > 500000000ull) {   // 最多 2fps
            lastPlaceholderTick = nowNs;
            CGSize s = self.targetSize;
            CVPixelBufferRef ph = [VCamPixelBufferUtils placeholderPixelBufferWithWidth:(size_t)s.width
                                                                                 height:(size_t)s.height
                                                                                   text:@"等待 OBS 推流…"];
            if (ph) {
                [self emitPixelBuffer:ph atStreamTime:CMClockGetTime(CMClockGetHostTimeClock())];
                CVPixelBufferRelease(ph);
            }
        }
    }
    os_unfair_lock_lock(&_lock);
    _dropped++;
    os_unfair_lock_unlock(&_lock);
    if (last) CVPixelBufferRelease(last);
}

- (void)stop {
    if (_pullTimer) { dispatch_source_cancel(_pullTimer); _pullTimer = nil; }
    if (_demuxer) { [_demuxer stop]; _demuxer = nil; }
    if (_videoDecoder) { [_videoDecoder stop]; _videoDecoder = nil; }
    if (_audioDecoder) { [_audioDecoder reset]; _audioDecoder = nil; }
    [_frameQueue flush];
    os_unfair_lock_lock(&_lock);
    if (_lastFrame) { CVPixelBufferRelease(_lastFrame); _lastFrame = NULL; }
    _receiving = NO;
    os_unfair_lock_unlock(&_lock);
}

- (void)invalidate {
    [self stop];
    _frameQueue = nil;
    os_unfair_lock_lock(&_lock);
    _decoded = 0;
    _dropped = 0;
    _streamSize = CGSizeZero;
    os_unfair_lock_unlock(&_lock);
}

@end
