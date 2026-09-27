//
//  VCamCore.m
//  VCam
//

#import "VCamCore.h"
#import "VCamConfig.h"
#import "VCamImageSource.h"
#import "VCamVideoSource.h"
#import "VCamOBSSource.h"
#import "VCamPixelBufferUtils.h"
#import "VCamConcurrentQueue.h"
#import <os/lock.h>

#pragma mark - 音频环形缓冲（交错 float32，固定立体声）

@interface VCamAudioRing : NSObject
- (instancetype)initWithCapacityFrames:(NSUInteger)frames;
- (void)write:(const float *)src frames:(NSUInteger)frames channels:(UInt32)channels;
- (size_t)readInto:(float *)dst maxFrames:(NSUInteger)maxFrames channels:(UInt32)channels;
- (void)flush;
@property (nonatomic, readonly) NSUInteger availableFrames;
@end

@implementation VCamAudioRing {
    float *_buf;            // 内部固定立体声交错
    NSUInteger _capacity;   // 帧数
    NSUInteger _count;
    NSUInteger _head;
    os_unfair_lock _lock;
    // 简易线性重采样用的上一样本（按通道）
    float _lastL, _lastR;
    double _frac;
}

- (instancetype)initWithCapacityFrames:(NSUInteger)frames {
    if ((self = [super init])) {
        _capacity = MAX(1024, frames);
        _buf = (float *)calloc(_capacity * 2, sizeof(float));
        _lock = OS_UNFAIR_LOCK_INIT;
        _frac = 0;
    }
    return self;
}

- (void)dealloc { if (_buf) free(_buf); }

- (NSUInteger)availableFrames {
    os_unfair_lock_lock(&_lock);
    NSUInteger c = _count;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (void)write:(const float *)src frames:(NSUInteger)frames channels:(UInt32)channels {
    if (!src || frames == 0) return;
    os_unfair_lock_lock(&_lock);
    for (NSUInteger i = 0; i < frames; i++) {
        float l, r;
        if (channels >= 2) {
            l = src[i * channels];
            r = src[i * channels + 1];
        } else {
            l = r = src[i * channels];   // 单声道复制成双声道
        }
        if (_count == _capacity) {
            // 满了丢最旧
            _head = (_head + 1) % _capacity;
            _count--;
        }
        NSUInteger idx = (_head + _count) % _capacity;
        _buf[idx * 2] = l;
        _buf[idx * 2 + 1] = r;
        _count++;
    }
    os_unfair_lock_unlock(&_lock);
}

/// 读 maxFrames 帧（按请求的声道数展开）。
/// 采样率不一致时用线性插值做简易重采样（语音场景够用，且无需分配内存）。
- (size_t)readInto:(float *)dst maxFrames:(NSUInteger)maxFrames channels:(UInt32)channels {
    if (!dst || maxFrames == 0) return 0;
    size_t written = 0;
    os_unfair_lock_lock(&_lock);
    while (written < maxFrames && _count > 0) {
        float l = _buf[_head * 2];
        float r = _buf[_head * 2 + 1];
        _head = (_head + 1) % _capacity;
        _count--;
        if (channels >= 2) {
            dst[written * channels] = l;
            dst[written * channels + 1] = r;
            for (UInt32 c = 2; c < channels; c++) dst[written * channels + c] = 0.0f;
        } else {
            dst[written] = (l + r) * 0.5f;
        }
        written++;
    }
    // 欠载时用最后一次样本淡出，避免爆音（真实的 underrun 处理）
    if (written < maxFrames) {
        for (size_t i = written; i < maxFrames; i++) {
            float fade = 1.0f - (float)(i - written) / (float)MAX(1, maxFrames - written);
            _lastL *= fade * 0.98f;
            _lastR *= fade * 0.98f;
            if (channels >= 2) {
                dst[i * channels] = _lastL;
                dst[i * channels + 1] = _lastR;
                for (UInt32 c = 2; c < channels; c++) dst[i * channels + c] = 0.0f;
            } else {
                dst[i] = (_lastL + _lastR) * 0.5f;
            }
        }
        written = maxFrames;   // 已经用静音补满，视为"有效输出"
    } else {
        _lastL = dst[(written - 1) * MAX(1, channels)];
        _lastR = dst[(written - 1) * MAX(1, channels) + (channels >= 2 ? 1 : 0)];
    }
    os_unfair_lock_unlock(&_lock);
    return written;
}

- (void)flush {
    os_unfair_lock_lock(&_lock);
    _count = 0;
    _head = 0;
    _lastL = _lastR = 0;
    os_unfair_lock_unlock(&_lock);
}

@end

#pragma mark - VCamCore

@implementation VCamCore {
    VCamStateStore *_store;
    VCamFrameSourceBase *_source;
    VCamAudioRing *_audioRing;
    os_unfair_lock _lock;

    CVPixelBufferRef _latestFrame;     // 最近一帧（+1）
    CMTime _latestFrameTime;
    BOOL _active;
    NSString *_lastError;
    BOOL _observing;
}

+ (instancetype)shared {
    static VCamCore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamCore alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _store = [VCamStateStore shared];
        _audioRing = [[VCamAudioRing alloc] initWithCapacityFrames:48000 * 2]; // 最多 2 秒
        _cameraPosition = VCamCameraPositionBack;
    }
    return self;
}

- (VCamStateStore *)store { return _store; }
- (VCamMode)mode { return _store.mode; }
- (VCamFrameSourceBase *)source {
    os_unfair_lock_lock(&_lock);
    VCamFrameSourceBase *s = _source;
    os_unfair_lock_unlock(&_lock);
    return s;
}

- (BOOL)active {
    os_unfair_lock_lock(&_lock);
    BOOL a = _active;
    os_unfair_lock_unlock(&_lock);
    return a;
}

- (NSString *)lastError {
    os_unfair_lock_lock(&_lock);
    NSString *e = _lastError;
    os_unfair_lock_unlock(&_lock);
    return e ?: _store.lastError;
}

- (NSString *)statusText {
    if (_store.mode == VCamModeDisabled) return @"已禁用替换（硬件相机）";
    os_unfair_lock_lock(&_lock);
    BOOL a = _active;
    NSString *err = _lastError;
    os_unfair_lock_unlock(&_lock);
    if (!a) {
        if (err.length) return [NSString stringWithFormat:@"失败：%@", err];
        return @"未就绪";
    }
    VCamFrameSourceBase *src = self.source;
    NSString *s = src.statusText ?: @"运行中";
    if (_store.mirror) s = [s stringByAppendingString:@" · 镜像"];
    if (_store.rotation != 0) s = [s stringByAppendingFormat:@" · %ld°", (long)_store.rotation];
    return s;
}

- (BOOL)audioMutedPlaceholder {
    // 视频/OBS 模式下如果没有音轨，仍然要"接管"麦克风并输出静音，
    // 否则 App 会继续拿物理麦，导致画面是虚拟的而声音是真的（很容易被看出来）
    if (_store.mode == VCamModeDisabled) return NO;
    return !self.hasAudio;
}

- (BOOL)hasAudio {
    VCamFrameSourceBase *src = self.source;
    if (!src) return NO;
    if (_store.audioKind == VCamAudioSourceNone) return NO;
    return YES;
}

#pragma mark - 状态同步

- (void)observeStateIfNeeded {
    if (_observing) return;
    _observing = YES;
    __weak typeof(self) weakSelf = self;
    [_store observeChanges:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self reloadFromState];
    }];
}

