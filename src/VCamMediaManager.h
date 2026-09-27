//
//  VCamMediaManager.h
//  虚拟摄像头
//
//  视频帧源管理：从相册视频解码出 CMSampleBuffer，循环播放，
//  并把时间戳重映射到"当前墙上时间"，让 AVCapture 的消费者看到连续的 PTS。
//
//  这个文件的结构参考了开源项目 lxxsoufahk/VCam 的 MediaManager，
//  但修掉了它的几个问题（详见 .m 里的注释）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamMediaManager : NSObject

/// 是否已加载媒体并且正在推流
@property (nonatomic, assign, readonly) BOOL isRunning;
/// 当前视频的像素尺寸（用于生成黑帧时保持同样尺寸）
@property (nonatomic, assign, readonly) CGSize videoSize;
/// 已产出多少帧（诊断用）
@property (nonatomic, assign, readonly) uint64_t frameCount;

+ (instancetype)shared;

/// 载入一个视频文件（相册导出的 URL 或沙盒内路径），成功后会重置解码器
- (BOOL)loadMediaFromURL:(NSURL *)url error:(NSError **)error;

/// 取下一帧视频。返回的 CMSampleBufferRef 由调用方负责 Release。
/// 未就绪或出错时返回 NULL（调用方应直接透传原始帧 / 或跳过替换）。
- (nullable CMSampleBufferRef)nextVideoFrame CF_RETURNS_RETAINED;

/// 生成一帧纯黑画面（尺寸与当前视频一致）。调用方负责 Release。
- (nullable CMSampleBufferRef)blackFrame CF_RETURNS_RETAINED;

/// 开启 / 停止推流
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
