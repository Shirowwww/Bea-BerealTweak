#import "BeaAppleMusicManager.h"
#import <MediaPlayer/MediaPlayer.h>
#import "../MusicManager/BeaMusicManager.h"
#import "../../../../Utilities/Debug/BeaDebug.h"
#import "../../../../Utilities/Localization/BeaLocalization.h"
#import "../../../../Utilities/Settings/BeaSettings.h"

static NSString *BeaAMString(id value) {
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *BeaAMCountryCode(void) {
	NSString *country = [NSLocale currentLocale].countryCode.lowercaseString;
	return country.length == 2 ? country : @"us";
}

static NSString *BeaAMArtworkURLWithBestSize(NSString *urlString) {
	if (urlString.length == 0) return nil;
	// iTunes artwork URLs carry their size as the last path component
	// ("/100x100bb.jpg"). Replace only that; query parameters can carry CDN
	// signatures and must stay untouched.
	NSRegularExpression *sizeExpression =
		[NSRegularExpression regularExpressionWithPattern:@"/(?:[0-9]{2,5})x(?:[0-9]{2,5})(?=[^/]*$)"
		                                          options:0
		                                            error:nil];
	return [sizeExpression stringByReplacingMatchesInString:urlString
	                                                options:0
	                                                  range:NSMakeRange(0, urlString.length)
	                                           withTemplate:@"/1000x1000"];
}

// One iTunes Search/lookup result -> the `music` object BeReal's own
// PostMusicDto declares. `preview` is not optional in practice: it is the 30s
// stream the feed plays, and a post attached without it renders as a track
// nobody can hear. The public search API is the only place a sideloaded build
// can get one for Apple Music.
static NSDictionary *BeaAMMusicFromResult(NSDictionary *result, NSString *fallbackTrack, NSString *fallbackArtist) {
	if (![result isKindOfClass:[NSDictionary class]]) return nil;

	NSString *track = BeaAMString(result[@"trackName"]) ?: fallbackTrack;
	NSString *artist = BeaAMString(result[@"artistName"]) ?: fallbackArtist;
	if (track.length == 0 || artist.length == 0) return nil;

	NSString *kind = BeaAMString(result[@"kind"]).lowercaseString ?: @"";
	NSString *wrapper = BeaAMString(result[@"wrapperType"]).lowercaseString ?: @"";
	BOOL isPodcast = [kind containsString:@"podcast"] || [wrapper containsString:@"podcast"];

	NSString *providerID = result[@"trackId"] ? [result[@"trackId"] description] : @"";
	return @{
		@"artist":     artist,
		@"track":      track,
		@"artwork":    BeaAMArtworkURLWithBestSize(BeaAMString(result[@"artworkUrl100"])) ?: @"",
		// The iTunes Search API does not publish ISRCs. BeReal treats the
		// field as optional (its Core Data model has it nullable); an empty
		// string is what its own path sends for a track it could not match.
		@"isrc":       @"",
		@"preview":    BeaAMString(result[@"previewUrl"]) ?: @"",
		@"openUrl":    BeaAMString(result[@"trackViewUrl"]) ?: @"",
		@"audioType":  isPodcast ? @"podcast" : @"track",
		@"provider":   @"appleMusic",
		@"providerId": providerID,
		@"visibility": @"public"
	};
}

@interface BeaAppleMusicManager ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastPublishedKey;
@property (nonatomic, assign) BOOL authorizationRequestInFlight;
@property (nonatomic, assign) BOOL generatingNotifications;
@property (nonatomic, assign) BeaAppleMusicState state;
@property (nonatomic, copy) NSString *lastLookupDescription;

// Declared up here so a call site earlier in the file resolves against a real
// signature rather than against whatever the compiler can infer from a Class
// receiver.
+ (NSURL *)catalogURLForStoreID:(NSString *)storeID track:(NSString *)track artist:(NSString *)artist;
+ (void)fetchResultsFromURL:(NSURL *)url completion:(void (^)(NSArray *results, NSString *outcome))completion;
+ (void)lookupCatalogForStoreID:(NSString *)storeID
                          track:(NSString *)track
                         artist:(NSString *)artist
                     completion:(void (^)(NSDictionary *music, NSString *outcome))completion;
@end

@implementation BeaAppleMusicManager

+ (instancetype)sharedInstance {
	static BeaAppleMusicManager *instance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [[self alloc] init];
	});
	return instance;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_state = BeaAppleMusicStateIdle;
		_lastLookupDescription = @"never run";
	}
	return self;
}

