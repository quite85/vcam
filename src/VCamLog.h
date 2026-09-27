//
//  VCamLog.h
//  虚拟摄像头
//
//  统一日志接口。
//
//  ⚠️ 为什么单独抽一个头文件，而不是在 .m 里定义、在 .xm 里 extern 声明：
//
//     Tweak.xm 扩展名是 .xm，Logos 会把它按 **Objective-C++** 处理，
//     而 VCamFrameInjector.m 是纯 Objective-C（C 链接）。
//     如果只在 .xm 里写：
//         extern void VCamLog(NSString *fmt, ...);
//     clang 会按 C++ 规则把它 mangle 成 _Z7VCamLogPKcz，
//     而 .m 里定义的是 C 符号 _VCamLog，
//     链接时报：
//         ld64.lld: error: undefined symbol: VCamLog(NSString*, ...)
//
//     解决办法：在头文件里用 extern "C" 包住声明，
//     这样 C++ 侧也会去找 C 符号。
//
#ifndef VCAM_LOG_H
#define VCAM_LOG_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 写一行运行日志。同时输出到 NSLog（进 syslog）和
/// /var/mobile/Library/VirtualCamera/vcam.log。
void VCamLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif

#endif /* VCAM_LOG_H */
