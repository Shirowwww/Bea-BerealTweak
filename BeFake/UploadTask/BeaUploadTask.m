#import "BeaUploadTask.h"
#import "../../Utilities/Localization/BeaLocalization.h"

// Internal steps of the upload sequence, kept out of the header - only
// -uploadBeRealWithCompletion: and -prepareMomentContextWithCompletion: are
// meant to be called from outside.
@interface BeaUploadTask ()
- (void)startUploadWithCompletion:(void (^)(BOOL success, NSError *error))completion;
- (void)fetchLastMomentWithCompletion:(void (^)(void))completion;
- (NSString *)describeFailureWithPrefix:(NSString *)prefix response:(NSURLResponse *)response body:(NSDictionary *)body error:(NSError *)error;
@end

@implementation BeaUploadTask
NSData* compressImage(UIImage *image, NSUInteger targetDataSize) {
    CGFloat compressionFactor = 1.0;
    NSData *imageData = UIImageJPEGRepresentation(image, compressionFactor);

    // if the current data length is below the target's size return the image
    if (imageData.length < targetDataSize) {
        return imageData;
    }
    
    while (imageData.length > targetDataSize && compressionFactor > 0.0) {
        compressionFactor -= 0.1;
        imageData = UIImageJPEGRepresentation(image, compressionFactor);
    }
    
    return imageData;
}

- (UIImage *)resizeImage:(UIImage *)image toSize:(CGSize)size {
    CGFloat aspectRatio = image.size.width / image.size.height;
    CGFloat targetRatio = size.width / size.height;
    CGFloat deviation = fabs(aspectRatio - targetRatio);

    if (deviation > 0.1) {
        size = CGSizeMake(size.width, size.width / aspectRatio);
    }

    // Scale 1.0, not image.scale: the context's scale multiplies into the
    // encoded bitmap, so a 3x screen scale turned a "1500x2000" resize into a
    // 4500x6000 JPEG - three times the pixels squeezed under the same 1 MB
    // budget (so visibly worse), and still described to the API as 1500x2000.
    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage;
}

- (instancetype)initWithData:(NSDictionary *)data frontImage:(UIImage *)frontImage backImage:(UIImage *)backImage {
    self = [super init];
    if (self) {
        self.userDictionary = data;

        self.headers = [[BeaTokenManager sharedInstance] headers];

        UIImage *resizedFrontImage = [self resizeImage:frontImage toSize:CGSizeMake(1500, 2000)];
        UIImage *resizedBackImage = [self resizeImage:backImage toSize:CGSizeMake(1500, 2000)];

        self.frontImageSize = resizedFrontImage.size;
        self.backImageSize = resizedBackImage.size;

        self.frontImageData = compressImage(resizedFrontImage, 1048576);
        self.backImageData = compressImage(resizedBackImage, 1048576);
    }
    return self;
}

- (void)handleErrorWithTitle:(NSString *)title message:(NSString *)message completion:(void (^)(BOOL success, NSError *error))completion {
    NSError *error = [NSError errorWithDomain:@"com.yan.bea" code:0 userInfo:@{ @"title":title, @"description":message }];
    completion(NO, error);
}

- (void)uploadBeRealWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    // Region and last moment first, then the upload - see the comment on
    // -prepareMomentContextWithCompletion: in the header for why these cannot
    // run alongside it.
    [self prepareMomentContextWithCompletion:^{
        [self startUploadWithCompletion:completion];
    }];
}

- (void)startUploadWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    // create the first request
    NSURL *uploadRequestURL = [NSURL URLWithString:@"https://mobile-l7.bereal.com/api/content/posts/upload-url?mimeType=image/webp"];
    NSMutableURLRequest *uploadRequest = [NSMutableURLRequest requestWithURL:uploadRequestURL];
    [uploadRequest setHTTPMethod:@"GET"];

    [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [uploadRequest setValue:value forHTTPHeaderField:field];
    }];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *uploadRequestTask = [session dataTaskWithRequest:uploadRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *getError) {
        NSDictionary *uploadRequestResponse = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![uploadRequestResponse isKindOfClass:[NSDictionary class]] || uploadRequestResponse[@"error"] || getError) {
            NSString *message = [self describeFailureWithPrefix:BeaLocalized(@"upload.error_could_not_start")
                                                       response:response
                                                           body:uploadRequestResponse
                                                          error:getError];
            [self handleErrorWithTitle:BeaLocalized(@"upload.error_title") message:message completion:completion];
        } else {
            [self makePUTRequestWithData:uploadRequestResponse completion:completion];
        }
    }];

    [uploadRequestTask resume];

}

