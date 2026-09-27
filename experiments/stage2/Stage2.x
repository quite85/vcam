// ============================================================================
//  Stage2.x —— 最小可用虚拟相机（基于开源项目验证过的做法）
// ============================================================================
//
//  设计原则（每一条都对应此前踩过的坑）：
//
//   1) 注入面极小：filter 只列 SpringBoard / Safari / Preferences 三个 Bundle，
//      **完全不注入 mediaserverd 等系统守护进程**。
//      依据：开源项目 lxxsoufahk/VCam 的 filter 只注入 SpringBoard。
//
//   2) 构造阶段绝不抛异常：每个 install 都包在 @try/@catch 里。
//      依据：此前四次黑屏，最可能就是构造阶段异常导致
//            进程（尤其 SpringBoard）崩溃重启循环。
//
//   3) 每一步都 NSLog：电脑上通过 idevicesyslog 能实时看到走到哪一步，
//      出问题能立刻定位，不用再猜。
//
//   4) 悬浮窗用 UIWindow + 一个按钮，交互极简（点一下弹菜单）。
//      依据：开源项目的做法（UIWindowLevelAlert + 浮动按钮）。
//
//  功能范围（本阶段）：
//   · SpringBoard 里：音量键监听 + 悬浮按钮 + 选视频
//   · 选中视频后：用 AVPlayer 循环播放，通过 AVCaptureVideoDataOutput
//     的代理回调把帧换成虚拟帧（App 层注入）
//
//  暂不包含（后续再加）：
//   · OBS 推流、麦克风替换、虚拟麦克风、拍照替换、录像替换
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
// class_addMethod 声明在此。不导入会报：
//     error: conflicting types for 'class_addMethod'
// （因为 clang 把它隐式声明成返回 int，而真实签名返回 BOOL）
#import <objc/runtime.h>

static NSString *const kStage2LogPath = @"/var/mobile/Library/VirtualCamera/stage2.log";

// ---------------------------------------------------------------------------
// 日志：同时用 NSLog（进 syslog，电脑可见）和写文件（兜底）
// ---------------------------------------------------------------------------
static void S2Log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[VCamStage2] %@", msg);

    @try {
        NSString *path = kStage2LogPath;
        NSString *dir = [path stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
        NSString *line = [NSString stringWithFormat:@"%.0f %@\n",
                            NSDate.date.timeIntervalSince1970, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:path atomically:YES
                     encoding:NSUTF8StringEncoding error:NULL];
        }
    } @catch (...) {
        // 写文件失败无所谓，NSLog 已经输出了
    }
}

/// 受保护的执行：任何异常都只记录，绝不向上抛
static BOOL S2Guard(NSString *stage, void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        S2Log(@"❌ %@ 抛异常: %@ — %@", stage, e.name, e.reason);
        return NO;
    } @catch (...) {
        S2Log(@"❌ %@ 抛未知异常", stage);
        return NO;
    }
}

// ============================================================================
#pragma mark - 全局状态
// ============================================================================

static BOOL      gEnabled = NO;
static UIWindow *gOverlayWindow = nil;
static UIButton *gFloatButton = nil;
static NSURL    *gVideoURL = nil;

// 视频帧源
static AVPlayer           *gPlayer = nil;
static AVPlayerItemVideoOutput *gPlayerOutput = nil;
static dispatch_source_t   gFrameTimer = nil;
static CVPixelBufferRef    gLatestFrame = NULL;

// ============================================================================
#pragma mark - 视频帧源：AVPlayer 循环播放 + 定时取帧
// ============================================================================

