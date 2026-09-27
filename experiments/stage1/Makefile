TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# ---------------------------------------------------------------------------
# 诊断构建 Stage 1
# ---------------------------------------------------------------------------
# 与主工程的三处关键差别：
#
# 1) **tweak 改名**：VCam → VirtualCamera
#    原因：用户手机上曾装过第三方闭源插件 com.vcam，它装的文件是
#        VCam.dylib / VCam.plist / VCamSB.dylib / VCamSB.plist
#    与本工程**完全同名**。即使卸载了，同名文件也可能残留并互相覆盖，
#    导致排查结果完全不可信（跑的可能一直是残留的旧插件）。
#    改成一个完全不同的名字，彻底消除这个变量。
#
# 2) **注入面缩到最小**：filter 只列 com.apple.Preferences（设置 App）
#    主工程的 VCam.plist 列了 111 个条目，另有 VCam-mediaserverd.plist
#    声明注入 mediaserverd / camerad / audioaccessoryd 等 7 个系统守护进程。
#    参考开源项目 lxxsoufahk/VCam，它的 filter 只有：
#        Bundles: com.apple.UIKit
#        Executables: SpringBoard
#    即"注入面尽量小"。注入面越大，崩溃面越大。
#    本阶段只注入设置 App —— 即使插件有严重问题，
#    最坏结果只是设置 App 打不开，**不会黑屏**（完全不碰 SpringBoard）。
#
# 3) **不打 mediaserverd filter**：layout 里什么都不放
#
# Linux 本地交叉编译修正（详见 Docs/LOCAL_BUILD.md）：
#   clang 在 Apple 目标下默认 -fuse-ld=llvm，Linux 上找不到就回退 GNU ld
#   并报 "unrecognised emulation mode: llvm"。用包装脚本作 TARGET_LD 解决。
TARGET_LD = /usr/local/bin/vcam-link
# Theos 的 toolchain 前缀会拼出 -fuse-ld=<bin>/arm64-apple-darwin14-ld，
# 而 clang 只取最后一段当链接器名（得到 "ld"）→ 又调回 GNU ld。置空规避。
_THEOS_TARGET_SDK_BIN_PREFIX :=

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VirtualCamera
VirtualCamera_FILES = Tweak.x

# 显式列出源文件，**不用 wildcard**。
# 原因：wildcard 会把 OBS 相关文件也编进来，而那些文件在
# VCAM_ENABLE_OBS=0 时不该参与编译：
#   · VCamTSDemuxer.m / VCamOBSAudioDecoder.m / VCamVideoToolboxDecoder.m
#     用到 libavformat、kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
#     kAudioConverterErr_NoMoreData 等只有完整 iOS SDK + FFmpeg 才有的符号
#   · VCAM_ENABLE_OBS=0 时应改用 VCamOBSSource_stub.m
# 主工程的 Makefile 就是这么做的（显式列举 + 按开关切换 stub），
# 这里对齐主工程，避免本地构建再踩同一个坑。
VirtualCamera_FILES += \
    Core/VCamConfig.m \
    Core/VCamStateStore.m \
    Core/VCamPixelBufferUtils.m \
    Core/VCamFrameSource.m \
    Core/VCamImageSource.m \
    Core/VCamVideoSource.m \
    Core/VCamConcurrentQueue.m \
    Core/VCamOBSAddress.m \
    Core/VCamCore.m \
    Core/VCamOBSSource_stub.m \
    UI/VCamPanel.m \
    UI/VCamPickerController.m \
    UI/VCamHUD.m \
    UI/VCamVolumeHook.m \
    UI/VCamVideoDataOutputProxy.m \
    UI/VCamPreviewOverlay.m \
    Media/VCamPhotoOutputInjector.m \
    Media/VCamMovieFileInjector.m \
    Mic/VCamMicInjector.m

VirtualCamera_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function \
    -Wno-nullability-completeness -Wno-objc-method-access -Wno-shadow \
    -Wno-unused-parameter -Wno-unguarded-availability-new \
    -I$(THEOS_PROJECT_DIR) -ICore -IUI -IMedia -IMic \
    -DVCAM_ENABLE_OBS=0 \
    -DVCAM_PKG_ID=\"com.quite85.vcamstage1\"

VirtualCamera_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo \
    AudioToolbox Accelerate QuartzCore MediaPlayer PhotosUI Photos ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk
