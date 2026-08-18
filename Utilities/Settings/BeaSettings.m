#import "BeaSettings.h"
#import "../Debug/BeaDebug.h"
#import <dlfcn.h>

NSString *const BeaSettingBlockAdNetworkRequests   = @"BeaBlockAdNetworkRequests";
NSString *const BeaSettingRemoveAdViews            = @"BeaRemoveAdViews";
NSString *const BeaSettingRemoveSponsoredCards     = @"BeaRemoveSponsoredCards";
NSString *const BeaSettingWidenFromAdMedia         = @"BeaWidenFromAdMedia";
NSString *const BeaSettingHideGatingOverlay        = @"BeaHideGatingOverlay";
NSString *const BeaSettingKeepGatingCTA            = @"BeaKeepGatingCTA";
NSString *const BeaSettingShowDownloadButton       = @"BeaShowDownloadButton";
NSString *const BeaSettingShowUploadButton         = @"BeaShowUploadButton";
NSString *const BeaSettingHideButtonsWhileScrolling = @"BeaHideButtonsWhileScrolling";
NSString *const BeaSettingLoadAccessibilityBundles = @"BeaLoadAccessibilityBundles";
NSString *const BeaSettingDebugLogging             = @"BeaDebugLogging";

static BOOL BeaAccessibilityBundlesLoaded = NO;

@implementation BeaSettings

+ (void)load {
	// -registerDefaults: rather than a ?: at every call site, so "never set"
	// and "explicitly set to NO" stay distinguishable in the store itself.
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{
		BeaSettingBlockAdNetworkRequests:    @YES,
		BeaSettingRemoveAdViews:             @YES,
		BeaSettingRemoveSponsoredCards:      @YES,
		BeaSettingWidenFromAdMedia:          @YES,
		BeaSettingHideGatingOverlay:         @YES,
		// Keeping the "Poste un BeReal." call to action is what the repo owner
		// asked for, but it is also the fiddliest half of the overlay strip -
		// turning it off hides the overlay whole, which is the outcome that
		// always works.
		BeaSettingKeepGatingCTA:             @YES,
		BeaSettingShowDownloadButton:        @YES,
		BeaSettingShowUploadButton:          @YES,
		// Off by default. The scroll-linked fade is a nicety, and the version
		// that shipped before this one read UIScrollView.isTracking, which is
		// already YES on finger-down - so simply holding a finger anywhere on
		// the feed made the "+" vanish until you let go. "Pinned and always
		// there" is the behaviour to default to.
		BeaSettingHideButtonsWhileScrolling: @NO,
		BeaSettingLoadAccessibilityBundles:  @YES,
		BeaSettingDebugLogging:              @NO,
	}];
}

+ (BOOL)boolForKey:(NSString *)key {
	if (key.length == 0) return NO;
	return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
	if (key.length == 0) return;
	[[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
	if ([key isEqualToString:BeaSettingDebugLogging]) BeaDebugRefreshLoggingFlag();
}

+ (BOOL)accessibilityBundlesLoaded {
	return BeaAccessibilityBundlesLoaded;
}

+ (void)loadAccessibilityBundlesIfEnabled {
	if (BeaAccessibilityBundlesLoaded) return;
	if (![self boolForKey:BeaSettingLoadAccessibilityBundles]) return;

	// UIKit's bundle brings the UIView/UIViewController accessibility
	// categories; SwiftUI's is the one that actually matters here, since it is
	// what turns a SwiftUI Text into a published UIAccessibilityElement. Load
	// both - SwiftUI's own AX code calls into UIKit's.
	//
	// RTLD_LAZY, and a missing bundle is not an error: these paths are not API
	// and Apple has moved them before. Failing to load them costs the text
	// scans and nothing else, so there is nothing to abort for.
	static const char *paths[] = {
		"/System/Library/AccessibilityBundles/UIKit.axbundle/UIKit",
		"/System/Library/AccessibilityBundles/SwiftUI.axbundle/SwiftUI",
	};

	BOOL loadedAny = NO;
	for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		if (dlopen(paths[i], RTLD_LAZY)) {
			loadedAny = YES;
		} else {
			BeaLog("[BeaA11y] could not load %{public}s (%{public}s)", paths[i], dlerror() ?: "unknown");
		}
	}

	// libAccessibility's own flag is what several UIKit code paths consult
	// before bothering to build an element tree. Resolved by name rather than
	// linked, so its absence is just a skipped step.
	void *handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
	if (handle) {
		void (*setEnabled)(Boolean) = (void (*)(Boolean))dlsym(handle, "_AXSSetApplicationAccessibilityEnabled");
		if (setEnabled) setEnabled(true);
	}

	BeaAccessibilityBundlesLoaded = loadedAny;
	BeaLog("[BeaA11y] accessibility bundles %{public}s", loadedAny ? "loaded" : "NOT loaded");
}

@end
