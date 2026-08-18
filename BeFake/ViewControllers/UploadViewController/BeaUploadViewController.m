#import "BeaUploadViewController.h"
#import <objc/runtime.h>
#import "../../../Utilities/Localization/BeaLocalization.h"

@implementation BeaUploadViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.locationVC = [[BeaLocationViewController alloc] init];
        self.locationVC.delegate = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    #ifdef JAILED
		NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"Bea" ofType:@"bundle"];
		NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
		UIImage *beFakeLogo = [UIImage imageWithContentsOfFile:[bundle pathForResource:@"BeFake" ofType:@"png"]];
	#else
		NSBundle *bundle = [NSBundle bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/Bea.bundle")];
		UIImage *beFakeLogo = [UIImage imageNamed:@"BeFake.png" inBundle:bundle compatibleWithTraitCollection:nil];
	#endif


    self.view.backgroundColor = [UIColor blackColor];
    self.spotifyViewController = [[BeaSpotifyViewController alloc] init];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    // So a tap anywhere in the option list dismisses the keyboard. -touchesBegan:
    // below never fires for taps that land on the scroll view itself.
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(musicManagerDidUpdateMusic) name:@"MusicUpdated" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showMusicViewController) name:@"openSpotifyViewController" object:nil];

    self.titleImageView = [[UIImageView alloc] initWithImage:beFakeLogo];
    self.titleImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.titleImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleImageView];

    self.backButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backButton addTarget:self action:@selector(dismissViewController) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.backButton];

    UIImage *backButtonImage = [[UIImage systemImageNamed:@"chevron.down"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.backButtonImageView = [[UIImageView alloc] initWithImage:backButtonImage];
    self.backButtonImageView.tintColor = [UIColor whiteColor];
    self.backButtonImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backButton addSubview:self.backButtonImageView];

    self.statusView = [[BeaStatusView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.statusView];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;

    self.frontImageView = [[UIImageView alloc] init];
    self.frontImageView.backgroundColor = [UIColor blackColor];
    self.frontImageView.layer.borderWidth = 1.8;
    self.frontImageView.layer.cornerRadius = 8.0;
    self.frontImageView.layer.masksToBounds = YES;
    self.frontImageView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.frontImageView.userInteractionEnabled = YES;
    self.frontImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.frontImageView.translatesAutoresizingMaskIntoConstraints = NO;
    
    UITapGestureRecognizer *frontTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageViewTapped:)];
    [self.frontImageView addGestureRecognizer:frontTapRecognizer];

    [self.contentView addSubview:self.frontImageView];

    self.frontTextLabel = [[UILabel alloc] init];
    self.frontTextLabel.font = [UIFont fontWithName:@"Inter" size:14];
    self.frontTextLabel.text = BeaLocalized(@"upload.front_image");
    self.frontTextLabel.textAlignment = NSTextAlignmentCenter;
    self.frontTextLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.frontImageView addSubview:self.frontTextLabel];

    self.backImageView = [[UIImageView alloc] init];
    self.backImageView.backgroundColor = [UIColor blackColor];
    self.backImageView.layer.borderWidth = 1.8;
    self.backImageView.layer.cornerRadius = 8.0;
    self.backImageView.layer.masksToBounds = YES;
    self.backImageView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.backImageView.userInteractionEnabled = YES;
    self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backImageView.translatesAutoresizingMaskIntoConstraints = NO;
    
    UITapGestureRecognizer *backTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageViewTapped:)];
    [self.backImageView addGestureRecognizer:backTapRecognizer];
    [self.contentView addSubview:self.backImageView];

    self.backTextLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.backTextLabel.font = [UIFont fontWithName:@"Inter" size:14];
    self.backTextLabel.text = BeaLocalized(@"upload.back_image");
    self.backTextLabel.textAlignment = NSTextAlignmentCenter;
    self.backTextLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backImageView addSubview:self.backTextLabel];

    self.captionTextField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.captionTextField.placeholder = BeaLocalized(@"upload.caption");
    self.captionTextField.font = [UIFont fontWithName:@"Inter" size:13];
    self.captionTextField.backgroundColor = [UIColor blackColor];
    self.captionTextField.layer.cornerRadius = 8.0;
    self.captionTextField.layer.borderWidth = 1.2;
    self.captionTextField.layer.borderColor = [UIColor whiteColor].CGColor;
    self.captionTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.captionTextField.delegate = self;

    self.captionTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 40)];
    self.captionTextField.leftViewMode = UITextFieldViewModeAlways;

    // EditingChanged as well as EditingDidEnd: tapping Send does not resign the
    // caption field's first-responder status, so an EditingDidEnd-only binding
    // silently dropped the caption whenever the user typed one and hit Send
    // without dismissing the keyboard first. -sendBeReal re-reads both fields
    // directly too, as a second line of defence.
    [self.captionTextField addTarget:self action:@selector(captionTextFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.captionTextField addTarget:self action:@selector(captionTextFieldDidChange:) forControlEvents:UIControlEventEditingDidEnd];
    [self.contentView addSubview:self.captionTextField];

    self.retakeTextField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.retakeTextField.keyboardType = UIKeyboardTypeNumberPad;
    self.retakeTextField.placeholder = BeaLocalized(@"upload.retakes");
    self.retakeTextField.font = [UIFont fontWithName:@"Inter" size:13];
    self.retakeTextField.backgroundColor = [UIColor blackColor];
    self.retakeTextField.layer.cornerRadius = 8.0;
    self.retakeTextField.layer.borderWidth = 1.2;
    self.retakeTextField.layer.borderColor = [UIColor whiteColor].CGColor;
    self.retakeTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.retakeTextField.delegate = self;

    self.retakeTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 40)];
    self.retakeTextField.leftViewMode = UITextFieldViewModeAlways;

    [self.retakeTextField addTarget:self action:@selector(retakeTextFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.retakeTextField addTarget:self action:@selector(retakeTextFieldDidChange:) forControlEvents:UIControlEventEditingDidEnd];
    [self.contentView addSubview:self.retakeTextField];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.actionButton setTitle:BeaSharedCopy(@"general_send_button", @"upload.send") forState:UIControlStateNormal];
	[self.actionButton addTarget:self action:@selector(sendBeReal) forControlEvents:UIControlEventTouchUpInside];
	[self.actionButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	self.actionButton.backgroundColor = [UIColor whiteColor];
	self.actionButton.titleLabel.font = [UIFont fontWithName:@"Inter" size:17];
	self.actionButton.layer.cornerRadius = 8.0;
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.actionButton];

    self.locationLabel = [[UILabel alloc] init];
    self.locationLabel.font = [UIFont fontWithName:@"Inter" size:22];
    self.locationLabel.text = BeaSharedCopy(@"userprofile_location", @"upload.location");
    self.locationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.locationLabel];

    self.locationButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.locationButton.frame = CGRectMake(0, 0, 32, 32);
    self.locationButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.locationButton addTarget:self action:@selector(locationButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.locationButton];

    UIImage *image = [[UIImage systemImageNamed:@"mappin.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.tintColor = [UIColor whiteColor];
    imageView.frame = self.locationButton.bounds;
    [self.locationButton addSubview:imageView];

    self.isLateSwitch = [[UISwitch alloc] init];
    self.isLateSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.isLateSwitch addTarget:self action:@selector(isLateStateChanged:) forControlEvents:UIControlEventValueChanged];
    [self.isLateSwitch setOn:NO animated:NO];
    [self.contentView addSubview:self.isLateSwitch];

    self.isLateLabel = [[UILabel alloc] init];
    self.isLateLabel.font = [UIFont fontWithName:@"Inter" size:22];
    self.isLateLabel.text = BeaLocalized(@"upload.post_late");
    self.isLateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.isLateLabel];

    self.visibilityLabel = [[UILabel alloc] init];
    self.visibilityLabel.font = [UIFont fontWithName:@"Inter" size:22];
    self.visibilityLabel.text = BeaSharedCopy(@"audience", @"upload.audience");
    self.visibilityLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.visibilityLabel];

    // Titles are display-only; the wire values live in -visibilityValue so the
    // two can't drift apart the way two parallel string lists would.
    self.visibilityControl = [[UISegmentedControl alloc] initWithItems:@[
        BeaSharedCopy(@"bottom_bar_friends_title", @"upload.friends"),
        BeaSharedCopy(@"general_fof", @"upload.friends_of_friends"),
        BeaSharedCopy(@"camera_audience_row_everyone_title", @"upload.everyone")
    ]];
    self.visibilityControl.selectedSegmentIndex = 0;
    self.visibilityControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.visibilityControl.selectedSegmentTintColor = [UIColor whiteColor];
    [self.visibilityControl setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor whiteColor] } forState:UIControlStateNormal];
    [self.visibilityControl setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor blackColor] } forState:UIControlStateSelected];
    [self.contentView addSubview:self.visibilityControl];

    self.swapButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.swapButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.swapButton.tintColor = [UIColor whiteColor];
    [self.swapButton setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"] forState:UIControlStateNormal];
    [self.swapButton addTarget:self action:@selector(swapImages) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.swapButton];

    self.spotifyMusicView = [[BeaSpotifyMusicView alloc] init];
    [self.contentView addSubview:self.spotifyMusicView];

    self.dropdownButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.dropdownButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.dropdownButton];

    UIImage *dotImage = [[UIImage systemImageNamed:@"ellipsis"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    self.dropdownImageView = [[UIImageView alloc] initWithImage:dotImage];
    self.dropdownImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.dropdownImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.dropdownImageView setTintColor:[UIColor whiteColor]];
    [self.dropdownButton addSubview:self.dropdownImageView];

    NSMutableArray *actions = [[NSMutableArray alloc] init];
    [actions addObject:[UIAction actionWithTitle:BeaLocalized(@"upload.show_information") image:[UIImage systemImageNamed:@"info.circle.fill"] identifier:nil handler:^(UIAction * action) {
        BeaInfoViewController *infoViewController = [[BeaInfoViewController alloc] init];
        [self presentViewController:infoViewController animated:YES completion:nil];
	}]];

    NSString *donationImage;
    if (@available(iOS 16.0, *)) {
        donationImage = @"mug.fill";
    } else {
        donationImage = @"dollarsign.circle.fill";
    }

    [actions addObject:[UIAction actionWithTitle:BeaLocalized(@"upload.buy_coffee") image:[UIImage systemImageNamed:donationImage] identifier:nil handler:^(UIAction * action) {
		NSURL *kofiURL = [NSURL URLWithString:@"https://ko-fi.com/yandevelop"];
        if ([[UIApplication sharedApplication] canOpenURL:kofiURL]) {
            [[UIApplication sharedApplication] openURL:kofiURL options:@{} completionHandler:nil];
        }
	}]];

    UIMenu *menu = [UIMenu menuWithChildren:actions];
    [self.dropdownButton setShowsMenuAsPrimaryAction:true];
    [self.dropdownButton setMenu:menu];

    // Frame-independent replacement for the previous self.view.frame.size.width-
    // based constants below, which baked in whatever the view's frame happened
    // to be during viewDidLoad (before layout) and never updated on rotation/
    // size class changes. Splitting the view into two layout guides and
    // centering each image within its own half is declarative and keeps
    // working across both. The guides hang off contentView rather than the
    // controller's own view now that the options list scrolls.
    UILayoutGuide *leftHalfGuide = [[UILayoutGuide alloc] init];
    UILayoutGuide *rightHalfGuide = [[UILayoutGuide alloc] init];
    [self.contentView addLayoutGuide:leftHalfGuide];
    [self.contentView addLayoutGuide:rightHalfGuide];
    [NSLayoutConstraint activateConstraints:@[
        [leftHalfGuide.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [leftHalfGuide.trailingAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [rightHalfGuide.leadingAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [rightHalfGuide.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
    ]];

    // Header and footer stay pinned to the controller's own view; only the
    // options between them scroll. contentView is pinned to the scroll view's
    // contentLayoutGuide on all four edges (which is what gives the scroll view
    // a content size at all) and matched to the frameLayoutGuide's width only
    // (which is what keeps it from scrolling sideways).
    [NSLayoutConstraint activateConstraints:@[
        [self.titleImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.titleImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.titleImageView.heightAnchor constraintEqualToConstant:18],
        [self.titleImageView.widthAnchor constraintEqualToConstant:84],

        [self.backButton.centerYAnchor constraintEqualToAnchor:self.titleImageView.centerYAnchor],
        [self.backButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.backButton.widthAnchor constraintEqualToConstant:40],
        [self.backButton.heightAnchor constraintEqualToConstant:40],

        [self.backButtonImageView.centerYAnchor constraintEqualToAnchor:self.backButton.centerYAnchor],
        [self.backButtonImageView.widthAnchor constraintEqualToConstant:20],
        [self.backButtonImageView.heightAnchor constraintEqualToConstant:20],

        [self.dropdownButton.centerYAnchor constraintEqualToAnchor:self.titleImageView.centerYAnchor],
        [self.dropdownButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.dropdownButton.widthAnchor constraintEqualToConstant:40],
        [self.dropdownButton.heightAnchor constraintEqualToConstant:40],

        [self.dropdownImageView.trailingAnchor constraintEqualToAnchor:self.dropdownButton.trailingAnchor],
        [self.dropdownImageView.centerYAnchor constraintEqualToAnchor:self.dropdownButton.centerYAnchor],
        [self.dropdownImageView.widthAnchor constraintEqualToAnchor:self.dropdownButton.widthAnchor multiplier:0.57],
        [self.dropdownImageView.heightAnchor constraintEqualToAnchor:self.dropdownButton.heightAnchor multiplier:0.57],

        [self.actionButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.actionButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.actionButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.actionButton.heightAnchor constraintEqualToConstant:44],

        [self.statusView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.statusView.bottomAnchor constraintEqualToAnchor:self.actionButton.topAnchor constant:-20],

        [self.scrollView.topAnchor constraintEqualToAnchor:self.titleImageView.bottomAnchor constant:16],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.actionButton.topAnchor constant:-12],

        [self.contentView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.frontImageView.centerXAnchor constraintEqualToAnchor:leftHalfGuide.centerXAnchor constant:2],
        [self.frontImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.frontImageView.widthAnchor constraintEqualToConstant:150],
        [self.frontImageView.heightAnchor constraintEqualToConstant:200],
        [self.frontTextLabel.centerXAnchor constraintEqualToAnchor:self.frontImageView.centerXAnchor],
        [self.frontTextLabel.centerYAnchor constraintEqualToAnchor:self.frontImageView.centerYAnchor],

        [self.backImageView.centerXAnchor constraintEqualToAnchor:rightHalfGuide.centerXAnchor constant:-2],
        [self.backImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.backImageView.widthAnchor constraintEqualToConstant:150],
        [self.backImageView.heightAnchor constraintEqualToConstant:200],
        [self.backTextLabel.centerXAnchor constraintEqualToAnchor:self.backImageView.centerXAnchor],
        [self.backTextLabel.centerYAnchor constraintEqualToAnchor:self.backImageView.centerYAnchor],

        [self.swapButton.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.swapButton.centerYAnchor constraintEqualToAnchor:self.frontImageView.centerYAnchor],
        [self.swapButton.widthAnchor constraintEqualToConstant:36],
        [self.swapButton.heightAnchor constraintEqualToConstant:36],

        [self.captionTextField.topAnchor constraintEqualToAnchor:self.frontImageView.bottomAnchor constant:20],
        [self.captionTextField.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
        [self.captionTextField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-22],
        [self.captionTextField.heightAnchor constraintEqualToConstant:40],

        [self.retakeTextField.topAnchor constraintEqualToAnchor:self.captionTextField.bottomAnchor constant:20],
        [self.retakeTextField.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
        [self.retakeTextField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-22],
        [self.retakeTextField.heightAnchor constraintEqualToConstant:40],

        [self.visibilityLabel.topAnchor constraintEqualToAnchor:self.retakeTextField.bottomAnchor constant:26],
        [self.visibilityLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],

        [self.visibilityControl.topAnchor constraintEqualToAnchor:self.visibilityLabel.bottomAnchor constant:10],
        [self.visibilityControl.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
        [self.visibilityControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-22],

        [self.isLateSwitch.topAnchor constraintEqualToAnchor:self.visibilityControl.bottomAnchor constant:26],
        [self.isLateSwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-22],

        [self.isLateLabel.centerYAnchor constraintEqualToAnchor:self.isLateSwitch.centerYAnchor],
        [self.isLateLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],

        [self.locationButton.topAnchor constraintEqualToAnchor:self.isLateSwitch.bottomAnchor constant:20],
        [self.locationButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-22],
        [self.locationButton.widthAnchor constraintEqualToConstant:32],
        [self.locationButton.heightAnchor constraintEqualToAnchor:self.locationButton.widthAnchor],

        [self.locationLabel.centerYAnchor constraintEqualToAnchor:self.locationButton.centerYAnchor],
        [self.locationLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
        [self.locationLabel.trailingAnchor constraintEqualToAnchor:self.locationButton.leadingAnchor constant:-8],

        [self.spotifyMusicView.topAnchor constraintEqualToAnchor:self.locationButton.bottomAnchor constant:14],
        [self.spotifyMusicView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [self.spotifyMusicView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [self.spotifyMusicView.heightAnchor constraintEqualToConstant:46],
        [self.spotifyMusicView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
    ]];

    // A long press clears a slot. Previously a wrong pick could only be
    // replaced by picking a different photo, never undone.
    for (UIImageView *slot in @[self.frontImageView, self.backImageView]) {
        UILongPressGestureRecognizer *clearRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(imageViewLongPressed:)];
        [slot addGestureRecognizer:clearRecognizer];
    }

    [self updateImageSlotState];
    [self registerForKeyboardNotifications];
    [self beginAutomaticLocationLookup];
}

#pragma mark - Options

// Wire values for the create-post payload's `visibility` array.
//
// "friends" is confirmed - it is what this screen has always sent, and what
// BeReal's own client sends by default. The other two are NOT confirmed
// against a live request: BeReal 4.88 names these audiences internally as a
// Swift `Audience` enum with a `friendsOfFriends` case and exposes a
// /content/posts/targetAudience endpoint, but the exact strings its REST
// create-post payload expects can't be read out of the binary, and the
// endpoint needs a real account token to probe. The hyphenated spellings below
// are the ones reverse-engineered BeReal clients use.
//
// If the server rejects one, the post fails cleanly and the status banner now
// shows BeReal's own error text (see -describeFailureWithPrefix:... in
// BeaUploadTask.m) rather than the old "(null), (null), (null)" - so the
// failure is diagnosable, and switching back to Friends always works.
- (NSString *)visibilityValue {
    switch (self.visibilityControl.selectedSegmentIndex) {
        case 1:  return @"friend-of-friends";
        case 2:  return @"public";
        case 0:
        default: return @"friends";
    }
}

// Both slots show their "Front image"/"Back image" placeholder only while
// empty, and Send is only enabled once both are filled - previously the label
// stayed drawn on top of a chosen photo and the only feedback for a missing
// one was an error banner after tapping Send.
- (void)updateImageSlotState {
    BOOL hasFront = self.frontImage != nil;
    BOOL hasBack = self.backImage != nil;

    self.frontTextLabel.alpha = hasFront ? 0.0 : 1.0;
    self.backTextLabel.alpha = hasBack ? 0.0 : 1.0;
    self.swapButton.enabled = hasFront || hasBack;
    self.swapButton.alpha = self.swapButton.enabled ? 1.0 : 0.3;

    BOOL ready = hasFront && hasBack;
    self.actionButton.enabled = ready;
    self.actionButton.alpha = ready ? 1.0 : 0.5;
}

- (void)swapImages {
    UIImage *previousFront = self.frontImage;
    self.frontImage = self.backImage;
    self.backImage = previousFront;

    self.frontImageView.image = self.frontImage;
    self.backImageView.image = self.backImage;

    [self updateImageSlotState];
}

- (void)imageViewLongPressed:(UILongPressGestureRecognizer *)gestureRecognizer {
    // UILongPressGestureRecognizer keeps sending Changed events while the
    // finger is down; only act once, on the initial recognition.
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *pressed = gestureRecognizer.view;
    if (pressed == self.frontImageView) {
        self.frontImage = nil;
        self.frontImageView.image = nil;
    } else if (pressed == self.backImageView) {
        self.backImage = nil;
        self.backImageView.image = nil;
    }

    [self updateImageSlotState];
}

#pragma mark - Keyboard

- (void)registerForKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardFrameWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

// The Send button and the scroll view are both pinned to the safe area, which
// the keyboard does not move - so without this the keyboard covers the caption
// and retake fields outright on a shorter device.
- (void)keyboardFrameWillChange:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardInView);
    [self applyKeyboardInset:MAX(overlap, 0.0)];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    [self applyKeyboardInset:0.0];
}

- (void)applyKeyboardInset:(CGFloat)inset {
    UIEdgeInsets contentInset = self.scrollView.contentInset;
    contentInset.bottom = inset;
    self.scrollView.contentInset = contentInset;
    self.scrollView.verticalScrollIndicatorInsets = contentInset;
}

- (void)showMusicViewController {
    [self presentViewController:self.spotifyViewController animated:YES completion:nil];
}

- (void)musicManagerDidUpdateMusic {
    if ([BeaMusicManager sharedInstance].playingStatus == 0) {
        self.musicDict = nil;
        return;
    }

    self.musicDict = [[BeaMusicManager sharedInstance] musicDict];
}

- (void)isLateStateChanged:(UISwitch *)sender {
    if (sender.isOn) {
        self.isLate = YES;
    } else {
        self.isLate = NO;
    }
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)locationButtonTapped {
    // Carry whatever the row already holds into the map. Without this, opening
    // the picker just to look at it and tapping Done reports the picker's own
    // 0,0 default back, silently wiping an automatically-filled location - and
    // marking it as a deliberate user choice while doing so.
    self.locationVC.latitude = self.latitude;
    self.locationVC.longitude = self.longitude;
    [self presentViewController:self.locationVC animated:YES completion:nil];
}

- (void)locationViewController:(BeaLocationViewController *)viewController didSelectLocationWithLatitude:(CLLocationDegrees)latitude longitude:(CLLocationDegrees)longitude {
    // Whatever came back from the map wins from here on - including 0,0,
    // which is how the map reports "no location". Turning it off there has to
    // stick, or the automatic lookup below would helpfully put it straight
    // back and there would be no way to post without a location at all.
    self.locationChosenManually = YES;
    [self applyLocationWithLatitude:latitude longitude:longitude];
}

// Shared by the map picker and the automatic lookup: records the coordinate
// and turns it into something readable in the location row.
- (void)applyLocationWithLatitude:(CLLocationDegrees)latitude longitude:(CLLocationDegrees)longitude {
    self.latitude = latitude;
    self.longitude = longitude;

    if (latitude == 0.0 && longitude == 0.0) {
        self.locationLabel.text = BeaSharedCopy(@"userprofile_location", @"upload.location");
        return;
    }

    self.locationLabel.text = BeaSharedCopy(@"general_loading", @"upload.loading");

    CLLocation *location = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    // Weak, so a composer dismissed while the geocoder is still in flight
    // isn't kept alive by the block (and doesn't touch a dead label).
    __weak __typeof(self) weakSelf = self;
    [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> * _Nullable placemarks, NSError * _Nullable error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            strongSelf.locationLabel.text = BeaLocalized(@"upload.location_error");
            return;
        }

        if (placemarks.count > 0) {
            CLPlacemark *placemark = placemarks.firstObject;
            if (placemark.locality && placemark.country) {
                strongSelf.locationLabel.text = [NSString stringWithFormat:@"%@, %@", placemark.locality, placemark.ISOcountryCode];
                return;
            }
        }
        strongSelf.locationLabel.text = BeaLocalized(@"upload.city_not_found");
    }];
}

// Fills the location row in from where the phone is, unless the user has
// already said otherwise through the map picker.
//
// Never prompts more than the app already would: when authorization hasn't
// been asked for yet this requests it and returns, and
// -locationManagerDidChangeAuthorization: comes back here once the user has
// answered. A denial just leaves the row saying "Location", which is exactly
// what it did before this existed.
- (void)beginAutomaticLocationLookup {
    if (self.locationChosenManually) return;

    if (!self.locationManager) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        // A BeReal's location is shown to friends as a rough place, so
        // there's nothing to gain from a GPS-accurate fix - and a coarse one
        // resolves faster and costs less battery.
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    }

    // The instance property, not +[CLLocationManager authorizationStatus] -
    // that one is deprecated as of iOS 14 and this tweak's deployment target
    // (see the Makefile) is 14.0, so there is no older path to support.
    CLAuthorizationStatus status = self.locationManager.authorizationStatus;

    if (status == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
        return;
    }
    if (status != kCLAuthorizationStatusAuthorizedWhenInUse &&
        status != kCLAuthorizationStatusAuthorizedAlways) {
        return;
    }

    self.locationLabel.text = BeaSharedCopy(@"general_loading", @"upload.loading");
    [self.locationManager requestLocation];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self beginAutomaticLocationLookup];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (self.locationChosenManually) return;
    CLLocation *location = locations.lastObject;
    if (!location) return;
    [self applyLocationWithLatitude:location.coordinate.latitude longitude:location.coordinate.longitude];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // -requestLocation reports a single failure and stops; there is nothing to
    // retry and nothing worth interrupting the user for. Put the row back to
    // its idle wording so it can't sit on "Loading…" forever.
    if (self.locationChosenManually) return;
    self.locationLabel.text = BeaSharedCopy(@"userprofile_location", @"upload.location");
}

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    self.statusView.titleLabel.text = title;
    self.statusView.messageLabel.text = message;
    self.statusView.backgroundColor = [UIColor colorWithRed: 0.95 green: 0.15 blue: 0.07 alpha: 1.00];
    self.statusView.imageView.image = self.statusView.image;

    [UIView animateWithDuration:0.3 animations:^{
        self.statusView.alpha = 1.0;
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            self.statusView.alpha = 0.0;
        }];
    });
}

