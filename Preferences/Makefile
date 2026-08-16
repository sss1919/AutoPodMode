ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AutoPodModePrefs

AutoPodModePrefs_FILES = APMPRootListController.m
AutoPodModePrefs_INSTALL_PATH = /Library/PreferenceBundles
AutoPodModePrefs_FRAMEWORKS = Foundation UIKit Preferences
AutoPodModePrefs_PRIVATE_FRAMEWORKS = Preferences
AutoPodModePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp AutoPodModeEntry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/com.sss1919.autopodmode.prefs.plist$(ECHO_END)
