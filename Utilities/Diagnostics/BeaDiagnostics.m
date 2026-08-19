#import "BeaDiagnostics.h"
#import "../Ads/BeaAdBlocker.h"
#import "../Debug/BeaDebug.h"
#import "../Downloader/BeaDownloader.h"
#import "../Localization/BeaLocalization.h"
#import "../Runtime/BeaRuntime.h"
#import "../Settings/BeaSettings.h"

#import "../BeaVersion.h"
#import <os/log.h>

static NSInteger BeaLastGatingMarkerCount = -1;
static NSInteger BeaLastGatingLayerCount = -1;
static NSInteger BeaLastGatingLayerHideCount = -1;
static NSInteger BeaLastSponsoredMarkerCount = -1;
static NSString *BeaLastHomeControllerName = nil;
static CGRect BeaLastDownloadAnchorFrame;
static BOOL BeaHasDownloadAnchorFrame = NO;
static NSString *BeaLastUploadAnchorClassName = nil;
static CGRect BeaLastUploadAnchorFrame;
static BOOL BeaHasUploadAnchorFrame = NO;
static NSInteger BeaLastMediaOverlayCount = -1;
static NSString *BeaLastMediaGesturesState = nil;
static NSString *BeaLastMediaHitTestClassName = nil;
static CFTimeInterval BeaLastReconcileDuration = -1;
static CFTimeInterval BeaWorstReconcileDuration = 0;
static NSString *BeaUploadBarItemRejectionReason = nil;

// ---------------------------------------------------------------------------
// One counter: a live one-second rate, the worst second ever seen, and a total.
// ---------------------------------------------------------------------------
typedef struct {
	const char *name;
	NSInteger threshold;      // per-second rate worth a log line
	CFTimeInterval bucketStart;
	NSInteger bucketCount;
	NSInteger rate;           // the last completed second
	NSInteger peak;
	NSUInteger total;
	BOOL warned;              // once per bucket, so a stuck loop cannot spam
} BeaRateCounter;

static BeaRateCounter BeaBarItemCounter = { "bar item re-inserts", 20, 0, 0, 0, 0, 0, NO };
static BeaRateCounter BeaReorderCounter = { "overlay re-orders", 40, 0, 0, 0, 0, 0, NO };
static BeaRateCounter BeaLayoutCounter  = { "layout passes", 240, 0, 0, 0, 0, 0, NO };
static BeaRateCounter BeaScanCounter    = { "full-tree scans", 60, 0, 0, 0, 0, 0, NO };

static void BeaCountTick(BeaRateCounter *counter) {
	CFTimeInterval now = CACurrentMediaTime();
	if (counter->bucketStart == 0) counter->bucketStart = now;

	if (now - counter->bucketStart >= 1.0) {
		counter->rate = counter->bucketCount;
		if (counter->bucketCount > counter->peak) counter->peak = counter->bucketCount;
		counter->bucketCount = 0;
		counter->bucketStart = now;
		counter->warned = NO;
	}

	counter->bucketCount++;
	counter->total++;

	// Deliberately not behind the debug-logging switch. A rate this high means
	// the tweak is in a feedback loop with SwiftUI, and that is worth a line in
	// the log of an install that has never turned logging on.
	if (!counter->warned && counter->bucketCount > counter->threshold) {
		counter->warned = YES;
		os_log_error(OS_LOG_DEFAULT, "[BeaLoop] %{public}s: %ld this second (threshold %ld)",
			counter->name, (long)counter->bucketCount, (long)counter->threshold);
	}
}

// The live rate, which for a loop is the current bucket rather than the last
// completed one - waiting a full second to notice is a second of frozen UI.
static NSInteger BeaCountRate(BeaRateCounter *counter) {
	CFTimeInterval now = CACurrentMediaTime();
	if (counter->bucketStart > 0 && now - counter->bucketStart >= 1.0) return 0;
	return MAX(counter->bucketCount, counter->rate);
}

static NSString *BeaCountDescription(BeaRateCounter *counter) {
	return [NSString stringWithFormat:@"%ld/s now, peak %ld/s, %lu total",
		(long)BeaCountRate(counter), (long)counter->peak, (unsigned long)counter->total];
}

@implementation BeaDiagnostics

+ (void)recordGatingMarkers:(NSInteger)count { BeaLastGatingMarkerCount = count; }
+ (void)recordGatingLayers:(NSInteger)found hidden:(NSInteger)hidden {
	BeaLastGatingLayerCount = found;
	// Sticky: the pass that actually hid the cluster is the interesting one,
	// and it is followed by hundreds of passes that legitimately hide nothing
	// because there is nothing left to hide. Reporting the last non-zero count
	// is what makes "it worked once and stuck" distinguishable from "it never
	// did anything" in a report shared minutes later.
	if (hidden > 0 || BeaLastGatingLayerHideCount < 0) BeaLastGatingLayerHideCount = hidden;
}
+ (void)recordSponsoredMarkers:(NSInteger)count { BeaLastSponsoredMarkerCount = count; }

