//
//  VCamConfig.m
//  VCam
//
//  这里只放"跨进程共享"的基础设施：路径、日志、进程判断。
//  真正的可变配置在 VCamStateStore 里。
//

#import "VCamConfig.h"
#import <notify.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <os/lock.h>

NSString *const kVCamStateKeyMode          = @"mode";
NSString *const kVCamStateKeyAssetPath     = @"assetPath";
NSString *const kVCamStateKeyAssetIsVideo  = @"assetIsVideo";
NSString *const kVCamStateKeyRotation      = @"rotation";
NSString *const kVCamStateKeyMirror        = @"mirror";
NSString *const kVCamStateKeyMirrorBack    = @"mirrorBack";
NSString *const kVCamStateKeyLoop          = @"loop";
NSString *const kVCamStateKeyPort          = @"port";
NSString *const kVCamStateKeyTransport     = @"transport";
NSString *const kVCamStateKeyLatencyMs     = @"latencyMs";
NSString *const kVCamStateKeyAudioKind     = @"audioKind";
NSString *const kVCamStateKeyAudioVolume   = @"audioVolume";
NSString *const kVCamStateKeyLipSyncMs     = @"lipSyncMs";
NSString *const kVCamStateKeyMSDDisabled   = @"msdDisabled";
NSString *const kVCamStateKeyAppLayerOnly  = @"appLayerOnly";
NSString *const kVCamStateKeySessionActive = @"sessionActive";
NSString *const kVCamStateKeyLastError     = @"lastError";
NSString *const kVCamStateKeyVersion       = @"schemaVersion";

NSString *const kVCamNotificationStateChanged   = @"com.quite85.vcam/stateChanged";
NSString *const kVCamNotificationUIrefresh      = @"com.quite85.vcam/uirefresh";
NSString *const kVCamNotificationMSDUnavailable = @"com.quite85.vcam/msdUnavailable";

#pragma mark - 路径

NSString *VCamStateDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/VCam";
        // 若 /var/mobile 不可写（极少见，例如某些 roothide 变体），退回 /tmp
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:@"/var/mobile/Library"]) {
            dir = @"/tmp/VCam";
        }
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @(0755)}
                                error:NULL];
        }
    });
    return dir;
}

NSString *VCamStateFilePath(void) {
    return [VCamStateDirectory() stringByAppendingPathComponent:@"state.plist"];
}

NSString *VCamLogFilePath(void) {
    return [VCamStateDirectory() stringByAppendingPathComponent:@"vcam.log"];
}

NSString *VCamMSDCrashFlagPath(void) {
    return [VCamStateDirectory() stringByAppendingPathComponent:@"msd_crash.flag"];
}

NSString *VCamAssetCacheDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [VCamStateDirectory() stringByAppendingPathComponent:@"assets"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @(0755)}
                                                     error:NULL];
    });
    return dir;
}

NSString *VCamRecordingTempDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [VCamStateDirectory() stringByAppendingPathComponent:@"rec"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @(0755)}
                                                     error:NULL];
    });
    return dir;
}

#pragma mark - 进程判断

NSString *VCamCurrentProcessName(void) {
    static NSString *name = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 用 sysctl 拿进程名，比 NSProcessInfo 在 daemon 里更可靠
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        struct kinfo_proc info;
        size_t size = sizeof(info);
        memset(&info, 0, sizeof(info));
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
            name = @(info.kp_proc.p_comm);
        }
        if (name.length == 0) {
            name = NSProcessInfo.processInfo.processName ?: @"unknown";
        }
    });
    return name;
}

BOOL VCamIsMediaServerProcess(void) {
    static BOOL is = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *n = VCamCurrentProcessName();
        // iOS 15/16 上相机与音频采集都归 mediaserverd 管；
        // mediaplaybackd / audioaccessoryd / camerad 在部分版本承担子功能。
        is = [n hasPrefix:@"mediaserverd"] ||
             [n isEqualToString:@"mediaplaybackd"] ||
             [n isEqualToString:@"camerad"] ||
             [n isEqualToString:@"audioaccessoryd"];
    });
    return is;
}

BOOL VCamIsSpringBoardProcess(void) {
    static BOOL is = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        is = [VCamCurrentProcessName() isEqualToString:@"SpringBoard"];
    });
    return is;
}

#pragma mark - 日志

void VCamLog(NSString *fmt, ...) {
#if DEBUG
    // Release 包下也保留日志（用户排查必需），但只在文件里，不刷屏
#endif
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!msg) return;

    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@][%@][%d] %@\n",
                      [df stringFromDate:NSDate.date],
                      VCamCurrentProcessName(),
                      getpid(),
                      msg];

    fprintf(stderr, "VCam %s", line.UTF8String);

    NSString *path = VCamLogFilePath();
    NSFileManager *fm = NSFileManager.defaultManager;
    // 滚动：超过 256KB 截断成后一半
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
        NSData *old = [NSData dataWithContentsOfFile:path];
        if (old.length > 128 * 1024) {
            NSData *tail = [old subdataWithRange:NSMakeRange(old.length - 128 * 1024, 128 * 1024)];
            [tail writeToFile:path atomically:YES];
        }
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {
            // 忽略：日志失败绝不能影响主流程
        }
        [fh closeFile];
    }
    os_unfair_lock_unlock(&lock);
}
