#import "BeaMediaUnlock.h"
#import "BeaMediaViewer.h"
#import "../Debug/BeaDebug.h"
#import "../Diagnostics/BeaDiagnostics.h"
#import "../Downloader/BeaDownloader.h"
#import "../Settings/BeaSettings.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// The tap recognizer older builds hung off the photo itself. Kept only so
// -restoreAll can still find and remove one left behind by a previous version
// of this class; nothing adds these any more - see the note below.
static const void *BeaMediaTapKey = &BeaMediaTapKey;

// The overlays this class owns, hung off the post card they were added to.
static const void *BeaMediaOverlaysKey = &BeaMediaOverlaysKey;

// BeReal's own gesture-catching overlay over a post's media. Matched as a
// substring, not against one exact mangled name: this repo has already been
// bitten twice by an exact class-name compare that silently stopped matching
// after a rename (see AGENTS.md on HomeViewHostingController and
// BlurStateUseCaseImpl). The bare type name survives a module move.
static NSString *const BeaMediaGesturesClassNameFragment = @"MainMediaGesturesView";

// Marks a gestures-overlay view we are currently holding disabled, so a
// reconcile pass that runs again 1/10s later knows not to record its (already
// disabled, by us) state as if it were the original value.
static const void *BeaMediaGesturesHeldKey = &BeaMediaGesturesHeldKey;

// When this card's overlays were last brought to the front. Per card, because
// the reorder has to be rate-limited against the view SwiftUI is re-appending
// into, not globally - a second gated post on screen is not the same fight.
static const void *BeaMediaLastReorderKey = &BeaMediaLastReorderKey;

// ---------------------------------------------------------------------------
// WHY THE TAP TARGET IS A VIEW OF OURS AND NOT A RECOGNIZER ON THE PHOTO
// ---------------------------------------------------------------------------
// The previous build put a UITapGestureRecognizer on each SDAnimatedImageView
// and held RealComponents.UIMainMediaGesturesView's own userInteractionEnabled
// at NO, expecting hit-testing to then fall through to the photo underneath.
// It does not, and that is the whole of the "media unlock still does not work"
// report. A device hierarchy dump of one gated card reads:
//
//   SwiftUI._UIInheritedView            {0,249} 402x536   <- photo branch
//     _UIInheritedView
//       UIKitPlatformViewHost<AnimatedImage>
//         AnimatedImageViewWrapper
//           SDAnimatedImageView                            <- recognizer was here
//   SwiftUI._UIInheritedView            {0,249} 402x536   <- gestures branch
//     UIKitPlatformViewHost<MainMediaGesturesView>
//       RealComponents.UIMainMediaGesturesView             <- held disabled
//
// -[UIView hitTest:withEvent:] walks subviews back to front and returns the
// deepest view that claims the point in the last branch that claims it at all;
// it does not resume searching earlier siblings when a deeper view declines.
// Disabling the innermost gestures view only promoted its still-interactive
// SwiftUI wrappers - which have the identical frame - to being the hit-test
// result. The touch therefore landed on a plain container in the gestures
// branch, and a recognizer attached to a view in the *photo* branch is neither
// that view nor one of its ancestors, so UIKit never delivered the touch to it.
// Tapping a gated photo did nothing at all, exactly as reported.
//
// The fix is to stop trying to make BeReal's view tree hand a touch to a view
// it does not contain, and instead put a view of ours where the touch already
// lands: a plain transparent overlay, added as the last subview of the post
// card, framed over the photo. The last sibling wins the hit test outright, so
// this needs nothing from BeReal's own interaction flags and cannot be defeated
// by the wrappers around them.
//
// UIMainMediaGesturesView is still held disabled while the post is gated, as
// defence in depth rather than as the mechanism: if SwiftUI rebuilds the card
// between two reconcile passes and our overlay is momentarily not the last
// subview, the worst case has to be "the tap does nothing", never "the tap
// opens the camera composer" - which is what BeReal binds to that view on a
// gated post, and is the symptom that made the first attempt at this feature
// worse than not having it.
@interface BeaMediaTapOverlay : UIView
// The photo this overlay stands in for. Weak, and re-read at tap time rather
// than trusted: BeReal recycles its image views between posts.
@property (nonatomic, weak) UIImageView *targetPhoto;
@end

