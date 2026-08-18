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

// Which switch a given collapse belongs to, so turning one off restores only
// what that switch did rather than un-hiding the whole ad stack.
typedef NS_ENUM(NSInteger, BeaSuppressionCategory) {
	BeaSuppressionCategoryAdView = 0,     // a vendor SDK / Adverts* view
	BeaSuppressionCategorySponsoredCard,  // an in-feed sponsored card
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

// BeReal's own in-feed sponsored posts - a "direct deal" or a Spotlight
// campaign, drawn by its SparkAds stack.
//
// These need a different mechanism from everything else here, because nothing
// about them is a recognisable ad *class*. SwiftUI draws the whole card -
// advertiser name, "Sponsored" byline, media, "Learn more" button, caption -
// with no per-element UIView, so verdictForClass: has nothing to match. What
// the existing hooks did catch was the AppLovin media view inside the card;
// removing it left the card itself in place, sized as before, which is
// precisely the black rectangle with the advertiser's name still on top of it.
//
// The card is instead found by the one string BeReal puts on every paid
// placement and nothing else - "Sponsored" (general_sponsored), read from its
// own string table so this works in all fifteen languages - and collapsed as a
// whole. Safe to call on any view, every layout pass; it does nothing at all
// when there's no sponsored copy on screen.
+ (void)removeSponsoredContentInView:(UIView *)root;

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

// Undoes every view suppression of one kind, and forgets it, so the matching
// switch can be turned back on later and take effect again.
//
// Suppression is not idempotent-by-observation: a hidden, zero-framed view
// looks nothing like the view BeReal handed us, and the hooks that suppress it
// only fire when it is *inserted*. Without an explicit undo, turning "remove
// ad views" off did nothing at all until the app was relaunched - the ad was
// already gone and nothing was ever going to put it back. Every collapse is
// therefore recorded with the state it replaced.
+ (void)restoreSuppressionsOfCategory:(BeaSuppressionCategory)category;

// Re-runs the class check over everything currently in the hierarchy. Needed
// when the switch is turned back *on*: -didAddSubview:/-didMoveToWindow only
// fire on insertion, so an ad that was already on screen would otherwise stay
// until the feed happened to rebuild it.
+ (void)reapplyToVisibleHierarchy;

// Diagnostics only (surfaced through BeaLog, so off unless MINIBEA_DEBUG=1).
+ (NSUInteger)suppressedViewCount;
+ (NSUInteger)blockedRequestCount;

@end
