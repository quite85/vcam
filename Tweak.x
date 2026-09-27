// ============================================================================
//  Tweak.x —— VCam 主 hook 入口（Logos）
//
//  这个文件是"总装配图"，按进程分流：
//
//   ┌─ SpringBoard ──────────────────────────────────────────────┐
//   │  · 音量键（音量减）拦截 → 悬浮小窗                          │
//   │  · 悬浮小窗 UI / 相册选择                                   │
//   │  · 自身不注入相机（SpringBoard 不采集）                     │
//   └────────────────────────────────────────────────────────────┘
//
//   ┌─ mediaserverd（系统级，最关键的一层）──────────────────────┐
//   │  · FigCaptureSource / FigVideoCaptureSource 后端出帧点       │
//   │  · 音频采集（AudioUnit / AURemoteIO）输入回调                │
//   │  这一层挡住之后，任何 App 拿到的都是虚拟源，                 │
//   │  不依赖 App 里有没有 tweak。                                 │
//   └────────────────────────────────────────────────────────────┘
//
//   ┌─ 其它 App（AVFoundation 层，兜底 + 保证拍照/录像也是虚拟的）│
//   │  · AVCaptureVideoDataOutput delegate                        │
//   │  · AVCaptureVideoPreviewLayer（无 data output 的 App）      │
//   │  · AVCapturePhotoOutput / AVCaptureMovieFileOutput          │
//   │  · AVAudioRecorder / AVAudioEngine 输入节点（麦克风）        │
//   └────────────────────────────────────────────────────────────┘
//
//  设计原则：
//   1) 任何 hook 里的第一件事都是"问 VCamCore 有没有虚拟帧"。
//      没有 → 原样调用原实现（%orig），绝不改变行为。
//   2) 所有 hook 外层包 @try/@catch，异常一律走原实现。
//   3) 不用 %hook 硬绑定可能不存在的类：私有类一律用 objc_getClass 运行时查找，
//      查不到就跳过（iOS 15/16 之间符号差异很大）。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>

#import "Core/VCamConfig.h"
#import "Core/VCamCore.h"
#import "Core/VCamStateStore.h"
#import "Core/VCamPixelBufferUtils.h"
#import "Core/VCamConcurrentQueue.h"
#import "UI/VCamPanel.h"
#import "UI/VCamPreviewOverlay.h"
#import "UI/VCamVideoDataOutputProxy.h"
#import "Mic/VCamMicInjector.h"
#import "Media/VCamPhotoOutputInjector.h"
#import "Media/VCamMovieFileInjector.h"

// ============================================================================
#pragma mark - 公共：Hook 运行环境自检
// ============================================================================

/// 把 VCam 的失败信息写进状态文件，UI 上能看到（用户排查必备）
static void VCamReportFailure(NSString *where, NSString *reason) {
    VCamLog(@"[hook][%@] %@", where, reason);
    [[VCamStateStore shared] recordError:[NSString stringWithFormat:@"%@: %@", where, reason]];
}

/// 防止 mediaserverd 被我们打崩：如果本次启动后 10 秒内 mediaserverd 退出过
/// （crash flag 存在），就自动降级为"只做 App 层注入"。
static void VCamMediaserverdWatchdog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *flag = VCamMSDCrashFlagPath();
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:flag error:NULL];
        if (attrs) {
            // 上一次 mediaserverd 是在我们注入后短时间挂掉的
            [[VCamStateStore shared] setMSDDisabled:YES];
            VCamLog(@"[hook] 检测到上次 mediaserverd 异常退出，已自动降级为 App 层注入");
            [NSFileManager.defaultManager removeItemAtPath:flag error:NULL];
        }
        // 写一个"正在注入"的标记，正常退出时（或者 App 层确认工作正常时）删除
        [@"1" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // 8 秒后如果还活着，说明基本稳定，删掉标记
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSFileManager.defaultManager removeItemAtPath:flag error:NULL];
        });
    });
}

// ============================================================================
#pragma mark - mediaserverd 层：FigCaptureSource 出帧点
// ============================================================================
//
//  iOS 的相机数据流（简化）：
//
//   硬件 ISP
//     → FigCaptureSourceBackend（mediaserverd 内，负责真正采集）
//     → FigCaptureSourceVideoStream / FigVideoCaptureSource
//     → FigCaptureImageQueue（跨进程共享的 IOSurface 队列）
//     → App 的 AVCaptureVideoDataOutput / PreviewLayer
//
//  我们想插在"FigCaptureSourceVideoStream 往外吐帧"的那一步。
//  问题是这些是 C++ 私有符号，且 iOS 15 / 16 名字有差异，
//  所以做法是：
//   1) dlopen 找到 mediaserverd 主可执行镜像；
//   2) 用 dlsym / 符号表里常见的几个名字去试；
//   3) 全部失败则记录日志，依赖 App 层兜底（功能仍然可用）。
//
//  下面给出两个真实的插入点（按成功率排序）：

