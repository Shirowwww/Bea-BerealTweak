#import "BeaButton.h"
#import <objc/runtime.h>
#import "../Localization/BeaLocalization.h"
#import "../Settings/BeaSettingsViewController.h"

// Identifiers used by Tweak.x to find and remove any stray/orphaned copy of
// a given button type from the window before adding a fresh one - see
// KNOWN_ISSUES.md bug #1 (stray/duplicate download button) and
// BeaRemoveStrayButtons in Tweak.x.
NSString *const BeaDownloadButtonAccessibilityID = @"BeaDownloadButton";
NSString *const BeaProfilePictureButtonAccessibilityID = @"BeaProfilePictureDownloadButton";
NSString *const BeaUploadButtonAccessibilityID = @"BeaUploadButton";

static const void *BeaTweakPresentedKey = &BeaTweakPresentedKey;

// Weak membership: a button removed from the window and released drops out of
// here on its own, so the per-frame sync can never resurrect or reposition a
// button nobody owns any more.
static NSHashTable<BeaButton *> *BeaAnchoredButtons;

// See +setTweakScreenVisible: - raised for as long as one of this tweak's own
// full screens is up, and read by the per-frame visibility policy in Tweak.x.
static BOOL BeaTweakScreenVisible = NO;

@implementation BeaButton

@synthesize anchorView = _anchorView;
@synthesize anchorCorner = _anchorCorner;
@synthesize anchorInset = _anchorInset;

- (void)attachToAnchor:(UIView *)anchor corner:(BeaButtonCorner)corner inset:(CGPoint)inset {
	self.anchorView = anchor;
	self.anchorCorner = corner;
	self.anchorInset = inset;
	// Frame-driven from here on. Any constraint left over from a previous
	// attachment would fight every frame we set.
	self.translatesAutoresizingMaskIntoConstraints = YES;

	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		BeaAnchoredButtons = [NSHashTable weakObjectsHashTable];
	});
	[BeaAnchoredButtons addObject:self];

	// Placed immediately as well as on the next frame, so a freshly added
	// button never gets one frame at the window origin on its way to the
	// right place.
	[self bea_syncPositionToAnchor];
}

// Returns NO when the button has no business being visible at all - which is
// deliberately the *only* thing that hides it here. Everything about when a
// button should fade is decided elsewhere; this method only ever answers
// "where does it go", and "nowhere" when the anchor is unusable.
- (BOOL)bea_syncPositionToAnchor {
	UIView *anchor = self.anchorView;
	UIWindow *window = self.window;
	if (!anchor || !window || !anchor.window) return NO;

	CGRect frameInWindow = [anchor convertRect:anchor.bounds toView:window];
	if (frameInWindow.size.width < 1 || frameInWindow.size.height < 1) return NO;
	if (!CGRectIntersectsRect(frameInWindow, window.bounds)) return NO;

	CGSize size = self.bounds.size;
	if (size.width < 1 || size.height < 1) {
		[self sizeToFit];
		size = self.bounds.size;
		if (size.width < 1 || size.height < 1) size = CGSizeMake(36, 36);
	}

	CGFloat x, y;
	if (self.anchorCorner == BeaButtonCornerTopLeading) {
		x = CGRectGetMinX(frameInWindow) + self.anchorInset.x;
		y = CGRectGetMinY(frameInWindow) + self.anchorInset.y;
	} else {
		x = CGRectGetMaxX(frameInWindow) - size.width - self.anchorInset.x;
		y = (self.anchorCorner == BeaButtonCornerBottomTrailing)
			? CGRectGetMaxY(frameInWindow) - size.height - self.anchorInset.y
			: CGRectGetMinY(frameInWindow) + self.anchorInset.y;
	}

	CGRect target = CGRectMake(round(x), round(y), size.width, size.height);
	// Written only when it actually moved: this runs every displayed frame and
	// assigning an identical frame still invalidates layout.
	if (!CGRectEqualToRect(self.frame, target)) self.frame = target;
	return YES;
}

- (void)detachFromAnchor {
	self.anchorView = nil;
	[BeaAnchoredButtons removeObject:self];
}

- (void)prepareAsBarButtonItemContent {
	// Off the per-frame placement first: a bar item's custom view is laid out by
	// UIKit inside the navigation bar, and +syncAnchoredButtons writing a frame
	// (and `hidden`) on top of that is two owners for one geometry.
	[self detachFromAnchor];

	self.translatesAutoresizingMaskIntoConstraints = NO;
	// 32pt square, to sit level with BeReal's own 24pt glyphs in their 36x24
	// wrappers without towering over them. Constraints rather than a frame,
	// because a bar item asks its custom view for a size.
	[NSLayoutConstraint activateConstraints:@[
		[self.widthAnchor constraintEqualToConstant:32],
		[self.heightAnchor constraintEqualToConstant:32],
	]];
	self.layer.cornerRadius = 16;
	self.layer.masksToBounds = YES;
	// A bar-hosted button has an ancestor view controller again, so nothing here
	// needs the window-parented workarounds - but the long-press-for-settings
	// recognizer added in +uploadButton presents explicitly anyway and works in
	// both hosting modes unchanged.
}

