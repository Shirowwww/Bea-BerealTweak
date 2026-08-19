#import "BeaDownloader.h"
#import <objc/runtime.h>
#import <os/log.h>
#import "../Debug/BeaDebug.h"
#import "../Localization/BeaLocalization.h"
#import "../Settings/BeaSettings.h"
#import "../Diagnostics/BeaDiagnostics.h"
#import "../Runtime/BeaOwnership.h"

static const void *BeaSearchRootKey = &BeaSearchRootKey;
static const void *BeaProfilePictureURLKey = &BeaProfilePictureURLKey;

static NSString *const BeaDownloadSelectionDefaultsKey = @"BeaDownloadSelection";

// ---------------------------------------------------------------------------
// UNDO
// ---------------------------------------------------------------------------
// Everything the gating hider touched, with the value it replaced. Without
// this the switch was a one-way door: turning it off left every already-hidden
// overlay hidden, because the only code that could show one again ran from the
// hide path itself.
@interface BeaGatingEdit : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) CALayer *layer;
@property (nonatomic, assign) BOOL originalHidden;
@property (nonatomic, strong) UIColor *originalBackgroundColor;
@property (nonatomic, assign) BOOL restoresBackgroundColor;
@end

@implementation BeaGatingEdit
@end

static NSMutableArray<BeaGatingEdit *> *BeaGatingEdits;

// Every record holds only weak references, so one whose view and layer have
// both gone is pure ballast - and there is a steady supply of them, because
// BeReal recycles a post's card as soon as it scrolls away. That was survivable
// while the layer pass hid one scrim per post; now that it hides the whole
// cluster it is six or seven records per gated post scrolled past, for the life
// of the process. Pruning the dead ones when the list gets long keeps a long
// feed session flat without ever dropping a record that could still be undone.
static void BeaPruneGatingEdits(void) {
	if (BeaGatingEdits.count < 512) return;

	NSMutableArray<BeaGatingEdit *> *live = [NSMutableArray arrayWithCapacity:BeaGatingEdits.count];
	for (BeaGatingEdit *edit in BeaGatingEdits) {
		if (edit.view || edit.layer) [live addObject:edit];
	}
	BeaGatingEdits = live;
}

static void BeaRecordGatingHiddenView(UIView *view) {
	if (!BeaGatingEdits) BeaGatingEdits = [NSMutableArray array];
	BeaPruneGatingEdits();
	BeaGatingEdit *edit = [BeaGatingEdit new];
	edit.view = view;
	edit.originalHidden = view.hidden;
	[BeaGatingEdits addObject:edit];
}

static void BeaRecordGatingClearedBackground(UIView *view) {
	if (!BeaGatingEdits) BeaGatingEdits = [NSMutableArray array];
	BeaPruneGatingEdits();
	BeaGatingEdit *edit = [BeaGatingEdit new];
	edit.view = view;
	edit.originalHidden = view.hidden;
	edit.originalBackgroundColor = view.backgroundColor;
	edit.restoresBackgroundColor = YES;
	[BeaGatingEdits addObject:edit];
}

// Whether `inner` is essentially inside `outer` - the containment test the
// gating cluster is built on. Not CGRectContainsRect: SwiftUI's frames are full
// of one-third-point rounding (every rect in a device report ends in
// .33333333333331), and a strict test fails on a layer that is visibly inside
// the photo by a third of a point.
static BOOL BeaRectIsMostlyInside(CGRect inner, CGRect outer) {
	CGFloat innerArea = inner.size.width * inner.size.height;
	if (innerArea <= 0) return NO;
	CGRect overlap = CGRectIntersection(inner, outer);
	if (CGRectIsNull(overlap)) return NO;
	return (overlap.size.width * overlap.size.height) / innerArea >= 0.9;
}

static void BeaRecordGatingHiddenLayer(CALayer *layer) {
	if (!BeaGatingEdits) BeaGatingEdits = [NSMutableArray array];
	BeaPruneGatingEdits();
	BeaGatingEdit *edit = [BeaGatingEdit new];
	edit.layer = layer;
	edit.originalHidden = layer.hidden;
	[BeaGatingEdits addObject:edit];
}


// Which physical camera a given on-screen image view is showing. Resolved from
// the CDN URL rather than from geometry: the user can tap a post to swap which
// photo is displayed large, so "the bigger one" is not reliably the back
// camera. BeaCameraUnknown is a real outcome (e.g. SDWebImage isn't backing
// this particular view) and the callers fall back to geometry for it.
typedef NS_ENUM(NSInteger, BeaCamera) {
	BeaCameraUnknown = 0,
	BeaCameraBack,
	BeaCameraFront,
};

// Tracks an in-flight save of one BeReal's images (front + back) so the
// checkmark/re-enable only fires once, after every image has finished saving.
@interface BeaDownloadContext : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, assign) NSInteger remaining;
@property (nonatomic, assign) BOOL failed;
@end

@implementation BeaDownloadContext
@end

@implementation BeaDownloader

+ (BeaDownloadSelection)selection {
	NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:BeaDownloadSelectionDefaultsKey];
	if (stored != BeaDownloadSelectionBack && stored != BeaDownloadSelectionFront) {
		// Covers both "never set" (integerForKey: returns 0) and any garbage
		// value, and keeps "both" as the default behaviour this button has
		// always had.
		return BeaDownloadSelectionBoth;
	}
	return (BeaDownloadSelection)stored;
}

