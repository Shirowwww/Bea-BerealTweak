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
- (void)toggleVisibilityWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;
@end