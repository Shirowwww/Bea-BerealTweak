#import <UIKit/UIKit.h>

// ============================================================================
// ON-DEVICE DIAGNOSTICS
// ============================================================================
// This repo's whole debugging model assumed a console: MINIBEA_DEBUG=1 and
// `log stream`. A sideloaded install on someone else's phone has neither, so
// every "it still doesn't work" report has had to be answered by guessing at
// the view tree and shipping another IPA - which is why the same four bugs
// have now survived several rounds.
//
// This writes the answer to those guesses into a text file the user can share
// straight out of the settings screen: what the tweak resolved (needles,
// bundle, class names), what it found on the last pass, and the actual view
// hierarchy under the feed, including the accessibility elements the text
// scans depend on.
@interface BeaDiagnostics : NSObject

// Counters the rest of the tweak feeds, so the report can say "the scan ran
// and found nothing" rather than leaving that indistinguishable from "the
// scan never ran".
+ (void)recordGatingMarkers:(NSInteger)count;
// What the gating hider's layer pass saw, and what it changed. A gating
// overlay that BeReal draws through SwiftUI has no view and no accessibility
// element, so "0 markers" and "0 layers" together mean something very different
// from "0 markers, 6 layers" - the first says the overlay is somewhere this
// tweak still cannot see, the second says it was found.
//
// Both numbers, because they answer different questions and only one of them
// was reported before: `hidden` is zero on every pass after the first (the
// cluster is already hidden), which read identically to "found nothing" and
// made the last device report impossible to interpret.
+ (void)recordGatingLayers:(NSInteger)found hidden:(NSInteger)hidden;
+ (void)recordSponsoredMarkers:(NSInteger)count;

// ---------------------------------------------------------------------------
// FEEDBACK-LOOP COUNTERS
// ---------------------------------------------------------------------------
// 0.9.2 froze the app, and "which of the two things that mutate SwiftUI's own
// view state every pass is doing it?" could not be answered from a device at
// all - both are invisible, neither logs, and the symptom of either is the
// same stopped UI. These are permanent for that reason: a rate is the one
// thing that distinguishes "reconciled a few times" from "fought SwiftUI four
// hundred times a second", and it costs an integer increment.
//
// Each keeps a one-second bucket (the live rate), the worst second seen, and a
// running total, and logs once per second when the rate crosses a threshold.
+ (void)countBarItemInsertion;     // navigationItem.leftBarButtonItems assigned
+ (void)countOverlayReorder;       // -bringSubviewToFront: inside a SwiftUI card
+ (void)countLayoutPass;           // -viewDidLayoutSubviews seen on any controller
+ (void)countLayoutScan;           // a pass where the full-tree scans actually ran

// The live per-second rate of bar-item insertions, which is what the "+"
// hosting code uses to decide that SwiftUI's toolbar is overwriting it faster
// than it can be reconciled and that the degraded placement is the honest
// answer. Reading a counter, not another heuristic.
+ (NSInteger)barItemInsertionRate;

// How long one reconcile pass took, so a report can say whether the pass is
// cheap (as designed) or tens of milliseconds (as it was when three full-tree
// scans ran on every layout pass of every controller).
+ (void)recordReconcileDuration:(CFTimeInterval)seconds;

// Which of the two "+" hosting modes gave up, and why.
+ (void)recordUploadBarItemRejection:(NSString *)reason;
+ (void)recordHomeControllerName:(NSString *)name;
+ (void)recordDownloadButtonAnchorFrame:(CGRect)frame;
// What the "+" is currently pinned to, by class and frame.
//
// The report had no way at all to answer "why is the + where it is", which is
// why a report of it moving with the feed could not be told apart from it
// sitting correctly in a transparent navigation bar that the feed scrolls
// underneath. A class name and a frame settle that in one line: BeReal's own
// bar does not move, so an anchor frame that changes between two reports taken
// at different scroll positions is the bug, and one that does not is not.
+ (void)recordUploadButtonAnchor:(NSString *)className frame:(CGRect)frame;

// What the media unlock actually built for the last gated post it reconciled,
// and - the part that matters - what UIKit says would receive a tap in the
// middle of that post's main photo right now.
//
// "The tap does nothing" has three completely different causes that look
// identical from the device: the post was never treated as gated, the overlay
// was built but something is on top of it, or the overlay is there and the
// viewer refused to present. A -hitTest: probe at the photo's centre separates
// the first two in one line, and it is the only way to answer "which view owns
// this tap" without another build-and-flash round. Cheap: one hit test, at the
// ~10Hz reconcile rate, on one point.
+ (void)recordMediaUnlockOverlays:(NSInteger)count
                  gesturesOverlay:(UIView *)gesturesOverlay
                        mainPhoto:(UIView *)photo;

// A one-screen summary - what resolved, what didn't, what the last pass saw.
+ (NSString *)summaryReport;

// The full view hierarchy under `root`, one line per view, with text and
// accessibility elements. This is the part that answers "why did the scan find
// nothing".
+ (NSString *)hierarchyReportForView:(UIView *)root;

// summaryReport + hierarchyReportForView: over the current key window, written
// to a file in the app's tmp directory. Returns the file URL, or nil.
+ (NSURL *)writeFullReport;
@end
