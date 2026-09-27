//
//  VCamPhotoOutputInjector.h
//  VCam
//
//  拍照注入：让"拍下来的照片"也是虚拟画面。
//
//  为什么单独做这件事：
//   mediaserverd 层的注入如果成功，AVCapturePhotoOutput 拿到的本来
//   就是虚拟帧，这一层就是冗余的；但 mediaserverd 的私有符号在
//   某些 iOS 16.4+ 版本上会变，App 层必须有独立兜底，
//   否则会出现"预览是虚拟的，拍下来是真的"这种最糟糕的结果。
//
//  实现方式：
//   App 调用 -capturePhotoWithSettings:delegate: 时，我们不去干扰真实
//   拍照流程（保持 App 的 delegate 时序完全正常），而是：
//     1) 立刻用虚拟帧现场编码一张 JPEG；
//     2) 在 delegate 的 -photoOutput:didFinishProcessingPhoto:error:
//        被调用前，把 AVCapturePhoto 对象换成一个"从我们 JPEG 构造的"
//        等价对象；
//     3) 用安全的方式尝试构造，失败就退回真实照片（绝不崩）。
//
//  AVCapturePhoto 的构造是私有的，按 a) initWithSampleBuffer:
//  b) initWithSettings:previewPhoto:resolvedSettings:... c) 退回真实照片
//  的顺序尝试，任何一步失败都不影响 App 的拍照流程。
//

#ifndef VCAM_PHOTO_OUTPUT_INJECTOR_H
#define VCAM_PHOTO_OUTPUT_INJECTOR_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamPhotoOutputInjector : NSObject

/// 在 App 进程内安装（%ctor 调用）
+ (void)install;

/// 给某个 AVCapturePhotoCaptureDelegate 实现类挂上"换照片"拦截（内部使用）
+ (void)vcam_instrumentDelegate:(id)delegate;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_PHOTO_OUTPUT_INJECTOR_H */
