#import <UIKit/UIKit.h>

// ============================================================================
// THE LOCAL MEDIA VIEWER
// ============================================================================
// Full-screen zoom/pan for a post's two photos, with the inset thumbnail
// swapping which one is large.
//
// WHY THIS EXISTS RATHER THAN BEREAL'S OWN VIEWER. BeReal 4.88 does have the
// machinery: RealComponents ships ExpandTransitionDelegate,
// ExpandTransitionAnimator, ExpandTransitionPullToDismissController and a
// PinchPanGestureModifier, and the binary carries a
// `beRealPrimaryMediaZoomEnabled` feature-flag key next to a
// `BeRealMediaPrimaryMediaZoomValue`. None of it is reachable from here: they
// are Swift types with no @objc surface, driven through SwiftUI view modifiers
// and a server-controlled flag, so there is no selector to send and no
// controller to present. Reusing them was checked before this was written (see
// the notes in BeaMediaUnlock.m) and the answer was no.
//
// What IS reused is everything that has an actual UIKit surface: the photos are
// the UIImages already decoded into BeReal's own image views, and the save
// button goes through BeaDownloader like the floating one does. BeReal's own
// gesture view over the photo is deliberately left alone rather than
// re-enabled - see BeaMediaUnlock for why.
//
// Strictly local. It reads two UIImages and shows them. It sends nothing,
// changes no view model, and touches no post state - opening it is exactly as
// visible to BeReal as taking a screenshot.
@interface BeaMediaViewer : UIViewController

// `images` is the post's photos, largest first (the order
// +qualifyingImageViewsInView: already returns). `index` is the one to show
// large - which is how "tap the side photo" fronts the side photo without
// touching anything in the feed.
//
// Presented from the window's own top-most controller, because the buttons this
// is opened from live on the UIWindow and so have no ancestor view controller
// of their own (the same reason the download picker is presented that way).
+ (void)presentImages:(NSArray<UIImage *> *)images
           startIndex:(NSUInteger)index
           fromWindow:(UIWindow *)window;

@end
