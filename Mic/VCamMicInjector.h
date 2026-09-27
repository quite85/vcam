//
//  VCamMicInjector.h
//  VCam
//
//  麦克风替换。要覆盖三条路径：
//
//   1) 系统级（mediaserverd 内）
//      iOS 的麦克风采集最终都汇到 AURemoteIO（AudioUnit 的 Remote IO）。
//      mediaserverd 里每一路客户端音频都通过 AudioUnit 的
//      "input render callback" 回调给上层。我们用 AudioUnitSetProperty
//      把这些回调换成自己的：从 VCamCore 拉 PCM 填进 buffer。
//      因为此时 mediaserverd 已经把 A/D 采样的数据准备好要往回调里送，
//      我们直接把 ioData 覆盖成虚拟 PCM 即可，听上去完全无缝。
//
//   2) App 层：AVCaptureAudioDataOutput
//      同视频的做法：包一层 delegate，替换 CMSampleBuffer 里的 PCM。
//
//   3) App 层：AVAudioRecorder / AVAudioEngine 输入节点
//      语音备忘录、部分 App 的录音走这里，直接 hook
//      -AVAudioRecorder updateMeters / -AVAudioEngine inputNode 的
//      render block 都比较脆弱，我们采用"hook AVAudioRecorder 的
//      recording 状态 + 在 AVAudioEngine 的 inputNode 上安装 tap"的方式：
//      如果 App 用了 tap，我们就把 tap 里的 buffer 替换掉。
//
//  唇形同步：
//   视频侧帧的时间戳与音频侧的时间戳都来自同一个 CMClock（mach host time），
//   并且 OBS / 视频源都做了 PTS → host time 的映射，
//   所以只要两边都用 CMClockGetHostTimeClock()，唇形天然同步。
//   额外的 lipSyncMs 偏移用于补偿蓝牙耳机等场景。
//

#ifndef VCAM_MIC_INJECTOR_H
#define VCAM_MIC_INJECTOR_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamMicInjector : NSObject

+ (instancetype)shared;

/// App 进程：安装 AVAudioRecorder / AVCaptureAudioDataOutput 等
- (void)install;

/// mediaserverd 进程：安装 AURemoteIO / AudioUnit 级的替换
- (void)installForMediaServer;

/// 卸载（禁用替换时调用）
- (void)uninstall;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_MIC_INJECTOR_H */