+ (NSArray<BeaButton *> *)anchoredButtons {
	return BeaAnchoredButtons.allObjects ?: @[];
}

+ (void)syncAnchoredButtons {
	if (BeaAnchoredButtons.count == 0) return;
	// -allObjects rather than enumerating the table itself: hiding a button can
	// release the last strong reference to another one, and mutating a weak
	// table mid-enumeration is not safe.
	for (BeaButton *button in BeaAnchoredButtons.allObjects) {
		BOOL placed = [button bea_syncPositionToAnchor];
		// An anchor that has scrolled away or been recycled means the post
		// this button belonged to is gone. Hiding rather than removing keeps
		// ownership with whichever controller created it - Tweak.x is what
		// tears these down, on its own staleness rules.
		//
		// Both directions, deliberately: this is the single owner of "is the
		// thing I am attached to on screen?", and Tweak.x's per-frame policy
		// (a modal is up, the feed is being dragged) is only ever allowed to
		// hide on top of it. When placement alone decided to hide but never to
		// show, a button whose post scrolled back into view stayed invisible.
		if (button.hidden != !placed) button.hidden = !placed;
	}
}

+ (void)markAsTweakPresented:(UIViewController *)controller {
    if (!controller) return;
    objc_setAssociatedObject(controller, BeaTweakPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)isTweakPresented:(UIViewController *)controller {
    return controller != nil && objc_getAssociatedObject(controller, BeaTweakPresentedKey) != nil;
}

+ (void)setTweakScreenVisible:(BOOL)visible {
    BeaTweakScreenVisible = visible;
    if (!visible) return;
    // Snapped here as well as from the per-frame policy, so the buttons are
    // already gone by the first frame of the presentation animation rather
    // than fading out over the screen sliding up.
    for (BeaButton *button in BeaAnchoredButtons.allObjects) {
        button.alpha = 0;
    }
}

+ (BOOL)isTweakScreenVisible {
    return BeaTweakScreenVisible;
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
    // Frame-placed against its anchor photo every frame - see attachToAnchor:.
    downloadButton.translatesAutoresizingMaskIntoConstraints = YES;
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

    // The download button's long press is the second way into the settings
    // screen, and on an install with the "+" turned off it is the only one
    // that is visible on screen at all. See BeaSettingsViewController's
    // +installFallbackGestureOnWindow: for the third (two fingers, long press,
    // anywhere on the feed), which works even with both buttons off.
    UIWindow *window = self.window;
    [sheet addAction:[UIAlertAction actionWithTitle:BeaLocalized(@"settings.open_hint")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *chosen) {
        if (window) [BeaSettingsViewController presentFromWindow:window];
    }]];

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
    downloadButton.translatesAutoresizingMaskIntoConstraints = YES;
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
    // These are the *fallback* geometry, for the degraded window-parented
    // placement used only on a screen with no navigation bar. In the normal case
    // the button is handed to -prepareAsBarButtonItemContent and hosted as a
    // real UIBarButtonItem inside BeReal's own header, where UIKit lays it out
    // and none of this applies - see the note above BeaSyncUploadButton in
    // Tweak.x for why coordinate-tracking was abandoned.
    uploadButton.translatesAutoresizingMaskIntoConstraints = YES;
    uploadButton.frame = CGRectMake(0, 0, 36, 36);
    uploadButton.layer.cornerRadius = 18;
    uploadButton.layer.masksToBounds = YES;

    // Long press opens MiniBea's own settings. Same reasoning as the download
    // button's picker, for the same reason: an explicit recognizer plus an
    // explicit presentation from the window's top-most controller, because a
    // window-parented view has no ancestor view controller for UIKit's own
    // menu machinery to present from.
    //
    // This gesture is the only entry point to the settings screen on the home
    // feed, so it is also the only way to turn any of this off on a sideloaded
    // install - the accessibility hint says so out loud.
    UILongPressGestureRecognizer *settingsRecognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:uploadButton action:@selector(bea_settingsLongPressed:)];
    settingsRecognizer.cancelsTouchesInView = YES;
    [uploadButton addGestureRecognizer:settingsRecognizer];
    uploadButton.accessibilityHint = BeaLocalized(@"settings.open_hint");

    return uploadButton;
}

- (void)bea_settingsLongPressed:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) return;
    UIWindow *window = self.window;
    if (!window) return;
    [BeaSettingsViewController presentFromWindow:window];
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