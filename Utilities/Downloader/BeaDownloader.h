#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Which of a post's two photos the download button saves. A BeReal is always
// exactly two images - BeReal's own API calls them "primary" (the back camera,
// the big one) and "secondary" (the front camera selfie, shown as the PiP by
// default), and those two words appear literally in the CDN paths, which is
// what makes reliable per-camera selection possible at all. See
// +cameraForImageView: in BeaDownloader.m.
typedef NS_ENUM(NSInteger, BeaDownloadSelection) {
	BeaDownloadSelectionBoth = 0,
	BeaDownloadSelectionBack = 1,
	BeaDownloadSelectionFront = 2,
};

@interface BeaDownloader : NSObject
// Persisted across launches so a tap on the button keeps doing whatever the
// user last picked from the long-press menu, instead of resetting to "both"
// every time BeReal is relaunched.
+ (BeaDownloadSelection)selection;
+ (void)setSelection:(BeaDownloadSelection)selection;
+ (NSString *)titleForSelection:(BeaDownloadSelection)selection;

// Saves using the currently persisted selection - this is the button's plain
// tap action.
+ (void)downloadImage:(id)sender;
// Saves a specific selection without changing the persisted one. Used by the
// long-press menu, which both remembers the choice and acts on it immediately.
+ (void)downloadSelection:(BeaDownloadSelection)selection forButton:(UIButton *)button;
+ (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo;
// Recursively finds BeReal's actual photo image views under root, deduped and
// sorted by displayed area descending (largest/most prominent first). Used
// both to pick which images to save and, by BeaButton's host cell hook, to
// find a stable anchor to position the download button against.
+ (NSArray<UIImageView *> *)qualifyingImageViewsInView:(UIView *)root;
// Walks up from anchor's superview looking for the smallest ancestor (short
// of root) that itself contains a full front+back pair. The feed keeps
// adjacent posts partially on-screen for smooth swiping, so a single post's
// own local container (this) is what qualifyingImageViewsInView: needs to be
// scoped to - anything wider can pick up a neighboring post's photo instead
// of this post's own second (usually much smaller) camera.
+ (UIView *)localContainerForAnchor:(UIView *)anchor upToRoot:(UIView *)root;
// Whether view's frame currently intersects its own window's bounds. Used to
// tell a scrolled-away anchor apart from one that's still genuinely visible -
// isDescendantOfView: alone stays true long after a post has scrolled off
// screen, until BeReal's own view recycling actually tears it down.
+ (BOOL)isViewOnScreen:(UIView *)view;
// Whether anchor isn't just on-screen but displayed at close to full post
// width - true for the single-post feed this button targets, false for
// grid-view thumbnails and small chrome elements. Only used to decide
// whether to create/keep the button - qualifyingImageViewsInView: (and
// downloadImage:'s search) must keep using isViewOnScreen:, since the front
// camera's PiP is legitimately much narrower and still has to qualify there.
+ (BOOL)isAnchorDisplayedProminently:(UIView *)anchor;
// SwiftUI-bridged wrapper/layout views commonly ship with interaction
// disabled, only re-enabling it on specific interactive children - a button
// added under such an ancestor never receives touches regardless of its own
// setting, since hit-testing stops descending as soon as it hits a disabled
// ancestor. Forces it back on from view up to and including root.
+ (void)enableUserInteractionFromView:(UIView *)view upToRoot:(UIView *)root;
// Same idea as enableUserInteractionFromView:upToRoot:, but downward through
// every descendant instead of upward through ancestors - a gated post
// disables interaction well beyond just whatever blocked our own button
// (e.g. BeReal's own tap-to-swap-camera gesture on the photo itself), and
// there's no single specific descendant to target it at.
+ (void)enableUserInteractionRecursivelyInView:(UIView *)view;
// Finds and hides the "Post to view" lock overlay (icon, title/body text,
// and CTA button) that a gated post draws above its own photo - separate
// from, and unaffected by, the CAFilter blur-removal hook, since it's a
// distinct always-shown UI element rather than part of the image itself.
// Scoped to root and excludes anything containing one of images, so this
// can't reach into an unrelated screen (e.g. the actual camera/upload flow,
// which never has a qualifying photo pair to exclude against in the first
// place).
//
// Two passes, because on BeReal 4.88 the overlay frequently is not a view at
// all. SwiftUI only materializes a UIView for content it has to bridge to
// UIKit (the photos, the "..." button); a plain ZStack of a scrim, two Texts
// and a Button is drawn straight into CALayers with no view and no published
// accessibility element, which is exactly what "0 marker(s) found" on a screen
// that visibly says "Poste pour voir" means. When the view/accessibility scan
// finds nothing, the layer pass looks for the drawing layers stacked directly
// over the post's own photo instead.
+ (void)hideGatingOverlaysInView:(UIView *)root excludingImages:(NSArray<UIImageView *> *)images;
// Puts back everything the gating hider hid, so the switch works in both
// directions rather than needing a relaunch.
+ (void)restoreGatingOverlays;
// Records which post-local container downloadImage: should search when this
// button is tapped. The button itself is attached to the window rather than
// to that container (see Tweak.x) so a gated post's lock overlay - drawn
// above the post's own content - can never end up covering it; this is what
// lets downloadImage: still find the right pair of photos despite the button
// no longer living anywhere near them in the view tree.
+ (void)setSearchRoot:(UIView *)root forButton:(UIButton *)button;
// Records which CDN URL downloadProfilePicture: should fetch when this button
// is tapped - snapshotted at button-creation time rather than re-read at tap
// time, since the "currently captured" profile picture URL is a single global
// value that could otherwise have moved on to a different profile by the time
// the user actually taps.
+ (void)setProfilePictureURLString:(NSString *)urlString forButton:(UIButton *)button;
// Unlike downloadImage:, which saves whatever a UIImageView is already
// displaying, this fetches the URL recorded via setProfilePictureURLString:
// forButton: over the network - profile pictures aren't found by walking the
// view hierarchy the way post photos are (see Tweak.x for why), only by a URL
// captured out of a network response.
+ (void)downloadProfilePicture:(id)sender;
@end