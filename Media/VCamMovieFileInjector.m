//
//  VCamMovieFileInjector.m
//  VCam
//

#import "VCamMovieFileInjector.h"
#import "VCamConfig.h"
#import "VCamCore.h"
#import "VCamPixelBufferUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <os/lock.h>

static const void *kVCamRecSwizzledKey = &kVCamRecSwizzledKey;

#pragma mark - 影子录制器

/// 负责把虚拟帧 + 虚拟音频写成 H.264/AAC 的 mp4
@interface VCamShadowRecorder : NSObject
@property (nonatomic, copy) NSURL *destinationURL;   // App 期望的最终路径
@property (nonatomic, copy) NSURL *tempURL;          // 我们实际写的临时文件
@property (nonatomic, strong, nullable) AVAssetWriter *writer;
@property (nonatomic, strong, nullable) AVAssetWriterInput *videoInput;
@property (nonatomic, strong, nullable) AVAssetWriterInput *audioInput;
@property (nonatomic, strong, nullable) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, assign) dispatch_source_t frameTimer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL audioStarted;
@property (nonatomic, assign) CMTime firstPTS;
@property (nonatomic, assign) uint64_t framesWritten;
- (BOOL)beginWritingWithSize:(CGSize)size fps:(NSInteger)fps;
- (void)appendAudioPCM:(const float *)pcm
                frames:(size_t)frames
              channels:(UInt32)channels
            sampleRate:(Float64)rate;
- (void)finishWithCompletion:(void (^)(BOOL ok))completion;
@end

static os_unfair_lock gRecLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, VCamShadowRecorder *> *gRecorders = nil;

@implementation VCamShadowRecorder

- (BOOL)beginWritingWithSize:(CGSize)size fps:(NSInteger)fps {
    if (_writer) return YES;
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtURL:_tempURL error:NULL];
    _writer = [AVAssetWriter assetWriterWithURL:_tempURL fileType:AVFileTypeMPEG4 error:&err];
    if (!_writer) {
        VCamLog(@"[movie] 创建 writer 失败: %@", err.localizedDescription);
        return NO;
    }

    // ---- 视频 ----
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(6 * 1024 * 1024),      // 6Mbps，1080p 足够
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: @(fps),             // 1 秒一个关键帧
            AVVideoExpectedSourceFrameRateKey: @(fps),
            AVVideoAllowFrameReorderingKey: @(NO),             // 低延迟
        },
    };
    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                     outputSettings:settings];
    _videoInput.expectsMediaDataInRealTime = YES;   // 实时录制必须开

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey: @(size.width),
        (id)kCVPixelBufferHeightKey: @(size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput
                                           sourcePixelBufferAttributes:attrs];
    if ([_writer canAddInput:_videoInput]) [_writer addInput:_videoInput];

    // ---- 音频 ----
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    NSDictionary *aSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: @(2),
        AVSampleRateKey: @(48000),
        AVEncoderBitRateKey: @(128000),
        AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof(layout)],
    };
    _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:aSettings];
    _audioInput.expectsMediaDataInRealTime = YES;
    if ([_writer canAddInput:_audioInput]) [_writer addInput:_audioInput];

    if (![_writer startWriting]) {
        VCamLog(@"[movie] startWriting 失败: %@", _writer.error.localizedDescription);
        return NO;
    }
    [_writer startSessionAtSourceTime:kCMTimeZero];
    _firstPTS = kCMTimeInvalid;
    _running = YES;
    _framesWritten = 0;

    VCamLog(@"[movie] 影子录制已开始 %@ (%.0fx%.0f @%ldfps)", _tempURL.lastPathComponent,
            size.width, size.height, (long)fps);
    return YES;
}

- (void)appendAudioPCM:(const float *)pcm
                frames:(size_t)frames
              channels:(UInt32)channels
            sampleRate:(Float64)rate {
    if (!_running || !_audioInput || !_audioInput.isReadyForMoreMediaData) return;
    if (frames == 0) return;

    CMTime ts = CMClockGetTime(CMClockGetHostTimeClock());
    if (!CMTIME_IS_NUMERIC(_firstPTS)) {
        _firstPTS = ts;
        ts = kCMTimeZero;
    } else {
        ts = CMTimeSubtract(ts, _firstPTS);
    }
    if (CMTIME_COMPARE_INLINE(ts, <, kCMTimeZero)) ts = kCMTimeZero;

    CMSampleBufferRef sb = [VCamPixelBufferUtils sampleBufferFromFloat32PCM:pcm
                                                                    frames:frames
                                                                  channels:channels
                                                                sampleRate:rate
                                                                  hostTime:ts];
    if (!sb) return;
    if ([_audioInput appendSampleBuffer:sb]) _audioStarted = YES;
    CFRelease(sb);
}

