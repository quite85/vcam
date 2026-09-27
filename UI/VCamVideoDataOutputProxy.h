//
//  VCamVideoDataOutputProxy.h
//  VCam
//
//  包装 App 自己的 AVCaptureVideoDataOutputSampleBufferDelegate，
//  在回调发生前把 sampleBuffer 换成虚拟帧。
//
//  为什么包一层 delegate 而不是直接 hook AVCaptureVideoDataOutput 的
//  -captureOutput:didOutputSampleBuffer:fromConnection: ？
//  因为那个方法定义在 App 自己的 delegate 类上，我们无法在 tweak 里
//  预先知道类名。做法是：在 App 调用 setSampleBufferDelegate:queue: 时，
//  用我们自己的代理对象替换 delegate，内部再转发给原 delegate。
//
//  这样做的额外好处：
//   - 完全不影响 App 的代码逻辑（它拿到的还是"合法的 sampleBuffer"）；
//   - 时间戳/GOP 都是我们控制的，录制时间轴正确；
//   - 禁用替换时随时可以卸载代理。
//

#ifndef VCAM_VIDEO_DATA_OUTPUT_PROXY_H
#define VCAM_VIDEO_DATA_OUTPUT_PROXY_H

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VCamVideoDataOutputProxy;

@interface AVCaptureVideoDataOutput (VCamProxy)
/// 关联一个代理对象（同时充当"是否已安装"的标记）
- (void)setAssociatedProxy:(nullable VCamVideoDataOutputProxy *)proxy;
- (nullable VCamVideoDataOutputProxy *)associatedProxy;
@end

@interface VCamVideoDataOutputProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

/// 为某个 output 安装代理（幂等）
+ (void)installForOutput:(AVCaptureVideoDataOutput *)output
                delegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                   queue:(dispatch_queue_t)queue;

/// 卸载所有代理（禁用替换时）
+ (void)uninstallAll;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_VIDEO_DATA_OUTPUT_PROXY_H */
