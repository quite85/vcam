//
//  VCamVideoDataOutputProxy.m
//  VCam
//

#import "VCamVideoDataOutputProxy.h"
#import "VCamConfig.h"
#import "VCamCore.h"
#import "VCamPixelBufferUtils.h"
#import <objc/runtime.h>
#import <os/lock.h>

static NSMutableArray<VCamVideoDataOutputProxy *> *gProxies = nil;
static os_unfair_lock gProxyLock = OS_UNFAIR_LOCK_INIT;
static const void *kVCamProxyAssocKey = &kVCamProxyAssocKey;

@interface VCamVideoDataOutputProxy ()
@property (nonatomic, weak, nullable) AVCaptureVideoDataOutput *output;
@property (nonatomic, weak, nullable) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue;
/// 记住原始尺寸，用于把虚拟帧缩放成下游期望的尺寸
@property (nonatomic, assign) CGSize expectedSize;
@property (nonatomic, assign) uint64_t injectedCount;
@end

@implementation VCamVideoDataOutputProxy

+ (void)installForOutput:(AVCaptureVideoDataOutput *)output
                delegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                   queue:(dispatch_queue_t)queue {
    if (!output || !delegate) return;
    if ([delegate isKindOfClass:VCamVideoDataOutputProxy.class]) return;   // 已经是我们的代理
    if ([output associatedProxy]) return;                                  // 已经装过

    VCamVideoDataOutputProxy *proxy = [[VCamVideoDataOutputProxy alloc] init];
    proxy.output = output;
    proxy.realDelegate = delegate;
    proxy.callbackQueue = queue;
    proxy.expectedSize = CGSizeZero;

    [output setAssociatedProxy:proxy];
    [output setSampleBufferDelegate:proxy queue:queue];

    os_unfair_lock_lock(&gProxyLock);
    if (!gProxies) gProxies = [NSMutableArray array];
    [gProxies addObject:proxy];
    os_unfair_lock_unlock(&gProxyLock);

    VCamLog(@"[app] 已为 AVCaptureVideoDataOutput 安装虚拟帧代理（原 delegate: %@）",
            NSStringFromClass([delegate class]));
}

+ (void)uninstallAll {
    NSArray<VCamVideoDataOutputProxy *> *snapshot = nil;
    os_unfair_lock_lock(&gProxyLock);
    snapshot = [gProxies copy];
    [gProxies removeAllObjects];
    os_unfair_lock_unlock(&gProxyLock);

    for (VCamVideoDataOutputProxy *p in snapshot) {
        AVCaptureVideoDataOutput *out = p.output;
        id real = p.realDelegate;
        if (out && real) {
            @try { [out setSampleBufferDelegate:real queue:p.callbackQueue]; }
            @catch (NSException *e) { VCamLog(@"[app] 卸载代理失败 %@", e); }
        }
        [out setAssociatedProxy:nil];
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef toDeliver = sampleBuffer;
    CMSampleBufferRef virtual = NULL;

    VCamCore *core = [VCamCore shared];
    if (core.active) {
        @try {
            // 用真实帧的尺寸作为虚拟帧的目标尺寸，避免下游拿到意外分辨率
            CVImageBufferRef realImage = CMSampleBufferGetImageBuffer(sampleBuffer);
            size_t w = realImage ? CVPixelBufferGetWidth(realImage) : 0;
            size_t h = realImage ? CVPixelBufferGetHeight(realImage) : 0;
            CVPixelBufferRef pb = [core copyPixelBufferForWidth:w height:h];

            if (pb && realImage) {
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
                CMVideoFormatDescriptionRef fmt = NULL;
                if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) == noErr) {
                    CMSampleTimingInfo timing = { dur, pts, kCMTimeInvalid };
                    CMSampleBufferRef newSB = NULL;
                    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt,
                                                                 &timing, &newSB) == noErr) {
                        virtual = newSB;
                        toDeliver = newSB;
                    }
                    CFRelease(fmt);
                }
            }
            if (pb) CVPixelBufferRelease(pb);

            self.injectedCount++;
            if (self.injectedCount % 300 == 0) {
                VCamLog(@"[app] 已注入 %llu 帧（%@）",
                        (unsigned long long)self.injectedCount,
                        NSStringFromClass([self.realDelegate class]));
            }
        } @catch (NSException *e) {
            VCamLog(@"[app] 注入异常，回退真实帧: %@", e);
            if (virtual) { CFRelease(virtual); virtual = NULL; }
            toDeliver = sampleBuffer;
        }
    }

    // 转发给 App 原来的 delegate
    id real = self.realDelegate;
    if (real && [real respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [real captureOutput:output didOutputSampleBuffer:toDeliver fromConnection:connection];
    } else if (real && [real respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        // 极少数 delegate 只实现 drop 回调，忽略
    }

    if (virtual) CFRelease(virtual);
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id real = self.realDelegate;
    if (real && [real respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [real captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

#pragma mark - 应答（App 有时会调这些）
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id real = self.realDelegate;
    return real && [real respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id real = self.realDelegate;
    if (real && [real respondsToSelector:aSelector]) return real;
    return [super forwardingTargetForSelector:aSelector];
}

@end

#pragma mark - AVCaptureVideoDataOutput 关联对象（避免污染主类）

@implementation AVCaptureVideoDataOutput (VCamProxy)

- (void)setAssociatedProxy:(VCamVideoDataOutputProxy *)proxy {
    objc_setAssociatedObject(self, kVCamProxyAssocKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (VCamVideoDataOutputProxy *)associatedProxy {
    return objc_getAssociatedObject(self, kVCamProxyAssocKey);
}

@end
