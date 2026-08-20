#import "BeaAppleMusicManager.h"
#import <MediaPlayer/MediaPlayer.h>
#import "../MusicManager/BeaMusicManager.h"
#import "../../../../Utilities/Debug/BeaDebug.h"
#import "../../../../Utilities/Localization/BeaLocalization.h"

static NSString *BeaAMString(id value) {
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *BeaAMURLString(id value) {
	if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
	return BeaAMString(value);
}

static NSString *BeaAMStoreID(MPMediaItem *item) {
	// playbackStoreID is the Apple Music catalog identifier. PersistentID is
	// only a local-library identifier and is deliberately used as a last resort
	// so it is never mistaken for a catalog ID when Apple provided one.
	if ([item respondsToSelector:@selector(playbackStoreID)]) {
		NSString *storeID = item.playbackStoreID;
		if (storeID.length > 0) return storeID;
	}
	return nil;
}

static NSString *BeaAMCountryCode(void) {
	NSString *country = [NSLocale currentLocale].countryCode.lowercaseString;
	return country.length == 2 ? country : @"us";
}

static NSString *BeAMURLForStoreID(NSString *storeID, NSString *track) {
	if (storeID.length == 0) return nil;
	NSString *encodedTrack = [track stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
	if (encodedTrack.length == 0) encodedTrack = @"song";
	return [NSString stringWithFormat:@"https://music.apple.com/%@/song/%@/%@", BeaAMCountryCode(), encodedTrack, storeID];
}

static NSString *BeaAMArtworkURLWithBestSize(NSString *urlString) {
	if (urlString.length == 0) return nil;
	// Apple/iTunes artwork URLs carry a size component in the path. Replace
	// only that component; query parameters (which can carry CDN signatures)
	// stay untouched.
	NSRegularExpression *sizeExpression = [NSRegularExpression regularExpressionWithPattern:@"/(?:[0-9]{2,5})x(?:[0-9]{2,5})(?=[^/]*$)" options:0 error:nil];
	return [sizeExpression stringByReplacingMatchesInString:urlString
	                                                  options:0
                                                    range:NSMakeRange(0, urlString.length)
                                             withTemplate:@"/1000x1000"];
}

@interface BeaAppleMusicManager ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastStoreID;
@property (nonatomic, copy) NSString *lastTrack;
@property (nonatomic, assign) BOOL authorizationRequestInFlight;
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

- (void)startMonitoring {
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
}

- (void)requestAuthorizationIfNeeded {
	MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
	BeaLog("[BeaAM] media authorization status=%{public}ld", (long)status);
	if (status != MPMediaLibraryAuthorizationStatusNotDetermined || self.authorizationRequestInFlight) return;

	self.authorizationRequestInFlight = YES;
	[MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus requestedStatus) {
		self.authorizationRequestInFlight = NO;
		BeaLog("[BeaAM] media authorization result=%{public}ld", (long)requestedStatus);
		[self retrieveCurrentlyPlayingSong];
	}];
}

- (void)retrieveCurrentlyPlayingSong {
	// These calls are intentionally public MediaPlayer APIs. No fabricated
	// BeReal post state, request, or HasPosted value is involved.
	NSBundle *mainBundle = [NSBundle mainBundle];
	NSString *bundleID = mainBundle.bundleIdentifier ?: @"(nil)";
	NSString *infoBundleID = [mainBundle objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"(nil)";
	Class musicAuthorization = NSClassFromString(@"MusicAuthorization") ?: NSClassFromString(@"MusicKit.MusicAuthorization");
	Class musicKitClient = NSClassFromString(@"_TtCO15CoreMusicDomain10AppleMusic14MusicKitClient");
	BeaLog("[BeaAM] bundle=%{public}@ infoBundle=%{public}@ MusicAuthorization=%{public}@ BeRealAppleMusicClient=%{public}@",
		bundleID, infoBundleID, musicAuthorization ? @"loaded" : @"absent", musicKitClient ? @"loaded" : @"absent");

	MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
	MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
	MPMediaItem *item = player.nowPlayingItem;
	NSDictionary *nowPlayingInfo = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
	NSNumber *rate = nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate];
	BeaLog("[BeaAM] permission=%{public}ld playerState=%{public}ld item=%{public}@ nowPlayingInfo=%{public}@ rate=%{public}@",
		(long)status, (long)player.playbackState, item ? @"yes" : @"no", nowPlayingInfo ? @"yes" : @"no", rate ?: @"(none)");

	NSString *track = BeaAMString([item valueForProperty:MPMediaItemPropertyTitle]);
	NSString *artist = BeaAMString([item valueForProperty:MPMediaItemPropertyArtist]);
	if (artist.length == 0) artist = BeaAMString([item valueForProperty:MPMediaItemPropertyAlbumArtist]);
	if (track.length == 0) track = BeaAMString(nowPlayingInfo[MPMediaItemPropertyTitle]);
	if (artist.length == 0) artist = BeaAMString(nowPlayingInfo[MPMediaItemPropertyArtist]);

	BOOL isPlaying = player.playbackState == MPMusicPlaybackStatePlaying;
	if (!isPlaying && rate != nil) isPlaying = rate.doubleValue > 0.0;
	if (!item || track.length == 0 || artist.length == 0 || !isPlaying) {
		self.lastStoreID = nil;
		// Do not erase a Spotify result merely because Apple Music has no active
		// item. If Apple was the current attachment, clear it so the composer
		// cannot silently post a stopped track.
		NSDictionary *currentMusic = [[BeaMusicManager sharedInstance] musicDict];
		if ([currentMusic[@"music"][@"provider"] isEqualToString:@"appleMusic"]) {
			NSDictionary *empty = @{ @"music": @{ @"artist": @"", @"track": @"" } };
			[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:empty];
		}
		return;
	}

	NSString *storeID = BeaAMStoreID(item);
	NSString *assetURL = BeaAMURLString([item valueForProperty:MPMediaItemPropertyAssetURL]);
	NSString *openURL = assetURL.length > 0 && [assetURL hasPrefix:@"http"] ? assetURL : BeAMURLForStoreID(storeID, track);
	MPMediaType mediaType = [[item valueForProperty:MPMediaItemPropertyMediaType] unsignedIntegerValue];
	NSString *audioType = (mediaType & MPMediaTypePodcast) != 0 ? @"podcast" : @"track";
	NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|%@", storeID ?: @"", track, artist];
	if ([cacheKey isEqualToString:self.lastStoreID]) return;
	self.lastStoreID = cacheKey;
	self.lastTrack = track;

	NSMutableDictionary *music = [@{
		@"artist": artist,
		@"track": track,
		@"audioType": audioType,
		@"isrc": @"",
		@"openUrl": openURL ?: @"",
		@"provider": @"appleMusic",
		@"providerId": storeID ?: @"",
		@"artwork": @"",
		@"visibility": @"public"
	} mutableCopy];

	// MediaPlayer exposes artwork as a UIImage, not as a remotely fetchable
	// URL. Resolve the catalog item by store ID (or title/artist) so BeReal gets
	// the same CDN artwork string its own MusicKit flow would send. This public
	// iTunes lookup is only metadata; it never uploads or logs account data.
	NSString *lookupURLString = storeID.length > 0
		? [NSString stringWithFormat:@"https://itunes.apple.com/lookup?entity=song&id=%@&country=%@", storeID, BeaAMCountryCode()]
		: nil;
	if (!lookupURLString && track.length > 0) {
		NSURLComponents *components = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
		components.queryItems = @[
			[NSURLQueryItem queryItemWithName:@"term" value:[NSString stringWithFormat:@"%@ %@", track, artist]],
			[NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
			[NSURLQueryItem queryItemWithName:@"limit" value:@"1"],
			[NSURLQueryItem queryItemWithName:@"country" value:BeaAMCountryCode()]
		];
		lookupURLString = components.URL.absoluteString;
	}

	if (!lookupURLString) {
		[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:@{ @"music": music }];
		return;
	}

	NSURL *lookupURL = [NSURL URLWithString:lookupURLString];
	BeaLog("[BeaAM] track=%{public}@ artist=%{public}@ providerId=%{public}@ audioType=%{public}@ lookup=itunes",
		track, artist, storeID ?: @"(none)", audioType);
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:lookupURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
		NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
		NSDictionary *result = [results isKindOfClass:[NSArray class]] ? results.firstObject : nil;
		if (error || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 || ![result isKindOfClass:[NSDictionary class]]) {
			BeaLog("[BeaAM] metadata lookup failed status=%{public}ld error=%{public}@", (long)httpResponse.statusCode, error.localizedDescription ?: @"(none)");
		} else {
			NSString *artwork = BeaAMArtworkURLWithBestSize(BeaAMString(result[@"artworkUrl100"]));
			NSString *resultURL = BeaAMString(result[@"trackViewUrl"]);
			NSString *resultID = [result[@"trackId"] description];
			if (artwork.length > 0) music[@"artwork"] = artwork;
			if (resultURL.length > 0) music[@"openUrl"] = resultURL;
			NSString *currentProviderID = [music[@"providerId"] isKindOfClass:[NSString class]] ? music[@"providerId"] : nil;
			if (currentProviderID.length == 0 && resultID.length > 0) music[@"providerId"] = resultID;
			BeaLog("[BeaAM] metadata resolved artwork=%{public}@ providerId=%{public}@", artwork.length > 0 ? @"yes" : @"no", music[@"providerId"] ?: @"(none)");
		}
		NSString *resolvedArtwork = [music[@"artwork"] isKindOfClass:[NSString class]] ? music[@"artwork"] : nil;
		if (resolvedArtwork.length == 0) {
			// The item is still valid without artwork; posting must not hang while
			// waiting for an optional catalog field.
			BeaLog("[BeaAM] using track without artwork URL");
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if ([self.lastStoreID isEqualToString:cacheKey]) {
				[[BeaMusicManager sharedInstance] updateCurrentlyPlaying:@{ @"music": music }];
			}
		});
	}];
	[task resume];
}

@end
