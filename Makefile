ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET := iphone:clang:26.2:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET := iphone:clang:26.2:15.0
else
	TARGET := iphone:clang:26.2:11.0
endif
INSTALL_TARGET_PROCESSES = YouTube
ARCHS = arm64
PACKAGE_VERSION = 2.0.3

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTABConfig

$(TWEAK_NAME)_FILES = Settings.x Tweak.x RuntimeFlagRegistry.m YTABLabUI.m YTABCatalogProvider.m YTNativeExperiments.x YTABCNativeMenus.m YTABCSettingsRowsInspector.m YTABNativeDiagnostics.m YTABNativeExperimentsHealth.m YTABNativeStudyControls.m YTABCoreDataModelCompatibility.m YTABRuntimeBrowser.m YTABRuntimeBrowserModern.m YTABRuntimeBrowserHooks.x YTABRuntimeBrowserEntry.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DTWEAK_VERSION=$(PACKAGE_VERSION)
$(TWEAK_NAME)_FRAMEWORKS = UIKit CoreData

include $(THEOS_MAKE_PATH)/tweak.mk

ifeq ($(FINALPACKAGE),1)
after-all::
	@ldid -S "$(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib"
endif