- (void)finishWithCompletion:(void (^)(BOOL))completion {
    _running = NO;
    if (_frameTimer) {
        dispatch_source_cancel(_frameTimer);
        _frameTimer = nil;
    }
    if (!_writer) {
        if (completion) completion(NO);
        return;
    }
    AVAssetWriter *w = _writer;
    AVAssetWriterInput *v = _videoInput, *a = _audioInput;
    [v markAsFinished];
    if (_audioStarted) [a markAsFinished];
    [w finishWritingWithCompletionHandler:^{
        BOOL ok = (w.status == AVAssetWriterStatusCompleted);
        if (!ok) {
            VCamLog(@"[movie] finishWriting 失败 status=%ld err=%@",
                    (long)w.status, w.error.localizedDescription);
        }
        if (completion) completion(ok);
    }];
}

@end

#pragma mark - 注入器

@implementation VCamMovieFileInjector

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        os_unfair_lock_lock(&gRecLock);
        if (!gRecorders) gRecorders = [NSMutableDictionary dictionary];
        os_unfair_lock_unlock(&gRecLock);

        Class cls = NSClassFromString(@"AVCaptureMovieFileOutput");
        if (!cls) {
            VCamLog(@"[movie] 找不到 AVCaptureMovieFileOutput");
            return;
        }
        [self _swizzle:cls
          originalSel:@selector(startRecordingToOutputFileURL:recordingDelegate:)
        replacementSel:@selector(vcam_startRecordingToOutputFileURL:recordingDelegate:)];
        [self _swizzle:cls
          originalSel:@selector(stopRecording)
        replacementSel:@selector(vcam_stopRecording)];
        VCamLog(@"[movie] 录像注入已安装");
    });
}

