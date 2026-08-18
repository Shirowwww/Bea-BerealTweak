#import "BeaAdBlocker.h"
#import "../Debug/BeaDebug.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import "../Settings/BeaSettings.h"
#import "../Diagnostics/BeaDiagnostics.h"
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
//     A class check alone is not enough for the in-feed sponsored post, which
//     SwiftUI renders with no per-element UIView to have a class at all - see
//     +removeSponsoredContentInView: at the bottom of this file for the third
//     signal that covers it.
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
//
// "SparkAds" rather than the four SparkAdsData/Domain/Presentation/DI spellings
// it replaced: they were an exhaustive list of the modules that existed when it
// was written, and the 4.88 binary already carries classes in all four plus
// nothing that starts "SparkAds" and isn't an ad. One marker also covers
// whatever module the next reorganisation invents - the same lesson as the
// BlurStateUseCaseImpl module move in AGENTS.md, applied before it bites.
static NSString *const kBeaAdModuleMarkers[] = {
	@"AdvertsData",
	@"AdvertsDomain",
	@"AdvertsPresentation",
	@"AdvertsDI",
	@"SparkAds",
	@"AdsGlobalPackage",
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

// Counts how many times a given card has had its frame re-zeroed, so a card
// whose owner keeps laying it straight back out can't turn into a layout loop.
static const void *BeaSponsoredReassertCountKey = &BeaSponsoredReassertCountKey;
static const NSInteger kBeaMaxSponsoredFrameReasserts = 8;

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
+ (void)collapseEmptyContainersAbove:(UIView *)view;
+ (BOOL)subtreeHasRealContent:(UIView *)view;
+ (void)collapseView:(UIView *)view;
+ (NSArray<NSString *> *)sponsoredCopyNeedles;
+ (BOOL)viewIsPlausibleSponsoredCard:(UIView *)view;
+ (UIView *)sponsoredCardForMarker:(UIView *)marker upToRoot:(UIView *)root;
+ (void)collapseSponsoredCard:(UIView *)card;
+ (void)collapseCardAroundRemovedAdInContainer:(UIView *)container;
@end

@implementation BeaAdBlocker

+ (void)installNetworkBlocking {
	// Read once, at launch. The protocol has to be registered before any SDK
	// builds its first session, so this switch is one of the two that only
	// takes effect on relaunch (the settings screen says so).
	if (![BeaSettings boolForKey:BeaSettingBlockAdNetworkRequests]) return;

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
	if (![BeaSettings boolForKey:BeaSettingRemoveAdViews]) return;
	if (objc_getAssociatedObject(view, BeaNeutralizedKey)) {
		// Already handled once. Still re-assert removal, since BeReal's own
		// containers get re-inserted into a recycled feed cell rather than
		// rebuilt, and would otherwise come back visible on the second pass.
		if (verdict == BeaAdVerdictRemove && view.superview) [view removeFromSuperview];
		return;
	}

	// Captured before the view is (possibly) removed from the hierarchy - the
	// container that has to be collapsed is only reachable through it.
	UIView *container = view.superview;

	objc_setAssociatedObject(view, BeaNeutralizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	BeaSuppressedViewCount++;
	BeaLog("[BeaAds] neutralizing %{public}@ (verdict=%{public}ld)", NSStringFromClass([view class]), (long)verdict);

	[self collapseView:view];

	if (verdict == BeaAdVerdictRemove) {
		[view removeFromSuperview];
	}

	[self collapseEmptyContainersAbove:container];

	// And then the card the ad was sitting in, which is a different problem
	// from an empty container and the one that actually got reported: taking
	// the vendor SDK's media view out of a sponsored post leaves the card
	// itself - advertiser name, "Sponsorisé", the CTA - as a full-height black
	// rectangle. collapseEmptyContainersAbove: cannot help there, because that
	// leftover copy is real content by any honest definition of the word.
	//
	// This is the signal that does not depend on reading any text: whatever
	// container held a view we just identified as an ad is, by construction,
	// ad furniture. It is still bounded by exactly the same
	// viewIsPlausibleSponsoredCard: guard as the text-driven path, so it can
	// no more take a real post or the timeline than that one can.
	[self collapseCardAroundRemovedAdInContainer:container];
}

+ (void)collapseCardAroundRemovedAdInContainer:(UIView *)container {
	if (!container) return;
	if (![BeaSettings boolForKey:BeaSettingWidenFromAdMedia]) return;

	// Deferred for the same reason as collapseEmptyContainersAbove: this runs
	// from -didAddSubview:/-didMoveToWindow, where the card may not be in a
	// window or laid out yet - and every guard below is geometric, so asking
	// now would answer "not plausible" and give up on a card that is merely
	// not built yet.
	dispatch_async(dispatch_get_main_queue(), ^{
		UIView *card = [self sponsoredCardForMarker:container upToRoot:nil];
		if (!card) return;
		[self collapseSponsoredCard:card];
	});
}

+ (void)collapseView:(UIView *)view {
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
}

// Whether anything in this subtree is content a person would actually see.
// Views already neutralized (and anything belonging to the ad stack) count as
// empty, which is the whole point: it lets an ancestor whose only reason to
// exist was hosting the ad be recognised as now-empty.
+ (BOOL)subtreeHasRealContent:(UIView *)view {
	if (!view) return NO;
	if (objc_getAssociatedObject(view, BeaNeutralizedKey)) return NO;
	if ([self verdictForView:view] != BeaAdVerdictNotAd) return NO;
	if (view.hidden || view.alpha <= 0.01) return NO;

	if ([view isKindOfClass:[UILabel class]]) {
		return ((UILabel *)view).text.length > 0;
	}
	if ([view isKindOfClass:[UIImageView class]]) {
		return ((UIImageView *)view).image != nil;
	}
	if ([view isKindOfClass:[UIControl class]]) {
		return YES;
	}

	for (UIView *subview in view.subviews) {
		if ([self subtreeHasRealContent:subview]) return YES;
	}

	// A plain container with nothing meaningful under it. Its own background
	// colour is deliberately NOT treated as content - a black-filled wrapper
	// left behind by a removed ad is exactly the thing being hunted here.
	return NO;
}

// Walks up from the removed ad's former parent collapsing every ancestor that
// is now empty, stopping at the first one that still holds real content.
//
// Deferred by one runloop turn: this runs from -didAddSubview:/-didMoveToWindow,
// i.e. potentially mid-construction, where a cell that will get real content
// in a moment currently looks empty. By the time the main queue drains, the
// hierarchy has settled - and subtreeHasRealContent: is re-evaluated then, not
// now.
+ (void)collapseEmptyContainersAbove:(UIView *)view {
	if (!view) return;

	dispatch_async(dispatch_get_main_queue(), ^{
		UIView *candidate = view;
		for (NSInteger depth = 0; candidate && depth < 6; depth++) {
			if ([candidate isKindOfClass:[UIWindow class]]) break;
			if (!candidate.superview) break;
			if ([self subtreeHasRealContent:candidate]) break;

			// Never collapse something that is effectively the whole screen.
			// An ad big enough to be a full feed page is a different problem
			// from the black band this is for, and getting it wrong here
			// would blank out a real post.
			UIWindow *window = candidate.window;
			if (window) {
				CGRect frameInWindow = [candidate convertRect:candidate.bounds toView:nil];
				CGFloat coverage = (frameInWindow.size.width * frameInWindow.size.height) /
					MAX(window.bounds.size.width * window.bounds.size.height, (CGFloat)1.0);
				if (coverage > 0.9) break;
			}

			if (!objc_getAssociatedObject(candidate, BeaNeutralizedKey)) {
				objc_setAssociatedObject(candidate, BeaNeutralizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				BeaLog("[BeaAds] collapsing empty ad container %{public}@", NSStringFromClass([candidate class]));
				[self collapseView:candidate];
			}

			candidate = candidate.superview;
		}
	});
}

// ============================================================================
// BEREAL'S OWN IN-FEED SPONSORED POSTS
// ============================================================================
// See the comment on +removeSponsoredContentInView: in the header for why this
// can't work off class names the way everything above does.

// The "Sponsored" byline, in whichever language BeReal is running in.
+ (NSArray<NSString *> *)sponsoredCopyNeedles {
	static NSArray<NSString *> *needles;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableArray<NSString *> *resolved = [NSMutableArray array];

		// general_sponsored is stamped on every paid placement BeReal shows -
		// a direct deal, a Spotlight, an in-house campaign - and on nothing
		// else. "Sponsorisé" in French, and thirteen more.
		NSString *localized = BeaNormalizedCopy(BeaAppLocalized(@"general_sponsored", @""));
		if (localized.length >= 3) [resolved addObject:localized];

		// Kept unconditionally as a floor. If BeReal renames the key this
		// still catches an English device, and no other language it ships
		// renders the literal word "sponsored" anyway, so it costs nothing.
		if (![resolved containsObject:@"sponsored"]) [resolved addObject:@"sponsored"];

		needles = [resolved copy];
		BeaLog("[BeaAds] sponsored needles: %{public}@", needles);
	});
	return needles;
}

// Whether collapsing `view` could only ever remove the ad.
//
// This is the safety property the whole mechanism rests on, so it is checked
// against the marker itself as well as against every ancestor the walk below
// considers - not only as a stop condition. The marker can legitimately be a
// large view: when the byline was found through the accessibility tree rather
// than a UILabel, the view reported back is the SwiftUI host that published it,
// which may be the whole feed. Collapsing that would blank the timeline.
// Refusing outright is the right failure - the ad stays, nothing else breaks.
//
//  - A real BeReal is always a front+back *pair*, so a view holding two
//    qualifying photos has picked up an actual post (the feed keeps the
//    neighbouring one mounted for smooth scrolling) and is not just the ad.
//  - A scroll view is never the card; nor is its content view, which holds
//    every post at once and, in a feed of full-screen posts, is far taller
//    than the screen - which the size test catches.
+ (BOOL)viewIsPlausibleSponsoredCard:(UIView *)view {
	if (!view || [view isKindOfClass:[UIWindow class]]) return NO;
	if ([view isKindOfClass:[UIScrollView class]]) return NO;

	UIWindow *window = view.window;
	if (!window) return NO;

	// One sponsored card is at most about a screenful. Cheap tests first -
	// the photo-pair walk below is the expensive one.
	CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
	if (frameInWindow.size.height > window.bounds.size.height * 1.2) return NO;
	if (frameInWindow.size.width > window.bounds.size.width * 1.2) return NO;

	return [[BeaDownloader qualifyingImageViewsInView:view] count] < 2;
}

// The ad's own card: widen from the byline for as long as every step is still
// only the ad, with a hard depth cap as a last resort.
+ (UIView *)sponsoredCardForMarker:(UIView *)marker upToRoot:(UIView *)root {
	if (![self viewIsPlausibleSponsoredCard:marker]) return nil;

	UIView *card = marker;
	UIView *candidate = marker.superview;

	for (NSInteger levelsWalked = 0; candidate && candidate != root && levelsWalked < 14; levelsWalked++) {
		if (![self viewIsPlausibleSponsoredCard:candidate]) break;
		card = candidate;
		candidate = candidate.superview;
	}

	return card;
}

+ (void)collapseSponsoredCard:(UIView *)card {
	if (!objc_getAssociatedObject(card, BeaNeutralizedKey)) {
		objc_setAssociatedObject(card, BeaNeutralizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		BeaSuppressedViewCount++;
		BeaLog("[BeaAds] collapsing sponsored card %{public}@", NSStringFromClass([card class]));
		[self collapseView:card];
		return;
	}

	// Already handled once, but re-assert anyway: SwiftUI re-runs its own
	// frame-based layout over this subtree on every feed layout pass, and the
	// zero-size constraints collapseView: installs only bite on Auto Layout
	// views, so they can't be relied on to hold here.
	//
	// The three property writes are no-ops when nothing changed. Re-zeroing
	// the frame is not - it invalidates layout, which brings us straight back
	// here - so it gets a budget rather than running forever. Past the budget
	// the card stays hidden and non-interactive and only its (empty) space
	// remains, which is a far better failure than a layout loop.
	card.hidden = YES;
	card.alpha = 0.0;
	card.userInteractionEnabled = NO;

	if (CGRectIsEmpty(card.frame)) return;
	NSNumber *attempts = objc_getAssociatedObject(card, BeaSponsoredReassertCountKey);
	if (attempts.integerValue >= kBeaMaxSponsoredFrameReasserts) return;
	objc_setAssociatedObject(card, BeaSponsoredReassertCountKey, @(attempts.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	card.frame = CGRectZero;
}

+ (void)removeSponsoredContentInView:(UIView *)root {
	if (!root) return;
	if (![BeaSettings boolForKey:BeaSettingRemoveSponsoredCards]) return;

	NSArray<NSString *> *needles = [self sponsoredCopyNeedles];
	NSMutableArray<UIView *> *markers = [NSMutableArray array];

	BeaCollectViewsWithMatchingText(@"sponsored", root, ^BOOL(NSString *normalized) {
		// A byline, or an accessibility label that folds the advertiser's name
		// into it ("Crédit Mutuel Alliance Fédérale, Sponsorisé"). Anything
		// longer is prose - a caption that merely mentions the word must not
		// take a real post down with it.
		if (normalized.length > 64) return NO;
		for (NSString *needle in needles) {
			if (BeaCopyContainsPhrase(normalized, needle)) return YES;
		}
		return NO;
	}, markers);

	[BeaDiagnostics recordSponsoredMarkers:(NSInteger)markers.count];
	if (markers.count == 0) return;

	for (UIView *marker in markers) {
		UIView *card = [self sponsoredCardForMarker:marker upToRoot:root];
		if (!card) continue;
		[self collapseSponsoredCard:card];
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
