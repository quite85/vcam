TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# ---------------------------------------------------------------------------
# Probe —— 对照测试包（验证插件注入是否生效）
# ---------------------------------------------------------------------------
# 只注入 SpringBoard，只做一件事：弹一个大弹窗。
# 用来一刀切开"环境问题"与"代码问题"。
ifneq ($(wildcard /usr/local/bin/vcam-link),)
  TARGET_LD = /usr/local/bin/vcam-link
  _THEOS_TARGET_SDK_BIN_PREFIX :=
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamProbe
VCamProbe_FILES = Probe.x
VCamProbe_CFLAGS = -fobjc-arc -Wno-everything
VCamProbe_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
