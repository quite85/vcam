//
//  VCamFrameInjector.m
//  虚拟摄像头
//
//  实现说明见 .h 里"为什么用代理模式"那一大段。
//  这里只补充几个实现细节上的坑。
//

#import "VCamFrameInjector.h"
#import "VCamMediaManager.h"
#import "VCamLog.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>

// ---------------------------------------------------------------------------
// 运行日志：写到固定文件，方便用 Filza 或连电脑查看
//
// 同时用 NSLog 输出（会进 syslog，idevicesyslog 能看到）。
// 之前只用 os_log 时，idevicesyslog 抓不到 —— 因为统一日志与
// 传统 syslog relay 是两条不同的通道。
// ---------------------------------------------------------------------------
static NSString *const kVCamLogPath = @"/var/mobile/Library/VirtualCamera/vcam.log";

void VCamLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[VCam] %@", msg);

    @try {
        static dispatch_queue_t q;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            q = dispatch_queue_create("com.quite85.vcam.log", DISPATCH_QUEUE_SERIAL);
            [NSFileManager.defaultManager createDirectoryAtPath:
                [kVCamLogPath stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES
                                                attributes:nil error:NULL];
        });
        dispatch_async(q, ^{
            @try {
                NSString *line = [NSString stringWithFormat:@"%.3f [%d] %@\n",
                                    NSDate.date.timeIntervalSince1970,
                                    getpid(), msg];
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kVCamLogPath];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                } else {
                    [line writeToFile:kVCamLogPath atomically:YES
                             encoding:NSUTF8StringEncoding error:NULL];
                }
            } @catch (...) {}
        });
    } @catch (...) {}
}

// ---------------------------------------------------------------------------
// 全局开关
// ---------------------------------------------------------------------------
static BOOL gVCamEnabled = NO;
static uint64_t gReplacedFrames = 0;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;

// ---------------------------------------------------------------------------
// 代理对象：夹在 AVCaptureVideoDataOutput 与真实 delegate 之间
// ---------------------------------------------------------------------------
@interface VCamVideoDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

/// 真实 delegate（弱引用：它的生命周期由调用方管理，我们不该延长）
@property (nonatomic, weak, nullable) id realDelegate;
/// 相机回调用的队列（用于判断是否需要切回主线程）
@property (nonatomic, assign, nullable) dispatch_queue_t delegateQueue;

@end

@implementation VCamVideoDelegateProxy

#pragma mark - 消息转发兜底
//
// 真实 delegate 可能实现了很多其他方法（比如
// captureOutput:didDropSampleBuffer:fromConnection:、以及它自己的私有方法）。
// 我们只覆盖出帧那一个，其余全部转发给真实 delegate。
//
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id real = self.realDelegate;
    return real ? [real respondsToSelector:aSelector] : NO;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id real = self.realDelegate;
    if (real && [real respondsToSelector:aSelector]) return real;
    return [super forwardingTargetForSelector:aSelector];
}

#pragma mark - 出帧回调（核心）
//
// 这是整个虚拟相机的关键位置：相机每出一帧都会走到这里。
//
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    CMSampleBufferRef toDeliver = sampleBuffer;
    CMSampleBufferRef fake = NULL;

    os_unfair_lock_lock(&gStateLock);
    BOOL enabled = gVCamEnabled;
    os_unfair_lock_unlock(&gStateLock);

    if (enabled) {
        // 取一帧虚拟画面
        fake = [[VCamMediaManager shared] nextVideoFrame];
        if (!fake) {
            // 视频还没就绪 / 解码失败 → 退化成黑帧，避免透出真实画面
            fake = [[VCamMediaManager shared] blackFrame];
        }
        if (fake) {
            toDeliver = fake;
            os_unfair_lock_lock(&gStateLock);
            gReplacedFrames++;
            os_unfair_lock_unlock(&gStateLock);
        }
    }

    // 转发给真实 delegate
    id real = self.realDelegate;
    if (real && [real respondsToSelector:_cmd]) {
        @try {
            [real captureOutput:output
        didOutputSampleBuffer:toDeliver
               fromConnection:connection];
        } @catch (NSException *e) {
            VCamLog(@"⚠️ 转发给真实 delegate 时抛异常: %@", e.reason);
        }
    }

    // fake 是我们创建的，用完要释放
    if (fake) CFRelease(fake);
}

