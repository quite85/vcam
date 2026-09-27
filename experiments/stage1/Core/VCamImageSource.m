//
//  VCamImageSource.m
//  VCam
//

#import "VCamImageSource.h"
#import "VCamConfig.h"
#import <ImageIO/ImageIO.h>
#import <os/lock.h>   // os_unfair_lock / OS_UNFAIR_LOCK_INIT 在这里，漏了会报
                      // "declaration of os_unfair_lock must be imported from module Darwin.os.lock"

@implementation VCamImageSource {
    dispatch_source_t _timer;
    NSString *_path;
    // 预先转好的"基准帧"（未旋转、未缩放），避免每帧都从 UIImage 重渲染
    CVPixelBufferRef _baseFrame;
    os_unfair_lock _frameLock;
}

- (instancetype)initWithImage:(UIImage *)image {
    if ((self = [super init])) {
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _image = image;
        _baseFrame = NULL;
    }
    return self;
}

- (instancetype)initWithImagePath:(NSString *)path {
    if ((self = [super init])) {
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _path = [path copy];
        _image = [self _loadImageAtPath:path];
        _baseFrame = NULL;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (UIImage *)_loadImageAtPath:(NSString *)path {
    if (path.length == 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    // 相册大图先做一次降采样，避免 4000x3000 的图占内存
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @(YES),
        (id)kCGImageSourceCreateThumbnailWithTransform: @(YES),   // 应用 EXIF 方向
        (id)kCGImageSourceThumbnailMaxPixelSize: @(2560),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

- (void)setImage:(UIImage *)image {
    os_unfair_lock_lock(&_frameLock);
    _image = image;
    if (_baseFrame) { CVPixelBufferRelease(_baseFrame); _baseFrame = NULL; }
    os_unfair_lock_unlock(&_frameLock);
}

- (NSString *)statusText {
    CGSize s = self.targetSize;
    return [NSString stringWithFormat:@"图片 · %.0fx%.0f · %ldfps",
            s.width, s.height, (long)self.targetFPS];
}

- (BOOL)isReady { return self.image != nil; }

#pragma mark - 启停

- (BOOL)start {
    if (!self.image) {
        self.lastError = @"没有可用图片";
        return NO;
    }
    // 生成基准帧：按目标尺寸（旋转前）渲染一次
    CGSize target = self.targetSize;
    // 旋转 90/270 时目标宽高是"最终"的，基准帧要反着来
    size_t bw = (size_t)target.width;
    size_t bh = (size_t)target.height;
    if (self.rotation == VCamRotation90 || self.rotation == VCamRotation270) {
        bw = (size_t)target.height;
        bh = (size_t)target.width;
    }
    CVPixelBufferRef frame = [VCamPixelBufferUtils pixelBufferFromImage:self.image
                                                                  width:bw
                                                                 height:bh];
    if (!frame) {
        self.lastError = @"图片转 CVPixelBuffer 失败";
        return NO;
    }
    os_unfair_lock_lock(&_frameLock);
    if (_baseFrame) CVPixelBufferRelease(_baseFrame);
    _baseFrame = frame;
    os_unfair_lock_unlock(&_frameLock);

    if (_timer) return YES;

    // 用 dispatch timer 而不是 NSTimer：不需要 runloop，daemon 里也能跑
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    NSInteger fps = MAX(1, self.targetFPS);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / (uint64_t)fps);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval,
                              interval / 8);   // 8 分之一容差，避免抖动累积
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        os_unfair_lock_lock(&self->_frameLock);
        CVPixelBufferRef f = self->_baseFrame;
        if (f) CVPixelBufferRetain(f);
        os_unfair_lock_unlock(&self->_frameLock);
        if (f) {
            // 静态图每帧都是"现在"，时间戳用 host 时间即可，录制时间轴才连续
            [self emitPixelBuffer:f atStreamTime:CMClockGetTime(CMClockGetHostTimeClock())];
            CVPixelBufferRelease(f);
        }
    });
    dispatch_resume(_timer);
    VCamLog(@"[img] 图片源已启动 %zux%zu @%ldfps", bw, bh, (long)fps);
    return YES;
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)invalidate {
    [self stop];
    os_unfair_lock_lock(&_frameLock);
    if (_baseFrame) { CVPixelBufferRelease(_baseFrame); _baseFrame = NULL; }
    _image = nil;
    os_unfair_lock_unlock(&_frameLock);
}

@end
