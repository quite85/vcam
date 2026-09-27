//
//  VCamConcurrentQueue.h
//  VCam
//
//  一个极简的"无锁拷贝"FIFO，专门用来在采集线程和解码/网络线程之间搬运帧。
//
//  为什么不直接用 NSMutableArray：
//   mediaserverd 的采集回调运行在实时线程上，那里不能阻塞、不能进 objc 消息发送的
//   slow path。这里用 C 数组 + os_unfair_lock 做短临界区，容量固定，
//   满了就丢最旧的一帧（丢帧比卡顿好，相机管线最怕延迟累积）。
//

#ifndef VCAM_CONCURRENT_QUEUE_H
#define VCAM_CONCURRENT_QUEUE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamConcurrentQueue : NSObject

/// capacity = 最大缓存帧数（建议 3-6，越小延迟越低）
- (instancetype)initWithCapacity:(NSUInteger)capacity;

/// 入队一帧（内部会 retain）。队列满时丢弃最旧的一帧并返回 NO。
- (BOOL)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)time;

/// 出队一帧。调用方负责 release 返回的 buffer。空队列返回 NULL。
- (CVPixelBufferRef _Nullable)dequeuePixelBufferWithTime:(CMTime *)outTime CF_RETURNS_RETAINED;

/// 只保留最新一帧，丢弃其余（用于"低延迟优先"场景）
- (CVPixelBufferRef _Nullable)dequeueLatestPixelBufferWithTime:(CMTime *)outTime CF_RETURNS_RETAINED;

- (void)flush;
@property (nonatomic, readonly) NSUInteger count;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_CONCURRENT_QUEUE_H */
