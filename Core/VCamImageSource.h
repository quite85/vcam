//
//  VCamImageSource.h
//  VCam
//
//  静态图片源：把一张图转成 NV12 后按 targetFPS（默认 30）重复送帧。
//
//  为什么要"重复送帧"而不是只送一帧：
//   AVCaptureVideoDataOutput 的下游（预览层、VideoToolbox 编码器、录制器）
//   是按帧驱动的。如果只送一帧，预览会停留在第一帧但录制器会因为长时间
//   收不到帧而 flush/超时，录出来的文件时间轴会错乱。
//

#ifndef VCAM_IMAGE_SOURCE_H
#define VCAM_IMAGE_SOURCE_H

#import "VCamFrameSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamImageSource : VCamFrameSourceBase

/// 直接给图片对象
- (instancetype)initWithImage:(UIImage *)image;
/// 给本地文件路径（相册导出后的文件）
- (instancetype)initWithImagePath:(NSString *)path;

@property (nonatomic, strong, nullable) UIImage *image;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_IMAGE_SOURCE_H */
