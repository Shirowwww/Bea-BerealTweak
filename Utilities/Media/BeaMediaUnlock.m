#import "BeaMediaUnlock.h"
#import "BeaMediaViewer.h"
#import "../Debug/BeaDebug.h"
#import "../Downloader/BeaDownloader.h"
#import "../Settings/BeaSettings.h"
#import <objc/runtime.h>

// The tap recognizer this class owns, hung off the photo it was added to, so a
// reconcile pass can tell "already unlocked" from "needs unlocking" and can
// take its own recognizer back off without touching BeReal's.
static const void *BeaMediaTapKey = &BeaMediaTapKey;

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

// A tap on a photo has to coexist with whatever BeReal has on the same photo,
// never replace it. Recognizing simultaneously (rather than requiring BeReal's
// to fail) is the deliberate choice: on a gated post BeReal's own tap handler
// may well recognize and then do nothing, and a failure requirement would make
// this feature silently dead in exactly the case it exists for. Both run; if
// BeReal does swap the photos in the feed, the viewer opens over the same two
// photos anyway.
@interface BeaMediaGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation BeaMediaGestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
	return YES;
}

@end

static BeaMediaGestureDelegate *BeaSharedGestureDelegate(void) {
	static BeaMediaGestureDelegate *shared;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ shared = [BeaMediaGestureDelegate new]; });
	return shared;
}

@interface BeaMediaUnlock ()
+ (void)detachFromPhotos:(NSArray<UIImageView *> *)photos;
+ (void)holdGesturesOverlayDisabledInContainer:(UIView *)container depth:(NSInteger)depth;
+ (void)restoreGatedGesturesOverlayIn:(UIView *)container depth:(NSInteger)depth;
+ (void)removeAddedRecognizersInView:(UIView *)view depth:(NSInteger)depth;
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
		if (![BeaSettings boolForKey:BeaSettingUnlockMediaInteractions]) [self restoreAll];
	}];
}