+ (void)setSelection:(BeaDownloadSelection)selection {
	[[NSUserDefaults standardUserDefaults] setInteger:selection forKey:BeaDownloadSelectionDefaultsKey];
}

+ (NSString *)titleForSelection:(BeaDownloadSelection)selection {
	switch (selection) {
		case BeaDownloadSelectionBack:  return BeaLocalized(@"download.back_only");
		case BeaDownloadSelectionFront: return BeaLocalized(@"download.front_only");
		case BeaDownloadSelectionBoth:
		default:                        return BeaLocalized(@"download.both");
	}
}

// BeReal's post media lives at .../post/<id>-primary/<w>/<h> and
// .../post/<id>-secondary/<w>/<h> (both spellings are literal strings in the
// 4.88 binary). "primary" is the back camera - the photo shown large by
// default - and "secondary" is the front-camera selfie.
+ (BeaCamera)cameraForImageView:(UIImageView *)imageView {
	if (![imageView respondsToSelector:@selector(sd_imageURL)]) return BeaCameraUnknown;
	id url = [imageView valueForKey:@"sd_imageURL"];
	NSString *urlString = [url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : nil;
	if (urlString.length == 0) return BeaCameraUnknown;

	if ([urlString containsString:@"secondary"]) return BeaCameraFront;
	if ([urlString containsString:@"primary"]) return BeaCameraBack;
	return BeaCameraUnknown;
}

// `sorted` arrives largest-displayed-first from qualifyingImageViewsInView:.
// For a selection of a single camera, prefer the URL-derived answer and only
// fall back to that ordering (largest = back) when the URL says nothing -
// which is exactly the assumption the old both-photos-only code already made.
+ (NSArray<UIImageView *> *)imageViewsIn:(NSArray<UIImageView *> *)sorted forSelection:(BeaDownloadSelection)selection {
	NSUInteger available = MIN(sorted.count, (NSUInteger)2);
	if (available == 0) return @[];

	NSArray<UIImageView *> *pair = [sorted subarrayWithRange:NSMakeRange(0, available)];
	if (selection == BeaDownloadSelectionBoth) return pair;

	BeaCamera wanted = (selection == BeaDownloadSelectionFront) ? BeaCameraFront : BeaCameraBack;
	for (UIImageView *imageView in pair) {
		if ([self cameraForImageView:imageView] == wanted) return @[imageView];
	}

	// No URL match. With only one photo on screen there's nothing to choose
	// between, so save it either way rather than silently doing nothing.
	if (pair.count == 1) return pair;

	return @[selection == BeaDownloadSelectionBack ? pair.firstObject : pair.lastObject];
}

+ (void)downloadImage:(id)sender {
	[self downloadSelection:[self selection] forButton:(UIButton *)sender];
}

+ (void)downloadSelection:(BeaDownloadSelection)selection forButton:(UIButton *)button {
	if (![button isKindOfClass:[UIButton class]]) return;
	// The button lives on the window now (see setSearchRoot:forButton: and
	// Tweak.x), so button.superview is the window, not the post - the real
	// search scope was recorded separately at creation time.
	UIView *root = objc_getAssociatedObject(button, BeaSearchRootKey) ?: button.superview;
	if (!root) return;

	NSArray<UIImageView *> *sorted = [self qualifyingImageViewsInView:root];
	NSArray<UIImageView *> *toSave = [self imageViewsIn:sorted forSelection:selection];

	NSMutableArray<UIImage *> *images = [NSMutableArray array];
	for (UIImageView *imageView in toSave) {
		if (imageView.image) [images addObject:imageView.image];
	}
	[self saveImages:images forButton:button];
}

// The one place that writes to the camera roll. Split out of
// downloadSelection:forButton: so the media viewer's own save button reports
// exactly the same way (disabled, then a green checkmark, then back) instead of
// growing a second, subtly different copy of this.
+ (void)saveImages:(NSArray<UIImage *> *)images forButton:(UIButton *)button {
	if (images.count == 0) return;

	button.enabled = NO;

	BeaDownloadContext *context = [BeaDownloadContext new];
	context.button = button;
	context.remaining = (NSInteger)images.count;
	context.failed = NO;

	for (UIImage *image in images) {
		void *contextInfo = (void *)CFBridgingRetain(context);
		UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), contextInfo);
	}
}

+ (void)downloadProfilePicture:(id)sender {
	UIButton *button = (UIButton *)sender;
	NSString *urlString = objc_getAssociatedObject(button, BeaProfilePictureURLKey);
	NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
	if (!url) return;

	button.enabled = NO;

	BeaDownloadContext *context = [BeaDownloadContext new];
	context.button = button;
	context.remaining = 1;
	context.failed = NO;

	// Unlike downloadImage:, which saves a UIImageView's already-decoded
	// .image, this has to actually fetch the CDN URL - there's no on-screen
	// view guaranteed to already hold this bitmap (the profile screen's own
	// image view was deliberately not used as the source, see the comment on
	// BeaLastCapturedProfilePictureURL in Tweak.x).
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		UIImage *image = data ? [UIImage imageWithData:data] : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!image) {
				context.button.enabled = YES;
				return;
			}
			void *contextInfo = (void *)CFBridgingRetain(context);
			UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), contextInfo);
		});
	}];
	[task resume];
}

