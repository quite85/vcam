//
//  Tweak.xm
//  虚拟摄像头
//
//  ---------------------------------------------------------------------------
//  结构参考了开源项目 lxxsoufahk/VCam（能加载、结构简单），
//  但修掉了它一个致命缺陷 —— 详见文件末尾 %ctor 里的注释。
//  ---------------------------------------------------------------------------
//
//  进程分工：
//    · SpringBoard：悬浮按钮 UI + 音量键触发 + 相册选视频
//    · 其它 App（相机 / Safari / 微信…）：安装帧替换 swizzle
//
//  交互（按用户要求）：
//    · 短按「音量减」→ 弹出悬浮小窗
//    · 小窗可拖动，松手贴边
//    · 点小窗 → 选相册视频 / 开关虚拟相机
//
//  与开源项目的差异（"他们没有的功能"）：
//    1) 用代理模式做帧替换（开源项目用 %hook NSObject，实际不生效）
//    2) 音量减触发（开源项目只有悬浮按钮）
//    3) 失败时弹窗告知具体原因
//    4) 运行日志写到文件 + NSLog，便于排查
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

#import "VCamMediaManager.h"
#import "VCamFrameInjector.h"
#import "VCamLog.h"


// ============================================================================
#pragma mark - 全局状态
// ============================================================================

static UIWindow *gOverlayWindow = nil;

// ============================================================================
#pragma mark - 悬浮按钮
// ============================================================================

// 注意声明顺序：VCamFloatButton 类（含 vcamApplyStateColor 方法）必须先定义，
// gFloatButton 才能声明成 VCamFloatButton* 并直接调用该私有方法。
// 如果把 gFloatButton 提前声明成 UIButton*，会报：
//     error: no visible @interface for 'UIButton' declares the selector
//            'vcamApplyStateColor'
@interface VCamFloatButton : UIButton
- (void)vcamApplyStateColor;
@end

static void VCamShowPanel(void);
static void VCamHandleFloatTap(UITapGestureRecognizer *g);
static void VCamHandleFloatPan(UIPanGestureRecognizer *g);

@implementation VCamFloatButton

- (void)vcamApplyStateColor {
    BOOL on = [VCamFrameInjector isEnabled];
    self.backgroundColor = on
        ? [UIColor colorWithRed:0.20 green:0.78 blue:0.42 alpha:0.95]
        : [UIColor colorWithRed:0.35 green:0.35 blue:0.38 alpha:0.95];
}

@end

/// 悬浮按钮实例（用子类类型，便于调用 vcamApplyStateColor）
static VCamFloatButton *gFloatButton = nil;

static void VCamEnsureOverlayWindow(void) {
    if (gOverlayWindow) return;

    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        gOverlayWindow = [[UIWindow alloc] initWithFrame:screen];
        gOverlayWindow.windowLevel = UIWindowLevelAlert + 100;
        gOverlayWindow.backgroundColor = UIColor.clearColor;
        gOverlayWindow.hidden = YES;

        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = UIColor.clearColor;
        gOverlayWindow.rootViewController = root;

        VCamLog(@"悬浮窗已创建（level=%.0f）", gOverlayWindow.windowLevel);
    } @catch (NSException *e) {
        VCamLog(@"创建悬浮窗异常: %@", e.reason);
    }
}

/// 创建（或复用）悬浮按钮
static void VCamEnsureFloatButton(void) {
    VCamEnsureOverlayWindow();
    if (gFloatButton || !gOverlayWindow) return;

    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        CGFloat size = 56;

        // 手势用 C 函数实现 → 先把它们挂成方法
        Class btnCls = VCamFloatButton.class;
        class_addMethod(btnCls, @selector(vcamHandleTap:), (IMP)VCamHandleFloatTap, "v@:@");
        class_addMethod(btnCls, @selector(vcamHandlePan:), (IMP)VCamHandleFloatPan, "v@:@");

        VCamFloatButton *btn = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(screen.size.width - size - 14, 140, size, size);
        btn.layer.cornerRadius = size / 2.0;
        btn.layer.shadowColor = UIColor.blackColor.CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.layer.shadowOpacity = 0.35;
        btn.layer.shadowRadius = 5;
        [btn setTitle:@"CAM" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:20];
        [btn vcamApplyStateColor];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:btn
                                                    action:@selector(vcamHandlePan:)];
        [btn addGestureRecognizer:pan];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:btn
                                                    action:@selector(vcamHandleTap:)];
        [btn addGestureRecognizer:tap];

        [gOverlayWindow.rootViewController.view addSubview:btn];
        gFloatButton = btn;

        VCamLog(@"悬浮按钮已创建");
    } @catch (NSException *e) {
        VCamLog(@"创建悬浮按钮异常: %@", e.reason);
    }
}

