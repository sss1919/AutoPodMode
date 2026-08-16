ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AutoPodModePrefs

AutoPodModePrefs_FILES = APMPRootListController.m
AutoPodModePrefs_INSTALL_PATH = /Library/PreferenceBundles
AutoPodModePrefs_FRAMEWORKS = Foundation UIKit Preferences
AutoPodModePrefs_PRIVATE_FRAMEWORKS = Preferences FrontBoardServices
AutoPodModePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
