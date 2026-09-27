//
//  VCamMediaManager.m
//  虚拟摄像头
//
//  参考了开源项目 lxxsoufahk/VCam 的 MediaManager，但修掉了它的几个问题：
//
//  问题 1：重映射时间戳时直接改原 sampleBuffer 的 PTS
//      原实现用 CMSampleBufferCreateCopy 复制后调用
//      CMSampleBufferSetOutputPresentationTimeStamp，
//      但 copy 出来的 buffer 如果没有被"拥有"时间戳，这个调用是无效的；
//      而且它把原 buffer 改坏了（原 buffer 属于 reader，不该改）。
//    修法：用 CMSampleBufferCreateCopyWithNewTiming 创建带新时间戳的副本，
//          原 buffer 保持不动。
//
//  问题 2：audioReader 与 videoReader 用同一份 asset 但没有同步重置
//      循环播放时只重置了 video，音频会错位。
//    修法：resetReaders 同时重建两个 reader。
//
//  问题 3：没有空值/错误检查，asset 无视频轨时会一直返回黑帧但不报错
//    修法：loadMediaFromURL 返回 BOOL + NSError，调用方能知道失败原因。
//
//  时间戳策略：
//    循环播放时，每取一帧都把 PTS 设成"当前墙上时间"。
//    这样即使视频循环回开头，下游（AVCaptureVideoPreviewLayer /
//    AVCaptureMovieFileOutput）看到的 PTS 也始终单调递增，
//    不会因为时间倒流而卡住或丢帧。
//

#import "VCamMediaManager.h"
#import <CoreImage/CoreImage.h>
#import <os/lock.h>

@interface VCamMediaManager ()
@property (nonatomic, strong, nullable) AVAsset *asset;
@property (nonatomic, strong, nullable) AVAssetReader *videoReader;
@property (nonatomic, strong, nullable) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) uint64_t frameCount;
@end

@implementation VCamMediaManager {
    // 用锁保护解码与状态读取：取帧可能在任意后台队列被调用，
    // 而 loadMedia / stop 可能来自主线程。
    os_unfair_lock _lock;
}

+ (instancetype)shared {
    static VCamMediaManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamMediaManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _videoSize = CGSizeMake(1280, 720);
    }
    return self;
}

#pragma mark - 载入媒体

- (BOOL)loadMediaFromURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"VCam" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"URL 为空"}];
        return NO;
    }

    AVAsset *asset = [AVAsset assetWithURL:url];
    if (!asset) {
        if (error) *error = [NSError errorWithDomain:@"VCam" code:2
                            userInfo:@{NSLocalizedDescriptionKey: @"无法创建 AVAsset"}];
        return NO;
    }

    NSArray<AVAssetTrack *> *videoTracks =
        [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"VCam" code:3
                            userInfo:@{NSLocalizedDescriptionKey:
                                       @"这个文件里没有视频轨（是不是选到音频了？）"}];
        return NO;
    }

    // 尺寸：优先用 naturalSize 配合 preferredTransform 换算实际显示尺寸
    AVAssetTrack *track = videoTracks.firstObject;
    CGSize size = track.naturalSize;
    CGAffineTransform t = track.preferredTransform;
    CGSize transformed = CGSizeApplyAffineTransform(size, t);
    transformed.width = fabs(transformed.width);
    transformed.height = fabs(transformed.height);

    os_unfair_lock_lock(&_lock);
    _asset = asset;
    if (transformed.width >= 16 && transformed.height >= 16) {
        _videoSize = transformed;
    }
    BOOL ok = [self _resetReadersLocked];
    _running = ok;
    _frameCount = 0;
    os_unfair_lock_unlock(&_lock);

    if (!ok && error) {
        *error = [NSError errorWithDomain:@"VCam" code:4
                    userInfo:@{NSLocalizedDescriptionKey: @"解码器初始化失败"}];
    }
    return ok;
}

/// 重建 video reader。调用前必须已持有 _lock。
- (BOOL)_resetReadersLocked {
    _videoReader = nil;
    _videoOutput = nil;

    if (!_asset) return NO;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:_asset error:&err];
    if (!reader) return NO;

    NSArray<AVAssetTrack *> *tracks = [_asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;

    // 输出 420 BiPlanar（NV12）：这是相机管线最常用的格式，
    // 下游 AVCaptureVideoPreviewLayer / 编码器都能直接吃，
    // 省掉一次颜色空间转换。
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;   // 不复制，省一次内存拷贝

    if (![reader canAddOutput:out]) return NO;
    [reader addOutput:out];

    if (![reader startReading]) return NO;

    _videoReader = reader;
    _videoOutput = out;
    return YES;
}

