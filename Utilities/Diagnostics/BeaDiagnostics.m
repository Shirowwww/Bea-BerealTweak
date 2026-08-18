#import "BeaDiagnostics.h"
#import "../Ads/BeaAdBlocker.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import "../Settings/BeaSettings.h"

#import "../BeaVersion.h"

static NSInteger BeaLastGatingMarkerCount = -1;
static NSInteger BeaLastSponsoredMarkerCount = -1;
static NSString *BeaLastHomeControllerName = nil;
static CGRect BeaLastDownloadAnchorFrame;
static BOOL BeaHasDownloadAnchorFrame = NO;

@implementation BeaDiagnostics

+ (void)recordGatingMarkers:(NSInteger)count { BeaLastGatingMarkerCount = count; }
+ (void)recordSponsoredMarkers:(NSInteger)count { BeaLastSponsoredMarkerCount = count; }

+ (void)recordHomeControllerName:(NSString *)name {
	if (name.length > 0) BeaLastHomeControllerName = [name copy];
}

+ (void)recordDownloadButtonAnchorFrame:(CGRect)frame {
	BeaLastDownloadAnchorFrame = frame;
	BeaHasDownloadAnchorFrame = YES;
}

// -[UIApplication windows] has been deprecated since iOS 15, so this goes
// through the scene graph. Falls back to the first window of the first window
// scene when nothing claims to be key, which happens while a modal transition
// is in flight.
+ (UIWindow *)keyWindow {
	UIWindow *fallback = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (window.isKeyWindow) return window;
			if (!fallback) fallback = window;
		}
	}
	return fallback;
}