#pragma mark - Monitoring

- (void)startMonitoring {
	// The switch is read here *and* in -retrieveCurrentlyPlayingSong, not once
	// at install time: a switch that only gates the path that starts a
	// behaviour cannot turn it off again, which is the one-way-door mistake
	// documented in AGENTS.md.
	if (![BeaSettings boolForKey:BeaSettingAppleMusicNowPlaying]) {
		[self stopMonitoring];
		[self setStateIfChanged:BeaAppleMusicStateIdle];
		return;
	}

	// Polling alone is what the first version did, and it inherits every
	// MPMusicPlayerController quirk: -playbackState is only kept current for a
	// process that has asked for playback notifications, so a poll-only reader
	// can sit next to a playing track reading "stopped" forever. Ask for the
	// notifications, act on them, and keep the timer purely as a backstop.
	MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
	if (!self.generatingNotifications) {
		self.generatingNotifications = YES;
		[player beginGeneratingPlaybackNotifications];
		[[NSNotificationCenter defaultCenter] addObserver:self
		                                         selector:@selector(retrieveCurrentlyPlayingSong)
		                                             name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification
		                                           object:player];
		[[NSNotificationCenter defaultCenter] addObserver:self
		                                         selector:@selector(retrieveCurrentlyPlayingSong)
		                                             name:MPMusicPlayerControllerPlaybackStateDidChangeNotification
		                                           object:player];
	}

	if (!self.timer) {
		self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0
		                                              target:self
		                                            selector:@selector(retrieveCurrentlyPlayingSong)
		                                            userInfo:nil
		                                             repeats:YES];
	}

	[self requestAuthorizationIfNeeded];
	[self retrieveCurrentlyPlayingSong];
}

- (void)stopMonitoring {
	[self.timer invalidate];
	self.timer = nil;
	if (self.generatingNotifications) {
		self.generatingNotifications = NO;
		[[NSNotificationCenter defaultCenter] removeObserver:self
		                                                name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification
		                                              object:nil];
		[[NSNotificationCenter defaultCenter] removeObserver:self
		                                                name:MPMusicPlayerControllerPlaybackStateDidChangeNotification
		                                              object:nil];
		[[MPMusicPlayerController systemMusicPlayer] endGeneratingPlaybackNotifications];
	}
}

- (void)requestAuthorizationIfNeeded {
	MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
	if (status != MPMediaLibraryAuthorizationStatusNotDetermined || self.authorizationRequestInFlight) return;

	self.authorizationRequestInFlight = YES;
	[MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus requestedStatus) {
		self.authorizationRequestInFlight = NO;
		BeaLog("[BeaAM] media authorization result=%{public}ld", (long)requestedStatus);
		dispatch_async(dispatch_get_main_queue(), ^{ [self retrieveCurrentlyPlayingSong]; });
	}];
}

#pragma mark - State

- (NSString *)stateDescription {
	switch (self.state) {
		case BeaAppleMusicStateIdle:           return @"not running (switch off, or composer never opened)";
		case BeaAppleMusicStateNotDetermined:  return @"permission not asked yet";
		case BeaAppleMusicStateDenied:         return @"permission DENIED - iOS Settings > BeReal > Media & Apple Music";
		case BeaAppleMusicStateNothingPlaying: return @"allowed, Music app has nothing playing";
		case BeaAppleMusicStatePlaying:        return @"allowed, track published";
	}
	return @"?";
}

