#import "BeaSpotifyAPIHandler.h"
#import "../../../../Utilities/Localization/BeaLocalization.h"
#import "../../../../Utilities/Debug/BeaDebug.h"

@implementation BeaSpotifyAPIHandler
- (instancetype)init {
    self = [super init];
    if (self) {
        [self validateAccessToken];
    }
    return self;
}


- (void)validateAccessToken {
    [[BeaTokenManager sharedInstance] retrieveCredentials];

    self.expiryValue = [[BeaTokenManager sharedInstance] expiryValue];
    
    NSDate *now = [NSDate date];
    NSTimeInterval nowTimestamp = [now timeIntervalSinceReferenceDate];

    NSTimeInterval expireTimestamp = [self.expiryValue doubleValue];

    // check if the access token already expired
    if (nowTimestamp > expireTimestamp) {
        [self refreshSpotifyAccessToken];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate managerDidValidateAccessToken];
        });
    }
}

// One attempt per minute, whatever asks. The 401 path is driven by a five-second
// poll, so without this an account whose Spotify link BeReal can no longer
// refresh sends a request to mobile-l7.bereal.com twelve times a minute for as
// long as the composer stays open.
- (void)refreshSpotifyAccessTokenIfNotRecentlyTried {
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (self.lastRefreshAttempt > 0 && now - self.lastRefreshAttempt < 60.0) return;
    self.lastRefreshAttempt = now;
    [self refreshSpotifyAccessToken];
}

- (void)refreshSpotifyAccessToken {
    // to refresh the access token, a call to bereals api endpoint has to be made
    // this will return a new access token that we can use to fetch the currently playing song

    self.refreshToken = [[BeaTokenManager sharedInstance] spotifyRefreshToken];
    NSString *BRAccessToken = [[BeaTokenManager sharedInstance] BRAccessToken];

    if (!self.refreshToken) return;

    NSString *baseRefreshURL = @"https://mobile-l7.bereal.com/api/music/spotify/refresh_token";
    NSString *refreshURLString = [NSString stringWithFormat:@"%@?refresh_token=%@", baseRefreshURL, self.refreshToken];
    NSURL *refreshURL = [NSURL URLWithString:refreshURLString];

    NSMutableURLRequest *refreshTokenRequest = [NSMutableURLRequest requestWithURL:refreshURL];
    [refreshTokenRequest setHTTPMethod:@"GET"];

    NSDictionary *headers = @{
        @"authorization": BRAccessToken,
        @"accept": @"*/*",
        @"bereal-platform": @"iOS",
        @"bereal-os-version": @"14.7.1",
        @"accept-Language": @"en-US;q=1.0",
        @"user-Agent": @"BeReal/1.7.0 (AlexisBarreyat.BeReal; build:11001; iOS 14.7.1) 1.0.0/BRApiKit",
        @"bereal-app-language": @"en-US",
        @"bereal-device-language": @"en",
        @"bereal-app-version" : @"1.7.0-(11001)"
    };

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [refreshTokenRequest setValue:value forHTTPHeaderField:field];
    }];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:refreshTokenRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 200) {
                NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
                self.accessToken = jsonResponse[@"accessToken"];

                // update the access tokens in the keychain to avoid future unneccesary api calls
                [[BeaTokenManager sharedInstance] writeToKeychainWithDictionary:jsonResponse];

                // notify the delegate that the manager now validated the access token
                [self.delegate managerDidValidateAccessToken];
            } else {
                NSLog(@"[Bea] Error! %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            }
        }
    }];
    [task resume];
}