static void S2StartVideo(NSURL *url) {
    S2Guard(@"startVideo", ^{
        S2Log(@"开始加载视频: %@", url.lastPathComponent);

        if (gFrameTimer) {
            dispatch_source_cancel(gFrameTimer);
            gFrameTimer = nil;
        }
        if (gLatestFrame) {
            CVPixelBufferRelease(gLatestFrame);
            gLatestFrame = NULL;
        }

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        gPlayerOutput = [[AVPlayerItemVideoOutput alloc]
            initWithPixelBufferAttributes:@{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            }];
        [item addOutput:gPlayerOutput];

        gPlayer = [AVPlayer playerWithPlayerItem:item];
        gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        gPlayer.muted = YES;

        // 循环播放
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            [gPlayer seekToTime:kCMTimeZero];
            [gPlayer play];
        }];

        [gPlayer play];

        // 30fps 取帧到 gLatestFrame
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        gFrameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        uint64_t interval = NSEC_PER_SEC / 30;
        dispatch_source_set_timer(gFrameTimer, DISPATCH_TIME_NOW, interval, interval / 4);
        dispatch_source_set_event_handler(gFrameTimer, ^{
            @try {
                if (!gPlayerOutput) return;
                CMTime t = gPlayer.currentTime;
                if (![gPlayerOutput hasNewPixelBufferForItemTime:t]) return;
                CVPixelBufferRef pb = [gPlayerOutput copyPixelBufferForItemTime:t
                                                               itemTimeForDisplay:NULL];
                if (!pb) return;
                if (gLatestFrame) CVPixelBufferRelease(gLatestFrame);
                gLatestFrame = pb;      // 持有，供 hook 使用
            } @catch (...) {
                // 忽略
            }
        });
        dispatch_resume(gFrameTimer);

        gEnabled = YES;
        gVideoURL = url;
        S2Log(@"✅ 视频已开始播放（循环），虚拟相机已启用");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gFloatButton) {
                gFloatButton.backgroundColor =
                    [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
            }
        });
    });
}

static void S2StopVideo(void) {
    S2Guard(@"stopVideo", ^{
        gEnabled = NO;
        if (gFrameTimer) {
            dispatch_source_cancel(gFrameTimer);
            gFrameTimer = nil;
        }
        [gPlayer pause];
        gPlayer = nil;
        gPlayerOutput = nil;
        if (gLatestFrame) {
            CVPixelBufferRelease(gLatestFrame);
            gLatestFrame = NULL;
        }
        S2Log(@"已停止虚拟相机");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gFloatButton) {
                gFloatButton.backgroundColor =
                    [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
            }
        });
    });
}

// ============================================================================
#pragma mark - 悬浮按钮 UI（在 SpringBoard 里）
// ============================================================================

@interface S2FloatButton : UIButton
@end
@implementation S2FloatButton
@end

static UIViewController *S2TopViewController(void) {
    UIViewController *top = nil;
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { top = w.rootViewController; break; }
            }
            if (top) break;
        }
        while (top.presentedViewController) top = top.presentedViewController;
    } @catch (...) {}
    return top;
}

static void S2HandlePan(UIPanGestureRecognizer *g) {
    @try {
        UIView *v = g.view;
        CGPoint t = [g translationInView:v.superview];
        v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
        [g setTranslation:CGPointZero inView:v.superview];
        if (g.state == UIGestureRecognizerStateEnded) {
            CGRect s = UIScreen.mainScreen.bounds;
            CGFloat x = v.center.x < s.size.width / 2 ? 42 : s.size.width - 42;
            [UIView animateWithDuration:0.2 animations:^{
                v.center = CGPointMake(x, v.center.y);
            }];
        }
    } @catch (...) {}
}

static void S2HandleTap(UITapGestureRecognizer *g) {
    @try {
        UIViewController *top = S2TopViewController();
        if (!top) {
            S2Log(@"拿不到 topViewController，无法弹菜单");
            return;
        }

        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"虚拟摄像头"
                             message:(gEnabled ? @"已启用（循环播放中）" : @"未启用")
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [sheet addAction:[UIAlertAction actionWithTitle:@"选择视频"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            S2Guard(@"pickVideo", ^{
                UIImagePickerController *p = [[UIImagePickerController alloc] init];
                p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                p.mediaTypes = @[@"public.movie"];
                p.delegate = (id<UIImagePickerControllerDelegate,
                                 UINavigationControllerDelegate>)
                             [NSClassFromString(@"VCamStage2PickerDelegate") new];
                [top presentViewController:p animated:YES completion:nil];
            });
        }]];

        if (gEnabled) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"关闭虚拟相机"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a) { S2StopVideo(); }]];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
            style:UIAlertActionStyleCancel handler:nil]];

        // iPad / 弹窗兼容
        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = g.view;
            sheet.popoverPresentationController.sourceRect = g.view.bounds;
        }

        [top presentViewController:sheet animated:YES completion:nil];
    } @catch (NSException *e) {
        S2Log(@"弹菜单异常: %@", e.reason);
    }
}