+ (BOOL)isViewOnScreen:(UIView *)view {
	UIWindow *window = view.window;
	if (!window) return NO;
	CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
	return CGRectIntersectsRect(frameInWindow, window.bounds);
}

+ (BOOL)isAnchorDisplayedProminently:(UIView *)anchor {
	UIWindow *window = anchor.window;
	if (!window) return NO;
	CGRect frameInWindow = [anchor convertRect:anchor.bounds toView:nil];
	if (!CGRectIntersectsRect(frameInWindow, window.bounds)) return NO;

	// Only used to decide whether to create/keep the download button - never
	// to filter which images actually get searched/downloaded, since the
	// front camera's PiP is legitimately much narrower than the back camera
	// and must still count as a qualifying image there. The "swipe down for
	// a grid of everyone's BeReals" view reuses the same kind of
	// full-resolution image views the single-post feed does, just displayed
	// as small thumbnails, and small always-present chrome elsewhere (nav
	// icons, etc.) can otherwise also intersect the window trivially.
	// Requiring near-full post width rules both out as button anchors.
	CGRect intersection = CGRectIntersection(frameInWindow, window.bounds);
	return intersection.size.width >= window.bounds.size.width * 0.6;
}

+ (NSArray<UIImageView *> *)qualifyingImageViewsInView:(UIView *)root {
	NSMutableArray<UIImageView *> *candidates = [NSMutableArray array];
	[self collectImageViewsInView:root result:candidates];

	if (candidates.count == 0) return @[];

	// BeReal's feed is a pager that keeps the next post's content mounted
	// off-screen for smooth swiping, so `root` (a shared container VC's view)
	// can contain more than one post's images at once. Restrict to images
	// whose frame actually falls within the screen so we don't pick up a
	// neighboring, not-yet-visible post's photo instead of (or alongside) the
	// one actually being viewed - this is what caused the button to anchor to
	// every other post, and downloads to grab an extra photo from the post
	// next to the one tapped.
	NSMutableArray<UIImageView *> *onScreen = [NSMutableArray array];
	for (UIImageView *imageView in candidates) {
		if ([self isViewOnScreen:imageView]) {
			[onScreen addObject:imageView];
		}
	}

	if (onScreen.count == 0) return @[];

	// Process visible views before hidden ones so dedupe keeps the copy with
	// meaningful on-screen geometry (BeReal keeps a hidden copy of whichever
	// image isn't currently the large frame).
	NSMutableArray<UIImageView *> *visible = [NSMutableArray array];
	NSMutableArray<UIImageView *> *hidden = [NSMutableArray array];
	for (UIImageView *imageView in onScreen) {
		if ([self isView:imageView visibleWithinRoot:root]) {
			[visible addObject:imageView];
		} else {
			[hidden addObject:imageView];
		}
	}

	NSMutableArray<UIImageView *> *ordered = [NSMutableArray arrayWithArray:visible];
	[ordered addObjectsFromArray:hidden];

	NSMutableSet *seenKeys = [NSMutableSet set];
	NSMutableArray<UIImageView *> *uniqueImageViews = [NSMutableArray array];
	for (UIImageView *imageView in ordered) {
		id key = [self dedupeKeyForImageView:imageView];
		if ([seenKeys containsObject:key]) continue;
		[seenKeys addObject:key];
		[uniqueImageViews addObject:imageView];
	}

	return [uniqueImageViews sortedArrayUsingComparator:^NSComparisonResult(UIImageView *a, UIImageView *b) {
		CGRect frameA = [a convertRect:a.bounds toView:nil];
		CGRect frameB = [b convertRect:b.bounds toView:nil];
		CGFloat areaA = frameA.size.width * frameA.size.height;
		CGFloat areaB = frameB.size.width * frameB.size.height;
		if (areaA > areaB) return NSOrderedAscending;
		if (areaA < areaB) return NSOrderedDescending;
		return NSOrderedSame;
	}];
}

+ (UIView *)localContainerForAnchor:(UIView *)anchor upToRoot:(UIView *)root {
	// Adjacent posts are always at least partially on-screen (the feed peeks
	// the next/previous post at the top/bottom edge for swipe affordance), so
	// the on-screen check in qualifyingImageViewsInView: alone can't tell a
	// peeking neighbor's photo apart from this post's own second (usually much
	// smaller) camera. View-tree proximity can: front and back camera image
	// views of the same post are near each other in the hierarchy, while a
	// different post's images live under a completely different branch.
	// Walk up from the anchor looking for the smallest ancestor that already
	// contains a full pair on its own - that's the post's own local container.
	UIView *candidate = anchor.superview;
	UIView *fallback = candidate ?: anchor;
	NSInteger levelsWalked = 0;
	while (candidate && candidate != root && levelsWalked < 12) {
		if ([self qualifyingImageViewsInView:candidate].count >= 2) {
			return candidate;
		}
		fallback = candidate;
		candidate = candidate.superview;
		levelsWalked++;
	}
	return fallback;
}

+ (void)enableUserInteractionFromView:(UIView *)view upToRoot:(UIView *)root {
	UIView *current = view;
	while (current) {
		current.userInteractionEnabled = YES;
		if (current == root) break;
		current = current.superview;
	}
}

