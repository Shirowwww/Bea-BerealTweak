#import "BeaAdBlocker.h"
#import "../Debug/BeaDebug.h"
#import <objc/runtime.h>
#import <os/lock.h>

// ============================================================================
// WHAT COUNTS AS AN AD
// ============================================================================
// Two independent signals, because the ad stack in BeReal 4.88 lives in two
// very different places (confirmed by reading the decrypted 4.88 binary, see
// the notes in README.md):
//
//  1. BeReal's own Swift modules - AdvertsData / AdvertsDomain /
//     AdvertsPresentation / AdvertsDI, and the separate in-house "Spark Ads"
//     stack (SparkAdsData / SparkAdsDomain / SparkAdsPresentation / SparkAdsDI,
//     which is where Spotlight, FoF ads and direct deals live). These are
//     matched by name.
//
//  2. ~18 third-party ad SDKs shipped as embedded frameworks (AppLovin MAX and
//     its ByteDance/InMobi/Moloco/PubMatic/Verve mediation adapters,
//     GoogleMobileAds, PAGAdSDK, HyBid, VungleAdsSDK, VoodooAdn, AppHarbr,
//     OpenWrap, the two OMSDK viewability kits). Matched by which *binary* the
//     class was loaded from (class_getImageName) rather than by name - that
//     covers every class those frameworks will ever add, including ones this
//     file has never heard of, without maintaining a name list that goes stale
//     on the next SDK bump.
//
// Deliberately NOT included: UserMessagingPlatform (Google's consent/CMP
// framework). It isn't an ad - it's the one-time GDPR consent sheet - and
// blocking a consent flow risks the app waiting forever on a callback that
// can now never arrive. With ads suppressed there's nothing for it to consent
// to anyway.
static NSString *const kBeaAdFrameworkImages[] = {
	@"AppLovinSDK",
	@"AppLovinQualityService",
	@"AppLovinMediationByteDanceAdapter",
	@"AppLovinMediationInMobiAdapter",
	@"AppLovinMediationMolocoAdapter",
	@"AppLovinMediationPubMaticAdapter",
	@"AppLovinMediationVerveAdapter",
	@"GoogleMobileAds",
	@"GoogleAdsOnDeviceConversion",
	@"BRGoogleAdsOnDeviceConversion",
	@"PAGAdSDK",
	@"InMobiSDK",
	@"MolocoSDK",
	@"OpenWrapSDK",
	@"OMSDK_Pubmatic",
	@"OMSDK_Voodooio",
	@"HyBid",
	@"VungleAdsSDK",
	@"VoodooAdn",
	@"AppHarbrSDK",
};

// Distinctive enough to match as substrings, which is what makes this work for
// both spellings of a Swift class name: the demangled "AdvertsData.AppLovinMRECView"
// that NSStringFromClass returns, and the raw "_TtC11AdvertsData16AppLovinMRECView"
// that class_getName does (plus the _TtCC/_TtCV forms Swift uses for nested
// types, which no prefix check would catch).
static NSString *const kBeaAdModuleMarkers[] = {
	@"AdvertsData",
	@"AdvertsDomain",
	@"AdvertsPresentation",
	@"AdvertsDI",
	@"SparkAdsData",
	@"SparkAdsDomain",
	@"SparkAdsPresentation",
	@"SparkAdsDI",
};

// Fallback for an SDK that gets statically linked into the main binary in some
// future build (at which point the image-name signal above stops working for
// it). Exact matches only - these are specific enough that a substring test
// would be the riskier choice.
static NSString *const kBeaAdViewClassNames[] = {
	@"MAAdView", @"MANativeAdView", @"ALAdView", @"ALInterstitialAd",
	@"GADBannerView", @"GADNativeAdView", @"GADMediaView",
	@"PAGBannerAdView", @"BUNativeExpressAdView",
	@"IMBanner", @"IMNativeView",
	@"VungleBannerView", @"POBBannerView", @"HyBidAdView",
	@"MolocoBannerView", @"AHBannerView",
};

#define BEA_ARRAY_COUNT(a) (sizeof(a) / sizeof((a)[0]))

