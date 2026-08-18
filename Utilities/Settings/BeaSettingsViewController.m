#import "BeaSettingsViewController.h"
#import "BeaSettings.h"
#import "../Button/BeaButton.h"
#import "../Diagnostics/BeaDiagnostics.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import <objc/runtime.h>

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

	BeaSettingsViewController *settings = [[BeaSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
	// Both halves of the presentation get the marker: BeaHasPresentedModal
	// walks the chain and only ever sees the navigation controller, but the
	// settings controller is what a nested presentation would come off.
	[BeaButton markAsTweakPresented:navigation];
	[BeaButton markAsTweakPresented:settings];
	[presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = BeaSharedCopy(@"general_settings", @"settings.title");
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(bea_done)];

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
	];

	BeaSettingsSection *buttons = [BeaSettingsSection new];
	buttons.header = BeaLocalized(@"settings.section_buttons");
	buttons.rows = @[
		[BeaSettingsRow toggle:BeaSettingShowDownloadButton
						 title:BeaLocalized(@"settings.button_download")
						detail:nil],
		[BeaSettingsRow toggle:BeaSettingShowUploadButton
						 title:BeaLocalized(@"settings.button_upload")
						detail:nil],
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

- (void)showSummary {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:BeaLocalized(@"settings.report_summary")
																  message:[BeaDiagnostics summaryReport]
														   preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:BeaSharedCopy(@"general_ok", @"general.done")
											  style:UIAlertActionStyleDefault
											handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
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

	// Built fresh rather than dequeued: this table is two screens at most and
	// the rows are not uniform. UIListContentConfiguration rather than the
	// cell's own textLabel/detailTextLabel, which have been deprecated since
	// iOS 14 and would put warnings in a build this repo requires to be clean.
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
	content.text = row.title;
	content.secondaryText = row.detail;
	content.secondaryTextProperties.numberOfLines = 0;
	content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
	cell.contentConfiguration = content;

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
	[BeaSettings setBool:toggle.isOn forKey:key];

	// Two switches only take effect at launch (the URLProtocol registration
	// has to be in place before any SDK builds its first session, and the
	// accessibility bundles have to be in before SwiftUI builds its trees).
	// Saying so is the difference between a working switch and a bug report.
	if ([key isEqualToString:BeaSettingBlockAdNetworkRequests] ||
		[key isEqualToString:BeaSettingLoadAccessibilityBundles]) {
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
