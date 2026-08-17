TARGET := iphone:clang:18.0:14.0
INSTALL_TARGET_PROCESSES = BeReal
ARCHS = arm64 arm64e


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniBea

$(TWEAK_NAME)_FILES = Tweak/Tweak.x $(shell find Utilities -name '*.m') $(shell find BeFake -name '*.m')
$(TWEAK_NAME)_CFLAGS = -fobjc-arc

ifeq ($(JAILED), 1)
$(TWEAK_NAME)_FILES += fishhook/fishhook.c SideloadFix/SideloadFix.xm
$(TWEAK_NAME)_CFLAGS += -D JAILED=1
# Logos's default (MobileSubstrate) generator emits hooks that call into
# CydiaSubstrate's MSHookMessageEx, which is why azule has to bundle a copy
# of that framework for sideloaded installs - and why on-device signers like
# Feather choke on it (it's a 2021-era binary still carrying dead armv6/armv7
# slices). The "internal" generator implements the same %hook/%orig/%new/
# %property surface with plain ObjC runtime calls (method_setImplementation,
# class_addMethod, objc_*AssociatedObject) baked directly into the compiled
# code, so the sideload build has no external hooking-library dependency at
# all. Scoped to JAILED=1 only - real jailbroken devices already have a
# working substrate daemon, so leave that path as-is.
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal
endif

include $(THEOS_MAKE_PATH)/tweak.mk