- (void)imageViewTapped:(UITapGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
        imagePicker.delegate = self;
        UIImageView *tapped = (UIImageView *)gestureRecognizer.view;
        if (tapped == self.frontImageView) {
            imagePicker.view.tag = 1;
        } else if (tapped == self.backImageView) {
            imagePicker.view.tag = 2;
        }
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BeaLocalized(@"upload.source_title") message:BeaLocalized(@"upload.source_message") preferredStyle:UIAlertControllerStyleActionSheet];
        
        UIAlertAction *cameraAction = [UIAlertAction actionWithTitle:BeaSharedCopy(@"whistler_edit_group_take_photo", @"upload.open_camera") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;
            if (tapped == self.frontImageView) {
                imagePicker.cameraDevice = UIImagePickerControllerCameraDeviceFront;
            } else {
                imagePicker.cameraDevice = UIImagePickerControllerCameraDeviceRear;
            }
            [self presentViewController:imagePicker animated:YES completion:nil];
        }];

        UIImage *cameraImage = [UIImage systemImageNamed:@"camera" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19]];
        [cameraAction setValue:cameraImage forKey:@"image"];
        
        UIAlertAction *photoAction = [UIAlertAction actionWithTitle:BeaSharedCopy(@"whistler_edit_group_choose_from_library", @"upload.choose_library") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            [self presentViewController:imagePicker animated:YES completion:nil];
        }];

        UIImage *photoImage = [UIImage systemImageNamed:@"photo" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19]];
        [photoAction setValue:photoImage forKey:@"image"];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:BeaSharedCopy(@"general_cancel", @"general.cancel") style:UIAlertActionStyleCancel handler:nil];
        
        [alertController addAction:cameraAction];
        [alertController addAction:photoAction];
        [alertController addAction:cancelAction];
        
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *pickedImage = info[UIImagePickerControllerOriginalImage];

    // check if the source type is camera or photo library and then check
    // if the picked photo is for the front image or back image view and assign it to it
    if (picker.sourceType == UIImagePickerControllerSourceTypeCamera) {
        if (picker.view.tag == 1) {
            UIImage *mirrored = [UIImage imageWithCGImage:pickedImage.CGImage scale:pickedImage.scale orientation:UIImageOrientationLeftMirrored];
            self.frontImage = mirrored;
            self.frontImageView.image = self.frontImage;
        } else if (picker.view.tag == 2) {
            self.backImage = pickedImage;
            self.backImageView.image = self.backImage;
        }
    } else if (picker.sourceType == UIImagePickerControllerSourceTypePhotoLibrary) {
        if (picker.view.tag == 1) {
            self.frontImage = pickedImage;
            self.frontImageView.image = self.frontImage;
        } else if (picker.view.tag == 2) {
            self.backImage = pickedImage;
            self.backImageView.image = self.backImage;
        }
    }

    [self updateImageSlotState];

    [picker dismissViewControllerAnimated:YES completion:nil];
}

