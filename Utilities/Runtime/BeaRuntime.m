#import "BeaRuntime.h"
#import "../Debug/BeaDebug.h"
#import "../Settings/BeaSettings.h"

NSString *const BeaRuntimeSuspensionDidChangeNotification = @"BeaRuntimeSuspensionDidChange";

static BOOL BeaSuspended = NO;

// ~2s, three fingers. Long enough that it cannot be reached by accident while
// pinching or two-finger scrolling, short enough to be usable one-handed-ish
// when someone is about to look at the screen.
static NSString *const BeaSuspendGestureName = @"BeaSuspendHold";

@implementation BeaRuntime

+ (BOOL)isSuspended {
	return BeaSuspended;
}

+ (void)toggleSuspended {
	[self setSuspended:!BeaSuspended];
}

+ (void)setSuspended:(BOOL)suspended {
	if (BeaSuspended == suspended) return;
	BeaSuspended = suspended;

	// Anything of ours that is currently on screen goes first, before the
	// per-key notifications rebuild or tear down the injected views underneath
	// it. Matched by class prefix rather than by an enumerated list of
	// classes: every screen this tweak can present is named Bea*, and a list
	// is one more thing to forget to add to.
	if (suspended) [self dismissTweakScreens];

	// The whole mechanism. Every observer that already knows how to undo one
	// switch runs here exactly as if the user had flipped it in the settings
	// screen - BeaAdBlocker's three categories, BeaMediaUnlock's restore,
	// BeaDownloader's gating undo, and the button teardown in Tweak.x - and
	// none of them needs to know this flag exists.
	//
	// Posted for the same key set in both directions, so resuming re-applies
	// whatever the user's own switches say rather than turning everything on.
	for (NSString *key in [BeaSettings suspendableKeys]) {
		[[NSNotificationCenter defaultCenter] postNotificationName:BeaSettingsDidChangeNotification
		                                                    object:key];
	}

	[[NSNotificationCenter defaultCenter] postNotificationName:BeaRuntimeSuspensionDidChangeNotification
	                                                    object:@(suspended)];

	// The only confirmation there is, on purpose: a visible indicator would
	// defeat the point of the gesture.
	UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
		initWithStyle:suspended ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleLight];
	[haptic prepare];
	[haptic impactOccurred];

	BeaLog("[BeaRuntime] tweak %{public}s", suspended ? "SUSPENDED" : "resumed");
}

// Everything this tweak can have presented over the app. Walks the whole
// presentation chain of every window rather than only the top-most one, since
// the settings screen can itself have an action sheet or the diagnostics
// summary on top of it.
+ (void)dismissTweakScreens {
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			UIViewController *outermostOurs = nil;
			for (UIViewController *walk = window.rootViewController; walk; walk = walk.presentedViewController) {
				if (walk == window.rootViewController) continue;
				if (![NSStringFromClass([walk class]) hasPrefix:@"Bea"]) continue;
				outermostOurs = walk;
				break;
			}
			// Dismissing the outermost one takes everything presented on top of
			// it with it, which is what makes this safe to do in one step.
			[outermostOurs dismissViewControllerAnimated:NO completion:nil];
		}
	}
}

+ (void)installSuspendGestureOnWindow:(UIWindow *)window {
	if (!window) return;
	for (UIGestureRecognizer *existing in window.gestureRecognizers) {
		if ([existing.name isEqualToString:BeaSuspendGestureName]) return;
	}

	UILongPressGestureRecognizer *recognizer =
		[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(bea_suspendHeld:)];
	recognizer.numberOfTouchesRequired = 3;
	recognizer.minimumPressDuration = 2.0;
	recognizer.name = BeaSuspendGestureName;
	// Never swallow a touch BeReal wanted - the same rule the settings screen's
	// two-finger fallback follows, and doubly important here because this one
	// has to keep working while the tweak is suspended, i.e. while the app is
	// meant to behave exactly as if MiniBea were not installed.
	recognizer.cancelsTouchesInView = NO;
	recognizer.delaysTouchesBegan = NO;
	recognizer.delaysTouchesEnded = NO;
	[window addGestureRecognizer:recognizer];
}

+ (void)bea_suspendHeld:(UILongPressGestureRecognizer *)recognizer {
	if (recognizer.state != UIGestureRecognizerStateBegan) return;
	[self toggleSuspended];
}

@end
