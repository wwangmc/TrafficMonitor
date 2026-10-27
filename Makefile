# Independent schemes: TYPE=1 rootless iOS 15+, TYPE=0 rootful iOS 14+.
TYPE ?= 1
DEBUG = 0
FINALPACKAGE = 1
TM_SDK ?= 16.5

ifeq ($(TYPE),0)
ARCHS ?= arm64
TARGET = iphone:clang:$(TM_SDK):14.0
THEOS_PACKAGE_SCHEME =
TM_ROOTLESS = 0
else ifeq ($(TYPE),1)
ARCHS ?= arm64 arm64e
TARGET = iphone:clang:$(TM_SDK):15.0
THEOS_PACKAGE_SCHEME = rootless
TM_ROOTLESS = 1
else
$(error Unsupported TYPE '$(TYPE)'; use 1 for rootless or 0 for rootful)
endif

# No guessed executable name or automatic process kill; cold-launch the target.
ifeq ($(strip $(THEOS)),)
$(error THEOS is not set; install Theos and export THEOS first)
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrafficMonitor
TrafficMonitor_FILES = Tweak.xm Sources/TMHTTPMonitor.mm Sources/TMHTTPRecorder.mm
TrafficMonitor_CFLAGS = -fobjc-arc -DTM_ROOTLESS=$(TM_ROOTLESS)
TrafficMonitor_CCFLAGS = -std=c++17
TrafficMonitor_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += probe
include $(THEOS_MAKE_PATH)/aggregate.mk