+ (void)syncPostWithContainer:(UIView *)container
                    mainPhoto:(UIImageView *)photo
                         root:(UIView *)root {
	if (!container || !photo) return;

	NSArray<UIImageView *> *photos = [BeaDownloader qualifyingImageViewsInView:container];
	if (photos.count == 0) return;

	if (![BeaSettings boolForKey:BeaSettingUnlockMediaInteractions]) {
		[self detachFromPhotos:photos];
		[self restoreGatedGesturesOverlayIn:container depth:0];
		return;
	}

	// Gated on the same evidence the overlay hider acts on, and no other. A
	// post the user can already open is a post BeReal's own gestures already
	// handle - adding a second tap handler there would be interference, not a
	// feature.
	UIView *card = [BeaDownloader gatingCardForPhoto:photo images:photos];
	if (!card || ![BeaDownloader photoIsGated:photo inCard:card]) {
		// Not (or no longer) gated. BeReal recycles these image views between
		// posts, so a recognizer left on one would follow it onto a post that
		// never needed it - and the gestures overlay this class may have been
		// holding disabled for it has to go back to however BeReal wants it for
		// an unlocked post (normally interactive, so its own tap-to-swap etc.
		// keep working).
		[self detachFromPhotos:photos];
		[self restoreGatedGesturesOverlayIn:container depth:0];
		return;
	}

	// Ancestors first, still needed: hit testing stops descending as soon as it
	// meets a view with interaction disabled, and our own tap (added below) is
	// on the photo itself, several levels under `container`.
	if (root) [BeaDownloader enableUserInteractionFromView:container upToRoot:root];

	// The gesture-catching overlay BeReal draws over every post's media has to
	// be kept OUT of the way, not put back. A device hierarchy dump shows it as
	// a sibling sitting directly on top of the photo, at the identical frame
	// (AnimatedImageViewWrapper, then MainMediaGesturesView, same rect - the
	// later sibling wins hit-testing and becomes the exclusive recipient of any
	// touch there, regardless of which of its own recognizers are enabled: a
	// gesture recognizer only ever sees a touch that was delivered to the view
	// it's attached to, or one of that view's *ancestors* - never a sibling, so
	// a tap recognizer added to the photo underneath can never fire while this
	// overlay is still hit-testable, whatever state its recognizers are in.
	//
	// An earlier version of this tried "layer 1": re-enabling that overlay's
	// own disabled recognizers, believing the strip was a photo-swap gesture.
	// On device it wasn't - it was (or included) whatever BeReal binds to "tap
	// this view on a gated post", which turned out to be the post/camera flow:
	// tapping opened the composer instead of this viewer. There is also a
	// second, independent reason the overlay must be handled explicitly here
	// rather than left alone: BeaCollectVisiblePosts in Tweak.x already calls
	// -enableUserInteractionRecursivelyInView: on every visible post's whole
	// subtree (needed so the download button's hit-testing isn't blocked by an
	// unrelated disabled SwiftUI wrapper), and that call does not know or care
	// about gating - it turns this exact overlay's own interaction back on for
	// every post, gated or not, on every pass, just before this method runs.
	// Simply "not re-enabling" it is therefore not enough on its own: it has to
	// be explicitly held disabled here, every pass, for as long as the post is
	// gated and this feature is on - which is the narrowest form of "explicitly
	// disable only the gated tap target" available, since it touches exactly
	// one view, only inside this one gated post's own card, only while the
	// switch is on, and is fully undone (see -restoreGatedGesturesOverlayIn:)
	// the moment either stops being true.
	[self holdGesturesOverlayDisabledInContainer:container depth:0];

	// Our own tap, on both photos. Two is the whole post - anything
	// beyond that is a neighbouring card the container walk picked up.
	NSUInteger limit = MIN(photos.count, (NSUInteger)2);
	for (NSUInteger i = 0; i < limit; i++) {
		UIImageView *target = photos[i];
		if (objc_getAssociatedObject(target, BeaMediaTapKey)) continue;

		if (!target.userInteractionEnabled) {
			BeaRecordInteractionEnabled(target);
			target.userInteractionEnabled = YES;
		}

		UITapGestureRecognizer *tap =
			[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bea_photoTapped:)];
		// Never swallow the touch. BeReal's own handling of this tap, whatever
		// it turns out to be, has to keep working untouched.
		tap.cancelsTouchesInView = NO;
		tap.delaysTouchesBegan = NO;
		tap.delaysTouchesEnded = NO;
		tap.delegate = BeaSharedGestureDelegate();
		tap.name = @"BeaMediaTap";
		[target addGestureRecognizer:tap];
		objc_setAssociatedObject(target, BeaMediaTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		BeaLog("[BeaMedia] unlocked %{public}@ on a gated post", NSStringFromClass([target class]));
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

// Finds BeReal's gesture-catching overlay within a gated post's own card and
// holds its `userInteractionEnabled` at NO, so hit-testing skips it and falls
// through to the photo underneath - where the tap added above actually lives.
// Re-asserted every reconcile pass: BeaCollectVisiblePosts in Tweak.x already
// force-enables interaction on this exact view (and everything else in the
// post) for an unrelated reason, on every pass, just before this method runs -
// see the comment at the call site.
//
// Guarded by BeaMediaGesturesHeldKey so a view already held disabled by an
// earlier pass isn't recorded again with its (already-disabled, by us) current
// value as if that were the original - which would make every future restore
// a no-op and would grow BeaMediaEdits without bound for a post that sits on
// screen for a while.
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

+ (void)bea_photoTapped:(UITapGestureRecognizer *)recognizer {
	UIView *tapped = recognizer.view;
	UIWindow *window = tapped.window;
	if (!window) return;

	// Re-derived from the view tree at tap time rather than captured when the
	// recognizer was installed. BeReal recycles its image views between posts,
	// so anything captured at install time can be describing a different post
	// by the time the tap arrives - the same trap KNOWN_ISSUES.md bug #1
	// records for the download button's search root.
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
	if (images.count == 0 && [tapped isKindOfClass:[UIImageView class]]) {
		UIImage *image = ((UIImageView *)tapped).image;
		if (image) [images addObject:image];
	}

	[BeaMediaViewer presentImages:images startIndex:startIndex fromWindow:window];
}

+ (void)restoreAll {
	for (BeaMediaEdit *edit in BeaMediaEdits) {
		UIView *view = edit.view;
		if (!view) continue;
		view.userInteractionEnabled = edit.originalValue;
		// Clears the "currently held disabled by us" marker too, if this was a
		// gestures overlay - a global toggle-off is a restore just as much as a
		// single post ungating is, and skipping this here left the marker stale
		// on the view, so the next gated post to reuse it would silently stop
		// recording (and therefore stop being able to correctly restore) its own
		// interaction state.
		objc_setAssociatedObject(view, BeaMediaGesturesHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	BeaLog("[BeaMedia] restored %{public}lu media edit(s)", (unsigned long)BeaMediaEdits.count);
	[BeaMediaEdits removeAllObjects];

	// The recognizers this class added are held only by the photos they are on,
	// so they have to be found the same way. Walking every window is the only
	// way to reach photos the reconcile pass will not visit again - a post that
	// has scrolled away keeps its recognizer otherwise.
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			[self removeAddedRecognizersInView:window depth:0];
		}
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
