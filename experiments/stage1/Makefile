TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# ---------------------------------------------------------------------------
# Stage1 诊断包 —— **零 hook** 最小验证
# ---------------------------------------------------------------------------
# 目的：用一个"什么都不做"的 dylib，回答一个唯一的问题 ——
#
#     "把我们的 dylib 注入到一个普通 App 里，会不会出事？"
#
# 它做什么：
#   · filter 只列 com.apple.Preferences（设置 App）
#   · Tweak 里只有一个 %ctor，往 /var/mobile/Library/VirtualCamera/stage1.log
#     追加一行时间戳
#   · @try/@catch 包住全部逻辑
#
# 它**不做**什么（这是重点）：
#   · 不含任何 %hook —— 一行 hook 都没有
#   · 不 import AVFoundation / 不碰相机 / 不碰音频
#   · 不注入 SpringBoard、不注入 mediaserverd 等系统守护进程
#   · 不加载工程里的 Core/UI/Media/Mic 任何代码
#
# 为什么要先做这个：
#   此前四次黑屏，主工程带了大量 hook 与 111 项 filter，
#   无法区分"注入机制本身有问题"还是"某个 hook 有问题"。
#   这个包把变量降到只剩"注入机制"。
#
# 风险：filter 只列设置 App，且零 hook。
#       即使 dylib 加载有问题，最坏也只是设置 App 打不开，不会黑屏。

# Linux 本地交叉编译修正（仅在包装脚本存在时生效，macOS CI 不受影响）。
# 详见 Docs/LOCAL_BUILD.md。
ifneq ($(wildcard /usr/local/bin/vcam-link),)
  TARGET_LD = /usr/local/bin/vcam-link
  _THEOS_TARGET_SDK_BIN_PREFIX :=
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VirtualCamera
VirtualCamera_FILES = Stage1.x

VirtualCamera_CFLAGS = -fobjc-arc -Wno-everything
VirtualCamera_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