typedef OSStatus (*VCamEnqueueFrameFn)(void *queue, void *pixelBuffer, void *context);
typedef CVPixelBufferRef (*VCamDequeueFrameFn)(void *queue, void *context);

/// 插入点 A：字节级 hook 一个 C 函数（用 ElleKit / Substrate 的 MSHookFunction）
typedef void (*VCamMSHookFunctionFn)(void *symbol, void *replace, void **result);
static VCamMSHookFunctionFn VCamMSHook = NULL;

static void VCamResolveHookEngine(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sym = dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!sym) {
            // ElleKit 也导出 MSHookFunction；Substitute 的等价符号是
            // SubstituteHookFunction，这里一并尝试
            void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (!h) h = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
            if (!h) h = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
            if (!h) h = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (h) sym = dlsym(h, "MSHookFunction");
        }
        if (sym) VCamMSHook = (VCamMSHookFunctionFn)sym;
        VCamLog(@"[hook] hook 引擎 %@", VCamMSHook ? @"可用" : @"不可用（将只走 App 层）");
    });
}

// ---- 原始函数指针 ----
static VCamEnqueueFrameFn orig_RTImageQueueEnqueue = NULL;
static VCamEnqueueFrameFn orig_FigImageQueueEnqueue = NULL;

/// 被替换的实现：如果当前有虚拟帧，就把虚拟帧交给队列；否则走原实现。
static OSStatus vcam_RTImageQueueEnqueue(void *queue, void *pixelBuffer, void *context) {
    @autoreleasepool {
        @try {
            VCamCore *core = [VCamCore shared];
            if (core.active) {
                CVPixelBufferRef pb = [core copyPixelBufferForNow];
                if (pb) {
                    OSStatus st = orig_RTImageQueueEnqueue
                                ? orig_RTImageQueueEnqueue(queue, (void *)pb, context)
                                : -1;
                    CVPixelBufferRelease(pb);
                    if (st == 0) return st;
                    // 失败也要放行真实帧，不能把相机管线堵死
                }
            }
        } @catch (NSException *e) {
            VCamLog(@"[hook][msd] enqueue 异常 %@", e);
        }
    }
    if (orig_RTImageQueueEnqueue) return orig_RTImageQueueEnqueue(queue, pixelBuffer, context);
    return -1;
}

static OSStatus vcam_FigImageQueueEnqueue(void *queue, void *pixelBuffer, void *context) {
    @autoreleasepool {
        @try {
            VCamCore *core = [VCamCore shared];
            if (core.active) {
                CVPixelBufferRef pb = [core copyPixelBufferForNow];
                if (pb) {
                    OSStatus st = orig_FigImageQueueEnqueue
                                ? orig_FigImageQueueEnqueue(queue, (void *)pb, context)
                                : -1;
                    CVPixelBufferRelease(pb);
                    if (st == 0) return st;
                }
            }
        } @catch (NSException *e) {
            VCamLog(@"[hook][msd] Fig enqueue 异常 %@", e);
        }
    }
    if (orig_FigImageQueueEnqueue) return orig_FigImageQueueEnqueue(queue, pixelBuffer, context);
    return -1;
}

/// 试探性地 hook 一组候选符号名。为了兼容 iOS 15/16，把见过的名字都列上，
/// 命中哪个用哪个（互不冲突，都是同一条管线上的不同层）。
static int VCamHookMediaServerdSymbols(void) {
    VCamResolveHookEngine();
    if (!VCamMSHook) return 0;

    int hooked = 0;
    void *handle = dlopen(NULL, RTLD_NOW);   // 主可执行镜像

    struct { const char *name; void *replace; void **orig; } candidates[] = {
        { "FigImageQueueEnqueue",        (void *)vcam_FigImageQueueEnqueue, (void **)&orig_FigImageQueueEnqueue },
        { "FigImageQueueEnqueueImage",   (void *)vcam_FigImageQueueEnqueue, (void **)&orig_FigImageQueueEnqueue },
        { "RTImageQueueEnqueue",         (void *)vcam_RTImageQueueEnqueue,  (void **)&orig_RTImageQueueEnqueue },
        { "FigCaptureImageQueueEnqueue", (void *)vcam_FigImageQueueEnqueue, (void **)&orig_FigImageQueueEnqueue },
        { "FigVideoQueueEnqueueFrame",   (void *)vcam_RTImageQueueEnqueue,  (void **)&orig_RTImageQueueEnqueue },
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *sym = dlsym(handle ? handle : RTLD_DEFAULT, candidates[i].name);
        if (!sym) continue;
        @try {
            VCamMSHook(sym, candidates[i].replace, candidates[i].orig);
            VCamLog(@"[hook][msd] 已 hook %s @ %p", candidates[i].name, sym);
            hooked++;
        } @catch (NSException *e) {
            VCamLog(@"[hook][msd] hook %s 失败: %@", candidates[i].name, e);
        }
    }
    if (hooked == 0) {
        VCamReportFailure(@"mediaserverd",
            @"未找到可 hook 的采集出帧符号（iOS 版本差异）。"
            @"已自动降级为 App 层注入，预览/拍照/录像仍然有效，"
            @"但极少数未注入的 App 可能拿到真实画面。");
    }
    return hooked;
}

