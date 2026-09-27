//
//  VCamCore.h
//  VCam
//
//  全局单例：把"当前用哪种虚拟源 + 出帧 + 出音频"收敛到一个对象。
//
//  使用方式（注入层）：
//      CVPixelBufferRef pb = [[VCamCore shared] copyPixelBufferForNow];
//      if (pb) { 替换原始帧; CVPixelBufferRelease(pb); } else { 走真相机; }
//
//  这样无论 mediaserverd 层还是 App 层，注入代码都只有几行，
//  而且禁用替换时 copyPixelBufferForNow 直接返回 NULL，天然 fallback 硬件。
//

#ifndef VCAM_CORE_H
#define VCAM_CORE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "VCamFrameSource.h"
#import "VCamStateStore.h"

NS_ASSUME_NONNULL_BEGIN

/// 摄像头朝向（用于前摄镜像判断）
typedef NS_ENUM(NSInteger, VCamCameraPosition) {
    VCamCameraPositionUnspecified = 0,
    VCamCameraPositionBack,
    VCamCameraPositionFront,
};

@interface VCamCore : NSObject

/// 单例
+ (instancetype)shared;

/// 启动状态监听（构造后第一次 reload 会自动调用）
- (void)observeStateIfNeeded;

/// 当前状态（只读快照，内部会随通知自动更新）
@property (nonatomic, readonly, strong) VCamStateStore *store;

/// 当前虚拟源（nil = 禁用替换）
@property (nonatomic, readonly, strong, nullable) VCamFrameSourceBase *source;
/// 当前模式
@property (nonatomic, readonly) VCamMode mode;
/// 是否处于"替换中"（模式非 disabled 且源已就绪）
@property (nonatomic, readonly) BOOL active;
/// 上一次失败原因（给 UI 显示）
@property (nonatomic, readonly, copy, nullable) NSString *lastError;
/// 状态描述文案（悬浮窗用）
@property (nonatomic, readonly, copy) NSString *statusText;

/// 依据 VCamStateStore 重新加载源。状态变化时自动调用，也可手动调用。
- (void)reloadFromState;

/// 取一帧（+1 引用，调用方负责 CVPixelBufferRelease）。
/// 返回 NULL 表示"没有虚拟帧，请用真实硬件"。
- (CVPixelBufferRef _Nullable)copyPixelBufferForNow CF_RETURNS_RETAINED;

/// 取一帧并指定"期望尺寸"，内部会做一次 aspect-fill 缩放。
/// App 层的 AVCaptureVideoDataOutput 会给出自己的 dimensions，
/// 用这个接口可以避免尺寸不匹配导致的预览拉伸。
- (CVPixelBufferRef _Nullable)copyPixelBufferForWidth:(size_t)width
                                               height:(size_t)height CF_RETURNS_RETAINED;

/// 当前朝向（前后摄），影响前摄镜像
@property (nonatomic, assign) VCamCameraPosition cameraPosition;

/// 取 PCM 音频：把最近的音频数据拷到 outBuffer（交错 float32）。
/// 返回实际写入的帧数；0 表示没有音频（走真实麦）。
- (size_t)pullPCMInto:(float *)outBuffer
            maxFrames:(size_t)maxFrames
             channels:(UInt32)channels
           sampleRate:(Float64)sampleRate;

/// 是否有可用的虚拟音频
- (BOOL)hasAudio;

/// 是否处于"静音占位"（OBS/视频有画面但没音轨时，输出静音 PCM 以防止
/// 下游拿到真实麦克风数据造成串音）
@property (nonatomic, readonly) BOOL audioMutedPlaceholder;

/// 释放所有资源（禁用替换时调用，立刻回到硬件）
- (void)teardown;

/// 通知"相册资源已导入"，触发 reload
- (void)setAssetPath:(NSString *)path isVideo:(BOOL)isVideo;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_CORE_H */
