#import "BeaMediaUnlock.h"
#import "BeaMediaViewer.h"
#import "../Debug/BeaDebug.h"
#import "../Downloader/BeaDownloader.h"
#import "../Settings/BeaSettings.h"
#import <objc/runtime.h>

// BeReal's own gesture host over a post's photo. Matched as a substring, not
// against this exact mangled spelling: the repo has already been bitten twice
// by an exact class-name compare that silently stopped matching after a rename
// (see AGENTS.md on HomeViewHostingController and BlurStateUseCaseImpl). The
// bare type name survives a module move and a re-parameterization.
static NSString *const BeaMediaGesturesClassNameFragment = @"MainMediaGesturesView";

// The tap recognizer this class owns, hung off the photo it was added to, so a
// reconcile pass can tell "already unlocked" from "needs unlocking" and can
// take its own recognizer back off without touching BeReal's.
static const void *BeaMediaTapKey = &BeaMediaTapKey;

// ---------------------------------------------------------------------------
// UNDO
// ---------------------------------------------------------------------------
// Same rule as everywhere else in this tweak: whoever changes one of BeReal's
// own views records what it replaced, or the switch is a one-way door.
@interface BeaMediaEdit : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) UIGestureRecognizer *recognizer;
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

static void BeaRecordRecognizerEnabled(UIGestureRecognizer *recognizer) {
	if (!BeaMediaEdits) BeaMediaEdits = [NSMutableArray array];
	BeaMediaEdit *edit = [BeaMediaEdit new];
	edit.recognizer = recognizer;
	edit.originalValue = recognizer.isEnabled;
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
+ (void)enableBeRealGesturesInContainer:(UIView *)container depth:(NSInteger)depth;
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
		// never needed it.
		[self detachFromPhotos:photos];
		return;
	}

	// Layer 1: BeReal's own gestures, put back where the gate turned them off.
	// Hit testing stops descending as soon as it meets a view with interaction
	// disabled, so the ancestors have to come first or nothing below them ever
	// sees a touch - ours included.
	if (root) [BeaDownloader enableUserInteractionFromView:container upToRoot:root];
	[self enableBeRealGesturesInContainer:container depth:0];

	// Layer 2: our own tap, on both photos. Two is the whole post - anything
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

// Re-enables the post's own RealComponents.UIMainMediaGesturesView and every
// recognizer on it. Recorded both ways, so the switch puts the gate back
// exactly as it found it.
+ (void)enableBeRealGesturesInContainer:(UIView *)container depth:(NSInteger)depth {
	if (!container || depth > 12) return;

	if ([NSStringFromClass([container class]) containsString:BeaMediaGesturesClassNameFragment]) {
		if (!container.userInteractionEnabled) {
			BeaRecordInteractionEnabled(container);
			container.userInteractionEnabled = YES;
		}
		for (UIGestureRecognizer *recognizer in container.gestureRecognizers) {
			if (recognizer.isEnabled) continue;
			BeaRecordRecognizerEnabled(recognizer);
			recognizer.enabled = YES;
			BeaLog("[BeaMedia] re-enabled BeReal gesture %{public}@", NSStringFromClass([recognizer class]));
		}
		return;
	}

	for (UIView *subview in container.subviews) {
		[self enableBeRealGesturesInContainer:subview depth:depth + 1];
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
		if (view) {
			view.userInteractionEnabled = edit.originalValue;
			continue;
		}
		UIGestureRecognizer *recognizer = edit.recognizer;
		if (recognizer) recognizer.enabled = edit.originalValue;
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
