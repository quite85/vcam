//
//  VCamVideoToolboxDecoder.h
//  VCam
//
//  H.264 硬解码：OBS 推来的 TS 里的视频轨 → CVPixelBuffer(NV12)。
//
//  设计要点：
//   - 用 VTDecompressionSession（走硬件解码器），不软解，1080p30 功耗可接受；
//   - 输出 420f(full range) NV12，与摄像头原生格式一致；
//   - 强制走 AVCC(长度前缀) 模式的 CMSampleBuffer：VT 也能吃 Annex-B，
//     但长度前缀在创建 sampleBuffer 时不需要再扫一遍起始码，延迟更低；
//   - 只在收到 IDR 后才真正建立解码会话（之前丢包，避免花屏）；
//   - 解出的帧进 VCamConcurrentQueue，由帧源按 targetFPS 拉取。
//

#ifndef VCAM_VIDEOTOOLBOX_DECODER_H
#define VCAM_VIDEOTOOLBOX_DECODER_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "VCamConcurrentQueue.h"

NS_ASSUME_NONNULL_BEGIN

@class VCamVideoToolboxDecoder;

@protocol VCamVideoToolboxDecoderDelegate <NSObject>
@optional
- (void)videoDecoder:(VCamVideoToolboxDecoder *)decoder
   didDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
      presentationTime:(CMTime)pts;
- (void)videoDecoder:(VCamVideoToolboxDecoder *)decoder
         didFailWith:(NSString *)reason;
@end

@interface VCamVideoToolboxDecoder : NSObject

- (instancetype)initWithDelegate:(nullable id<VCamVideoToolboxDecoderDelegate>)delegate;

/// 期望输出尺寸（0 表示跟随流的分辨率）。OBS 推 1080x1920 时这里填 1080x1920。
@property (nonatomic, assign) CGSize expectedSize;
/// 解码后的帧进这个队列（可空，则走 delegate）
@property (nonatomic, strong, nullable) VCamConcurrentQueue *outputQueue;
/// 关键帧丢失时是否自动等待下一个 IDR（默认 YES）
@property (nonatomic, assign) BOOL waitForKeyframe;
/// 当前流的宽高（解析出来后更新）
@property (nonatomic, readonly) CGSize streamSize;

- (BOOL)start;
- (void)stop;

/// 送入一个 H.264 访问单元。extradata 为 AVCDecoderConfigurationRecord 或 nil。
/// data 允许是 Annex-B（带 00 00 00 01）或长度前缀格式，内部会自动判断。
- (void)feedAccessUnit:(NSData *)data
             extradata:(nullable NSData *)extradata
            isKeyframe:(BOOL)isKeyframe
                 ptsMs:(int64_t)ptsMs;

/// 统计
@property (nonatomic, readonly) uint64_t decodedFrames;
@property (nonatomic, readonly) uint64_t droppedFrames;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_VIDEOTOOLBOX_DECODER_H */
