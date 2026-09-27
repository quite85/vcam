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
// ⚠️ 所有 #import 必须集中在文件顶部、任何 %hook / %ctor 之前。
//    原因：Logos 会把"不在 %hook 块里的代码"统一放进它生成的构造函数，
//    如果 #import 出现在 %hook 之后，就会被塞进某个函数体，报这些错：
//        Tweak.x:337: error: function definition is not allowed here
//        VCamVolumeHook.h:29: error: redundant #include of module 'Foundation'
//                             appears within function '...$hasFlash'
//        VCamVolumeHook.h:33: error: unexpected '@' in program
#import "UI/VCamVolumeHook.h"

// ============================================================================
#pragma mark - 崩溃保护：让任何一步失败都不会拖死进程
// ============================================================================
//
// ⚠️ 为什么必须有这一段（v1.0.0 / v1.0.1 的**黑屏事故**）：
//
//   原来的 %ctor 是"裸奔"的：
//       %ctor {
//           [[VCamCore shared] observeStateIfNeeded];
//           if (VCamIsSpringBoardProcess()) {
//               [VCamVolumeHook install];
//               [[VCamPanel shared] prepare];
//               return;
//           }
//           %init;
//           [VCamPhotoOutputInjector install];
//           ...
//       }
//
//   四个 install 里任何一个抛 Objective-C 异常（或访问了非法内存），
//   **进程当场崩溃**。而 filter 里包含 SpringBoard ——
//   SpringBoard 在构造阶段崩溃 = 崩溃重启循环 = **整机黑屏**。
//
//   注入类插件有一条铁律：**构造阶段绝不能抛异常**。
//   因为此时进程还没起来，用户既看不到界面也来不及卸载。
//
//   现在的做法：
//     1) 每一步都包在 @try/@catch 里，失败只记录、不抛出；
//     2) 每步执行前先在状态文件里留"正在执行第 N 步"的标记，
//        成功后清除。若某步执行到一半进程就崩了，标记会残留，
//        **下次启动直接跳过这一步** —— 于是不会陷入无限崩溃循环；
//     3) 如果连续多次启动都有残留标记，进入"紧急停止"：
//        本次完全不注入，保证设备能正常开机。
//
//   这样即使我的某个 hook 在真机上有问题，最坏结果也只是
//   "某个功能不生效"，而不是黑屏。

/// 安全执行一个代码块：捕获所有 Objective-C 异常与 C++ 异常
static BOOL VCamGuarded(NSString *stage, void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        VCamLog(@"[guard] 步骤 %@ 抛出异常，已忽略: %@ — %@",
                stage, e.name, e.reason);
        [[VCamStateStore shared] recordError:
            [NSString stringWithFormat:@"%@ 异常: %@", stage, e.reason ?: e.name]];
        return NO;
    } @catch (...) {
        VCamLog(@"[guard] 步骤 %@ 抛出未知异常，已忽略", stage);
        [[VCamStateStore shared] recordError:
            [NSString stringWithFormat:@"%@ 未知异常", stage]];
        return NO;
    }
}

/// 状态文件里记录"正在执行哪个阶段"，用于识别"执行到一半就崩了"
static NSString *const kVCamStageKey   = @"ctorStage";
static NSString *const kVCamCrashKey   = @"ctorCrashCount";

