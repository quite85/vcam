//
//  VCamConfig.h
//  VCam —— 全局配置与跨进程共享状态的常量定义
//
//  设计要点：
//   1. UI 进程（SpringBoard）与媒体进程（mediaserverd）是两个不同的进程，
//      必须通过文件 + Darwin notification 交换状态，不能用内存单例跨进程。
//   2. 状态文件写在 /var/mobile/Library/VCam/ 下，权限 0644，
//      这样 mediaserverd（root）和沙盒 App 都能读。
//   3. 所有路径统一用 C 函数拼出来，兼容 rootful / rootless。
//

#ifndef VCAM_CONFIG_H
#define VCAM_CONFIG_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 运行模式

/// 虚拟源模式。数值故意与"UI 上的顺序"一致，方便写进 state 文件。
typedef NS_ENUM(NSInteger, VCamMode) {
    VCamModeDisabled = 0,   ///< 禁用替换：完整回到物理摄像头 + 物理麦
    VCamModeImage    = 1,   ///< 相册图片，按 ~30fps 重复同一帧
    VCamModeVideo    = 2,   ///< 相册视频，循环播放，音轨作为虚拟麦
    VCamModeOBS      = 3,   ///< OBS / 电脑推流，MPEG-TS over UDP/TCP
};

/// 音轨来源（视频自带音轨时用 Video；OBS 模式用 OBS）
typedef NS_ENUM(NSInteger, VCamAudioSourceKind) {
    VCamAudioSourceNone  = 0,
    VCamAudioSourceVideo = 1,
    VCamAudioSourceOBS   = 2,
    VCamAudioSourceTone  = 3,   ///< 兜底：无声（输出静音 PCM，防止 App 拿到脏数据）
};

/// 悬浮窗贴边位置。
/// 当前 VCamPanel 内部用局部变量记录吸附方向，这个枚举保留给「记住上次贴边位置」
/// 这类扩展使用（想加就把值写进 state.plist）。
typedef NS_ENUM(NSInteger, VCamPanelDock) {
    VCamPanelDockNone  = 0,
    VCamPanelDockLeft  = 1,
    VCamPanelDockRight = 2,
};

#pragma mark - 状态文件的键名

extern NSString *const kVCamStateKeyMode;          ///< NSNumber(VCamMode)
extern NSString *const kVCamStateKeyAssetPath;     ///< NSString，相册资源导出后的本地路径
extern NSString *const kVCamStateKeyAssetIsVideo;  ///< NSNumber(BOOL)
extern NSString *const kVCamStateKeyRotation;      ///< NSNumber，0/90/180/270
extern NSString *const kVCamStateKeyMirror;        ///< NSNumber(BOOL) 左右镜像
extern NSString *const kVCamStateKeyMirrorBack;    ///< NSNumber(BOOL) 前摄镜像（自拍习惯）
extern NSString *const kVCamStateKeyLoop;          ///< NSNumber(BOOL) 视频循环
extern NSString *const kVCamStateKeyPort;          ///< NSNumber，OBS 监听端口
extern NSString *const kVCamStateKeyTransport;     ///< NSString，"udp" 或 "tcp"
extern NSString *const kVCamStateKeyLatencyMs;     ///< NSNumber，目标缓冲延迟
extern NSString *const kVCamStateKeyAudioKind;     ///< NSNumber(VCamAudioSourceKind)
extern NSString *const kVCamStateKeyAudioVolume;   ///< NSNumber(float) 0.0-2.0
extern NSString *const kVCamStateKeyLipSyncMs;     ///< NSNumber，音频相对视频的偏移（毫秒）
extern NSString *const kVCamStateKeyMSDDisabled;   ///< NSNumber(BOOL) mediaserverd 层是否已被自动降级
extern NSString *const kVCamStateKeyAppLayerOnly;  ///< NSNumber(BOOL) 只做 App 层注入
extern NSString *const kVCamStateKeySessionActive; ///< NSNumber(BOOL) 当前是否有活跃采集会话
extern NSString *const kVCamStateKeyLastError;     ///< NSString，最近一次错误（给用户排查）
extern NSString *const kVCamStateKeyVersion;       ///< NSNumber，配置结构版本

#pragma mark - 通知名

/// 状态变化广播。mediaserverd 侧 dlsym 监听，收到后 reload。
extern NSString *const kVCamNotificationStateChanged;
/// 请求 UI 进程刷新悬浮窗文案
extern NSString *const kVCamNotificationUIrefresh;
/// mediaserverd 报告"注入层不可用"，UI 侧据此提示用户
extern NSString *const kVCamNotificationMSDUnavailable;

#pragma mark - 路径工具（兼容 rootful / rootless）

/// 状态存储目录：/var/mobile/Library/VCam（不存在则尝试创建）
FOUNDATION_EXPORT NSString *VCamStateDirectory(void);
/// 状态 plist：/var/mobile/Library/VCam/state.plist
FOUNDATION_EXPORT NSString *VCamStateFilePath(void);
/// 日志文件：/var/mobile/Library/VCam/vcam.log（滚动，最大 256KB）
FOUNDATION_EXPORT NSString *VCamLogFilePath(void);
/// mediaserverd 崩溃标记
FOUNDATION_EXPORT NSString *VCamMSDCrashFlagPath(void);
/// 相册资源导出目录（视频/图片转成本地文件，避免每次解码 PHAsset）
FOUNDATION_EXPORT NSString *VCamAssetCacheDirectory(void);
/// 录像注入的临时输出目录
FOUNDATION_EXPORT NSString *VCamRecordingTempDirectory(void);
/// 当前进程是否是 mediaserverd 家族
FOUNDATION_EXPORT BOOL VCamIsMediaServerProcess(void);
/// 当前进程是否是 SpringBoard
FOUNDATION_EXPORT BOOL VCamIsSpringBoardProcess(void);
/// 当前进程名
FOUNDATION_EXPORT NSString *VCamCurrentProcessName(void);
/// 简易日志（同时写 stderr 与文件，带滚动截断）
FOUNDATION_EXPORT void VCamLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END

#endif /* VCAM_CONFIG_H */