@implementation BeaMediaTapOverlay
@end

// Every overlay currently installed, weakly. This is the catcher's map of
// "where is a gated photo right now" - it has to be a registry rather than a
// walk of the view tree, because it is consulted from
// -gestureRecognizer:shouldReceiveTouch:, i.e. once per touch that lands
// anywhere in BeReal's window.
static NSHashTable<BeaMediaTapOverlay *> *BeaOverlayRegistry;
static NSUInteger BeaWindowCatcherTapCount = 0;
static BOOL BeaWindowCatcherInstalled = NO;

// Guards the two paths that can open the viewer for the same tap - the
// overlay's own recognizer, and the window catcher - from both firing. Whichever
// gets there first wins; the other sees the timestamp and returns.
static CFTimeInterval BeaLastViewerPresentation = 0;

// The recognizer this class hangs on a UIWindow, so -restoreAll can find it
// again on a window the reconcile pass will never visit.
static const void *BeaMediaWindowCatcherKey = &BeaMediaWindowCatcherKey;

@interface BeaMediaWindowCatcherDelegate : NSObject <UIGestureRecognizerDelegate>
@end

// ---------------------------------------------------------------------------
// UNDO
// ---------------------------------------------------------------------------
// Same rule as everywhere else in this tweak: whoever changes one of BeReal's
// own views records what it replaced, or the switch is a one-way door.
@interface BeaMediaEdit : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, assign) BOOL originalValue;
@end

@implementation BeaMediaEdit
@end

static NSMutableArray<BeaMediaEdit *> *BeaMediaEdits;

static void BeaRecordInteractionEnabled(UIView *view) {
	if (!BeaMediaEdits) BeaMediaEdits = [NSMutableArray array];
	BeaMediaEdit *edit = [BeaMediaEdit new];
	edit.view = view;
	edit.originalValue = view.userInteractionEnabled;
	[BeaMediaEdits addObject:edit];
}

@interface BeaMediaUnlock ()
+ (void)tearDownPost:(UIView *)container card:(UIView *)card photos:(NSArray<UIImageView *> *)photos;
+ (void)detachFromPhotos:(NSArray<UIImageView *> *)photos;
+ (void)removeOverlaysFromCard:(UIView *)card;
+ (void)holdGesturesOverlayDisabledInContainer:(UIView *)container depth:(NSInteger)depth;
+ (void)restoreGatedGesturesOverlayIn:(UIView *)container depth:(NSInteger)depth;
+ (UIView *)gesturesOverlayInContainer:(UIView *)container depth:(NSInteger)depth;
+ (void)removeAddedRecognizersInView:(UIView *)view depth:(NSInteger)depth;
+ (void)removeOverlaysInView:(UIView *)view depth:(NSInteger)depth;
+ (void)installWindowCatcherOnWindow:(UIWindow *)window;
+ (BeaMediaTapOverlay *)overlayForWindowPoint:(CGPoint)point inWindow:(UIWindow *)window;
+ (void)presentViewerForPhoto:(UIImageView *)photo inWindow:(UIWindow *)window;
@end

@implementation BeaMediaWindowCatcherDelegate

