#import <UIKit/UIKit.h>

// The MiniBea settings screen. Four ways in, deliberately:
//
//  - long-press the floating "+" on the home feed;
//  - long-press the download button and pick "MiniBea settings" from the sheet;
//  - long-press anywhere with two fingers;
//  - the BeFake composer's own menu.
//
// The first two are the two buttons this screen can switch off, so neither can
// be the only way in. Turning the "+" off used to remove the only entry point
// there was, which made that one switch unrecoverable without reinstalling.
//
// Presented from the window's top-most view controller, and deliberately NOT
// marked with +[BeaButton markAsTweakPresented:]: this is a full sheet, the
// download buttons are parented to the window and so do not respect
// presentation z-order on their own, and one of them sitting on top of its own
// settings screen is exactly what that marker caused. Only the small action
// sheets anchored to a button are marked.
//
// ---------------------------------------------------------------------------
// NOT A UITableView ANY MORE
// ---------------------------------------------------------------------------
// Two rounds of device reports described the same symptoms - rows missing
// entirely, tall blank gaps exactly where a row should be, sections split in
// two, text starting under the navigation bar - and two rounds of fixes both
// tried to talk UITableView into measuring its own cells correctly
// (estimatedRowHeight = 0, then = UITableViewAutomaticDimension). Neither
// worked, and the second report's blank gaps were the same height as the rows
// that were meant to be in them, which says the table had *measured* those rows
// correctly and still drew nothing there.
//
// Self-sizing cells are the wrong mechanism for this screen. It is a dozen
// static rows of a title over a two-to-five-line explanation: there is no
// recycling to gain, no scrolling performance to protect, and every one of the
// failure modes above is specific to the estimate-then-correct machinery. It is
// now a UIScrollView with a UIStackView of plain views in it, laid out by
// ordinary Auto Layout, where a row's height is whatever its labels need and
// nothing measures anything twice. Same reasoning as KNOWN_ISSUES.md bug #2:
// the mechanism, not the tuning, was the bug.
@interface BeaSettingsViewController : UIViewController
+ (void)presentFromWindow:(UIWindow *)window;

// The two-finger long press above. Idempotent - safe to call on every layout
// pass; it attaches at most one recognizer per window.
+ (void)installFallbackGestureOnWindow:(UIWindow *)window;
@end
