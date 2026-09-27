//
//  VCamOBSAudioDecoder.h
//  VCam
//
//  AAC → 交错 float32 PCM（用 AudioToolbox 的 AudioConverter，硬件/系统实现）。
//
//  为什么不用 FFmpeg 的 AAC 解码器：
//   iOS 自带的 AudioConverter 在 AAC-LC 上是系统优化路径，功耗更低，
//   而且 AudioSpecificConfig → AudioStreamBasicDescription 的转换逻辑
//   我们已经要为麦克风注入写一份，复用同一套。
//

#ifndef VCAM_OBS_AUDIO_DECODER_H
#define VCAM_OBS_AUDIO_DECODER_H

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// 解出的 PCM 回调（交错 float32）
typedef void (^VCamPCMHandler)(const float *interleaved,
                               size_t frames,
                               UInt32 channels,
                               Float64 sampleRate,
                               CMTime presentationTime);

@interface VCamOBSAudioDecoder : NSObject

/// 输出采样率（默认 48000）
@property (nonatomic, assign) Float64 outputSampleRate;
/// 输出声道数（默认 2）
@property (nonatomic, assign) UInt32 outputChannels;
/// 音量增益（0.0 - 2.0）
@property (nonatomic, assign) float gain;

@property (nonatomic, copy, nullable) VCamPCMHandler pcmHandler;

/// 送入一个 AAC 原始帧。extradata 为 AudioSpecificConfig（TS 里通常带在
/// 流的 codecpar->extradata 上），第一次调用时必须能拿到。
- (void)feedAACFrame:(NSData *)frame
           extradata:(nullable NSData *)extradata
          sampleRate:(int)sampleRate
            channels:(int)channels
               ptsMs:(int64_t)ptsMs;

- (void)reset;
@property (nonatomic, readonly) uint64_t decodedFrames;
@property (nonatomic, readonly) uint64_t droppedFrames;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_OBS_AUDIO_DECODER_H */
