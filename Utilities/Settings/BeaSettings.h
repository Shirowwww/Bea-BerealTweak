#import <UIKit/UIKit.h>

// ============================================================================
// USER-FACING SETTINGS
// ============================================================================
// Every behaviour in this tweak that has ever needed a second device-testing
// round is now a switch. That is not a feature request - it is the direct
// consequence of how this codebase fails: silently. When the ad collapse takes
// something it shouldn't, or the gating strip hides the wrong view, the only
// recovery a sideloaded user has today is to wait for another IPA. A switch
// turns that into a five-second fix and, just as importantly, turns a bug
// report into a bisection ("turn each one off until it stops").
//
// Backed by NSUserDefaults in BeReal's own domain. Every key is registered
// with an explicit default in +load, so -boolForKey: on a fresh install
// answers the intended value rather than NO.
FOUNDATION_EXPORT NSString *const BeaSettingBlockAdNetworkRequests;   // restart required
FOUNDATION_EXPORT NSString *const BeaSettingRemoveAdViews;
FOUNDATION_EXPORT NSString *const BeaSettingRemoveSponsoredCards;
FOUNDATION_EXPORT NSString *const BeaSettingWidenFromAdMedia;
FOUNDATION_EXPORT NSString *const BeaSettingHideGatingOverlay;
FOUNDATION_EXPORT NSString *const BeaSettingKeepGatingCTA;
FOUNDATION_EXPORT NSString *const BeaSettingUnlockMediaInteractions;
FOUNDATION_EXPORT NSString *const BeaSettingShowDownloadButton;
FOUNDATION_EXPORT NSString *const BeaSettingShowUploadButton;
FOUNDATION_EXPORT NSString *const BeaSettingHideButtonsWhileScrolling;
FOUNDATION_EXPORT NSString *const BeaSettingLoadAccessibilityBundles; // restart required
FOUNDATION_EXPORT NSString *const BeaSettingDebugLogging;

// Posted (on the main thread) whenever +setBool:forKey: actually changes a
// value. `object` is the key that changed.
//
// Every switch here used to be read only where the behaviour it gates happens
// to run next, which made most of them one-way doors: turning "remove ad
// views" off changed nothing until the app was relaunched, because the views
// were already gone and the hook that removes them only fires on insertion.
// A switch that cannot be un-flipped is worse than no switch at all - it turns
// "turn it off and tell me what changes" into "reinstall".
FOUNDATION_EXPORT NSString *const BeaSettingsDidChangeNotification;

@interface BeaSettings : NSObject
+ (BOOL)boolForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

// Best-effort: makes SwiftUI publish its accessibility tree in a process with
// no assistive technology attached.
//
// This is the missing piece behind "the gating overlay hider still does
// nothing on a real device". SwiftUI draws Text into one drawing view and
// publishes the string only as UIAccessibilityElement objects - but the code
// that vends those lives in /System/Library/AccessibilityBundles/*.axbundle,
// which UIKit only loads when an accessibility client (VoiceOver, the
// Accessibility Inspector, an XCUITest runner) attaches. With no client, a
// scan of -accessibilityElements finds nothing at all, whatever the needles
// say. Apple's own developer forums have the same observation from the other
// side ("AX Elements in some apps only exposed when using VoiceOver or
// Accessibility Inspector", thread 756895).
//
// dlopen'ing those bundles installs the same categories UIKit would have
// installed itself. It is deliberately a switch: it is the one change here
// that alters UIKit's own behaviour rather than the tweak's, so it has to be
// possible to rule out from the device.
+ (void)loadAccessibilityBundlesIfEnabled;
// Whether the bundles are actually loaded right now - reported on the
// diagnostics screen, since "the scan found nothing" and "the scan could
// never have found anything" look identical from the outside.
+ (BOOL)accessibilityBundlesLoaded;
@end
