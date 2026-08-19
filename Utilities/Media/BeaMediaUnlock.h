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
// TWO LAYERS, IN ORDER OF PREFERENCE.
//
//  1. BeReal's own gestures. Every post - gated or not - mounts a
//     RealComponents.UIMainMediaGesturesView over its photo, and that view is a
//     real UIView with real UIGestureRecognizers on it. Where a gated post has
//     turned that off, this turns it back on (recording what it changed), so
//     BeReal's own tap-to-swap keeps being BeReal's own tap-to-swap.
//
//  2. A viewer of our own, for what layer 1 cannot reach. BeReal's full-screen
//     expand and pinch-zoom exist (ExpandTransitionDelegate,
//     PinchPanGestureModifier, a `beRealPrimaryMediaZoomEnabled` flag in the
//     4.88 binary) but are pure Swift/SwiftUI behind a server-side flag, with
//     no ObjC selector to send and no view controller to present. Rather than
//     guess at Swift internals, a tap on either photo of a *gated* post opens
//     BeaMediaViewer - see that header for the reasoning.
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

// Puts back every gesture recognizer state and interaction flag this changed,
// and removes every recognizer it added. Driven by the switch, so it is
// undoable live rather than at the next relaunch.
+ (void)restoreAll;

@end
