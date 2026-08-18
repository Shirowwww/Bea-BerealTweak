#import "SideloadFix.h"

// All credits go to https://github.com/level3tjg/RedditSideloadFix and https://github.com/opa334/IGSideloadFix

%hook NSBundle

- (NSString *)bundleIdentifier {
  NSArray *address = [NSThread callStackReturnAddresses];
  if (address.count <= 2) return %orig;
  Dl_info info;
  if (dladdr((void *)[address[2] longLongValue], &info) == 0) return %orig;
  NSString *path = [NSString stringWithUTF8String:info.dli_fname];
  if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) return BR_BUNDLE_ID;
  return %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
  if ([key isEqualToString:@"CFBundleIdentifier"]) return BR_BUNDLE_ID;
  if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return BR_NAME;
  return %orig;
}

%end


NSString* keychainAccessGroup;
NSURL* fakeGroupContainerURL;

void createDirectoryIfNotExists(NSURL* URL) {
  if (![URL checkResourceIsReachableAndReturnError:nil]) {
    [[NSFileManager defaultManager] createDirectoryAtURL:URL withIntermediateDirectories:YES attributes:nil error:nil];
  }
}

@implementation NSFileManager (SideloadedFixes)

- (NSURL*)swizzled_containerURLForSecurityApplicationGroupIdentifier:(NSString*)groupIdentifier {
  NSURL* fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];

  createDirectoryIfNotExists(fakeURL);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library"]);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library/Caches"]);

  return fakeURL;
}

@end

// Thanks to level3tjg! https://github.com/level3tjg/TwitchAdBlock/blob/master/Sideloaded.x


static void loadKeychainAccessGroup() {
  NSDictionary* dummyItem = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrAccount : @"dummyItem",
    (__bridge id)kSecAttrService : @"dummyService",
    (__bridge id)kSecReturnAttributes : @YES,
  };

  CFTypeRef result = NULL;
  OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
  if (ret == -25300) {
    ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);
  }

  if (ret == 0 && result) {
    // __bridge_transfer, not __bridge: SecItemCopyMatching/SecItemAdd follow
    // the Core Foundation "Copy"/"Create" ownership rule - this result is
    // ours to release, and handing it to ARC via __bridge_transfer does
    // that instead of leaking it.
    NSDictionary* resultDict = (__bridge_transfer id)result;
    keychainAccessGroup = resultDict[(__bridge id)kSecAttrAccessGroup];
    NSLog(@"loaded keychainAccessGroup: %@", keychainAccessGroup);
  }
}

// All four hooks below build a mutable copy of the query/attributes dict
// (toll-free-bridged to CFDictionaryRef for the call to orig - no separate
// immutable copy needed) and CFRelease it once orig returns, rather than
// leaking a fresh CFDictionaryRef on every keychain call.
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef*);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef* result) {
  if (CFDictionaryContainsKey(attributes, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableAttributes = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFDictionarySetValue(mutableAttributes, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
    OSStatus status = orig_SecItemAdd(mutableAttributes, result);
    CFRelease(mutableAttributes);
    return status;
  }
  return orig_SecItemAdd(attributes, result);
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef*);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef* result) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
    OSStatus status = orig_SecItemCopyMatching(mutableQuery, result);
    CFRelease(mutableQuery);
    return status;
  }
  return orig_SecItemCopyMatching(query, result);
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
    OSStatus status = orig_SecItemUpdate(mutableQuery, attributesToUpdate);
    CFRelease(mutableQuery);
    return status;
  }
  return orig_SecItemUpdate(query, attributesToUpdate);
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
    OSStatus status = orig_SecItemDelete(mutableQuery);
    CFRelease(mutableQuery);
    return status;
  }
  return orig_SecItemDelete(query);
}

static void initSideloadedFixes() {
  fakeGroupContainerURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"] isDirectory:YES];
  loadKeychainAccessGroup();
  rebind_symbols(
      (struct rebinding[]){
          {"SecItemAdd", (void*)hook_SecItemAdd, (void**)&orig_SecItemAdd},
          {"SecItemCopyMatching", (void*)hook_SecItemCopyMatching,
           (void**)&orig_SecItemCopyMatching},
          {"SecItemUpdate", (void*)hook_SecItemUpdate, (void**)&orig_SecItemUpdate},
          {"SecItemDelete", (void*)hook_SecItemDelete, (void**)&orig_SecItemDelete},
      },
    4);
    Method originalMethod = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method swizzledMethod = class_getInstanceMethod([NSFileManager class], @selector(swizzled_containerURLForSecurityApplicationGroupIdentifier:));
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

%ctor {
  %init;
  initSideloadedFixes();
}