// ============================================================================
#pragma mark - App 层：AVFoundation 注入
// ============================================================================

/// 记录每个 output 对象对应的"是否是我们注入过的"
static const void *kVCamSwizzledKey = &kVCamSwizzledKey;

// ---------------------------------------------------------------------------
// 1) AVCaptureVideoDataOutput：把 delegate 回调里的 sampleBuffer 换成虚拟帧
//    这是 App 层最有效的一刀，覆盖绝大多数"用 data output 做处理"的 App
//    （TikTok/抖音/微信视频号/各种直播 App 的采集都走这里）
// ---------------------------------------------------------------------------
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    %orig(delegate, queue);
    if (!delegate) return;
    // 包一层：替换 delegate 的回调，不改 App 的代码逻辑
    [[VCamCore shared] observeStateIfNeeded];
    [VCamVideoDataOutputProxy installForOutput:self delegate:delegate queue:queue];
}

%end

// ---------------------------------------------------------------------------
// 2) AVCaptureVideoPreviewLayer：有些 App 只用预览层（简单相机、扫码、系统相机预览）
//    previewLayer 的帧来自 layer 的 internal 层，直接替换 pixelBuffer 比较困难，
//    我们采用"在其上覆盖一个 CALayer 显示虚拟帧"的方式，
//    这样不破坏原有预览层结构，禁用时移除覆盖层即可。
// ---------------------------------------------------------------------------
%hook AVCaptureVideoPreviewLayer

- (void)setSession:(AVCaptureSession *)session {
    %orig(session);
    [VCamPreviewOverlay attachToPreviewLayer:self];
}

- (void)layoutSublayers {
    %orig;
    [VCamPreviewOverlay layoutOverlayForPreviewLayer:self];
}

%end

// ---------------------------------------------------------------------------
// 3) AVCaptureSession：跟踪 session 是否在跑（用于"是否有活跃采集"判断）
// ---------------------------------------------------------------------------
%hook AVCaptureSession

- (void)startRunning {
    %orig;
    [[VCamStateStore shared] update:^(NSMutableDictionary *d) {
        d[kVCamStateKeySessionActive] = @(YES);
    }];
    // 前后摄切换时更新镜像判断
    for (AVCaptureDeviceInput *input in self.inputs) {
        AVCaptureDevice *dev = input.device;
        if (dev.position == AVCaptureDevicePositionFront) {
            [VCamCore shared].cameraPosition = VCamCameraPositionFront;
        } else if (dev.position == AVCaptureDevicePositionBack) {
            [VCamCore shared].cameraPosition = VCamCameraPositionBack;
        }
    }
}

- (void)stopRunning {
    %orig;
    [[VCamStateStore shared] update:^(NSMutableDictionary *d) {
        d[kVCamStateKeySessionActive] = @(NO);
    }];
}

// 前后摄切换：canAddInput 之前拦一刀，把朝向记下来，
// 虚拟源据此决定"前摄是否镜像"（自拍习惯）
- (BOOL)canAddInput:(AVCaptureInput *)input {
    if ([input isKindOfClass:AVCaptureDeviceInput.class]) {
        AVCaptureDevice *dev = ((AVCaptureDeviceInput *)input).device;
        if (dev.position == AVCaptureDevicePositionFront) {
            [VCamCore shared].cameraPosition = VCamCameraPositionFront;
        } else if (dev.position == AVCaptureDevicePositionBack) {
            [VCamCore shared].cameraPosition = VCamCameraPositionBack;
        }
    }
    return %orig(input);
}

%end

// ---------------------------------------------------------------------------
// 4) 闪光灯 / 对焦 / 白平衡：虚拟源下这些操作没有意义，
//    但 App 会调用并且期望"成功"。这里做假成功，避免 App 因为
//    lockForConfiguration 抛异常或返回 NO 而崩。
// ---------------------------------------------------------------------------
%hook AVCaptureDevice

- (BOOL)lockForConfiguration:(NSError **)outError {
    if ([VCamCore shared].active) {
        // 假成功：直接告诉 App 拿到了锁
        return YES;
    }
    return %orig(outError);
}

