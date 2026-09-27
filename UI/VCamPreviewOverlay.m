//
//  VCamPreviewOverlay.m
//  VCam
//

#import "VCamPreviewOverlay.h"
#import "VCamConfig.h"
#import "VCamCore.h"
#import "VCamPixelBufferUtils.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

static const void *kVCamOverlayKey = &kVCamOverlayKey;
static const void *kVCamOverlayTimerKey = &kVCamOverlayTimerKey;
static os_unfair_lock gOverlayLock = OS_UNFAIR_LOCK_INIT;
static BOOL gPassthrough = NO;

@interface VCamOverlayHost : NSObject
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *layer;
@property (nonatomic, strong) CALayer *overlay;
@property (nonatomic, strong) CATextLayer *hint;
@property (nonatomic, assign) dispatch_source_t timer;
@property (nonatomic, assign) BOOL running;
@end

@implementation VCamOverlayHost

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (_running) return;
    _running = YES;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    // 30fps 刷新覆盖层；比 refresh rate 低一点，省电且肉眼无差别
    uint64_t interval = NSEC_PER_SEC / 30;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self tick];
    });
    dispatch_resume(_timer);
}

- (void)stop {
    _running = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)tick {
    if (gPassthrough) return;

    VCamCore *core = [VCamCore shared];
    if (!core.active) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.overlay.hidden = YES;
            self.hint.hidden = YES;
        });
        return;
    }

    CVPixelBufferRef pb = [core copyPixelBufferForNow];
    if (!pb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hint.string = @"VCam：等待信号…";
            self.hint.hidden = NO;
        });
        return;
    }

    UIImage *img = [VCamPixelBufferUtils imageFromPixelBuffer:pb];
    CVPixelBufferRelease(pb);
    if (!img || !img.CGImage) return;

    CGImageRef cg = CGImageRetain(img.CGImage);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 覆盖层必须和 previewLayer 的坐标系一致
        self.overlay.contents = (__bridge id)cg;
        self.overlay.hidden = NO;
        self.hint.hidden = ([VCamCore shared].active);
        CGImageRelease(cg);
    });
}

@end

@implementation VCamPreviewOverlay

+ (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
    if (!layer) return;
    os_unfair_lock_lock(&gOverlayLock);
    VCamOverlayHost *host = objc_getAssociatedObject(layer, kVCamOverlayKey);
    os_unfair_lock_unlock(&gOverlayLock);
    if (host) {
        [self layoutOverlayForPreviewLayer:layer];
        return;
    }

    VCamOverlayHost *newHost = [[VCamOverlayHost alloc] init];
    newHost.layer = layer;

    CALayer *overlay = [CALayer layer];
    overlay.frame = layer.bounds;
    overlay.contentsGravity = kCAGravityResizeAspectFill;   // 与 previewLayer 默认行为一致
    overlay.masksToBounds = YES;
    overlay.hidden = YES;
    overlay.zPosition = 10;
    // 覆盖层不参与触摸
    overlay.allowsEdgeAntialiasing = YES;

    CATextLayer *hint = [CATextLayer layer];
    hint.string = @"VCam：等待信号…";
    hint.fontSize = 15;
    hint.alignmentMode = kCAAlignmentCenter;
    hint.foregroundColor = UIColor.whiteColor.CGColor;
    hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    hint.cornerRadius = 8;
    hint.frame = CGRectMake(0, 0, 220, 34);
    hint.position = CGPointMake(CGRectGetMidX(layer.bounds), CGRectGetMidY(layer.bounds));
    hint.hidden = YES;
    hint.zPosition = 11;
    // 防止 Retina 下文字模糊
    hint.contentsScale = UIScreen.mainScreen.scale;

    [layer addSublayer:overlay];
    [layer addSublayer:hint];
    newHost.overlay = overlay;
    newHost.hint = hint;

    objc_setAssociatedObject(layer, kVCamOverlayKey, newHost, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [newHost start];

    VCamLog(@"[app] 已为 AVCaptureVideoPreviewLayer 挂载虚拟画面覆盖层");
    [self layoutOverlayForPreviewLayer:layer];
}

+ (void)layoutOverlayForPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
    if (!layer) return;
    VCamOverlayHost *host = objc_getAssociatedObject(layer, kVCamOverlayKey);
    if (!host) return;
    CGRect b = layer.bounds;
    if (CGRectIsEmpty(b)) {
        // 有些 App 先 addSublayer 再设 frame，这里用 bounds 的估算值兜底
        b = layer.frame;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];    // 不做隐式动画，避免画面"抖"
    host.overlay.frame = b;
    host.hint.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    [CATransaction commit];
}

+ (void)setPassthroughMode:(BOOL)passthrough {
    gPassthrough = passthrough;
}

+ (void)detachAll {
    // 遍历所有 UIWindow 找到 previewLayer 太麻烦，这里通过关联对象反向清理：
    // 由于 VCamOverlayHost 持有 weak layer，我们只需要让所有 host 停止并移除图层。
    // 实际做法（简单可靠）：遍历所有 window 的 layer 树，找带关联对象的层。
    NSMutableArray<CALayer *> *found = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        [self _collectLayersFrom:w.layer into:found];
    }
    for (CALayer *l in found) {
        VCamOverlayHost *host = objc_getAssociatedObject(l, kVCamOverlayKey);
        if (!host) continue;
        [host stop];
        [host.overlay removeFromSuperlayer];
        [host.hint removeFromSuperlayer];
        objc_setAssociatedObject(l, kVCamOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    VCamLog(@"[app] 已移除所有预览覆盖层（共 %lu 个）", (unsigned long)found.count);
}

+ (void)_collectLayersFrom:(CALayer *)root into:(NSMutableArray<CALayer *> *)out {
    if (!root) return;
    [out addObject:root];
    for (CALayer *sub in root.sublayers) {
        [self _collectLayersFrom:sub into:out];
    }
}

@end
