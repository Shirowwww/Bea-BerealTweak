#import <Foundation/Foundation.h>

@protocol BeaSpotifyAPIHandlerDelegate <NSObject>
- (void)managerDidValidateAccessToken;
@optional
// Spotify answered 401 repeatedly and the refresh never recovered - the link
// is gone on BeReal's side, and there is nothing a five-second poll can do
// about it except keep asking. Lets the widget stop that poll without
// touching the Apple Music watcher next to it.
- (void)managerDidExhaustSpotifyAccess;
@end