// methods for the text field
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

// method for the caption text field
- (void)captionTextFieldDidChange:(UITextField *)textField {
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // nil rather than @"" for an empty field, so createDataDictionary leaves
    // the key out entirely instead of posting an empty caption.
    self.caption = trimmed.length > 0 ? trimmed : nil;
}

// method for the retake text field
- (void)retakeTextFieldDidChange:(UITextField *)textField {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    BOOL containsNonDigits = [textField.text rangeOfCharacterFromSet:nonDigits].location != NSNotFound;
    
    if (!containsNonDigits) {
        NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
        NSNumber *number = [numberFormatter numberFromString:textField.text];
        self.retakeCount = number;
        textField.layer.borderColor = [UIColor whiteColor].CGColor;
    } else {
        textField.layer.borderColor = [UIColor redColor].CGColor;
        CALayer *layer = textField.layer;
    
        CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        animation.duration = 0.3;
        animation.repeatCount = 1;
        animation.values = @[
            [NSValue valueWithCGPoint:CGPointMake(layer.position.x - 10, layer.position.y)],
            [NSValue valueWithCGPoint:CGPointMake(layer.position.x + 10, layer.position.y)],
            [NSValue valueWithCGPoint:CGPointMake(layer.position.x - 10, layer.position.y)],
            [NSValue valueWithCGPoint:CGPointMake(layer.position.x + 10, layer.position.y)],
            [NSValue valueWithCGPoint:CGPointMake(layer.position.x, layer.position.y)]
        ];

        [layer addAnimation:animation forKey:@"shake"];
    }
}

