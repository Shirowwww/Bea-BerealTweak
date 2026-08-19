#import "BeaSettingsViewController.h"
#import "BeaSettings.h"
#import "../Button/BeaButton.h"
#import "../Diagnostics/BeaDiagnostics.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import <objc/runtime.h>

static NSString *const BeaSettingsCellIdentifier = @"BeaSettingsCell";

// One row. `settingKey` nil means an action row rather than a switch.
@interface BeaSettingsRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *settingKey;
@property (nonatomic, copy) void (^action)(void);
@end

@implementation BeaSettingsRow
+ (instancetype)toggle:(NSString *)key title:(NSString *)title detail:(NSString *)detail {
	BeaSettingsRow *row = [BeaSettingsRow new];
	row.settingKey = key;
	row.title = title;
	row.detail = detail;
	return row;
}
+ (instancetype)action:(NSString *)title detail:(NSString *)detail block:(void (^)(void))block {
	BeaSettingsRow *row = [BeaSettingsRow new];
	row.title = title;
	row.detail = detail;
	row.action = block;
	return row;
}
@end

@interface BeaSettingsSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSArray<BeaSettingsRow *> *rows;
@end

@implementation BeaSettingsSection
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
@end

@implementation BeaSettingsViewController

+ (void)presentFromWindow:(UIWindow *)window {
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

	BeaSettingsViewController *settings = [[BeaSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *navigation = [[BeaSettingsNavigationController alloc] initWithRootViewController:settings];
	// Deliberately NOT marked as tweak-presented. See the header: the marker is
	// for the small action sheets anchored to a button, and applying it here is
	// what left the "+" and the download arrow floating on top of this screen -
	// they are window-parented, so nothing else stops them.
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

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = BeaSharedCopy(@"general_settings", @"settings.title");
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(bea_done)];

	// Every row here is a title over a two-to-four-line explanation, so every
	// row is a different height. None of that was configured, and the result is
	// the reported one: rows missing entirely, black gaps where they should be,
	// and text from one section drawn on top of another.
	//
	// estimatedRowHeight = 0, not a guess. A non-zero estimate makes UITableView
	// lay the table out from estimates first and correct afterwards, and the
	// correction is what moves rows around underneath their own content. Zero
	// disables estimation entirely and asks each cell for its real height up
	// front - normally the expensive option, and completely free here, because
	// the whole table is a dozen rows on one screen.
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 0;
	self.tableView.estimatedSectionHeaderHeight = 0;
	self.tableView.estimatedSectionFooterHeight = 0;
	[self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:BeaSettingsCellIdentifier];

	[self rebuildSections];
}

- (void)bea_done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)rebuildSections {
	__weak __typeof(self) weakSelf = self;

	BeaSettingsSection *ads = [BeaSettingsSection new];
	ads.header = BeaLocalized(@"settings.section_ads");
	ads.rows = @[
		[BeaSettingsRow toggle:BeaSettingBlockAdNetworkRequests
						 title:BeaLocalized(@"settings.ads_network")
						detail:BeaLocalized(@"settings.ads_network_detail")],
		[BeaSettingsRow toggle:BeaSettingRemoveAdViews
						 title:BeaLocalized(@"settings.ads_views")
						detail:BeaLocalized(@"settings.ads_views_detail")],
		[BeaSettingsRow toggle:BeaSettingRemoveSponsoredCards
						 title:BeaLocalized(@"settings.ads_sponsored")
						detail:BeaLocalized(@"settings.ads_sponsored_detail")],
		[BeaSettingsRow toggle:BeaSettingWidenFromAdMedia
						 title:BeaLocalized(@"settings.ads_widen")
						detail:BeaLocalized(@"settings.ads_widen_detail")],
	];

	BeaSettingsSection *feed = [BeaSettingsSection new];
	feed.header = BeaLocalized(@"settings.section_feed");
	feed.rows = @[
		[BeaSettingsRow toggle:BeaSettingHideGatingOverlay
						 title:BeaLocalized(@"settings.gating_hide")
						detail:BeaLocalized(@"settings.gating_hide_detail")],
		[BeaSettingsRow toggle:BeaSettingKeepGatingCTA
						 title:BeaLocalized(@"settings.gating_keep_cta")
						detail:BeaLocalized(@"settings.gating_keep_cta_detail")],
		[BeaSettingsRow toggle:BeaSettingUnlockMediaInteractions
						 title:BeaLocalized(@"settings.media_unlock")
						detail:BeaLocalized(@"settings.media_unlock_detail")],
	];

	BeaSettingsSection *buttons = [BeaSettingsSection new];
	buttons.header = BeaLocalized(@"settings.section_buttons");
	buttons.rows = @[
		[BeaSettingsRow toggle:BeaSettingShowDownloadButton
						 title:BeaLocalized(@"settings.button_download")
						detail:BeaLocalized(@"settings.button_download_detail")],
		// The detail line here is not decoration: this switch used to remove
		// the only way back into this screen, so it has to say where the other
		// ways in are.
		[BeaSettingsRow toggle:BeaSettingShowUploadButton
						 title:BeaLocalized(@"settings.button_upload")
						detail:BeaLocalized(@"settings.button_upload_detail")],
		[BeaSettingsRow toggle:BeaSettingHideButtonsWhileScrolling
						 title:BeaLocalized(@"settings.button_hide_scrolling")
						detail:BeaLocalized(@"settings.button_hide_scrolling_detail")],
		[BeaSettingsRow action:BeaLocalized(@"download.picker_title")
						detail:[BeaDownloader titleForSelection:[BeaDownloader selection]]
						 block:^{ [weakSelf presentDownloadSelectionPicker]; }],
	];

	BeaSettingsSection *diagnostics = [BeaSettingsSection new];
	diagnostics.header = BeaLocalized(@"settings.section_diagnostics");
	diagnostics.rows = @[
		[BeaSettingsRow toggle:BeaSettingLoadAccessibilityBundles
						 title:BeaLocalized(@"settings.a11y_bundles")
						detail:BeaLocalized(@"settings.a11y_bundles_detail")],
		[BeaSettingsRow toggle:BeaSettingDebugLogging
						 title:BeaLocalized(@"settings.debug_logging")
						detail:BeaLocalized(@"settings.debug_logging_detail")],
		[BeaSettingsRow action:BeaLocalized(@"settings.report_share")
						detail:BeaLocalized(@"settings.report_share_detail")
						 block:^{ [weakSelf shareDiagnosticsReport]; }],
		[BeaSettingsRow action:BeaLocalized(@"settings.report_summary")
						detail:nil
						 block:^{ [weakSelf showSummary]; }],
	];

	self.sections = @[ads, feed, buttons, diagnostics];
}

