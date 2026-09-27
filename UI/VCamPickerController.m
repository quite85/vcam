//
//  VCamPickerController.m
//  VCam
//

#import "VCamPickerController.h"
#import "VCamVolumeHook.h"
#import "VCamConfig.h"
#import "VCamHUD.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdlib.h>    // arc4random()

@interface VCamPickerController () <PHPickerViewControllerDelegate>
@property (nonatomic, copy, nullable) VCamPickerCompletion completion;
@property (nonatomic, assign) VCamPickerType type;
@property (nonatomic, strong, nullable) PHPickerViewController *picker;
@property (nonatomic, strong, nullable) UIWindow *pickerWindow;
@end

@implementation VCamPickerController

+ (instancetype)shared {
    static VCamPickerController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamPickerController alloc] init]; });
    return s;
}

+ (void)presentPickerWithType:(VCamPickerType)type completion:(VCamPickerCompletion)completion {
    VCamPickerController *p = [self shared];
    p.type = type;
    p.completion = completion;
    // 选择期间挂起音量键，避免误触
    [VCamVolumeHook suspend];
    [p _present];
}

- (void)_present {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 先确保相册权限（导出到本地文件需要）
        [self _ensurePhotoPermission:^(BOOL granted) {
            if (!granted) {
                NSError *e = [NSError errorWithDomain:@"com.quite85.vcam"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"没有相册权限。请到 设置 → 隐私 → 照片 里允许 VCam 访问。"}];
                [self _finishWithPath:nil isVideo:NO error:e];
                return;
            }
            [self _presentPickerNow];
        }];
    });
}

- (void)_ensurePhotoPermission:(void (^)(BOOL))done {
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) {
        done(YES);
        return;
    }
    if (st == PHAuthorizationStatusDenied || st == PHAuthorizationStatusRestricted) {
        done(NO);
        return;
    }
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                               handler:^(PHAuthorizationStatus s) {
        done(s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited);
    }];
}

- (void)_presentPickerNow {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = 1;
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    if (self.type == VCamPickerTypeVideo) {
        config.filter = [PHPickerFilter videosFilter];
    } else {
        config.filter = [PHPickerFilter imagesFilter];
    }

    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:config];
    vc.delegate = self;
    self.picker = vc;

    // 用独立 window 呈现：SpringBoard 里没有现成的 key window 可以 present
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
    w.windowLevel = UIWindowLevelAlert + 500;
    w.rootViewController = [[UIViewController alloc] init];
    w.hidden = NO;
    self.pickerWindow = w;
    [w.rootViewController presentViewController:vc animated:YES completion:nil];
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.pickerWindow.hidden = YES;
        self.pickerWindow = nil;
        self.picker = nil;
    });

    if (results.count == 0) {
        [self _finishWithPath:nil isVideo:NO error:nil];   // 用户取消
        return;
    }

    PHPickerResult *r = results.firstObject;
    NSItemProvider *provider = r.itemProvider;
    BOOL isVideo = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier] ||
                   [provider hasItemConformingToTypeIdentifier:UTTypeVideo.identifier];

    [VCamHUD show:@"正在导入…" success:YES];

    if (isVideo) {
        [self _importVideoFromProvider:provider];
    } else {
        [self _importImageFromProvider:provider];
    }
}

#pragma mark - 导出：视频

- (void)_importVideoFromProvider:(NSItemProvider *)provider {
    NSString *typeID = UTTypeMovie.identifier;
    if (![provider hasItemConformingToTypeIdentifier:typeID]) {
        typeID = UTTypeVideo.identifier;
    }
    [provider loadFileRepresentationForTypeIdentifier:typeID
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (error || !url) {
            [self _finishWithPath:nil isVideo:YES error:error ?: [self _err:@"视频读取失败"]];
            return;
        }
        // PHPicker 给的临时 URL 在选择器关闭后就失效，必须立刻拷走。
        // 这里同时做一次"重封装"：把 HEVC/ProRes 等转成 H.264+AAC 的 mp4，
        // 保证 mediaserverd 侧 AVPlayer 一定能解，也避免某些格式 seek 慢导致循环卡顿。
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"vcam_import_%u.mov", arc4random()]];
        NSError *copyErr = nil;
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp]
                                                    error:&copyErr]) {
            [self _finishWithPath:nil isVideo:YES error:copyErr];
            return;
        }
        [self _transcodeIfNeededThenFinish:tmp];
    }];
}