+ (void)setSearchRoot:(UIView *)root forButton:(UIButton *)button {
	objc_setAssociatedObject(button, BeaSearchRootKey, root, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)setProfilePictureURLString:(NSString *)urlString forButton:(UIButton *)button {
	objc_setAssociatedObject(button, BeaProfilePictureURLKey, urlString, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)enableUserInteractionRecursivelyInView:(UIView *)view {
	view.userInteractionEnabled = YES;
	for (UIView *subview in view.subviews) {
		[self enableUserInteractionRecursivelyInView:subview];
	}
}

+ (BOOL)viewOrDescendantIsButtonLike:(UIView *)view {
	// A plain UIButton class check misses SwiftUI's own Button, which when
	// hosted in UIKit doesn't reliably bridge to a real UIButton instance -
	// but SwiftUI does correctly mark it accessible as a button regardless of
	// its underlying class, so check accessibility traits too.
	if ([view isKindOfClass:[UIButton class]]) return YES;
	if ((view.accessibilityTraits & UIAccessibilityTraitButton) != 0) return YES;
	for (UIView *subview in view.subviews) {
		if ([self viewOrDescendantIsButtonLike:subview]) return YES;
	}
	return NO;
}

// The gating copy, read out of BeReal's own string table at runtime rather
// than hardcoded.
//
// This is what the previous hardcoded-English version got wrong: it looked for
// "post to view" / "share yours with them", so on any device not set to
// English the overlay was never found and never hidden. In French, for
// instance, BeReal renders "Poste pour voir" and "Pour voir les BeReal de tes
// amis, poste le tien." - no overlap with either needle. Reading the strings
// from the app means all 15 languages BeReal ships work, and so does a future
// copy change, without maintaining a translation table here.
//
// The keys below are BeReal 4.88's real key names (from
// Localisation_Localisation.bundle). Anything that doesn't resolve is skipped,
// and if the bundle itself can't be found at all the English literals are
// still used as a fallback so this is never worse than before.
+ (NSArray<NSString *> *)gatingCopyNeedles {
	static NSArray<NSString *> *needles;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSArray<NSString *> *keys = @[
			@"timelineCell_blurredView_title",
			@"timelineCell_blurredView_title_cf",
			@"timelineCell_blurredView_title_nearby",
			@"timelineCell_blurredView_description_myFriends",
			@"timelineCell_blurredView_description_discoveryFoF",
			@"timelineCell_blurredView_description_cf",
			@"timelineCell_blurredView_description_nearby",
			@"profile_oa_blurred_post",
		];

		NSMutableArray<NSString *> *resolved = [NSMutableArray array];

		for (NSString *key in keys) {
			// BeaAppLocalized returns the fallback (here: nothing usable)
			// rather than echoing the key back, which is exactly what must not
			// end up in the needle list - a key like
			// "timelineCell_blurredView_title" would never match rendered text
			// but would still be dead weight on every scan.
			NSString *normalized = BeaNormalizedCopy(BeaAppLocalized(key, @""));
			if (normalized.length >= 6) [resolved addObject:normalized];
		}

		if (resolved.count == 0) {
			[resolved addObjectsFromArray:@[@"post to view", @"share yours with them"]];
		}

		needles = [resolved copy];
		BeaLog("[Bea] gating copy: %{public}ld localized needle(s) resolved", (long)needles.count);
	});
	return needles;
}

+ (BOOL)textMatchesGatingCopy:(NSString *)normalizedCandidate {
	if (normalizedCandidate.length < 6) return NO;

	for (NSString *needle in [self gatingCopyNeedles]) {
		if ([normalizedCandidate containsString:needle]) return YES;
		// The other direction too: SwiftUI can hand back a truncated or
		// partially-composed accessibility label for a long body string.
		if (normalizedCandidate.length >= 12 && [needle containsString:normalizedCandidate]) return YES;
	}
	return NO;
}

+ (void)collectGatingMarkersInView:(UIView *)view result:(NSMutableArray<UIView *> *)result {
	// Matched on the specific gating copy, not a generic fragment like
	// "to view" - that alone also matched unrelated text elsewhere (most
	// likely an auto-generated accessibility hint on a nav bar icon), hiding
	// things nowhere near the actual lock overlay.
	//
	// BeaCollectViewsWithMatchingText is what reads the text, and it looks in
	// more places than this used to: UILabel/UITextView/UIButton titles, the
	// view's own accessibilityLabel, and - the one that matters here - the
	// UIAccessibilityContainer elements a SwiftUI hosting view publishes.
	// Matching UILabel.text plus accessibilityLabel found nothing on a real
	// device even with correctly localized needles, and SwiftUI not bridging
	// its Text to any UIView at all is the explanation that fits: the string
	// exists only as a UIAccessibilityElement hanging off the hosting view.
	BeaCollectViewsWithMatchingText(@"gating", view, ^BOOL(NSString *normalized) {
		return [self textMatchesGatingCopy:normalized];
	}, result);
}

