#import <UIKit/UIKit.h>
#import "../../Music/BeaSpotifyAPIHandlerDelegate.h"
#import "../../Music/Managers/MusicManager/BeaMusicManager.h"
#import "../../Music/Managers/APIHandler/BeaSpotifyAPIHandler.h"
#import "../../Music/Managers/AppleMusic/BeaAppleMusicManager.h"

@interface BeaSpotifyMusicView : UIView <BeaSpotifyAPIHandlerDelegate>
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UILabel *trackLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) NSDictionary *musicDict;
@property (nonatomic, strong) UITapGestureRecognizer *tapRecognizer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) BeaSpotifyAPIHandler *handler;
@property (nonatomic, strong) BeaAppleMusicManager *appleMusicManager;
// Set once the user picks a track in the search sheet: auto-detection must not
// come back and overwrite a deliberate choice.
@property (nonatomic, assign) BOOL manualSelection;
// Spotify answered 401 until there was no point asking again; its poll stays
// stopped for the session, the Apple Music watcher carries on.
@property (nonatomic, assign) BOOL spotifyExhausted;
- (void)refreshMusicView;
- (void)stopTimer;
// Restarts both watchers after the composer has been covered by a picker.
- (void)resumeMonitoring;
@end