- (void)_transcodeIfNeededThenFinish:(NSString *)srcPath {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:srcPath] options:nil];
    AVAssetTrack *vTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!vTrack) {
        [self _finishWithPath:nil isVideo:YES error:[self _err:@"这个文件里没有视频轨"]];
        return;
    }
    NSString *codec = [vTrack.formatDescriptions.firstObject description] ?: @"";
    NSString *out = [VCamAssetCacheDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"video_%@.mp4", [self _stamp]]];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];

    // 已经是 H.264/HEVC 且容器是 mp4/mov 的，直接拷过去当资源（省时间、不损失画质）
    BOOL isH264 = [codec containsString:@"H.264"] || [codec containsString:@"avc1"];
    if (isH264) {
        NSError *e = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:out error:&e]) {
            [[NSFileManager defaultManager] removeItemAtPath:srcPath error:NULL];
            VCamLog(@"[picker] 视频直接使用（H.264）: %@", out.lastPathComponent);
            [self _finishWithPath:out isVideo:YES error:nil];
            return;
        }
    }

    // 否则转码：H.264 + AAC，最高 1080p
    AVAssetExportSession *exporter =
        [[AVAssetExportSession alloc] initWithAsset:asset
                                         presetName:AVAssetExportPreset1280x720];
    if (!exporter) {
        exporter = [[AVAssetExportSession alloc] initWithAsset:asset
                                                   presetName:AVAssetExportPresetMediumQuality];
    }
    if (!exporter) {
        // 实在无法转码：直接用原文件（大部分情况也能播）
        NSError *e = nil;
        NSString *fallback = [VCamAssetCacheDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"video_%@.mov", [self _stamp]]];
        [[NSFileManager defaultManager] removeItemAtPath:fallback error:NULL];
        [[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:fallback error:&e];
        [[NSFileManager defaultManager] removeItemAtPath:srcPath error:NULL];
        [self _finishWithPath:e ? nil : fallback isVideo:YES error:e];
        return;
    }
    exporter.outputURL = [NSURL fileURLWithPath:out];
    exporter.outputFileType = AVFileTypeMPEG4;
    exporter.shouldOptimizeForNetworkUse = NO;
    exporter.timeRange = CMTimeRangeMake(kCMTimeZero,
        CMTimeMinimum(asset.duration, CMTimeMakeWithSeconds(600, 600)));  // 最长 10 分钟

    [exporter exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:srcPath error:NULL];
            if (exporter.status == AVAssetExportSessionStatusCompleted) {
                VCamLog(@"[picker] 视频转码完成: %@", out.lastPathComponent);
                [self _finishWithPath:out isVideo:YES error:nil];
            } else {
                [self _finishWithPath:nil isVideo:YES
                                error:exporter.error ?: [self _err:@"视频转码失败"]];
            }
        });
    }];
}

#pragma mark - 导出：图片

- (void)_importImageFromProvider:(NSItemProvider *)provider {
    if ([provider canLoadObjectOfClass:UIImage.class]) {
        [provider loadObjectOfClass:UIImage.class
                  completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || ![object isKindOfClass:UIImage.class]) {
                    [self _finishWithPath:nil isVideo:NO
                                    error:error ?: [self _err:@"图片读取失败"]];
                    return;
                }
                [self _saveImage:(UIImage *)object];
            });
        }];
        return;
    }
    [provider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier
                                   completionHandler:^(NSData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *img = data ? [UIImage imageWithData:data] : nil;
            if (!img) {
                [self _finishWithPath:nil isVideo:NO error:error ?: [self _err:@"图片解码失败"]];
                return;
            }
            [self _saveImage:img];
        });
    }];
}

- (void)_saveImage:(UIImage *)image {
    // 统一存成 JPEG：
    //  1) HEIC 在 mediaserverd 里解码路径较长；
    //  2) 存成 JPEG 时已经把 EXIF 方向烘焙进像素，避免旋转两次；
    //  3) 顺带限制最长边到 2560，控制内存。
    CGFloat maxSide = 2560;
    CGFloat w = image.size.width, h = image.size.height;
    if (MAX(w, h) > maxSide) {
        CGFloat s = maxSide / MAX(w, h);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = 1.0;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
            initWithSize:CGSizeMake(w * s, h * s) format:fmt];
        image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [image drawInRect:CGRectMake(0, 0, w * s, h * s)];
        }];
    }
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
    if (!jpeg) {
        [self _finishWithPath:nil isVideo:NO error:[self _err:@"图片编码失败"]];
        return;
    }
    NSString *out = [VCamAssetCacheDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"image_%@.jpg", [self _stamp]]];
    NSError *e = nil;
    if (![jpeg writeToFile:out options:NSDataWritingAtomic error:&e]) {
        [self _finishWithPath:nil isVideo:NO error:e];
        return;
    }
    // 清理旧资源，避免越用越占空间
    [self _pruneOldAssetsKeeping:out];
    [self _finishWithPath:out isVideo:NO error:nil];
}

#pragma mark - 工具

- (NSString *)_stamp {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMddHHmmss";
    return [df stringFromDate:NSDate.date];
}

- (NSError *)_err:(NSString *)msg {
    return [NSError errorWithDomain:@"com.quite85.vcam" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

/// 只保留最近 4 个资源文件
- (void)_pruneOldAssetsKeeping:(NSString *)keep {
    NSString *dir = VCamAssetCacheDirectory();
    NSArray<NSString *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray<NSString *> *full = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasPrefix:@"."]) continue;
        [full addObject:[dir stringByAppendingPathComponent:f]];
    }
    [full sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [[NSFileManager defaultManager] attributesOfItemAtPath:a error:NULL][NSFileModificationDate];
        NSDate *db = [[NSFileManager defaultManager] attributesOfItemAtPath:b error:NULL][NSFileModificationDate];
        return [db compare:da];    // 新的在前
    }];
    for (NSUInteger i = 4; i < full.count; i++) {
        if ([full[i] isEqualToString:keep]) continue;
        [[NSFileManager defaultManager] removeItemAtPath:full[i] error:NULL];
    }
}

- (void)_finishWithPath:(NSString *)path isVideo:(BOOL)isVideo error:(NSError *)error {
    [VCamVolumeHook resume];
    VCamPickerCompletion done = self.completion;
    self.completion = nil;
    if (done) done(path, isVideo, error);
}

@end
