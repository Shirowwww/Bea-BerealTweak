#import "BeaSongSearchViewController.h"
#import "../../../../Utilities/Localization/BeaLocalization.h"
#import "../../../../Utilities/Debug/BeaDebug.h"

@implementation BeaSongSearchViewController
- (void)viewDidLoad {
    [super viewDidLoad];

    self.imageCache = [[NSCache alloc] init];
    // totalCostLimit only ever bounds anything if entries are added with a
    // per-item cost (setObject:forKey:cost:) - this cache uses the costless
    // setObject:forKey: below, so a cost limit of 10 never evicted anything.
    // countLimit is the right knob for "cap the number of cached artworks".
    self.imageCache.countLimit = 10;

    self.contentContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentContainer.layer.cornerRadius = 8.0;
    self.contentContainer.clipsToBounds = YES;
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentContainer];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.delegate = self;
    self.searchBar.barTintColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.06 alpha:1.00];
    self.searchBar.placeholder = BeaLocalized(@"music.search_placeholder");
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.searchBar];

    // Spotify is only offered when BeReal has actually handed us a token for
    // it; without one the segment would just be a button that always fails.
    BOOL spotifyAvailable = [[BeaTokenManager sharedInstance] spotifyAccessToken].length > 0;
    self.providerControl = [[UISegmentedControl alloc] initWithItems:@[
        BeaLocalized(@"music.provider_apple"),
        BeaLocalized(@"music.provider_spotify")
    ]];
    self.providerControl.selectedSegmentIndex = 0;
    [self.providerControl setEnabled:spotifyAvailable forSegmentAtIndex:1];
    [self.providerControl addTarget:self action:@selector(providerChanged) forControlEvents:UIControlEventValueChanged];
    self.providerControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.providerControl];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.06 alpha:1.00];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.tableView];

    // A search that returns nothing has to say so. The version before this one
    // logged the failure with NSLog and left an empty table on screen, which
    // reads exactly like "this feature does nothing".
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.hidden = YES;
    [self.contentContainer addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentContainer.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.75],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:4],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        
        [self.providerControl.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:6],
        [self.providerControl.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.providerControl.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],

        [self.tableView.topAnchor constraintEqualToAnchor:self.providerControl.bottomAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.tableView.topAnchor constant:24],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-24]
    ]];
}

- (void)providerChanged {
    if (self.searchBar.text.length > 0) [self performSearchWithKeyword:self.searchBar.text];
}

- (void)showResults:(NSArray *)results emptyMessage:(NSString *)emptyMessage {
    self.searchResults = results;
    self.statusLabel.text = emptyMessage;
    self.statusLabel.hidden = results.count > 0;
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self performSearchWithKeyword:searchBar.text];
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self showResults:@[] emptyMessage:nil];
}

- (void)performSearchWithKeyword:(NSString *)keyword {
    if (self.providerControl.selectedSegmentIndex == 1) {
        [self performSpotifySearchWithKeyword:keyword];
    } else {
        [self performAppleMusicSearchWithKeyword:keyword];
    }
}

- (void)performAppleMusicSearchWithKeyword:(NSString *)keyword {
    [BeaAppleMusicManager searchCatalogForTerm:keyword completion:^(NSArray<NSDictionary *> *results) {
        [self showResults:results emptyMessage:BeaLocalized(@"music.search_no_results")];
    }];
}

