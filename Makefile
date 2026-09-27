# ============================================================================
#  VCam —— 系统级虚拟摄像头 + 虚拟麦克风越狱插件
#  Makefile (Theos)
#
#  支持：
#    - rootful  (iphoneos-arm64)   安装到 /Library/MobileSubstrate/DynamicLibraries
#    - rootless (iphoneos-arm64)   安装到 /var/jb/Library/MobileSubstrate/DynamicLibraries
#    - roothide                    用 roothide 的 Theos 分支或 Patcher 处理
#
#  架构说明：
#    VCamCore 编译为静态库，被主 tweak（以及可选 Prefs）复用。
#    THEOS_PACKAGE_SCHEME=rootless 时 Theos 会自动给所有安装路径加 /var/jb 前缀。
#
#  常用命令：
#    make package                                    # 打 rootful 包
#    make package THEOS_PACKAGE_SCHEME=rootless      # 打 rootless 包
#    ./scripts/build.sh                              # 一次同时打两个 deb（推荐）
#    VCAM_ENABLE_OBS=0 make package                  # 不带 FFmpeg 的轻量包
#
#  注意：control / control-rootless 两个文件都在仓库根目录，
#        Theos 会按 scheme 自动挑选（rootless -> control-rootless）。
# ============================================================================

export ARCHS        = arm64 arm64e
export TARGET       = iphone:clang:latest:15.0
export PACKAGE_BUILDNAME = vcam

# ---------------------------------------------------------------------------
# 编译用 SDK 版本
# ---------------------------------------------------------------------------
# Theos **不自带** iOS SDK，它只在 $THEOS/sdks/ 和 Xcode 内部找。
# GitHub 的 macOS 运行器上两处都没有 iPhoneOS SDK，
# 所以 CI 必须先下载 SDK 到 $THEOS/sdks/，否则 make 会在 before-all 阶段
# 直接报「You do not have any SDKs in ...」并以 exit 1 结束。
#
# 本机（macOS）开发时不要设这个变量：Theos 会 fallback 到 Xcode 自带的 SDK。
# CI 里通过环境变量 VCAM_SDK_VERSION=16.5 指定，scripts/build.sh 会传进来。
ifneq ($(VCAM_SDK_VERSION),)
  export SDKVERSION = $(VCAM_SDK_VERSION)
endif

# ---------------------------------------------------------------------------
# 用户可改的变量
# ---------------------------------------------------------------------------
# 反转域名。改这里的同时也要改 control / control-rootless 的 Package 行
export VCAM_PKG_ID     ?= com.quite85.vcam
# 是否编译 OBS(FFmpeg) 支持。0 时 OBS 菜单项会提示"本包未编译 OBS 支持"
export VCAM_ENABLE_OBS ?= 1
# 是否附带 PreferenceLoader 设置面板（默认关，主交互走音量键悬浮窗）
export VCAM_BUILD_PREFS ?= 0

ifeq ($(THEOS),)
$(error 未找到 THEOS。请先安装 Theos 并 export THEOS=/opt/theos)
endif

# 说明：control 文件的切换由 scripts/build.sh 负责 ——
#   rootful  -> 把 control-rootful 拷成 ./control
#   rootless -> 把 control-rootless 拷成 ./control
#   （Theos 只会读根目录的 ./control，不区分 scheme）
# 只想手动打一个包时也请照做，例如：
#   cp control-rootless control && make package THEOS_PACKAGE_SCHEME=rootless
include $(THEOS)/makefiles/common.mk

# ===========================================================================
# 1) VCamCore —— 共享静态库（帧源 / 状态 / 解码 / 工具）
# ===========================================================================
LIBRARY_NAME = VCamCore

VCamCore_FILES = \
    Core/VCamConfig.m \
    Core/VCamStateStore.m \
    Core/VCamPixelBufferUtils.m \
    Core/VCamFrameSource.m \
    Core/VCamImageSource.m \
    Core/VCamVideoSource.m \
    Core/VCamConcurrentQueue.m \
    Core/VCamOBSAddress.m \
    Core/VCamCore.m