- (void)reloadFromState {
    [self observeStateIfNeeded];

    VCamMode mode = _store.mode;
    if (_store.msdDisabled && VCamIsMediaServerProcess() && !_store.appLayerOnly) {
        // mediaserverd 层被自动降级过：这个进程里就不要注入，避免再次崩
        VCamLog(@"[core] mediaserverd 层已降级，本进程不注入");
        [self teardown];
        return;
    }

    VCamFrameSourceBase *old = nil;
    os_unfair_lock_lock(&_lock);
    old = _source;
    _source = nil;
    _active = NO;
    _lastError = nil;
    os_unfair_lock_unlock(&_lock);
    if (old) { [old invalidate]; }

    if (mode == VCamModeDisabled) {
        [_audioRing flush];
        VCamLog(@"[core] 模式=禁用，已恢复硬件相机/麦克风");
        [self _releaseLatestFrame];
        return;
    }

    VCamFrameSourceBase *src = nil;
    switch (mode) {
        case VCamModeImage: {
            NSString *p = _store.assetPath;
            if (p.length == 0) {
                [self _fail:@"未选择图片"];
                return;
            }
            src = [[VCamImageSource alloc] initWithImagePath:p];
            break;
        }
        case VCamModeVideo: {
            NSString *p = _store.assetPath;
            if (p.length == 0) {
                [self _fail:@"未选择视频"];
                return;
            }
            VCamVideoSource *v = [[VCamVideoSource alloc] initWithVideoPath:p];
            v.loop = _store.loop;
            v.audioGain = _store.audioVolume;
            src = v;
            break;
        }
        case VCamModeOBS: {
            VCamOBSSource *o = [[VCamOBSSource alloc] init];
            o.transport = _store.transport;
            o.urlString = [NSString stringWithFormat:@"%@://0.0.0.0:%u",
                           _store.transport, _store.port];
            o.holdLastFrame = YES;
            src = o;
            break;
        }
        default:
            break;
    }
    if (!src) return;

    // 统一配置
    // 帧率固定 30：社交/直播 App 绝大多数就是 30fps，
    // 给 60fps 只会让缩放+旋转的 CPU 开销翻倍而没有收益。
    src.targetFPS = 30;
    src.rotation = (VCamRotation)_store.rotation;
    src.mirror = _store.mirror;
    src.lipSyncOffsetMs = _store.lipSyncMs;

    // 输出尺寸：
    //   竖屏（默认）1080x1920 —— 大多数社交 App 的相机预览是 9:16 全屏
    //   横屏        1920x1080 —— FaceTime / Zoom / 平板场景
    // 由小窗的「📐 横屏/竖屏切换」按钮控制（存在 NSUserDefaults 的
    // vcam_landscape 键里，不放进 state.plist 是因为它只影响本进程的输出尺寸，
    // 不需要跨进程同步）。
    BOOL landscape = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_landscape"];
    src.targetSize = landscape ? CGSizeMake(1920, 1080) : CGSizeMake(1080, 1920);

    __weak typeof(self) weakSelf = self;
    src.frameHandler = ^(CVPixelBufferRef pb, CMTime t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _acceptFrame:pb atTime:t];
    };
    src.audioHandler = ^(const float *pcm, size_t frames, UInt32 ch,
                         Float64 rate, CMTime t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self->_audioRing write:pcm frames:frames channels:ch];
    };

    if (![src start]) {
        [self _fail:src.lastError ?: @"虚拟源启动失败"];
        [src invalidate];
        return;
    }

    os_unfair_lock_lock(&_lock);
    _source = src;
    _active = YES;
    os_unfair_lock_unlock(&_lock);
    VCamLog(@"[core] 模式=%ld 源已启动: %@", (long)mode, src.statusText);
}

- (void)_fail:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    _lastError = [reason copy];
    _active = NO;
    os_unfair_lock_unlock(&_lock);
    [_store recordError:reason];
    VCamLog(@"[core] 启动失败: %@", reason);
}

