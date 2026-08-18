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
// Download buttons only - rebuilds the long-press front/back/both picker so
// the checkmark tracks the current selection. See BeaButton.m.
- (void)refreshDownloadSelectionMenu;
- (void)toggleVisibilityWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;
@end