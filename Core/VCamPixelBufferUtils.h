//
//  VCamPixelBufferUtils.h
//  VCam
//
//  像素缓冲工具：统一输出 NV12(420f/420v) 格式。
//
//  为什么坚持 NV12：
//   - 摄像头硬件（ISP）原生输出就是 NV12/420f，mediaserverd 与
//     AVCaptureVideoDataOutput 的下游（VideoToolbox 编码器、预览层、
//     CoreImage）在这个格式上路径最短，转 RGBA 会掉帧。
//   - VideoToolbox H.264 硬解默认输出也是 420v/420f，可以直接对接。
//

#ifndef VCAM_PIXELBUFFER_UTILS_H
#define VCAM_PIXELBUFFER_UTILS_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCamRotation) {
    VCamRotation0   = 0,
    VCamRotation90  = 90,
    VCamRotation180 = 180,
    VCamRotation270 = 270,
};

@interface VCamPixelBufferUtils : NSObject

/// 全局共享的 CVPixelBufferPool 池（按尺寸+格式缓存），避免频繁分配
+ (CVPixelBufferRef _Nullable)createPixelBufferWithWidth:(size_t)width
                                                  height:(size_t)height
                                                  format:(OSType)format
                                              fromPoolKey:(NSString *)key CF_RETURNS_RETAINED;

/// 把 CGImage / UIImage 画进一个 NV12 buffer（内部走 CoreImage + 颜色空间转换）
+ (CVPixelBufferRef _Nullable)pixelBufferFromImage:(UIImage *)image
                                             width:(size_t)width
                                            height:(size_t)height CF_RETURNS_RETAINED;

/// 从 CVPixelBuffer 生成 UIImage（用于"选完立刻确认"的缩略图）
+ (UIImage * _Nullable)imageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// 旋转 + 镜像（90/270 会交换宽高）。输入输出都是 NV12。
+ (CVPixelBufferRef _Nullable)transformPixelBuffer:(CVPixelBufferRef)src
                                          rotation:(VCamRotation)rotation
                                            mirror:(BOOL)mirror CF_RETURNS_RETAINED;

/// 等比 aspect-fill 缩放到目标尺寸（NV12 输出）
+ (CVPixelBufferRef _Nullable)scalePixelBuffer:(CVPixelBufferRef)src
                                    toWidth:(size_t)width
                                     height:(size_t)height CF_RETURNS_RETAINED;

/// 生成一个纯色/棋盘格占位帧（断流时显示"等待 OBS"用）
+ (CVPixelBufferRef _Nullable)placeholderPixelBufferWithWidth:(size_t)width
                                                       height:(size_t)height
                                                        text:(nullable NSString *)text CF_RETURNS_RETAINED;

/// 用 CVPixelBuffer 组装 CMSampleBuffer（时间戳用 CMClock 的 host 时间）
+ (CMSampleBufferRef _Nullable)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                 timebase:(CMTimebaseRef _Nullable)timebase
                                                    atTime:(CMTime)time CF_RETURNS_RETAINED;

/// 当前 host 时钟时间（与 AVCaptureVideoDataOutput 给的 PTS 同源）
+ (CMTime)hostTime;
/// 把"流内相对时间"平移到 host 时间轴上（OBS 流与相册视频都用它对齐）
+ (CMTime)hostTimeForStreamTime:(CMTime)streamTime anchor:(CMTime)anchor;

/// 音频辅助：把 float32 交错 PCM 转成 CMSampleBuffer
+ (CMSampleBufferRef _Nullable)sampleBufferFromFloat32PCM:(const float *)interleaved
                                                   frames:(size_t)frames
                                                 channels:(UInt32)channels
                                               sampleRate:(Float64)sampleRate
                                                 hostTime:(CMTime)hostTime CF_RETURNS_RETAINED;

/// 通用：从任意 audio buffer list 生成 CMSampleBuffer（给麦克风注入用）
+ (CMSampleBufferRef _Nullable)sampleBufferFromAudioBufferList:(AudioBufferList *)abl
                                                       frames:(size_t)frames
                                                  formatFlags:(AudioFormatFlags)flags
                                                     bytesPerPacket:(UInt32)bytesPerPacket
                                                    framesPerPacket:(UInt32)framesPerPacket
                                                     channels:(UInt32)channels
                                                   sampleRate:(Float64)sampleRate
                                                     hostTime:(CMTime)hostTime CF_RETURNS_RETAINED;

/// 清空内部的 buffer pool 缓存（禁用替换时调用，释放内存）
+ (void)flushPools;

@end

NS_ASSUME_NONNULL_END