- (void)retrieveCurrentlyPlayingSong {
    // since the delegate is called from the main thread and thus this function also
    // enter the background thread again

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // check if the access token is nil since it's possible that it hasn't been set before
        if (!self.accessToken) {
            self.accessToken = [[BeaTokenManager sharedInstance] spotifyAccessToken];
        }

        NSString *currentlyPlayingURLString = @"https://api.spotify.com/v1/me/player/currently-playing?additional_types=episode";    
        NSURL *currentlyPlayingURL = [NSURL URLWithString:currentlyPlayingURLString];

        NSMutableURLRequest *currentlyPlayingRequest = [NSMutableURLRequest requestWithURL:currentlyPlayingURL];
        [currentlyPlayingRequest setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken] forHTTPHeaderField:@"Authorization"];
        
        NSURLSessionDataTask *currentlyPlayingTask = [[NSURLSession sharedSession] dataTaskWithRequest:currentlyPlayingRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;

            // Nothing playing on Spotify is a *status*, not an attachment. It
            // used to be published through -updateCurrentlyPlaying: with the
            // message sitting in the `track` field, which erased whatever Apple
            // Music had just resolved - every five seconds, for as long as this
            // poll ran.
            if (httpResponse.statusCode == 204 || data.length == 0) {
                [[BeaMusicManager sharedInstance] reportProviderStatus:BeaLocalized(@"music.no_track_playing")];
                [[BeaMusicManager sharedInstance] clearAttachmentForProvider:@"spotify"];
                return;
            }

            if (error) {
                BeaLog("[BeaMusic] spotify currently-playing failed: %{public}@", error.localizedDescription);
                return;
            }

            if (httpResponse.statusCode == 401) {
                [[BeaMusicManager sharedInstance] reportProviderStatus:BeaLocalized(@"music.token_expired")];
                [[BeaMusicManager sharedInstance] clearAttachmentForProvider:@"spotify"];
                // Rate-limited on purpose: this poll runs every five seconds, so
                // an unrecoverable 401 used to mean a refresh request to BeReal's
                // own API twelve times a minute for as long as the composer was
                // open.
                [self refreshSpotifyAccessTokenIfNotRecentlyTried];
                return;
            }

            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
            NSDictionary *item = [jsonResponse isKindOfClass:[NSDictionary class]] ? jsonResponse[@"item"] : nil;
            if (![item isKindOfClass:[NSDictionary class]]) {
                // An ad break, or a device Spotify will not describe. Not an
                // error, and not something to attach either.
                [[BeaMusicManager sharedInstance] reportProviderStatus:BeaLocalized(@"music.no_track_playing")];
                return;
            }

            NSString *audioType = jsonResponse[@"currently_playing_type"];

            NSString *artist;
            NSString *artwork;
            NSString *isrc;

            if ([audioType isEqual:@"episode"]) {
                artist = item[@"show"][@"publisher"];
                artwork = [item[@"images"] firstObject][@"url"];
                isrc = @"";
            } else {
                artist = [item[@"artists"] firstObject][@"name"];
                artwork = [item[@"album"][@"images"] firstObject][@"url"];
                isrc = item[@"external_ids"][@"isrc"];
            }

            NSString *track = item[@"name"];
            if (![track isKindOfClass:[NSString class]] || track.length == 0) return;
            if (![artist isKindOfClass:[NSString class]]) artist = @"";

            // BeReal's PostMusicDto calls it `preview` and the feed needs it to
            // play anything; Spotify calls it preview_url and it is genuinely
            // null for some tracks, so an empty value here is expected rather
            // than a failure.
            NSString *preview = item[@"preview_url"];
            if (![preview isKindOfClass:[NSString class]]) preview = @"";

            NSDictionary *musicDict = @{
                @"music" : @{
                    @"artist" : artist,
                    @"artwork" : [artwork isKindOfClass:[NSString class]] ? artwork : @"",
                    @"audioType" : [audioType isKindOfClass:[NSString class]] ? audioType : @"track",
                    @"isrc" : [isrc isKindOfClass:[NSString class]] ? isrc : @"",
                    @"preview" : preview,
                    @"openUrl" : item[@"external_urls"][@"spotify"] ?: @"",
                    @"provider" : @"spotify",
                    @"providerId" : item[@"id"] ?: @"",
                    @"track" : track,
                    @"visibility" : @"public"
                }
            };

            [[BeaMusicManager sharedInstance] reportProviderStatus:nil];
            [[BeaMusicManager sharedInstance] updateCurrentlyPlaying:musicDict];
        }];
        
        [currentlyPlayingTask resume]; 
    });
}
@end