// The whole of the catcher's "am I allowed to be involved at all" decision.
// Everything it rejects here is a touch the recognizer never sees again, which
// is what keeps a window-level recognizer from being the reckless thing it
// sounds like.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
	if (![BeaSettings effectiveBoolForKey:BeaSettingUnlockMediaInteractions]) return NO;

	UIWindow *window = touch.window ?: (UIWindow *)recognizer.view;
	if (![window isKindOfClass:[UIWindow class]]) return NO;

	CGPoint point = [touch locationInView:window];
	if (![BeaMediaUnlock overlayForWindowPoint:point inWindow:window]) return NO;

	// A gated photo has BeReal's own "..." button on it, and this tweak's
	// window-parented download button sits in its top-trailing corner. Because
	// the catcher never cancels a touch, accepting one of those would open the
	// viewer *as well as* doing what the control does - so anything that already
	// belongs to a control is left alone. Whatever wins the hit test is by
	// definition the thing the user aimed at.
	UIView *hit = [window hitTest:point withEvent:nil];
	for (UIView *view = hit; view && view != window; view = view.superview) {
		if ([view isKindOfClass:[BeaMediaTapOverlay class]]) break;
		if ([NSStringFromClass([view class]) hasPrefix:@"Bea"]) return NO;
		if ([view isKindOfClass:[UIControl class]]) return NO;
		if ((view.accessibilityTraits & UIAccessibilityTraitButton) != 0) return NO;
	}
	return YES;
}

// Never a competitor to anything BeReal drives - the feed's pan, the horizontal
// pager and BeReal's own taps all keep working through this untouched.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
	return YES;
}

@end

@implementation BeaMediaUnlock

+ (void)load {
	[[NSNotificationCenter defaultCenter] addObserverForName:BeaSettingsDidChangeNotification
	                                                  object:nil
	                                                   queue:[NSOperationQueue mainQueue]
	                                              usingBlock:^(NSNotification *note) {
		if (![note.object isEqual:BeaSettingUnlockMediaInteractions]) return;
		// Only the off direction needs doing here. Turning it back on is picked
		// up by the next reconcile pass a tenth of a second later.
		//
		// Reads the *effective* value, so the three-finger master suspend takes
		// this path too without BeaRuntime having to know this class exists.
		if (![BeaSettings effectiveBoolForKey:BeaSettingUnlockMediaInteractions]) [self restoreAll];
	}];
}

