//
//  VCamPanel.h
//  VCam
//
//  音量减弹出的悬浮小窗。要求：
//   - 可拖动、可贴边，不阻断当前 App（用独立 UIWindow，windowLevel 很高）
//   - 相机 App 内也能弹（音量减 hook 只在系统级注册一次）
//   - 显示当前状态：图片 / 视频 / OBS / 已禁用
//   - 提供选择视频、选择图片、OBS 推流、禁用替换
//   - 额外：旋转 90°、镜像、循环开关、端口设置、推流地址复制
//

#ifndef VCAM_PANEL_H
#define VCAM_PANEL_H

#import <UIKit/UIKit.h>
#import "VCamConfig.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamPanel : NSObject

+ (instancetype)shared;

/// SpringBoard 启动时预热（提前建 window，避免第一次弹窗卡顿）
- (void)prepare;

/// 显示 / 隐藏（再次按音量减就切换）
- (void)toggle;
- (void)show;
- (void)hide;
@property (nonatomic, readonly) BOOL isVisible;

/// 外部（状态变化）触发文案刷新
- (void)refreshStatus;

@end
NS_ASSUME_NONNULL_END

#endif /* VCAM_PANEL_H */
