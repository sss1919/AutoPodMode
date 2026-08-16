ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AutoPodModePrefs

AutoPodModePrefs_FILES = APMPRootListController.m
AutoPodModePrefs_INSTALL_PATH = /Library/PreferenceBundles
AutoPodModePrefs_FRAMEWORKS = Foundation UIKit Preferences
AutoPodModePrefs_PRIVATE_FRAMEWORKS = Preferences FrontBoardServices MobileCoreServices
AutoPodModePrefs_CFLAGS = -fobjc-arc

# Bundle resources: Info.plist (CFBundleInfo) + Root.plist (Preferences specifiers)
AutoPodModePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	# 1. PreferenceLoader entry: tells Settings where to find our pref bundle
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp AutoPodModeEntry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/com.sss1919.autopodmode.prefs.plist$(ECHO_END)
	# 2. Bundle Info.plist: CFBundleIdentifier / NSPrincipalClass
	$(ECHO_NOTHING)cp Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/AutoPodModePrefs.bundle/Info.plist$(ECHO_END)
	# 3. Bundle Root.plist: PSPrincipalClass, initial items
	$(ECHO_NOTHING)cp Root.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/AutoPodModePrefs.bundle/Root.plist$(ECHO_END)
