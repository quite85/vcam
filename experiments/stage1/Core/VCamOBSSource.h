//
//  VCamOBSSource.h
//  VCam
//
//  OBS / 电脑推流源。
//  数据流：
//    OBS --MPEG-TS over UDP/TCP--> VCamTSDemuxer
//        ├─ H.264 包 --> VCamVideoToolboxDecoder --> VCamConcurrentQueue
//        │                                              │ (按 targetFPS 取最新帧)
//        │                                              └--> emitPixelBuffer --> 相机注入层
//        └─ AAC 包  --> VCamOBSAudioDecoder --> PCM --> audioHandler --> 麦克风注入层
//
//  时间戳策略：
//   - 视频帧的时间戳用"解码器算出的 host 时间"，保证单调递增；
//   - 音频 PCM 的时间戳来自流 PTS 映射，配合 lipSyncOffsetMs 做唇形同步；
//   - 断流超过 stallTimeout 秒后，改为送"最后一帧"或占位帧，避免预览黑屏。
//

#ifndef VCAM_OBS_SOURCE_H
#define VCAM_OBS_SOURCE_H

#import "VCamFrameSource.h"
#import "VCamConcurrentQueue.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamOBSSource : VCamFrameSourceBase

/// 例如 @"udp://0.0.0.0:5600" 或 @"tcp://0.0.0.0:5600"
@property (nonatomic, copy, nullable) NSString *urlString;
/// @"udp" / @"tcp"
@property (nonatomic, copy) NSString *transport;

/// 断流判定（秒），超过这个时间没收到帧就显示占位/最后一帧
@property (nonatomic, assign) NSTimeInterval stallTimeout;
/// 断流时是否保留最后一帧（NO = 显示"等待 OBS"占位图）
@property (nonatomic, assign) BOOL holdLastFrame;

/// 统计信息（给悬浮窗显示）
@property (nonatomic, readonly) double bitrateKbps;
@property (nonatomic, readonly) uint64_t decodedFrames;
@property (nonatomic, readonly) uint64_t droppedFrames;
/// 是否正在接收（有包进来）
@property (nonatomic, readonly) BOOL receiving;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_OBS_SOURCE_H */
