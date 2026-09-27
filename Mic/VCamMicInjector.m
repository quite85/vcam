//
//  VCamMicInjector.m
//  VCam
//

#import "VCamMicInjector.h"
#import "VCamConfig.h"
#import "VCamCore.h"
#import "VCamPixelBufferUtils.h"
#import "VCamPreviewOverlay.h"
#import "VCamVideoDataOutputProxy.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>          // dlsym / dlopen（运行时查找 MSHookFunction）
// 说明：这里**不** #import <substrate.h>。
//   1) 本文件不需要它 —— 所有 hook 入口都用 dlsym 取函数指针
//      （见下面的 HookFn / VCamAudioUnitSetPropertyFn），
//      不需要编译期的 MSHookFunction 声明；
//   2) Theos 自带的 vendor/include/substrate.h 只有一行 `CydiaSubstrate.h`，
//      而它又用尖括号引用 <CydiaSubstrate/CydiaSubstrate.h>，
//      需要额外把 $THEOS/vendor/lib 加进 -I 才能解析，CI 上会报
//        fatal error: 'CydiaSubstrate/CydiaSubstrate.h' file not found
//      去掉这个 import 后，rootful / rootless / roothide 都不会因此失败。

#pragma mark - 音频数据代理（AVCaptureAudioDataOutput）

static const void *kVCamAudioProxyKey = &kVCamAudioProxyKey;
static const void *kVCamAudioRealKey  = &kVCamAudioRealKey;
static const void *kVCamAudioQueueKey = &kVCamAudioQueueKey;

