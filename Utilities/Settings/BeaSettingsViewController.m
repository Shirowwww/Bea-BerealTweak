#import "BeaSettingsViewController.h"
#import "BeaSettings.h"
#import "../Button/BeaButton.h"
#import "../Diagnostics/BeaDiagnostics.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import "../Runtime/BeaOwnership.h"
#import "../Runtime/BeaRuntime.h"
#import <objc/runtime.h>

// One row. `settingKey` nil means an action row rather than a switch.
//
// `effect` is the third line: when the change actually takes hold. It is not
// decoration - every ad switch in this tweak has at some point looked broken on
// a device purely because the user could not tell "this does nothing" from
// "this does nothing until the feed reloads", and answering that in the row
// itself is cheaper than another round trip.
@interface BeaSettingsRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *effect;
@property (nonatomic, copy) NSString *settingKey;
@property (nonatomic, copy) void (^action)(void);
@end

@implementation BeaSettingsRow
+ (instancetype)toggle:(NSString *)key title:(NSString *)title detail:(NSString *)detail effect:(NSString *)effect {
	BeaSettingsRow *row = [BeaSettingsRow new];
	row.settingKey = key;
	row.title = title;
	row.detail = detail;
	row.effect = effect;
	return row;
}
+ (instancetype)action:(NSString *)title detail:(NSString *)detail block:(void (^)(void))block {
	BeaSettingsRow *row = [BeaSettingsRow new];
	row.title = title;
	row.detail = detail;
	row.action = block;
	return row;
}
// A row with no control at all - a paragraph of text in the same visual
// container as the switches. Used for the three-finger override, which has no
// stored value to show.
+ (instancetype)note:(NSString *)title detail:(NSString *)detail {
	BeaSettingsRow *row = [BeaSettingsRow new];
	row.title = title;
	row.detail = detail;
	return row;
}
@end

@interface BeaSettingsSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSArray<BeaSettingsRow *> *rows;
@end

@implementation BeaSettingsSection
@end

// ---------------------------------------------------------------------------
// ONE ROW
// ---------------------------------------------------------------------------
// Plain Auto Layout, top to bottom, with no ambiguity anywhere: the labels are
// pinned to the container's top and bottom, so the row's height is exactly what
// its text needs and no estimate is ever involved. This is the whole of the
// settings-layout fix - see the header.
@interface BeaSettingsRowView : UIView
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) BeaSettingsRow *row;
// Declared, not just defined: the compiler rejects a selector it has never
// seen an interface for, which is the same "no visible @interface declares the
// selector" trap documented above the UIViewController hook in Tweak.x.
- (instancetype)initWithRow:(BeaSettingsRow *)row target:(id)target;
@end

@implementation BeaSettingsRowView