ifeq ($(VCAM_ENABLE_OBS),1)
VCamCore_FILES += \
    Core/VCamTSDemuxer.m \
    Core/VCamOBSAudioDecoder.m \
    Core/VCamVideoToolboxDecoder.m \
    Core/VCamOBSSource.m
VCamCore_CFLAGS = -DVCAM_ENABLE_OBS=1
else
VCamCore_FILES += Core/VCamOBSSource_stub.m
VCamCore_CFLAGS = -DVCAM_ENABLE_OBS=0
endif

VCamCore_CFLAGS += -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable \
                   -Wno-unused-function -Wno-nullability-completeness \
                   -Wno-objc-method-access -Wno-shadow -Wno-unused-parameter \
                   -Wno-unguarded-availability-new \
                   -DVCAM_PKG_ID=\"$(VCAM_PKG_ID)\"
VCamCore_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo \
                      AudioToolbox VideoToolbox CoreImage ImageIO Photos
VCamCore_LIBRARIES = z bz2
ifeq ($(VCAM_ENABLE_OBS),1)
# FFmpeg 只用于 mpegts demux 与 h264/aac parser，不需要编码器。
# 构建方法见 scripts/ffmpeg-deps.sh
VCamCore_EXTRA_FRAMEWORKS = avformat avcodec avutil swresample
VCamCore_CFLAGS += -I$(THEOS)/vendor/include/ffmpeg
VCamCore_LDFLAGS = -L$(THEOS)/vendor/lib
endif

include $(THEOS_MAKE_PATH)/library.mk

# ===========================================================================
# 2) VCam —— 主 tweak（UI + hook + 注入）
# ===========================================================================
TWEAK_NAME = VCam

VCam_FILES = \
    Tweak.x \
    UI/VCamPanel.m \
    UI/VCamPickerController.m \
    UI/VCamHUD.m \
    UI/VCamVolumeHook.m \
    UI/VCamVideoDataOutputProxy.m \
    UI/VCamPreviewOverlay.m \
    Media/VCamPhotoOutputInjector.m \
    Media/VCamMovieFileInjector.m \
    Mic/VCamMicInjector.m

# 说明：这里刻意 **不** 链接 libsubstrate。
#   - Logos 的 %hook 走的是运行时 class_replaceMethod / MSHookFunction（dlsym 拿），
#     不需要链接期符号；
#   - 手工的 swizzle 全用 Objective-C runtime API；
#   - 私有 C 符号的 hook 在 Tweak.x 里用 dlsym(RTLD_DEFAULT, "MSHookFunction")。
# 这样在 rootful / rootless / roothide 三种环境下都不会因为库路径不同而链接失败。
VCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable \
              -Wno-unused-function -Wno-nullability-completeness \
              -Wno-objc-method-access -Wno-shadow -Wno-unused-parameter \
              -Wno-unguarded-availability-new \
              -I$(THEOS_PROJECT_DIR) \
              -DVCAM_ENABLE_OBS=$(VCAM_ENABLE_OBS) \
              -DVCAM_PKG_ID=\"$(VCAM_PKG_ID)\"

VCam_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo \
                  AudioToolbox Accelerate QuartzCore MediaPlayer PhotosUI \
                  Photos ImageIO
VCam_LIBRARIES = VCamCore

include $(THEOS_MAKE_PATH)/tweak.mk

# ===========================================================================
# 3) VCamPrefs —— 可选的 PreferenceLoader 设置面板
# ===========================================================================
ifeq ($(VCAM_BUILD_PREFS),1)
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
endif

# ===========================================================================
# 4) 打包提示
# ===========================================================================
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  _VCAM_ARCH_TAG = iphoneos-arm64-rootless
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
  _VCAM_ARCH_TAG = iphoneos-arm64-roothide
else
  _VCAM_ARCH_TAG = iphoneos-arm64-rootful
endif

after-package::
	@echo ""
	@echo "==============================================================="
	@echo " VCam 打包完成   架构标记: $(_VCAM_ARCH_TAG)"
	@echo " deb 输出目录: $(THEOS)/packages 或 ./packages"
	@echo " 下一步: ./scripts/build.sh && ./scripts/make-repo.sh"
	@echo "==============================================================="