static void VCamHandleFloatPan(UIPanGestureRecognizer *g) {
    @try {
        UIView *v = g.view;
        CGPoint t = [g translationInView:v.superview];
        v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
        [g setTranslation:CGPointZero inView:v.superview];

        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled) {
            CGRect s = UIScreen.mainScreen.bounds;
            CGFloat x = v.center.x < s.size.width / 2 ? 44 : s.size.width - 44;
            CGFloat y = MIN(MAX(v.center.y, 80), s.size.height - 120);
            [UIView animateWithDuration:0.22
                                  delay:0
                 usingSpringWithDamping:0.8
                  initialSpringVelocity:0.4
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                CGPoint c = v.center; c.x = x; c.y = y; v.center = c;
            } completion:nil];
        }
    } @catch (...) {}
}

static void VCamHandleFloatTap(UITapGestureRecognizer *g) {
    VCamShowPanel();
}

// ============================================================================
#pragma mark - 菜单
// ============================================================================

@interface VCamPickerDelegate : NSObject <UIImagePickerControllerDelegate,
                                          UINavigationControllerDelegate>
@end

@implementation VCamPickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    @try {
        NSURL *src = info[UIImagePickerControllerMediaURL];
        if (!src) {
            VCamLog(@"选中的不是视频（没有 MediaURL）");
            return;
        }
        VCamLog(@"选中视频: %@", src.lastPathComponent);

        // 复制到沙盒：相册返回的 URL 权限受限，直接读可能失败
        NSString *dest = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"vcam_input.mp4"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:dest error:NULL];
        NSError *err = nil;
        NSURL *useURL = src;
        if ([fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dest] error:&err]) {
            useURL = [NSURL fileURLWithPath:dest];
            VCamLog(@"已复制到沙盒: %@", dest);
        } else {
            VCamLog(@"复制失败（%@），直接用原 URL", err.localizedDescription);
        }

        NSError *loadErr = nil;
        BOOL ok = [[VCamMediaManager shared] loadMediaFromURL:useURL error:&loadErr];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = gOverlayWindow.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
            if (!top) return;

            if (ok) {
                [VCamFrameInjector setEnabled:YES];
                [[VCamMediaManager shared] start];
                CGSize sz = [VCamMediaManager shared].videoSize;
                VCamLog(@"虚拟相机已开启  尺寸=%.0fx%.0f", sz.width, sz.height);
                [gFloatButton vcamApplyStateColor];

                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"虚拟摄像头"
                                     message:[NSString stringWithFormat:
                                        @"已启用\n视频尺寸: %.0f x %.0f\n\n"
                                        @"现在打开相机或 Safari 网页试试。",
                                        sz.width, sz.height]
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
                [top presentViewController:a animated:YES completion:nil];
            } else {
                VCamLog(@"载入视频失败: %@", loadErr.localizedDescription);
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"载入失败"
                                     message:(loadErr.localizedDescription ?: @"未知错误")
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
                [top presentViewController:a animated:YES completion:nil];
            }
        });
    } @catch (NSException *e) {
        VCamLog(@"处理选中视频异常: %@", e.reason);
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamPickerDelegate *gPickerDelegate = nil;

static void VCamShowPanel(void) {
    @try {
        if (!gOverlayWindow) { VCamLog(@"悬浮窗不存在"); return; }

        gOverlayWindow.hidden = NO;
        [gOverlayWindow makeKeyAndVisible];

        BOOL on = [VCamFrameInjector isEnabled];

        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"虚拟摄像头"
                             message:[NSString stringWithFormat:
                                        @"状态: %@\n已替换 %llu 帧",
                                        on ? @"已启用" : @"未启用",
                                        [VCamFrameInjector replacedFrameCount]]
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [sheet addAction:[UIAlertAction actionWithTitle:@"选择相册视频"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            @try {
                UIImagePickerController *p = [[UIImagePickerController alloc] init];
                p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                p.mediaTypes = @[@"public.movie"];
                p.delegate = gPickerDelegate;
                UIViewController *top = gOverlayWindow.rootViewController;
                while (top.presentedViewController) top = top.presentedViewController;
                [top presentViewController:p animated:YES completion:nil];
            } @catch (NSException *e) {
                VCamLog(@"打开相册失败: %@", e.reason);
            }
        }]];

        [sheet addAction:[UIAlertAction actionWithTitle:(on ? @"关闭虚拟相机" : @"开启虚拟相机")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            if ([VCamFrameInjector isEnabled]) {
                [VCamFrameInjector setEnabled:NO];
                [[VCamMediaManager shared] stop];
            } else {
                [VCamFrameInjector setEnabled:YES];
                [[VCamMediaManager shared] start];
            }
            [gFloatButton vcamApplyStateColor];
        }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮按钮"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) {
            gOverlayWindow.hidden = YES;
            VCamLog(@"悬浮按钮已隐藏（按音量减可再次唤出）");
        }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = gFloatButton;
            sheet.popoverPresentationController.sourceRect = gFloatButton.bounds;
        }

        UIViewController *top = gOverlayWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:sheet animated:YES completion:nil];
    } @catch (NSException *e) {
        VCamLog(@"弹菜单异常: %@", e.reason);
    }
}

