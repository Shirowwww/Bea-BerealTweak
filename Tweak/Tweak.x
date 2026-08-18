#import "Tweak.h"
#import "Utilities/Settings/BeaSettings.h"
#import "Utilities/Settings/BeaSettingsViewController.h"
#import "Utilities/Diagnostics/BeaDiagnostics.h"
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>
#import "Utilities/Debug/BeaDebug.h"

// Host-based check for whether a URL belongs to BeReal's own API surface,
// shared by every [BeaNet] diagnostic hook below. Checking just the host
// (rather than a raw substring search across the whole URL) avoids matching
// an unrelated domain that happens to embed "bereal.com" somewhere in a
// query string, and keeps this scoped to bereal.com and its subdomains (e.g.
// mobile-l7.bereal.com) - not cdn.bereal.network or storage.googleapis.com,
// which are different domains entirely and would otherwise flood the log
// with image/upload traffic.
static BOOL BeaURLIsInteresting(NSURL *url) {
	NSString *host = url.host.lowercaseString;
	return host != nil && [host hasSuffix:@"bereal.com"];
}

// Records one Authorization / bereal-device-id header into BeaTokenManager,
// which is where BeFake reads the credentials it uploads with. Shared by both
// of NSMutableURLRequest's single-header setters below.
//
// A plain C function rather than a %new method on NSMutableURLRequest: a %new
// method exists only at runtime, so message-sending it from another hook in
// this file wouldn't compile without also declaring it in a category (the same
// "no visible @interface declares the selector" problem documented above the
// UIViewController hook further down).
//
// Never logs the header *value*, only that a capture happened.
static void BeaCaptureHeaderField(NSString *field, NSString *value) {
	if (value.length == 0 || field.length == 0) return;

	// HTTP header names are case-insensitive and a request builder is free to
	// spell it "authorization"; the previous case-sensitive comparison would
	// silently skip that.
	NSString *normalized = field.lowercaseString;
	BOOL isAuthorization = [normalized isEqualToString:@"authorization"];
	if (!isAuthorization && ![normalized isEqualToString:@"bereal-device-id"]) return;

	// Stored under the canonical spelling BeaUploadTask sends back out.
	NSString *canonical = isAuthorization ? @"Authorization" : @"bereal-device-id";

	NSMutableDictionary *existingHeaders = [[[BeaTokenManager sharedInstance] headers] mutableCopy] ?: [NSMutableDictionary dictionary];
	existingHeaders[canonical] = value;
	[[BeaTokenManager sharedInstance] setHeaders:existingHeaders];
	headers = existingHeaders;
	BeaLog("[BeaAuth] captured %{public}@ via a single-header setter", canonical);
}

// ============================================
// JAILBREAK / ENVIRONMENT DETECTION BYPASS
// ============================================
// Nikolozi's original PAGDeviceHelper/STKDevice coverage, widened with the
// extra ad/analytics SDK checks and BeReal's own 4.58.0 JailbreakCheck class
// that tqmane added for environments where those additional checks actually
// fire. Every one of these hooks a real, fixed (non-Swift-mangled) class
// name, so Logos's default ungrouped %hook already no-ops safely if a given
// SDK isn't linked into a particular BeReal build - no extra guarding needed,
// consistent with how PAGDeviceHelper/STKDevice already worked here.

%hook PAGDeviceHelper
+ (BOOL)bu_isJailBroken {
	return NO;
}
+ (BOOL)isJailBroken {
	return NO;
}
%end

%hook STKDevice
+ (BOOL)containsJailbrokenFiles {
	return NO;
}

+ (BOOL)containsJailbrokenPermissions {
	return NO;
}

+ (BOOL)isJailbroken {
	return NO;
}

+ (BOOL)isDebug {
	return NO;
}
%end

// Shake SDK
%hook SHKDeviceInfo
+ (BOOL)isJailbroken {
	return NO;
}
- (BOOL)isJailbroken {
	return NO;
}
%end

// Adjust SDK
%hook ADJDeviceInfo
- (BOOL)isJailBroken {
	return NO;
}
+ (BOOL)isJailBroken {
	return NO;
}
%end

// Google Ads SDK
%hook GADDeviceInfo
- (BOOL)isJailbroken {
	return NO;
}
%end

// Meta Audience Network SDK
%hook FBAdUtility
+ (BOOL)isJailbroken {
	return NO;
}
%end

// Generic UIDevice extension some SDKs probe via respondsToSelector: rather
// than a named helper class above - adds the selector rather than overriding
// an existing one (Logos handles this the same way %hook always does), so
// it's inert for anything that never asks.
%hook UIDevice
- (BOOL)isJailbroken {
	return NO;
}
%end

// Blocks a handful of jailbreak-app URL schemes from canOpenURL: probes,
// which several ad SDKs use as a secondary jailbreak signal alongside the
// file-system checks below. URL schemes are case-insensitive, so this
// normalizes before comparing; the blocked-scheme set is static rather than
// rebuilt on every call, since canOpenURL: can be probed frequently.
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
	if (!url) return %orig;
	NSString *scheme = url.scheme.lowercaseString;
	if (!scheme) return %orig;
	static NSSet<NSString *> *blockedSchemes;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		blockedSchemes = [NSSet setWithArray:@[@"cydia", @"sileo", @"zebra", @"filza", @"undecimus", @"activator"]];
	});
	if ([blockedSchemes containsObject:scheme]) {
		return NO;
	}
	return %orig;
}
%end

%hook NSMutableURLRequest
-(void)setAllHTTPHeaderFields:(NSDictionary *)arg1 {
	%orig;

	// Always refresh (not just capture-once) so a token refresh mid-session
	// is picked up too - a single stale capture from early in the session
	// would otherwise silently keep BeFake's uploads authenticated with an
	// expired token.
	if ([[arg1 allKeys] containsObject:@"Authorization"] && [[arg1 allKeys] containsObject:@"bereal-device-id"]) {
		if ([arg1[@"Authorization"] length] > 0) {
			headers = [arg1 copy];
			[[BeaTokenManager sharedInstance] setHeaders:headers];
			BeaLog("[BeaAuth] captured headers via setAllHTTPHeaderFields:");
		}
	}

	// Piggybacked on this hook rather than only the NSURLSession
	// factory-method hooks further down, since those never fired at all in
	// practice - BeReal's own networking likely doesn't route its feed-fetch
	// through either of the two specific selectors hooked there. This one is
	// already confirmed firing (it's how the auth token itself gets
	// captured, and that's been working since early in this project), so it
	// at least confirms which URLs are actually being called even without
	// response bodies.
	//
	// Widened from a raw "bereal.com/api/" substring match to the host-based
	// BeaURLIsInteresting check - a real capture showed heavy feed/reaction/
	// unblur activity but zero matching traffic under /api/, even though
	// person/me, settings, and content/posts all did. The class survey found
	// *ServiceAsyncClient classes (Relationships, Discovery), the naming
	// convention gRPC/Connect-RPC codegen uses - those clients typically hit
	// paths like /relationships.v1.RelationshipsService/Method on the same
	// host, not /api/..., which would explain the total silence under the
	// old filter.
	NSString *urlString = self.URL.absoluteString ?: @"";
	if (BeaURLIsInteresting(self.URL)) {
		BeaLog("[BeaNet] request configured: %{public}@ %{public}@", self.HTTPMethod ?: @"GET", urlString);
	}
}

// Some networking paths set Authorization/bereal-device-id one header at a
// time rather than via a full dictionary - these two are the
// setAllHTTPHeaderFields: hook's siblings for that case, so auth capture
// doesn't depend on which spelling BeReal's own code happens to use.
//
// NSMutableURLRequest has two single-header setters and only setValue: was
// hooked before. addValue:forHTTPHeaderField: appends rather than replaces,
// and is what a request builder that accumulates headers one at a time calls -
// so if BeReal's networking uses it for Authorization, no token was ever
// captured, and every BeFake upload failed with "please restart the app" with
// nothing to indicate why.
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
	%orig;
	BeaCaptureHeaderField(field, value);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
	%orig;
	BeaCaptureHeaderField(field, value);
}
%end

%hook CAFilter
-(void)setValue:(id)arg1 forKey:(id)arg2 {
    // remove the blur that gets applied to the BeReals
	// this is kind of a fallback if the normal unblur function somehow fails (BeReal 2.0+)

	if (([arg1 isEqual:@(13)] || [arg1 isEqual:@(8)]) && [self.name isEqual:@"gaussianBlur"]) {
		return %orig(0, arg2);
	}
    %orig;
}
%end

// BeReal 4.58.0 introduced a dedicated blur-state layer that the CAFilter
// hook above never touches (it only intercepts the CoreAnimation filter
// value, not whatever decides a post counts as "blurred" in the first
// place). Forcing both to report "not blurred" is the complementary,
// version-specific fix tqmane added; resolved dynamically below and no-ops
// on BeReal versions where these classes don't exist, so it's additive to -
// not a replacement for - the CAFilter fallback.
%hook BlurStateUseCaseImpl
- (BOOL)isBlurred {
	return NO;
}
- (BOOL)isBlurredState {
	return NO;
}
- (id)blurState {
	return nil;
}
%end

%hook NewDoubleMediaViewModel
- (BOOL)isBlurred {
	return NO;
}
- (BOOL)blurred {
	return NO;
}
%end

// BeReal's own new (4.58.0) jailbreak-check class - resolved dynamically
// below alongside the blur-state classes above, same reasoning.
%hook BeaJailbreakCheck
- (BOOL)isJailbroken {
	return NO;
}
+ (BOOL)isJailbroken {
	return NO;
}
- (BOOL)check {
	return NO;
}
+ (BOOL)check {
	return NO;
}
- (BOOL)isJailbreak {
	return NO;
}
+ (BOOL)isJailbreak {
	return NO;
}
%end

