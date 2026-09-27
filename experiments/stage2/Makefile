TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# ---------------------------------------------------------------------------
# Stage2 —— 基于开源项目验证过的做法，做最小可用版本
# ---------------------------------------------------------------------------
# 设计依据（参考两个真实开源 iOS 虚拟摄像头项目）
#
#   lxxsoufahk/VCam 的 filter：
#       Bundles:     com.apple.UIKit
#       Executables: SpringBoard
#     → 只注入 SpringBoard 一个进程，注入面极小。
#
#   MurkAskA01/ios-vcam 的 filter：
#       Classes: AVCaptureSession / AVCaptureDevice /
#                AVCaptureVideoPreviewLayer / AVCaptureVideoDataOutput /
#                AVCapturePhotoOutput
#
# 本工程之前的问题：filter 列了 111 个条目 + 7 个系统守护进程
# （mediaserverd / camerad / audioaccessoryd…），注入面太大，崩溃面也大。
#
# Stage2 的做法：
#   · filter **只列 3 个 Bundle**：SpringBoard / Safari / Preferences
#   · **完全不注入任何系统守护进程**（不打 mediaserverd filter）
#   · 每个 hook/install 都包在 @try/@catch 里，抛异常只记录不崩溃
#   · 每一步都 NSLog，电脑上能实时看到走到哪一步
#
# Linux 本地交叉编译修正（仅在包装脚本存在时生效）。
ifneq ($(wildcard /usr/local/bin/vcam-link),)
  TARGET_LD = /usr/local/bin/vcam-link
  _THEOS_TARGET_SDK_BIN_PREFIX :=
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam
VCam_FILES = Stage2.x
VCam_CFLAGS = -fobjc-arc -Wno-everything
VCam_FRAMEWORKS = Foundation UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