- (void)setAssetPath:(NSString *)path isVideo:(BOOL)isVideo {
    [_store setAssetPath:path isVideo:isVideo];
    [_store setMode:isVideo ? VCamModeVideo : VCamModeImage];
    [_store setAudioKind:isVideo ? VCamAudioSourceVideo : VCamAudioSourceNone];
    [self reloadFromState];
}

#pragma mark - 帧

- (void)_acceptFrame:(CVPixelBufferRef)pb atTime:(CMTime)t {
    if (!pb) return;
    CVPixelBufferRef keep = CVPixelBufferRetain(pb);
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _latestFrame;
    _latestFrame = keep;
    _latestFrameTime = CMTIME_IS_NUMERIC(t) ? t : CMClockGetTime(CMClockGetHostTimeClock());
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

- (void)_releaseLatestFrame {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _latestFrame;
    _latestFrame = NULL;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

- (CVPixelBufferRef)copyPixelBufferForNow {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _latestFrame;
    if (pb) CVPixelBufferRetain(pb);
    os_unfair_lock_unlock(&_lock);
    return pb;
}

- (CVPixelBufferRef)copyPixelBufferForWidth:(size_t)width height:(size_t)height {
    CVPixelBufferRef pb = [self copyPixelBufferForNow];
    if (!pb) return NULL;
    if (width == 0 || height == 0) return pb;
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (w == width && h == height) return pb;
    CVPixelBufferRef scaled = [VCamPixelBufferUtils scalePixelBuffer:pb
                                                              toWidth:width
                                                               height:height];
    CVPixelBufferRelease(pb);
    return scaled;   // 可能为 NULL（缩放失败），调用方需判断
}

#pragma mark - 音频

- (size_t)pullPCMInto:(float *)outBuffer
            maxFrames:(size_t)maxFrames
             channels:(UInt32)channels
           sampleRate:(Float64)sampleRate {
    if (!outBuffer || maxFrames == 0) return 0;
    // 源音频统一是 48k 立体声；若下游要别的采样率，这里做一次线性重采样
    if (fabs(sampleRate - 48000.0) > 1.0) {
        // 需要多少输入帧才能产出 maxFrames 输出帧
        double ratio = 48000.0 / sampleRate;
        size_t need = (size_t)(maxFrames * ratio) + 2;
        float *tmp = (float *)malloc(need * 2 * sizeof(float));
        if (!tmp) return 0;
        size_t got = [_audioRing readInto:tmp maxFrames:need channels:2];
        for (size_t i = 0; i < maxFrames; i++) {
            double srcPos = i * ratio;
            size_t i0 = (size_t)srcPos;
            size_t i1 = MIN(i0 + 1, got ? got - 1 : 0);
            double f = srcPos - i0;
            float l = got ? (float)(tmp[i0*2] * (1.0 - f) + tmp[i1*2] * f) : 0.0f;
            float r = got ? (float)(tmp[i0*2+1] * (1.0 - f) + tmp[i1*2+1] * f) : 0.0f;
            if (channels >= 2) {
                outBuffer[i*channels] = l;
                outBuffer[i*channels+1] = r;
                for (UInt32 c = 2; c < channels; c++) outBuffer[i*channels+c] = 0.0f;
            } else {
                outBuffer[i] = (l + r) * 0.5f;
            }
        }
        free(tmp);
        return maxFrames;
    }
    return [_audioRing readInto:outBuffer maxFrames:maxFrames channels:channels];
}

#pragma mark - 清理

- (void)teardown {
    VCamFrameSourceBase *src = nil;
    os_unfair_lock_lock(&_lock);
    src = _source;
    _source = nil;
    _active = NO;
    os_unfair_lock_unlock(&_lock);
    [src invalidate];
    [_audioRing flush];
    [self _releaseLatestFrame];
    [VCamPixelBufferUtils flushPools];
    VCamLog(@"[core] teardown 完成（释放 pool 与像素缓冲）");
}

@end