- (void)makePUTRequestWithData:(NSDictionary *)response completion:(void (^)(BOOL success, NSError *error))completion {
    // The old `if (!response) return;` stranded the caller: with no completion
    // call the Send button stays disabled and the spinner runs forever. Every
    // exit from this method now reports something.
    NSArray *entries = [response[@"data"] isKindOfClass:[NSArray class]] ? response[@"data"] : nil;
    if (entries.count < 2) {
        [self handleErrorWithTitle:BeaLocalized(@"upload.error_title")
                           message:BeaLocalized(@"upload.error_missing_slots")
                        completion:completion];
        return;
    }

    NSString *frontCameraURLString = response[@"data"][0][@"url"];
    NSString *backCameraURLString = response[@"data"][1][@"url"];

    NSURL *frontCameraURL = [NSURL URLWithString:frontCameraURLString];
    NSURL *backCameraURL = [NSURL URLWithString:backCameraURLString];
    
    // those headers have to be included in the next put request 
    NSDictionary *frontHeaders = response[@"data"][0][@"headers"];
    NSDictionary *backHeaders = response[@"data"][1][@"headers"];

    NSString *frontImageUploadPath = response[@"data"][0][@"path"];
    NSString *backImageUploadPath = response[@"data"][1][@"path"];

    NSString *frontImageBucket = response[@"data"][0][@"bucket"];
    NSString *backImageBucket = response[@"data"][1][@"bucket"];
    
    // otherwise the postbereal function would get called even if one of the put requests didnt succeed.
    // Both completion blocks always leave the group, success or failure - an
    // early return that skipped dispatch_group_leave would permanently block
    // dispatch_group_notify below, leaving the upload UI stuck. Failure is
    // instead tracked explicitly and checked once both PUTs have finished.
    dispatch_group_t group = dispatch_group_create();
    __block BOOL frontSucceeded = NO;
    __block BOOL backSucceeded = NO;

    dispatch_group_enter(group);
    [self putPhotoWithURL:frontCameraURL headers:frontHeaders imageData:self.frontImageData completion:^(BOOL success) {
        frontSucceeded = success;
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [self putPhotoWithURL:backCameraURL headers:backHeaders imageData:self.backImageData completion:^(BOOL success) {
        backSucceeded = success;
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (!frontSucceeded || !backSucceeded) {
            [self handleErrorWithTitle:BeaLocalized(@"upload.error_title") message:BeaLocalized(@"upload.error_photo_failed") completion:completion];
            return;
        }
        [self postBeRealWithFrontPath:frontImageUploadPath backPath:backImageUploadPath frontBucket:frontImageBucket backBucket:backImageBucket completion:completion];
    });
}

- (void)putPhotoWithURL:(NSURL *)url headers:(NSDictionary *)headers imageData:(NSData *)imageData completion:(void (^)(BOOL success))completion {

    NSMutableURLRequest *putRequest = [NSMutableURLRequest requestWithURL:url];
    [putRequest setHTTPMethod:@"PUT"];
    [putRequest setAllHTTPHeaderFields:headers];

    NSURLSessionTask *task = [[NSURLSession sharedSession] uploadTaskWithRequest:putRequest fromData:imageData completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || httpResponse.statusCode > 299) {
            completion(NO);
            return;
        }

        // A pre-signed-URL PUT commonly succeeds with an empty body (data ==
        // nil/zero-length) - gating success on a non-nil body meant a
        // legitimate 2xx response could leave completion never called at
        // all, which - see makePUTRequestWithData: above - hung the whole
        // upload. Any status under 300 is success regardless of body.
        completion(YES);
    }];
    
    [task resume];
}

