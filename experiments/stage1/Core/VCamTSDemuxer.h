//
//  VCamTSDemuxer.h
//  VCam
//
//  MPEG-TS 接收 + 解复用（OBS 推流用）。
//
//  依赖：FFmpeg 的 libavformat / libavcodec / libavutil。
//  只需要 demux，不需要编码器，所以可以让用户用 --disable-everything
//  只开 mpegts demuxer + h264/aac parser，库体积能压到几百 KB。
//  构建方法见 scripts/ffmpeg-deps.sh。
//
//  线程模型：
//   - 一个专用线程跑 av_read_frame 循环（阻塞在 UDP socket 上）；
//   - 视频 AVPacket 直接回调给 VideoToolbox 解码器；
//   - 音频 AVPacket 回调给音频解码/注入层；
//   - stop 时通过 interrupt_callback 让 av_read_frame 立刻返回。
//

#ifndef VCAM_TS_DEMUXER_H
#define VCAM_TS_DEMUXER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 视频包（H.264 Annex-B 或 AVCC，取决于流；用 AVCC 时带 extradata）
typedef void (^VCamTSVideoPacketHandler)(NSData *packetData,
                                         NSData * _Nullable extradata,
                                         BOOL isKeyframe,
                                         int64_t ptsMs);

/// 音频包（AAC 原始帧，未解码）
typedef void (^VCamTSAudioPacketHandler)(NSData *packetData,
                                         NSData * _Nullable extradata,
                                         int sampleRate,
                                         int channels,
                                         int64_t ptsMs);

@interface VCamTSDemuxer : NSObject

- (instancetype)initWithURLString:(NSString *)urlString
                        transport:(NSString *)transport;   // @"udp" / @"tcp"

@property (nonatomic, copy, nullable) VCamTSVideoPacketHandler videoHandler;
@property (nonatomic, copy, nullable) VCamTSAudioPacketHandler audioHandler;

/// 统计信息，给悬浮窗显示
@property (nonatomic, readonly) uint64_t videoPacketCount;
@property (nonatomic, readonly) uint64_t audioPacketCount;
@property (nonatomic, readonly) uint64_t errorCount;
@property (nonatomic, readonly) double   bitrateKbps;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;
/// 是否已经收到过关键帧（UI 上"等待 OBS"的判断依据之一）
@property (nonatomic, readonly) BOOL gotKeyframe;

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_TS_DEMUXER_H */
