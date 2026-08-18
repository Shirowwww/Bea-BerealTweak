#import <UIKit/UIKit.h>
#import "../Downloader/BeaDownloader.h"

// See BeaButton.m for what these identify and why.
extern NSString *const BeaDownloadButtonAccessibilityID;
extern NSString *const BeaProfilePictureButtonAccessibilityID;
extern NSString *const BeaUploadButtonAccessibilityID;

// Which corner of its anchor a window-parented button sits in.
typedef NS_ENUM(NSInteger, BeaButtonCorner) {
	BeaButtonCornerTopTrailing,
	BeaButtonCornerBottomTrailing,
};

@interface BeaButton : UIButton
+ (instancetype)downloadButton;
+ (instancetype)profilePictureDownloadButton;
+ (instancetype)uploadButton;

// The floating buttons live on the UIWindow, so they don't respect normal
// presentation z-ordering and Tweak.x hides them whenever something is
// presented over the feed. That rule has to make an exception for sheets this
// tweak puts up itself: the long-press photo picker is anchored to the
// download button, and hiding the button the moment its own menu opens is
// exactly the "long press works but the icon disappears" symptom.
//
// A marker on the controller rather than a global flag, so nested
// presentations (picker on top of the composer, say) each answer for
// themselves and a missed teardown can't leave the app in a stuck state.
+ (void)markAsTweakPresented:(UIViewController *)controller;
+ (BOOL)isTweakPresented:(UIViewController *)controller;
// Download buttons only - rebuilds the long-press front/back/both picker so
// the checkmark tracks the current selection. See BeaButton.m.
- (void)refreshDownloadSelectionMenu;
- (void)toggleVisibilityWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;

// ---------------------------------------------------------------------------
// ANCHORING
// ---------------------------------------------------------------------------
// Both photo buttons are parented to the UIWindow (they have to be, to
// out-rank a gated post's lock overlay) but must appear in a corner of a photo
// that lives several levels down inside BeReal's feed. That used to be done
// with NSLayoutConstraints from the button to the photo's own anchors, and it
// is the direct cause of two of the longest-running bugs in KNOWN_ISSUES.md:
//
//  - The photo is inside a scroll view. Scrolling moves content by changing
//    the scroll view's bounds origin, which is not a layout change of the
//    photo's frame inside its superview, so the constraint solver is never
//    asked to re-place the button. It sits where the photo *was*.
//  - When the photo is finally recycled out of the hierarchy, the button and
//    the photo stop sharing a common ancestor and UIKit deactivates those
//    constraints for us. The button is then completely unconstrained and
//    lands at the origin - which is exactly the "stuck in the top-left corner
//    near the nav bar" artifact reported against the first post, filed as
//    KNOWN_ISSUES.md bug #1 and blamed for years on duplicate buttons.
//
// Placing the button by frame, every displayed frame, from the anchor's own
// -convertRect:toView: has neither failure mode: -convertRect: accounts for
// scroll offsets, and an anchor that has gone away reports itself gone rather
// than silently dropping the button somewhere.
@property (nonatomic, weak) UIView *anchorView;
@property (nonatomic, assign) BeaButtonCorner anchorCorner;
@property (nonatomic, assign) CGPoint anchorInset;

// Registers the button for per-frame placement and takes it off Auto Layout.
- (void)attachToAnchor:(UIView *)anchor corner:(BeaButtonCorner)corner inset:(CGPoint)inset;

// Called once per displayed frame from the tweak's display link. Hides any
// button whose anchor is gone, off-screen, or not laid out yet.
+ (void)syncAnchoredButtons;
@end