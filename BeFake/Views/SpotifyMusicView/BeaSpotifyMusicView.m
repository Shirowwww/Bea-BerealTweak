#import "BeaSpotifyMusicView.h"
#import "../../../Utilities/Localization/BeaLocalization.h"

@implementation BeaSpotifyMusicView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMusicView) name:@"MusicUpdated" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userChoseTrackManually) name:@"StopUpdatingCurrentlyPlaying" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMusicView) name:BeaMusicStatusNotification object:nil];

        self.translatesAutoresizingMaskIntoConstraints = NO;

        self.artworkImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.artworkImageView.layer.cornerRadius = 1.0;
        self.artworkImageView.clipsToBounds = YES;
        [self addSubview:self.artworkImageView];

        // set up the properties for the artist and track label
        self.trackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.trackLabel.font = [UIFont fontWithName:@"Inter" size:17];
        self.trackLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.trackLabel];

        self.artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.artistLabel.font = [UIFont systemFontOfSize:12];
        self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.artistLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.artworkImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.artworkImageView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.artworkImageView.widthAnchor constraintEqualToConstant:36],
            [self.artworkImageView.heightAnchor constraintEqualToConstant:36],
            
            [self.trackLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [self.trackLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [self.trackLabel.trailingAnchor constraintEqualToAnchor:self.artworkImageView.leadingAnchor constant:-12],

            [self.artistLabel.topAnchor constraintEqualToAnchor:self.trackLabel.bottomAnchor constant:2],
            [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.trackLabel.leadingAnchor],
            [self.artistLabel.widthAnchor constraintLessThanOrEqualToConstant:125],
        ]];

        // Unconditional, and that is the fix. It used to be installed only from
        // -startFetchingSongs, which the Spotify handler calls once it has
        // validated a token - so on an account that never linked Spotify the
        // widget was inert: no tap, no picker, no way to attach anything. The
        // picker it opens now works for Apple Music with no account at all.
        self.tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openSpotifyViewController)];
        [self addGestureRecognizer:self.tapRecognizer];

        self.handler = [[BeaSpotifyAPIHandler alloc] init];
        self.handler.delegate = self;

        // The official MusicKit connector cannot survive a sideloaded App ID.
        // Keep Spotify untouched and run the public MediaPlayer fallback in
        // parallel; it only publishes a track when Apple Music is actually
        // playing, so it does not erase a valid Spotify attachment.
        self.appleMusicManager = [BeaAppleMusicManager sharedInstance];
        [self.appleMusicManager startMonitoring];
        [self refreshMusicView];
    }

    return self;
}

// The composer presents pickers on top of itself (photos, location, music),
// and a full-screen one takes it through -viewWillDisappear:. Stopping the
// music watchers there and never restarting them is what left the widget dead
// for the rest of the session once you had chosen your two photos.
- (void)resumeMonitoring {
    // A track the user picked by hand outranks whatever is playing now, so
    // coming back from the picker must not restart the watchers that would
    // immediately overwrite it.
    if (self.manualSelection) {
        [self refreshMusicView];
        return;
    }
    if (!self.timer && self.handler.delegate) [self startTimer];
    [self.appleMusicManager startMonitoring];
    [self refreshMusicView];
}

- (void)userChoseTrackManually {
    self.manualSelection = YES;
    [self stopTimer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timer invalidate];
    [self.appleMusicManager stopMonitoring];
}

- (void)managerDidValidateAccessToken {
    [self startFetchingSongs];
}

- (void)startFetchingSongs {
    // The tap recognizer is installed once, in -initWithFrame:. Adding it here
    // as well gave the view two of them the moment Spotify validated.
    [self.handler retrieveCurrentlyPlayingSong];
    [self startTimer];
}

- (void)startTimer {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self.handler selector:@selector(retrieveCurrentlyPlayingSong) userInfo:nil repeats:YES];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
    [self.appleMusicManager stopMonitoring];
}

- (void)openSpotifyViewController {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"openSpotifyViewController" object:nil];
}

- (void)refreshMusicView {
    self.musicDict = [[BeaMusicManager sharedInstance] musicDict];
    NSString *trackText = self.musicDict[@"music"][@"track"];
    NSString *artistText = self.musicDict[@"music"][@"artist"];
    NSURL *artworkURL = [NSURL URLWithString:self.musicDict[@"music"][@"artwork"]];

    // An empty row is the single most misleading thing this widget can show:
    // it looks the same whether no music is playing, the media permission was
    // refused two months ago, or the whole feature is broken. Say which.
    if (trackText.length == 0) {
        trackText = BeaLocalized(@"music.tap_to_choose");
        // Order matters: a refused permission is the one the user can act on,
        // then whatever a provider last said about itself, then the generic
        // "nothing is playing". These are shown here and never written into the
        // attachment - see -reportProviderStatus:.
        NSString *providerStatus = [[BeaMusicManager sharedInstance] providerStatus];
        if (self.appleMusicManager.state == BeaAppleMusicStateDenied) {
            artistText = BeaLocalized(@"music.permission_denied");
        } else {
            artistText = providerStatus.length > 0 ? providerStatus : BeaLocalized(@"music.no_track_playing");
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView transitionWithView:self.trackLabel duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            self.trackLabel.text = trackText;
        } completion:nil];

        [UIView transitionWithView:self.artistLabel duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            self.artistLabel.text = artistText;
        } completion:nil];
    });

    // Fetched asynchronously - dataWithContentsOfURL: here ran synchronously
    // on whatever thread posted the "MusicUpdated" notification, which can
    // be (and block) the main thread.
    if (!artworkURL) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.artworkImageView.image = nil; });
        return;
    }
    NSURLSessionDataTask *artworkTask = [[NSURLSession sharedSession] dataTaskWithURL:artworkURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *mime = response.MIMEType.lowercaseString ?: @"";
        BOOL valid = !error && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 && (mime.length == 0 || [mime hasPrefix:@"image/"]);
        UIImage *artworkImage = valid ? [UIImage imageWithData:data] : nil;
        if (!artworkImage) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.musicDict[@"music"][@"artwork"] isEqualToString:artworkURL.absoluteString]) return;
            [UIView transitionWithView:self.artworkImageView duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                [self.artworkImageView setImage:artworkImage];
            } completion:nil];
        });
    }];
    [artworkTask resume];
}
@end
