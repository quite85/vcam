# ============================================================================
#  虚拟摄像头 (VCam) —— iOS 15.0 - 16.6.1 虚拟相机越狱插件
#  Makefile (Theos)
#
#  支持：
#    - rootless (Dopamine / palera1n rootless / XinaA15)
#        安装到 /var/jb/Library/MobileSubstrate/DynamicLibraries
#    - rootful  (unc0ver / checkra1n / palera1n rootful)
#        安装到 /Library/MobileSubstrate/DynamicLibraries
#
#  常用命令：
#    make package                                    # 打 rootful 包
#    make package THEOS_PACKAGE_SCHEME=rootless      # 打 rootless 包
#    ./scripts/build.sh                              # 一次打两个 deb（推荐）
#
#  ============================================================================
#  设计说明（这一版是基于开源项目重写的）
#  ============================================================================
#  骨架参考了开源项目 lxxsoufahk/VCam：
#    · filter 用标准 XML plist，只列少量 Bundle（注入面小 = 崩溃面小）
#    · SpringBoard 里一个可拖动悬浮按钮 + UIAlertController 菜单
#    · AVAssetReader 解码相册视频，循环播放，PTS 重映射到墙上时间
#
#  但修掉了它的致命缺陷，并加了它没有的功能：
#    1) 帧替换改用"代理模式"（它用 %hook NSObject，实际从未生效）
#    2) 音量减触发（它只有悬浮按钮）
#    3) 失败时弹窗告知原因
#    4) 日志写文件 + NSLog
# ============================================================================

export ARCHS  = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

# ---------------------------------------------------------------------------
# SDK 版本
# ---------------------------------------------------------------------------
# Theos 不自带 iOS SDK，只在 $THEOS/sdks/ 与 Xcode 内部找。
# GitHub 的 macOS 运行器两处都没有，所以 CI 必须先下载 SDK 到 $THEOS/sdks/，
# 否则 make 会在 before-all 阶段报「You do not have any SDKs in ...」。
# 本机 macOS 开发不要设这个变量（会 fallback 到 Xcode 自带 SDK）。
ifneq ($(VCAM_SDK_VERSION),)
  export SDKVERSION = $(VCAM_SDK_VERSION)
endif

# ---------------------------------------------------------------------------
# 包标识（改这里的同时也要改 control / control-rootless 的 Package 行）
# ---------------------------------------------------------------------------
export VCAM_PKG_ID ?= com.quite85.virtualcamera

# ---------------------------------------------------------------------------
# Linux 本地交叉编译修正
# ---------------------------------------------------------------------------
# 仅当包装脚本存在时生效（我在 WSL 里的验证环境）。
# macOS 上不存在该文件，所以这段对 CI 完全无影响。
#
# 背景：clang / clang++ 在 Apple 目标下默认 -fuse-ld=llvm，
#       Linux 上找不到叫这个名字的链接器就回退到 GNU ld，报：
#           /usr/bin/x86_64-linux-gnu-ld.bfd: unrecognised emulation mode: llvm
#       解决办法是用包装脚本强制 clang 使用 lld。
#
# ⚠️ 必须同时覆盖 TARGET_CC、TARGET_CXX、TARGET_LD 三个变量。
#    只设 TARGET_LD 是不够的 —— Theos 链接 C++ 目标时用的是 TARGET_CXX
#    （calls clang++），而 clang++ 自己也会去调 -fuse-ld=llvm。
#    这是踩过的坑：只设 TARGET_LD 时链接仍然报同一个错。
ifneq ($(wildcard /usr/local/bin/vcam-link),)
  TARGET_CC  = /usr/local/bin/vcam-link
  TARGET_CXX = /usr/local/bin/vcam-link
  TARGET_LD  = /usr/local/bin/vcam-link
  # Theos 的 toolchain 前缀会拼出 -fuse-ld=<bin>/arm64-apple-darwin14-ld，
  # 而 clang 只取最后一段当链接器名（得到 "ld"）→ 又调回 GNU ld。置空规避。
  _THEOS_TARGET_SDK_BIN_PREFIX :=
endif

include $(THEOS)/makefiles/common.mk

# ===========================================================================
#  主 tweak
# ===========================================================================
TWEAK_NAME = VCam

VCam_FILES = \
    Tweak.xm \
    src/VCamMediaManager.m \
    src/VCamFrameInjector.m

# -fobjc-arc：整个工程使用 ARC
# -Wno-...：屏蔽掉一批"不影响正确性但会因 -Werror 变成致命错误"的警告。
#           Theos 默认开 -Werror，这些警告（弃用 API、未使用变量等）
#           会让编译直接失败。
VCam_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-unused-function \
    -Wno-nullability-completeness \
    -Wno-objc-method-access \
    -Wno-shadow \
    -Wno-unused-parameter \
    -Wno-unguarded-availability-new \
    -I$(THEOS_PROJECT_DIR)/src

VCam_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo \
                  CoreImage QuartzCore Photos

# 不链接 libsubstrate / CydiaSubstrate：
#   Logos 的 %hook 走运行时 class_replaceMethod / MSHookFunction（dlsym 拿），
#   手工 swizzle 全用 Objective-C runtime API。
#   这样 rootful / rootless / roothide 三种环境都不会因库路径不同而链接失败。
# stdlib：Tweak.xm 被 Logos 按 Objective-C++ 编译，
# @catch(...) 会引入 std::terminate / __cxa_begin_catch 等 C++ 运行时符号。
# 不链接 libstdc++ 会报：
#     ld64.lld: error: undefined symbol: std::terminate()
#     ld64.lld: error: undefined symbol: __cxa_begin_catch
VCam_LIBRARIES = c++ c++abi

include $(THEOS_MAKE_PATH)/tweak.mk

# ===========================================================================
#  打包提示
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
	@echo " 虚拟摄像头 打包完成   架构标记: $(_VCAM_ARCH_TAG)"
	@echo " deb 输出目录: packages/ 或 \$$THEOS/packages"
	@echo " 下一步: ./scripts/build.sh && ./scripts/make-repo.sh"
	@echo "==============================================================="