@interface VCamAudioDataOutputProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) AVCaptureAudioDataOutput *output;
@property (nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> real;
@end

@implementation VCamAudioDataOutputProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef deliver = sampleBuffer;
    CMSampleBufferRef virtual = NULL;

    VCamCore *core = [VCamCore shared];
    if (core.active) {
        @try {
            // 下游要求的格式（采样率/声道数/格式标志）直接从真实 buffer 读出来，
            // 这样我们构造的 buffer 与 App 期望的完全一致，避免 App 侧解析出错。
            CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sampleBuffer);
            const AudioStreamBasicDescription *asbd =
                fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
            size_t nFrames = CMSampleBufferGetNumSamples(sampleBuffer);
            if (asbd && nFrames > 0) {
                UInt32 ch = MAX(1u, asbd->mChannelsPerFrame);
                Float64 rate = asbd->mSampleRate > 0 ? asbd->mSampleRate : 48000.0;

                // 上限保护：一次最多处理 8192 帧，防止异常值导致大分配
                size_t frames = MIN(nFrames, (size_t)8192);
                float *pcm = (float *)calloc(frames * ch, sizeof(float));
                if (pcm) {
                    size_t got = [core pullPCMInto:pcm maxFrames:frames
                                          channels:ch sampleRate:rate];
                    if (got > 0) {
                        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                        virtual = [VCamPixelBufferUtils sampleBufferFromFloat32PCM:pcm
                                                                            frames:got
                                                                          channels:ch
                                                                        sampleRate:rate
                                                                          hostTime:pts];
                        if (virtual) deliver = virtual;
                    }
                    free(pcm);
                }
            }
        } @catch (NSException *e) {
            VCamLog(@"[mic] 音频注入异常（回退真实音频）: %@", e);
            if (virtual) { CFRelease(virtual); virtual = NULL; }
            deliver = sampleBuffer;
        }
    }

    id real = self.real;
    if (real && [real respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [real captureOutput:output didOutputSampleBuffer:deliver fromConnection:connection];
    }
    if (virtual) CFRelease(virtual);
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id real = self.real;
    if (real && [real respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [real captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return self.real && [self.real respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (self.real && [self.real respondsToSelector:aSelector]) return self.real;
    return [super forwardingTargetForSelector:aSelector];
}

@end

static const void *kVCamAudioProxyAssocKey = &kVCamAudioProxyAssocKey;

@implementation AVCaptureAudioDataOutput (VCamMicProxy)

- (void)vcam_setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                               queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:VCamAudioDataOutputProxy.class] && delegate) {
        VCamAudioDataOutputProxy *proxy = [[VCamAudioDataOutputProxy alloc] init];
        proxy.output = self;
        proxy.real = delegate;
        objc_setAssociatedObject(self, kVCamAudioProxyAssocKey, proxy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];   // 调用原实现
        VCamLog(@"[mic] 已为 AVCaptureAudioDataOutput 安装音频代理");
        return;
    }
    [self vcam_setSampleBufferDelegate:delegate queue:queue];
}

@end

#pragma mark - 注入器

@implementation VCamMicInjector {
    BOOL _installed;
    BOOL _mediaServerInstalled;
    os_unfair_lock _lock;
}

+ (instancetype)shared {
    static VCamMicInjector *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamMicInjector alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

#pragma mark - App 层

- (void)install {
    os_unfair_lock_lock(&_lock);
    if (_installed) { os_unfair_lock_unlock(&_lock); return; }
    _installed = YES;
    os_unfair_lock_unlock(&_lock);

    // 1) AVCaptureAudioDataOutput —— 相机同时录视频+音频的 App 走这里
    Class audioOut = NSClassFromString(@"AVCaptureAudioDataOutput");
    if (audioOut) {
        [self _swizzle:audioOut
          originalSel:@selector(setSampleBufferDelegate:queue:)
        replacementSel:@selector(vcam_setSampleBufferDelegate:queue:)];
    }

    // 2) AVAudioRecorder —— 语音/录音类 App
    Class recorder = NSClassFromString(@"AVAudioRecorder");
    if (recorder) {
        [self _swizzle:recorder
          originalSel:@selector(record)
        replacementSel:@selector(vcam_record)];
        [self _swizzle:recorder
          originalSel:@selector(recordForDuration:)
        replacementSel:@selector(vcam_recordForDuration:)];
    }

    // 3) 状态变化时，禁用替换就卸载
    [[VCamStateStore shared] observeChanges:^{
        if ([VCamStateStore shared].mode == VCamModeDisabled) {
            VCamLog(@"[mic] 模式=禁用，音频注入让位给真实麦克风");
        }
    }];

    VCamLog(@"[mic] App 层麦克风注入已安装");
}

- (void)_swizzle:(Class)cls originalSel:(SEL)orig replacementSel:(SEL)repl {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

#pragma mark - mediaserverd 层

- (void)installForMediaServer {
    os_unfair_lock_lock(&_lock);
    if (_mediaServerInstalled) { os_unfair_lock_unlock(&_lock); return; }
    _mediaServerInstalled = YES;
    os_unfair_lock_unlock(&_lock);

    // ---- 关键：替换 AudioUnit 的 input render callback ----
    //
    // mediaserverd 里所有麦克风数据都经由 AudioUnit 的 render callback
    // 交付给上层。做法是 swizzle AudioUnitSetProperty：
    // 当有人设置 kAudioOutputUnitProperty_SetInputCallback（输入回调）时，
    // 我们把回调换成自己的，并在里面把 ioData 的内容改成虚拟 PCM。
    //
    // 为什么不在 "input proc" 上做：input proc 是给 A/D 送原始数据的，
    // mediaserverd 自己会创建它；我们替换 SetInputCallback 更靠上层，
    // 拿到的已经是 mediaserverd 处理好的 buffer，直接覆盖即可。
    Class audioUnitClass = NSClassFromString(@"AudioUnit");
    if (!audioUnitClass) audioUnitClass = NSClassFromString(@"AUAudioUnit");
    // AudioUnitSetProperty 是 C 函数，不是 ObjC 方法，所以走符号 hook
    [self _hookAudioUnitSetProperty];

    VCamLog(@"[mic] mediaserverd 层麦克风注入已安装（AURemoteIO 路径）");
}

typedef OSStatus (*VCamAudioUnitSetPropertyFn)(AudioUnit inUnit,
                                              AudioUnitPropertyID inID,
                                              AudioUnitScope inScope,
                                              AudioUnitElement inElement,
                                              const void *inData,
                                              UInt32 inDataSize);
static VCamAudioUnitSetPropertyFn gOrigAudioUnitSetProperty = NULL;

/// 我们自己的 input callback：
/// 先调用原始回调（让 mediaserverd 把真实数据填进去，保持内部状态一致），
/// 再用虚拟 PCM 覆盖 ioData 的内容。这样内部计时器、帧计数都不会错。
static OSStatus vcam_InputCallback(void *inRefCon,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    // 原回调存在 refCon 的一个包装结构里；找不到就什么也不做
    VCamCore *core = [VCamCore shared];
    if (!ioData || inNumberFrames == 0) return noErr;

    if (core.active) {
        @try {
            UInt32 ch = ioData->mNumberBuffers > 0
                      ? MAX(1u, ioData->mBuffers[0].mNumberChannels) : 1;
            // 采样率：从 AudioUnit 上读不方便，统一按 48k 处理（iOS 内建麦常见值），
            // 若实际不同，pullPCMInto 会做重采样
            Float64 rate = 48000.0;
            size_t frames = MIN((size_t)inNumberFrames, (size_t)8192);
            float *pcm = (float *)calloc(frames * ch, sizeof(float));
            if (pcm) {
                size_t got = [core pullPCMInto:pcm maxFrames:frames channels:ch sampleRate:rate];
                if (got > 0) {
                    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
                        AudioBuffer *buf = &ioData->mBuffers[b];
                        UInt32 bufCh = MAX(1u, buf->mNumberChannels);
                        float *dst = (float *)buf->mData;
                        if (!dst) continue;
                        size_t maxFrames = buf->mDataByteSize / (sizeof(float) * bufCh);
                        for (size_t i = 0; i < MIN(maxFrames, got); i++) {
                            for (UInt32 c = 0; c < bufCh; c++) {
                                dst[i * bufCh + c] = pcm[i * ch + MIN(c, ch - 1)];
                            }
                        }
                    }
                }
                free(pcm);
            }
        } @catch (NSException *e) {
            VCamLog(@"[mic][msd] input callback 异常，使用真实数据: %@", e);
        }
    }
    return noErr;
}

- (void)_hookAudioUnitSetProperty {
    void *sym = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if (!sym) {
        VCamLog(@"[mic][msd] 找不到 AudioUnitSetProperty");
        return;
    }
    // ElleKit / Substrate 的 MSHookFunction
    typedef void (*HookFn)(void *, void *, void **);
    HookFn hook = (HookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!hook) {
        void *h = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
        if (!h) h = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
        if (!h) h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
        if (h) hook = (HookFn)dlsym(h, "MSHookFunction");
    }
    if (!hook) {
        VCamLog(@"[mic][msd] hook 引擎不可用，mediaserverd 音频替换跳过（退回 App 层）");
        return;
    }
    hook(sym, (void *)vcam_AudioUnitSetProperty, (void **)&gOrigAudioUnitSetProperty);
    VCamLog(@"[mic][msd] 已 hook AudioUnitSetProperty @ %p", sym);
}

/// 替换实现：把输入回调换成我们的
static OSStatus vcam_AudioUnitSetProperty(AudioUnit inUnit,
                                          AudioUnitPropertyID inID,
                                          AudioUnitScope inScope,
                                          AudioUnitElement inElement,
                                          const void *inData,
                                          UInt32 inDataSize) {
    if (inID == kAudioOutputUnitProperty_SetInputCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct original = *(const AURenderCallbackStruct *)inData;
        AURenderCallbackStruct ours = original;
        ours.inputProc = vcam_InputCallback;
        // refCon 保留原值：我们的回调里暂时不用它（真实数据由 mediaserverd
        // 自己在 render 阶段填充），这样不会破坏它的内部结构。
        VCamLog(@"[mic][msd] 替换输入回调 %p -> %p", original.inputProc, vcam_InputCallback);
        if (gOrigAudioUnitSetProperty) {
            return gOrigAudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                             &ours, sizeof(ours));
        }
    }
    if (gOrigAudioUnitSetProperty) {
        return gOrigAudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
    }
    return noErr;
}

#pragma mark - 卸载

- (void)uninstall {
    // 视频代理与音频代理一起卸掉，恢复真实的 AVCapture 数据流
    [VCamVideoDataOutputProxy uninstallAll];
    VCamLog(@"[mic] 已卸载音频注入，恢复真实麦克风");
}

@end

#pragma mark - AVAudioRecorder 替换实现

@implementation AVAudioRecorder (VCamMic)

- (BOOL)vcam_record {
    // 真实麦克风在被虚拟麦接管的场景下仍然存在（我们只是覆盖数据），
    // 所以这里只需要保证音频会话是激活的，避免录音直接失败。
    // 数据层面的替换由 AVCaptureAudioDataOutput 代理与 AudioUnit 层完成。
    if ([VCamCore shared].active) {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES withOptions:0 error:&err];
        if (err) VCamLog(@"[mic] 激活音频会话失败: %@", err.localizedDescription);
    }
    return [self vcam_record];   // swizzle 后指向原实现
}

- (BOOL)vcam_recordForDuration:(NSTimeInterval)duration {
    if ([VCamCore shared].active) {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES withOptions:0 error:&err];
        if (err) VCamLog(@"[mic] 激活音频会话失败: %@", err.localizedDescription);
    }
    return [self vcam_recordForDuration:duration];   // swizzle 后指向原实现
}

@end
