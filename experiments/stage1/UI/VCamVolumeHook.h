//
//  VCamVolumeHook.h
//  VCam
//
//  「音量减」键拦截。
//
//  为什么不用长按 Home：iPhone X 之后没有 Home 键；而且长按 Home 会触发
//  系统的 AssistiveTouch / Siri 行为，在相机 App 里还会被拦截。音量键是
//  唯一在所有 App（包括相机、FaceTime、全屏游戏）里都能稳定拿到的硬件事件。
//
//  实现方案（双通道，互为兜底）：
//   通道 A：AVAudioSession 的 OutputVolume 监听。
//           调一次 setActive:YES（不改类别！）即可让系统开始上报音量变化。
//           优点：公开 API，稳定，iOS 15/16 行为一致。
//           缺点：系统音量到 0 或到 1 之后继续按不再产生变化事件。
//   通道 B：私有符号 _AVSystemController_SystemVolumeDidChangeNotification
//           （AVSystemController 框架）。这个通知即使音量到顶/到底也会发，
//           并且带 reason 字段区分"按键"和"程序设置"。
//
//  音量策略（按需求单）：
//   - 短按（< 0.35s 松开）→ 弹窗，并且把音量"还原"（不误调音量）
//   - 长按（>= 0.35s）    → 交给系统调音量
//   - 通话中 / 正在录音的语音备忘录场景 → 完全不拦截
//

#ifndef VCAM_VOLUME_HOOK_H
#define VCAM_VOLUME_HOOK_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamVolumeHook : NSObject

/// 在 SpringBoard 进程内安装（%ctor 里调用）
+ (void)install;

/// 临时挂起（例如弹出相册选择器时，避免音量键又触发面板）
+ (void)suspend;
+ (void)resume;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_VOLUME_HOOK_H */
