ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
export THEOS_PACKAGE_SCHEME

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoPodMode

AutoPodMode_FILES = Tweak.xm
AutoPodMode_FRAMEWORKS = Foundation UIKit AVFoundation
AutoPodMode_PRIVATE_FRAMEWORKS = MediaRemote BluetoothManager
AutoPodMode_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable

SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard Preferences || true"