- (void)setStateIfChanged:(BeaAppleMusicState)state {
	if (self.state == state) return;
	self.state = state;
	BeaLog("[BeaAM] state -> %{public}@", self.stateDescription);
}

// Only clears an attachment this manager itself made. A Spotify result, or a
// track the user picked by hand, is not ours to erase because the Music app
// went quiet.
- (void)clearOwnAttachment {
	self.lastPublishedKey = nil;
	NSDictionary *current = [[BeaMusicManager sharedInstance] musicDict];
	if (![current[@"music"][@"provider"] isEqualToString:@"appleMusic"]) return;
	[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:@{ @"music": @{ @"artist": @"", @"track": @"" } }];
}

#pragma mark - Now playing

- (void)retrieveCurrentlyPlayingSong {
	if (![BeaSettings boolForKey:BeaSettingAppleMusicNowPlaying]) {
		[self stopMonitoring];
		[self setStateIfChanged:BeaAppleMusicStateIdle];
		return;
	}

	// Public MediaPlayer only. Nothing here fabricates post state, rewrites a
	// request, or touches BeReal's own session - see AGENTS.md.
	MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
	if (status == MPMediaLibraryAuthorizationStatusNotDetermined) {
		[self setStateIfChanged:BeaAppleMusicStateNotDetermined];
		return;
	}
	if (status != MPMediaLibraryAuthorizationStatusAuthorized) {
		[self setStateIfChanged:BeaAppleMusicStateDenied];
		[self clearOwnAttachment];
		return;
	}

	MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
	MPMediaItem *item = player.nowPlayingItem;
	NSString *track = BeaAMString([item valueForProperty:MPMediaItemPropertyTitle]);
	NSString *artist = BeaAMString([item valueForProperty:MPMediaItemPropertyArtist]);
	if (artist.length == 0) artist = BeaAMString([item valueForProperty:MPMediaItemPropertyAlbumArtist]);

	// Deliberately not `playbackState == Playing`. Pausing for ten seconds
	// while you write a caption is still "what I am listening to", and
	// hard-gating on Playing is how a widget ends up empty for a reason no log
	// explains. Only an explicit Stopped - the queue really is finished -
	// drops the attachment.
	BOOL hasTrack = item != nil && track.length > 0 && artist.length > 0;
	if (!hasTrack || player.playbackState == MPMusicPlaybackStateStopped) {
		[self setStateIfChanged:BeaAppleMusicStateNothingPlaying];
		[self clearOwnAttachment];
		return;
	}

	NSString *storeID = [item respondsToSelector:@selector(playbackStoreID)] ? item.playbackStoreID : nil;
	NSString *publishKey = [NSString stringWithFormat:@"%@|%@|%@", storeID ?: @"", track, artist];
	if ([publishKey isEqualToString:self.lastPublishedKey]) {
		[self setStateIfChanged:BeaAppleMusicStatePlaying];
		return;
	}
	self.lastPublishedKey = publishKey;

	BeaLog("[BeaAM] now playing track=%{public}@ artist=%{public}@ storeID=%{public}@",
		track, artist, storeID ?: @"(none)");

	// MediaPlayer hands artwork over as a UIImage and has no preview stream at
	// all, so the catalog lookup is not a nicety here - it is where `artwork`,
	// `preview` and `openUrl` come from. Publish immediately with what is
	// already known so the widget fills in at once, then refine.
	NSDictionary *provisional = @{
		@"music": @{
			@"artist": artist, @"track": track, @"artwork": @"", @"isrc": @"",
			@"preview": @"", @"openUrl": @"", @"audioType": @"track",
			@"provider": @"appleMusic", @"providerId": storeID ?: @"", @"visibility": @"public"
		}
	};
	[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:provisional];
	[self setStateIfChanged:BeaAppleMusicStatePlaying];

	[BeaAppleMusicManager lookupCatalogForStoreID:storeID
	                                  track:track
	                                 artist:artist
	                             completion:^(NSDictionary *music, NSString *outcome) {
		self.lastLookupDescription = outcome;
		if (!music) return;
		// A track change while the lookup was in flight wins - never overwrite
		// a newer attachment with a stale one.
		if (![self.lastPublishedKey isEqualToString:publishKey]) return;
		[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:@{ @"music": music }];
	}];
}