+ (void)syncPostWithContainer:(UIView *)container
                    mainPhoto:(UIImageView *)photo
                         root:(UIView *)root {
	if (!container || !photo) return;

	NSArray<UIImageView *> *photos = [BeaDownloader qualifyingImageViewsInView:container];
	if (photos.count == 0) return;

	// Resolved before either teardown path, not inside the success path.
	// +gatingCardForPhoto: and +localContainerForAnchor: (which is where
	// `container` comes from) walk up from the same photo by different rules and
	// are only *usually* the same view - and the overlays are hung off the card.
	// Tearing down against `container` alone therefore had a case where it
	// silently found nothing to remove, which is how a stale tap target survives
	// a switch being turned off.
	UIView *card = [BeaDownloader gatingCardForPhoto:photo images:photos];

	if (![BeaSettings effectiveBoolForKey:BeaSettingUnlockMediaInteractions]) {
		[self tearDownPost:container card:card photos:photos];
		return;
	}

	// Gated on the same evidence the overlay hider acts on, and no other. A
	// post the user can already open is a post BeReal's own gestures already
	// handle - adding a second tap target there would be interference, not a
	// feature.
	if (!card || ![BeaDownloader photoIsGated:photo inCard:card]) {
		// Not (or no longer) gated. BeReal recycles these views between posts,
		// so anything left on one would follow it onto a post that never needed
		// it - and the gestures overlay this class may have been holding
		// disabled has to go back to however BeReal wants it for an unlocked
		// post (normally interactive, so its own gestures keep working).
		[self tearDownPost:container card:card photos:photos];
		return;
	}

	// Ancestors first: hit testing stops descending as soon as it meets a view
	// with interaction disabled, and our overlays are added inside `card`.
	if (root) [BeaDownloader enableUserInteractionFromView:card upToRoot:root];

	// Defence in depth, not the mechanism - see the long note above. It has to
	// be re-asserted every pass regardless, because BeaCollectVisiblePosts in
	// Tweak.x force-enables interaction on every view in a visible post (for the
	// download button's sake) immediately before this method runs.
	[self holdGesturesOverlayDisabledInContainer:card depth:0];

	// One overlay per photo, in the order +qualifyingImageViewsInView: returns
	// them - largest first. Two is the whole post; anything beyond that is a
	// neighbouring card the container walk picked up.
	NSUInteger wanted = MIN(photos.count, (NSUInteger)2);
	NSMutableArray<BeaMediaTapOverlay *> *overlays = objc_getAssociatedObject(card, BeaMediaOverlaysKey);
	if (!overlays) {
		overlays = [NSMutableArray array];
		objc_setAssociatedObject(card, BeaMediaOverlaysKey, overlays, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	while (overlays.count > wanted) {
		[overlays.lastObject removeFromSuperview];
		[overlays removeLastObject];
	}

	for (NSUInteger i = 0; i < wanted; i++) {
		UIImageView *target = photos[i];
		BeaMediaTapOverlay *overlay = (i < overlays.count) ? overlays[i] : nil;
		if (!overlay) {
			overlay = [[BeaMediaTapOverlay alloc] initWithFrame:CGRectZero];
			overlay.backgroundColor = [UIColor clearColor];
			overlay.userInteractionEnabled = YES;
			overlay.accessibilityIdentifier = @"BeaMediaTapOverlay";
			overlay.isAccessibilityElement = NO;

			UITapGestureRecognizer *tap =
				[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_overlayTapped:)];
			// Never swallow the touch. Panning the feed, the horizontal pager and
			// anything else BeReal drives from an ancestor recognizer has to keep
			// working through this view untouched - which it does, since a
			// recognizer on an ancestor still receives touches that land here.
			tap.cancelsTouchesInView = NO;
			tap.delaysTouchesBegan = NO;
			tap.delaysTouchesEnded = NO;
			tap.name = @"BeaMediaTap";
			[overlay addGestureRecognizer:tap];
			[overlays addObject:overlay];

			if (!BeaOverlayRegistry) BeaOverlayRegistry = [NSHashTable weakObjectsHashTable];
			[BeaOverlayRegistry addObject:overlay];
		}

		overlay.targetPhoto = target;
		// Positioned in the card's own coordinate space, so scrolling moves the
		// card and the overlay together with no per-frame work - unlike the
		// window-parented buttons, which is exactly why those have to be
		// re-placed every displayed frame.
		CGRect frameInCard = [target convertRect:target.bounds toView:card];
		if (!CGRectEqualToRect(overlay.frame, frameInCard)) overlay.frame = frameInCard;
		if (overlay.superview != card) [card addSubview:overlay];
	}

	// The last sibling wins the hit test, and the inset front-camera photo has
	// to win inside the main photo's rect - so both overlays go to the front in
	// the same largest-first order, leaving the smaller one on top.
	//
	// Only when the order is actually wrong, and at most twice a second even
	// then. -bringSubviewToFront: invalidates the card's layout, SwiftUI lays the
	// card out and re-appends its own views after ours, and the condition is true
	// again on the next pass: at ten times a second that is twenty forced layouts
	// of a feed card per second, for nothing. Half a second is far below the time
	// it takes to move a finger to a photo, and it is counted so a report can say
	// whether this is reconciling or fighting - see BeaDiagnostics.h.
	if (overlays.count > 0 && card.subviews.lastObject != overlays.lastObject) {
		CFTimeInterval now = CACurrentMediaTime();
		NSNumber *last = objc_getAssociatedObject(card, BeaMediaLastReorderKey);
		if (!last || now - last.doubleValue > 0.5) {
			objc_setAssociatedObject(card, BeaMediaLastReorderKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[BeaDiagnostics countOverlayReorder];
			for (BeaMediaTapOverlay *overlay in overlays) [card bringSubviewToFront:overlay];
		}
	}

	// The overlay is still the preferred path - when the descent does reach it,
	// nothing else is involved. The catcher is what makes the feature independent
	// of whether it does; see the header.
	[self installWindowCatcherOnWindow:card.window];

	[BeaDiagnostics recordMediaUnlockOverlays:(NSInteger)overlays.count
	                          gesturesOverlay:[self gesturesOverlayInContainer:card depth:0]
	                                mainPhoto:photo
	                               tapOverlay:overlays.firstObject];
}

// ---------------------------------------------------------------------------
// THE WINDOW CATCHER
// ---------------------------------------------------------------------------

+ (void)installWindowCatcherOnWindow:(UIWindow *)window {
	if (!window) return;
	if (objc_getAssociatedObject(window, BeaMediaWindowCatcherKey)) return;

	static BeaMediaWindowCatcherDelegate *delegate;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ delegate = [BeaMediaWindowCatcherDelegate new]; });

	UITapGestureRecognizer *tap =
		[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_windowTapped:)];
	// The same three flags the overlay's own recognizer carries, for the same
	// reason and with more at stake: this one sees touches over BeReal's whole
	// window, so it must never delay or swallow one.
	tap.cancelsTouchesInView = NO;
	tap.delaysTouchesBegan = NO;
	tap.delaysTouchesEnded = NO;
	tap.delegate = delegate;
	tap.name = @"BeaMediaWindowTap";
	[window addGestureRecognizer:tap];

	objc_setAssociatedObject(window, BeaMediaWindowCatcherKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	BeaWindowCatcherInstalled = YES;
	BeaLog("[BeaMedia] window tap catcher installed on %{public}@", NSStringFromClass([window class]));
}

