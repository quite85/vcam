//
//  VCamOBSAddress.h
//  VCam
//
//  本机地址工具（独立于 OBS 功能）。
//
//  为什么单独做成一个类，而不是放在 VCamOBSSource 上：
//   1) 架构问题：UI 层（VCamPanel 要显示推流地址）不应该依赖 Core 层的
//      VCamOBSSource —— 那会让"只想显示地址"的代码被迫链接整个 OBS 模块。
//   2) 编译问题：如果把这些方法**声明**在 VCamOBSSource.h 上、却**实现**在
//      category（VCamOBSAddress.m）里，clang 会报
//        error: category is implementing a method which will also be
//               implemented by its primary class
//               [-Werror,-Wobjc-protocol-method-implementation]
//      因为"声明在 @interface 上"就等于告诉编译器主实现会有它。
//   3) 两种构建都能用：VCAM_ENABLE_OBS=0 的轻量包里，VCamOBSSource 会退化
//      成 stub，但地址显示功能依然应该正常工作。
//
//  所以：这个类同时被 VCamCore 与主 tweak 编译，两条链路都能调用。
//

#ifndef VCAM_OBS_ADDRESS_H
#define VCAM_OBS_ADDRESS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamOBSAddress : NSObject

/// 本机所有可用于推流的 IPv4 地址（Wi-Fi / USB 网络共享都算）。
/// USB 网络共享的网段（172.20.10.x / 192.168.42.x）会被排到最前面，
/// 因为有线连接比 Wi-Fi 稳定得多、延迟也低。
+ (NSArray<NSString *> *)localIPv4Addresses;

/// 生成给用户复制到 OBS 的完整推流地址，例如 udp://192.168.1.20:5600
+ (NSString *)pushURLForTransport:(NSString *)transport port:(uint16_t)port;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_OBS_ADDRESS_H */
