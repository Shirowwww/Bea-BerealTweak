#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <rootless.h>
#import "../../Music/SpotifyImports.h"
#import "../LocationViewController/BeaLocationViewController.h"
#import "../InfoViewController/BeaInfoViewController.h"
#import "../../UploadTask/BeaUploadTask.h"
#import "../../Views/StatusView/BeaStatusView.h"
#import "../../Views/SpotifyMusicView/BeaSpotifyMusicView.h"
#import "../../Music/Managers/MusicManager/BeaMusicManager.h"

@interface BeaUploadViewController : UIViewController <UINavigationControllerDelegate, UIImagePickerControllerDelegate, UITextFieldDelegate, BeaLocationViewControllerDelegate, CLLocationManagerDelegate>
@property (nonatomic, strong) BeaLocationViewController *locationVC;

// Fills the location row in from where the phone actually is, so posting from
// the composer doesn't mean opening the map and dropping a pin by hand every
// time. Only ever a starting point: tapping the pin still opens the map, and
// turning the location off there (which reports 0,0) sets
// locationChosenManually so the automatic lookup never overrides that choice
// again for this session.
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, assign) BOOL locationChosenManually;
@property (nonatomic, strong) UIImageView *frontImageView;
@property (nonatomic, strong) UIImageView *backImageView;
@property (nonatomic, strong) UILabel *frontTextLabel;
@property (nonatomic, strong) UILabel *backTextLabel;
@property (nonatomic, strong) UIImage *frontImage;
@property (nonatomic, strong) UIImage *backImage;
@property (nonatomic, strong) UITextField *captionTextField;
@property (nonatomic, strong) NSString *caption;
@property (nonatomic, strong) UITextField *retakeTextField;
@property (nonatomic, strong) NSNumber *retakeCount;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) BeaStatusView *statusView;
@property (nonatomic, strong) UIButton *locationButton;
@property (nonatomic, strong) UILabel *locationLabel;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (nonatomic, strong) UIImageView *titleImageView;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIImageView *backButtonImageView;
@property (nonatomic, strong) UISwitch *isLateSwitch;
@property (nonatomic, strong) UILabel *isLateLabel;
@property (nonatomic, assign) BOOL isLate;
@property (nonatomic, strong) UIButton *dropdownButton;
@property (nonatomic, strong) UIImageView *dropdownImageView;
@property (nonatomic, strong) NSDictionary *musicDict;
@property (nonatomic, strong) BeaSpotifyViewController *spotifyViewController;
@property (nonatomic, strong) BeaSpotifyMusicView *spotifyMusicView;

// Everything between the fixed header (logo/close/overflow) and the fixed
// footer (status banner + Send) lives inside this scroll view. Without it the
// options below the caption field are unreachable on a short screen once the
// keyboard is up - and the option list grew when the audience picker was
// added.
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

// Audience for the post. BeReal's own API takes this as an array of strings on
// the create-post payload; see BeaUploadTask.m for the exact values and
// -visibilityValue below for the mapping from the segment index.
@property (nonatomic, strong) UILabel *visibilityLabel;
@property (nonatomic, strong) UISegmentedControl *visibilityControl;

// Swaps whichever photos are currently loaded between the two slots, so a pair
// picked in the wrong order doesn't have to be re-picked one at a time.
@property (nonatomic, strong) UIButton *swapButton;
@end