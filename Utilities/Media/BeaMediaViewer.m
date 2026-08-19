#import "BeaMediaViewer.h"
#import "../Button/BeaButton.h"
#import "../Debug/BeaDebug.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"

@interface BeaMediaViewer () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<UIImage *> *images;
@property (nonatomic, assign) NSUInteger frontIndex;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIButton *thumbnailButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *saveButton;

// The dismiss drag only owns the gesture while the photo is at rest. Zoomed in,
// the same downward drag is a pan of the image and must stay with the scroll
// view - see -gestureRecognizerShouldBegin:.
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;
@end

@implementation BeaMediaViewer

+ (void)presentImages:(NSArray<UIImage *> *)images
           startIndex:(NSUInteger)index
           fromWindow:(UIWindow *)window {
	if (images.count == 0 || !window) return;

	UIViewController *presenter = window.rootViewController;
	while (presenter.presentedViewController) presenter = presenter.presentedViewController;
	if (!presenter) return;
	// Already up. The tap that opens this comes off a photo in the feed, and
	// the feed is still laid out (and still taking taps) underneath.
	if ([presenter isKindOfClass:[BeaMediaViewer class]]) return;

	BeaMediaViewer *viewer = [[BeaMediaViewer alloc] init];
	viewer.images = images;
	viewer.frontIndex = MIN(index, images.count - 1);
	viewer.modalPresentationStyle = UIModalPresentationOverFullScreen;
	viewer.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

	// Deliberately NOT marked with +markAsTweakPresented:. That exemption is
	// for the small sheets anchored to a button, which have to keep their own
	// button visible underneath them. This covers the whole screen, so every
	// injected button should be out of the way exactly as it is for BeReal's
	// own modals.
	[presenter presentViewController:viewer animated:YES completion:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];

	self.scrollView = [[UIScrollView alloc] init];
	self.scrollView.delegate = self;
	self.scrollView.minimumZoomScale = 1.0;
	self.scrollView.maximumZoomScale = 5.0;
	self.scrollView.showsHorizontalScrollIndicator = NO;
	self.scrollView.showsVerticalScrollIndicator = NO;
	self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.scrollView];

	self.imageView = [[UIImageView alloc] init];
	self.imageView.contentMode = UIViewContentModeScaleAspectFit;
	self.imageView.userInteractionEnabled = YES;
	self.imageView.isAccessibilityElement = YES;
	self.imageView.accessibilityLabel = BeaLocalized(@"viewer.a11y_photo");
	[self.scrollView addSubview:self.imageView];

	self.thumbnailButton = [self bea_thumbnailButton];
	[self.view addSubview:self.thumbnailButton];

	self.closeButton = [self bea_chromeButtonWithSymbol:@"xmark"
	                                       accessibility:BeaSharedCopy(@"general_close", @"viewer.close")
	                                              action:@selector(bea_close)];
	[self.view addSubview:self.closeButton];

	self.saveButton = [self bea_chromeButtonWithSymbol:@"arrow.down.circle.fill"
	                                      accessibility:BeaSharedCopy(@"general_save", @"viewer.save")
	                                             action:@selector(bea_save)];
	// Matched to the symbol configuration +flashCheckmarkOnButton: restores.
	// That method is shared with the floating download button and rebuilds the
	// image at a fixed 19pt regular, so a save would otherwise leave this
	// button visibly a size heavier than it started.
	[self.saveButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"
	                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19]]
	                 forState:UIControlStateNormal];
	[self.view addSubview:self.saveButton];

	[NSLayoutConstraint activateConstraints:@[
		[self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

		[self.closeButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
		[self.closeButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
		[self.closeButton.widthAnchor constraintEqualToConstant:40],
		[self.closeButton.heightAnchor constraintEqualToConstant:40],

		[self.saveButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
		[self.saveButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
		[self.saveButton.widthAnchor constraintEqualToConstant:40],
		[self.saveButton.heightAnchor constraintEqualToConstant:40],

		// Bottom-leading, so it cannot sit under either chrome button and does
		// not cover the middle of the photo.
		[self.thumbnailButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
		[self.thumbnailButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
		[self.thumbnailButton.widthAnchor constraintEqualToConstant:84],
		[self.thumbnailButton.heightAnchor constraintEqualToConstant:112],
	]];

	// Double tap to zoom, the standard photo-viewer gesture. Required to fail
	// before the single tap, or every double tap also closes the viewer.
	UITapGestureRecognizer *doubleTap =
		[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_doubleTapped:)];
	doubleTap.numberOfTapsRequired = 2;
	[self.scrollView addGestureRecognizer:doubleTap];

	UITapGestureRecognizer *singleTap =
		[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_close)];
	[singleTap requireGestureRecognizerToFail:doubleTap];
	[self.scrollView addGestureRecognizer:singleTap];

	self.dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bea_dismissPanned:)];
	self.dismissPan.delegate = self;
	[self.view addGestureRecognizer:self.dismissPan];

	[self bea_applyFrontImage];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	[self bea_layoutImageView];
}

// ------------------------------------------------------------------ chrome --

- (UIButton *)bea_chromeButtonWithSymbol:(NSString *)symbolName
                           accessibility:(NSString *)label
                                  action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18
	                                                                                     weight:UIImageSymbolWeightSemibold];
	[button setImage:[UIImage systemImageNamed:symbolName withConfiguration:config] forState:UIControlStateNormal];
	button.tintColor = [UIColor whiteColor];
	button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
	button.layer.cornerRadius = 20;
	button.layer.masksToBounds = YES;
	button.accessibilityLabel = label;
	button.translatesAutoresizingMaskIntoConstraints = NO;
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (UIButton *)bea_thumbnailButton {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	button.imageView.contentMode = UIViewContentModeScaleAspectFill;
	button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
	button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
	button.layer.cornerRadius = 10;
	button.layer.masksToBounds = YES;
	button.layer.borderWidth = 2;
	button.layer.borderColor = [UIColor whiteColor].CGColor;
	button.accessibilityLabel = BeaLocalized(@"viewer.swap");
	[button addTarget:self action:@selector(bea_swap) forControlEvents:UIControlEventTouchUpInside];
	return button;
}

// ------------------------------------------------------------------ images --

- (UIImage *)bea_frontImage {
	return self.images[self.frontIndex];
}

- (UIImage *)bea_backImage {
	if (self.images.count < 2) return nil;
	return self.images[(self.frontIndex + 1) % self.images.count];
}

- (void)bea_applyFrontImage {
	self.imageView.image = [self bea_frontImage];
	UIImage *other = [self bea_backImage];
	[self.thumbnailButton setImage:other forState:UIControlStateNormal];
	// One photo (a post whose second camera never loaded) is a real case; there
	// is simply nothing to swap to.
	self.thumbnailButton.hidden = (other == nil);

	self.scrollView.zoomScale = 1.0;
	[self.view setNeedsLayout];
}

- (void)bea_swap {
	if (self.images.count < 2) return;
	self.frontIndex = (self.frontIndex + 1) % self.images.count;
	[UIView transitionWithView:self.view
	                  duration:0.2
	                   options:UIViewAnimationOptionTransitionCrossDissolve
	                animations:^{ [self bea_applyFrontImage]; }
	                completion:nil];
}

// The image view is sized to the aspect-fit rect of the photo rather than to
// the scroll view, and the content size follows it. Doing it the other way
// round (a full-bleed image view with contentMode fit) is the classic source of
// a photo that pans into empty space at zoom > 1, because the scroll view's
// content is then mostly transparent padding.
- (void)bea_layoutImageView {
	UIImage *image = self.imageView.image;
	CGSize bounds = self.scrollView.bounds.size;
	if (!image || bounds.width < 1 || bounds.height < 1) return;

	CGFloat scale = MIN(bounds.width / image.size.width, bounds.height / image.size.height);
	CGSize fitted = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));

	self.imageView.bounds = CGRectMake(0, 0, fitted.width, fitted.height);
	self.scrollView.contentSize = fitted;
	[self bea_centerImageView];
}