// Hides everything under `container` that isn't on the path down to a button,
// and returns how many pieces of non-button content it found (whether or not
// they were already hidden, so the count is stable across repeated passes).
//
// This is what keeps the "Post a BeReal." call to action while the eye-slash
// icon, the "Post to view" title and the body line below it all go: the CTA is
// the only thing in the overlay that is - or contains - a button.
+ (NSInteger)hideNonButtonContentInView:(UIView *)container {
	// `container` itself is on the path to the button and stays, but its own
	// backdrop is part of what's covering the photo.
	if (container.backgroundColor) BeaRecordGatingClearedBackground(container);
	container.backgroundColor = [UIColor clearColor];

	NSInteger contentFound = 0;
	for (UIView *subview in container.subviews) {
		// The button itself - leave it completely alone, including its own
		// label and background, or "keep the button" turns into an invisible
		// button-shaped hole.
		if ([subview isKindOfClass:[UIButton class]] ||
		    (subview.accessibilityTraits & UIAccessibilityTraitButton) != 0) {
			continue;
		}

		if ([self viewOrDescendantIsButtonLike:subview]) {
			contentFound += [self hideNonButtonContentInView:subview];
		} else {
			contentFound++;
			if (!subview.hidden) {
				BeaRecordGatingHiddenView(subview);
				subview.hidden = YES;
			}
		}
	}
	return contentFound;
}

// ---------------------------------------------------------------------------
// LAYER PASS
// ---------------------------------------------------------------------------
// The post's own card: the nearest ancestor of the photo that also holds the
// front-camera photo, i.e. the smallest view that is definitely one whole post.
+ (UIView *)gatingCardForPhoto:(UIView *)photo images:(NSArray<UIImageView *> *)images {
	UIView *candidate = photo.superview;
	for (NSInteger depth = 0; candidate && depth < 8; depth++) {
		NSInteger contained = 0;
		for (UIImageView *image in images) {
			if ([image isDescendantOfView:candidate]) contained++;
		}
		if (contained >= 2) return candidate;
		candidate = candidate.superview;
	}
	return nil;
}

// The gating overlay's drawing layers inside one post card, as a cluster
// anchored on its scrim.
//
// The version this replaces collected any layer between 5% and 160% of the
// photo's area, and that one filter is the whole of the "gating is still
// visible" report. Measured against a real 402x536 photo, the scrim (402x536,
// 100%) was the only piece of the overlay that passed it: the eye-slash icon is
// 40x40 (0.7%), the title 120x20 (1.1%), the body 314x18 (2.6%), the CTA pill
// 144x36 (2.4%) and its label 120x18 (1.0%) - every one of them under the 5%
// floor meant to skip "decorations". The device report says exactly that, and
// so does the screenshot next to it: the photo undimmed, and "Poste pour voir",
// the icon and the button all still on screen.
//
// Size is the wrong signal. Stacking order is the right one - SwiftUI draws
// this overlay as a scrim with everything else painted on top of it, so the
// cluster is
//
//     the scrim, plus every drawing layer above it that stays inside the photo
//
// which needs no size threshold at all, and cannot reach anything BeReal drew
// *below* the scrim (the post header, the front-camera placeholder), because
// that is content the overlay dims rather than part of the overlay.
//
// Every guard is still shaped so the failure mode is "the overlay stays" rather
// than "the feed goes blank":
//
//  - view-backed layers are excluded outright, so this can never hide either
//    photo, the gesture view or the "..." button;
//  - the cluster only exists at all if a scrim does: a background-filled layer,
//    above the photo in the card's own sublayer order, covering at least half
//    of it. A post with no scrim is not gated and contributes nothing;
//  - every member has to sit inside the photo's own rect, so a caption or a
//    reaction row under the photo is out of reach;
//  - and the count is capped, so a pathological card cannot take a screenful
//    of layers with it.
+ (NSArray<CALayer *> *)gatingLayerClusterForPhoto:(UIView *)photo inCard:(UIView *)card {
	CALayer *cardLayer = card.layer;
	CALayer *photoLayer = photo.layer;
	if (!cardLayer || !photoLayer) return @[];

	// Which of the card's own sublayers the photo lives under - the ordering
	// reference for "drawn above".
	NSInteger photoBranch = -1;
	NSArray<CALayer *> *sublayers = cardLayer.sublayers;
	for (NSInteger i = 0; i < (NSInteger)sublayers.count && photoBranch < 0; i++) {
		for (CALayer *walk = photoLayer; walk; walk = walk.superlayer) {
			if (walk == sublayers[i]) { photoBranch = i; break; }
		}
	}
	if (photoBranch < 0) return @[];

	CGRect photoInCard = [photoLayer convertRect:photoLayer.bounds toLayer:cardLayer];
	CGFloat photoArea = MAX(photoInCard.size.width * photoInCard.size.height, (CGFloat)1.0);

	// Pass one: find the scrim. Deliberately does *not* skip already-hidden
	// layers. On every pass after the first, the scrim is one this code hid
	// itself, and treating that as "no scrim, not gated" would leave the rest of
	// the overlay on screen forever - which is the other half of the same
	// report, since the first pass hid the scrim and nothing else. Nothing is
	// written here, so re-finding it every pass costs a dozen rect conversions.
	NSInteger scrimIndex = -1;
	for (NSInteger i = photoBranch + 1; i < (NSInteger)sublayers.count; i++) {
		CALayer *layer = sublayers[i];
		if ([layer.delegate isKindOfClass:[UIView class]]) continue;
		if (!layer.backgroundColor) continue;

		CGRect frameInCard = [layer convertRect:layer.bounds toLayer:cardLayer];
		if (frameInCard.size.width * frameInCard.size.height < photoArea * 0.5) continue;
		if (!BeaRectIsMostlyInside(frameInCard, photoInCard)) continue;

		scrimIndex = i;
		break;
	}
	if (scrimIndex < 0) return @[];

	NSMutableArray<CALayer *> *cluster = [NSMutableArray array];
	for (NSInteger i = scrimIndex; i < (NSInteger)sublayers.count && cluster.count < 24; i++) {
		CALayer *layer = sublayers[i];
		if ([layer.delegate isKindOfClass:[UIView class]]) continue;

		CGRect frameInCard = [layer convertRect:layer.bounds toLayer:cardLayer];
		if (frameInCard.size.width < 1 || frameInCard.size.height < 1) continue;
		if (!BeaRectIsMostlyInside(frameInCard, photoInCard)) continue;

		[cluster addObject:layer];
	}
	return cluster;
}

