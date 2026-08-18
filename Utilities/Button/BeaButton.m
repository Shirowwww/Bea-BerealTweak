#import "BeaButton.h"

// Identifiers used by Tweak.x to find and remove any stray/orphaned copy of
// a given button type from the window before adding a fresh one - see
// KNOWN_ISSUES.md bug #1 (stray/duplicate download button) and
// BeaRemoveStrayButtons in Tweak.x.
NSString *const BeaDownloadButtonAccessibilityID = @"BeaDownloadButton";
NSString *const BeaProfilePictureButtonAccessibilityID = @"BeaProfilePictureDownloadButton";
NSString *const BeaUploadButtonAccessibilityID = @"BeaUploadButton";

@implementation BeaButton
+ (instancetype)downloadButton {
    BeaButton *downloadButton = [BeaButton buttonWithType:UIButtonTypeRoundedRect];
    [downloadButton setTitle:@"" forState:UIControlStateNormal];
    downloadButton.accessibilityIdentifier = BeaDownloadButtonAccessibilityID;

	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19];
	UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:config];
	downloadImage = [downloadImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

	downloadButton.layer.shadowColor = [[UIColor blackColor] CGColor];
    downloadButton.layer.shadowOffset = CGSizeMake(0, 0);
    downloadButton.layer.shadowRadius = 3;
    downloadButton.layer.shadowOpacity = 0.5;

    [downloadButton setImage:downloadImage forState:UIControlStateNormal];
    [downloadButton setTintColor:[UIColor whiteColor]];
    [downloadButton sizeToFit];
	downloadButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadButton addTarget:[BeaDownloader class] action:@selector(downloadImage:) forControlEvents:UIControlEventTouchUpInside];

    // showsMenuAsPrimaryAction is deliberately left off: a plain tap keeps
    // saving straight away (with whatever the user last chose), and the
    // front/back/both picker is on long press. Making the menu the primary
    // action instead would turn every single save into two taps.
    [downloadButton refreshDownloadSelectionMenu];

    return downloadButton;
}

// Rebuilt rather than mutated after every pick, because UIMenu and UIAction
// are immutable value types - the checkmark on the current selection can only
// move by handing the button a new menu.
- (void)refreshDownloadSelectionMenu {
    BeaDownloadSelection current = [BeaDownloader selection];

    NSArray<NSNumber *> *order = @[@(BeaDownloadSelectionBoth), @(BeaDownloadSelectionBack), @(BeaDownloadSelectionFront)];
    NSArray<NSString *> *symbols = @[@"square.on.square", @"camera", @"person.crop.square"];

    // Weak: the button owns the menu, which owns the action, which owns this
    // block - capturing self strongly would make the download button outlive
    // every post it's ever attached to.
    __weak __typeof(self) weakSelf = self;

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    [order enumerateObjectsUsingBlock:^(NSNumber *raw, NSUInteger index, BOOL *stop) {
        BeaDownloadSelection selection = (BeaDownloadSelection)raw.integerValue;
        UIAction *action = [UIAction actionWithTitle:[BeaDownloader titleForSelection:selection]
                                               image:[UIImage systemImageNamed:symbols[index]]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [BeaDownloader setSelection:selection];
            [strongSelf refreshDownloadSelectionMenu];
            [BeaDownloader downloadSelection:selection forButton:strongSelf];
        }];
        action.state = (selection == current) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }];

    self.menu = [UIMenu menuWithTitle:@"Save" children:actions];
    self.accessibilityLabel = @"Save BeReal photos";
    self.accessibilityHint = [NSString stringWithFormat:@"%@. Touch and hold to choose front, back, or both.",
                              [BeaDownloader titleForSelection:current]];
}

+ (instancetype)profilePictureDownloadButton {
    // Same visual treatment as downloadButton (floating over a photo, not
    // sitting in a chrome row like uploadButton) since this sits directly
    // over the profile picture the same way the post download button sits
    // over a post's photo.
    BeaButton *downloadButton = [BeaButton buttonWithType:UIButtonTypeRoundedRect];
    [downloadButton setTitle:@"" forState:UIControlStateNormal];
    downloadButton.accessibilityIdentifier = BeaProfilePictureButtonAccessibilityID;

	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19];
	UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:config];
	downloadImage = [downloadImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

	downloadButton.layer.shadowColor = [[UIColor blackColor] CGColor];
    downloadButton.layer.shadowOffset = CGSizeMake(0, 0);
    downloadButton.layer.shadowRadius = 3;
    downloadButton.layer.shadowOpacity = 0.5;

    [downloadButton setImage:downloadImage forState:UIControlStateNormal];
    [downloadButton setTintColor:[UIColor whiteColor]];
    [downloadButton sizeToFit];
	downloadButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadButton addTarget:[BeaDownloader class] action:@selector(downloadProfilePicture:) forControlEvents:UIControlEventTouchUpInside];

    return downloadButton;
}

+ (instancetype)uploadButton {
    BeaButton *uploadButton = [BeaButton buttonWithType:UIButtonTypeCustom];
    [uploadButton setTitle:@"" forState:UIControlStateNormal];
    uploadButton.accessibilityIdentifier = BeaUploadButtonAccessibilityID;

    // Styled to match the existing add-friend/notification-bell icons in the
    // home feed's top row (solid dark circle, plain glyph) rather than the
    // download button's floating-over-a-photo look, since this sits directly
    // alongside those icons rather than over content.
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
	UIImage *plusImage = [UIImage systemImageNamed:@"plus" withConfiguration:config];
	plusImage = [plusImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    uploadButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];

    [uploadButton setImage:plusImage forState:UIControlStateNormal];
    [uploadButton setTintColor:[UIColor whiteColor]];
    uploadButton.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [uploadButton.widthAnchor constraintEqualToConstant:36],
        [uploadButton.heightAnchor constraintEqualToConstant:36]
    ]];
    uploadButton.layer.cornerRadius = 18;
    uploadButton.layer.masksToBounds = YES;

    return uploadButton;
}

- (void)toggleVisibilityWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    if ((gestureRecognizer.numberOfTouches < 2 && [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) || gestureRecognizer.state == 3) {
        if (gestureRecognizer.state == 2) return;
        [UIView animateWithDuration:0.2 animations:^{
            self.alpha = 1;
        }];
    } else if ((gestureRecognizer.state == 1 || gestureRecognizer.state == 2)) {
        [UIView animateWithDuration:0.2 animations:^{
            self.alpha = 0;
        }];
    }
}
@end