- (void)sendBeReal {
    // Committing whatever is currently typed before reading anything: the
    // caption/retake fields only publish on EditingChanged/EditingDidEnd, and
    // tapping Send does not itself end editing. This makes the send path
    // independent of that entirely.
    [self.view endEditing:YES];
    [self captionTextFieldDidChange:self.captionTextField];
    [self retakeTextFieldDidChange:self.retakeTextField];

    if (!self.frontImage || !self.backImage) {
        [self showErrorWithTitle:BeaLocalized(@"upload.missing_images_title")
                         message:BeaLocalized(@"upload.missing_images_message")];
        return;
    }

    // Checked before disabling the button/adding the spinner below -
    // showErrorWithTitle:message: only shows a status banner, it doesn't
    // restore action-button/spinner state, so returning here after that UI
    // was already put into its "sending" state left the button permanently
    // disabled/blank with the spinner still spinning.
    if (![[BeaTokenManager sharedInstance] BRAccessToken]) {
        [self showErrorWithTitle:BeaLocalized(@"upload.error_title")
                         message:BeaLocalized(@"upload.error_restart")];
        return;
    }

    self.actionButton.enabled = NO;
    [self.actionButton setTitle:@"" forState:UIControlStateNormal];

    // stop the api calls being made
    [self.spotifyMusicView stopTimer];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.center = self.actionButton.center;
    [self.view addSubview:spinner];
    [spinner startAnimating];

    [UIView animateWithDuration:0.3 animations:^{
        self.actionButton.alpha = 0.5;
    }];

    NSDictionary *userData = [self createDataDictionary];

    // because of processing the images the spinner lags a bit
    BeaUploadTask *task = [[BeaUploadTask alloc] initWithData:userData frontImage:self.frontImage backImage:self.backImage];
    [task uploadBeRealWithCompletion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [spinner stopAnimating];
            [spinner removeFromSuperview];
            self.actionButton.enabled = YES;
            [self.actionButton setTitle:BeaSharedCopy(@"general_send_button", @"upload.send") forState:UIControlStateNormal];
            [UIView animateWithDuration:0.3 animations:^{
                self.actionButton.alpha = 1.0;
            }];
            
            if (success) {
                [self uploadDidSucceed];
            } else {
                [self showErrorWithTitle:error.userInfo[@"title"] message:error.userInfo[@"description"]];
            }
        });
    }];
}