// The smallest overlay whose rect contains the point, so the inset front-camera
// photo wins inside the main photo exactly as the sibling order gives it when
// hit testing does work.
+ (BeaMediaTapOverlay *)overlayForWindowPoint:(CGPoint)point inWindow:(UIWindow *)window {
	if (!window) return nil;

	BeaMediaTapOverlay *best = nil;
	CGFloat bestArea = CGFLOAT_MAX;
	for (BeaMediaTapOverlay *overlay in BeaOverlayRegistry) {
		if (overlay.window != window || overlay.hidden || !overlay.superview) continue;
		if (!overlay.targetPhoto) continue;
		CGRect rect = [overlay convertRect:overlay.bounds toView:window];
		if (!CGRectContainsPoint(rect, point)) continue;
		CGFloat area = rect.size.width * rect.size.height;
		if (area >= bestArea) continue;
		bestArea = area;
		best = overlay;
	}
	return best;
}

+ (void)bea_windowTapped:(UITapGestureRecognizer *)recognizer {
	UIWindow *window = (UIWindow *)recognizer.view;
	if (![window isKindOfClass:[UIWindow class]]) return;

	BeaMediaTapOverlay *overlay = [self overlayForWindowPoint:[recognizer locationInView:window] inWindow:window];
	if (!overlay) return;

	BeaWindowCatcherTapCount++;
	[self presentViewerForPhoto:overlay.targetPhoto inWindow:window];
}

+ (BOOL)windowCatcherInstalled { return BeaWindowCatcherInstalled; }
+ (NSUInteger)windowCatcherTapCount { return BeaWindowCatcherTapCount; }

// ---------------------------------------------------------------------------

+ (void)bea_overlayTapped:(UITapGestureRecognizer *)recognizer {
	BeaMediaTapOverlay *overlay = (BeaMediaTapOverlay *)recognizer.view;
	if (![overlay isKindOfClass:[BeaMediaTapOverlay class]]) return;
	[self presentViewerForPhoto:overlay.targetPhoto inWindow:overlay.window];
}

