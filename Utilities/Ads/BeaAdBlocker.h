#import <UIKit/UIKit.h>

// What to do with a view/controller once its class has been identified as
// belonging to the ad stack. Two tiers rather than one because BeReal's own
// advert containers and a third-party SDK's own views fail very differently
// when you take them out of the hierarchy:
//
//  - Remove   - BeReal's own `AdvertsData.*` / `SparkAds*.*` containers. These
//               are plain wrappers BeReal itself inserts into the feed, and
//               pulling them out is exactly what the pre-existing
//               AdvertNativeViewContainer hook in Tweak.x already did without
//               trouble.
//  - Suppress - a vendor SDK's own view (AppLovin, GoogleMobileAds, Pangle,
//               ...). Left in the hierarchy on purpose: these SDKs activate
//               NSLayoutConstraints between the ad view and its superview, and
//               a constraint between two views with no common ancestor raises
//               NSInternalInconsistencyException. Hidden + zero-sized +
//               non-interactive is visually identical and can't throw.
typedef NS_ENUM(NSInteger, BeaAdVerdict) {
	BeaAdVerdictNotAd = 0,
	BeaAdVerdictSuppress,
	BeaAdVerdictRemove,
};

@interface BeaAdBlocker : NSObject

// Cached per Class (class objects are immortal, so the cache is keyed on the
// pointer and never needs invalidating). Both the view-hierarchy hooks and the
// presentation hook in Tweak.x call this on hot paths - everything expensive
// (image-name lookup, string matching) happens once per class, ever.
+ (BeaAdVerdict)verdictForClass:(Class)cls;
+ (BeaAdVerdict)verdictForView:(UIView *)view;

// Idempotent - safe to call from several hooks on the same view (which is the
// normal case: didMoveToWindow and the parent's didAddSubview: both fire).
//
// Also collapses the container the ad was sitting in, one runloop turn later
// (see -collapseEmptyContainersAbove: in the implementation). Hiding the ad
// view alone is not enough: BeReal sizes the surrounding feed row itself, so
// what the user is left with is a black rectangle of exactly the ad's former
// height sitting in the feed.
+ (void)neutralizeView:(UIView *)view withVerdict:(BeaAdVerdict)verdict;

// Full-screen/interstitial ads: every SDK here ultimately routes through
// -[UIViewController presentViewController:animated:completion:], so refusing
// that one call covers AppLovin, AdMob, Pangle, Vungle and the rest at once.
+ (BOOL)shouldBlockPresentationOfViewController:(UIViewController *)viewController;

// Ad windows (a few SDKs put their interstitial in their own UIWindow rather
// than presenting from the app's root controller).
+ (BOOL)shouldBlockWindow:(UIWindow *)window;

// Registers BeaAdURLProtocol so requests to known ad/mediation hosts fail
// immediately instead of being fetched. Called once from %ctor. This is what
// keeps an ad slot from ever being *filled* in the first place, so the feed
// renders with no gap at all rather than with a hidden-but-present ad cell.
+ (void)installNetworkBlocking;

// Diagnostics only (surfaced through BeaLog, so off unless MINIBEA_DEBUG=1).
+ (NSUInteger)suppressedViewCount;
+ (NSUInteger)blockedRequestCount;

@end