// Device introspection (objc_getClassList scanning every loaded class) proved
// there is no plain "UIHostingController" class to resolve at all: BeReal's
// screens are all concrete bound-generic specializations like
// _TtGC7SwiftUI19UIHostingControllerV6BeReal10ReportView_ - Swift mints a
// distinct runtime class per SwiftUI view type, one per screen, with no
// shared name to hook. But every one of those specializations reports its
// own superclass as plain UIViewController, and UIViewController is already
// hooked here (for the alert-dismissal fix below) - so the button logic lives
// on viewDidLayoutSubviews here instead of on any one hosting-controller
// class. The >=400pt width filter in qualifyingImageViewsInView: is what
// keeps this scoped to actual BeReal photos rather than firing on every
// screen in the app (settings, profile, camera, etc. all reach this too).
//
// %property doesn't work here the way it did for MediaView/UIHostingController
// stubs: those were classes *we* declared via a stub @interface in Tweak.h, so
// Logos's generated accessors matched a real (if fake) interface. UIViewController
// is Apple's own already-fully-declared SDK class, and the compiler rejects
// calling selectors it never declared ("no visible @interface... declares the
// selector"). Associated objects via the plain runtime API sidestep this
// entirely - no property/interface declaration needed at all.
//
// Tracked per-controller (not globally by anchor object identity - that was
// tried and reverted). BeReal recycles its UIImageView instances as the feed
// scrolls, reusing the same object for a new post rather than creating a
// fresh one - a global map keyed by anchor identity treated a recycled view
// as "already has a button" and never refreshed which post's photos that
// button actually searches, only what it was created with. That caused
// exactly what it was meant to prevent: wrong photos downloaded (stale
// search scope surviving a recycle), missing buttons (a new post silently
// reusing a tracked object instead of being evaluated fresh), and duplicates
// (a genuinely new object existing alongside a stale tracked one) - all
// worse than the single bug it fixed. That original bug - MainTabBarController
// independently rediscovering the same anchor HomeViewHostingController
// already has a button for, and creating its own duplicate, since both
// controllers get their own independent viewDidLayoutSubviews call and
// MainTabBarController's view contains the same post content as a descendant
// (confirmed via the [BeaDiag] logging below) - is instead fixed by scoping
// this whole block to only run on HomeViewHostingController's own pass, so
// no other controller's pass ever reaches this code at all.
//
// NOTE for future maintenance: BeReal 4.58 restructured top-level navigation
// around a new MainTabBarController (see tqmane's fork), which raises the
// possibility that HomeViewHostingController's exact mangled name below no
// longer exists on very recent BeReal versions, silently disabling both
// floating buttons rather than erroring. Deliberately NOT widening the match
// to also accept MainTabBarController here: that's the exact condition
// KNOWN_ISSUES.md's bug #1 traces the original duplicate-button symptom to
// (MainTabBarController independently re-discovering the same on-screen
// content and creating its own second button). If a real device confirms
// HomeViewHostingController no longer exists, this needs a proper
// single-owner redesign, not a second qualifying class name.
//
// ONE BUTTON PER POST. This used to be a single button per Home controller,
// anchored to the first qualifying photo in the whole feed, and it is the
// direct cause of the "download button belongs to the wrong post" report: with
// two posts on screen, only the first one had a button at all, and the second
// only ever got one once the first had scrolled far enough away to stop
// counting as prominent. The set is now reconciled against every post
// currently on screen - see BeaSyncDownloadButtons.
//
// Reconciled by index rather than keyed on the anchor view. BeReal recycles
// its UIImageView instances as the feed scrolls, reusing one object for a
// different post, so anchor identity is not a stable key for anything (that
// was tried, and is the history recorded in KNOWN_ISSUES.md bug #1). Position
// in the on-screen order is stable, and every pass re-points each button at
// the anchor and search root it should have right now, so a recycle cannot
// leave a button searching the post it was created for.
static const void *BeaDownloadButtonsKey = &BeaDownloadButtonsKey;

// Separate from the two keys above - the profile picture button is a
// different controller entirely from Home (whatever the profile screen's own
// class is), tracked the same per-controller way to avoid the exact stray/
// duplicate-button problems documented in KNOWN_ISSUES.md for the post
// download button.
static const void *BeaProfilePictureButtonKey = &BeaProfilePictureButtonKey;
static const void *BeaProfilePictureButtonAnchorKey = &BeaProfilePictureButtonAnchorKey;

// Temporary: dumps whatever's mounted in the top of the screen (nav/title
// chrome), re-logging per controller whenever that content's shape actually
// changes, so the real "+" upload hook can target the actual current
// class/structure of the BeReal wordmark logo instead of guessing at a name
// that changed in the rewrite. Remove once that hook is wired up. Filter
// device logs for "[BeaDiag]" (with MINIBEA_DEBUG=1 set - see BeaDebug.h).
//
// Round 1 logged once per controller on its very first layout pass, which
// mostly caught still-loading placeholders (a bare activity spinner, a
// FloatingBarHostingView with zero children yet) - the same async-mounting
// behavior already seen elsewhere in this file for the gating overlay.
// Round 2 re-logged on any change in descendant count to catch content that
// mounts later, but kept the same <140pt cutoff - real device data showed
// the scroll-edge blur effect behind the nav area alone runs up to 210pt
// tall in this redesigned "Liquid Glass" chrome, so 140 was too shallow and
// nothing resembling a logo ever showed up under FriendsFeedOverview even
// once fully loaded. Raised the cutoff to comfortably clear that, and added
// accessibilityIdentifier alongside accessibilityLabel - SwiftUI content
// frequently renders without materializing a matching UIImageView/UILabel at
// all (mirrors the gating-overlay Text not bridging to UILabel elsewhere in
// this file), so a UI test identifier may be the only signal a plain
// class/text scan can find.
static const void *BeaLoggedTopChromeCountKey = &BeaLoggedTopChromeCountKey;

static NSInteger BeaCountTopChrome(UIView *view, NSInteger depth) {
	if (depth > 8) return 0;
	CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
	if (frameInWindow.origin.y > 260) return 0;

	NSInteger count = 1;
	for (UIView *subview in view.subviews) {
		count += BeaCountTopChrome(subview, depth + 1);
	}
	return count;
}

static void BeaLogTopChrome(UIView *view, UIWindow *window, NSInteger depth) {
	if (!window || depth > 8) return;
	if (!BeaDebugLoggingEnabled()) return;

	CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
	if (frameInWindow.origin.y > 260) return;

	NSString *accessibilityLabel = view.accessibilityLabel ?: @"";
	NSString *accessibilityIdentifier = view.accessibilityIdentifier ?: @"";
	NSString *extra = @"";
	if ([view isKindOfClass:[UIImageView class]]) {
		UIImage *image = ((UIImageView *)view).image;
		extra = [NSString stringWithFormat:@"image=%.0fx%.0f", image.size.width, image.size.height];
	} else if ([view isKindOfClass:[UILabel class]]) {
		extra = [NSString stringWithFormat:@"text=%@", ((UILabel *)view).text];
	}

	NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
	BeaLog("[BeaDiag]%{public}@%{public}@ frame=%{public}@ a11y=%{public}@ id=%{public}@ %{public}@",
		indent, NSStringFromClass([view class]), NSStringFromCGRect(frameInWindow), accessibilityLabel, accessibilityIdentifier, extra);

	for (UIView *subview in view.subviews) {
		BeaLogTopChrome(subview, window, depth + 1);
	}
}

// The BeReal wordmark/logo itself couldn't be found anywhere in the view
// hierarchy across three rounds of diagnostic logging on the home feed - just
// a translucent scroll-edge blur where it visually sits, meaning it's most
// likely drawn directly by SwiftUI's own renderer with no backing UIView at
// all (the same reason the gating overlay's text needed accessibilityLabel
// instead of UILabel.text). Rather than continue chasing an invisible view,
// the "+" button is added independently to the one real, stable, resolvable
// class name found for the home feed screen itself.
//
// Matched as a substring rather than against one exact mangled name. On BeReal
// 4.58 this controller was a *generic* Swift class, so its ObjC runtime name
// was the specialization "_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_"
// - the literal this used to compare against. Reading the decrypted 4.88
// binary shows it now registers as plain "BeReal.HomeViewHostingController",
// which that comparison can never match, silently taking both floating buttons
// (download *and* the BeFake "+") out of the app entirely with no error
// anywhere. Substring matching covers the generic spelling, the plain one, and
// any future re-parameterization.
//
// This does not reopen KNOWN_ISSUES.md bug #1 (MainTabBarController
// independently rediscovering the same content and adding a duplicate button):
// that class is named "MainTabBarController" and contains this substring
// nowhere, so it still never reaches the button code.
static NSString *const BeaHomeViewHostingControllerClassName = @"HomeViewHostingController";
static const void *BeaUploadButtonKey = &BeaUploadButtonKey;

// Weak so a Home controller BeReal discards gets freed normally - this is
// only ever consulted, never what keeps it alive. Refreshed on every layout
// pass of the Home controller itself, but read from *any* controller's pass
// (see below) since switching away from Home fires the newly-active
// controller's own hook, not Home's - that's the only way to react to
// navigation the button isn't itself present for.
static __weak UIViewController *BeaActiveHomeController = nil;

// Not useful for positioning (its bounding box is the full screen width, see
// the comment on BeaHomeViewHostingControllerClassName above) but still
// useful for visibility: this row hides itself (transform/alpha, not removal)
// when the feed auto-hides its nav chrome on scroll, and mirroring that state
// (via BeaVisibilitySyncTarget below) is the only way the upload button
// doesn't end up floating disconnected from the row it's meant to sit next to.
static UIView *BeaFindViewByClassName(UIView *view, NSString *className, NSInteger depth) {
	if (!view || depth > 20) return nil;
	if ([NSStringFromClass([view class]) isEqualToString:className]) return view;
	for (UIView *subview in view.subviews) {
		UIView *found = BeaFindViewByClassName(subview, className, depth + 1);
		if (found) return found;
	}
	return nil;
}