// The one place either tap path ends up, so the two of them cannot open two
// viewers for one finger: whichever recognizer fires first takes the tap, and
// the other sees the timestamp and returns. Both are wanted - the overlay's own
// recognizer is the correct path wherever hit testing actually reaches it, and
// the catcher is the one that does not depend on that.
+ (void)presentViewerForPhoto:(UIImageView *)tapped inWindow:(UIWindow *)window {
	if (!tapped || !window) return;

	CFTimeInterval now = CACurrentMediaTime();
	if (now - BeaLastViewerPresentation < 0.4) return;
	BeaLastViewerPresentation = now;

	// Re-derived from the view tree at tap time rather than captured when the
	// overlay was installed. BeReal recycles its image views between posts, so
	// anything captured at install time can be describing a different post by
	// the time the tap arrives - the same trap KNOWN_ISSUES.md bug #1 records
	// for the download button's search root.
	UIView *container = [BeaDownloader localContainerForAnchor:tapped upToRoot:window];
	NSArray<UIImageView *> *photos = [BeaDownloader qualifyingImageViewsInView:container ?: tapped];

	NSMutableArray<UIImage *> *images = [NSMutableArray array];
	NSUInteger startIndex = 0;
	for (UIImageView *photo in photos) {
		if (!photo.image) continue;
		if (photo == tapped) startIndex = images.count;
		[images addObject:photo.image];
	}
	// The tapped photo itself, when the container walk found nothing usable -
	// degrading to "opens the one photo you touched" rather than to nothing.
	if (images.count == 0 && tapped.image) [images addObject:tapped.image];

	BeaLog("[BeaMedia] tap on gated photo -> viewer with %{public}lu image(s)", (unsigned long)images.count);
	[BeaMediaViewer presentImages:images startIndex:startIndex fromWindow:window];
}

// Both teardown paths, in one place, against both candidate container views -
// see the note at the call site for why "both" rather than "the right one".
+ (void)tearDownPost:(UIView *)container card:(UIView *)card photos:(NSArray<UIImageView *> *)photos {
	[self detachFromPhotos:photos];
	[self removeOverlaysFromCard:container];
	[self restoreGatedGesturesOverlayIn:container depth:0];
	if (card && card != container) {
		[self removeOverlaysFromCard:card];
		[self restoreGatedGesturesOverlayIn:card depth:0];
	}
}