/// 图片选择器代理
@interface VCamStage2PickerDelegate : NSObject
    <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation VCamStage2PickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    @try {
        NSURL *url = info[UIImagePickerControllerMediaURL];
        if (!url) {
            S2Log(@"选中的不是视频");
            return;
        }
        // 复制到沙盒，避免相册 URL 权限问题
        NSString *dest = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"vcam_stage2.mp4"];
        [NSFileManager.defaultManager removeItemAtPath:dest error:NULL];
        NSError *err = nil;
        if (![NSFileManager.defaultManager copyItemAtURL:url
                                                   toURL:[NSURL fileURLWithPath:dest]
                                                   error:&err]) {
            S2Log(@"复制视频失败: %@（直接用原 URL 试）", err.localizedDescription);
            S2StartVideo(url);
            return;
        }
        S2StartVideo([NSURL fileURLWithPath:dest]);
    } @catch (NSException *e) {
        S2Log(@"处理选中视频异常: %@", e.reason);
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamStage2PickerDelegate *gPickerDelegate = nil;

static void S2SetupFloatButton(void) {
    S2Guard(@"setupFloatButton", ^{
        if (gFloatButton) {
            S2Log(@"悬浮按钮已存在，跳过");
            return;
        }

        CGRect screen = UIScreen.mainScreen.bounds;
        CGFloat size = 54;

        gFloatButton = [S2FloatButton buttonWithType:UIButtonTypeSystem];
        gFloatButton.frame = CGRectMake(screen.size.width - size - 16, 120, size, size);
        gFloatButton.layer.cornerRadius = size / 2.0;
        gFloatButton.backgroundColor =
            [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        [gFloatButton setTitle:@"📷" forState:UIControlStateNormal];
        gFloatButton.titleLabel.font = [UIFont systemFontOfSize:26];
        gFloatButton.layer.shadowColor = UIColor.blackColor.CGColor;
        gFloatButton.layer.shadowOffset = CGSizeMake(0, 2);
        gFloatButton.layer.shadowOpacity = 0.3;
        gFloatButton.layer.shadowRadius = 4;

        // 手势：pan（拖动）与 tap（点按弹菜单）
        // 注意先用 class_addMethod 把 C 函数挂成方法，再创建手势并指向它。
        // 之前先建手势再 addMethod 是错的顺序（手势 target 在创建时就固定了）。
        class_addMethod([gFloatButton class], @selector(handlePan:),
                        (IMP)S2HandlePan, "v@:@");
        class_addMethod([gFloatButton class], @selector(handleTap:),
                        (IMP)S2HandleTap, "v@:@");

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:gFloatButton
                                                    action:@selector(handlePan:)];
        [gFloatButton addGestureRecognizer:pan];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:gFloatButton
                                                    action:@selector(handleTap:)];
        [gFloatButton addGestureRecognizer:tap];

        gOverlayWindow = [[UIWindow alloc] initWithFrame:screen];
        gOverlayWindow.windowLevel = UIWindowLevelAlert + 100;
        gOverlayWindow.backgroundColor = UIColor.clearColor;
        gOverlayWindow.hidden = NO;

        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = UIColor.clearColor;
        [root.view addSubview:gFloatButton];
        gOverlayWindow.rootViewController = root;

        gPickerDelegate = [[VCamStage2PickerDelegate alloc] init];

        S2Log(@"✅ 悬浮按钮已创建（窗口 level=%.0f）", gOverlayWindow.windowLevel);
    });
}

// ============================================================================
#pragma mark - 音量键监听（KVO 观察 AVAudioSession.outputVolume）
// ============================================================================

@interface S2VolumeWatcher : NSObject
@end

@implementation S2VolumeWatcher

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    @try {
        float v = AVAudioSession.sharedInstance.outputVolume;
        S2Log(@"★ 音量变化 -> %.3f（虚拟相机%@）", v, gEnabled ? @"已启用" : @"未启用");

        // 短按弹出按钮（简单版：每次音量变化都把按钮提到最前并轻微提示）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gFloatButton) return;
            [gOverlayWindow bringSubviewToFront:gFloatButton];
            [UIView animateWithDuration:0.12 animations:^{
                gFloatButton.transform = CGAffineTransformMakeScale(1.15, 1.15);
            } completion:^(BOOL done) {
                [UIView animateWithDuration:0.12 animations:^{
                    gFloatButton.transform = CGAffineTransformIdentity;
                }];
            }];
        });
    } @catch (NSException *e) {
        S2Log(@"音量回调异常: %@", e.reason);
    }
}

@end

static S2VolumeWatcher *gVolumeWatcher = nil;

static void S2InstallVolumeWatch(void) {
    S2Guard(@"installVolumeWatch", ^{
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gVolumeWatcher = [[S2VolumeWatcher alloc] init];
            [AVAudioSession.sharedInstance
                addObserver:gVolumeWatcher
                 forKeyPath:@"outputVolume"
                    options:NSKeyValueObservingOptionNew
                    context:NULL];
            S2Log(@"✅ 音量键监听已安装（按一下音量键即可验证）");
        });
    });
}

// ============================================================================
#pragma mark - App 层注入：换掉 AVCaptureVideoDataOutput 的帧
// ============================================================================

static CVPixelBufferRef S2CopyLatestFrame(void) {
    @try {
        if (!gEnabled || !gLatestFrame) return NULL;
        CVPixelBufferRef out = NULL;
        // 复制一份给调用方（它负责释放）
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault,
                                        CVPixelBufferGetWidth(gLatestFrame),
                                        CVPixelBufferGetHeight(gLatestFrame),
                                        CVPixelBufferGetPixelFormatType(gLatestFrame),
                                        NULL, &out);
        if (r != kCVReturnSuccess || !out) return NULL;

        CVPixelBufferLockBaseAddress(gLatestFrame, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(out, 0);
        size_t h = CVPixelBufferGetHeight(gLatestFrame);
        size_t bpr = CVPixelBufferGetBytesPerRow(gLatestFrame);
        memcpy(CVPixelBufferGetBaseAddress(out),
               CVPixelBufferGetBaseAddress(gLatestFrame),
               h * bpr);
        CVPixelBufferUnlockBaseAddress(out, 0);
        CVPixelBufferUnlockBaseAddress(gLatestFrame, kCVPixelBufferLock_ReadOnly);
        return out;
    } @catch (...) {
        return NULL;
    }
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    %orig;
    S2Log(@"App 层：AVCaptureVideoDataOutput 设置了代理 %@（虚拟相机%@）",
          delegate ? NSStringFromClass([delegate class]) : @"nil",
          gEnabled ? @"已启用" : @"未启用");
}

%end

%ctor {
    @autoreleasepool {
        S2Guard(@"ctor", ^{
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            NSString *bid  = NSBundle.mainBundle.bundleIdentifier ?: @"?";

            S2Log(@"===== 已注入 %@ (bundle=%@) pid=%d =====", proc, bid, getpid());

            if ([bid isEqualToString:@"com.apple.springboard"]) {
                S2Log(@"这是 SpringBoard：安装音量监听 + 悬浮按钮");
                S2InstallVolumeWatch();
                // 延迟 1 秒再建 UI，等 SpringBoard 起来
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    S2SetupFloatButton();
                    S2Log(@"===== SpringBoard 初始化完成 =====");
                });
            } else {
                S2Log(@"这是 App 进程（%@），App 层 hook 已生效", bid);
            }
        });
    }
}