+ (void)_swizzle:(Class)cls originalSel:(SEL)orig replacementSel:(SEL)repl {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

/// 给 App 的录制 delegate 装拦截（换文件）
+ (void)vcam_instrumentRecordingDelegate:(id)delegate {
    if (!delegate) return;
    if (objc_getAssociatedObject(delegate, kVCamRecSwizzledKey)) return;
    objc_setAssociatedObject(delegate, kVCamRecSwizzledKey, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
    Class cls = object_getClass(delegate);
    Class target = nil;
    Method m = NULL;
    for (Class c = cls; c && c != NSObject.class; c = class_getSuperclass(c)) {
        Method cm = class_getInstanceMethod(c, sel);
        if (cm) { m = cm; target = c; break; }
    }
    if (!m || !target) {
        VCamLog(@"[movie] delegate 未实现 didFinishRecording 回调，跳过文件替换");
        return;
    }
    const char *types = method_getTypeEncoding(m);
    IMP original = method_getImplementation(m);
    SEL mangled = NSSelectorFromString(
        @"VCamOriginal_captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:");
    class_addMethod(target, mangled, original, types);
    class_replaceMethod(target, sel, (IMP)vcam_didFinishRecording, types);
    VCamLog(@"[movie] 已为录制 delegate %@ 安装文件替换", NSStringFromClass(cls));
}

/// 替换实现：先做文件替换，再转发给 App
static void vcam_didFinishRecording(id self, SEL _cmd, AVCaptureFileOutput *output,
                                    NSURL *outputFileURL, NSArray *connections,
                                    NSError *error) {
    if (outputFileURL && !error) {
        @try {
            [VCamMovieFileInjector vcam_swapInVirtualMovieForURL:outputFileURL];
        } @catch (NSException *e) {
            VCamLog(@"[movie] 替换录像文件异常: %@", e);
        }
    }
    SEL orig = NSSelectorFromString(
        @"VCamOriginal_captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:");
    if ([self respondsToSelector:orig]) {
        typedef void (*Fn)(id, SEL, id, id, id, id);
        Fn fn = (Fn)[self methodForSelector:orig];
        if (fn) fn(self, orig, output, outputFileURL, connections, error);
    }
}

/// 把影子文件搬到 App 期望的路径
+ (void)vcam_swapInVirtualMovieForURL:(NSURL *)url {
    NSString *key = url.path;
    os_unfair_lock_lock(&gRecLock);
    VCamShadowRecorder *rec = gRecorders[key];
    [gRecorders removeObjectForKey:key];
    os_unfair_lock_unlock(&gRecLock);

    if (!rec) return;
    // 影子录制可能还在收尾，给它最多 3 秒
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [rec finishWithCompletion:^(BOOL ok) {
        done = ok;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));

    if (!done || rec.framesWritten == 0) {
        VCamLog(@"[movie] 影子录制未完成（写入 %llu 帧），保留原始录像",
                (unsigned long long)rec.framesWritten);
        [[NSFileManager defaultManager] removeItemAtURL:rec.tempURL error:NULL];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    // 先备份原文件，替换失败时能回滚
    NSURL *backup = [NSURL fileURLWithPath:[url.path stringByAppendingString:@".vcam_real"]];
    [fm removeItemAtURL:backup error:NULL];
    if ([fm fileExistsAtPath:url.path]) {
        [fm moveItemAtURL:url toURL:backup error:NULL];
    }
    NSError *err = nil;
    if ([fm moveItemAtURL:rec.tempURL toURL:url error:&err]) {
        [fm removeItemAtURL:backup error:NULL];
        VCamLog(@"[movie] 已用虚拟录像替换 %@（%llu 帧）",
                url.lastPathComponent, (unsigned long long)rec.framesWritten);
    } else {
        VCamLog(@"[movie] 替换失败: %@，回滚原始录像", err.localizedDescription);
        [fm removeItemAtURL:url error:NULL];
        if ([fm fileExistsAtPath:backup.path]) [fm moveItemAtURL:backup toURL:url error:NULL];
    }
}

@end

#pragma mark - AVCaptureMovieFileOutput 替换实现

@implementation AVCaptureMovieFileOutput (VCamInject)

- (void)vcam_startRecordingToOutputFileURL:(NSURL *)outputFileURL
                         recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    @try {
        VCamCore *core = [VCamCore shared];
        if (core.active && outputFileURL && delegate) {
            [VCamMovieFileInjector vcam_instrumentRecordingDelegate:delegate];

            NSString *tmp = [VCamRecordingTempDirectory()
                stringByAppendingPathComponent:
                [NSString stringWithFormat:@"shadow_%u.mp4", arc4random()]];
            VCamShadowRecorder *rec = [[VCamShadowRecorder alloc] init];
            rec.destinationURL = outputFileURL;
            rec.tempURL = [NSURL fileURLWithPath:tmp];

            // 尺寸：用虚拟源的输出尺寸（竖屏 1080x1920）。
            // 如果 App 指定了横屏，AVAssetWriter 会自动按我们给的尺寸录，
            // App 播放时按元数据旋转，不会变形。
            CGSize size = CGSizeMake(1080, 1920);
            NSInteger fps = 30;
            if ([rec beginWritingWithSize:size fps:fps]) {
                os_unfair_lock_lock(&gRecLock);
                gRecorders[outputFileURL.path] = rec;
                os_unfair_lock_unlock(&gRecLock);

                // 启动帧循环
                __weak VCamShadowRecorder *weakRec = rec;
                dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
                rec.frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
                uint64_t interval = NSEC_PER_SEC / (uint64_t)fps;
                dispatch_source_set_timer(rec.frameTimer, DISPATCH_TIME_NOW, interval, interval / 8);
                dispatch_source_set_event_handler(rec.frameTimer, ^{
                    VCamShadowRecorder *r = weakRec;
                    if (!r || !r.running) return;

                    // ---- 视频帧 ----
                    if (r.videoInput.isReadyForMoreMediaData) {
                        CVPixelBufferRef pb = [[VCamCore shared]
                            copyPixelBufferForWidth:(size_t)size.width height:(size_t)size.height];
                        if (pb) {
                            CMTime ts = CMClockGetTime(CMClockGetHostTimeClock());
                            if (!CMTIME_IS_NUMERIC(r.firstPTS)) {
                                r.firstPTS = ts;
                                ts = kCMTimeZero;
                            } else {
                                ts = CMTimeSubtract(ts, r.firstPTS);
                            }
                            if (CMTIME_COMPARE_INLINE(ts, <, kCMTimeZero)) ts = kCMTimeZero;
                            if ([r.adaptor appendPixelBuffer:pb withPresentationTime:ts]) {
                                r.framesWritten++;
                            }
                            CVPixelBufferRelease(pb);
                        }
                    }

                    // ---- 音频 ----
                    if (r.audioInput.isReadyForMoreMediaData) {
                        const size_t frames = 1024;
                        float pcm[frames * 2];
                        size_t got = [[VCamCore shared] pullPCMInto:pcm maxFrames:frames
                                                          channels:2 sampleRate:48000];
                        if (got > 0) {
                            [r appendAudioPCM:pcm frames:got channels:2 sampleRate:48000];
                        }
                    }
                });
                dispatch_resume(rec.frameTimer);
            }
        }
    } @catch (NSException *e) {
        VCamLog(@"[movie] 启动影子录制异常（不影响真实录制）: %@", e);
    }
    [self vcam_startRecordingToOutputFileURL:outputFileURL recordingDelegate:delegate];
}

- (void)vcam_stopRecording {
    // 影子录制在 delegate 回调里收尾（因为要知道最终文件路径与是否有错误）
    [self vcam_stopRecording];
}

@end
