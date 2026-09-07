#import <Foundation/Foundation.h>

// Sideload-safe Apple Music bridge, in two halves that fail independently.
//
// BeReal's own connector is MusicKit (`CoreMusicDomain.AppleMusic.MusicKitClient`,
// linked against /System/Library/Frameworks/MusicKit.framework). Its catalog
// calls go through MusicDataRequest, which needs a developer token minted for
// the App ID that shipped the app - a re-signed IPA is signed by another team
// and cannot recreate that identity, so every `MusicDataRequest` in the app
// answers `appleMusicAccessNotGranted` no matter what the user does. There is
// nothing to hook: those are Swift types with no @objc surface.
//
// So this manager rebuilds the two things the composer actually needs, out of
// APIs a sideloaded app is allowed to call:
//
//  * "what is playing right now" - MPMusicPlayerController's system player.
//    Public, but it only ever sees the Music app (not Spotify, not YouTube),
//    and it needs the media-library permission. It can therefore legitimately
//    have no answer, which is why `state` exists: "nothing is playing" and
//    "the user said no in 2024" must not look the same to the UI.
//
//  * "let me pick a track" - the public iTunes Search API. No account, no
//    token, no permission, no entitlement. This is the half that always works
//    and the one to reach for when a report says the widget stayed empty.
//
// Both produce the same `music` dictionary BeaUploadTask sends, with the field
// names read out of BeReal's own PostMusicDto: isrc, track, artist, artwork,
// preview, openUrl, audioType, provider, providerId, visibility.
typedef NS_ENUM(NSInteger, BeaAppleMusicState) {
	BeaAppleMusicStateIdle,           // never started
	BeaAppleMusicStateNotDetermined,  // permission has not been asked yet
	BeaAppleMusicStateDenied,         // user refused, or parental restriction
	BeaAppleMusicStateNothingPlaying, // allowed, but the Music app has no item
	BeaAppleMusicStatePlaying,        // allowed, and a track was published
};

@interface BeaAppleMusicManager : NSObject
+ (instancetype)sharedInstance;

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)retrieveCurrentlyPlayingSong;

// Why the widget is empty. Reported on the diagnostics screen, because
// "no music is playing" and "MediaPlayer was never allowed to answer" are
// otherwise indistinguishable from the outside.
@property (nonatomic, readonly) BeaAppleMusicState state;
@property (nonatomic, readonly, copy) NSString *stateDescription;
// Last iTunes outcomes, same reasoning. Kept apart so the now-playing lookup
// cannot overwrite the record of a search the user actually ran.
@property (nonatomic, readonly, copy) NSString *lastLookupDescription;
@property (nonatomic, readonly, copy) NSString *lastSearchDescription;

// Public catalog search. `results` are ready-to-attach music dictionaries in
// the same shape BeaSongSearchViewController already renders for Spotify; the
// block runs on the main queue.
//
// `failure` is nil when the request itself succeeded - an empty `results` then
// genuinely means the catalog had no match. It carries a human-readable reason
// otherwise, because folding a network failure into "no results" is how a
// broken search looks exactly like a bad spelling, which is precisely the
// report this parameter exists to answer.
+ (void)searchCatalogForTerm:(NSString *)term
                  completion:(void (^)(NSArray<NSDictionary *> *results, NSString *failure))completion;
@end
