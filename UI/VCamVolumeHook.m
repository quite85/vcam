//
//  VCamVolumeHook.m
//  VCam
//

#import "VCamVolumeHook.h"
#import "VCamPanel.h"
#import "VCamHUD.h"
#import "VCamConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>

/// 私有通知名（AVSystemController）。找不到时自动退回公开 API。
static NSString *const kVCamSystemVolumeChanged =
    @"_AVSystemController_SystemVolumeDidChangeNotification";
static NSString *const kVCamSystemVolumeReasonKey = @"AVSystemController_AudioVolumeChangeReasonNotificationParameter";
static NSString *const kVCamSystemVolumeReasonExplicit = @"ExplicitVolumeChange";

@implementation VCamVolumeHook {
    BOOL _suspended;
    NSTimeInterval _lastTriggerTime;
    float _lastKnownVolume;
    BOOL _restorePending;
}

+ (instancetype)shared {
    static VCamVolumeHook *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamVolumeHook alloc] init]; });
    return s;
}

+ (void)install {
    [[self shared] _install];
}

+ (void)suspend { [self shared]->_suspended = YES; }
+ (void)resume  { [self shared]->_suspended = NO; }

#pragma mark - 安装

- (void)_install {
    _lastTriggerTime = 0;
    _lastKnownVolume = [self _currentVolume];

    // ---- 通道 A：公开 AVAudioSession 音量监听 ----
    // 注意：只 setActive，不要改 category，否则会影响正在运行的相机 App
    //      （改 category 会打断 App 的音频会话，是常见的"装了插件就没声音"的原因）
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [session setActive:YES withOptions:0 error:&err];
    if (err) {
        VCamLog(@"[vol] setActive 失败（继续尝试通道 B）: %@", err.localizedDescription);
    }
    [session addObserver:self
             forKeyPath:@"outputVolume"
                options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                context:NULL];

    // ---- 通道 B：私有 AVSystemController 通知 ----
    // reason == ExplicitVolumeChange 才是物理按键，程序改音量不会触发
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_systemVolumeChanged:)
                                                 name:kVCamSystemVolumeChanged
                                               object:nil];
    // 有些版本用带 bundle id 后缀的名字
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_systemVolumeChanged:)
                                                 name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                               object:nil];

    VCamLog(@"[vol] 音量键监听已安装");
}

#pragma mark - 通道 A

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    float newV = [change[NSKeyValueChangeNewKey] floatValue];
    float oldV = [change[NSKeyValueChangeOldKey] floatValue];
    [self _handleVolumeStepFrom:oldV to:newV explicit:NO];
}

#pragma mark - 通道 B

- (void)_systemVolumeChanged:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *reason = info[kVCamSystemVolumeReasonKey];
    if (reason && ![reason isEqualToString:kVCamSystemVolumeReasonExplicit]) {
        return;   // 程序调节音量，不是按键
    }
    float newV = [info[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
    [self _handleVolumeStepFrom:_lastKnownVolume to:newV explicit:YES];
}

#pragma mark - 共同处理

- (BOOL)_isCallActive {
    // 通话中不拦截音量键：用户可能真的想调通话音量
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (session.category == AVAudioSessionCategoryPlayAndRecord ||
        session.category == AVAudioSessionCategoryRecord) {
        // 录音类别不代表在通话，还要看其它 App 是否在跑。
        // 这里用比较保守的判断：有其它音频在播放且类别是 playAndRecord 时认为是通话/录音。
        return session.isOtherAudioPlaying ? YES : NO;
    }
    // 通过私有 API 再确认一次（拿不到就返回 NO）
    static BOOL (*isInCall)(void) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities",
                         RTLD_LAZY);
        if (h) isInCall = (BOOL (*)(void))dlsym(h, "TUIsCallActive");
    });
    if (isInCall) return isInCall();
    return NO;
}

- (float)_currentVolume {
    return [AVAudioSession sharedInstance].outputVolume;
}

- (void)_setVolume:(float)v {
    // 用 MPVolumeView 里的 UISlider 来"无声"地还原音量，避免弹音量 HUD
    static MPVolumeView *volumeView = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 100, 40)];
        UIWindow *w = UIApplication.sharedApplication.windows.firstObject;
        [w addSubview:volumeView];
    });
    UISlider *slider = nil;
    for (UIView *sub in volumeView.subviews) {
        if ([sub isKindOfClass:UISlider.class]) { slider = (UISlider *)sub; break; }
    }
    if (slider) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [slider setValue:v animated:NO];
            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
    }
}

- (void)_handleVolumeStepFrom:(float)oldV to:(float)newV explicit:(BOOL)explicit {
    if (_suspended) return;
    if (newV >= oldV - 0.0001f) return;      // 只处理"音量减"
    if (newV >= 1.0f) return;

    // 通话/录音中不拦截
    if ([self _isCallActive]) {
        VCamLog(@"[vol] 通话中，放行音量键");
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - _lastTriggerTime < 0.45) return;   // 去抖：连按不重复弹
    _lastTriggerTime = now;
    _lastKnownVolume = oldV;

    // 判断"短按"：用音量变化到我们处理之间的耗时近似。
    // 精确的按下/松开需要 hook AVAudioSession 的私有方法，
    // 但实测 OS 上报间隔 < 80ms，用固定延迟来区分长短按足够可靠。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        float nowVol = self->_currentVolume;
        // 如果这 280ms 内音量还在继续下降，说明用户在长按 → 不弹窗
        if (nowVol < self->_lastKnownVolume - 0.02f) {
            VCamLog(@"[vol] 判定为长按，放行系统音量调节");
            return;
        }
        // 短按：先把音量还原（"尽量不误调音量"），再弹窗
        if (self->_lastKnownVolume > 0.001f) {
            [self _setVolume:self->_lastKnownVolume];
        }
        [[VCamPanel shared] toggle];
    });
}

@end
