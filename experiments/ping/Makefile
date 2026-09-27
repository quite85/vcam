TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# ---------------------------------------------------------------------------
# Linux 本地交叉编译修正（重要）
# ---------------------------------------------------------------------------
# 现象：链接时 clang 报
#     /usr/bin/x86_64-linux-gnu-ld.bfd: unrecognised emulation mode: llvm
#
# 原因：clang 在 Apple 目标下默认尝试 -fuse-ld=llvm（即找 ld.llvm）。
#       Linux 的 clang 包通常没装那个名字的链接器，于是回退到系统 GNU ld，
#       而 GNU ld 不认 clang 传的 `-m llvm`，直接报错。
#       实测：单独跑
#           clang -target arm64-apple-ios15.0 -dynamiclib x.c -o x.dylib
#       也会失败，与 Theos 无关。
#
# 修法：把 TARGET_LD 显式指向 lld 的完整路径。linux.mk 里定义的是
#           TARGET_LD ?= $(TARGET_CC)
#       命令行赋值优先级最高，能可靠覆盖。
#
# 注意：只影响 **Linux 本地交叉编译**（WSL 里的验证环境）。
#       macOS 上的 CI 走 Darwin 目标，用 Xcode 自带链接器，不受影响。
# ---------------------------------------------------------------------------
TARGET_LD = /usr/bin/ld.lld

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPing
VCamPing_FILES = Ping.x
VCamPing_CFLAGS = -fobjc-arc
VCamPing_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	@echo "VCamPing 安装完成（只对「设置」App 生效）"