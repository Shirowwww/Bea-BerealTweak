#import <UIKit/UIKit.h>
#import "../../Managers/MusicManager/BeaMusicManager.h"
#import "../../Managers/AppleMusic/BeaAppleMusicManager.h"
#import "../../../TokenManager/BeaTokenManager.h"

// Two providers, because they fail in completely different ways. Spotify needs
// a token BeReal only hands out once the account is linked in the real app, so
// for anyone who never linked it this screen was permanently empty - it fired a
// search with a nil bearer and logged the 401 nowhere the user could see.
// Apple Music goes through the public iTunes Search API: no account, no token,
// no permission, so it is the provider that is always available and the one
// this screen defaults to when Spotify has nothing to offer.
@interface BeaSongSearchViewController : UIViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *providerControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *searchResults;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) NSCache *imageCache;
@property (nonatomic, strong) UILabel *statusLabel;
@end