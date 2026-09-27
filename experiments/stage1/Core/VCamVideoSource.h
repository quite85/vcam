//
//  VCamVideoSource.h
//  VCam
//
//  相册视频源。
//
//  两条独立的管线：
//   视频：AVPlayer + AVPlayerItemVideoOutput（依赖系统播放器的硬件解码，
//         比 AVAssetReader 省电得多，而且天然支持 seek 循环）
//   音频：AVAssetReader + AVAssetReaderTrackOutput（直接解成 16bit/32bit PCM，
//         交给麦克风注入层。AAC→PCM 转换在 readNextSampleBuffer 里完成）
//
//  为什么视频不用 AVAssetReader：
//   1) AVAssetReader 是一次性的，循环播放必须重建 reader，会有肉眼可见的卡顿；
//   2) AVAssetReader 的视频解码在 CPU/VideoToolbox 之间来回拷，功耗高；
//   3) 内存：AVAssetReader 顺序读不会把整个文件读进内存，但循环重建时
//      每次都要重新解析 moov，1080p 60fps 视频会明显掉帧。
//   AVPlayer 天然循环 + 硬件解码，代价是需要一个 runloop 来驱动
//   （在 mediaserverd 里我们用 dispatch timer 手动 copyPixelBufferForItemTime，
//    不依赖 runloop，避免 daemon 主 runloop 被相机管线占用的问题）。
//

#ifndef VCAM_VIDEO_SOURCE_H
#define VCAM_VIDEO_SOURCE_H

#import "VCamFrameSource.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamVideoSource : VCamFrameSourceBase

/// 本地视频文件（相册导出后放在 VCamAssetCacheDirectory 里）
- (instancetype)initWithVideoPath:(NSString *)path;

/// 是否循环播放（默认 YES）
@property (nonatomic, assign) BOOL loop;
/// 音量（0.0 - 2.0），影响送往虚拟麦的 PCM（注意不是播放音量）
@property (nonatomic, assign) float audioGain;
/// 当前播放位置（秒），给 UI 显示
@property (nonatomic, readonly) double currentSeconds;
@property (nonatomic, readonly) double durationSeconds;
/// 视频自带音轨是否存在
@property (nonatomic, readonly) BOOL hasAudioTrack;

/// 重新开始播放（切换循环/旋转后调用）
- (void)restartPlayback;

@end

NS_ASSUME_NONNULL_END
#endif /* VCAM_VIDEO_SOURCE_H */
