// ============================================================================
//  Stage1.x —— 最小注入验证（v3：加音量键探测）
// ============================================================================
//
//  这个文件基本没有业务逻辑，只做"证明自己被加载了"。
//
//  为什么加音量键探测（v3 相比 v2）：
//    v1/v2 只写文件。如果注入没发生，我们只能看到"什么都没有"，
//    无法区分"没注入"和"注入了但写文件失败/日志抓不到"。
//
//    音量键探测能给出**强信号**：
//    用户只要按一下音量键，插件（如果已加载进 SpringBoard）就会
//    NSLog 一行。NSLog 进 syslog，电脑上立刻能看到。
//
//    好处：用户不需要重启、不需要打开特定 App、不需要 Fillet/NewTerm，
//          只按一下音量键即可 —— 这是最低的操作成本。
//
//  如何探测音量键：
//    用 KVO 监听 AVAudioSession 的 outputVolume。
//    按音量键会改变 outputVolume，从而触发 observeValueForKeyPath。
//    这是纯公开 API，不需要 hook 任何私有符号，风险极低。
//
//  filter 同时包含 springboard / Preferences / Safari，所以：
//    · 重启后 SpringBoard 加载 → 立即有日志
//    · 按音量键 → 立即有日志
//
//  注意：整个文件包在 @try/@catch 里，且不 hook 任何方法，
//        因此即使出问题也不会让宿主进程崩溃。
// ============================================================================

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

/// 依次尝试多个可写位置，返回第一个成功的路径（都失败返回 nil）
static NSString *Stage1WriteAnywhere(NSString *line) {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [candidates addObject:@"/var/mobile/Library/VirtualCamera/stage1.log"];
    [candidates addObject:@"/var/mobile/Documents/stage1.log"];
    [candidates addObject:@"/tmp/stage1.log"];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [candidates addObject:[home stringByAppendingPathComponent:@"Documents/stage1.log"]];
    }

    NSString *stamp = [NSString stringWithFormat:@"%.0f %@\n",
                         NSDate.date.timeIntervalSince1970, line];

    for (NSString *path in candidates) {
        @try {
            NSString *dir = [path stringByDeletingLastPathComponent];
            if (![fm fileExistsAtPath:dir]) {
                [fm createDirectoryAtPath:dir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:NULL];
            }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[stamp dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                return path;
            }
            if ([stamp writeToFile:path atomically:YES
                          encoding:NSUTF8StringEncoding error:NULL]) {
                return path;
            }
        } @catch (NSException *e) {
            NSLog(@"[VCamStage1] 写 %@ 抛异常: %@", path, e.reason);
        } @catch (...) {
            NSLog(@"[VCamStage1] 写 %@ 抛未知异常", path);
        }
    }
    return nil;
}

/// 音量键探测：KVO 观察 AVAudioSession.outputVolume
@interface VCamStage1VolumeWatcher : NSObject
@end

@implementation VCamStage1VolumeWatcher

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    @try {
        float v = [AVAudioSession sharedInstance].outputVolume;
        NSLog(@"[VCamStage1] ★ 检测到音量变化 (keyPath=%@) outputVolume=%.3f",
              keyPath ?: @"?", v);
        Stage1WriteAnywhere([NSString stringWithFormat:
                                @"volume changed -> %.3f", v]);
    } @catch (NSException *e) {
        NSLog(@"[VCamStage1] 音量回调异常: %@", e.reason);
    } @catch (...) {
        NSLog(@"[VCamStage1] 音量回调未知异常");
    }
}

@end

static VCamStage1VolumeWatcher *gStage1VolumeWatcher = nil;

static void Stage1StartVolumeWatch(void) {
    @try {
        AVAudioSession *s = AVAudioSession.sharedInstance;
        if (!s) {
            NSLog(@"[VCamStage1] 拿不到 AVAudioSession，跳过音量监听");
            return;
        }
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gStage1VolumeWatcher = [[VCamStage1VolumeWatcher alloc] init];
            [s addObserver:gStage1VolumeWatcher
                forKeyPath:@"outputVolume"
                   options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                   context:NULL];
            NSLog(@"[VCamStage1] ✅ 音量键监听已安装（按一下音量键即可验证）");
            Stage1WriteAnywhere(@"volume watcher installed");
        });
    } @catch (NSException *e) {
        NSLog(@"[VCamStage1] 安装音量监听失败: %@", e.reason);
    } @catch (...) {
        NSLog(@"[VCamStage1] 安装音量监听失败（未知异常）");
    }
}

%ctor {
    @autoreleasepool {
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            NSString *bid  = NSBundle.mainBundle.bundleIdentifier ?: @"?";
            int pid = getpid();

            NSLog(@"[VCamStage1] ===== 已注入 %@ (bundle=%@) pid=%d =====",
                  proc, bid, pid);

            NSString *where = Stage1WriteAnywhere(
                [NSString stringWithFormat:@"injected proc=%@ bundle=%@ pid=%d",
                                           proc, bid, pid]);
            NSLog(@"[VCamStage1] 日志写入结果: %@",
                  where ?: @"全部位置都失败（沙盒限制？）");

            // 只在 SpringBoard 里装音量监听（UI 进程，能收到音量变化）
            if ([bid isEqualToString:@"com.apple.springboard"]) {
                Stage1StartVolumeWatch();
            }
        } @catch (NSException *e) {
            NSLog(@"[VCamStage1] 构造异常: %@", e.reason);
        } @catch (...) {
            NSLog(@"[VCamStage1] 构造未知异常");
        }
    }
}