/// 读取上一次启动残留的阶段标记（非 nil 说明上次是崩在这一步）
static NSString *VCamPendingStage(void) {
    id v = [[VCamStateStore shared] raw][kVCamStageKey];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

static NSInteger VCamCrashCount(void) {
    id v = [[VCamStateStore shared] raw][kVCamCrashKey];
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}

/// 标记"即将执行某阶段"
static void VCamBeginStage(NSString *stage) {
    [[VCamStateStore shared] update:^(NSMutableDictionary *d) {
        d[kVCamStageKey] = stage;
        NSInteger c = [d[kVCamCrashKey] integerValue] + 1;
        d[kVCamCrashKey] = @(c);
    }];
}

/// 标记"某阶段已成功完成"
static void VCamFinishStage(void) {
    [[VCamStateStore shared] update:^(NSMutableDictionary *d) {
        [d removeObjectForKey:kVCamStageKey];
        d[kVCamCrashKey] = @0;
    }];
}

/// 执行一个带保护的阶段。若上次崩在同名阶段，本次直接跳过。
///   返回 YES = 真的执行了；NO = 跳过了（上次崩在这 / 超出分级预算 / 出异常）。
///
/// 分级调试：gStageBudget 由 %ctor 在开头用 VCamSetStageBudget() 设置。
/// 每调用一次本函数，gStageUsed 递增；超出预算的阶段会被跳过，
/// 用来实现"每次启动只多放行一步"。
static NSInteger gStageBudget = NSIntegerMax;
static NSInteger gStageUsed = 0;

static void VCamSetStageBudget(NSInteger budget) {
    gStageBudget = budget;
    gStageUsed = 0;
}

static BOOL VCamRunStage(NSString *stage, void (^block)(void)) {
    gStageUsed += 1;
    if (gStageUsed > gStageBudget) {
        VCamLog(@"[staged] 本次启动只放行到第 %ld 步，跳过阶段「%@」",
                (long)gStageBudget, stage);
        return NO;
    }
    if ([VCamPendingStage() isEqualToString:stage]) {
        VCamLog(@"[guard] 上次启动崩在阶段「%@」，本次跳过它（保持系统可用）", stage);
        [[VCamStateStore shared] recordError:
            [NSString stringWithFormat:@"已自动跳过曾导致崩溃的阶段: %@", stage]];
        // 清掉标记，让后面的阶段能继续尝试
        [[VCamStateStore shared] update:^(NSMutableDictionary *d) {
            [d removeObjectForKey:kVCamStageKey];
        }];
        return NO;
    }
    VCamBeginStage(stage);
    BOOL ok = VCamGuarded(stage, block);
    VCamFinishStage();
    return ok;
}

/// 紧急停止阈值：连续这么多次启动都留下残留标记 → 停止注入
static const NSInteger kVCamEmergencyStopCount = 3;

// ============================================================================
#pragma mark - 分级调试模式（定位"到底哪一步把设备搞崩"）
// ============================================================================
//
// 背景：v1.0.0 / v1.0.1 装上都黑屏，但**无法定位是哪一步导致的** ——
//       因为所有注入在第一次启动时就全做了，崩了就什么都没有了。
//
// 做法：给每个进程维护一个"启动计数"，本次启动**只放行前 N 步**注入，
//       N 随启动次数递增：
//          第 1 次启动 → 什么注入都不做（只写日志）
//          第 2 次      → 只做第 1 步
//          第 3 次      → 前 2 步
//          …
//       这样：
//         · 某次启动后黑屏 → 崩的就是"本次新增的那一步"，一步定位
//         · 上一步验证过没问题，再往下走，风险可控
//         · 每次重启只前进一小步，最坏情况也只是"多几次重启"
//
// 开关：环境变量 VCAM_SAFE_LAUNCHES
//        未设置（默认）→ 完整注入（正常使用）
//        = 1          → 分级模式，每启动一次多放行一步
//        = 0          → 与未设置相同
//
// 用法（SSH 或 NewTerm 里执行，然后重启对应进程/重启手机）：
//        launchctl setenv VCAM_SAFE_LAUNCHES 1
//        killall -9 SpringBoard
//     观察是否黑屏，再看日志末尾：
//        tail -5 /var/mobile/Library/VirtualCamera/virtualcamera.log
//     日志会明确写出"本次放行到第 N 步 / 共 M 步"。
//
// 关闭分级模式（恢复正常使用）：
//        launchctl unsetenv VCAM_SAFE_LAUNCHES
//        killall -9 SpringBoard

/// 本次应放行的阶段数。返回 -1 表示"不限制"（正常模式）
static NSInteger VCamAllowedStageCount(void) {
    const char *env = getenv("VCAM_SAFE_LAUNCHES");
    if (!env || !*env) return -1;
    if (atoi(env) == 0) return -1;
    return 1;   // 仅用于"是否启用分级模式"的判断，实际步数由计数器决定
}

static BOOL VCamStagedModeEnabled(void) {
    return VCamAllowedStageCount() > 0;
}

/// 分进程维护启动计数，返回本次应放行的步数
static NSInteger VCamCurrentAllowedStages(void) {
    if (!VCamStagedModeEnabled()) return NSIntegerMax;

    NSString *proc = VCamCurrentProcessName() ?: @"unknown";
    NSString *path = [VCamStateDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"launches-%@.txt", proc]];

    NSInteger n = 0;
    NSString *prev = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (prev.length) n = [prev integerValue];
    n += 1;

    [@(n).stringValue writeToFile:path atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
    return n;
}

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

// 注意：这几个方法刻意写成多行。
// 原来写成单行 `- (BOOL)hasFlash { if (...) return YES; return %orig; }`，
// 一旦文件里出现任何"被 Logos 拼到方法体内"的内容（例如误放在 %hook 之后的
// #import），行号会刚好落在这里、报错信息很难看懂：
//     Tweak.x:337:164: error: function definition is not allowed here
//     VCamVolumeHook.h:29:1: error: ... appears within function
//                             '_logos_method$...$hasFlash'
// 多行写法之后，出问题时列号会直接指向出错的那一行。
- (BOOL)hasTorch {
    if ([VCamCore shared].active) return YES;
    return %orig;
}

- (BOOL)isTorchAvailable {
    if ([VCamCore shared].active) return YES;
    return %orig;
}

- (BOOL)hasFlash {
    if ([VCamCore shared].active) return YES;
    return %orig;
}

- (BOOL)isFlashAvailable {
    if ([VCamCore shared].active) return YES;
    return %orig;
}

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
// VCamVolumeHook.h 的 import 已移到文件顶部的 import 区（原因见那里的注释）。

// ============================================================================
#pragma mark - 构造：按进程分流
// ============================================================================

%ctor {
    // ⚠️ 整个构造过程分阶段执行，每一步都由 VCamRunStage 包裹：
    //    · 抛异常 → 只记录，进程继续活着
    //    · 上次崩在这一步 → 本次跳过这一步
    //    · 连续多次留下残留标记 → 紧急停止，本进程完全不注入
    //    详见文件上方"崩溃保护"那一大段注释。
    @autoreleasepool {
        NSString *proc = VCamCurrentProcessName();
        VCamLog(@"=========== 虚拟摄像头 加载到 %@ (pid %d) ===========", proc, getpid());

        // ---- 0) 紧急停止检查 ----
        // 状态文件里 ctorCrashCount 会随每次 BeginStage 递增、成功 FinishStage 归零。
        // 若它偏大，说明多次启动都在注入过程中崩掉 —— 此时绝不能再注入，
        // 否则设备会陷入"开机即崩"的循环（表现为黑屏）。
        NSInteger crashes = VCamCrashCount();
        if (crashes >= kVCamEmergencyStopCount) {
            VCamLog(@"[guard] ⛔️ 检测到连续 %ld 次注入过程异常，本次**完全跳过注入**以保证设备可用",
                    (long)crashes);
            VCamLog(@"[guard] 请在设置面板或状态文件里检查 lastError 后，"
                    @"删除 /var/mobile/Library/VirtualCamera/state.plist 重试");
            return;
        }

        // ---- 0) 救砖开关：safe 文件存在 → 本进程完全不注入 ----
        //
        // 这是给"装上之后黑屏、但不想再走一遍强制重启+安全模式"准备的。
        //
        // 只要这个文件存在，所有进程都只写一行日志、不做任何 hook：
        //     /var/mobile/Library/VirtualCamera/safe
        //
        // 怎么在没越狱的情况下创建它？——用 Filza（越狱 App 本身往往还能开），
        // 或者连电脑用 ifuse/iMazing 往 App 沙盒写。都不行就还是走安全模式。
        //
        // 恢复使用：删掉这个文件即可。
        NSString *safeFlag = [VCamStateDirectory() stringByAppendingPathComponent:@"safe"];
        if ([NSFileManager.defaultManager fileExistsAtPath:safeFlag]) {
            VCamLog(@"⛔️ 检测到救砖开关 %@，本次**完全不注入**（删除该文件即可恢复）",
                    safeFlag);
            return;
        }

        // ---- 0.5) 分级调试预算 ----
        // 正常模式（未设 VCAM_SAFE_LAUNCHES）→ 不限步数，完整注入。
        // 分级模式 → 本次启动只放行前 N 步，N 随启动次数递增。
        NSInteger allowed = VCamCurrentAllowedStages();
        VCamSetStageBudget(allowed);
        if (allowed != NSIntegerMax) {
            VCamLog(@"[staged] ⚠️ 分级调试模式：进程 %@ 第 %ld 次启动，"
                    @"本次只放行前 %ld 步注入（共 5~6 步）",
                    proc, (long)allowed, (long)allowed);
        }

        // ---- 1) 状态监听（所有进程都要，且必须最先做）----
        VCamRunStage(@"observeState", ^{
            [[VCamCore shared] observeStateIfNeeded];
        });

        // ---- 2) mediaserverd / 系统守护进程 ----
        if (VCamIsMediaServerProcess()) {
            VCamRunStage(@"msdWatchdog", ^{
                VCamMediaserverdWatchdog();
            });
            VCamRunStage(@"msdHook", ^{
                int hooked = VCamHookMediaServerdSymbols();
                VCamLog(@"[ctor] mediaserverd 层 hook 数量 = %d", hooked);
            });
            VCamRunStage(@"msdMic", ^{
                [[VCamMicInjector shared] installForMediaServer];
            });
            return;   // 系统守护进程不需要 App 层与 UI
        }

        // ---- 3) SpringBoard：只做 UI 与音量键，**绝不碰相机管线** ----
        if (VCamIsSpringBoardProcess()) {
            VCamRunStage(@"sbVolumeHook", ^{
                [VCamVolumeHook install];
            });
            VCamRunStage(@"sbPanel", ^{
                [[VCamPanel shared] prepare];
            });
            VCamLog(@"[ctor] SpringBoard 音量键与悬浮窗就绪");
            return;
        }

        // ---- 4) 其它进程（各 App）：AVFoundation 层 ----
        // 每个 install 单独一个阶段，这样"哪个 install 崩"能精确定位，
        // 而且崩过一次之后那一个就被永久跳过，其余功能仍可用。
        VCamRunStage(@"appSwizzle", ^{
            %init;
        });
        VCamRunStage(@"appMic", ^{
            [[VCamMicInjector shared] install];
        });
        VCamRunStage(@"appPhoto", ^{
            [VCamPhotoOutputInjector install];
        });
        VCamRunStage(@"appMovie", ^{
            [VCamMovieFileInjector install];
        });
        VCamRunStage(@"appOverlay", ^{
            // mediaserverd 层可用时，预览覆盖层就让位（避免一次多余的像素转换）
            if (![[VCamStateStore shared] msdDisabled]) {
                [VCamPreviewOverlay setPassthroughMode:NO];
            }
        });
        VCamLog(@"[ctor] App 层注入完成");
    }
}