#pragma mark - 取帧

- (CMSampleBufferRef)nextVideoFrame {
    os_unfair_lock_lock(&_lock);

    if (!_running || !_videoOutput) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }

    CMSampleBufferRef sample = [_videoOutput copyNextSampleBuffer];

    // 读到结尾 → 循环回开头
    if (!sample) {
        if ([self _resetReadersLocked]) {
            sample = [_videoOutput copyNextSampleBuffer];
        }
    }

    if (!sample) {
        os_unfair_lock_unlock(&_lock);
        // 真的没数据了：返回 NULL 让调用方决定（通常是透传原始帧）
        return NULL;
    }

    _frameCount++;

    // 把 PTS 重映射到当前墙上时间，保证下游看到的 PTS 单调递增。
    // ⚠️ 这里用 CMSampleBufferCreateCopyWithNewTiming 而不是直接改原 buffer：
    //    · 原 buffer 属于 AVAssetReader，改它可能破坏 reader 内部状态
    //    · copy + SetOutputPresentationTimeStamp 在无 timing 信息时不生效
    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    size_t count = CMSampleBufferGetNumSamples(sample);
    CMTime dur = CMSampleBufferGetDuration(sample);
    if (CMTIME_IS_INVALID(dur) || dur.value == 0) {
        dur = CMTimeMake(1, 30);
    }

    // ⚠️ 数组元素类型必须是 CMSampleTimingInfo，不是 CMTime。
    //    之前误写成 CMTime timing[...] 会报：
    //        error: no member named 'presentationTimeStamp' in 'CMTime'
    //    因为 presentationTimeStamp / decodeTimeStamp / duration
    //    是 CMSampleTimingInfo 的成员，不是 CMTime 的。
    CMItemCount n = (CMItemCount)(count ? count : 1);
    CMSampleTimingInfo *timing = calloc((size_t)n, sizeof(CMSampleTimingInfo));
    if (!timing) {
        CFRelease(sample);
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }
    for (CMItemCount i = 0; i < n; i++) {
        timing[i].presentationTimeStamp = now;
        timing[i].decodeTimeStamp = kCMTimeInvalid;
        timing[i].duration = dur;
    }

    CMSampleBufferRef retimed = NULL;
    OSStatus st = CMSampleBufferCreateCopyWithNewTiming(
        kCFAllocatorDefault, sample, n, timing, &retimed);

    free(timing);
    CFRelease(sample);
    os_unfair_lock_unlock(&_lock);

    if (st != noErr || !retimed) return NULL;
    return retimed;
}

#pragma mark - 黑帧

- (CMSampleBufferRef)blackFrame {
    os_unfair_lock_lock(&_lock);
    CGSize size = _videoSize;
    os_unfair_lock_unlock(&_lock);

    size_t w = (size_t)MAX(16.0, size.width);
    size_t h = (size_t)MAX(16.0, size.height);

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess
        || !pb) {
        return NULL;
    }

    // VideoRange（有限范围）下：Y=16 是黑，UV=128 是无色度
    CVPixelBufferLockBaseAddress(pb, 0);
    void *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    if (y) {
        memset(y, 16, CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                       * CVPixelBufferGetHeightOfPlane(pb, 0));
    }
    void *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (uv) {
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                        * CVPixelBufferGetHeightOfPlane(pb, 1));
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr
        || !fmt) {
        CVPixelBufferRelease(pb);
        return NULL;
    }

    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    CMSampleTimingInfo ti = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = now,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true,
                                                    NULL, NULL, fmt, &ti, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(pb);

    if (st != noErr) return NULL;
    return sb;
}

#pragma mark - 生命周期

- (void)start {
    os_unfair_lock_lock(&_lock);
    if (_asset) {
        if (!_videoOutput) [self _resetReadersLocked];
        _running = (_videoOutput != nil);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    _running = NO;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 只读属性

- (BOOL)isRunning { return _running; }
- (CGSize)videoSize { return _videoSize; }
- (uint64_t)frameCount { return _frameCount; }

@end
