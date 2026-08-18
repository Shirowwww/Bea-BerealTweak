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
+ (void)recordSponsoredMarkers:(NSInteger)count;
+ (void)recordHomeControllerName:(NSString *)name;
+ (void)recordDownloadButtonAnchorFrame:(CGRect)frame;

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
