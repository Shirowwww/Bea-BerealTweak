#import <UIKit/UIKit.h>

// The MiniBea settings screen. Reached by long-pressing the floating "+" on
// the home feed (the same gesture idiom the download button already uses for
// its front/back/both picker), and from the BeFake composer's own menu.
//
// Presented from the window's top-most view controller, and marked with
// +[BeaButton markAsTweakPresented:] so putting it up does not make the
// buttons it configures disappear from underneath it.
@interface BeaSettingsViewController : UITableViewController
+ (void)presentFromWindow:(UIWindow *)window;
@end
