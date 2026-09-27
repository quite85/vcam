//
//  VCamFrameSource.h
//  VCam
//
//  帧源抽象。所有虚拟画面（图片 / 视频 / OBS）都实现同一套协议，
//  上层（mediaserverd 注入层、AVFoundation 注入层、预览层）只依赖这个协议，
//  因此新增一种源不需要改 hook 代码。
//
//  内存约定（非常重要，写错了就是每帧泄漏一个 1080p buffer）：
//   - 生产者（FrameSource）保证在调用 frameHandler 期间 pixelBuffer 有效；
//   - 回调返回后，生产者会立即释放这一帧的持有；
//   - 回调方如果需要跨函数保留（比如丢进 dispatch_async），必须自己
//     CVPixelBufferRetain / Release，或直接用 CVPixelBufferPool 复制。
//

#ifndef VCAM_FRAME_SOURCE_H
#define VCAM_FRAME_SOURCE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "VCamPixelBufferUtils.h"

NS_ASSUME_NONNULL_BEGIN

/// 视频帧回调。presentationTime 已换算到 host 时基（可直接给 CMSampleBuffer 用）
typedef void (^VCamFrameHandler)(CVPixelBufferRef pixelBuffer, CMTime presentationTime);

/// 音频回调。data 为交错 float32，长度 = frames * channels * 4 字节。
/// 生命周期同帧回调：回调返回后生产者即可复用该内存。
typedef void (^VCamAudioHandler)(const float *interleaved,
                                 size_t frames,
                                 UInt32 channels,
                                 Float64 sampleRate,
                                 CMTime presentationTime);

@protocol VCamFrameSource <NSObject>

/// 目标输出尺寸（injector 会请求这个尺寸的帧；源内部按需缩放）
@property (nonatomic, assign) CGSize targetSize;
/// 目标帧率，默认 30
@property (nonatomic, assign) NSInteger targetFPS;
/// 旋转（0/90/180/270）
@property (nonatomic, assign) VCamRotation rotation;
/// 左右镜像
@property (nonatomic, assign) BOOL mirror;
/// 唇形同步微调：音频时间戳整体平移的毫秒数（正数 = 音频延后）
@property (nonatomic, assign) NSInteger lipSyncOffsetMs;

/// 帧回调（可空：OBS 模式只出音频时不注册）
@property (nonatomic, copy, nullable) VCamFrameHandler frameHandler;
/// 音频回调（可空：图片模式没有音频）
@property (nonatomic, copy, nullable) VCamAudioHandler audioHandler;

/// 状态描述，给悬浮窗显示，例如「视频 · 1080x1920 · 30fps」
@property (nonatomic, readonly, copy) NSString *statusText;
/// 是否已经准备好出帧（OBS 模式在收到第一个关键帧前为 NO）
@property (nonatomic, readonly) BOOL isReady;
/// 最近一次错误
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

- (BOOL)start;
- (void)stop;
- (void)invalidate;   ///< stop + 释放所有资源

@end

#pragma mark - 基类（抽出公共属性 + 节流逻辑）

@interface VCamFrameSourceBase : NSObject <VCamFrameSource>

@property (nonatomic, assign) CGSize targetSize;
@property (nonatomic, assign) NSInteger targetFPS;
@property (nonatomic, assign) VCamRotation rotation;
@property (nonatomic, assign) BOOL mirror;
@property (nonatomic, assign) NSInteger lipSyncOffsetMs;
@property (nonatomic, copy, nullable) VCamFrameHandler frameHandler;
@property (nonatomic, copy, nullable) VCamAudioHandler audioHandler;
@property (nonatomic, copy, nullable) NSString *lastError;

/// 节流用的串行队列（图像处理放这里，不要占主队列）
@property (nonatomic, readonly) dispatch_queue_t workQueue;

/// 处理管线：源像素 → 缩放 → 旋转/镜像 → 回调。
/// 子类拿到原始像素后统一调它，保证输出格式/尺寸一致。
- (void)emitPixelBuffer:(CVPixelBufferRef)pixelBuffer atStreamTime:(CMTime)streamTime;

/// 是否已经超过 1/targetFPS 的间隔（用于 OBS 与视频节流）
- (BOOL)shouldEmitNow;

/// 重置节流计时
- (void)resetThrottle;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_FRAME_SOURCE_H */
