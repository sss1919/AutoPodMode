ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = com.apple.mediaremoted

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoPodMode

AutoPodMode_FILES = Tweak.xm
AutoPodMode_FRAMEWORKS = Foundation UIKit AVFoundation MediaRemote
AutoPodMode_PRIVATE_FRAMEWORKS = MediaRemote Bluetooth
AutoPodMode_CFLAGS = -fobjc-arc

SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 mediaremoted Preferences || true"
