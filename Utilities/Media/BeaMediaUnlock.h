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
// THE TAP TARGET IS A VIEW OF OURS, NOT A RECOGNIZER ON BEREAL'S.
//
// Two earlier attempts both failed on a real device, for two different
// reasons, and BeaMediaUnlock.m records the evidence for each:
//
//   1. re-enabling UIMainMediaGesturesView's own disabled recognizers, on the
//      theory that the strip was a photo-swap gesture. It wasn't: it is (or
//      includes) whatever BeReal binds to "tap this view on a gated post",
//      which is the post/camera flow - tapping opened the composer.
//   2. holding that overlay's interaction at NO and putting a tap recognizer
//      on the photo underneath, expecting hit-testing to fall through. It does
//      not fall through: -hitTest:withEvent: does not resume searching earlier
//      siblings when a deeper view declines, so the touch simply landed on the
//      gestures view's own still-interactive SwiftUI wrappers - which have the
//      identical frame - and a recognizer on a view in a different branch never
//      saw it. Tapping did nothing at all.
//
// What works is not asking BeReal's view tree for anything: a plain transparent
// BeaMediaTapOverlay, added as the *last* subview of the post's own card and
// framed over each photo. The last sibling wins the hit test outright. BeReal's
// gestures view is still held disabled while the post is gated, but only as
// defence in depth - if SwiftUI rebuilds the card between two reconcile passes,
// the worst case has to be "the tap does nothing", never "the tap opens the
// composer".
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
// it added - including the window-level catcher below. Driven by the switch,
// so it is undoable live rather than at the next relaunch.
+ (void)restoreAll;

// ---------------------------------------------------------------------------
// THE CATCHER, AND WHY A CORRECTLY INSTALLED OVERLAY STILL NEEDS ONE
// ---------------------------------------------------------------------------
// A 0.9.3 device report proved the overlays are built, framed over both photos
// and are the card's last two subviews - and that a hit test at the centre of
// the main photo still stops several levels above them, on the feed's
// `HostingScrollView.PlatformGroupContainer`. Nothing about our overlays can
// fix that: hit testing never reaches a view whose *ancestor* declined the
// point, and the ancestor that declines is one of BeReal's.
//
// So the tap stops being routed by descent. One UITapGestureRecognizer on the
// window receives every touch the window delivers to anything, whatever
// declined it on the way down. Its delegate only accepts a touch that lands
// inside a currently-installed overlay's rect (and not on a button, or on one
// of the tweak's own window-parented buttons), it never cancels a touch, and
// it recognises simultaneously with everything - so on any screen without a
// gated photo under the finger it is inert.
//
// This is deliberately *not* a window-parented tap view, which is the thing
// AGENTS.md rules out: no view is added to the window, nothing outranks a
// modal, and z-ordering is not involved at all.
+ (BOOL)windowCatcherInstalled;
+ (NSUInteger)windowCatcherTapCount;

@end