+ (BOOL)photoIsGated:(UIView *)photo inCard:(UIView *)card {
	if (!photo || !card) return NO;
	return [self gatingLayerClusterForPhoto:photo inCard:card].count > 0;
}

// The "Poste un BeReal." pill inside a cluster, or nil.
//
// It is the one member that is background-*filled* and is not the scrim, which
// is a property of how SwiftUI draws this overlay rather than a guess: the
// icon, both text lines and the button's own label are all either drawing
// layers (contents, no fill) or plain clipping containers, and the only two
// filled layers in the whole cluster are the scrim covering the photo and the
// button. Deliberately not a cornerRadius test - the pill is rounded with a
// mask layer rather than a corner radius, so that would find nothing.
//
// Returning nil is a supported outcome: "keep the CTA" then degrades to hiding
// the overlay whole, which is exactly what that switch already promises when
// the overlay turns out not to be separable.
+ (CALayer *)gatingCTALayerInCluster:(NSArray<CALayer *> *)cluster
                         inCardLayer:(CALayer *)cardLayer
                           photoArea:(CGFloat)photoArea {
	CALayer *best = nil;
	CGFloat bestArea = 0;
	for (CALayer *layer in cluster) {
		if (!layer.backgroundColor) continue;

		CGRect frameInCard = [layer convertRect:layer.bounds toLayer:cardLayer];
		CGFloat area = frameInCard.size.width * frameInCard.size.height;
		// Anything approaching the photo's own size is the scrim, not a button.
		if (area <= 0 || area > photoArea * 0.25) continue;
		if (area > bestArea) {
			best = layer;
			bestArea = area;
		}
	}
	return best;
}

+ (NSInteger)hideGatingLayersInView:(UIView *)root excludingImages:(NSArray<UIImageView *> *)images {
	NSMutableArray<CALayer *> *toHide = [NSMutableArray array];
	NSInteger found = 0;

	for (UIImageView *photo in images) {
		// Only a full-size photo, never the front-camera inset - the overlay is
		// drawn over the post, and that inset sits on top of it.
		if (![self isAnchorDisplayedProminently:photo]) continue;
		UIView *card = [self gatingCardForPhoto:photo images:images];
		if (!card) continue;

		NSArray<CALayer *> *cluster = [self gatingLayerClusterForPhoto:photo inCard:card];
		if (cluster.count == 0) continue;
		found += (NSInteger)cluster.count;

		CGRect photoInCard = [photo.layer convertRect:photo.layer.bounds toLayer:card.layer];
		CGFloat photoArea = MAX(photoInCard.size.width * photoInCard.size.height, (CGFloat)1.0);

		CALayer *cta = [BeaSettings effectiveBoolForKey:BeaSettingKeepGatingCTA]
			? [self gatingCTALayerInCluster:cluster inCardLayer:card.layer photoArea:photoArea]
			: nil;
		CGRect ctaFrame = cta ? [cta convertRect:cta.bounds toLayer:card.layer] : CGRectNull;

		for (CALayer *layer in cluster) {
			if (cta) {
				if (layer == cta) continue;
				// The button's label is a sibling of the pill rather than a child
				// of it, so "keep the button" has to be geometric: keep whatever
				// the pill's own rect contains, or the CTA survives as an empty
				// button-shaped hole.
				CGRect frameInCard = [layer convertRect:layer.bounds toLayer:card.layer];
				if (BeaRectIsMostlyInside(frameInCard, ctaFrame)) continue;
			}
			[toHide addObject:layer];
		}
	}

	NSInteger hidden = 0;
	for (CALayer *layer in toHide) {
		if (layer.hidden) continue;
		BeaRecordGatingHiddenLayer(layer);
		layer.hidden = YES;
		hidden++;
		BeaLog("[Bea] hiding gating layer %{public}@ %{public}@",
			NSStringFromClass([layer class]), NSStringFromCGRect(layer.frame));
	}

	// Both numbers, not just the second. On every pass after the first the
	// cluster is already hidden, and "0 hidden" on its own reads identically to
	// "never found anything" - which is what made the last device report
	// ambiguous about whether the layer pass was working at all.
	[BeaDiagnostics recordGatingLayers:found hidden:hidden];
	return found;
}

