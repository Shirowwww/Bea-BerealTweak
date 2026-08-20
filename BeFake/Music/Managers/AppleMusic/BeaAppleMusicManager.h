#import <Foundation/Foundation.h>

// Sideload-safe Apple Music bridge. BeReal's own MusicKit connector requires
// the original Apple Developer App ID and its server-side MusicKit setup; a
// re-signed IPA cannot recreate that identity. This manager reads the public
// system now-playing surface and converts it to the same `music` dictionary
// BeaUploadTask already sends for Spotify.
@interface BeaAppleMusicManager : NSObject
+ (instancetype)sharedInstance;
- (void)startMonitoring;
- (void)stopMonitoring;
- (void)retrieveCurrentlyPlayingSong;
@end