- (void)uploadDidSucceed {
    self.statusView.backgroundColor = [UIColor colorWithRed:76.0/255.0 green:178.0/255.0 blue:80.0/255.0 alpha:1.0];
    self.statusView.titleLabel.text = BeaLocalized(@"upload.success_title");
    self.statusView.messageLabel.text = BeaLocalized(@"upload.success_message");

    UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle"];

    self.statusView.imageView.image = checkmarkImage;

    [UIView animateWithDuration:0.3 animations:^{
        self.statusView.alpha = 1.0;
        self.frontTextLabel.alpha = 1.0;
        self.backTextLabel.alpha = 1.0;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            self.statusView.alpha = 0.0;
        }];
    });

    [self resetProperties];
}

- (void)resetProperties {
    // reset the view and properties to initial state
    self.frontImageView.image = nil;
    self.backImageView.image = nil;
    self.frontImage = nil;
    self.backImage = nil;
    self.caption = nil;
    self.captionTextField.text = nil;
    self.retakeCount = nil;
    self.retakeTextField.text = nil;
    self.longitude = 0.0;
    self.latitude = 0.0;
    self.locationLabel.text = BeaSharedCopy(@"userprofile_location", @"upload.location");
    self.isLate = NO;
    [self.isLateSwitch setOn:NO animated:YES];
    self.visibilityControl.selectedSegmentIndex = 0;
    [self updateImageSlotState];

    // Composing a second post in the same session starts from the same place
    // the first one did - unless the user turned the location off by hand, in
    // which case locationChosenManually keeps it off.
    [self beginAutomaticLocationLookup];
}