- (void)performSpotifySearchWithKeyword:(NSString *)keyword {
    NSString *accessToken = [[BeaTokenManager sharedInstance] spotifyAccessToken];
    if (accessToken.length == 0) {
        [self showResults:@[] emptyMessage:BeaLocalized(@"music.spotify_not_linked")];
        return;
    }

    NSString *query = [keyword stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *apiUrl = [NSString stringWithFormat:@"https://api.spotify.com/v1/search?q=%@&type=track&limit=25", query];
    NSURL *url = [NSURL URLWithString:apiUrl];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *dataTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || httpResponse.statusCode != 200) {
            // A failed search used to go to NSLog and leave an empty table, so
            // an expired token and "no such song" looked identical on screen.
            BeaLog("[BeaMusic] spotify search failed status=%{public}ld error=%{public}@",
                (long)httpResponse.statusCode, error.localizedDescription ?: @"(none)");
            NSString *message = httpResponse.statusCode == 401
                ? BeaLocalized(@"music.token_expired")
                : BeaLocalized(@"music.search_failed");
            dispatch_async(dispatch_get_main_queue(), ^{ [self showResults:@[] emptyMessage:message]; });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

        NSArray *tracks = json[@"tracks"][@"items"];
        NSMutableArray *results = [NSMutableArray array];

        for (NSDictionary *track in tracks) {
            if (![track isKindOfClass:[NSDictionary class]]) continue;
            NSString *artist = [track[@"album"][@"artists"] firstObject][@"name"];
            NSString *artwork = [track[@"album"][@"images"] firstObject][@"url"];
            NSString *isrc = track[@"external_ids"][@"isrc"];
            NSString *audioType = track[@"type"];
            NSString *openUrl = track[@"external_urls"][@"spotify"];
            NSString *providerId = track[@"id"];
            NSString *trackName = track[@"name"];
            // BeReal's PostMusicDto calls it `preview` and the feed needs it to
            // play anything at all; Spotify calls the same thing preview_url
            // and it is null for a fair number of tracks, hence the ?: "".
            NSString *preview = track[@"preview_url"];
            if (![preview isKindOfClass:[NSString class]]) preview = @"";
            if (trackName.length == 0 || artist.length == 0) continue;

            [results addObject:@{
                @"music" : @{
                    @"artist" : artist,
                    @"artwork" : artwork ?: @"",
                    @"audioType" : audioType ?: @"track",
                    @"isrc" : isrc ?: @"",
                    @"preview" : preview,
                    @"openUrl" : openUrl ?: @"",
                    @"provider" : @"spotify",
                    @"providerId" : providerId ?: @"",
                    @"track" : trackName,
                    @"visibility" : @"public"
                }
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self showResults:results emptyMessage:BeaLocalized(@"music.search_no_results")];
        });
    }];

    [dataTask resume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.searchResults.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SearchResultCell"];

    UIImageView *artworkImageView;
    UILabel *trackLabel;
    UILabel *artistLabel;

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SearchResultCell"];

        cell.contentView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.06 alpha:1.00];

        artworkImageView = [[UIImageView alloc] init];
        artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
        artworkImageView.layer.cornerRadius = 4.0;
        artworkImageView.clipsToBounds = YES;
        artworkImageView.tag = 1;
        [cell.contentView addSubview:artworkImageView];

        trackLabel = [[UILabel alloc] init];
        trackLabel.translatesAutoresizingMaskIntoConstraints = NO;
        trackLabel.font = [UIFont fontWithName:@"Inter" size:17];
        trackLabel.tag = 2;
        [cell.contentView addSubview:trackLabel];

        artistLabel = [[UILabel alloc] init];
        artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        artistLabel.font = [UIFont systemFontOfSize:13];
        artistLabel.tag = 3;
        [cell.contentView addSubview:artistLabel];

        [NSLayoutConstraint activateConstraints:@[
            [artworkImageView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [artworkImageView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [artworkImageView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [artworkImageView.widthAnchor constraintEqualToConstant:58],
            [artworkImageView.heightAnchor constraintEqualToConstant:58],

            [trackLabel.leadingAnchor constraintEqualToAnchor:artworkImageView.trailingAnchor constant:10],
            [trackLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [trackLabel.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:20],

            [artistLabel.leadingAnchor constraintEqualToAnchor:artworkImageView.trailingAnchor constant:10],
            [artistLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [artistLabel.topAnchor constraintEqualToAnchor:trackLabel.bottomAnchor constant:5],
            [artistLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-20],
        ]];
    } else {
        artworkImageView = (UIImageView *)[cell.contentView viewWithTag:1];
        trackLabel = (UILabel *)[cell.contentView viewWithTag:2];
        artistLabel = (UILabel *)[cell.contentView viewWithTag:3];
    }

    NSDictionary *searchResult = self.searchResults[indexPath.row][@"music"];

    NSString *artist = searchResult[@"artist"];
    NSString *track = searchResult[@"track"];

    trackLabel.text = track;
    artistLabel.text = artist;

    NSString *imageUrlString = searchResult[@"artwork"];

    // check if the image is already cached
    UIImage *cachedImage = [self.imageCache objectForKey:imageUrlString];
    if (cachedImage) {
        artworkImageView.image = cachedImage;
    } else {
        artworkImageView.image = nil;

        NSURL *imageURL = [NSURL URLWithString:imageUrlString];
        if (imageURL) {
        NSURLSessionDataTask *imageTask = [[NSURLSession sharedSession] dataTaskWithURL:imageURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSString *mime = response.MIMEType.lowercaseString ?: @"";
            BOOL valid = !error && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 && (mime.length == 0 || [mime hasPrefix:@"image/"]);
            UIImage *artworkImage = valid ? [UIImage imageWithData:data] : nil;

            if (artworkImage) [self.imageCache setObject:artworkImage forKey:imageUrlString];

            dispatch_async(dispatch_get_main_queue(), ^{
                // Ensure that both the index path and the URL still belong to
                // this cell; SwiftUI/UIKit can recycle the row while the
                // request is in flight.
                if (artworkImage && [tableView.indexPathsForVisibleRows containsObject:indexPath] && [self.searchResults[indexPath.row][@"music"][@"artwork"] isEqualToString:imageUrlString]) {
                    [UIView transitionWithView:artworkImageView duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                        artworkImageView.image = artworkImage;
                    } completion:nil];
                }
            });
        }];
        [imageTask resume];
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *results = self.searchResults[indexPath.row];
    [[BeaMusicManager sharedInstance] updateCurrentlyPlaying:results];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"StopUpdatingCurrentlyPlaying" object:nil];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
