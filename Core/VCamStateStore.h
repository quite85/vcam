//
//  VCamStateStore.h
//  VCam
//
//  跨进程共享配置（线程安全 + 变更广播）。
//
//  为什么不用 CFPreferences：
//   mediaserverd 是 root 且带着自己的沙盒，读 mobile 用户的
//   ~/Library/Preferences 并不总是成功（尤其 Dopamine rootless）。
//   用 /var/mobile/Library/VCam/state.plist（0644）最稳，
//   再配合 Darwin notify 做变更广播。
//

#ifndef VCAM_STATE_STORE_H
#define VCAM_STATE_STORE_H

#import "VCamConfig.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamStateStore : NSObject

/// 进程内单例
+ (instancetype)shared;

#pragma mark - 读

@property (nonatomic, readonly) VCamMode mode;
@property (nonatomic, readonly, copy) NSString *assetPath;
@property (nonatomic, readonly) BOOL assetIsVideo;
@property (nonatomic, readonly) NSInteger rotation;      ///< 0 / 90 / 180 / 270
@property (nonatomic, readonly) BOOL mirror;
@property (nonatomic, readonly) BOOL mirrorBack;
@property (nonatomic, readonly) BOOL loop;
@property (nonatomic, readonly) uint16_t port;           ///< OBS 监听端口
@property (nonatomic, readonly, copy) NSString *transport; ///< @"udp" / @"tcp"
@property (nonatomic, readonly) NSInteger latencyMs;
@property (nonatomic, readonly) VCamAudioSourceKind audioKind;
@property (nonatomic, readonly) float audioVolume;
@property (nonatomic, readonly) NSInteger lipSyncMs;
@property (nonatomic, readonly) BOOL msdDisabled;
@property (nonatomic, readonly) BOOL appLayerOnly;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

/// 原始字典副本（只读）
@property (nonatomic, readonly, copy) NSDictionary *raw;

#pragma mark - 写

- (void)setMode:(VCamMode)mode;
- (void)setAssetPath:(nullable NSString *)path isVideo:(BOOL)isVideo;
- (void)setRotation:(NSInteger)rotation;
- (void)setMirror:(BOOL)mirror;
- (void)setMirrorBack:(BOOL)mirrorBack;
- (void)setLoop:(BOOL)loop;
- (void)setPort:(uint16_t)port;
- (void)setTransport:(NSString *)transport;
- (void)setLatencyMs:(NSInteger)ms;
- (void)setAudioKind:(VCamAudioSourceKind)kind;
- (void)setAudioVolume:(float)volume;
- (void)setLipSyncMs:(NSInteger)ms;
- (void)setMSDDisabled:(BOOL)disabled;
- (void)setAppLayerOnly:(BOOL)only;
- (void)recordError:(nullable NSString *)error;

/// 批量写入（减少 notify 次数）
- (void)update:(void (^)(NSMutableDictionary *dict))block;

#pragma mark - 重建 / 监听

/// 强制从磁盘重读，并触发所有已注册的监听
- (void)reload;
/// 注册状态变化监听（内部自动去重 notify 注册），block 在任意线程回调
- (void)observeChanges:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_STATE_STORE_H */
