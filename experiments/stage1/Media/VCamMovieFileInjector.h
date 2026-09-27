//
//  VCamMovieFileInjector.h
//  VCam
//
//  录像注入：让录像文件里也是虚拟画面 + 同步音频。
//
//  为什么不能让原始录制器直接录虚拟帧：
//   AVCaptureMovieFileOutput 的画面来自 mediaserverd 侧的采集，
//   在 App 进程里没有"写入一帧"的公开接口（AVAssetWriterInput 对应的是
//   AVCaptureVideoDataOutput 的流，而不是 MovieFileOutput）。
//
//  因此采用"影子录制 + 替换"策略：
//    1) App 调 -startRecordingToOutputFileURL:recordingDelegate: 时，
//       我们同时启动一个 AVAssetWriter 写到一个隐藏的临时文件，
//       每帧从 VCamCore 拉虚拟帧，音频从虚拟麦拉 PCM；
//    2) 原录制流程照常进行（保证 App 的 UI 计时、回调时序完全正常）；
//    3) App 的 delegate 收到 -captureOutput:didFinishRecordingToOutputFileAtURL:
//       时，我们把临时文件替换成正式文件，然后再转发给 App 的 delegate。
//
//  这样做的代价：录制期间会多一次 H.264 编码（虚拟视频），
//  iPhone A 系列芯片的硬件编码器可以同时跑 2 路 1080p，实测无压力。
//  如果在意功耗，可以在 mediaserverd 层注入成功时关闭影子录制
//  （检测到 --vcam-msd-ok 标记时自动关闭，见 README）。
//

#ifndef VCAM_MOVIE_FILE_INJECTOR_H
#define VCAM_MOVIE_FILE_INJECTOR_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamMovieFileInjector : NSObject

/// 在 App 进程内安装
+ (void)install;

/// 给 App 的录制 delegate 挂上"文件替换"拦截（内部使用，也可被其它模块调用）
+ (void)vcam_instrumentRecordingDelegate:(id)delegate;

/// 把影子录制的文件替换到 App 期望的路径（内部使用）
+ (void)vcam_swapInVirtualMovieForURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_MOVIE_FILE_INJECTOR_H */