// ============================================================================
// AD / MEDIATION HOSTS
// ============================================================================
// Suffix-matched against the request's host, so "ms.applvn.com" matches
// "applvn.com" but "notapplvn.com" does not (the match requires the character
// before the suffix to be a dot).
//
// Deliberately excludes anything BeReal itself needs: bereal.com,
// bereal.network, the Firebase/Crashlytics/Datadog endpoints, Zendesk, and
// Spotify (BeFake's music attachment talks to it directly). Also excludes
// google-analytics.com and app-measurement.com - those are Firebase Analytics,
// not ad serving, and breaking them can take Firebase Messaging down with them.
static NSString *const kBeaAdHosts[] = {
	@"applovin.com", @"applvn.com", @"applov.in",
	@"doubleclick.net", @"googlesyndication.com", @"googleadservices.com", @"admob.com",
	@"moloco.com", @"adsmoloco.com",
	@"inmobi.com", @"inmobicdn.net",
	@"pubmatic.com", @"pubnative.net",
	@"vungle.com", @"vungle.io",
	@"pangle.io", @"pangle.cn", @"byteoversea.com", @"isnssdk.com", @"pglstatp-toutiao.com",
	@"appharbr.com",
	@"adnxs.com", @"casalemedia.com", @"rubiconproject.com", @"smartadserver.com",
	@"criteo.com", @"criteo.net",
	@"adn.voodoo.io",
};

static NSUInteger BeaSuppressedViewCount = 0;
static NSUInteger BeaBlockedRequestCount = 0;

static const void *BeaNeutralizedKey = &BeaNeutralizedKey;

// Class objects live for the lifetime of the process, so a pointer-keyed cache
// with no retain/release callbacks is both safe and the cheapest option here -
// verdictForClass: is called from -didAddSubview:, which fires for every single
// view insertion anywhere in the app.
static CFMutableDictionaryRef BeaVerdictCache;
static os_unfair_lock BeaVerdictCacheLock = OS_UNFAIR_LOCK_INIT;

static BOOL BeaHostMatchesSuffix(NSString *host, NSString *suffix) {
	if (host.length < suffix.length) return NO;
	if ([host isEqualToString:suffix]) return YES;
	// Require a dot boundary so "evilapplvn.com" can't pass as "applvn.com".
	return [host hasSuffix:[@"." stringByAppendingString:suffix]];
}

static BOOL BeaURLIsAdHost(NSURL *url) {
	NSString *host = url.host.lowercaseString;
	if (host.length == 0) return NO;
	for (size_t i = 0; i < BEA_ARRAY_COUNT(kBeaAdHosts); i++) {
		if (BeaHostMatchesSuffix(host, kBeaAdHosts[i])) return YES;
	}
	return NO;
}

// ============================================================================
// NETWORK BLOCKING
// ============================================================================

@interface BeaAdURLProtocol : NSURLProtocol
@end

@implementation BeaAdURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
	// NSURLProtocol re-issues the request through the loading system after
	// startLoading, so without this marker a protocol that *handled* a request
	// could be asked about it again and recurse. This one never re-issues
	// anything (it fails immediately), but the property is kept as a cheap
	// guard in case that ever changes.
	if ([NSURLProtocol propertyForKey:@"BeaAdBlocked" inRequest:request]) return NO;
	return BeaURLIsAdHost(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
	return request;
}

- (void)startLoading {
	BeaBlockedRequestCount++;
	BeaLog("[BeaAds] blocked request to %{public}@", self.request.URL.host);
	NSError *error = [NSError errorWithDomain:NSURLErrorDomain
										 code:NSURLErrorCancelled
									 userInfo:@{ NSLocalizedDescriptionKey: @"cancelled by MiniBea ad blocking" }];
	[self.client URLProtocol:self didFailWithError:error];
}

- (void)stopLoading {
}

@end

// Registering the protocol with +[NSURLProtocol registerClass:] only reaches
// NSURLConnection and [NSURLSession sharedSession]. Every ad SDK builds its own
// NSURLSession from its own configuration, and those consult the configuration's
// protocolClasses instead - which is why the two factory methods have to be
// swizzled to insert our class at the front of that list.
typedef NSURLSessionConfiguration *(*BeaConfigurationIMP)(id, SEL);
static BeaConfigurationIMP BeaOrigDefaultConfiguration;
static BeaConfigurationIMP BeaOrigEphemeralConfiguration;

static NSURLSessionConfiguration *BeaConfigurationWithProtocol(NSURLSessionConfiguration *configuration) {
	if (!configuration) return configuration;
	NSMutableArray *protocols = [NSMutableArray arrayWithArray:configuration.protocolClasses ?: @[]];
	Class blocker = [BeaAdURLProtocol class];
	if (![protocols containsObject:blocker]) {
		// Front of the list: NSURLSession asks each protocol in order and the
		// first to claim the request wins, so anything already installed (by
		// the app, or by another tweak) must not get to answer first.
		[protocols insertObject:blocker atIndex:0];
		configuration.protocolClasses = protocols;
	}
	return configuration;
}

