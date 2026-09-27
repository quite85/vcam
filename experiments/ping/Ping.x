// ============================================================================
//  Ping.x —— 最小可行注入测试（诊断用）
//
//  目的：回答一个**唯一**的问题 ——
//        "往 App 里注入我们编出来的 dylib，本身会不会把系统搞黑屏？"
//
//  它做的事情：
//     · 只对 com.apple.Preferences（设置 App）生效
//     · 只往一个文件里追加一行时间戳
//     · **不 hook 任何方法、不 import AVFoundation、不碰相机、不碰状态文件**
//
//  为什么这样能定位问题：
//     · 如果装了它、打开设置 App 正常  → 注入机制没问题，
//                                        黑屏是相机/SpringBoard 那条路引起的
//     · 如果打开设置 App 就黑屏/卡死   → 问题在 dylib 加载本身，
//                                        需要换完全不同的技术路线
//
//  风险面极小：filter 只列了设置 App，
//  即使出问题也只是设置 App 打不开，**不会黑屏**（不碰 SpringBoard）。
// ============================================================================

#import <Foundation/Foundation.h>
#import <os/log.h>

// 注意：这里刻意**不使用**工程里的 VCamLog / VCamStateStore，
//       避免把任何潜在的依赖问题带进这个测试。
static void VCamPingAppendLine(NSString *line) {
    @try {
        NSString *dir = @"/var/mobile/Library/VirtualCamera";
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"ping.log"];
        NSString *stamp = [NSString stringWithFormat:@"%.0f %@\n",
                             NSDate.date.timeIntervalSince1970, line];

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [stamp writeToFile:path atomically:YES
                      encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[stamp dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        os_log(OS_LOG_DEFAULT, "[VCamPing] 写日志失败: %{public}@", e.reason);
    } @catch (...) {
        os_log(OS_LOG_DEFAULT, "[VCamPing] 写日志失败（未知异常）");
    }
}

%ctor {
    // 整个构造体只有一个动作：写一行日志。
    // 如果连这个都会让设备黑屏，说明 dylib 在**加载阶段**就出了问题，
    // 与我们的任何 hook 代码无关。
    @autoreleasepool {
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            os_log(OS_LOG_DEFAULT, "[VCamPing] 已注入 %{public}@ pid=%d",
                   proc, getpid());
            VCamPingAppendLine([NSString stringWithFormat:@"injected %@ pid=%d",
                                  proc, getpid()]);
        } @catch (...) {
            // 什么都不做 —— 绝不能因为写日志把进程搞崩
        }
    }
}
