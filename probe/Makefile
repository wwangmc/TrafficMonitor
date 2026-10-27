TYPE ?= 1
TM_SDK ?= 16.5
override ARCHS = arm64
ifeq ($(TYPE),1)
TARGET = iphone:clang:$(TM_SDK):15.0
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(TYPE),0)
TARGET = iphone:clang:$(TM_SDK):14.0
THEOS_PACKAGE_SCHEME =
else ifeq ($(TYPE),2)
TARGET = iphone:clang:$(TM_SDK):15.0
THEOS_PACKAGE_SCHEME = roothide
else
$(error Unsupported TYPE)
endif

include $(THEOS)/makefiles/common.mk
TOOL_NAME = tm-probe
tm-probe_FILES = main.mm TMFixture.mm ../Sources/TMHTTPMonitor.mm ../Sources/TMHTTPRecorder.mm ../Sources/TMSocket.mm
tm-probe_CFLAGS = -fobjc-arc -DTM_SOCKET_TEST
tm-probe_CCFLAGS = -std=c++17
tm-probe_FRAMEWORKS = Foundation
tm-probe_INSTALL_PATH = /usr/libexec/trafficmonitor
ifeq ($(TYPE),2)
tm-probe_CODESIGN_FLAGS = -Sentitlements.plist
endif
include $(THEOS_MAKE_PATH)/tool.mk
