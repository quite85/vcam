//
//  VCamPreviewOverlay.h
//  VCam
//
//  预览层注入。
//
//  为什么不能直接替换 AVCaptureVideoPreviewLayer 内部的画面：
//   previewLayer 内部是一个私有的 CALayer（AVCaptureVideoPreviewLayer 的
//   internal layer），它的 contents 由 mediaserverd 通过 IOSurface 直接喂给
//   CoreAnimation，不经过任何我们能在 App 进程 hook 的 Objective-C 方法。
//
//  所以在 App 层我们采用"覆盖"策略：
//   在 previewLayer 上叠加一个自己的 CALayer，把虚拟帧的 CGImage 设成 contents。
//   由于层级在上方，用户看到的是虚拟画面。
//
//  这个策略的取舍：
//   + 简单、稳定、不会因为内部结构变化而在 iOS 15/16 之间失效；
//   + 禁用时移除覆盖层即可，100% 恢复原状；
//   + 拍照/录像走的是另外两条 hook（PhotoOutput / MovieFileOutput），
//     所以"预览是虚拟的，但拍下来是真的"这种不一致不会发生。
//   - 额外一次 CVPixelBuffer → CGImage 的转换（有 GPU 加速，1080p 约 2-4ms）；
//   - 如果 App 自己在预览层上面又叠了 UI，我们的层可能被遮住（罕见）。
//
//  注意：如果 mediaserverd 层的注入生效了，这个覆盖层其实是多余的
//  （此时 previewLayer 拿到的本来就是虚拟帧）。我们会在检测到
//  mediaserverd 层可用时自动禁用覆盖层，避免双重转换浪费性能。
//

#ifndef VCAM_PREVIEW_OVERLAY_H
#define VCAM_PREVIEW_OVERLAY_H

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamPreviewOverlay : NSObject

/// 为 previewLayer 挂载覆盖层（幂等）
+ (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;

/// 布局变化时同步覆盖层大小（在 -layoutSublayers 里调用）
+ (void)layoutOverlayForPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;

/// 移除所有覆盖层（禁用替换时）
+ (void)detachAll;

/// mediaserverd 层已工作时，覆盖层自动让位
+ (void)setPassthroughMode:(BOOL)passthrough;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_PREVIEW_OVERLAY_H */
