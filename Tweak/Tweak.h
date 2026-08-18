#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "fishhook/fishhook.h"
#import "Utilities/Button/BeaButton.h"
#import "BeFake/TokenManager/BeaTokenManager.h"
#import "BeFake/ViewControllers/UploadViewController/BeaUploadViewController.h"
#import "Utilities/Ads/BeaAdBlocker.h"

// Single source of truth for the tweak's own version string - also guards
// BeaInfoViewController.h's copy (via #ifndef there) so the two never
// silently drift apart. Bump this alongside control's Version field.
#define TWEAK_VERSION @"0.6.0-merged"

NSDictionary *headers;

// BeReal's own advert wrappers, all in its AdvertsData module. Bound to their
// real (mangled Swift) classes in %ctor, so each hook no-ops safely on a build
// where that class doesn't exist. These three are the ones that actually reach
// the feed; everything else in the ad stack - including all ~18 embedded
// vendor SDKs - is caught generically by the %hook UIView pair in Tweak.x,
// which routes through BeaAdBlocker rather than needing a named class here.
@interface AdvertsDataNativeViewContainer : UIView
@end

@interface AdvertsDataAppLovinMRECView : UIView
@end

@interface AdvertsDataAppLovinNativeView : UIView
@end

// ============================================
// JAILBREAK / ENVIRONMENT DETECTION CLASSES
// ============================================
// Nikolozi's original two classes (PAGDeviceHelper, STKDevice) plus the
// wider SDK coverage tqmane added for BeReal 4.58+ (Shake, Adjust, Google
// Ads, Meta Ads) and BeReal's own new JailbreakCheck class. Deliberately
// does NOT bring back tqmane's earlier C-level access()/stat()/fopen()/
// getenv() hooks - those were removed upstream (see Tweak.x) because they
// crashed in jailed/sideloaded environments; only the plain ObjC hooks below
// are considered safe enough to keep.

@interface PAGDeviceHelper : NSObject
+ (BOOL)bu_isJailBroken;
+ (BOOL)isJailBroken;
@end

@interface STKDevice : NSObject
+ (BOOL)containsJailbrokenFiles;
+ (BOOL)containsJailbrokenPermissions;
+ (BOOL)isJailbroken;
+ (BOOL)isDebug;
@end

// Shake SDK
@interface SHKDeviceInfo : NSObject
+ (BOOL)isJailbroken;
- (BOOL)isJailbroken;
@end

// Adjust SDK
@interface ADJDeviceInfo : NSObject
- (BOOL)isJailBroken;
+ (BOOL)isJailBroken;
@end

// Google Ads SDK
@interface GADDeviceInfo : NSObject
- (BOOL)isJailbroken;
@end

// Meta Audience Network SDK
@interface FBAdUtility : NSObject
+ (BOOL)isJailbroken;
@end

// BeReal's own jailbreak-check class, new in 4.58.0
@interface BeaJailbreakCheck : NSObject
- (BOOL)isJailbroken;
+ (BOOL)isJailbroken;
- (BOOL)check;
+ (BOOL)check;
- (BOOL)isJailbreak;
+ (BOOL)isJailbreak;
@end

@interface HomeViewController : UIViewController
@property (nonatomic, retain) UIImageView *ibNavBarLogoImageView;
- (void)showVersionAlert;
@end

@interface CAFilter : NSObject
@property (copy) NSString *name;
@end

@interface MediaView : UIView
@property (nonatomic, strong) BeaButton *downloadButton;
@end

// ============================================
// BLUR STATE CLASSES (BeReal 4.58.0)
// ============================================
// Complementary to the CAFilter fallback hook below - BeReal 4.58 introduced
// a dedicated blur-state layer that CAFilter's gaussianBlur-radius override
// doesn't touch at all. Both classes are resolved dynamically at %ctor time
// and no-op safely if absent on older BeReal versions (see Tweak.x).

@interface BlurStateUseCaseImpl : NSObject
- (BOOL)isBlurred;
- (BOOL)isBlurredState;
- (id)blurState;
@end

@interface NewDoubleMediaViewModel : NSObject
- (BOOL)isBlurred;
- (BOOL)blurred;
@end
