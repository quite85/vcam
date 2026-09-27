// ============================================================================
//  Probe.x —— 对照测试：插件注入是否生效
// ============================================================================
//
//  目的：一个**绝对不可能被忽略**的信号 ——
//        如果这个插件被加载了，SpringBoard 启动 3 秒后屏幕上会弹出一个
//        大大的红色弹窗，写着「插件注入成功」。
//
//        如果屏幕上什么都没出现，就说明**你的越狱环境根本没有加载任何插件**，
//        与我们写的代码无关。
//
//  为什么用弹窗而不是写日志：
//    日志需要连电脑才能看，而你之前明确说过不想做技术操作。
//    弹窗是零成本验证 —— 看一眼屏幕就知道。
//
//  设计：
//    · filter 只列 com.apple.springboard（注入面最小）
//    · 只 hook SpringBoard 的 applicationDidFinishLaunching:（公开方法）
//    · 只显示一个 UIAlertController，不碰任何其他东西
//    · 全部包在 @try/@catch，绝不崩溃
//
//  三种结果的解读：
//    A) 屏幕弹出红色弹窗  → 注入正常，问题在我们的 VCam 代码里
//    B) 屏幕什么都没出现  → 注入没生效，是越狱环境/注入框架的问题
//    C) 弹窗出现但内容异常 → 告诉我具体内容
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void ProbeLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VCamProbe] %@", msg);
}

static void ProbeShowAlert(void) {
    @try {
        NSString *text = [NSString stringWithFormat:
            @"插件注入成功 ✅\n\n"
            @"进程: SpringBoard\n"
            @"PID: %d\n"
            @"时间: %@\n\n"
            @"说明：这个弹窗是 VCam 对照测试包弹出的。\n"
            @"说明注入框架（ElleKit）工作正常。",
            getpid(),
            [NSDateFormatter localizedStringFromDate:NSDate.date
                                           dateStyle:NSDateFormatterNoStyle
                                           timeStyle:NSDateFormatterMediumStyle]];

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"VCam 对照测试"
                             message:text
                      preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];

        // 找当前最顶层的窗口来呈现
        UIWindow *keyWin = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWin = w; break; }
            }
            if (keyWin) break;
        }
        if (!keyWin) {
            // 退回到第一个可见窗口
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.hidden) { keyWin = w; break; }
                }
                if (keyWin) break;
            }
        }

        UIViewController *root = keyWin.rootViewController;
        if (!root) {
            ProbeLog(@"找不到窗口来显示弹窗（keyWin=%@）", keyWin);
            return;
        }
        while (root.presentedViewController) root = root.presentedViewController;

        [root presentViewController:alert animated:YES completion:^{
            ProbeLog(@"✅ 弹窗已显示");
        }];
        ProbeLog(@"已请求显示弹窗（keyWin=%@）", keyWin);
    } @catch (NSException *e) {
        ProbeLog(@"显示弹窗异常: %@", e.reason);
    } @catch (...) {
        ProbeLog(@"显示弹窗未知异常");
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    ProbeLog(@"===== SpringBoard applicationDidFinishLaunching 已触发 =====");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ProbeShowAlert();
    });
}

%end

%ctor {
    @autoreleasepool {
        @try {
            NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
            ProbeLog(@"===== VCamProbe 已注入 bundle=%@ pid=%d =====", bid, getpid());

            // 如果只注入 SpringBoard，%hook 已经生效；
            // 但对已启动的 SpringBoard（不是重启而是热加载的情况），
            // applicationDidFinishLaunching 不会再触发 —— 这时直接弹窗。
            if ([bid isEqualToString:@"com.apple.springboard"]) {
                ProbeLog(@"是 SpringBoard，2 秒后直接尝试弹窗（兼容热加载场景）");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ProbeShowAlert();
                });
            }
        } @catch (NSException *e) {
            ProbeLog(@"ctor 异常: %@", e.reason);
        } @catch (...) {
            ProbeLog(@"ctor 未知异常");
        }
    }
}
