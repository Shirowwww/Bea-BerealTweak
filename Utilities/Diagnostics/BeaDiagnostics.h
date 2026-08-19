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
