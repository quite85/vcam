//
//  VCamFrameSource.m
//  VCam
//

#import "VCamFrameSource.h"
#import "VCamConfig.h"
#import <os/lock.h>

@implementation VCamFrameSourceBase {
    uint64_t _lastEmitHostTime;
    dispatch_queue_t _queue;
    os_unfair_lock _lock;
}

- (instancetype)init {
    if ((self = [super init])) {
        _targetSize = CGSizeMake(1080, 1920);
        _targetFPS = 30;
        _rotation = VCamRotation0;
        _mirror = NO;
        _lipSyncOffsetMs = 0;
        _lastEmitHostTime = 0;
        _lock = OS_UNFAIR_LOCK_INIT;
        _queue = dispatch_queue_create("com.quite85.vcam.framesource", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

- (dispatch_queue_t)workQueue { return _queue; }

- (NSString *)statusText { return @"未知源"; }
- (BOOL)isReady { return NO; }

- (BOOL)start { return NO; }
- (void)stop {}
- (void)invalidate { [self stop]; }

#pragma mark - 节流

- (BOOL)shouldEmitNow {
    NSInteger fps = MAX(1, self.targetFPS);
    uint64_t now = mach_absolute_time();
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    uint64_t nowNs = now * tb.numer / tb.denom;
    uint64_t minIntervalNs = (uint64_t)(1000000000ull / (uint64_t)fps);
    os_unfair_lock_lock(&_lock);
    BOOL ok = (nowNs - _lastEmitHostTime) >= minIntervalNs;
    if (ok) _lastEmitHostTime = nowNs;
    os_unfair_lock_unlock(&_lock);
    return ok;
}

- (void)resetThrottle {
    os_unfair_lock_lock(&_lock);
    _lastEmitHostTime = 0;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 统一输出管线

- (void)emitPixelBuffer:(CVPixelBufferRef)pixelBuffer atStreamTime:(CMTime)streamTime {
    if (!pixelBuffer) return;
    VCamFrameHandler handler = self.frameHandler;
    if (!handler) return;

    // 在 workQueue 上做缩放/旋转/镜像，避免占用采集回调线程。
    // 这里用 "transfer" 语义：retain 一份交给 block，block 结束后 release。
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(_queue, ^{
        CVPixelBufferRef working = pixelBuffer;   // 已 +1
        @try {
            CGSize target = self.targetSize;
            if (target.width > 1 && target.height > 1) {
                CVPixelBufferRef scaled =
                    [VCamPixelBufferUtils scalePixelBuffer:working
                                                   toWidth:(size_t)target.width
                                                    height:(size_t)target.height];
                if (scaled && scaled != working) {
                    CVPixelBufferRelease(working);
                    working = scaled;             // scaled 已 +1
                } else if (scaled == working) {
                    CVPixelBufferRelease(scaled); // 只是 retain 了同一个，抵消掉
                }
            }
            if (self.rotation != VCamRotation0 || self.mirror) {
                CVPixelBufferRef xf =
                    [VCamPixelBufferUtils transformPixelBuffer:working
                                                      rotation:self.rotation
                                                        mirror:self.mirror];
                if (xf && xf != working) {
                    CVPixelBufferRelease(working);
                    working = xf;
                } else if (xf == working) {
                    CVPixelBufferRelease(xf);
                }
            }
            CMTime ts = [VCamPixelBufferUtils hostTimeForStreamTime:streamTime
                                                             anchor:CMTimeMake(0, 1)];
            handler(working, ts);
        } @catch (NSException *e) {
            VCamLog(@"[source] emit 异常: %@", e);
        }
        if (working) CVPixelBufferRelease(working);
    });
}

@end