static NSURLSessionConfiguration *BeaDefaultConfiguration(id self, SEL _cmd) {
	if (!BeaOrigDefaultConfiguration) return nil;
	return BeaConfigurationWithProtocol(BeaOrigDefaultConfiguration(self, _cmd));
}

static NSURLSessionConfiguration *BeaEphemeralConfiguration(id self, SEL _cmd) {
	if (!BeaOrigEphemeralConfiguration) return nil;
	return BeaConfigurationWithProtocol(BeaOrigEphemeralConfiguration(self, _cmd));
}

// Declared up front rather than relying on same-@implementation lookup, so the
// compiler checks the signature at the call site in verdictForClass:.
@interface BeaAdBlocker ()
+ (BeaAdVerdict)uncachedVerdictForClass:(Class)cls;
@end

@implementation BeaAdBlocker

+ (void)installNetworkBlocking {
	[NSURLProtocol registerClass:[BeaAdURLProtocol class]];

	Class configurationClass = [NSURLSessionConfiguration class];
	Class meta = object_getClass(configurationClass);

	Method defaultMethod = class_getClassMethod(configurationClass, @selector(defaultSessionConfiguration));
	if (defaultMethod) {
		BeaOrigDefaultConfiguration = (BeaConfigurationIMP)method_getImplementation(defaultMethod);
		class_replaceMethod(meta, @selector(defaultSessionConfiguration), (IMP)BeaDefaultConfiguration, method_getTypeEncoding(defaultMethod));
	}

	Method ephemeralMethod = class_getClassMethod(configurationClass, @selector(ephemeralSessionConfiguration));
	if (ephemeralMethod) {
		BeaOrigEphemeralConfiguration = (BeaConfigurationIMP)method_getImplementation(ephemeralMethod);
		class_replaceMethod(meta, @selector(ephemeralSessionConfiguration), (IMP)BeaEphemeralConfiguration, method_getTypeEncoding(ephemeralMethod));
	}

	// Background configurations are deliberately left alone: NSURLSession does
	// not support custom NSURLProtocols there at all, and inserting one is
	// documented as undefined behaviour.
}

+ (BeaAdVerdict)verdictForClass:(Class)cls {
	if (!cls) return BeaAdVerdictNotAd;

	os_unfair_lock_lock(&BeaVerdictCacheLock);
	if (!BeaVerdictCache) {
		BeaVerdictCache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
	}
	const void *cached = NULL;
	Boolean hit = CFDictionaryGetValueIfPresent(BeaVerdictCache, (__bridge const void *)cls, &cached);
	os_unfair_lock_unlock(&BeaVerdictCacheLock);
	// Stored as verdict+1 so that a genuine BeaAdVerdictNotAd (0) is still a
	// distinguishable stored value rather than a NULL that reads as "absent".
	if (hit) return (BeaAdVerdict)((NSInteger)(uintptr_t)cached - 1);

	BeaAdVerdict verdict = [self uncachedVerdictForClass:cls];

	os_unfair_lock_lock(&BeaVerdictCacheLock);
	CFDictionarySetValue(BeaVerdictCache, (__bridge const void *)cls, (const void *)(uintptr_t)(verdict + 1));
	os_unfair_lock_unlock(&BeaVerdictCacheLock);

	return verdict;
}