- (instancetype)initWithRow:(BeaSettingsRow *)row target:(id)target {
	self = [super initWithFrame:CGRectZero];
	if (!self) return nil;
	_row = row;

	UILabel *title = [[UILabel alloc] init];
	title.text = row.title;
	title.numberOfLines = 0;
	title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	title.adjustsFontForContentSizeCategory = YES;
	title.textColor = [UIColor labelColor];
	title.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:title];

	UILabel *detail = nil;
	if (row.detail.length > 0) {
		detail = [[UILabel alloc] init];
		detail.text = row.detail;
		detail.numberOfLines = 0;
		detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
		detail.adjustsFontForContentSizeCategory = YES;
		detail.textColor = [UIColor secondaryLabelColor];
		detail.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:detail];
	}

	UILabel *effect = nil;
	if (row.effect.length > 0) {
		effect = [[UILabel alloc] init];
		effect.text = row.effect;
		effect.numberOfLines = 0;
		effect.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
		effect.adjustsFontForContentSizeCategory = YES;
		effect.textColor = [UIColor tertiaryLabelColor];
		effect.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:effect];
	}

	// The trailing control: a switch, a chevron, or nothing.
	UIView *accessory = nil;
	if (row.settingKey) {
		_toggle = [[UISwitch alloc] init];
		_toggle.on = [BeaSettings boolForKey:row.settingKey];
		// The key rides on the control itself, so the handler needs no index and
		// cannot go stale if the screen is rebuilt underneath it.
		objc_setAssociatedObject(_toggle, @selector(bea_toggleChanged:), row.settingKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[_toggle addTarget:target action:@selector(bea_toggleChanged:) forControlEvents:UIControlEventValueChanged];
		accessory = _toggle;
	} else if (row.action) {
		UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
		chevron.tintColor = [UIColor tertiaryLabelColor];
		chevron.contentMode = UIViewContentModeScaleAspectFit;
		accessory = chevron;
	}
	accessory.translatesAutoresizingMaskIntoConstraints = NO;
	if (accessory) [self addSubview:accessory];

	// A switch must never be squeezed by a long title, and a long title must
	// never be truncated by the switch - so the text column is the one that
	// stretches.
	[accessory setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	[accessory setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

	UILayoutGuide *text = [[UILayoutGuide alloc] init];
	[self addLayoutGuide:text];

	NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
		[text.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
		[text.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
		[text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],

		[title.topAnchor constraintEqualToAnchor:text.topAnchor],
		[title.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
		[title.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
	]];

	UIView *last = title;
	if (detail) {
		[constraints addObjectsFromArray:@[
			[detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
			[detail.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
			[detail.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
		]];
		last = detail;
	}
	if (effect) {
		[constraints addObjectsFromArray:@[
			[effect.topAnchor constraintEqualToAnchor:last.bottomAnchor constant:4],
			[effect.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
			[effect.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
		]];
		last = effect;
	}
	// The one constraint that decides the row's height. Every label above is
	// chained to it, so the row is exactly as tall as its content.
	[constraints addObject:[last.bottomAnchor constraintEqualToAnchor:text.bottomAnchor]];

	if (accessory) {
		[constraints addObjectsFromArray:@[
			[accessory.leadingAnchor constraintEqualToAnchor:text.trailingAnchor constant:12],
			[accessory.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
			[accessory.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		]];
	} else {
		[constraints addObject:[text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16]];
	}

	[NSLayoutConstraint activateConstraints:constraints];
	return self;
}

@end

// The settings screen's own navigation controller.
//
// It exists only to own the "one of this tweak's screens is on screen" flag.
// Hanging that off BeaSettingsViewController itself does not work: pushing the
// diagnostics summary takes the settings screen off the window, so its
// -viewDidDisappear: fires while a tweak screen is still very much up, and the
// injected buttons would come back on top of the summary. The navigation
// controller is on screen for the whole presentation, pushes included.
@interface BeaSettingsNavigationController : UINavigationController
@end

@implementation BeaSettingsNavigationController

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[BeaButton setTweakScreenVisible:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[BeaButton setTweakScreenVisible:NO];
}

@end

@interface BeaSettingsViewController ()
@property (nonatomic, copy) NSArray<BeaSettingsSection *> *sections;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation BeaSettingsViewController

+ (void)presentFromWindow:(UIWindow *)window {
	// The single choke point for "can this screen open at all". While the tweak
	// is suspended none of its own UI may appear - the three-finger override is
	// supposed to leave BeReal looking untouched, and the two-finger settings
	// gesture is still installed on the window because it has to survive the
	// resume.
	if ([BeaRuntime isSuspended]) return;

	UIViewController *presenter = window.rootViewController;
	while (presenter.presentedViewController) {
		presenter = presenter.presentedViewController;
	}
	if (!presenter) return;

	// Already up: three entry points can now fire, and putting a second copy on
	// top of the first is how a screen ends up looking undismissable.
	for (UIViewController *walk = window.rootViewController; walk; walk = walk.presentedViewController) {
		if ([walk isKindOfClass:[BeaSettingsViewController class]]) return;
		if ([walk isKindOfClass:[UINavigationController class]] &&
		    [((UINavigationController *)walk).viewControllers.firstObject isKindOfClass:[BeaSettingsViewController class]]) {
			return;
		}
	}

	// Before the presentation rather than from the navigation controller's own
	// -viewWillAppear:, which lands a frame or two later - long enough for a
	// window-parented button to be composited over the screen sliding up.
	[BeaButton setTweakScreenVisible:YES];

	BeaSettingsViewController *settings = [[BeaSettingsViewController alloc] init];
	UINavigationController *navigation = [[BeaSettingsNavigationController alloc] initWithRootViewController:settings];
	// Deliberately NOT marked as tweak-presented. See the header: the marker is
	// for the small action sheets anchored to a button, and applying it here is
	// what left the download arrow floating on top of this screen.
	[presenter presentViewController:navigation animated:YES completion:nil];
}

+ (void)installFallbackGestureOnWindow:(UIWindow *)window {
	if (!window) return;
	for (UIGestureRecognizer *existing in window.gestureRecognizers) {
		if ([existing.name isEqualToString:@"BeaSettingsFallback"]) return;
	}

	UILongPressGestureRecognizer *recognizer =
		[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(bea_fallbackLongPressed:)];
	recognizer.numberOfTouchesRequired = 2;
	recognizer.name = @"BeaSettingsFallback";
	// The point of this one is to still work when everything else has been
	// switched off, so it must never swallow a touch BeReal was going to act
	// on. Two fingers held still is not a gesture BeReal uses anywhere.
	recognizer.cancelsTouchesInView = NO;
	recognizer.delaysTouchesBegan = NO;
	recognizer.delaysTouchesEnded = NO;
	[window addGestureRecognizer:recognizer];
}

+ (void)bea_fallbackLongPressed:(UILongPressGestureRecognizer *)recognizer {
	if (recognizer.state != UIGestureRecognizerStateBegan) return;
	if (![recognizer.view isKindOfClass:[UIWindow class]]) return;
	[self presentFromWindow:(UIWindow *)recognizer.view];
}

// ------------------------------------------------------------------ screen --

- (void)viewDidLoad {
	[super viewDidLoad];

	// This screen explains what each switch does by quoting BeReal's own copy -
	// « Poste pour voir », « Sponsorisé » - which is exactly what the gating and
	// sponsored hunts look for. Unmarked, they found it here and did to this
	// screen what they are meant to do to a post: strip the text out of the card
	// and collapse it. Three device reports of missing rows, blank gaps and
	// finally an entirely empty screen were all this. See BeaOwnership.h.
	BeaMarkViewAsOurs(self.view);

	self.title = BeaSharedCopy(@"general_settings", @"settings.title");
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(bea_done)];

	UIScrollView *scrollView = [[UIScrollView alloc] init];
	scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	scrollView.alwaysBounceVertical = YES;
	// The default already adjusts for the navigation bar and the home
	// indicator; saying so explicitly because "content started too high, under
	// the title" was one of the reported symptoms and this is the property that
	// decides it.
	scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
	[self.view addSubview:scrollView];

	self.contentStack = [[UIStackView alloc] init];
	self.contentStack.axis = UILayoutConstraintAxisVertical;
	self.contentStack.alignment = UIStackViewAlignmentFill;
	self.contentStack.spacing = 0;
	self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
	[scrollView addSubview:self.contentStack];

	[NSLayoutConstraint activateConstraints:@[
		[scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

		[self.contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
		[self.contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24],
		[self.contentStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
		[self.contentStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
		// The one constraint that gives the vertical scroll view a definite
		// content width. Without it the stack has no width to wrap its labels
		// against and the whole screen lays out ambiguously.
		[self.contentStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
	]];

	[self rebuildSections];
	[self rebuildContent];
}

- (void)bea_done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

// ------------------------------------------------------------------- model --

- (void)rebuildSections {
	__weak __typeof(self) weakSelf = self;

	NSString *immediate = BeaLocalized(@"settings.effect_immediate");
	NSString *newRequests = BeaLocalized(@"settings.effect_new_requests");
	NSString *restart = BeaLocalized(@"settings.effect_restart");

	BeaSettingsSection *ads = [BeaSettingsSection new];
	ads.header = BeaLocalized(@"settings.section_ads");
	ads.rows = @[
		[BeaSettingsRow toggle:BeaSettingBlockAdNetworkRequests
						 title:BeaLocalized(@"settings.ads_network")
						detail:BeaLocalized(@"settings.ads_network_detail")
						effect:newRequests],
		[BeaSettingsRow toggle:BeaSettingRemoveAdViews
						 title:BeaLocalized(@"settings.ads_views")
						detail:BeaLocalized(@"settings.ads_views_detail")
						effect:immediate],
		[BeaSettingsRow toggle:BeaSettingRemoveSponsoredCards
						 title:BeaLocalized(@"settings.ads_sponsored")
						detail:BeaLocalized(@"settings.ads_sponsored_detail")
						effect:immediate],
		[BeaSettingsRow toggle:BeaSettingWidenFromAdMedia
						 title:BeaLocalized(@"settings.ads_widen")
						detail:BeaLocalized(@"settings.ads_widen_detail")
						effect:immediate],
	];

	BeaSettingsSection *feed = [BeaSettingsSection new];
	feed.header = BeaLocalized(@"settings.section_feed");
	feed.rows = @[
		[BeaSettingsRow toggle:BeaSettingHideGatingOverlay
						 title:BeaLocalized(@"settings.gating_hide")
						detail:BeaLocalized(@"settings.gating_hide_detail")
						effect:immediate],
		[BeaSettingsRow toggle:BeaSettingKeepGatingCTA
						 title:BeaLocalized(@"settings.gating_keep_cta")
						detail:BeaLocalized(@"settings.gating_keep_cta_detail")
						effect:immediate],
		[BeaSettingsRow toggle:BeaSettingUnlockMediaInteractions
						 title:BeaLocalized(@"settings.media_unlock")
						detail:BeaLocalized(@"settings.media_unlock_detail")
						effect:immediate],
	];

	BeaSettingsSection *buttons = [BeaSettingsSection new];
	buttons.header = BeaLocalized(@"settings.section_buttons");
	buttons.rows = @[
		[BeaSettingsRow toggle:BeaSettingShowDownloadButton
						 title:BeaLocalized(@"settings.button_download")
						detail:BeaLocalized(@"settings.button_download_detail")
						effect:immediate],
		// The detail line here is not decoration: this switch used to remove
		// the only way back into this screen, so it has to say where the other
		// ways in are.
		[BeaSettingsRow toggle:BeaSettingShowUploadButton
						 title:BeaLocalized(@"settings.button_upload")
						detail:BeaLocalized(@"settings.button_upload_detail")
						effect:immediate],
		[BeaSettingsRow toggle:BeaSettingHideButtonsWhileScrolling
						 title:BeaLocalized(@"settings.button_hide_scrolling")
						detail:BeaLocalized(@"settings.button_hide_scrolling_detail")
						effect:immediate],
		[BeaSettingsRow action:BeaLocalized(@"download.picker_title")
						detail:[BeaDownloader titleForSelection:[BeaDownloader selection]]
						 block:^{ [weakSelf presentDownloadSelectionPicker]; }],
	];

	// No switch of its own: it is a runtime override, and writing it into
	// NSUserDefaults is exactly what it must not do. The row exists so the
	// gesture is discoverable at all - it has no visible indicator by design.
	BeaSettingsSection *master = [BeaSettingsSection new];
	master.header = BeaLocalized(@"settings.section_master");
	master.rows = @[
		[BeaSettingsRow note:BeaLocalized(@"settings.suspend")
					  detail:BeaLocalized(@"settings.suspend_detail")],
	];

	BeaSettingsSection *diagnostics = [BeaSettingsSection new];
	diagnostics.header = BeaLocalized(@"settings.section_diagnostics");
	diagnostics.rows = @[
		[BeaSettingsRow toggle:BeaSettingLoadAccessibilityBundles
						 title:BeaLocalized(@"settings.a11y_bundles")
						detail:BeaLocalized(@"settings.a11y_bundles_detail")
						effect:restart],
		[BeaSettingsRow toggle:BeaSettingDebugLogging
						 title:BeaLocalized(@"settings.debug_logging")
						detail:BeaLocalized(@"settings.debug_logging_detail")
						effect:immediate],
		[BeaSettingsRow action:BeaLocalized(@"settings.report_share")
						detail:BeaLocalized(@"settings.report_share_detail")
						 block:^{ [weakSelf shareDiagnosticsReport]; }],
		[BeaSettingsRow action:BeaLocalized(@"settings.report_summary")
						detail:nil
						 block:^{ [weakSelf showSummary]; }],
	];

	self.sections = @[ads, feed, buttons, master, diagnostics];
}

// -------------------------------------------------------------------- view --

- (void)rebuildContent {
	for (UIView *view in [self.contentStack.arrangedSubviews copy]) {
		[self.contentStack removeArrangedSubview:view];
		[view removeFromSuperview];
	}

	for (BeaSettingsSection *section in self.sections) {
		[self.contentStack addArrangedSubview:[self headerViewWithTitle:section.header]];
		[self.contentStack addArrangedSubview:[self cardViewForSection:section]];
	}
}

- (UIView *)headerViewWithTitle:(NSString *)title {
	UIView *container = [[UIView alloc] init];
	UILabel *label = [[UILabel alloc] init];
	label.text = title.uppercaseString;
	label.numberOfLines = 0;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.adjustsFontForContentSizeCategory = YES;
	label.textColor = [UIColor secondaryLabelColor];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:label];

	[NSLayoutConstraint activateConstraints:@[
		[label.topAnchor constraintEqualToAnchor:container.topAnchor constant:24],
		[label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
		[label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:32],
		[label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-32],
	]];
	return container;
}

// The inset-grouped look, built by hand: one rounded card holding the section's
// rows in a vertical stack, with a hairline between them. Built rather than
// borrowed from UITableView precisely because the borrowed version is what kept
// leaving blank gaps where rows should be.
- (UIView *)cardViewForSection:(BeaSettingsSection *)section {
	UIView *outer = [[UIView alloc] init];

	UIStackView *card = [[UIStackView alloc] init];
	card.axis = UILayoutConstraintAxisVertical;
	card.alignment = UIStackViewAlignmentFill;
	card.spacing = 0;
	card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	card.layer.cornerRadius = 12;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.clipsToBounds = YES;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[outer addSubview:card];

	[NSLayoutConstraint activateConstraints:@[
		[card.topAnchor constraintEqualToAnchor:outer.topAnchor],
		[card.bottomAnchor constraintEqualToAnchor:outer.bottomAnchor],
		[card.leadingAnchor constraintEqualToAnchor:outer.leadingAnchor constant:16],
		[card.trailingAnchor constraintEqualToAnchor:outer.trailingAnchor constant:-16],
	]];

	NSUInteger index = 0;
	for (BeaSettingsRow *row in section.rows) {
		if (index > 0) [card addArrangedSubview:[self separatorView]];

		BeaSettingsRowView *rowView = [[BeaSettingsRowView alloc] initWithRow:row target:self];
		[card addArrangedSubview:rowView];

		if (row.action) {
			UITapGestureRecognizer *tap =
				[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_rowTapped:)];
			[rowView addGestureRecognizer:tap];
		}
		index++;
	}
	return outer;
}

- (UIView *)separatorView {
	UIView *container = [[UIView alloc] init];
	UIView *line = [[UIView alloc] init];
	line.backgroundColor = [UIColor separatorColor];
	line.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:line];
	[NSLayoutConstraint activateConstraints:@[
		[container.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
		[line.topAnchor constraintEqualToAnchor:container.topAnchor],
		[line.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
		[line.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
		[line.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
	]];
	return container;
}

// ---------------------------------------------------------------- actions --

- (void)bea_rowTapped:(UITapGestureRecognizer *)recognizer {
	BeaSettingsRowView *rowView = (BeaSettingsRowView *)recognizer.view;
	if (![rowView isKindOfClass:[BeaSettingsRowView class]]) return;
	if (rowView.row.action) rowView.row.action();
}

- (void)bea_toggleChanged:(UISwitch *)toggle {
	NSString *key = objc_getAssociatedObject(toggle, @selector(bea_toggleChanged:));
	if (key.length == 0) return;
	// Undoing/re-applying whatever this switch controls hangs off the change
	// notification this posts - see BeaSettingsDidChangeNotification. Nothing
	// here needs to know which behaviour that is.
	[BeaSettings setBool:toggle.isOn forKey:key];

	// One switch is left that only takes effect at launch: the accessibility
	// bundles have to be dlopen'd before SwiftUI builds its view trees.
	// Ad-network blocking used to be the other one and no longer is - the
	// URLProtocol is now registered unconditionally and reads the switch per
	// request, so it can be turned off and back on without relaunching.
	if ([key isEqualToString:BeaSettingLoadAccessibilityBundles]) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
																	  message:BeaLocalized(@"settings.restart_required")
															   preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:BeaSharedCopy(@"general_ok", @"general.done")
												  style:UIAlertActionStyleDefault
												handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
	}
}

- (void)presentDownloadSelectionPicker {
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:BeaLocalized(@"download.picker_title")
																  message:nil
														   preferredStyle:UIAlertControllerStyleActionSheet];
	__weak __typeof(self) weakSelf = self;
	for (NSNumber *raw in @[@(BeaDownloadSelectionBoth), @(BeaDownloadSelectionBack), @(BeaDownloadSelectionFront)]) {
		BeaDownloadSelection selection = (BeaDownloadSelection)raw.integerValue;
		NSString *title = [BeaDownloader titleForSelection:selection];
		if (selection == [BeaDownloader selection]) title = [title stringByAppendingString:@" ✓"];
		[sheet addAction:[UIAlertAction actionWithTitle:title
												  style:UIAlertActionStyleDefault
												handler:^(UIAlertAction *action) {
			[BeaDownloader setSelection:selection];
			[weakSelf rebuildSections];
			[weakSelf rebuildContent];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:BeaSharedCopy(@"general_cancel", @"general.cancel")
											  style:UIAlertActionStyleCancel
											handler:nil]];
	sheet.popoverPresentationController.sourceView = self.view;
	sheet.popoverPresentationController.sourceRect = self.view.bounds;
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)shareDiagnosticsReport {
	// Captured against the window *behind* this screen, not this screen: the
	// whole point is the feed's hierarchy, and by the time settings is up the
	// feed is no longer what the key window renders on top. Dismiss first,
	// capture on the next runloop turn once the feed is back.
	// Captured before the dismissal, not inside the completion: by then this
	// controller is off-screen and its own -view.window is already nil.
	UIWindow *window = self.view.window;
	[self dismissViewControllerAnimated:YES completion:^{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			NSURL *report = [BeaDiagnostics writeFullReport];
			if (!report) return;

			UIViewController *presenter = window.rootViewController;
			while (presenter.presentedViewController) presenter = presenter.presentedViewController;
			if (!presenter) return;

			UIActivityViewController *share =
				[[UIActivityViewController alloc] initWithActivityItems:@[report] applicationActivities:nil];
			[BeaButton markAsTweakPresented:share];
			share.popoverPresentationController.sourceView = presenter.view;
			share.popoverPresentationController.sourceRect =
				CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
			[presenter presentViewController:share animated:YES completion:nil];
		});
	}];
}

// Pushed onto this screen's own navigation controller, not presented as an
// alert.
//
// UIAlertController's message label does not scroll and is laid out to fit
// whatever it is given. Handed the ~1.5KB diagnostics summary, it produced an
// alert taller than the screen with its own dismiss button off the bottom edge
// - which is exactly the "large empty modal that cannot be dismissed" this
// replaces. A text view scrolls, and the navigation bar's back button is always
// on screen.
- (void)showSummary {
	UIViewController *screen = [[UIViewController alloc] init];
	screen.title = BeaLocalized(@"settings.report_summary");
	screen.view.backgroundColor = [UIColor systemBackgroundColor];

	UITextView *text = [[UITextView alloc] init];
	text.editable = NO;
	text.alwaysBounceVertical = YES;
	text.backgroundColor = [UIColor systemBackgroundColor];
	text.textColor = [UIColor labelColor];
	text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	text.textContainerInset = UIEdgeInsetsMake(16, 12, 32, 12);
	text.text = [BeaDiagnostics summaryReport];
	[screen.view addSubview:text];

	// Constraints, not initWithFrame: + an autoresizing mask. That is why this
	// screen came up empty: a view controller built with -init and never yet in
	// a hierarchy has no meaningful -view.bounds, so the text view was created
	// at zero size, and an autoresizing mask cannot grow a zero-sized view -
	// it distributes a superview's size *change* proportionally, and every
	// proportion of zero is zero. The screen pushed, the title showed, and the
	// report was laid out inside a 0x0 rectangle.
	text.translatesAutoresizingMaskIntoConstraints = NO;
	[NSLayoutConstraint activateConstraints:@[
		[text.topAnchor constraintEqualToAnchor:screen.view.topAnchor],
		[text.bottomAnchor constraintEqualToAnchor:screen.view.bottomAnchor],
		[text.leadingAnchor constraintEqualToAnchor:screen.view.leadingAnchor],
		[text.trailingAnchor constraintEqualToAnchor:screen.view.trailingAnchor],
	]];

	if (self.navigationController) {
		[self.navigationController pushViewController:screen animated:YES];
		return;
	}

	// Defensive: +presentFromWindow: always wraps this screen in a navigation
	// controller, so the push above is the real path. If some future caller
	// presents it bare, the summary still has to be dismissable.
	screen.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(bea_dismissPresented)];
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:screen]
					   animated:YES
					 completion:nil];
}

- (void)bea_dismissPresented {
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end
