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

// The last non-empty attachment this session ever held, and when. Deliberately
// survives -resetData.
//
// musicDict only exists while the composer is open, and -resetData clears it in
// the composer's -dealloc - so a diagnostics report, which is reached from the
// settings screen after the composer has closed, always read "Attached track:
// none" however well the attachment had worked. A 0.9.7 report showed exactly
// that next to "Apple Music watcher: track published", which on its own says
// nothing about whether the attachment was right. Same sticky reasoning as the
// gating-layer counter.
@property (nonatomic, copy, readonly) NSDictionary *lastAttachment;
@property (nonatomic, strong, readonly) NSDate *lastAttachmentDate;
@end