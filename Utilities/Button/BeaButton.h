#import <UIKit/UIKit.h>
#import "../Downloader/BeaDownloader.h"

// See BeaButton.m for what these identify and why.
extern NSString *const BeaDownloadButtonAccessibilityID;
extern NSString *const BeaProfilePictureButtonAccessibilityID;
extern NSString *const BeaUploadButtonAccessibilityID;

@interface BeaButton : UIButton
+ (instancetype)downloadButton;
+ (instancetype)profilePictureDownloadButton;
+ (instancetype)uploadButton;

// The floating buttons live on the UIWindow, so they don't respect normal
// presentation z-ordering and Tweak.x hides them whenever something is
// presented over the feed. That rule has to make an exception for sheets this
// tweak puts up itself: the long-press photo picker is anchored to the
// download button, and hiding the button the moment its own menu opens is
// exactly the "long press works but the icon disappears" symptom.
//
// A marker on the controller rather than a global flag, so nested
// presentations (picker on top of the composer, say) each answer for
// themselves and a missed teardown can't leave the app in a stuck state.
+ (void)markAsTweakPresented:(UIViewController *)controller;
+ (BOOL)isTweakPresented:(UIViewController *)controller;
// Download buttons only - rebuilds the long-press front/back/both picker so
// the checkmark tracks the current selection. See BeaButton.m.
- (void)refreshDownloadSelectionMenu;
- (void)toggleVisibilityWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;
@end