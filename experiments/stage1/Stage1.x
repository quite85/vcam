// ============================================================================
//  Stage1.x —— 零 hook 最小注入验证
// ============================================================================
//
//  这个文件里**没有任何 %hook**。整个插件只做一件事：
//  在被注入时往一个文件追加一行时间戳。
//
//  它要回答的问题只有一个：
//
//      "把我们的 dylib 注入到一个普通 App 里，会不会出事？"
//
//  为什么需要它：
//    主工程（VCam）带 111 项 filter 与大量 hook，此前四次黑屏，
//    无法区分是"注入机制"还是"某个 hook"导致的。
//    这个包把变量降到只剩注入机制本身。
//
//  filter 只列 com.apple.Preferences（设置 App），
//  所以即使 dylib 加载有问题，最坏也只是设置 App 打不开，不会黑屏。
//
//  安装后验证方法：
//    1) 打开「设置」App —— 应正常打开
//    2) 看日志文件 /var/mobile/Library/VirtualCamera/stage1.log
//       应出现 "injected com.apple.Preferences pid=..."
//    3) 看 syslog —— 应出现 [VCamStage1] 前缀的行
//
//  三种结果的含义：
//    A) 设置 App 正常 + 日志有记录   → 注入机制 OK，问题在 hook 里
//    B) 设置 App 打不开 / 闪退       → dylib 加载有问题
//    C) 设置 App 正常但日志无记录    → filter 没生效（注入没发生）
// ============================================================================

#import <Foundation/Foundation.h>
#import <os/log.h>

static NSString *const kStage1LogPath = @"/var/mobile/Library/VirtualCamera/stage1.log";

static void Stage1Append(NSString *line) {
    @try {
        NSString *dir = [kStage1LogPath stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];

        NSString *stamp = [NSString stringWithFormat:@"%.0f %@\n",
                             NSDate.date.timeIntervalSince1970, line];

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kStage1LogPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[stamp dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [stamp writeToFile:kStage1LogPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL];
        }
    } @catch (NSException *e) {
        os_log(OS_LOG_DEFAULT, "[VCamStage1] 写日志失败: %{public}@", e.reason);
    } @catch (...) {
        os_log(OS_LOG_DEFAULT, "[VCamStage1] 写日志失败（未知异常）");
    }
}

%ctor {
    // 整个构造体只有一个动作。包在 @try/@catch 里，
    // 保证即使写日志失败也绝不让宿主进程崩溃。
    @autoreleasepool {
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            int pid = getpid();

            os_log(OS_LOG_DEFAULT,
                   "[VCamStage1] 已注入 %{public}@ pid=%d",
                   proc, pid);

            Stage1Append([NSString stringWithFormat:
                            @"injected %@ pid=%d bundle=%@",
                            proc, pid,
                            NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
        } @catch (...) {
            // 什么都不做 —— 绝不能因为写日志把进程搞崩
        }
    }
}
