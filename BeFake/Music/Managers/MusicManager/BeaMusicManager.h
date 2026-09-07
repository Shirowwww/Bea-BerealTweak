#include <Foundation/Foundation.h>

// Posted when a provider has something to *say* rather than something to
// attach. `object` is the message, or nil to clear it.
FOUNDATION_EXPORT NSString *const BeaMusicStatusNotification;

@interface BeaMusicManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *musicDict;
@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *track;
@property (nonatomic, assign) NSInteger playingStatus;
// The last thing a provider said about itself ("token expired", "nothing
// playing"). Deliberately not part of musicDict - see -reportProviderStatus:.
@property (nonatomic, copy, readonly) NSString *providerStatus;
+ (instancetype)sharedInstance;
- (void)updateCurrentlyPlaying:(NSDictionary *)musicDict;

// Status text is not an attachment. The Spotify handler used to publish "Jeton
// d'accès expiré" through -updateCurrentlyPlaying: with the message in the
// `track` field, which meant a provider error overwrote whatever the other
// provider had legitimately attached - every five seconds, for as long as the
// poll ran. A device report caught exactly that: an Apple Music track resolved
// and published, then replaced by Spotify's 401 message. Anything that is a
// message about a provider goes here instead.
- (void)reportProviderStatus:(NSString *)message;

// Drops the current attachment only if it came from `provider`. No provider may
// erase another's result, or a track the user picked by hand.
- (void)clearAttachmentForProvider:(NSString *)provider;

- (void)setMusicVisibility:(NSString *)visibility;
- (void)resetData;
@end