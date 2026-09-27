//
//  VCamFrameInjector.h
//  虚拟摄像头
//
//  在 App 层替换相机画面。
//
//  ---------------------------------------------------------------------------
//  为什么不用开源项目那种 %hook NSObject 的写法
//  ---------------------------------------------------------------------------
//  lxxsoufahk/VCam 是这样做的：
//
//      %hook NSObject
//      - (void)captureOutput:(AVCaptureOutput *)output
//          didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
//                 fromConnection:(AVCaptureConnection *)connection {
//          ...
//      }
//      %end
//
//  这个写法有两个问题：
//
//    1) %hook NSObject 只会把方法**加到 NSObject 这个类**上。
//       真正实现 captureOutput:... 的是各个 delegate 子类，
//       它们在消息转发链上优先命中自己的实现，
//       NSObject 上新增的那份不会被调用。
//       → 结果就是"看起来 hook 了，实际不生效"。
//       （这也是那个开源项目相机替换从未真正生效的原因之一。）
//
//    2) 即使侥幸被调用，它也无法把 fake frame 交给真正的 delegate ——
//       %orig 调用的是 NSObject 上的空实现，不是原 delegate 的实现。
//
//  ---------------------------------------------------------------------------
//  本工程的做法：代理（proxy）模式
//  ---------------------------------------------------------------------------
//  相机出帧的调用链是：
//
//      AVCaptureVideoDataOutput --调用--> delegate 的
//          captureOutput:didOutputSampleBuffer:fromConnection:
//
//  所以只要把 delegate 换成一个我们自己的对象，就能在这条链上做替换：
//
//      1) hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
//         保存真实 delegate，改设为我们自己的 proxy
//      2) proxy 实现 captureOutput:...
//         启用虚拟相机时：把 sampleBuffer 换成虚拟帧再转发
//         未启用时：原样转发
//      3) 这样无论真实 delegate 是什么类、用什么方式实现，都能覆盖
//
//  这样做的代价是多一层对象转发，但换来了"确实能生效"。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamFrameInjector : NSObject

/// 安装 swizzle（幂等，可重复调用）
+ (void)install;

/// 全局开关：是否用虚拟帧替换真实相机帧
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;

/// 诊断计数：实际替换了多少帧
+ (uint64_t)replacedFrameCount;

@end

NS_ASSUME_NONNULL_END