+ (void)restoreGatingOverlays {
	for (BeaGatingEdit *edit in BeaGatingEdits) {
		UIView *view = edit.view;
		if (view) {
			view.hidden = edit.originalHidden;
			if (edit.restoresBackgroundColor) view.backgroundColor = edit.originalBackgroundColor;
			continue;
		}
		CALayer *layer = edit.layer;
		if (layer) layer.hidden = edit.originalHidden;
	}
	BeaLog("[Bea] restored %{public}lu gating edit(s)", (unsigned long)BeaGatingEdits.count);
	[BeaGatingEdits removeAllObjects];
}

// The view pass: act on markers the text/accessibility scan found. Returns how
// many overlays it actually took off the screen, which is what decides whether
// the layer pass still has work to do.
+ (NSInteger)hideGatingOverlayViewsForMarkers:(NSArray<UIView *> *)markers
                                         root:(UIView *)root
                                       images:(NSArray<UIImageView *> *)images {
	UIWindow *window = root.window;
	NSInteger handled = 0;

	for (UIView *marker in markers) {
		BeaLog("[Bea] gating marker: class=%{public}@ a11yLabel=%{public}@", NSStringFromClass([marker class]), marker.accessibilityLabel);

		// Widen from the matched view to the whole overlay. Unlike before,
		// this no longer stops at the first button-like ancestor - stopping
		// there meant the overlay that got hidden was the one *containing* the
		// CTA, which took the button with it. The button is now preserved by
		// hideNonButtonContentInView: below instead, so widening can go as far
		// as it safely can.
		UIView *overlay = marker;
		UIView *candidate = marker.superview;
		NSInteger levelsWalked = 0;

		while (candidate && candidate != root && levelsWalked < 10) {
			BOOL containsPhoto = NO;
			for (UIImageView *imageView in images) {
				if ([imageView isDescendantOfView:candidate]) {
					containsPhoto = YES;
					break;
				}
			}
			// Any wider ancestor contains the photo too - keep the last safe
			// candidate and stop.
			if (containsPhoto) break;

			// Second guard, for the case where the gated post's photo never
			// became a qualifying image view (not loaded yet, too small) and
			// so isn't in `images` to stop the walk. Without it a missing
			// photo could widen this all the way to a full-screen container.
			if (window) {
				CGRect frameInWindow = [candidate convertRect:candidate.bounds toView:nil];
				CGFloat coverage = (frameInWindow.size.width * frameInWindow.size.height) /
					MAX(window.bounds.size.width * window.bounds.size.height, (CGFloat)1.0);
				if (coverage > 0.95) break;
			}

			overlay = candidate;
			candidate = candidate.superview;
			levelsWalked++;
		}

		// Refuse an "overlay" that is really the post, or the whole feed.
		//
		// The loop above only ever used containsPhoto as a *stop* condition, so
		// it never checked the view it settled on - and the view it settles on is
		// the marker itself whenever the marker already contains a photo. That is
		// not hypothetical: a marker found through the accessibility tree reports
		// the SwiftUI view that published the string, which for BeReal's feed is
		// the host for the entire timeline. Hiding that blanks the screen, and
		// with "read SwiftUI text" on (the default) it is the *likely* path, not
		// the edge case. The sponsored-card remover has had the equivalent guard
		// since it was written (+viewIsPlausibleSponsoredCard:); this is the same
		// rule, and the correct outcome is the same too - fall through to the
		// layer pass, which can act on a SwiftUI-drawn overlay precisely, rather
		// than act on something this wide.
		BOOL overlayHoldsPhoto = NO;
		for (UIImageView *imageView in images) {
			if ([imageView isDescendantOfView:overlay]) {
				overlayHoldsPhoto = YES;
				break;
			}
		}
		if (overlayHoldsPhoto) {
			BeaLog("[Bea] refusing gating overlay %{public}@ - it holds the post's own photo", NSStringFromClass([overlay class]));
			continue;
		}
		if (window) {
			CGRect frameInWindow = [overlay convertRect:overlay.bounds toView:nil];
			CGFloat coverage = (frameInWindow.size.width * frameInWindow.size.height) /
				MAX(window.bounds.size.width * window.bounds.size.height, (CGFloat)1.0);
			if (coverage > 0.6) {
				BeaLog("[Bea] refusing gating overlay %{public}@ - covers %.0f%% of the window",
					NSStringFromClass([overlay class]), coverage * 100);
				continue;
			}
		}

		// If the overlay is *itself* the button (SwiftUI can publish an entire
		// tappable overlay as one element), there is no inside to strip -
		// stripping it would only gut the button. Fall through to hiding it.
		BOOL overlayIsTheButton = [overlay isKindOfClass:[UIButton class]] ||
			(overlay.accessibilityTraits & UIAccessibilityTraitButton) != 0;

		// Keeping the CTA is the nicer outcome and what was asked for, but it
		// is also the half that depends on the overlay having a separable view
		// structure at all. When it is switched off, the overlay is hidden
		// whole - less pretty, always works.
		if (!overlayIsTheButton &&
		    [BeaSettings effectiveBoolForKey:BeaSettingKeepGatingCTA] &&
		    [self viewOrDescendantIsButtonLike:overlay] &&
		    [self hideNonButtonContentInView:overlay] > 0) {
			BeaLog("[Bea] stripped gating copy from %{public}@ (%d levels up), CTA kept", overlay, (int)levelsWalked);
			handled++;
			continue;
		}

		// No button anywhere under the overlay, or nothing separable from it
		// (SwiftUI can publish an entire overlay - icon, both lines and the
		// button - as a single accessibility element with no child views to
		// pick apart). Hiding the lot still gets the photo visible, which is
		// the point; the CTA is the nice-to-have.
		if (!overlay.hidden) {
			BeaLog("[Bea] hiding whole gating overlay %{public}@ (%d levels up from marker)", overlay, (int)levelsWalked);
			BeaRecordGatingHiddenView(overlay);
			overlay.hidden = YES;
		}
		handled++;
	}

	return handled;
}

