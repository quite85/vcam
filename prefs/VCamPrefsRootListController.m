//
//  VCamPrefsRootListController.m
//  VCam
//
//  设置面板：只放"适合慢慢调"的选项（端口、分辨率、唇形同步、降级开关）。
//  日常切换（图片/视频/OBS/禁用）请用音量减悬浮窗，快得多。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>

#define VCAM_STATE_PATH @"/var/mobile/Library/VCam/state.plist"
#define VCAM_NOTIFY "com.quite85.vcam/stateChanged"

@interface VCamPrefsRootListController : PSListController
@end

@implementation VCamPrefsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VCam 虚拟相机";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重载" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reloadState)];
}

- (NSDictionary *)_state {
    return [NSDictionary dictionaryWithContentsOfFile:VCAM_STATE_PATH] ?: @{};
}

- (void)_writeState:(NSDictionary *)state {
    NSMutableDictionary *d = [[self _state] mutableCopy] ?: [NSMutableDictionary dictionary];
    [d addEntriesFromDictionary:state];
    [d writeToFile:VCAM_STATE_PATH atomically:YES];
    // 通知所有进程状态已更新
    notify_post(VCAM_NOTIFY);
}

#pragma mark - 开关

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    return [self _state][key] ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if (!key) return;
    [self _writeState:@{key: value}];
}

#pragma mark - 动作

- (void)reloadState {
    notify_post(VCAM_NOTIFY);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已重载"
        message:@"所有进程已重新读取 VCam 配置。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)openLog {
    NSString *log = @"/var/mobile/Library/VCam/vcam.log";
    NSString *text = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) text = @"（日志为空）";
    // 只显示最后 8000 字符，避免超大日志卡住 UI
    if (text.length > 8000) text = [text substringFromIndex:text.length - 8000];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VCam 日志（末尾 8000 字）"
        message:text preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)clearLog {
    [@"" writeToFile:@"/var/mobile/Library/VCam/vcam.log" atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
    [self reloadState];
}

- (void)resetAll {
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_STATE_PATH error:NULL];
    notify_post(VCAM_NOTIFY);
    [self reloadState];
}

- (void)showDisclaimer {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"使用须知"
        message:@"VCam 用于个人内容创作、直播画面替代、或物理摄像头/麦克风损坏时的应急方案。\n\n"
                @"请自行遵守所使用 App 的服务条款与当地法律法规。本插件不含卡密、不联网授权、不上传任何信息。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
