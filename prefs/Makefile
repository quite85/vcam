# ============================================================================
#  prefs —— 可选的 PreferenceLoader 设置面板
#  编译开关：在根 Makefile 上传入 VCAM_BUILD_PREFS=1
# ============================================================================

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VCamPrefs

VCamPrefs_FILES = VCamPrefsRootListController.m
VCamPrefs_INSTALL_PATH = /Library/PreferenceBundles
VCamPrefs_FRAMEWORKS = UIKit
VCamPrefs_PRIVATE_FRAMEWORKS = Preferences
VCamPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk

# 把设置入口注册到系统的"设置 → 越狱插件"列表里
internal-all::
	@$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	@$(ECHO_NOTHING)cp layout/Library/PreferenceLoader/Preferences/VCam.plist \
		$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/VCam.plist$(ECHO_END)