+ (void)hideGatingOverlaysInView:(UIView *)root excludingImages:(NSArray<UIImageView *> *)images {
	if (![BeaSettings effectiveBoolForKey:BeaSettingHideGatingOverlay]) return;

	NSMutableArray<UIView *> *markers = [NSMutableArray array];
	[self collectGatingMarkersInView:root result:markers];
	BeaLog("[Bea] gating scan: %{public}ld marker(s) found under %{public}@", (long)markers.count, NSStringFromClass([root class]));
	[BeaDiagnostics recordGatingMarkers:(NSInteger)markers.count];

	// The view pass first when it has anything to act on, and the layer pass
	// whenever the view pass did not actually take an overlay off the screen.
	//
	// It used to be strictly one or the other, chosen on "did the text scan find
	// anything at all". That is the wrong question, and it is why turning "read
	// SwiftUI text" on could make the gating hider do *less*: with the
	// accessibility bundles loaded the scan does find the copy - published by
	// the hosting view for the whole feed, which the guard above rightly refuses
	// to hide - and the layer pass, the only one that can act on a
	// SwiftUI-drawn overlay at all, then never ran.
	NSInteger handledViews = markers.count > 0
		? [self hideGatingOverlayViewsForMarkers:markers root:root images:images]
		: 0;
	if (handledViews > 0) {
		[BeaDiagnostics recordGatingLayers:0 hidden:0];
		return;
	}

	[self hideGatingLayersInView:root excludingImages:images];
}

+ (void)collectImageViewsInView:(UIView *)view result:(NSMutableArray<UIImageView *> *)result {
	// The tweak's own views are not posts, and never a search root - the
	// buttons carry SF Symbol image views and the media viewer shows the very
	// photos this walk is looking for. See BeaOwnership.h.
	if (BeaViewIsOurs(view)) return;

	// Deliberately does not prune hidden/zero-alpha subtrees here (unlike the
	// old class-name-based search) - the front camera's image view may live in
	// one of those, and we need it collected so it can be saved too.
	if ([view isKindOfClass:[UIImageView class]]) {
		UIImageView *imageView = (UIImageView *)view;
		// BeReal photos are ~1500x2000; this filters out avatars, reaction
		// thumbnails, and the download button's own SF Symbol image view.
		if (imageView.image && imageView.image.size.width >= 400) {
			[result addObject:imageView];
		}
	}

	for (UIView *subview in view.subviews) {
		[self collectImageViewsInView:subview result:result];
	}
}

+ (BOOL)isView:(UIView *)view visibleWithinRoot:(UIView *)root {
	UIView *current = view;
	while (current) {
		if (current.hidden || current.alpha <= 0.0) {
			return NO;
		}
		if (current == root) break;
		current = current.superview;
	}
	return YES;
}

+ (id)dedupeKeyForImageView:(UIImageView *)imageView {
	// SDWebImage is already linked into the BeReal binary; if this image view
	// is backed by it, its source URL is the most reliable identity to dedupe
	// on (a swapped/hidden copy of the same photo shares the same URL).
	if ([imageView respondsToSelector:@selector(sd_imageURL)]) {
		id url = [imageView valueForKey:@"sd_imageURL"];
		if (url) return url;
	}

	if (imageView.image) {
		return [NSValue valueWithNonretainedObject:imageView.image];
	}

	return [NSValue valueWithNonretainedObject:imageView];
}

+ (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
	BeaDownloadContext *context = (BeaDownloadContext *)CFBridgingRelease(contextInfo);

	// UIImageWriteToSavedPhotosAlbum's completion isn't guaranteed to land on
	// the main thread, and with two images in flight it can arrive from two
	// threads at once - serialize the shared counter through the main queue.
	dispatch_async(dispatch_get_main_queue(), ^{
		if (error) {
			NSLog(@"[Bea]Error saving image: %@", error.localizedDescription);
			context.failed = YES;
		}

		context.remaining -= 1;
		if (context.remaining > 0) return;

		if (context.failed) {
			// Leave the button as-is (no checkmark) but re-enable it - it was
			// disabled before the saves started and must not get stuck.
			context.button.enabled = YES;
		} else {
			[self flashCheckmarkOnButton:context.button];
		}
	});
}

+ (void)flashCheckmarkOnButton:(UIButton *)button {
	if (!button) return;

	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19];
	UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:config];
	[UIView transitionWithView:button duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
	[button setImage:checkmarkImage forState:UIControlStateNormal];
	[button setEnabled:NO];
	[button.imageView setTintColor:[UIColor colorWithRed:122.0/255.0 green:255.0/255.0 blue:108.0/255.0 alpha:1.0]];} completion:nil];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:config];
		[UIView transitionWithView:button duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
			[button setImage:downloadImage forState:UIControlStateNormal];
			[button.imageView setTintColor:[UIColor whiteColor]];
			[button setEnabled:YES];
		} completion:nil];
    });
}
@end
