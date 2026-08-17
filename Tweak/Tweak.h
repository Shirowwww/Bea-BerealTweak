#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "fishhook/fishhook.h"
#import "Utilities/Button/BeaButton.h"
#import "BeFake/TokenManager/BeaTokenManager.h"
#import "BeFake/ViewControllers/UploadViewController/BeaUploadViewController.h"

NSDictionary *headers;

@interface AdvertsDataNativeViewContainer : UIView
@end

@interface PAGDeviceHelper : NSObject
+ (BOOL)bu_isJailBroken;
@end

@interface STKDevice : NSObject
+ (BOOL)containsJailbrokenFiles;
+ (BOOL)containsJailbrokenPermissions;
+ (BOOL)isJailbroken;
@end

@interface CAFilter : NSObject
@property (copy) NSString *name;
@end