- (NSDictionary *)createDataDictionary {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];

    [data setValue:@(self.isLate) forKey:@"isLate"];
    [data setObject:[self visibilityValue] forKey:@"visibility"];
    
    if (self.caption) {
        [data setObject:self.caption forKey:@"caption"];
    }
    if (self.retakeCount) {
        [data setObject:self.retakeCount forKey:@"retakeCounter"];
    }
    if ((self.latitude != 0.0) && (self.longitude != 0.0)) {
        NSNumber *longitudeNumber = @(self.longitude);
        NSNumber *latitudeNumber = @(self.latitude);

        [data setObject:longitudeNumber forKey:@"longitude"];
        [data setObject:latitudeNumber forKey:@"latitude"];
    }

    if (self.musicDict && [BeaMusicManager sharedInstance].playingStatus == 1) {
        [data addEntriesFromDictionary:self.musicDict];
    }

    return [data copy];
}

- (void)dealloc {
    // Belt and braces alongside viewWillDisappear:'s targeted removals below -
    // the keyboard observers are registered once in viewDidLoad and must not
    // outlive the controller, and viewWillDisappear: also fires when merely
    // presenting the photo picker on top of this screen (where re-registering
    // never happens).
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"MusicUpdated" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"openSpotifyViewController" object:nil];
    [self.spotifyMusicView stopTimer];
    [[BeaMusicManager sharedInstance] resetData];
}
@end