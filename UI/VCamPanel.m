//
//  VCamPanel.m
//  VCam
//
//  UI 实现说明：
//   - 用独立的 passthrough UIWindow（windowLevel = 10000001）承载面板，
//     优点：不受当前 App 的 key window 影响，所有 App 上都能显示，
//     并且通过 hitTest 只让面板区域接收触摸，其它区域穿透给下面的 App，
//     这样"不阻断当前 App"是天然成立的。
//   - 面板本身是 UIVisualEffectView，圆角 + 阴影，支持拖动与左右贴边。
//   - 所有控件用代码创建（不用 xib），因为 tweak 里加载资源包比较麻烦。
//

#import "VCamPanel.h"
#import "VCamPickerController.h"
#import "VCamCore.h"
#import "VCamOBSSource.h"
#import "VCamHUD.h"

#pragma mark - 承载窗口（空白区域穿透）

@interface VCamPassthroughWindow : UIWindow
@end

@implementation VCamPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中自己（也就是空白背景）时返回 nil，让触摸穿透到下层 App
    if (hit == self) return nil;
    return hit;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 让窗口只在自己有子视图并且子视图命中的时候才算"内部"
    for (UIView *sub in self.subviews) {
        if ([sub pointInside:[sub convertPoint:point fromView:self] withEvent:event]) {
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - 面板

/// 按钮样式（定义在 @interface 之前，避免前向引用）
typedef NS_ENUM(NSInteger, VCamButtonStyle) {
    VCamButtonStylePrimary,
    VCamButtonStyleSecondary,
    VCamButtonStyleActive,
    VCamButtonStyleDanger,
};

@interface VCamPanel ()
@property (nonatomic, strong, nullable) VCamPassthroughWindow *window;
@property (nonatomic, strong, nullable) UIVisualEffectView *panelView;
@property (nonatomic, strong, nullable) UILabel *statusLabel;
@property (nonatomic, strong, nullable) UILabel *addressLabel;
@property (nonatomic, strong, nullable) UIStackView *buttonStack;
@property (nonatomic, strong, nullable) UIButton *expandButton;
@property (nonatomic, assign) BOOL expanded;
@end

@implementation VCamPanel {
    CGPoint _panStartCenter;
}

+ (instancetype)shared {
    static VCamPanel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamPanel alloc] init]; });
    return s;
}

- (BOOL)isVisible { return self.window != nil && !self.window.hidden; }

#pragma mark - 预热 / 显示

- (void)prepare {
    // 提前创建窗口，第一次弹窗才不会有明显延迟
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.window) [self _buildWindow];
        // 状态变化时自动刷新文案
        [[VCamStateStore shared] observeChanges:^{
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStatus]; });
        }];
    });
}

- (void)toggle {
    if (self.isVisible) [self hide];
    else [self show];
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.window) [self _buildWindow];
        [self refreshStatus];
        self.window.hidden = NO;
        self.panelView.transform = CGAffineTransformMakeScale(0.85, 0.85);
        self.panelView.alpha = 0.0;
        [UIView animateWithDuration:0.22
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.panelView.transform = CGAffineTransformIdentity;
            self.panelView.alpha = 1.0;
        } completion:nil];
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.16 animations:^{
            self.panelView.alpha = 0.0;
            self.panelView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL finished) {
            self.window.hidden = YES;
            self.expanded = NO;
        }];
    });
}

#pragma mark - 构建