- (void)bea_centerImageView {
	CGSize bounds = self.scrollView.bounds.size;
	CGSize content = self.scrollView.contentSize;
	self.imageView.center = CGPointMake(MAX(content.width, bounds.width) / 2.0,
	                                    MAX(content.height, bounds.height) / 2.0);
}

// ---------------------------------------------------------------- gestures --

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
	return self.imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
	[self bea_centerImageView];
}

- (void)bea_doubleTapped:(UITapGestureRecognizer *)recognizer {
	if (self.scrollView.zoomScale > self.scrollView.minimumZoomScale) {
		[self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
		return;
	}

	// Zoom around the tap, not the centre.
	CGPoint point = [recognizer locationInView:self.imageView];
	CGFloat scale = 3.0;
	CGSize bounds = self.scrollView.bounds.size;
	CGRect target = CGRectMake(point.x - (bounds.width / scale) / 2.0,
	                           point.y - (bounds.height / scale) / 2.0,
	                           bounds.width / scale,
	                           bounds.height / scale);
	[self.scrollView zoomToRect:target animated:YES];
}

// Drag down to dismiss, with the photo following the finger. Only while the
// photo is at rest - see -gestureRecognizerShouldBegin:.
- (void)bea_dismissPanned:(UIPanGestureRecognizer *)recognizer {
	CGPoint translation = [recognizer translationInView:self.view];

	switch (recognizer.state) {
		case UIGestureRecognizerStateChanged: {
			CGFloat progress = MIN(MAX(translation.y / 300.0, 0.0), 1.0);
			self.scrollView.transform = CGAffineTransformMakeTranslation(0, MAX(translation.y, 0));
			self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0 - progress * 0.7];
			break;
		}
		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled: {
			CGFloat velocity = [recognizer velocityInView:self.view].y;
			if (translation.y > 120 || velocity > 900) {
				[self bea_close];
				return;
			}
			[UIView animateWithDuration:0.25 animations:^{
				self.scrollView.transform = CGAffineTransformIdentity;
				self.view.backgroundColor = [UIColor blackColor];
			}];
			break;
		}
		default:
			break;
	}
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
	if (gestureRecognizer != self.dismissPan) return YES;
	// Zoomed in, a downward drag is a pan of the photo. Handing it to the
	// dismiss gesture instead would make a zoomed photo impossible to look
	// around.
	if (self.scrollView.zoomScale > self.scrollView.minimumZoomScale + 0.01) return NO;

	CGPoint velocity = [self.dismissPan velocityInView:self.view];
	return velocity.y > 0 && fabs(velocity.y) > fabs(velocity.x);
}

// ----------------------------------------------------------------- actions --

- (void)bea_close {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)bea_save {
	UIImage *image = [self bea_frontImage];
	if (!image) return;
	// The same save path as the floating download button, so this reports a
	// finished save the same way (disabled, green checkmark, back to normal).
	[BeaDownloader saveImages:@[image] forButton:self.saveButton];
}

@end
