#import "BeaMusicManager.h"

NSString *const BeaMusicStatusNotification = @"BeaMusicStatus";

@interface BeaMusicManager ()
@property (nonatomic, copy) NSString *providerStatus;
@end

@implementation BeaMusicManager
+ (instancetype)sharedInstance {
    static BeaMusicManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)updateCurrentlyPlaying:(NSDictionary *)musicDict {
    if ([self.musicDict isEqual:musicDict]) return;

    self.musicDict = [musicDict mutableCopy];

    if ([musicDict[@"music"][@"artist"] isEqual:@""] || [musicDict[@"music"][@"track"] isEqual:@""]) {
        [self setPlayingStatus:0];
    } else {
        [self setPlayingStatus:1];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"MusicUpdated" object:nil];
}



- (void)reportProviderStatus:(NSString *)message {
    if (message == self.providerStatus || [message isEqualToString:self.providerStatus]) return;
    self.providerStatus = message;
    [[NSNotificationCenter defaultCenter] postNotificationName:BeaMusicStatusNotification object:message];
}

- (void)clearAttachmentForProvider:(NSString *)provider {
    if (provider.length == 0) return;
    if (![self.musicDict[@"music"][@"provider"] isEqualToString:provider]) return;
    [self updateCurrentlyPlaying:@{ @"music": @{ @"artist": @"", @"track": @"" } }];
}

- (void)setMusicVisibility:(NSString *)visibility {
    if ([visibility isEqual:@"none"]) {
        // Dropping the dictionary on the floor was not enough: everything that
        // reads it (the composer's own copy, the widget, the picker) is driven
        // by the notification, and playingStatus stayed at 1 - so picking
        // "Disabled" left the track attached to the post it was meant to
        // remove it from.
        self.musicDict = nil;
        [self setPlayingStatus:0];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MusicUpdated" object:nil];
        return;
    }

    NSMutableDictionary *mutableMusicDict = [self.musicDict[@"music"] mutableCopy];
    if (!mutableMusicDict) return;
    [mutableMusicDict setValue:visibility forKey:@"visibility"];
    [self.musicDict setObject:mutableMusicDict forKey:@"music"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MusicUpdated" object:nil];
}

- (void)resetData {
    self.musicDict = nil;
    self.artist = nil;
    self.track = nil;
}
@end