+ (void)countBarItemInsertion { BeaCountTick(&BeaBarItemCounter); }
+ (void)countOverlayReorder   { BeaCountTick(&BeaReorderCounter); }
+ (void)countLayoutPass       { BeaCountTick(&BeaLayoutCounter); }
+ (void)countLayoutScan       { BeaCountTick(&BeaScanCounter); }

+ (NSInteger)barItemInsertionRate { return BeaCountRate(&BeaBarItemCounter); }

+ (void)recordReconcileDuration:(CFTimeInterval)seconds {
	BeaLastReconcileDuration = seconds;
	if (seconds > BeaWorstReconcileDuration) BeaWorstReconcileDuration = seconds;
}

+ (void)recordUploadBarItemRejection:(NSString *)reason {
	BeaUploadBarItemRejectionReason = [reason copy];
}

+ (void)recordHomeControllerName:(NSString *)name {
	if (name.length > 0) BeaLastHomeControllerName = [name copy];
}

+ (void)recordDownloadButtonAnchorFrame:(CGRect)frame {
	BeaLastDownloadAnchorFrame = frame;
	BeaHasDownloadAnchorFrame = YES;
}

+ (void)recordUploadButtonAnchor:(NSString *)className frame:(CGRect)frame {
	BeaLastUploadAnchorClassName = [className copy];
	BeaLastUploadAnchorFrame = frame;
	BeaHasUploadAnchorFrame = YES;
}

