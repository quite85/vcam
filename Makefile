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
export VCAM_PKG_ID     ?= com.quite85.virtualcamera
# 是否编译 OBS(FFmpeg) 支持。0 时 OBS 菜单项会提示"本包未编译 OBS 支持"
export VCAM_ENABLE_OBS ?= 1
# 是否附带 PreferenceLoader 设置面板（默认关，主交互走音量键悬浮窗）
export VCAM_BUILD_PREFS ?= 0
# Logos 代码生成器。
#   留空（默认）= MobileSubstrate 生成器，产物调用 MSHookMessageEx，
#                会写入 .linker_option "-framework CydiaSubstrate"。
#                Dopamine 的 ElleKit 自带该兼容层，这是经过最多验证的路径。
#   internal   = 纯 Objective-C runtime 实现（class_replaceMethod /
#                method_setImplementation），不依赖任何 hook 框架。
#                链接期报找不到 CydiaSubstrate 时打开它。
# export LOGOS_DEFAULT_GENERATOR = internal

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
# 1) 关于「VCamCore 静态库」的说明（已改为直接编进 tweak）
# ===========================================================================
# 原来这里是：
#     LIBRARY_NAME = VCamCore
#     ...
#     include $(THEOS_MAKE_PATH)/library.mk
# 主 tweak 里用 VCam_LIBRARIES = VCamCore 链接它。
#
# 实际构建时报：
#     ==> Linking tweak VCam (arm64)…
#     ld: library 'VCamCore' not found
#     clang: error: linker command failed with exit code 1
#
# 原因（已核对 Theos 2.5 的 makefiles）：
#   · library.mk 第 22 行
#       _LOCAL_LINKAGE_TYPE = $(or $($(INSTANCE)_LINKAGE_TYPE),$(THEOS_LINKAGE_TYPE))
#     common.mk 第 297 行
#       THEOS_LINKAGE_TYPE ?= dynamic
#     即默认产出的是 **动态库 VCamCore.dylib**，而 VCam_LIBRARIES 展开成
#     -lVCamCore，链接器找不到 libVCamCore.a，于是失败。
#     构建日志也印证了这点：只有 Linking / Stripping / Signing 这些
#     动态库才有的步骤，**从未出现任何 .a 归档**。
#   · 看起来可以用 VCamCore_LINKAGE_TYPE = static 让它产出 .a，
#     但 rules.mk 里负责生成归档的那条规则被
#         ifeq ($(_THEOS_LIBRARY_TYPE),static)
#     包住，而 _THEOS_LIBRARY_TYPE **在整个 Theos 里只被读取、从未被赋值**
#     （全仓库搜索只命中 rules.mk:551 一处），条件永远为假 ——
#     也就是说那条静态归档分支是不可达的死代码。因此这条捷径并不可靠。
#
# 结论：不使用 Theos 的 library 机制，把 Core 的源码直接编进主 tweak。
#   · 少一层跨目标依赖，链接错误从设计上消失
#   · VCamCore 的每个源文件本来就只被 libtweak 这一处使用
#   · Core 里的类名/文件名保持不变（VCamCore.h / VCamCore.m 仍存在），
#     只是它们随主 tweak 一起编译，不再单独打成一个库
# ===========================================================================

# ===========================================================================
# 2) VCam —— 主 tweak（Core + UI + Media + Mic + hook）
# ===========================================================================
TWEAK_NAME = VCam

VCam_FILES = \
    Tweak.x \
    Core/VCamConfig.m \
    Core/VCamStateStore.m \
    Core/VCamPixelBufferUtils.m \
    Core/VCamFrameSource.m \
    Core/VCamImageSource.m \
    Core/VCamVideoSource.m \
    Core/VCamConcurrentQueue.m \
    Core/VCamOBSAddress.m \
    Core/VCamCore.m \
    UI/VCamPanel.m \
    UI/VCamPickerController.m \
    UI/VCamHUD.m \
    UI/VCamVolumeHook.m \
    UI/VCamVideoDataOutputProxy.m \
    UI/VCamPreviewOverlay.m \
    Media/VCamPhotoOutputInjector.m \
    Media/VCamMovieFileInjector.m \
    Mic/VCamMicInjector.m

# OBS 支持（可选）：VCAM_ENABLE_OBS=0 时用 stub 顶替整个 OBS 模块
ifeq ($(VCAM_ENABLE_OBS),1)
VCam_FILES += \
    Core/VCamTSDemuxer.m \
    Core/VCamOBSAudioDecoder.m \
    Core/VCamVideoToolboxDecoder.m \
    Core/VCamOBSSource.m
VCAM_OBS_DEFINE = 1
else
VCam_FILES += Core/VCamOBSSource_stub.m
VCAM_OBS_DEFINE = 0
endif

# ---------------------------------------------------------------------------
# include 路径
# ---------------------------------------------------------------------------
# 项目里跨目录使用引号 import，例如：
#     UI/VCamPanel.h                →  #import "VCamConfig.h"      （在 Core/）
#     Media/VCamMovieFileInjector.m →  #import "VCamCore.h"         （在 Core/）
#     Mic/VCamMicInjector.m         →  #import "VCamPreviewOverlay.h"（在 UI/）
# 引号 import 只在「当前文件所在目录」和 -I 指定的目录里查找，
# 不加这些 -I 就会报：
#     UI/VCamPanel.h:17:9: fatal error: 'VCamConfig.h' file not found
# Tweak.x 在仓库根目录，其余源文件在四个子目录里，所以全部加进来。
#
# 说明：这里刻意 **不** 链接 libsubstrate。
#   · Logos 的 %hook 走运行时 class_replaceMethod / MSHookFunction
#   · 手工 swizzle 全用 Objective-C runtime API
#   · 私有 C 符号的 hook 用 dlsym(RTLD_DEFAULT, "MSHookFunction")
# 这样 rootful / rootless / roothide 三种环境都不会因库路径不同而失败。
VCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable \
              -Wno-unused-function -Wno-nullability-completeness \
              -Wno-objc-method-access -Wno-shadow -Wno-unused-parameter \
              -Wno-unguarded-availability-new \
              -I$(THEOS_PROJECT_DIR) -ICore -IUI -IMedia -IMic \
              -DVCAM_ENABLE_OBS=$(VCAM_OBS_DEFINE) \
              -DVCAM_PKG_ID=\"$(VCAM_PKG_ID)\"

VCam_PRIVATE_FRAMEWORKS = MediaToolbox

ifeq ($(VCAM_ENABLE_OBS),1)
# FFmpeg 只用于 mpegts demux 与 h264/aac parser，不需要编码器。
# 构建方法见 scripts/ffmpeg-deps.sh
VCam_EXTRA_FRAMEWORKS = avformat avcodec avutil swresample
VCam_CFLAGS += -I$(THEOS)/vendor/include/ffmpeg
VCam_LDFLAGS = -L$(THEOS)/vendor/lib
endif

VCam_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo \
                  AudioToolbox Accelerate QuartzCore MediaPlayer PhotosUI \
                  Photos ImageIO

# 注意：这里**没有** VCam_LIBRARIES = VCamCore。
# Core 的源码已经直接编进本 target（见上面的 VCam_FILES），
# 不需要也无法再链接一个名为 VCamCore 的库。
# 详见文件开头「关于 VCamCore 静态库的说明」。

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