// KNOWN_ISSUES.md bug #1 (stray/duplicate download button) defensive fix:
// called only right before adding a *newly created* button of a given kind
// (i.e. when this controller's own tracked reference to one is nil), so any
// matching identifier still found anywhere under window at that point is -
// by definition - not the one we're tracking, and therefore orphaned: left
// behind by a controller/anchor no longer tracking it (recycling, dealloc
// without cleanup, etc). Safe to always remove: it can only ever clear a
// genuine stray, never our own about-to-be-added button, since that one
// isn't in the hierarchy yet when this runs. Searches recursively (not just
// window's direct subviews) since the upload button can end up parented
// several levels down, inside the nav-row platter rather than the window
// itself - see its creation site below.
static void BeaRemoveStrayButtons(UIView *root, NSString *identifier, NSInteger depth) {
	if (!root || depth > 20) return;
	for (UIView *subview in [root.subviews copy]) {
		if ([subview.accessibilityIdentifier isEqualToString:identifier]) {
			[subview removeFromSuperview];
		} else {
			BeaRemoveStrayButtons(subview, identifier, depth + 1);
		}
	}
}

// Both floating buttons live directly on the window (needed to out-rank the
// gating overlay's own z-order), which means neither respects normal view-
// controller presentation z-ordering on its own. Without this check, a
// controller whose layout pass fires again mid-presentation-transition
// (plausible, and observed) can re-assert a tracked button back on top of a
// freshly-presented modal - e.g. tapping "+" and getting the previous post's
// download button back on top of the upload screen, only clearing once back
// on the feed and scrolled to a new post.
//
// Sheets this tweak puts up itself are deliberately not counted. The download
// button's long-press front/back/both picker is presented from the window's
// own top-most controller (it has to be - the button is on the window and so
// has no ancestor view controller of its own), so the plain "is anything
// presented?" test hid the button the instant its own menu opened: long press
// worked, the sheet appeared, and the icon it belonged to vanished from under
// it. See +markAsTweakPresented: in BeaButton.
//
// The BeFake composer is *not* marked, so presenting that still hides both
// floating buttons exactly as before.
static BOOL BeaHasPresentedModal(UIWindow *window) {
	UIViewController *presented = window.rootViewController.presentedViewController;
	while (presented) {
		if (![BeaButton isTweakPresented:presented]) return YES;
		presented = presented.presentedViewController;
	}
	return NO;
}

// The feed's own scroll view, so the "+" can get out of the way while the
// timeline is being dragged the same way BeReal's nav row does.
//
// Deliberately a plain UIScrollView search rather than another private-class
// lookup: KNOWN_ISSUES.md bug #2 is the whole history of trying to mirror that
// row through UIKit.NavigationBarPlatterContainer_v2, and its closing note is
// "do not re-introduce a code path that can hide the button when a private
// class lookup fails". Finding nothing here reports "not scrolling", which
// leaves the button visible.
//
// Cached weakly and re-resolved at most twice a second, because this is read
// from the display link every frame while the plain walk is not free.
static __weak UIScrollView *BeaFeedScrollView = nil;

static UIScrollView *BeaLargestScrollViewInView(UIView *view, NSInteger depth) {
	if (!view || depth > 16) return nil;

	UIScrollView *best = nil;
	CGFloat bestArea = 0;
	if ([view isKindOfClass:[UIScrollView class]]) {
		best = (UIScrollView *)view;
		bestArea = view.bounds.size.width * view.bounds.size.height;
	}

	for (UIView *subview in view.subviews) {
		UIScrollView *found = BeaLargestScrollViewInView(subview, depth + 1);
		if (!found) continue;
		CGFloat area = found.bounds.size.width * found.bounds.size.height;
		if (area > bestArea) {
			best = found;
			bestArea = area;
		}
	}
	return best;
}

static BOOL BeaFeedIsScrolling(UIView *root) {
	UIScrollView *scrollView = BeaFeedScrollView;
	if (!scrollView || ![scrollView isDescendantOfView:root]) {
		static CFTimeInterval lastSearch = 0;
		CFTimeInterval now = CACurrentMediaTime();
		if (now - lastSearch < 0.5) return NO;
		lastSearch = now;

		scrollView = BeaLargestScrollViewInView(root, 0);
		BeaFeedScrollView = scrollView;
	}
	if (!scrollView) return NO;
	// Deliberately NOT isTracking. That is already YES the instant a finger
	// lands on the scroll view, before any movement at all - which is why the
	// previous build made the "+" fade out for as long as you held a finger
	// anywhere on the feed, with nothing scrolling. isDragging only becomes
	// YES once the content has actually started to move.
	return scrollView.isDragging || scrollView.isDecelerating;
}

// KNOWN_ISSUES.md bug #2 is closed by deletion rather than by a fix.
//
// The upload button used to try to mirror BeReal's own nav row: find
// UIKit.NavigationBarPlatterContainer_v2, multiply every ancestor's live
// presentation-layer opacity together, and fade with it. Three rounds of
// device testing went into that and it never once tracked the row reliably,
// while every version of it hid the button at a moment it should not have.
// The button is now anchored to the row's *frame* instead (see
// BeaHeaderRowInWindow), which is the part that was actually wanted, and the
// only fade left is the explicit "fade out while scrolling" switch.

// BeReal's own header row. A plain UINavigationBar - Apple's class, present on
// every build, so unlike UIKit.NavigationBarPlatterContainer_v2 (the private
// class KNOWN_ISSUES.md bug #2 is the history of chasing) it either exists or
// the screen has no navigation bar at all.
//
// The "+" is anchored to it rather than to the window's safe area. A safe-area
// constraint is a fixed offset from the *screen*: when iOS 26's chrome moves
// the row, or the safe area changes, the button stays where it was and the gap
// between it and the icons it is meant to sit beside drifts - which is the
// second half of the button-ownership report.
static UIView *BeaHeaderRowInWindow(UIWindow *window) {
	return BeaFindViewByClassName(window, @"UINavigationBar", 0);
}