- (void)_buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    VCamPassthroughWindow *win = scene
        ? [[VCamPassthroughWindow alloc] initWithWindowScene:scene]
        : [[VCamPassthroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.frame = UIScreen.mainScreen.bounds;
    win.backgroundColor = UIColor.clearColor;
    win.windowLevel = UIWindowLevelAlert + 1000;   // 高于系统弹窗，保证相机 App 里也可见
    win.rootViewController = [[UIViewController alloc] init];
    win.rootViewController.view.backgroundColor = UIColor.clearColor;
    win.hidden = YES;
    self.window = win;

    // ---- 面板本体 ----
    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    panel.layer.cornerRadius = 18;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.clipsToBounds = YES;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    panel.translatesAutoresizingMaskIntoConstraints = YES;
    panel.frame = CGRectMake(16, 120, 232, 0);
    [win.rootViewController.view addSubview:panel];
    self.panelView = panel;

    // 拖动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(_handlePan:)];
    pan.maximumNumberOfTouches = 1;
    [panel addGestureRecognizer:pan];

    // ---- 标题行 ----
    UIView *content = panel.contentView;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCam 虚拟相机";
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.textColor = UIColor.whiteColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];

    UIButton *expand = [UIButton buttonWithType:UIButtonTypeSystem];
    [expand setTitle:@"⋯" forState:UIControlStateNormal];
    [expand setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
    expand.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    expand.translatesAutoresizingMaskIntoConstraints = NO;
    [expand addTarget:self action:@selector(_toggleExpand) forControlEvents:UIControlEventTouchUpInside];
    self.expandButton = expand;

    // ---- 状态 ----
    UILabel *status = [[UILabel alloc] init];
    status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    status.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    status.numberOfLines = 0;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;

    // ---- 地址（OBS 模式显示，可长按复制）----
    UILabel *addr = [[UILabel alloc] init];
    addr.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    addr.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1.0];
    addr.numberOfLines = 0;
    addr.userInteractionEnabled = YES;
    addr.translatesAutoresizingMaskIntoConstraints = NO;
    [addr addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
                                initWithTarget:self action:@selector(_copyAddress)]];
    self.addressLabel = addr;

    // ---- 按钮 ----
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.buttonStack = stack;

    for (UIView *v in @[title, close, expand, status, addr, stack]) {
        [content addSubview:v];
    }

    UILayoutGuide *g = content.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:g.topAnchor constant:2],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:expand.leadingAnchor constant:-6],

        [close.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:22],
        [close.heightAnchor constraintEqualToConstant:22],

        [expand.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-4],
        [expand.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [expand.widthAnchor constraintEqualToConstant:22],
        [expand.heightAnchor constraintEqualToConstant:22],

        [status.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],

        [addr.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [addr.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [addr.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:4],

        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:addr.bottomAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];

    [self _rebuildButtons];

    // 初始位置：左上，离状态栏一点距离
    panel.center = CGPointMake(16 + 232 / 2.0, 150);
    [panel layoutIfNeeded];
}

#pragma mark - 按钮

- (void)_rebuildButtons {
    for (UIView *v in [self.buttonStack.arrangedSubviews copy]) {
        [self.buttonStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    VCamMode mode = [VCamStateStore shared].mode;

    UIButton *video = [self _makeButton:@"🎬  选择视频（相册）"
                                 action:@selector(_pickVideo)
                                  style:VCamButtonStylePrimary];
    UIButton *image = [self _makeButton:@"🖼  选择图片（相册）"
                                 action:@selector(_pickImage)
                                  style:VCamButtonStylePrimary];
    UIButton *obs   = [self _makeButton:@"📡  电脑推流 / OBS"
                                 action:@selector(_startOBS)
                                  style:(mode == VCamModeOBS ? VCamButtonStyleActive : VCamButtonStylePrimary)];
    UIButton *off   = [self _makeButton:@"⛔️  禁用替换（恢复相机）"
                                 action:@selector(_disable)
                                  style:(mode == VCamModeDisabled ? VCamButtonStyleActive : VCamButtonStyleDanger)];

    [self.buttonStack addArrangedSubview:video];
    [self.buttonStack addArrangedSubview:image];
    [self.buttonStack addArrangedSubview:obs];
    [self.buttonStack addArrangedSubview:off];

    if (self.expanded) {
        BOOL mirror = [VCamStateStore shared].mirror;
        BOOL loop = [VCamStateStore shared].loop;
        NSInteger rot = [VCamStateStore shared].rotation;
        [self.buttonStack addArrangedSubview:
            [self _makeButton:[NSString stringWithFormat:@"↻  旋转 90°（当前 %ld°）", (long)rot]
                       action:@selector(_rotate) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:(mirror ? @"⇋  镜像：开" : @"⇋  镜像：关")
                       action:@selector(_toggleMirror) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:(loop ? @"🔁  循环：开" : @"🔁  循环：关")
                       action:@selector(_toggleLoop) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:@"🔊  唇形同步微调 (0/+40/-40ms)"
                       action:@selector(_cycleLipSync) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:@"📐  横屏/竖屏切换"
                       action:@selector(_toggleOrientation) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:@"📋  复制推流地址"
                       action:@selector(_copyAddress) style:VCamButtonStyleSecondary]];
        [self.buttonStack addArrangedSubview:
            [self _makeButton:@"🔄  重载虚拟源"
                       action:@selector(_reload) style:VCamButtonStyleSecondary]];
    }
}

- (UIButton *)_makeButton:(NSString *)title
                   action:(SEL)action
                    style:(VCamButtonStyle)style {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(9, 12, 9, 10);
    b.layer.cornerRadius = 10;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:34].active = YES;

    UIColor *bg = [UIColor colorWithWhite:1.0 alpha:0.10];
    UIColor *fg = UIColor.whiteColor;
    switch (style) {
        case VCamButtonStylePrimary:
            break;
        case VCamButtonStyleSecondary:
            bg = [UIColor colorWithWhite:1.0 alpha:0.06];
            fg = [UIColor colorWithWhite:1.0 alpha:0.85];
            break;
        case VCamButtonStyleActive:
            bg = [UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:0.85];
            break;
        case VCamButtonStyleDanger:
            bg = [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.30];
            fg = [UIColor colorWithRed:1.0 green:0.75 blue:0.75 alpha:1.0];
            break;
    }
    b.backgroundColor = bg;
    [b setTitleColor:fg forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 动作

- (void)_toggleExpand {
    self.expanded = !self.expanded;
    [self _rebuildButtons];
    [UIView animateWithDuration:0.2 animations:^{
        [self.panelView layoutIfNeeded];
    }];
    [self _resizeToFit];
}

- (void)_resizeToFit {
    [self.panelView layoutIfNeeded];
    CGSize fit = [self.panelView.systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGRect f = self.panelView.frame;
    f.size.width = 232;
    f.size.height = MAX(150, fit.height);
    self.panelView.frame = f;
}

- (void)_pickVideo {
    [self hide];
    [VCamPickerController presentPickerWithType:VCamPickerTypeVideo
                                     completion:^(NSString *path, BOOL isVideo, NSError *error) {
        if (error) {
            [VCamHUD show:[NSString stringWithFormat:@"导入失败：%@", error.localizedDescription]
                  success:NO];
            return;
        }
        [[VCamCore shared] setAssetPath:path isVideo:YES];
        [VCamHUD show:@"已切换为：相册视频循环" success:YES];
        [self show];
    }];
}

- (void)_pickImage {
    [self hide];
    [VCamPickerController presentPickerWithType:VCamPickerTypeImage
                                     completion:^(NSString *path, BOOL isVideo, NSError *error) {
        if (error) {
            [VCamHUD show:[NSString stringWithFormat:@"导入失败：%@", error.localizedDescription]
                  success:NO];
            return;
        }
        [[VCamCore shared] setAssetPath:path isVideo:NO];
        [VCamHUD show:@"已切换为：相册图片静帧" success:YES];
        [self show];
    }];
}

- (void)_startOBS {
    VCamStateStore *st = [VCamStateStore shared];
    [st setTransport:st.transport];
    [st setMode:VCamModeOBS];
    [st setAudioKind:VCamAudioSourceOBS];
    [[VCamCore shared] reloadFromState];

    NSString *url = [VCamOBSSource pushURLForTransport:st.transport port:st.port];
    UIPasteboard.generalPasteboard.string = url;
    [VCamHUD show:[NSString stringWithFormat:@"OBS 模式已开启\n推流地址（已复制）：\n%@", url]
          success:YES];
    [self _resizeToFit];
    [self refreshStatus];
}

- (void)_disable {
    VCamStateStore *st = [VCamStateStore shared];
    [st setMode:VCamModeDisabled];
    [st setAudioKind:VCamAudioSourceNone];
    [[VCamCore shared] teardown];
    [VCamHUD show:@"已恢复真实摄像头与麦克风" success:YES];
    [self refreshStatus];
}

- (void)_rotate {
    VCamStateStore *st = [VCamStateStore shared];
    NSInteger r = ([st rotation] + 90) % 360;
    [st setRotation:r];
    [[VCamCore shared] reloadFromState];
    [self _rebuildButtons];
    [self _resizeToFit];
    [self refreshStatus];
}

- (void)_toggleMirror {
    VCamStateStore *st = [VCamStateStore shared];
    [st setMirror:![st mirror]];
    [[VCamCore shared] reloadFromState];
    [self _rebuildButtons];
    [self refreshStatus];
}

- (void)_toggleLoop {
    VCamStateStore *st = [VCamStateStore shared];
    [st setLoop:![st loop]];
    [[VCamCore shared] reloadFromState];
    [self _rebuildButtons];
    [self refreshStatus];
}

- (void)_cycleLipSync {
    VCamStateStore *st = [VCamStateStore shared];
    NSInteger v = [st lipSyncMs];
    NSInteger next = (v == 0) ? 40 : (v == 40 ? -40 : 0);
    [st setLipSyncMs:next];
    [[VCamCore shared] reloadFromState];
    [VCamHUD show:[NSString stringWithFormat:@"唇形同步偏移：%+ld ms", (long)next] success:YES];
}

- (void)_toggleOrientation {
    // 竖屏 1080x1920 <-> 横屏 1920x1080
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL landscape = [d boolForKey:@"vcam_landscape"];
    [d setBool:!landscape forKey:@"vcam_landscape"];
    [[VCamCore shared] reloadFromState];
    [VCamHUD show:(!landscape ? @"已切换到横屏 1920x1080" : @"已切换到竖屏 1080x1920")
          success:YES];
}

- (void)_copyAddress {
    VCamStateStore *st = [VCamStateStore shared];
    NSString *url = [VCamOBSSource pushURLForTransport:st.transport port:st.port];
    UIPasteboard.generalPasteboard.string = url;
    [VCamHUD show:[NSString stringWithFormat:@"已复制：%@", url] success:YES];
}

- (void)_reload {
    [[VCamCore shared] reloadFromState];
    [self refreshStatus];
    [VCamHUD show:@"虚拟源已重载" success:YES];
}

#pragma mark - 状态刷新

- (void)refreshStatus {
    if (!self.statusLabel) return;
    VCamCore *core = [VCamCore shared];
    VCamStateStore *st = [VCamStateStore shared];

    BOOL active = core.active;
    NSString *dot = active ? @"🟢" : (st.mode == VCamModeDisabled ? @"⚪️" : @"🔴");
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ %@\n", dot, core.statusText];
    [s appendFormat:@"模式：%@", [self _modeName:st.mode]];
    if (st.mode == VCamModeVideo || st.mode == VCamModeImage) {
        NSString *name = st.assetPath.lastPathComponent;
        if (name.length) [s appendFormat:@"（%@）", name];
    }
    [s appendString:@"\n"];
    if ([st lastError].length > 0 && !active) {
        [s appendFormat:@"⚠️ %@\n", [st lastError]];
    }
    self.statusLabel.text = s;

    if (st.mode == VCamModeOBS) {
        NSString *url = [VCamOBSSource pushURLForTransport:st.transport port:st.port];
        NSArray<NSString *> *all = [VCamOBSSource localIPv4Addresses];
        NSMutableString *a = [NSMutableString string];
        [a appendFormat:@"推流地址（长按复制）\n%@\n", url];
        if (all.count > 1) {
            [a appendFormat:@"其它可用网卡：%@\n", [all componentsJoinedByString:@", "]];
        }
        [a appendString:@"OBS → 设置 → 输出 → 自定义输出(FFmpeg)\n容器 mpegts · libx264 · aac"];
        self.addressLabel.text = a;
        self.addressLabel.hidden = NO;
    } else {
        self.addressLabel.text = nil;
        self.addressLabel.hidden = YES;
    }
    [self _resizeToFit];
}

- (NSString *)_modeName:(VCamMode)m {
    switch (m) {
        case VCamModeDisabled: return @"已禁用（硬件）";
        case VCamModeImage:    return @"图片";
        case VCamModeVideo:    return @"视频";
        case VCamModeOBS:      return @"OBS 推流";
    }
    return @"未知";
}

#pragma mark - 拖动 / 贴边

- (void)_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = self.panelView;
    if (!v) return;
    CGPoint t = [pan translationInView:v.superview];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _panStartCenter = v.center;
            [UIView animateWithDuration:0.12 animations:^{
                v.transform = CGAffineTransformMakeScale(1.03, 1.03);
                v.alpha = 0.96;
            }];
            break;
        case UIGestureRecognizerStateChanged: {
            CGPoint c = CGPointMake(_panStartCenter.x + t.x, _panStartCenter.y + t.y);
            CGSize bounds = v.superview.bounds.size;
            CGFloat halfW = v.bounds.size.width / 2.0;
            CGFloat halfH = v.bounds.size.height / 2.0;
            // 允许部分出界，但保留可抓取区域
            c.x = MAX(halfW - 40, MIN(bounds.width - halfW + 40, c.x));
            c.y = MAX(halfH + 20, MIN(bounds.height - halfH - 20, c.y));
            v.center = c;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            [UIView animateWithDuration:0.2 animations:^{
                v.transform = CGAffineTransformIdentity;
                v.alpha = 1.0;
            }];
            // 贴边：靠近左右边缘则吸过去
            CGSize bounds = v.superview.bounds.size;
            CGFloat halfW = v.bounds.size.width / 2.0;
            CGFloat margin = 6;
            CGPoint c = v.center;
            CGFloat speed = [pan velocityInView:v.superview].x;
            BOOL toLeft = (c.x < bounds.width / 2.0);
            if (fabs(speed) > 300) toLeft = (speed < 0);
            c.x = toLeft ? (halfW + margin) : (bounds.width - halfW - margin);
            [UIView animateWithDuration:0.26
                                  delay:0
                 usingSpringWithDamping:0.85
                  initialSpringVelocity:0.3
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ v.center = c; }
                             completion:nil];
            break;
        }
        default:
            break;
    }
}

@end
