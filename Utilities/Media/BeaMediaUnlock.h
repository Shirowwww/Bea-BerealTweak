#import <UIKit/UIKit.h>

// ============================================================================
// UNLOCKING A GATED POST'S MEDIA - LOCALLY
// ============================================================================
// A post you have not unlocked yet still has both photos fully decoded in its
// own image views (a device hierarchy dump shows both SDAnimatedImageViews
// carrying a 1206x1608 image); what BeReal withholds is the *interaction*.
// This puts the interaction back, and only the interaction.
//
// WHAT IT DOES NOT DO, deliberately and by construction:
//
//   - it does not spoof HasPosted, and hooks nothing in BeReal's post/upload
//     domain;
//   - it does not fabricate a post, an upload or a moment;
//   - it sends nothing and rewrites no request. Every symbol it touches is a
//     UIView, a UIGestureRecognizer or a UIImage that is already on screen.
//
// From BeReal's side this is indistinguishable from the user taking a
// screenshot: the pixels were already there, and nothing about the account's
// state is asserted to be different.
//
// ONE LAYER: a viewer of our own, added directly to the photo - and BeReal's
// own gesture-catching overlay held *out of the way* of it, not put back.
//
// RealComponents.UIMainMediaGesturesView sits as a sibling directly on top of
// the photo (confirmed from a device hierarchy dump: identical frame, later in
// the sibling list, which is what wins hit-testing), so whichever of the two
// is interactive is the one that receives every tap on that spot - never both,
// and a recognizer on the photo can never fire while the overlay above it is
// still hit-testable, whatever state the overlay's *own* recognizers are in.
//
// An earlier version tried the opposite: re-enabling that overlay's own
// disabled recognizers, on the theory that the strip was a photo-swap gesture.
// On a real device it wasn't - it was (or included) whatever BeReal binds to
// "tap this view on a gated post", which turned out to be the post/camera
// flow: tapping opened the composer instead of this viewer. This class now
// does the reverse for a gated post: keeps that overlay's interaction held at
// NO for as long as the post stays gated and this feature is on, re-asserted
// every reconcile pass (BeaCollectVisiblePosts in Tweak.x force-enables
// interaction on every view in a visible post, including this one, for an
// unrelated reason - see BeaMediaUnlock.m), so hit-testing always falls
// through to the photo, where the tap this class adds is the only thing left
// to receive it.
//
// BeReal's own full-screen expand and pinch-zoom exist (ExpandTransitionDelegate,
// PinchPanGestureModifier, a `beRealPrimaryMediaZoomEnabled` flag in the
// 4.88 binary) but are pure Swift/SwiftUI behind a server-side flag, with
// no ObjC selector to send and no view controller to present. Rather than
// guess at Swift internals, a tap on either photo of a *gated* post opens
// BeaMediaViewer - see that header for the reasoning.
//
// Scoped to gated posts only, on the same evidence the gating hider uses
// (+photoIsGated:inCard:). That is what keeps it out of the way on a normal
// post, where BeReal's own gestures already work and adding a second tap
// handler would only interfere.
@interface BeaMediaUnlock : NSObject

// Reconcile one post currently on screen. Called from the tweak's per-frame
// policy at the same ~10Hz the download buttons are reconciled at, because a
// post scrolls into view without invalidating anyone's layout.
+ (void)syncPostWithContainer:(UIView *)container
                    mainPhoto:(UIImageView *)photo
                         root:(UIView *)root;

// Puts back every interaction flag this changed, and removes every recognizer
// it added. Driven by the switch, so it is undoable live rather than at the
// next relaunch.
+ (void)restoreAll;

@end