#pragma mark - Public catalog (no account, no token, no permission)

+ (NSURL *)catalogURLForStoreID:(NSString *)storeID track:(NSString *)track artist:(NSString *)artist {
	if (storeID.length > 0) {
		NSURLComponents *components = [NSURLComponents componentsWithString:@"https://itunes.apple.com/lookup"];
		components.queryItems = @[
			[NSURLQueryItem queryItemWithName:@"id" value:storeID],
			[NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
			[NSURLQueryItem queryItemWithName:@"country" value:BeaAMCountryCode()]
		];
		return components.URL;
	}
	if (track.length == 0) return nil;
	NSString *term = artist.length > 0 ? [NSString stringWithFormat:@"%@ %@", track, artist] : track;
	NSURLComponents *components = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
	components.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"term" value:term],
		[NSURLQueryItem queryItemWithName:@"media" value:@"music"],
		[NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
		[NSURLQueryItem queryItemWithName:@"limit" value:@"1"],
		[NSURLQueryItem queryItemWithName:@"country" value:BeaAMCountryCode()]
	];
	return components.URL;
}

+ (void)fetchResultsFromURL:(NSURL *)url completion:(void (^)(NSArray *results, NSString *outcome))completion {
	if (!url) {
		completion(@[], @"no query to run");
		return;
	}
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
		if (error || http.statusCode < 200 || http.statusCode >= 300) {
			NSString *outcome = [NSString stringWithFormat:@"failed (HTTP %ld, %@)",
				(long)http.statusCode, error.localizedDescription ?: @"no error"];
			BeaLog("[BeaAM] itunes %{public}@", outcome);
			dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], outcome); });
			return;
		}
		NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
		if (![results isKindOfClass:[NSArray class]]) results = @[];
		NSString *outcome = [NSString stringWithFormat:@"%lu result(s)", (unsigned long)results.count];
		dispatch_async(dispatch_get_main_queue(), ^{ completion(results, outcome); });
	}];
	[task resume];
}

+ (void)lookupCatalogForStoreID:(NSString *)storeID
                          track:(NSString *)track
                         artist:(NSString *)artist
                     completion:(void (^)(NSDictionary *music, NSString *outcome))completion {
	NSURL *url = [self catalogURLForStoreID:storeID track:track artist:artist];
	[self fetchResultsFromURL:url completion:^(NSArray *results, NSString *outcome) {
		NSDictionary *music = BeaAMMusicFromResult(results.firstObject, track, artist);
		if (music && [music[@"preview"] length] == 0) {
			// Worth saying out loud: an attachment with no preview stream is
			// exactly the "the song shows but nothing plays" report.
			outcome = [outcome stringByAppendingString:@", no preview URL"];
		}
		completion(music, outcome);
	}];
}

+ (void)searchCatalogForTerm:(NSString *)term
                  completion:(void (^)(NSArray<NSDictionary *> *results))completion {
	NSString *trimmed = [term stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (trimmed.length == 0) {
		completion(@[]);
		return;
	}
	NSURLComponents *components = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
	components.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"term" value:trimmed],
		[NSURLQueryItem queryItemWithName:@"media" value:@"music"],
		[NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
		[NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
		[NSURLQueryItem queryItemWithName:@"country" value:BeaAMCountryCode()]
	];

	[self fetchResultsFromURL:components.URL completion:^(NSArray *results, NSString *outcome) {
		[BeaAppleMusicManager sharedInstance].lastLookupDescription = outcome;
		NSMutableArray *rows = [NSMutableArray array];
		for (NSDictionary *result in results) {
			NSDictionary *music = BeaAMMusicFromResult(result, nil, nil);
			if (music) [rows addObject:@{ @"music": music }];
		}
		completion(rows);
	}];
}

@end
