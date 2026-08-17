#import <UIKit/UIKit.h>

@interface BeaInfoViewController : UIViewController
@property (nonatomic, strong) UIImageView *profileImageView;
@property (nonatomic, strong) UILabel *twitterLabel;
@property (nonatomic, strong) UILabel *smallLabel;
@property (nonatomic, strong) UIView *wrapperView;
@property (nonatomic, strong) UILabel *versionLabel;
@end

// Kept in sync by hand with Tweak.h's own TWEAK_VERSION - the two are
// compiled into separate translation units, so a single #define can't be
// shared directly. This one had drifted to a stale "1.3.7" (from long before
// this fork), silently showing the wrong version on the in-app Info screen;
// the #ifndef guard is just a safety net in case a future refactor ever pulls
// both headers into the same file.
#ifndef TWEAK_VERSION
#define TWEAK_VERSION @"0.4.0-merged"
#endif