- (void)unlockForConfiguration {
    if ([VCamCore shared].active) {
        // 没有真的 lock，就不要 unlock（否则会影响真实设备的锁计数）
        return;
    }
    %orig;
}

- (BOOL)hasTorch { if ([VCamCore shared].active) return YES; return %orig; }
- (BOOL)isTorchAvailable { if ([VCamCore shared].active) return YES; return %orig; }
- (BOOL)hasFlash { if ([VCamCore shared].active) return YES; return %orig; }
- (BOOL)isFlashAvailable { if ([VCamCore shared].active) return YES; return %orig; }

- (BOOL)setTorchModeOnWithLevel:(float)level error:(NSError **)outError {
    if ([VCamCore shared].active) return YES;   // 假成功
    return %orig(level, outError);
}

- (void)setTorchMode:(AVCaptureTorchMode)mode {
    if ([VCamCore shared].active) return;       // 吞掉，不要真的开闪光灯
    %orig(mode);
}

- (BOOL)isFocusPointOfInterestSupported {
    if ([VCamCore shared].active) return YES;
    return %orig;
}

- (void)setFocusPointOfInterest:(CGPoint)point {
    if ([VCamCore shared].active) return;       // 虚拟源没有对焦
    %orig(point);
}

- (void)setFocusMode:(AVCaptureFocusMode)mode {
    if ([VCamCore shared].active) return;
    %orig(mode);
}

- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)mode {
    if ([VCamCore shared].active) return;
    %orig(mode);
}

- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime))handler {
    if ([VCamCore shared].active) {
        if (handler) handler(CMClockGetTime(CMClockGetHostTimeClock()));
        return;
    }
    %orig(bias, handler);
}

%end

// ---------------------------------------------------------------------------
// 5) 摄像头发现：Hooking AVCaptureDeviceDiscoverySession 保证虚拟源生效时
//    App 依然能"看到"摄像头设备（否则某些 App 会因为 devices 为空而崩溃）
// ---------------------------------------------------------------------------
%hook AVCaptureDeviceDiscoverySession

+ (instancetype)discoverySessionWithDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    id result = %orig(deviceTypes, mediaType, position);
    if ([VCamCore shared].active) {
        // 不修改返回结果，只记录日志：真实设备列表仍然保留，
        // 因为我们是在数据层替换而不是假装没有摄像头。
        // 这样做的好处：App 的 UI（切换前后摄按钮等）仍然正常。
        VCamLog(@"[hook] discoverySession 返回 %lu 个设备（虚拟源生效中）",
                (unsigned long)[result devices].count);
    }
    return result;
}

%end

// ============================================================================
#pragma mark - 音量键拦截（音量减 → 悬浮小窗）
// ============================================================================

#import "UI/VCamVolumeHook.h"

// ============================================================================
#pragma mark - 构造：按进程分流
// ============================================================================

%ctor {
    @autoreleasepool {
        NSString *proc = VCamCurrentProcessName();
        VCamLog(@"=========== 虚拟摄像头 加载到 %@ (pid %d) ===========", proc, getpid());

        // 1) 所有进程都需要状态监听
        [[VCamCore shared] observeStateIfNeeded];

        if (VCamIsMediaServerProcess()) {
            // ---- mediaserverd：系统级注入 ----
            VCamMediaserverdWatchdog();
            int hooked = VCamHookMediaServerdSymbols();
            VCamLog(@"[ctor] mediaserverd 层 hook 数量 = %d", hooked);
            // 音频：麦克风采集替换（这一层是"系统级虚拟麦"的关键）
            [[VCamMicInjector shared] installForMediaServer];
            // 不需要 UI
            return;
        }

        if (VCamIsSpringBoardProcess()) {
            // ---- SpringBoard：只做 UI 与音量键 ----
            [VCamVolumeHook install];
            [[VCamPanel shared] prepare];
            VCamLog(@"[ctor] SpringBoard 音量键与悬浮窗就绪");
            return;
        }

        // ---- 其它进程（各 App）：AVFoundation 层兜底 ----
        // 注意：这里不能再判断"是不是相机 App"，因为直播类 App 太多了。
        // 用 filter plist 控制加载范围，比运行时判断更可靠。
        %init;
        [[VCamMicInjector shared] install];
        [VCamPhotoOutputInjector install];
        [VCamMovieFileInjector install];
        // mediaserverd 层可用时，预览覆盖层就让位（避免一次多余的像素转换）
        if (![[VCamStateStore shared] msdDisabled]) {
            [VCamPreviewOverlay setPassthroughMode:NO];
        }
        VCamLog(@"[ctor] App 层注入完成");
    }
}