+ (void)recordMediaUnlockOverlays:(NSInteger)count
                  gesturesOverlay:(UIView *)gesturesOverlay
                        mainPhoto:(UIView *)photo {
	BeaLastMediaOverlayCount = count;
	BeaLastMediaGesturesState = gesturesOverlay
		? (gesturesOverlay.userInteractionEnabled ? @"interactive" : @"held disabled")
		: @"not found";

	// The probe, and the one thing in this method that is not a property read:
	// -hitTest: walks the whole window and can force layout, and this runs once
	// per gated post per reconcile pass. It has no business on that path in a
	// normal install, so it only runs with verbose logging on - which is exactly
	// when someone is reading the answer.
	if (!BeaDebugLoggingEnabled()) {
		BeaLastMediaHitTestClassName = nil;
		return;
	}

	// Against the window rather than the card, so it answers the same question a
	// real finger asks: given everything on screen, who gets this touch?
	UIWindow *window = photo.window;
	if (!window) {
		BeaLastMediaHitTestClassName = nil;
		return;
	}
	CGRect photoInWindow = [photo convertRect:photo.bounds toView:window];
	CGPoint centre = CGPointMake(CGRectGetMidX(photoInWindow), CGRectGetMidY(photoInWindow));
	UIView *hit = [window hitTest:centre withEvent:nil];
	if (!hit) {
		BeaLastMediaHitTestClassName = @"(nothing)";
		return;
	}

	// The class alone is not enough to act on: several of the views in this
	// stack are anonymous SwiftUI containers with the same name. How many
	// recognizers it carries, and whether one of them is ours, is what
	// distinguishes "our overlay is receiving the tap" from "a wrapper with the
	// same frame is swallowing it".
	NSInteger ours = 0;
	for (UIGestureRecognizer *recognizer in hit.gestureRecognizers) {
		if ([recognizer.name hasPrefix:@"BeaMedia"]) ours++;
	}
	BeaLastMediaHitTestClassName = [NSString stringWithFormat:@"%@ (%lu recognizer(s), %ld ours)",
		NSStringFromClass([hit class]), (unsigned long)hit.gestureRecognizers.count, (long)ours];
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
	[out appendFormat:@"Gating layer pass:    %@\n",
		BeaLastGatingLayerCount < 0
			? @"never ran"
			: [NSString stringWithFormat:@"%ld layer(s) in cluster, %ld hidden",
				(long)BeaLastGatingLayerCount, (long)BeaLastGatingLayerHideCount]];
	[out appendFormat:@"Last sponsored scan:  %@\n",
		BeaLastSponsoredMarkerCount < 0 ? @"never ran" : [NSString stringWithFormat:@"%ld marker(s)", (long)BeaLastSponsoredMarkerCount]];
	[out appendFormat:@"Download anchor:      %@\n",
		BeaHasDownloadAnchorFrame ? NSStringFromCGRect(BeaLastDownloadAnchorFrame) : @"none"];
	[out appendFormat:@"\"+\" anchor:          %@\n",
		BeaHasUploadAnchorFrame
			? [NSString stringWithFormat:@"%@ %@", BeaLastUploadAnchorClassName ?: @"?",
				NSStringFromCGRect(BeaLastUploadAnchorFrame)]
			: @"none"];
	[out appendFormat:@"Media unlock:         %@\n",
		BeaLastMediaOverlayCount < 0
			? @"no gated post reconciled yet"
			: [NSString stringWithFormat:@"%ld tap overlay(s), BeReal gestures view %@",
				(long)BeaLastMediaOverlayCount, BeaLastMediaGesturesState ?: @"?"]];
	[out appendFormat:@"Tap lands on:         %@\n", BeaLastMediaHitTestClassName ?: @"not probed"];
	// The loop counters. Anything here in the hundreds per second is the tweak
	// fighting SwiftUI rather than reconciling against it - see BeaDiagnostics.h.
	[out appendFormat:@"Bar item re-inserts:  %@\n", BeaCountDescription(&BeaBarItemCounter)];
	[out appendFormat:@"Overlay re-orders:    %@\n", BeaCountDescription(&BeaReorderCounter)];
	[out appendFormat:@"Layout passes:        %@\n", BeaCountDescription(&BeaLayoutCounter)];
	[out appendFormat:@"Full-tree scans:      %@\n", BeaCountDescription(&BeaScanCounter)];
	[out appendFormat:@"Reconcile pass:       %@\n",
		BeaLastReconcileDuration < 0
			? @"never ran"
			: [NSString stringWithFormat:@"%.1f ms last, %.1f ms worst",
				BeaLastReconcileDuration * 1000.0, BeaWorstReconcileDuration * 1000.0]];
	if (BeaUploadBarItemRejectionReason.length > 0) {
		[out appendFormat:@"\"+\" bar hosting:     given up - %@\n", BeaUploadBarItemRejectionReason];
	}
	[out appendFormat:@"Ad views suppressed:  %lu\n", (unsigned long)[BeaAdBlocker suppressedViewCount]];
	[out appendFormat:@"Ad requests blocked:  %lu\n\n", (unsigned long)[BeaAdBlocker blockedRequestCount]];

	// Before the switches, because it overrides every one of them: while this is
	// on, each line below still reports its stored value and behaves as off.
	[out appendFormat:@"MASTER SUSPEND:       %@\n\n",
		[BeaRuntime isSuspended] ? @"ON - all tweaks suspended (3-finger hold)" : @"off"];

	[out appendString:@"Settings (stored values):\n"];
	for (NSString *key in @[BeaSettingBlockAdNetworkRequests, BeaSettingRemoveAdViews,
	                        BeaSettingRemoveSponsoredCards, BeaSettingWidenFromAdMedia,
	                        BeaSettingHideGatingOverlay, BeaSettingKeepGatingCTA,
	                        BeaSettingUnlockMediaInteractions,
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

// The CALayers a view draws into that are not themselves backed by a subview.
//
// This is the half of the screen the view dump cannot show, and on BeReal 4.88
// it is where most of the feed actually is: SwiftUI only creates a UIView for
// content it has to bridge to UIKit (the photos, the "..." button), and draws
// everything else - the username row, the "Poste pour voir" overlay, its scrim
// and its button - straight into layers. A report that walks only views
// therefore shows a gated post as a photo with nothing on top of it, which is
// exactly how "0 marker(s) found" and a screenshot of the overlay ended up
// being reported together.
//
// Anything whose delegate is a UIView is skipped: that layer belongs to a
// subview this walk prints in its own right.
+ (void)appendDrawingLayersOf:(CALayer *)layer to:(NSMutableString *)out indent:(NSString *)indent depth:(NSInteger)depth {
	if (!layer || depth > 6) return;

	for (CALayer *sublayer in layer.sublayers) {
		if ([sublayer.delegate isKindOfClass:[UIView class]]) continue;

		CGRect inWindow = [sublayer convertRect:sublayer.bounds toLayer:nil];
		NSMutableString *extra = [NSMutableString string];
		if (sublayer.contents) [extra appendString:@" contents=yes"];
		if (sublayer.backgroundColor) [extra appendString:@" bg=yes"];
		if (sublayer.mask) [extra appendString:@" masked"];
		if (sublayer.hidden) [extra appendString:@" HIDDEN"];
		if (sublayer.opacity < 0.99) [extra appendFormat:@" opacity=%.2f", sublayer.opacity];

		[out appendFormat:@"%@  layer %@ %@%@\n", indent, NSStringFromClass([sublayer class]),
			NSStringFromCGRect(inWindow), extra];
		[self appendDrawingLayersOf:sublayer to:out indent:[indent stringByAppendingString:@"  "] depth:depth + 1];
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
	[self appendDrawingLayersOf:view.layer to:out indent:indent depth:0];

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