// ============================================================================
#pragma mark - 音量键监听（用户要求的触发方式）
// ============================================================================
//
//  用 KVO 观察 AVAudioSession.outputVolume：
//    · 短按音量减 → 音量下降 → 回调 → 弹出面板
//    · 去抖 0.6 秒，避免长按连弹
//    · 通话/录音中不弹（避免干扰通话）
//
//  为什么不用 hook SpringBoard 的音量 HUD：
//    那是私有实现，iOS 15/16 差异大，且可能要 hook 私有符号。
//    KVO 观察 outputVolume 是公开 API，稳定、风险低。
//
@interface VCamVolumeWatcher : NSObject
@property (nonatomic, assign) float lastVolume;
@property (nonatomic, assign) NSTimeInterval lastTrigger;
@end

@implementation VCamVolumeWatcher

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    @try {
        float v = AVAudioSession.sharedInstance.outputVolume;
        float old = self.lastVolume;
        self.lastVolume = v;

        if (v >= old - 0.001f) return;   // 只关心音量减小

        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now - self.lastTrigger < 0.6) return;   // 去抖
        self.lastTrigger = now;

        NSString *cat = AVAudioSession.sharedInstance.category;
        if ([cat isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
            [cat isEqualToString:AVAudioSessionCategoryRecord]) {
            VCamLog(@"音量减：当前是通话/录音（%@），不弹面板", cat);
            return;
        }

        VCamLog(@"音量减被按下（%.2f -> %.2f），弹出面板", old, v);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCamEnsureFloatButton();
            VCamShowPanel();
        });
    } @catch (NSException *e) {
        VCamLog(@"音量回调异常: %@", e.reason);
    }
}

@end

static VCamVolumeWatcher *gVolumeWatcher = nil;

static void VCamInstallVolumeWatcher(void) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gVolumeWatcher = [[VCamVolumeWatcher alloc] init];
            gVolumeWatcher.lastVolume = AVAudioSession.sharedInstance.outputVolume;

            [AVAudioSession.sharedInstance addObserver:gVolumeWatcher
                                            forKeyPath:@"outputVolume"
                                               options:NSKeyValueObservingOptionNew |
                                                       NSKeyValueObservingOptionOld
                                               context:NULL];
            VCamLog(@"音量键监听已安装（短按音量减 -> 弹出面板）");
        });
    } @catch (NSException *e) {
        VCamLog(@"安装音量监听失败: %@", e.reason);
    }
}

// ============================================================================
#pragma mark - 构造：按进程分流
// ============================================================================
//
//  ---- 这里修掉了开源项目 lxxsoufahk/VCam 的一个致命缺陷 ----
//
//  它的写法：
//      NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
//      if (![bundleID isEqualToString:@"com.apple.springboard"]) {
//          %init(VCamHooks);       // 只在非 SpringBoard 里安装 hook
//      }
//  而它的 filter 只注入 SpringBoard。
//  -> hook 从未被安装，相机替换从未生效，只剩一个空按钮。
//
//  正确做法：在所有进程里都安装帧替换，
//            SpringBoard 里额外装 UI 与音量监听。
//
%ctor {
    @autoreleasepool {
        @try {
            NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            VCamLog(@"===== 载入 %@ (bundle=%@) pid=%d =====", proc, bid, getpid());

            BOOL isSpringBoard = [bid isEqualToString:@"com.apple.springboard"];

            // ---- 1) 帧替换：所有进程都装 ----
            [VCamFrameInjector install];
            [VCamMediaManager shared];

            // ---- 2) SpringBoard：UI + 音量键 ----
            if (isSpringBoard) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        VCamInstallVolumeWatcher();
                        VCamEnsureFloatButton();
                        VCamLog(@"===== SpringBoard 初始化完成 =====");
                    } @catch (NSException *e) {
                        VCamLog(@"SpringBoard 初始化异常: %@", e.reason);
                    }
                });
            } else {
                VCamLog(@"App 进程已就绪，等待相机");
            }
        } @catch (NSException *e) {
            VCamLog(@"ctor 异常: %@", e.reason);
        } @catch (...) {
            VCamLog(@"ctor 未知异常");
        }
    }
}
