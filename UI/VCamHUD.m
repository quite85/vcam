//
//  VCamHUD.m
//  VCam
//

#import "VCamHUD.h"
#import <UIKit/UIKit.h>

@implementation VCamHUD

static UIWindow *gHUDWindow = nil;
static UIView *gToast = nil;

+ (void)show:(NSString *)text success:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _ensureWindow];
        for (UIView *v in [gHUDWindow.rootViewController.view.subviews copy]) {
            [v removeFromSuperview];
        }
        UIView *toast = [self _makeToast:text success:success];
        [gHUDWindow.rootViewController.view addSubview:toast];
        gToast = toast;

        // 放到屏幕顶部偏下，避开状态栏与灵动岛
        CGSize screen = UIScreen.mainScreen.bounds.size;
        toast.center = CGPointMake(screen.width / 2.0, 120);
        toast.alpha = 0;
        toast.transform = CGAffineTransformMakeTranslation(0, -12);
        [UIView animateWithDuration:0.22 animations:^{
            toast.alpha = 1;
            toast.transform = CGAffineTransformIdentity;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (toast != gToast) return;
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0;
                toast.transform = CGAffineTransformMakeTranslation(0, -10);
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
                gToast = nil;
            }];
        });
    });
}

+ (void)showPersistent:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _ensureWindow];
        for (UIView *v in [gHUDWindow.rootViewController.view.subviews copy]) {
            [v removeFromSuperview];
        }
        UIView *toast = [self _makeToast:text success:YES];
        [gHUDWindow.rootViewController.view addSubview:toast];
        gToast = toast;
        CGSize screen = UIScreen.mainScreen.bounds.size;
        toast.center = CGPointMake(screen.width / 2.0, 120);
        toast.alpha = 0;
        [UIView animateWithDuration:0.22 animations:^{ toast.alpha = 1; }];
    });
}

+ (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ gToast.alpha = 0; }
                         completion:^(BOOL finished) {
            [gToast removeFromSuperview];
            gToast = nil;
        }];
    });
}

#pragma mark - 内部

+ (void)_ensureWindow {
    if (gHUDWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.frame = UIScreen.mainScreen.bounds;
    w.windowLevel = UIWindowLevelAlert + 2000;
    w.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = NO;      // 绝不拦截触摸
    w.rootViewController = [[UIViewController alloc] init];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.hidden = NO;
    gHUDWindow = w;
}

+ (UIView *)_makeToast:(NSString *)text success:(BOOL)success {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    container.layer.cornerRadius = 12;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 0.5;
    container.layer.borderColor = (success
        ? [UIColor colorWithRed:0.3 green:0.8 blue:0.45 alpha:0.8]
        : [UIColor colorWithRed:0.9 green:0.35 blue:0.3 alpha:0.8]).CGColor;

    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithFormat:@"%@  %@", success ? @"✅" : @"⚠️", text];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
    ]];

    CGSize maxSize = CGSizeMake(UIScreen.mainScreen.bounds.size.width - 60, 400);
    CGSize fit = [container systemLayoutSizeFittingSize:maxSize
                          withHorizontalFittingPriority:UILayoutPriorityDefaultHigh
                                verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    container.frame = CGRectMake(0, 0, MIN(maxSize.width, fit.width), fit.height);
    return container;
}

@end
