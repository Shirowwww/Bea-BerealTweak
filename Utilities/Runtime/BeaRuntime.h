#import <UIKit/UIKit.h>

// ============================================================================
// THE MASTER RUNTIME SWITCH
// ============================================================================
// Hold three fingers anywhere for ~2s and every visible or behavioural part of
// this tweak stops. Hold again and it all comes back exactly as it was.
//
// WHY THIS IS ONE FLAG AND NOT A CHECK PER FEATURE. Every previous "turn it
// off" mechanism in this codebase is a per-behaviour switch that its owner
// reads where the behaviour happens, and the recurring bug is that some owner
// forgets one path (see BeaSettings' own header: three ad switches were
// one-way doors because they were read at install time rather than at answer
// time). A master override that is checked in a dozen new places would
// reproduce that failure exactly. Instead this suspends the *switches*:
// +[BeaSettings effectiveBoolForKey:] answers NO for every suspendable key
// while this is on, and suspension then posts the ordinary
// BeaSettingsDidChangeNotification for each of those keys - so every undo path
// that already exists for "the user turned this switch off" runs, unchanged,
// with no new code to forget.
//
// It is deliberately NOT persisted. It is an emergency override for showing
// someone the phone, not a preference, and a tweak that came back up suspended
// after a relaunch with no visible indicator would be indistinguishable from a
// broken install. No NSUserDefaults value is read, written or destroyed by any
// of this - the user's own configuration is untouched and is what comes back.
//
// WHAT IS DELIBERATELY NOT SUSPENDED: the jailbreak/environment-detection
// bypass in Tweak.x and SideloadFix. Those are what let a sideloaded BeReal
// run at all; switching them off mid-session would not "restore native
// behaviour", it would get the user logged out. They also change nothing the
// user or BeReal's UI can see.
FOUNDATION_EXPORT NSString *const BeaRuntimeSuspensionDidChangeNotification;

@interface BeaRuntime : NSObject

+ (BOOL)isSuspended;
+ (void)setSuspended:(BOOL)suspended;
+ (void)toggleSuspended;

// The three-finger hold. Idempotent - safe to call from every layout pass, the
// same way the settings screen's two-finger fallback is installed.
+ (void)installSuspendGestureOnWindow:(UIWindow *)window;

@end
