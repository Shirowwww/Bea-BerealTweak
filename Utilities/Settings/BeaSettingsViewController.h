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
// floating buttons are parented to the window and so do not respect
// presentation z-order on their own, and a "+" sitting on top of its own
// settings screen is exactly what that marker caused. Only the small action
// sheets anchored to a button are marked.
@interface BeaSettingsViewController : UITableViewController
+ (void)presentFromWindow:(UIWindow *)window;

// The two-finger long press above. Idempotent - safe to call on every layout
// pass; it attaches at most one recognizer per window.
+ (void)installFallbackGestureOnWindow:(UIWindow *)window;
@end