// Creates, tears down and re-anchors the "+" for `home`. Called from Home's own
// layout pass and from the display link, so flipping its switch in the settings
// screen takes effect without waiting for BeReal to invalidate layout.
static void BeaSyncUploadButton(UIViewController *home) {
	if (!home) return;
	UIView *root = home.view;
	UIWindow *window = root.window;
	BeaButton *tracked = objc_getAssociatedObject(home, BeaUploadButtonKey);

	if (!window || ![BeaSettings boolForKey:BeaSettingShowUploadButton]) {
		if (tracked) {
			[tracked removeFromSuperview];
			objc_setAssociatedObject(home, BeaUploadButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		return;
	}

	if (tracked) {
		// Re-anchor if the row has been rebuilt underneath it (a tab switch
		// replaces the navigation bar's contents, and can replace the bar).
		UIView *headerRow = BeaHeaderRowInWindow(window);
		if (headerRow && tracked.anchorView != headerRow) {
			[tracked attachToAnchor:headerRow corner:BeaButtonCornerLeadingCenter inset:CGPointMake(64, 0)];
		}
		if (tracked.superview != window) [window addSubview:tracked];
		[window bringSubviewToFront:tracked];
		return;
	}

	BeaButton *uploadButton = [BeaButton uploadButton];
	[uploadButton addTarget:home action:@selector(bea_uploadButtonTapped) forControlEvents:UIControlEventTouchUpInside];
	objc_setAssociatedObject(home, BeaUploadButtonKey, uploadButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	// Still parented to the window, never into the navigation bar itself.
	// Parenting into the row was tried (KNOWN_ISSUES.md bug #2) and has two
	// failure modes that both end in an invisible button and no error: the row
	// clips its own subviews, and it lays them out itself. Anchoring to it for
	// *position* gets the same result with neither risk, and the display link
	// below is what stops a window-parented button outranking a modal.
	BeaRemoveStrayButtons(window, BeaUploadButtonAccessibilityID, 0);
	[window addSubview:uploadButton];
	[window bringSubviewToFront:uploadButton];
	uploadButton.layer.zPosition = 99;

	UIView *headerRow = BeaHeaderRowInWindow(window);
	if (headerRow) {
		// There is a visible gap between BeReal's add-friend icon and the
		// wordmark; 64pt in from the row's leading edge lands the button there.
		[uploadButton attachToAnchor:headerRow corner:BeaButtonCornerLeadingCenter inset:CGPointMake(64, 0)];
	} else {
		// No navigation bar on this screen: fall back to the window's own safe
		// area, which is where this button used to live unconditionally.
		// Degrading to the old placement, never to no button - see the
		// NavigationBarPlatterContainer_v2 note above.
		[uploadButton attachToAnchor:window
		                      corner:BeaButtonCornerTopLeading
		                       inset:CGPointMake(64, window.safeAreaInsets.top + 8)];
	}
}

// One download button per post currently on screen, each following its own
// post's photo. See BeaDownloadButtonsKey for why this is reconciled by index.
static void BeaSyncDownloadButtons(UIViewController *home) {
	if (!home) return;
	UIView *root = home.view;
	UIWindow *window = root.window;
	NSMutableArray<BeaButton *> *buttons = objc_getAssociatedObject(home, BeaDownloadButtonsKey);

	if (!window || ![BeaSettings boolForKey:BeaSettingShowDownloadButton]) {
		for (BeaButton *button in buttons) [button removeFromSuperview];
		objc_setAssociatedObject(home, BeaDownloadButtonsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	// Every post on screen right now, in the order they appear.
	NSArray<UIImageView *> *images = [BeaDownloader qualifyingImageViewsInView:root];
	NSMutableArray<UIView *> *anchors = [NSMutableArray array];
	NSMutableArray<UIView *> *containers = [NSMutableArray array];

	for (UIImageView *image in images) {
		// The permissive filter inside qualifyingImageViewsInView: has to
		// accept the front camera's narrow inset too; this is the one place
		// that requires a full-size, single-post photo.
		if (![BeaDownloader isAnchorDisplayedProminently:image]) continue;

		UIView *container = [BeaDownloader localContainerForAnchor:image upToRoot:root];
		// localContainerForAnchor: falls back to returning *something* even
		// when it never found a real front+back pair nearby - only a genuine
		// pair counts as a post.
		if (!container || [BeaDownloader qualifyingImageViewsInView:container].count < 2) continue;
		if ([containers indexOfObjectIdenticalTo:container] != NSNotFound) continue;

		// SwiftUI-bridged containers commonly ship with interaction disabled,
		// opting specific children back in. Re-asserted every pass, not just at
		// creation, in case BeReal re-disables it.
		[BeaDownloader enableUserInteractionFromView:container upToRoot:root];
		[BeaDownloader enableUserInteractionRecursivelyInView:container];

		[anchors addObject:image];
		[containers addObject:container];
	}

	if (!buttons) {
		buttons = [NSMutableArray array];
		objc_setAssociatedObject(home, BeaDownloadButtonsKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	while (buttons.count > anchors.count) {
		[buttons.lastObject removeFromSuperview];
		[buttons removeLastObject];
	}

	for (NSUInteger i = 0; i < anchors.count; i++) {
		BeaButton *button = (i < buttons.count) ? buttons[i] : nil;
		if (!button) {
			// Only safe while we own none: anything already in the window under
			// this identifier is by definition orphaned. Once we do own one,
			// this would take our own buttons with it.
			if (buttons.count == 0) BeaRemoveStrayButtons(window, BeaDownloadButtonAccessibilityID, 0);
			button = [BeaButton downloadButton];
			button.layer.zPosition = 99;
			[buttons addObject:button];
		}
		if (button.superview != window) [window addSubview:button];
		// A gated post's overlay can mount, or remount, after the button was
		// added - reassert front position rather than trusting it to stick.
		[window bringSubviewToFront:button];

		[BeaDownloader setSearchRoot:containers[i] forButton:button];
		if (button.anchorView != anchors[i]) {
			[button attachToAnchor:anchors[i]
			                corner:BeaButtonCornerTopTrailing
			                 inset:CGPointMake(11.6, 11.6)];
		}
	}

	if (anchors.count > 0) {
		[BeaDiagnostics recordDownloadButtonAnchorFrame:[anchors[0] convertRect:anchors[0].bounds toView:nil]];
	}
}

@interface BeaVisibilitySyncTarget : NSObject
@end

@implementation BeaVisibilitySyncTarget

// One place that decides whether each injected button is visible, and where it
// sits, every displayed frame.
//
// It has to be here rather than in -viewDidLayoutSubviews for three separate
// reasons, all of them bugs that were reported against the previous build:
//
//  - a button anchored to a photo inside a scroll view has to be re-placed as
//    the feed scrolls, and scrolling is not a layout pass (see -attachToAnchor:);
//  - posts scroll onto the screen without Home's layout being invalidated, so a
//    new post would not get its own button until something else caused a pass;
//  - while a modal is up, Home does not lay out at all - which is exactly when
//    a window-parented button must be hidden, and exactly why the "+" and the
//    download arrow were still floating on top of the settings screen.
- (void)bea_tick:(CADisplayLink *)link {
	// Placement first and unconditionally: these belong to whichever controller
	// is on screen (the profile-picture one is not Home's at all), and this is
	// what hides any whose anchor has scrolled away or been recycled.
	[BeaButton syncAnchoredButtons];

	UIViewController *home = BeaActiveHomeController;
	UIView *homeRoot = home.view;
	// Not homeRoot.window alone: the profile-picture button is anchored on a
	// screen Home may never have been part of, and "is something presented?"
	// still has to be answerable there.
	UIWindow *window = homeRoot.window ?: [BeaButton anchoredButtons].firstObject.window;
	BOOL modalUp = window != nil && BeaHasPresentedModal(window);
	BOOL homeOnScreen = window != nil && [BeaDownloader isViewOnScreen:homeRoot];

	// Reconciling the button set is a walk of the feed's view tree, so it runs
	// at ~10Hz rather than every frame. That is fast enough that a post
	// scrolling into view has its own button before it has finished arriving,
	// and slow enough not to matter next to what SwiftUI itself does per frame.
	if (home && homeOnScreen && !modalUp) {
		static CFTimeInterval lastReconcile = 0;
		CFTimeInterval now = CACurrentMediaTime();
		if (now - lastReconcile > 0.1) {
			lastReconcile = now;
			BeaSyncUploadButton(home);
			BeaSyncDownloadButtons(home);
		}
	}

	// The scroll-linked fade, off by default. It applies to every injected
	// button now, not just the "+": having one of them fade out on a drag while
	// the other stayed put is why this switch was impossible to tell the effect
	// of. isDragging/isDecelerating, never isTracking - see BeaFeedIsScrolling.
	BOOL scrolling = homeOnScreen &&
		[BeaSettings boolForKey:BeaSettingHideButtonsWhileScrolling] &&
		BeaFeedIsScrolling(homeRoot);

	BeaButton *uploadButton = home ? objc_getAssociatedObject(home, BeaUploadButtonKey) : nil;

	for (BeaButton *button in [BeaButton anchoredButtons]) {
		// The "+" belongs to the home feed specifically; the download buttons
		// are hidden by their own anchors going away, but the header row the
		// "+" is anchored to is still perfectly on screen on every other tab.
		BOOL orphaned = (button == uploadButton) && !homeOnScreen;

		// Alpha only. `hidden` belongs to +syncAnchoredButtons, which is the
		// one thing that knows whether the button's anchor is still on screen;
		// having two writers for it meant every frame set it twice. Alpha is
		// enough on its own - UIKit's hit testing already ignores a view at
		// alpha 0, so a faded button is untappable as well as invisible.
		if (modalUp || orphaned) {
			// Snapped, not eased. A window-parented button has no business
			// being visible over a modal even for the four frames an ease would
			// take, and this is the path that keeps the settings screen clear.
			if (button.alpha != 0) button.alpha = 0;
			continue;
		}

		CGFloat target = scrolling ? 0.0 : 1.0;
		CGFloat alpha = button.alpha;
		// Eased rather than snapped so the button fades with the drag instead
		// of blinking, and written only when it actually changed, so a button
		// at rest costs nothing per frame.
		alpha = (fabs(target - alpha) < 0.01) ? target : alpha + (target - alpha) * 0.18;
		if (alpha != button.alpha) button.alpha = alpha;
	}
}
@end

static CADisplayLink *BeaVisibilityDisplayLink;
static BeaVisibilitySyncTarget *BeaVisibilitySyncTargetInstance;

// Populated by BeaCaptureFriendProfilePictures, defined later in this file
// alongside the rest of the [BeaNet] response-body capture machinery -
// declared here instead since viewDidLayoutSubviews below reads it directly
// and needs it in scope before that point.
//
// Keyed by username AND fullname (lowercased) rather than user ID, both
// mapping to the same URL - two real device captures (opening both an
// already-viewed and a genuinely fresh profile) never once showed
// GET /api/person/profiles/{userId} firing at all, meaning that single
// earlier sighting of it wasn't reproducible and the profile screen almost
// certainly just reads from this already-cached friends list instead of
// making its own fetch. Without a per-profile network call, there's no
// reliable way to know which user ID is currently open just from watching
// requests - matching whatever name text is actually showing on screen back
// to an entry already known from this list is the substitute.
static NSMutableDictionary<NSString *, NSString *> *BeaFriendProfilePictureURLsByName;

static NSString *BeaProfilePictureURLForDisplayedName(NSString *text) {
	if (text.length == 0 || BeaFriendProfilePictureURLsByName.count == 0) return nil;
	NSString *normalized = text.lowercaseString;
	if ([normalized hasPrefix:@"@"]) normalized = [normalized substringFromIndex:1];
	return BeaFriendProfilePictureURLsByName[normalized];
}

// Scans for any UILabel.text or accessibilityLabel matching a cached
// friend's username/fullname - the profile screen shows the person's name
// prominently near their picture (confirmed via device screenshots), so this
// is what actually identifies whose profile is open, not the network layer.
static NSString *BeaFindMatchingFriendProfilePictureURLInView(UIView *view, NSInteger depth) {
	if (!view || depth > 15) return nil;

	if ([view isKindOfClass:[UILabel class]]) {
		NSString *matched = BeaProfilePictureURLForDisplayedName(((UILabel *)view).text);
		if (matched) return matched;
	}
	NSString *a11yMatched = BeaProfilePictureURLForDisplayedName(view.accessibilityLabel);
	if (a11yMatched) return a11yMatched;

	for (UIView *subview in view.subviews) {
		NSString *found = BeaFindMatchingFriendProfilePictureURLInView(subview, depth + 1);
		if (found) return found;
	}
	return nil;
}

%hook UIViewController
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
	// Full-screen/interstitial ads: AppLovin, AdMob, Pangle, Vungle and the
	// rest all ultimately show themselves through this one call, so refusing
	// it here covers every one of them. The caller's completion block is still
	// run (asynchronously, matching what a real presentation would do) - a
	// presenter that waits on it to re-enable its own UI would otherwise hang.
	if ([BeaAdBlocker shouldBlockPresentationOfViewController:viewControllerToPresent]) {
		BeaLog("[BeaAds] blocked presentation of %{public}@", NSStringFromClass([viewControllerToPresent class]));
		if (completion) dispatch_async(dispatch_get_main_queue(), completion);
		return;
	}

	// BeReal somehow shows an error alert when using this tweak (at least on my device), so remove it
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)viewControllerToPresent;
        if ([alert.message isEqualToString:@"[\"Unable to load contents\"]"]) {
            return;
        }
    }
    %orig;
}

- (void)viewDidLayoutSubviews {
	%orig;

	UIView *root = [self view];
	if (!root) return;

	UIWindow *window = root.window;

	if (window && BeaDebugLoggingEnabled()) {
		NSInteger currentTopChromeCount = BeaCountTopChrome(root, 0);
		NSNumber *lastLoggedCount = objc_getAssociatedObject(self, BeaLoggedTopChromeCountKey);
		if (!lastLoggedCount || lastLoggedCount.integerValue != currentTopChromeCount) {
			objc_setAssociatedObject(self, BeaLoggedTopChromeCountKey, @(currentTopChromeCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			BeaLog("[BeaDiag]==== %{public}@ (n=%{public}ld) ====", NSStringFromClass([self class]), (long)currentTopChromeCount);
			BeaLogTopChrome(root, window, 0);
		}
	}

	BOOL isHomeController = [NSStringFromClass([self class]) containsString:BeaHomeViewHostingControllerClassName];

	if (isHomeController) {
		BeaActiveHomeController = self;
		[BeaDiagnostics recordHomeControllerName:NSStringFromClass([self class])];
		// Same two calls the display link makes, so a layout pass applies a
		// settings change (or a rebuilt header row) immediately rather than up
		// to a tenth of a second later.
		BeaSyncUploadButton(self);
	}

	// The entry point of last resort into the settings screen: two fingers,
	// long press, anywhere. Installed from here because it needs a window, and
	// idempotent because this runs on every layout pass of every controller.
	// It is what makes turning the "+" off recoverable - that switch used to
	// remove the only way back in.
	if (window) [BeaSettingsViewController installFallbackGestureOnWindow:window];

	// Upload button visibility (Home-active, nav row auto-hide) is handled
	// continuously by BeaVisibilityDisplayLink instead of here - see its
	// comment for why a layout-pass hook can't observe a transform/alpha-only
	// hide animation.

	NSArray<UIImageView *> *qualifyingImages = [BeaDownloader qualifyingImageViewsInView:root];

	// Gated ("Post to view") posts draw a lock overlay - eye-slash icon,
	// title/body text, and a CTA button - above the photo, separate from and
	// unaffected by the CAFilter blur-removal hook below. Runs unconditionally
	// on every layout pass, since BeReal can (re)mount it at any time, same
	// as the button z-order issue this file already works around.
	[BeaDownloader hideGatingOverlaysInView:root excludingImages:qualifyingImages];

	// BeReal's own in-feed sponsored posts. The %hook UIView pair further down
	// already takes out the vendor SDK's media view inside one of these, but
	// the card around it - advertiser name, "Sponsored", the CTA and the
	// caption - is SwiftUI-drawn with no ad class to match, so it survived as
	// a full-height black rectangle with the advertiser still named on top of
	// it. This finds it by its own "Sponsored" byline instead; see
	// +removeSponsoredContentInView: in BeaAdBlocker.
	[BeaAdBlocker removeSponsoredContentInView:root];

	// Profile picture download button - deliberately NOT scoped to
	// isHomeController like the post download button below, since the
	// profile screen is a different controller entirely with an unknown
	// class name (same "no plain UIHostingController to hook" situation
	// documented above). Detected by exactly one qualifying image (a
	// profile picture, unlike a post's front+back pair) combined with the
	// currently-displayed name resolving to a cached friend - see
	// BeaCaptureFriendProfilePictures and BeaFindMatchingFriendProfilePictureURLInView.
	BeaButton *existingProfilePictureButton = objc_getAssociatedObject(self, BeaProfilePictureButtonKey);
	UIView *existingProfilePictureAnchor = objc_getAssociatedObject(self, BeaProfilePictureButtonAnchorKey);

	// Visibility (a modal is up, the anchor scrolled away) is the display
	// link's job for this button too - see bea_tick:. All that is left here is
	// creating it and tearing it down.
	if (existingProfilePictureButton && (!existingProfilePictureAnchor || ![existingProfilePictureAnchor isDescendantOfView:root] || ![BeaDownloader isAnchorDisplayedProminently:existingProfilePictureAnchor])) {
		[existingProfilePictureButton removeFromSuperview];
		objc_setAssociatedObject(self, BeaProfilePictureButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(self, BeaProfilePictureButtonAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		existingProfilePictureButton = nil;
	}

	if (existingProfilePictureButton) {
		if (window) [window bringSubviewToFront:existingProfilePictureButton];
	} else if (window && qualifyingImages.count == 1) {
		UIView *profilePictureAnchor = qualifyingImages.firstObject;
		NSString *matchedURL = BeaFindMatchingFriendProfilePictureURLInView(root, 0);
		if (profilePictureAnchor && [BeaDownloader isAnchorDisplayedProminently:profilePictureAnchor] && matchedURL.length > 0) {
			BeaButton *profilePictureButton = [BeaButton profilePictureDownloadButton];
			profilePictureButton.layer.zPosition = 99;
			[BeaDownloader setProfilePictureURLString:matchedURL forButton:profilePictureButton];

			objc_setAssociatedObject(self, BeaProfilePictureButtonKey, profilePictureButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(self, BeaProfilePictureButtonAnchorKey, profilePictureAnchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

			BeaRemoveStrayButtons(window, BeaProfilePictureButtonAccessibilityID, 0);
			[window addSubview:profilePictureButton];
			[window bringSubviewToFront:profilePictureButton];

			// Bottom-trailing corner, not top-trailing like the post
			// download button - BeReal's own "..." overflow menu already
			// occupies the top-trailing corner of the profile screen.
			[profilePictureButton attachToAnchor:profilePictureAnchor
										  corner:BeaButtonCornerBottomTrailing
										   inset:CGPointMake(11.6, 11.6)];
		}
	}

	// The post download buttons only ever need to be reconciled for the actual
	// home feed controller - see the comment on BeaDownloadButtonsKey above for
	// why letting every controller (including ancestors like
	// MainTabBarController, which contains the same content as a descendant)
	// run this independently produced duplicate and wrongly-scoped buttons.
	if (!isHomeController) return;
	BeaSyncDownloadButtons(self);
}

%new
- (void)bea_uploadButtonTapped {
	// Deliberately NOT gated on BRAccessToken any more. It used to return
	// silently when no Authorization header had been captured yet, which is
	// indistinguishable from a dead button - tap, nothing happens, no way to
	// tell whether the tweak is broken, the button is inert, or the token
	// just hasn't been seen yet. The composer itself already checks for the
	// token when Send is pressed and shows a real message, so opening it
	// unconditionally is strictly more informative.
	if (![[BeaTokenManager sharedInstance] BRAccessToken]) {
		BeaLog("[BeaAuth] opening BeFake with no captured token yet");
	}

	BeaUploadViewController *uploadViewController = [[BeaUploadViewController alloc] init];
	uploadViewController.modalPresentationStyle = UIModalPresentationFullScreen;
	[self presentViewController:uploadViewController animated:YES completion:nil];
}
%end

// ============================================
// FILE SYSTEM JAILBREAK DETECTION BYPASS
// ============================================
// isBlockedPath is pure C (no Objective-C) deliberately - it's called from
// hooks that must stay safe to invoke very early, before assuming the ObjC
// runtime's own state is fully settled. tqmane's list below (allow-listing
// the app's own bundle path, prefix + exact-match checks, and explicit
// /var/jb/... rootless-prefixed variants of the same jailbreak app paths)
// replaces Nikolozi's original narrower version - strictly wider coverage,
// same mechanism.
//
// IMPORTANT: this project deliberately does NOT hook the C-level access(),
// stat(), lstat(), fopen(), or getenv() functions (e.g. via fishhook) to
// backstop this - tqmane's fork removed exactly those hooks after they
// caused crashes in jailed/sideloaded environments, and reintroducing them
// here would bring that regression back. NSFileManager's own ObjC-level
// methods below are the full extent of the file-system bypass.
static BOOL isBlockedPath(const char *path) {
	if (!path || path[0] == '\0') return NO;

	// Always allow access to the app's own bundle.
	if (strstr(path, "BeReal.app") != NULL) {
		return NO;
	}

	static const char *blockedPrefixes[] = {
		"/var/jb",
		"/private/preboot/",
		"/private/var/jb",
		"/private/var/lib/apt",
		"/private/var/lib/cydia",
		"/private/var/stash",
		"/private/var/tmp/cydia",
		NULL
	};

	for (int i = 0; blockedPrefixes[i] != NULL; i++) {
		size_t len = strlen(blockedPrefixes[i]);
		if (strncmp(path, blockedPrefixes[i], len) == 0) {
			return YES;
		}
	}

	static const char *blockedPaths[] = {
		"/Applications/Cydia.app",
		"/Applications/Sileo.app",
		"/Applications/Zebra.app",
		"/Applications/Filza.app",
		"/Applications/Installer.app",
		"/Applications/NewTerm.app",
		"/Applications/iFile.app",
		"/Library/MobileSubstrate/MobileSubstrate.dylib",
		"/Library/MobileSubstrate/DynamicLibraries",
		"/usr/lib/libhooker.dylib",
		"/usr/lib/libsubstitute.dylib",
		"/usr/lib/substitute",
		"/usr/lib/substrate",
		"/System/Library/LaunchDaemons/com.ikey.bbot.plist",
		"/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
		"/bin/bash",
		"/bin/sh",
		"/usr/sbin/sshd",
		"/usr/bin/sshd",
		"/usr/libexec/sftp-server",
		"/etc/apt",
		"/etc/ssh/sshd_config",
		"/private/etc/apt",
		"/private/etc/ssh/sshd_config",
		"/private/jailbreak.test",
		"/var/tmp/cydia.log",
		"/var/jb/Applications/Cydia.app",
		"/var/jb/Applications/Sileo.app",
		"/var/jb/Applications/Zebra.app",
		"/var/jb/usr/lib/libhooker.dylib",
		"/var/jb/usr/lib/libsubstitute.dylib",
		"/var/jb/bin/bash",
		"/var/jb/bin/sh",
		NULL
	};

	for (int i = 0; blockedPaths[i] != NULL; i++) {
		if (strcmp(path, blockedPaths[i]) == 0) {
			return YES;
		}
	}

	return NO;
}

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (isBlockedPath([path UTF8String])) {
        return NO;
    }
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
	if (isBlockedPath([path UTF8String])) {
		return NO;
	}
	return %orig;
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
	if (isBlockedPath([path UTF8String])) {
		return NO;
	}
	return %orig;
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
	if (isBlockedPath([path UTF8String])) {
		return NO;
	}
	return %orig;
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
	if (isBlockedPath([path UTF8String])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
		return nil;
	}
	return %orig;
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError **)error {
	if (isBlockedPath([path UTF8String])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
		return nil;
	}
	return %orig;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
	NSArray *contents = %orig;
	if (!contents) return contents;

	NSMutableArray *filtered = [NSMutableArray array];
	for (NSString *item in contents) {
		NSString *fullPath = [path stringByAppendingPathComponent:item];
		if (!isBlockedPath([fullPath UTF8String])) {
			[filtered addObject:item];
		}
	}
	return filtered;
}
%end

// ============================================
// AD REMOVAL
// ============================================
// Three layers, because BeReal 4.88 serves ads three different ways and no
// single hook covers all of them:
//
//  1. Named hooks on BeReal's own advert containers (below). Removing the view
//     alone isn't enough for a container inside a self-sizing SwiftUI/UIKit
//     row - zeroing sizeThatFits:/intrinsicContentSize is what actually
//     collapses the empty space it leaves behind.
//  2. A generic %hook UIView pair that asks BeaAdBlocker about every view as
//     it's inserted or moved into a window. That's what covers the ~18
//     embedded vendor SDKs (AppLovin MAX + its five mediation adapters,
//     GoogleMobileAds, Pangle, InMobi, Moloco, PubMatic/OpenWrap, HyBid,
//     Vungle, VoodooAdn, AppHarbr, the OMSDK viewability kits) without naming
//     a single one of their classes - see BeaAdBlocker.m for how they're
//     recognised.
//  3. Refusing to present ad view controllers/windows, which is how every one
//     of those SDKs shows an interstitial.
//
// BeaAdBlocker additionally fails ad/mediation network requests outright (set
// up from %ctor), so in the normal case a slot is never filled to begin with
// and there is nothing left to hide.

%hook AdvertsDataNativeViewContainer
- (void)didMoveToSuperview {
    %orig;
    [BeaAdBlocker neutralizeView:self withVerdict:BeaAdVerdictRemove];
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeZero;
}

- (CGSize)intrinsicContentSize {
    return CGSizeZero;
}
%end

%hook AdvertsDataAppLovinMRECView
- (void)didMoveToSuperview {
    %orig;
    [BeaAdBlocker neutralizeView:self withVerdict:BeaAdVerdictRemove];
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeZero;
}

- (CGSize)intrinsicContentSize {
    return CGSizeZero;
}
%end

%hook AdvertsDataAppLovinNativeView
- (void)didMoveToSuperview {
    %orig;
    [BeaAdBlocker neutralizeView:self withVerdict:BeaAdVerdictRemove];
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeZero;
}

- (CGSize)intrinsicContentSize {
    return CGSizeZero;
}
%end

// Both of these run for every view in the app, so the actual test lives behind
// BeaAdBlocker's per-Class cache - the work is done once per class, ever, and
// every call after that is a pointer lookup.
//
// Two entry points rather than one because neither alone is reliable:
// didAddSubview: fires on the parent (missed if a subclass overrides it
// without calling super) and didMoveToWindow fires on the view itself (missed
// the same way). A view has to defeat both to get through.
%hook UIView
- (void)didAddSubview:(UIView *)subview {
	%orig;
	BeaAdVerdict verdict = [BeaAdBlocker verdictForView:subview];
	if (verdict != BeaAdVerdictNotAd) {
		[BeaAdBlocker neutralizeView:subview withVerdict:verdict];
	}
}

- (void)didMoveToWindow {
	%orig;
	if (!self.window) return;
	BeaAdVerdict verdict = [BeaAdBlocker verdictForView:self];
	if (verdict != BeaAdVerdictNotAd) {
		[BeaAdBlocker neutralizeView:self withVerdict:verdict];
	}
}
%end

// A handful of SDKs put their interstitial in their own UIWindow instead of
// presenting it from the app's root controller, which routes around the
// presentViewController: check above.
%hook UIWindow
- (void)makeKeyAndVisible {
	if ([BeaAdBlocker shouldBlockWindow:self]) {
		self.hidden = YES;
		BeaLog("[BeaAds] blocked ad window %{public}@", NSStringFromClass([self class]));
		return;
	}
	%orig;
}
%end

// Static string analysis of the decrypted BeReal binary (no live device
// needed for this part) turned up a real, NSObject-rooted Swift class -
// BeReal.HasPostedUseCaseImpl - wired directly alongside postRepository and
// blurState in the feed's own dependency graph, making it a much stronger
// candidate for the actual root of the "Post to view" gate than continuing
// to fight the rendered UI after the fact. But the class being visible to
// objc_getClass only proves the *class* is NSObject-rooted - it says nothing
// about whether any individual method is @objc-dynamic (and therefore
// hookable via %hook, which works by swizzling objc_msgSend dispatch) versus
// pure Swift vtable dispatch (invisible to this technique entirely). Rather
// than guess a selector name and burn a round finding out it's wrong, dump
// the real method list at launch - this is the same class_copyMethodList
// technique that resolved the UIHostingController question earlier.
static void BeaLogMethodsOfClass(Class klass, const char *label) {
	if (!BeaDebugLoggingEnabled()) return;
	if (!klass) {
		BeaLog("[BeaClassDump] %{public}s: class not found at ctor time", label);
		return;
	}

	unsigned int instanceCount = 0;
	Method *instanceMethods = class_copyMethodList(klass, &instanceCount);
	BeaLog("[BeaClassDump] %{public}s: %{public}u instance method(s)", label, instanceCount);
	for (unsigned int i = 0; i < instanceCount; i++) {
		BeaLog("[BeaClassDump]   -[%{public}s %{public}s] type=%{public}s",
			label, sel_getName(method_getName(instanceMethods[i])), method_getTypeEncoding(instanceMethods[i]));
	}
	if (instanceMethods) free(instanceMethods);

	unsigned int classCount = 0;
	Method *classMethods = class_copyMethodList(object_getClass(klass), &classCount);
	BeaLog("[BeaClassDump] %{public}s: %{public}u class method(s)", label, classCount);
	for (unsigned int i = 0; i < classCount; i++) {
		BeaLog("[BeaClassDump]   +[%{public}s %{public}s] type=%{public}s",
			label, sel_getName(method_getName(classMethods[i])), method_getTypeEncoding(classMethods[i]));
	}
	if (classMethods) free(classMethods);
}

// Widens the single-class technique above into a full survey: BeReal's
// "UseCase"/"Repository" naming (Clean Architecture, one class per business
// capability) means the app's entire internal feature surface can be mapped
// by enumerating every loaded class and matching on name, rather than
// guessing individual class names and burning a round each time one's wrong.
// "UseCase"/"Repository" are distinctive enough to match unrestricted; the
// broader keywords (Manager, Service, Client, etc.) are common enough in
// Apple's own SDK that they're only checked within modules already directly
// observed in this project's own device logs (BeReal itself, plus the
// per-feature Presentation modules seen in earlier [BeaDiag] captures) to
// keep the output signal, not noise.
static NSArray<NSString *> *BeaKnownModulePrefixes(void) {
	return @[
		@"BeReal.",
		@"RelationshipsPresentation.", @"RelationshipsDomain.", @"RelationshipsData.",
		@"ProfilePresentation.", @"ProfileDomain.", @"ProfileData.",
		@"FeedsFeaturePresentation.", @"FeedsFeatureDomain.", @"FeedsFeatureData.",
		@"MemoriesPresentation.", @"MemoriesDomain.", @"MemoriesData.",
		@"OnboardingPresentation.", @"ContactPermissionPresentation.",
		@"ContentDomain.", @"ContentData.", @"NotificationDomain.", @"NotificationData.",
	];
}

static void BeaSurveyClasses(void) {
	if (!BeaDebugLoggingEnabled()) return;

	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	BeaLog("[BeaClassDump] scanning %{public}u loaded classes", count);

	NSArray<NSString *> *knownModules = BeaKnownModulePrefixes();
	NSArray<NSString *> *alwaysKeywords = @[@"UseCase", @"Repository"];
	NSArray<NSString *> *scopedKeywords = @[@"Manager", @"Service", @"Client", @"Store", @"Provider", @"Interactor", @"Gateway"];

	unsigned long matchCount = 0;
	for (unsigned int i = 0; i < count; i++) {
		Class klass = classes[i];
		const char *rawName = class_getName(klass);
		if (!rawName) continue;
		NSString *name = @(rawName);

		BOOL matches = NO;
		for (NSString *keyword in alwaysKeywords) {
			if ([name rangeOfString:keyword].location != NSNotFound) { matches = YES; break; }
		}
		if (!matches) {
			BOOL inKnownModule = NO;
			for (NSString *prefix in knownModules) {
				if ([name hasPrefix:prefix]) { inKnownModule = YES; break; }
			}
			if (inKnownModule) {
				for (NSString *keyword in scopedKeywords) {
					if ([name rangeOfString:keyword].location != NSNotFound) { matches = YES; break; }
				}
			}
		}
		if (!matches) continue;

		matchCount++;
		BeaLogMethodsOfClass(klass, rawName);
	}

	free(classes);
	BeaLog("[BeaClassDump] %{public}lu matching class(es) total", matchCount);
}

// Temporary: logs method+URL+status+a truncated body preview for every
// request/response through the app's own networking, not just the ones this
// tweak makes itself (BeaUploadTask already logs nothing of its own
// responses either) - the only way to confirm what BeReal's feed-fetch
// actually returns (reactions, retake count, full history, etc.) instead of
// inferring it from the upload payload's schema. Scoped to any bereal.com
// URL (not just /api/ - a real capture showed heavy feed/reaction traffic
// producing zero matches under the old, narrower filter, most likely because
// it uses gRPC/Connect-RPC-style paths on the same host instead). Bodies
// truncated (not full multi-KB+ feed JSON) since this is meant to reveal
// field *names* and rough shape, not capture complete data. Entirely
// gated behind MINIBEA_DEBUG (see BeaDebug.h) - this can include auth
// tokens and other account data, so it must never run by default.
//
// Two entry points, not one - BeaUploadTask itself proves both are in real
// use: dataTaskWithRequest:completionHandler: for its plain GETs
// (upload-url, region, last moment), uploadTaskWithRequest:fromData:completionHandler:
// for the ones with a body (image PUTs, and - the most interesting one to
// confirm the schema for - the actual POST that creates a post). The body
// for that second kind arrives as a separate parameter, not on the request
// itself, hence the explicit override below rather than always reading
// request.HTTPBody.
static BOOL BeaIsInterestingURL(NSURLRequest *request) {
	return BeaURLIsInteresting(request.URL);
}

// BeaFriendProfilePictureURLsByName is declared earlier in this file, right
// before %hook UIViewController - viewDidLayoutSubviews reads it directly
// via BeaFindMatchingFriendProfilePictureURLInView, and that hook comes
// before this function in the file. Populating it does NOT depend on
// MINIBEA_DEBUG - it's the actual profile-picture-download feature, not a
// diagnostic - only the [BeaNet] logging elsewhere in this block is gated.
//
// Originally scoped to GET /api/person/profiles/{userId}?withPost=true,
// which seemed to fire once in an early capture - but two later captures
// (one opening an already-viewed profile, one opening a genuinely fresh one)
// never showed that endpoint fire at all, meaning that sighting wasn't
// reproducible. GET /api/relationships/friends/?page, which reliably does
// fire (re-polled periodically) and already carries a profilePicture.url per
// friend, is the real source - the profile screen most likely just reads
// from this already-cached list rather than making its own fetch.
static void BeaCaptureFriendProfilePictures(NSURL *requestURL, NSData *body) {
	if (body.length == 0) return;
	if ([requestURL.path rangeOfString:@"/api/relationships/friends/"].location == NSNotFound) return;

	id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
	if (![json isKindOfClass:[NSDictionary class]]) return;

	id friends = ((NSDictionary *)json)[@"data"];
	if (![friends isKindOfClass:[NSArray class]]) return;

	if (!BeaFriendProfilePictureURLsByName) BeaFriendProfilePictureURLsByName = [NSMutableDictionary new];

	NSInteger captured = 0;
	for (id friendEntry in (NSArray *)friends) {
		if (![friendEntry isKindOfClass:[NSDictionary class]]) continue;
		NSDictionary *friendDict = (NSDictionary *)friendEntry;

		id profilePicture = friendDict[@"profilePicture"];
		if (![profilePicture isKindOfClass:[NSDictionary class]]) continue;
		id urlValue = ((NSDictionary *)profilePicture)[@"url"];
		if (![urlValue isKindOfClass:[NSString class]] || [(NSString *)urlValue length] == 0) continue;

		id username = friendDict[@"username"];
		id fullname = friendDict[@"fullname"];
		BOOL storedAny = NO;
		if ([username isKindOfClass:[NSString class]] && [(NSString *)username length] > 0) {
			BeaFriendProfilePictureURLsByName[[(NSString *)username lowercaseString]] = (NSString *)urlValue;
			storedAny = YES;
		}
		if ([fullname isKindOfClass:[NSString class]] && [(NSString *)fullname length] > 0) {
			BeaFriendProfilePictureURLsByName[[(NSString *)fullname lowercaseString]] = (NSString *)urlValue;
			storedAny = YES;
		}
		if (storedAny) captured++;
	}
	if (captured > 0) {
		BeaLog("[BeaNet] captured %{public}ld friend profile picture URL(s)", (long)captured);
	}
}

static void BeaLogNetworkRequest(NSURLRequest *request, NSData *explicitBody) {
	if (!BeaDebugLoggingEnabled()) return;
	NSData *body = explicitBody ?: request.HTTPBody;
	NSString *bodyPreview = @"(no body)";
	if (body.length > 0) {
		NSString *decoded = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"(non-utf8 body)";
		bodyPreview = decoded.length > 2000 ? [decoded substringToIndex:2000] : decoded;
	}
	BeaLog("[BeaNet] -> %{public}@ %{public}@ body=%{public}@", request.HTTPMethod ?: @"GET", request.URL.absoluteString ?: @"", bodyPreview);
}

typedef void (^BeaNetworkCompletionBlock)(NSData *data, NSURLResponse *response, NSError *error);

static BeaNetworkCompletionBlock BeaWrapNetworkCompletion(NSURLRequest *request, BeaNetworkCompletionBlock completionHandler) {
	NSString *urlString = request.URL.absoluteString ?: @"";
	NSString *method = request.HTTPMethod ?: @"GET";
	NSURL *requestURL = request.URL;
	return ^(NSData *data, NSURLResponse *response, NSError *error) {
		if (BeaDebugLoggingEnabled()) {
			NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
			NSString *bodyPreview = @"(no data)";
			if (data.length > 0) {
				NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(non-utf8 data)";
				bodyPreview = decoded.length > 4000 ? [decoded substringToIndex:4000] : decoded;
			}
			BeaLog("[BeaNet] <- %{public}@ %{public}@ status=%{public}ld body=%{public}@",
				method, urlString, (long)httpResponse.statusCode, bodyPreview);
		}
		BeaCaptureFriendProfilePictures(requestURL, data);
		completionHandler(data, response, error);
	};
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
	if (!completionHandler || !BeaIsInterestingURL(request)) return %orig;
	BeaLogNetworkRequest(request, nil);
	return %orig(request, BeaWrapNetworkCompletion(request, completionHandler));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
	if (!completionHandler || !BeaIsInterestingURL(request)) return %orig;
	BeaLogNetworkRequest(request, bodyData);
	return %orig(request, bodyData, BeaWrapNetworkCompletion(request, completionHandler));
}

// Same completion-handler shape as the fromData: variant above, just a
// from-file upload instead - cheap extra coverage for the same reason.
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
	if (!completionHandler || !BeaIsInterestingURL(request)) return %orig;
	BeaLogNetworkRequest(request, nil);
	return %orig(request, fileURL, BeaWrapNetworkCompletion(request, completionHandler));
}

// Neither of the two hooks above ever fired in practice on a real device -
// BeReal's own networking (as opposed to this tweak's own BeaUploadTask,
// which does use dataTaskWithRequest:completionHandler: for its plain GETs)
// most likely goes through Swift's async/await URLSession APIs instead,
// which may not bridge through either of those specific selectors. Added
// for completeness/cheap coverage; the resume catch-all below is what
// should actually reveal what's really being called, since it works
// regardless of which factory method created the task.
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
	NSString *urlString = url.absoluteString ?: @"";
	if (!completionHandler || !BeaURLIsInteresting(url)) {
		return %orig;
	}
	BeaLog("[BeaNet] -> GET %{public}@ body=(no body)", urlString);
	NSURLRequest *syntheticRequest = [NSURLRequest requestWithURL:url];
	return %orig(url, BeaWrapNetworkCompletion(syntheticRequest, completionHandler));
}
%end

// Catch-all: fires for every NSURLSessionTask (data, upload, download)
// regardless of which NSURLSession factory method created it or whether it
// uses a completion handler or a delegate - async/await's URLSession.data(for:)
// and third-party networking layers built on delegate callbacks both still
// ultimately call resume on a real task object to start it. Can't recover
// the response body this way (that only reaches whichever completion
// handler or delegate the task was actually created with), but confirms
// which URLs/task classes are genuinely in play - concrete data instead of
// guessing at which specific factory method to hook next. Gated behind
// MINIBEA_DEBUG like the rest of [BeaNet].
%hook NSURLSessionTask
- (void)resume {
	if (BeaDebugLoggingEnabled()) {
		NSURL *url = self.currentRequest.URL ?: self.originalRequest.URL;
		NSString *urlString = url.absoluteString ?: @"";
		if (BeaURLIsInteresting(url)) {
			NSString *method = self.currentRequest.HTTPMethod ?: self.originalRequest.HTTPMethod ?: @"GET";
			BeaLog("[BeaNet] task resumed: class=%{public}@ %{public}@ %{public}@",
				NSStringFromClass([self class]), method, urlString);
		}
	}
	%orig;
}
%end

// Every genuinely BeReal-initiated call (as opposed to this tweak's own
// upload code, which does hit the completion-handler factory methods above)
// has -resume/header-hook confirming a task was created and started, but
// never produces a body through any of the three completion-handler hooks -
// consistent with BeReal routing its own networking through a delegate-based
// task (no completion handler passed at creation, response delivered via
// URLSessionDataDelegate/URLSessionTaskDelegate callbacks instead), which is
// exactly the pattern Swift's `URLSession.data(for:)` async bridge is
// documented to use internally. The concrete class implementing that
// delegate isn't known ahead of time (most likely a private class inside
// Apple's Concurrency bridge, or BeReal's own network layer), so rather than
// naming one in %hook, this scans every loaded class at startup for whichever
// ones directly declare the two callbacks below and swizzles them in place.
// Entirely gated behind MINIBEA_DEBUG (see BeaHookURLSessionDelegateCallbacks
// below) - by default this whole ~127k-class scan never runs at all, since
// it's diagnostic-only and has a real startup-latency cost.
//
// Done with plain ObjC runtime calls (method_setImplementation), not
// CydiaSubstrate's MSHookMessageEx - the JAILED=1 build this project ships
// (see Makefile) deliberately avoids that dependency via Logos's "internal"
// generator, so MSHookMessageEx isn't linked for the build actually used to
// test on-device. Scoped to classes that DIRECTLY declare the selector
// (class_copyMethodList on the class itself, not class_getInstanceMethod's
// hierarchy walk) rather than every subclass that merely inherits it -
// otherwise a single shared base implementation could get redundantly
// re-hooked once per subclass. Original IMPs are stored per-class and looked
// up by walking from the calling instance's actual class up to the nearest
// hooked ancestor, so calling through %orig-equivalent stays correct even
// for subclass instances that never got their own override.
typedef void (*BeaDidReceiveDataIMP)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
typedef void (*BeaDidCompleteIMP)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);

// Keyed by class NAME (NSString), not the Class object itself - a raw Class
// pointer doesn't reliably conform to NSCopying, which NSDictionary requires
// of its keys, and using one anyway is a well-known way to crash on insert.
static NSMutableDictionary<NSString *, NSValue *> *BeaOrigDidReceiveDataByClass;
static NSMutableDictionary<NSString *, NSValue *> *BeaOrigDidCompleteByClass;
static NSMutableDictionary<NSNumber *, NSMutableData *> *BeaPendingTaskBodies;

static IMP BeaFindOriginalIMP(NSMutableDictionary<NSString *, NSValue *> *table, Class klass) {
	while (klass) {
		NSValue *value = table[NSStringFromClass(klass)];
		if (value) return (IMP)[value pointerValue];
		klass = class_getSuperclass(klass);
	}
	return NULL;
}

static void BeaHookedDidReceiveData(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
	NSURL *url = dataTask.currentRequest.URL ?: dataTask.originalRequest.URL;
	if (url && BeaURLIsInteresting(url)) {
		@synchronized (BeaPendingTaskBodies) {
			NSNumber *key = @(dataTask.taskIdentifier);
			NSMutableData *buffer = BeaPendingTaskBodies[key];
			if (!buffer) {
				buffer = [NSMutableData new];
				BeaPendingTaskBodies[key] = buffer;
			}
			[buffer appendData:data];
		}
	}
	IMP orig = BeaFindOriginalIMP(BeaOrigDidReceiveDataByClass, [self class]);
	if (orig) ((BeaDidReceiveDataIMP)orig)(self, _cmd, session, dataTask, data);
}

static void BeaHookedDidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
	NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
	if (url && BeaURLIsInteresting(url)) {
		NSNumber *key = @(task.taskIdentifier);
		NSData *body = nil;
		@synchronized (BeaPendingTaskBodies) {
			body = BeaPendingTaskBodies[key];
			[BeaPendingTaskBodies removeObjectForKey:key];
		}
		if (BeaDebugLoggingEnabled()) {
			NSHTTPURLResponse *httpResponse = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
			NSString *bodyPreview = @"(no data)";
			if (body.length > 0) {
				NSString *decoded = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"(non-utf8 data)";
				bodyPreview = decoded.length > 4000 ? [decoded substringToIndex:4000] : decoded;
			}
			BeaLog("[BeaNet] <-delegate %{public}@ %{public}@ status=%{public}ld err=%{public}@ body=%{public}@",
				task.currentRequest.HTTPMethod ?: task.originalRequest.HTTPMethod ?: @"GET",
				url.absoluteString ?: @"",
				(long)httpResponse.statusCode,
				error.localizedDescription ?: @"(none)",
				bodyPreview);
		}
		BeaCaptureFriendProfilePictures(url, body);
	}
	IMP orig = BeaFindOriginalIMP(BeaOrigDidCompleteByClass, [self class]);
	if (orig) ((BeaDidCompleteIMP)orig)(self, _cmd, session, task, error);
}

// One class_copyMethodList call per class (checking both selectors against
// that single list), not one call per selector - the class list this walks
// is the same ~127k classes BeaSurveyClasses() already scans, so doubling
// the per-class work there would be a real, avoidable startup-latency cost.
//
// Only ever called when MINIBEA_DEBUG is enabled (see %ctor below) - profile
// picture capture (BeaCaptureFriendProfilePictures) does NOT depend on this
// scan running, since it's driven off the header-capture and completion-
// handler hooks above instead, both of which are always active.
static void BeaHookURLSessionDelegateCallbacks(void) {
	BeaPendingTaskBodies = [NSMutableDictionary new];
	BeaOrigDidReceiveDataByClass = [NSMutableDictionary new];
	BeaOrigDidCompleteByClass = [NSMutableDictionary new];
	SEL didReceiveDataSel = @selector(URLSession:dataTask:didReceiveData:);
	SEL didCompleteSel = @selector(URLSession:task:didCompleteWithError:);
	unsigned int classCount = 0;
	Class *classes = objc_copyClassList(&classCount);
	int hookedReceive = 0, hookedComplete = 0;
	for (unsigned int i = 0; i < classCount; i++) {
		Class klass = classes[i];
		unsigned int methodCount = 0;
		Method *methods = class_copyMethodList(klass, &methodCount);
		for (unsigned int m = 0; m < methodCount; m++) {
			SEL sel = method_getName(methods[m]);
			if (sel == didReceiveDataSel) {
				BeaOrigDidReceiveDataByClass[NSStringFromClass(klass)] = [NSValue valueWithPointer:method_getImplementation(methods[m])];
				method_setImplementation(methods[m], (IMP)BeaHookedDidReceiveData);
				hookedReceive++;
			} else if (sel == didCompleteSel) {
				BeaOrigDidCompleteByClass[NSStringFromClass(klass)] = [NSValue valueWithPointer:method_getImplementation(methods[m])];
				method_setImplementation(methods[m], (IMP)BeaHookedDidComplete);
				hookedComplete++;
			}
		}
		free(methods);
	}
	free(classes);
	BeaLog("[BeaNet] delegate hook scan complete: receive=%{public}d complete=%{public}d", hookedReceive, hookedComplete);
}

%ctor {
	// BlurStateUseCaseImpl moved module between BeReal versions - it was
	// FeedsFeatureDomain on 4.58 and is CoreFeedDomain on 4.88 (the 4.88 binary
	// has no FeedsFeatureDomain blur symbols at all). Resolving the first name
	// that exists keeps the unblur working on both instead of silently
	// no-opping on whichever one this file wasn't written against.
	Class blurStateUseCase = NSClassFromString(@"_TtC14CoreFeedDomain20BlurStateUseCaseImpl")
		?: NSClassFromString(@"_TtC18FeedsFeatureDomain20BlurStateUseCaseImpl");

	%init(
      AdvertsDataNativeViewContainer = objc_getClass("AdvertsData.AdvertNativeViewContainer"),
      AdvertsDataAppLovinMRECView = objc_getClass("AdvertsData.AppLovinMRECView"),
      AdvertsDataAppLovinNativeView = objc_getClass("AdvertsData.AppLovinNativeView"),
      BeaJailbreakCheck = NSClassFromString(@"_TtC6BeReal14JailbreakCheck"),
      BlurStateUseCaseImpl = blurStateUseCase,
      NewDoubleMediaViewModel = NSClassFromString(@"_TtC14RealComponents23NewDoubleMediaViewModel")
	);

	// Before anything builds a view. SwiftUI only publishes its text as
	// accessibility elements once these bundles are in, and both the gating
	// overlay hider and the sponsored-card remover read exactly that - see
	// +loadAccessibilityBundlesIfEnabled for the whole story.
	[BeaSettings loadAccessibilityBundlesIfEnabled];

	// Registers the ad/mediation-host NSURLProtocol. Done here rather than
	// lazily so it's in place before any SDK has built its first session.
	[BeaAdBlocker installNetworkBlocking];

	// Undo for the two feed switches. The ad ones own their own undo inside
	// BeaAdBlocker; this covers the gating hider, which is the other thing in
	// the tweak that edits BeReal's own views in place.
	[[NSNotificationCenter defaultCenter] addObserverForName:BeaSettingsDidChangeNotification
	                                                  object:nil
	                                                   queue:[NSOperationQueue mainQueue]
	                                              usingBlock:^(NSNotification *note) {
		NSString *key = note.object;
		if ([key isEqualToString:BeaSettingHideGatingOverlay] ||
		    [key isEqualToString:BeaSettingKeepGatingCTA]) {
			// Unconditional, both directions. Turning it off has to put the
			// overlay back; turning "keep the CTA" on or off has to undo the
			// other variant's edits before the next layout pass re-applies the
			// new one, or the two strategies' hidden views accumulate.
			[BeaDownloader restoreGatingOverlays];
		} else if ([key isEqualToString:BeaSettingShowUploadButton] ||
		           [key isEqualToString:BeaSettingShowDownloadButton]) {
			// The display link picks these up within a tenth of a second on its
			// own; doing it here as well means the change has already happened
			// by the time the settings screen finishes dismissing.
			BeaSyncUploadButton(BeaActiveHomeController);
			BeaSyncDownloadButtons(BeaActiveHomeController);
		}
	}];

	BeaVisibilitySyncTargetInstance = [BeaVisibilitySyncTarget new];
	BeaVisibilityDisplayLink = [CADisplayLink displayLinkWithTarget:BeaVisibilitySyncTargetInstance selector:@selector(bea_tick:)];
	// NSRunLoopCommonModes, not just the default mode - a display link added
	// only to the default mode pauses for the entire duration of an active
	// scroll drag (UIScrollView tracking runs the loop in its own tracking
	// mode), which is exactly when this needs to keep firing.
	[BeaVisibilityDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

	// Unconditional, no MINIBEA_DEBUG/URL filter involved - fires the moment
	// %ctor runs regardless of debug mode or network traffic, so a bug
	// report can always confirm the tweak itself loaded (install/signing
	// issue vs. genuinely not doing anything) even with debug logging off.
	os_log(OS_LOG_DEFAULT, "[Bea] MiniBea %{public}@ loaded (debug logging %{public}s)",
		TWEAK_VERSION, BeaDebugLoggingEnabled() ? "ON" : "off");

	// The full-class-list scans below (URLSession delegate swizzling,
	// UseCase/Repository survey) are diagnostic-only and have a real
	// startup-latency cost across BeReal's ~127k loaded classes - both stay
	// off unless MINIBEA_DEBUG=1 is set (see BeaDebug.h).
	if (BeaDebugLoggingEnabled()) {
		BeaHookURLSessionDelegateCallbacks();
		BeaSurveyClasses();
	}
}
