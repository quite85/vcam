//
//  VCamPickerController.h
//  VCam
//
//  相册选择（视频 / 图片）。
//
//  为什么用 PHPickerViewController：
//   - iOS 14+ 官方推荐，无需相册权限即可选择（由系统进程代读）；
//   - 支持直接拿到 UTType，视频/图片判断简单；
//   - 不会像 UIImagePickerController 那样"接管整个相机 UI"。
//
//  但我们仍然请求相册权限：因为要"导出到本地文件"给 mediaserverd 读，
//  mediaserverd 没有 PHPicker 提供的临时授权（那个授权只给调用进程，
//  而且只在当前会话有效）。所以流程是：
//    PHPicker 选 → 在 SpringBoard 进程内导出到
//    /var/mobile/Library/VCam/assets/ → mediaserverd 读本地文件
//  这样 mediaserverd 不需要任何相册权限。
//

#ifndef VCAM_PICKER_CONTROLLER_H
#define VCAM_PICKER_CONTROLLER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCamPickerType) {
    VCamPickerTypeVideo = 0,
    VCamPickerTypeImage = 1,
};

/// completion: path = 导出后的本地文件路径；isVideo = 是否视频；error = 失败原因
typedef void (^VCamPickerCompletion)(NSString *_Nullable path,
                                     BOOL isVideo,
                                     NSError *_Nullable error);

@interface VCamPickerController : NSObject

+ (void)presentPickerWithType:(VCamPickerType)type
                   completion:(VCamPickerCompletion)completion;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAM_PICKER_CONTROLLER_H */