+ (NSString *)summaryReport {
	NSMutableString *out = [NSMutableString string];

	[out appendFormat:@"MiniBea %@\n", TWEAK_VERSION];
	[out appendFormat:@"BeReal %@ (%@)\n",
		[NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
		[NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?"];
	[out appendFormat:@"iOS %@ - %@\n", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model];
	[out appendFormat:@"UI language: %@\n\n", [NSBundle mainBundle].preferredLocalizations.firstObject ?: @"?"];

	// Whether BeReal's own string table resolved. If this says it did not,
	// every text-matched feature in the tweak is hunting for English copy on a
	// French screen and cannot possibly work.
	NSString *sponsored = BeaAppLocalized(@"general_sponsored", @"");
	NSString *gatingTitle = BeaAppLocalized(@"timelineCell_blurredView_title", @"");
	[out appendFormat:@"BeReal string table: %@\n", sponsored.length > 0 ? @"resolved" : @"NOT resolved"];
	[out appendFormat:@"  general_sponsored              = \"%@\"\n", sponsored];
	[out appendFormat:@"  timelineCell_blurredView_title = \"%@\"\n\n", gatingTitle];

	[out appendFormat:@"Accessibility bundles: %@\n",
		[BeaSettings accessibilityBundlesLoaded] ? @"loaded" : @"NOT loaded"];
	[out appendString:@"  (SwiftUI only publishes its text as accessibility\n"
	                   "   elements once these are in; without them the gating\n"
	                   "   and sponsored scans have nothing at all to read.)\n\n"];

	[out appendFormat:@"Home controller seen: %@\n", BeaLastHomeControllerName ?: @"NEVER"];
	[out appendFormat:@"Last gating scan:     %@\n",
		BeaLastGatingMarkerCount < 0 ? @"never ran" : [NSString stringWithFormat:@"%ld marker(s)", (long)BeaLastGatingMarkerCount]];
	[out appendFormat:@"Last sponsored scan:  %@\n",
		BeaLastSponsoredMarkerCount < 0 ? @"never ran" : [NSString stringWithFormat:@"%ld marker(s)", (long)BeaLastSponsoredMarkerCount]];
	[out appendFormat:@"Download anchor:      %@\n",
		BeaHasDownloadAnchorFrame ? NSStringFromCGRect(BeaLastDownloadAnchorFrame) : @"none"];
	[out appendFormat:@"Ad views suppressed:  %lu\n", (unsigned long)[BeaAdBlocker suppressedViewCount]];
	[out appendFormat:@"Ad requests blocked:  %lu\n\n", (unsigned long)[BeaAdBlocker blockedRequestCount]];

	[out appendString:@"Settings:\n"];
	for (NSString *key in @[BeaSettingBlockAdNetworkRequests, BeaSettingRemoveAdViews,
	                        BeaSettingRemoveSponsoredCards, BeaSettingWidenFromAdMedia,
	                        BeaSettingHideGatingOverlay, BeaSettingKeepGatingCTA,
	                        BeaSettingShowDownloadButton, BeaSettingShowUploadButton,
	                        BeaSettingHideButtonsWhileScrolling,
	                        BeaSettingLoadAccessibilityBundles, BeaSettingDebugLogging]) {
		[out appendFormat:@"  %@ = %@\n", key, [BeaSettings boolForKey:key] ? @"on" : @"off"];
	}

	return out;
}

// The accessibility elements a view publishes, flattened. This is the single
// most important thing in the report: if SwiftUI's text shows up here, the
// scans can work and it is the needles or the guards that are wrong; if it
// never shows up anywhere, the text approach is dead on this device and the
// fix has to come from somewhere else entirely.
+ (void)appendAccessibilityElementsOf:(id)container to:(NSMutableString *)out indent:(NSString *)indent depth:(NSInteger)depth {
	if (!container || depth > 3) return;

	NSArray *elements = [container respondsToSelector:@selector(accessibilityElements)]
		? [container accessibilityElements] : nil;
	NSInteger count = (NSInteger)elements.count;
	if (!elements && [container respondsToSelector:@selector(accessibilityElementCount)]) {
		count = [container accessibilityElementCount];
		if (count == NSNotFound) count = 0;
	}
	if (count <= 0) return;

	for (NSInteger i = 0; i < MIN(count, (NSInteger)24); i++) {
		id element = elements ? elements[i] : [container accessibilityElementAtIndex:i];
		if (!element) continue;
		NSString *label = [element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil;
		NSString *value = [element respondsToSelector:@selector(accessibilityValue)] ? [element accessibilityValue] : nil;
		[out appendFormat:@"%@  ax[%ld] %@ label=%@ value=%@\n",
			indent, (long)i, NSStringFromClass([element class]), label ?: @"-", value ?: @"-"];
		[self appendAccessibilityElementsOf:element to:out indent:[indent stringByAppendingString:@"  "] depth:depth + 1];
	}
}

+ (void)appendView:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
	if (!view || depth > 22) return;

	NSString *indent = [@"" stringByPaddingToLength:MIN(depth, 22) * 2 withString:@" " startingAtIndex:0];
	CGRect inWindow = [view convertRect:view.bounds toView:nil];

	NSMutableString *extra = [NSMutableString string];
	if ([view isKindOfClass:[UILabel class]]) {
		[extra appendFormat:@" text=\"%@\"", ((UILabel *)view).text ?: @""];
	} else if ([view isKindOfClass:[UIButton class]]) {
		[extra appendFormat:@" title=\"%@\"", ((UIButton *)view).currentTitle ?: @""];
	} else if ([view isKindOfClass:[UIImageView class]]) {
		UIImage *image = ((UIImageView *)view).image;
		if (image) [extra appendFormat:@" image=%.0fx%.0f", image.size.width, image.size.height];
	}
	if (view.accessibilityLabel.length > 0) [extra appendFormat:@" a11y=\"%@\"", view.accessibilityLabel];
	if (view.accessibilityIdentifier.length > 0) [extra appendFormat:@" id=%@", view.accessibilityIdentifier];
	if (view.hidden) [extra appendString:@" HIDDEN"];
	if (view.alpha < 0.99) [extra appendFormat:@" alpha=%.2f", view.alpha];

	[out appendFormat:@"%@%@ %@%@\n", indent, NSStringFromClass([view class]),
		NSStringFromCGRect(inWindow), extra];

	[self appendAccessibilityElementsOf:view to:out indent:indent depth:0];

	for (UIView *subview in view.subviews) {
		[self appendView:subview to:out depth:depth + 1];
	}
}

+ (NSString *)hierarchyReportForView:(UIView *)root {
	if (!root) return @"(no view)\n";
	NSMutableString *out = [NSMutableString string];
	[self appendView:root to:out depth:0];
	return out;
}

+ (NSURL *)writeFullReport {
	NSMutableString *out = [NSMutableString string];
	[out appendString:[self summaryReport]];
	[out appendString:@"\n=========== VIEW HIERARCHY ===========\n"];
	[out appendString:[self hierarchyReportForView:[self keyWindow]]];

	NSString *name = [NSString stringWithFormat:@"MiniBea-diagnostics-%ld.txt",
		(long)[NSDate date].timeIntervalSince1970];
	NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];

	NSError *error = nil;
	if (![out writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) return nil;
	return url;
}

@end