+ (BeaAdVerdict)uncachedVerdictForClass:(Class)cls {
	const char *rawName = class_getName(cls);
	if (!rawName) return BeaAdVerdictNotAd;
	NSString *rawNameString = @(rawName);

	// This tweak's own classes are all Bea-prefixed. Bailing out first keeps a
	// future BeaAdSomething from ever matching one of the markers below.
	if ([rawNameString hasPrefix:@"Bea"]) return BeaAdVerdictNotAd;

	// NSStringFromClass gives Swift's demangled "Module.Type"; class_getName
	// gives the raw mangled symbol. Which one a given marker matches depends on
	// how the class was declared, so both are checked.
	NSString *displayName = NSStringFromClass(cls) ?: rawNameString;

	for (size_t i = 0; i < BEA_ARRAY_COUNT(kBeaAdModuleMarkers); i++) {
		NSString *marker = kBeaAdModuleMarkers[i];
		if ([displayName containsString:marker] || [rawNameString containsString:marker]) {
			return BeaAdVerdictRemove;
		}
	}

	for (size_t i = 0; i < BEA_ARRAY_COUNT(kBeaAdViewClassNames); i++) {
		if ([displayName isEqualToString:kBeaAdViewClassNames[i]]) return BeaAdVerdictSuppress;
	}

	// Runtime-created classes (KVO's NSKVONotifying_*, and anything else made
	// with objc_allocateClassPair) have no image at all. Walk up to the first
	// ancestor that does, which for a KVO subclass is the real class.
	Class imageOwner = cls;
	const char *imageName = NULL;
	for (NSInteger depth = 0; imageOwner && depth < 8; depth++) {
		imageName = class_getImageName(imageOwner);
		if (imageName) break;
		imageOwner = class_getSuperclass(imageOwner);
	}
	if (!imageName) return BeaAdVerdictNotAd;

	NSString *image = [@(imageName) lastPathComponent];
	for (size_t i = 0; i < BEA_ARRAY_COUNT(kBeaAdFrameworkImages); i++) {
		if ([image isEqualToString:kBeaAdFrameworkImages[i]]) return BeaAdVerdictSuppress;
	}

	return BeaAdVerdictNotAd;
}

+ (BeaAdVerdict)verdictForView:(UIView *)view {
	if (!view) return BeaAdVerdictNotAd;
	return [self verdictForClass:[view class]];
}

+ (void)neutralizeView:(UIView *)view withVerdict:(BeaAdVerdict)verdict {
	if (!view || verdict == BeaAdVerdictNotAd) return;
	if (objc_getAssociatedObject(view, BeaNeutralizedKey)) {
		// Already handled once. Still re-assert removal, since BeReal's own
		// containers get re-inserted into a recycled feed cell rather than
		// rebuilt, and would otherwise come back visible on the second pass.
		if (verdict == BeaAdVerdictRemove && view.superview) [view removeFromSuperview];
		return;
	}
	objc_setAssociatedObject(view, BeaNeutralizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	BeaSuppressedViewCount++;
	BeaLog("[BeaAds] neutralizing %{public}@ (verdict=%{public}ld)", NSStringFromClass([view class]), (long)verdict);

	view.hidden = YES;
	view.alpha = 0.0;
	view.userInteractionEnabled = NO;
	view.clipsToBounds = YES;
	view.frame = CGRectZero;

	// Only meaningful for a view that actually participates in Auto Layout.
	// Adding these to an autoresizing-mask view would just fight that view's
	// own required width/height constraints and spill a constraint-conflict
	// log on every layout pass for no benefit - the zeroed frame above already
	// covers that case.
	if (!view.translatesAutoresizingMaskIntoConstraints) {
		NSLayoutConstraint *zeroHeight = [view.heightAnchor constraintEqualToConstant:0];
		NSLayoutConstraint *zeroWidth = [view.widthAnchor constraintEqualToConstant:0];
		// Just under required, so a genuinely required constraint elsewhere
		// wins instead of producing an unsatisfiable set.
		zeroHeight.priority = UILayoutPriorityRequired - 1;
		zeroWidth.priority = UILayoutPriorityRequired - 1;
		[NSLayoutConstraint activateConstraints:@[zeroHeight, zeroWidth]];
	}

	if (verdict == BeaAdVerdictRemove) {
		[view removeFromSuperview];
	}
}

+ (BOOL)shouldBlockPresentationOfViewController:(UIViewController *)viewController {
	if (!viewController) return NO;
	if ([self verdictForClass:[viewController class]] != BeaAdVerdictNotAd) return YES;

	// A few SDKs present a plain UIViewController (or a UINavigationController)
	// whose *content* is the ad. Checking the already-loaded root view catches
	// those without forcing a view load on anything else.
	if (viewController.isViewLoaded && [self verdictForClass:[viewController.view class]] != BeaAdVerdictNotAd) return YES;

	return NO;
}

+ (BOOL)shouldBlockWindow:(UIWindow *)window {
	if (!window) return NO;
	if ([self verdictForClass:[window class]] != BeaAdVerdictNotAd) return YES;
	return [self shouldBlockPresentationOfViewController:window.rootViewController];
}

+ (NSUInteger)suppressedViewCount {
	return BeaSuppressedViewCount;
}

+ (NSUInteger)blockedRequestCount {
	return BeaBlockedRequestCount;
}

@end
