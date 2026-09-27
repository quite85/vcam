//
//  VCamHUD.h
//  VCam
//
//  轻量吐司提示。不用 UIAlertController：它会抢 keyWindow，
//  在相机 App 里弹出会导致相机预览暂停、甚至触发 App 的
//  "检测到弹窗"逻辑（某些直播 App 会中断推流）。
//

#ifndef VCAM_HUD_H
#define VCAM_HUD_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamHUD : NSObject

/// 显示一条提示，1.8 秒后自动消失
+ (void)show:(NSString *)text success:(BOOL)success;

/// 常驻提示（需要自己调 dismiss），用于"等待 OBS"这类持续状态
+ (void)showPersistent:(NSString *)text;
+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_HUD_H */