@end

// ---------------------------------------------------------------------------
// 关联对象 key：把 proxy 挂到 output 上，避免被释放
// ---------------------------------------------------------------------------
static const void *kVCamProxyKey = &kVCamProxyKey;

// ---------------------------------------------------------------------------
// swizzle：AVCaptureVideoDataOutput 的 setSampleBufferDelegate:queue:
// ---------------------------------------------------------------------------
static IMP gOrigSetDelegate = NULL;

static void VCamSetSampleBufferDelegate(id self, SEL _cmd,
                                       id delegate, dispatch_queue_t queue) {
    @try {
        AVCaptureVideoDataOutput *output = (AVCaptureVideoDataOutput *)self;

        // 已经是我们的 proxy 就不再包一层（避免递归包装）
        if ([delegate isKindOfClass:VCamVideoDelegateProxy.class]) {
            if (gOrigSetDelegate) {
                ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetDelegate)
                    (self, _cmd, delegate, queue);
            }
            return;
        }

        if (delegate) {
            VCamVideoDelegateProxy *proxy = [[VCamVideoDelegateProxy alloc] init];
            proxy.realDelegate = delegate;
            proxy.delegateQueue = queue;

            // 挂到 output 上保持存活
            objc_setAssociatedObject(output, kVCamProxyKey, proxy,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            VCamLog(@"已包装 delegate: %@ -> VCamVideoDelegateProxy",
                    NSStringFromClass([delegate class]));

            if (gOrigSetDelegate) {
                ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetDelegate)
                    (self, _cmd, proxy, queue);
            }
            return;
        } else {
            // 设为 nil：清掉我们的 proxy
            objc_setAssociatedObject(output, kVCamProxyKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            VCamLog(@"delegate 被置空");
        }
    } @catch (NSException *e) {
        VCamLog(@"⚠️ setSampleBufferDelegate hook 异常: %@", e.reason);
    }

    if (gOrigSetDelegate) {
        ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetDelegate)
            (self, _cmd, delegate, queue);
    }
}

// ---------------------------------------------------------------------------
// 公开接口
// ---------------------------------------------------------------------------
@implementation VCamFrameInjector

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            Class cls = objc_getClass("AVCaptureVideoDataOutput");
            if (!cls) {
                VCamLog(@"❌ 找不到 AVCaptureVideoDataOutput 类");
                return;
            }

            SEL sel = @selector(setSampleBufferDelegate:queue:);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) {
                VCamLog(@"❌ AVCaptureVideoDataOutput 没有 setSampleBufferDelegate:queue:");
                return;
            }

            gOrigSetDelegate = method_getImplementation(m);
            method_setImplementation(m, (IMP)VCamSetSampleBufferDelegate);

            VCamLog(@"✅ 已 swizzle AVCaptureVideoDataOutput setSampleBufferDelegate:queue:");
        } @catch (NSException *e) {
            VCamLog(@"❌ install 异常: %@", e.reason);
        } @catch (...) {
            VCamLog(@"❌ install 未知异常");
        }
    });
}

+ (void)setEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&gStateLock);
    gVCamEnabled = enabled;
    os_unfair_lock_unlock(&gStateLock);
    VCamLog(@"虚拟相机开关 -> %@", enabled ? @"开" : @"关");
}

+ (BOOL)isEnabled {
    os_unfair_lock_lock(&gStateLock);
    BOOL e = gVCamEnabled;
    os_unfair_lock_unlock(&gStateLock);
    return e;
}

+ (uint64_t)replacedFrameCount {
    os_unfair_lock_lock(&gStateLock);
    uint64_t c = gReplacedFrames;
    os_unfair_lock_unlock(&gStateLock);
    return c;
}

@end
