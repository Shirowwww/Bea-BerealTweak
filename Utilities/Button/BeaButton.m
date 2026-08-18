#import "BeaButton.h"
#import <objc/runtime.h>
#import "../Localization/BeaLocalization.h"

// Identifiers used by Tweak.x to find and remove any stray/orphaned copy of
// a given button type from the window before adding a fresh one - see
// KNOWN_ISSUES.md bug #1 (stray/duplicate download button) and
// BeaRemoveStrayButtons in Tweak.x.
NSString *const BeaDownloadButtonAccessibilityID = @"BeaDownloadButton";
NSString *const BeaProfilePictureButtonAccessibilityID = @"BeaProfilePictureDownloadButton";
NSString *const BeaUploadButtonAccessibilityID = @"BeaUploadButton";

static const void *BeaTweakPresentedKey = &BeaTweakPresentedKey;

@implementation BeaButton

+ (void)markAsTweakPresented:(UIViewController *)controller {
    if (!controller) return;
    objc_setAssociatedObject(controller, BeaTweakPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)isTweakPresented:(UIViewController *)controller {
    return controller != nil && objc_getAssociatedObject(controller, BeaTweakPresentedKey) != nil;
}

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

    // A plain tap keeps saving straight away (with whatever the user last
    // chose); the front/back/both picker is on long press. Making the picker
    // the primary action instead would turn every single save into two taps.
    //
    // This is NOT UIButton's built-in `menu` property. That was tried and
    // does nothing here: the download button is added directly to the
    // UIWindow (see the comment on BeaDownloadButtonKey in Tweak.x for why it
    // has to be, to out-rank a gated post's lock overlay), so it has no
    // ancestor view controller - and UIKit's context-menu interaction, which
    // is what `menu` + showsMenuAsPrimaryAction=NO uses on long press, finds
    // nothing to present the menu from and silently gives up. Tapping worked,
    // long-pressing did nothing at all. An explicit recognizer plus an action
    // sheet presented from the window's own top-most controller does not
    // depend on that lookup.
    UILongPressGestureRecognizer *pickerRecognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:downloadButton action:@selector(bea_selectionLongPressed:)];
    // Default, but explicit because the behaviour matters here: once the long
    // press recognises, the button's own touch tracking is cancelled, so
    // lifting the finger does not also fire a download behind the sheet.
    pickerRecognizer.cancelsTouchesInView = YES;
    [downloadButton addGestureRecognizer:pickerRecognizer];

    [downloadButton refreshDownloadSelectionMenu];

    return downloadButton;
}

// Keeps the accessibility hint in step with the persisted selection. (Named
// for what it used to do with UIButton.menu; the picker itself is now built
// on demand in -bea_selectionLongPressed:.)
- (void)refreshDownloadSelectionMenu {
    self.accessibilityLabel = BeaLocalized(@"download.a11y_label");
    self.accessibilityHint = [NSString stringWithFormat:BeaLocalized(@"download.a11y_hint"),
                              [BeaDownloader titleForSelection:[BeaDownloader selection]]];
}

// The window's top-most view controller. Walking the presentation chain
// matters because the feed itself is frequently sitting under something.
- (UIViewController *)bea_presentingViewController {
    UIViewController *controller = self.window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)bea_selectionLongPressed:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) return;

    UIViewController *presenter = [self bea_presentingViewController];
    if (!presenter) return;

    BeaDownloadSelection current = [BeaDownloader selection];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:BeaLocalized(@"download.picker_title")
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    // Without this the button hides itself the instant its own menu opens -
    // see +markAsTweakPresented: and BeaHasPresentedModal in Tweak.x.
    [BeaButton markAsTweakPresented:sheet];

    NSArray<NSNumber *> *order = @[@(BeaDownloadSelectionBoth), @(BeaDownloadSelectionBack), @(BeaDownloadSelectionFront)];
    // Weak: UIAlertAction handlers are retained by the sheet, which is
    // retained by the presentation until dismissed.
    __weak __typeof(self) weakSelf = self;

    for (NSNumber *raw in order) {
        BeaDownloadSelection selection = (BeaDownloadSelection)raw.integerValue;
        NSString *title = [BeaDownloader titleForSelection:selection];
        if (selection == current) {
            // UIAlertAction has no checkmark state, so mark the current
            // choice in the title itself.
            title = [title stringByAppendingString:@" ✓"];
        }
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *chosen) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [BeaDownloader setSelection:selection];
            [strongSelf refreshDownloadSelectionMenu];
            [BeaDownloader downloadSelection:selection forButton:strongSelf];
        }];
        [sheet addAction:action];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:BeaSharedCopy(@"general_cancel", @"general.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // Required on iPad, where an action sheet is presented as a popover and
    // raises an exception without an anchor.
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect = self.bounds;

    [presenter presentViewController:sheet animated:YES completion:nil];
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