+ (void)detachFromPhotos:(NSArray<UIImageView *> *)photos {
	for (UIImageView *photo in photos) {
		UIGestureRecognizer *tap = objc_getAssociatedObject(photo, BeaMediaTapKey);
		if (!tap) continue;
		[photo removeGestureRecognizer:tap];
		objc_setAssociatedObject(photo, BeaMediaTapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

+ (void)removeOverlaysFromCard:(UIView *)card {
	NSMutableArray<BeaMediaTapOverlay *> *overlays = objc_getAssociatedObject(card, BeaMediaOverlaysKey);
	if (!overlays) return;
	for (BeaMediaTapOverlay *overlay in overlays) [overlay removeFromSuperview];
	objc_setAssociatedObject(card, BeaMediaOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Finds BeReal's gesture-catching overlay within a gated post's own card and
// holds its `userInteractionEnabled` at NO. Guarded by BeaMediaGesturesHeldKey
// so a view already held disabled by an earlier pass isn't recorded again with
// its (already-disabled, by us) current value as if that were the original -
// which would make every future restore a no-op and would grow BeaMediaEdits
// without bound for a post that sits on screen for a while.
+ (void)holdGesturesOverlayDisabledInContainer:(UIView *)container depth:(NSInteger)depth {
	if (!container || depth > 12) return;

	if ([NSStringFromClass([container class]) containsString:BeaMediaGesturesClassNameFragment]) {
		if (!objc_getAssociatedObject(container, BeaMediaGesturesHeldKey)) {
			BeaRecordInteractionEnabled(container);
			objc_setAssociatedObject(container, BeaMediaGesturesHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		container.userInteractionEnabled = NO;
		return;
	}

	for (UIView *subview in container.subviews) {
		[self holdGesturesOverlayDisabledInContainer:subview depth:depth + 1];
	}
}

// The other half of the pair above: once a post is no longer gated (or this
// feature is off), stop overriding the gestures overlay and let whatever
// already force-enables interaction on it for every post (again,
// BeaCollectVisiblePosts) be the only thing touching it from here on.
+ (void)restoreGatedGesturesOverlayIn:(UIView *)container depth:(NSInteger)depth {
	if (!container || depth > 12) return;

	if ([NSStringFromClass([container class]) containsString:BeaMediaGesturesClassNameFragment]) {
		if (objc_getAssociatedObject(container, BeaMediaGesturesHeldKey)) {
			objc_setAssociatedObject(container, BeaMediaGesturesHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			container.userInteractionEnabled = YES;
		}
		return;
	}

	for (UIView *subview in container.subviews) {
		[self restoreGatedGesturesOverlayIn:subview depth:depth + 1];
	}
}

// Read-only lookup for the diagnostics report, which is the only way a device
// can answer "is BeReal's gesture view still the thing receiving these taps?"
// without another guess-and-flash round.
+ (UIView *)gesturesOverlayInContainer:(UIView *)container depth:(NSInteger)depth {
	if (!container || depth > 12) return nil;
	if ([NSStringFromClass([container class]) containsString:BeaMediaGesturesClassNameFragment]) return container;
	for (UIView *subview in container.subviews) {
		UIView *found = [self gesturesOverlayInContainer:subview depth:depth + 1];
		if (found) return found;
	}
	return nil;
}

+ (void)restoreAll {
	for (BeaMediaEdit *edit in BeaMediaEdits) {
		UIView *view = edit.view;
		if (!view) continue;
		view.userInteractionEnabled = edit.originalValue;
		// Clears the "currently held disabled by us" marker too - a global
		// toggle-off is a restore just as much as a single post ungating is, and
		// skipping this left the marker stale on the view, so the next gated post
		// to reuse it would silently stop recording (and therefore stop being
		// able to correctly restore) its own interaction state.
		objc_setAssociatedObject(view, BeaMediaGesturesHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	BeaLog("[BeaMedia] restored %{public}lu media edit(s)", (unsigned long)BeaMediaEdits.count);
	[BeaMediaEdits removeAllObjects];
	BeaWindowCatcherInstalled = NO;

	// The overlays are held only by the cards they were added to, so they have
	// to be found the same way. Walking every window is the only way to reach a
	// post the reconcile pass will not visit again - one that has scrolled away
	// keeps its overlay otherwise.
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			[self removeOverlaysInView:window depth:0];
			[self removeAddedRecognizersInView:window depth:0];

			// The catcher is on the window itself, not on anything inside a post,
			// so nothing above reaches it. Removed rather than left inert: the
			// switch has to undo what it did, and a recognizer of ours on BeReal's
			// window is exactly the kind of state a suspend is meant to drop.
			UIGestureRecognizer *catcher = objc_getAssociatedObject(window, BeaMediaWindowCatcherKey);
			if (catcher) {
				[window removeGestureRecognizer:catcher];
				objc_setAssociatedObject(window, BeaMediaWindowCatcherKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
		}
	}
}

+ (void)removeOverlaysInView:(UIView *)view depth:(NSInteger)depth {
	if (!view || depth > 24) return;

	// The association is cleared as well as the views removed, so a card that
	// comes back on screen builds a fresh set rather than reusing an array of
	// orphans - which is what would otherwise leave a suspend/resume cycle with
	// no tap target at all.
	if (objc_getAssociatedObject(view, BeaMediaOverlaysKey)) [self removeOverlaysFromCard:view];

	for (UIView *subview in [view.subviews copy]) {
		if ([subview isKindOfClass:[BeaMediaTapOverlay class]]) {
			[subview removeFromSuperview];
			continue;
		}
		[self removeOverlaysInView:subview depth:depth + 1];
	}
}

+ (void)removeAddedRecognizersInView:(UIView *)view depth:(NSInteger)depth {
	if (!view || depth > 24) return;

	UIGestureRecognizer *tap = objc_getAssociatedObject(view, BeaMediaTapKey);
	if (tap) {
		[view removeGestureRecognizer:tap];
		objc_setAssociatedObject(view, BeaMediaTapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	for (UIView *subview in view.subviews) {
		[self removeAddedRecognizersInView:subview depth:depth + 1];
	}
}

@end