// ---------------------------------------------------------------- actions --

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
			[weakSelf.tableView reloadData];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:BeaSharedCopy(@"general_cancel", @"general.cancel")
											  style:UIAlertActionStyleCancel
											handler:nil]];
	sheet.popoverPresentationController.sourceView = self.tableView;
	sheet.popoverPresentationController.sourceRect = self.tableView.bounds;
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

// ----------------------------------------------------------- table source --

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return self.sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return self.sections[section].header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	BeaSettingsRow *row = self.sections[indexPath.section].rows[indexPath.row];

	// Dequeued, not built fresh. Building a new cell every call was not itself
	// the layout bug, but it did hide it: a reused cell keeps its accessory
	// view and its configuration, so the leftovers cleared below are what a
	// correct recycling path has to deal with - and going through the reuse
	// queue is also what lets the table measure a row once and keep the answer.
	//
	// UIListContentConfiguration rather than the cell's own textLabel/
	// detailTextLabel, which have been deprecated since iOS 14 and would put
	// warnings in a build this repo requires to be clean.
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:BeaSettingsCellIdentifier
	                                                       forIndexPath:indexPath];
	UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
	content.text = row.title;
	content.textProperties.numberOfLines = 0;
	content.secondaryText = row.detail;
	content.secondaryTextProperties.numberOfLines = 0;
	content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
	cell.contentConfiguration = content;

	// A recycled cell arrives carrying whatever the last row put on it.
	cell.accessoryView = nil;
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	if (row.settingKey) {
		UISwitch *toggle = [[UISwitch alloc] init];
		toggle.on = [BeaSettings boolForKey:row.settingKey];
		// The key rides on the control itself, so the handler needs no index
		// path and cannot go stale if the sections are rebuilt underneath it.
		objc_setAssociatedObject(toggle, @selector(bea_toggleChanged:), row.settingKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[toggle addTarget:self action:@selector(bea_toggleChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else {
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}

	return cell;
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	BeaSettingsRow *row = self.sections[indexPath.section].rows[indexPath.row];
	if (row.action) row.action();
}

@end
