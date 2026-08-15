#import <UIKit/UIKit.h>
#import "../TokenManager/BeaTokenManager.h"

@interface BeaUploadTask : NSObject
- (instancetype)initWithData:(NSDictionary *)data frontImage:(UIImage *)frontImage backImage:(UIImage *)backImage;
@property (nonatomic, retain) NSData *frontImageData;
@property (nonatomic, retain) NSData *backImageData;
@property (nonatomic, strong) NSDictionary *userDictionary;
@property (nonatomic, strong) NSString *takenAt;
@property (nonatomic, strong) NSString *lastMoment;
@property (nonatomic, strong) NSString *region;
@property (nonatomic, strong) NSDictionary *headers;
// Pixel dimensions of what was actually encoded and PUT, recorded at init
// time. The create-post payload has to describe the media it references, and
// hardcoding 1500x2000 there was wrong for any source photo whose aspect ratio
// didn't match - resizeImage:toSize: deliberately preserves aspect ratio and
// returns something else in that case.
@property (nonatomic, assign) CGSize frontImageSize;
@property (nonatomic, assign) CGSize backImageSize;
- (void)uploadBeRealWithCompletion:(void (^)(BOOL success, NSError *error))completion;
- (void)makePUTRequestWithData:(NSDictionary *)data completion:(void (^)(BOOL success, NSError *error))completion;
- (void)putPhotoWithURL:(NSURL *)url headers:(NSDictionary *)headers imageData:(NSData *)imageData completion:(void (^)(BOOL success))completion;
- (void)postBeRealWithFrontPath:(NSString *)frontPath backPath:(NSString *)backPath frontBucket:(NSString *)frontBucket backBucket:(NSString *)backBucket completion:(void (^)(BOOL success, NSError *error))completion;
// Region then last moment, in that order, both before anything is uploaded -
// postBeRealWithFrontPath:... reads self.lastMoment to backdate a non-late
// post into the current moment's window, and firing these off in parallel with
// the upload (as this used to) meant that read raced the fetch and usually
// lost. `completion` always runs exactly once, including on failure: a missing
// region or moment is not fatal, it just means takenAt falls back to "now".
- (void)prepareMomentContextWithCompletion:(void (^)(void))completion;
- (void)handleErrorWithTitle:(NSString *)title message:(NSString *)message completion:(void (^)(BOOL success, NSError *error))completion;
@end