- (void)postBeRealWithFrontPath:(NSString *)frontPath backPath:(NSString *)backPath frontBucket:(NSString *)frontBucket backBucket:(NSString *)backBucket completion:(void (^)(BOOL success, NSError *error))completion {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSXXX"];
    [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];

    if (![self.userDictionary[@"isLate"] boolValue] && self.lastMoment) {
        // randomize the taken at to be between the startDate and endDate because its
        // logically impossible to "post" on the start time
        NSDate *moment = [dateFormatter dateFromString:self.lastMoment];
        NSInteger randomSeconds = arc4random_uniform(105 - 60) + 60;
        NSDate *dateInRange = [moment dateByAddingTimeInterval:randomSeconds];
        NSString *dateString = [dateFormatter stringFromDate:dateInRange];
        self.takenAt = dateString;
    } else {
        NSDate *currentDate = [NSDate date];
        self.takenAt = [dateFormatter stringFromDate:currentDate];
    }
    
    // Audience comes from the picker on the upload screen; "friends" stays both
    // the default and the fallback, since that is what this always sent before.
    NSString *visibility = [self.userDictionary[@"visibility"] isKindOfClass:[NSString class]] ? self.userDictionary[@"visibility"] : @"friends";

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"visibility": @[visibility],
        @"isLate": @([self.userDictionary[@"isLate"] boolValue]),
        @"retakeCounter": self.userDictionary[@"retakeCounter"] ?: @0,
        @"takenAt": self.takenAt,
        @"backCamera": @{
            @"bucket": backBucket,
            @"height": @((NSInteger)lround(self.backImageSize.height)),
            @"width": @((NSInteger)lround(self.backImageSize.width)),
            @"path": backPath
        },
        @"frontCamera": @{
            @"bucket": frontBucket,
            @"height": @((NSInteger)lround(self.frontImageSize.height)),
            @"width": @((NSInteger)lround(self.frontImageSize.width)),
            @"path": frontPath
        }
    }];

    if (self.userDictionary[@"music"]) {
        [payload setObject:self.userDictionary[@"music"] forKey:@"music"];
    }

    if (self.userDictionary[@"longitude"] && self.userDictionary[@"latitude"]) {
        NSDictionary *locationDict = @{
            @"latitude": self.userDictionary[@"latitude"],
            @"longitude": self.userDictionary[@"longitude"]
        };
        [payload setObject:locationDict forKey:@"location"];
    }

    if (self.userDictionary[@"caption"]) {
        [payload setObject:self.userDictionary[@"caption"] forKey:@"caption"];
    }

    NSData *payloadJSON = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingWithoutEscapingSlashes error:nil];

    NSURL *postBeRealURL = [NSURL URLWithString:@"https://mobile-l7.bereal.com/api/content/posts"];
    NSMutableURLRequest *postBeRealRequest = [NSMutableURLRequest requestWithURL:postBeRealURL];

    [postBeRealRequest setHTTPMethod:@"POST"];

    [postBeRealRequest setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [postBeRealRequest setValue:value forHTTPHeaderField:field];
    }];

    NSURLSessionUploadTask *uploadTask = [[NSURLSession sharedSession] uploadTaskWithRequest:postBeRealRequest fromData:payloadJSON completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSDictionary *responseDictionary = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![responseDictionary isKindOfClass:[NSDictionary class]]) responseDictionary = nil;

        if (error || httpResponse.statusCode > 299) {
            NSString *message = [self describeFailureWithPrefix:BeaLocalized(@"upload.error_rejected")
                                                       response:response
                                                           body:responseDictionary
                                                          error:error];
            [self handleErrorWithTitle:BeaLocalized(@"upload.api_error_title") message:message completion:completion];
            return;
        }

        // A 2xx with an empty body is still a success. The old check gated this
        // on a non-nil body, so such a response called completion neither way
        // and left the Send button disabled with the spinner still running.
        completion(YES, nil);
    }];

    [uploadTask resume];
}

// Says what actually went wrong. The previous version formatted three keys
// unconditionally, so a failure carrying none of them - a transport error, an
// HTML error page, a bare 5xx - rendered as the literal "(null), (null), (null)".
- (NSString *)describeFailureWithPrefix:(NSString *)prefix response:(NSURLResponse *)response body:(NSDictionary *)body error:(NSError *)error {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    if (statusCode > 0) [parts addObject:[NSString stringWithFormat:@"HTTP %ld", (long)statusCode]];

    for (NSString *key in @[@"message", @"errorKey", @"error"]) {
        id value = body[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            [parts addObject:value];
            break;
        }
    }

    if (error.localizedDescription.length > 0) [parts addObject:error.localizedDescription];

    if (parts.count == 0) return prefix;
    return [NSString stringWithFormat:@"%@ (%@)", prefix, [parts componentsJoinedByString:@" - "]];
}

- (void)prepareMomentContextWithCompletion:(void (^)(void))completion {
    if (!completion) return;

    NSURL *meURL = [NSURL URLWithString:@"https://mobile-l7.bereal.com/api/person/me"];
    NSMutableURLRequest *regionRequest = [NSMutableURLRequest requestWithURL:meURL];

    [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [regionRequest setValue:value forHTTPHeaderField:field];
    }];

    NSURLSessionDataTask *regionRequestTask = [[NSURLSession sharedSession] dataTaskWithRequest:regionRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        id body = (!error && httpResponse.statusCode == 200 && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id region = [body isKindOfClass:[NSDictionary class]] ? body[@"region"] : nil;

        if (![region isKindOfClass:[NSString class]] || [region length] == 0) {
            // Without a region there is no moment to look up. Not fatal - the
            // post just ends up with takenAt = now.
            completion();
            return;
        }

        self.region = region;
        [self fetchLastMomentWithCompletion:completion];
    }];

    [regionRequestTask resume];
}

- (void)fetchLastMomentWithCompletion:(void (^)(void))completion {
    NSURL *lastMomentURL = [NSURL URLWithString:@"https://mobile-l7.bereal.com/api/bereal/moments/last/"];
    lastMomentURL = [lastMomentURL URLByAppendingPathComponent:self.region];

    NSMutableURLRequest *lastMomentRequest = [NSMutableURLRequest requestWithURL:lastMomentURL];
    [lastMomentRequest setHTTPMethod:@"GET"];

    [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [lastMomentRequest setValue:value forHTTPHeaderField:field];
    }];

    NSURLSessionDataTask *lastMomentRequestTask = [[NSURLSession sharedSession] dataTaskWithRequest:lastMomentRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (!error && httpResponse.statusCode == 200 && data) {
            id lastMomentResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([lastMomentResponse isKindOfClass:[NSDictionary class]] && [lastMomentResponse[@"startDate"] isKindOfClass:[NSString class]]) {
                self.lastMoment = lastMomentResponse[@"startDate"];
            }
        }
        completion();
    }];

    [lastMomentRequestTask resume];
}
@end