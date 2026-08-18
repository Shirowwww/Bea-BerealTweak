#import <UIKit/UIKit.h>

// ============================================================================
// TEXT THIS TWEAK SHOWS, AND TEXT IT LOOKS FOR
// ============================================================================
// Two separate problems, one file, because both come down to "never hardcode
// an English literal" - the single worst class of bug in this repo (see
// AGENTS.md).
//
//  1. Copy the tweak renders itself (the BeFake composer, the download
//     picker). BeReal ships fifteen languages and the repo owner's device is
//     French; an English-only composer sitting inside a French app is the
//     symptom this half fixes.
//  2. Copy the tweak *matches against* to find something in BeReal's own UI
//     (the "Post to view" gating overlay, the "Sponsored" label on a paid
//     placement). Matching a hardcoded English string there doesn't just look
//     wrong, it silently does nothing at all.
//
// Both halves prefer BeReal's own string table over anything written here, so
// a phrase BeReal already has comes out in whichever of its fifteen languages
// the app is actually running in.

// This tweak's own copy, from the table in BeaLocalization.m. English and
// French are translated; any other language falls back to English.
FOUNDATION_EXPORT NSString *BeaLocalized(NSString *key);

// BeReal's own copy, read at runtime from its Localisation_Localisation.bundle
// by key. `fallback` is returned whenever the bundle or the key can't be
// resolved - so a key BeReal renames in a future version degrades to readable
// text rather than to the raw key name, which is what
// -localizedStringForKey:value:table: would otherwise hand back.
FOUNDATION_EXPORT NSString *BeaAppLocalized(NSString *berealKey, NSString *fallback);

// The common case: a phrase BeReal already has a translation for. Prefers
// BeReal's (so the tweak's UI reads like the rest of the app, in all fifteen
// languages) and falls back to this tweak's own table when the key is gone.
FOUNDATION_EXPORT NSString *BeaSharedCopy(NSString *berealKey, NSString *ownKey);

// Lowercased, typographic apostrophes folded to ASCII, runs of whitespace
// collapsed, and everything from the first %-format specifier onwards dropped.
// BeReal's copy uses U+2019 ("your friends<U+2019> BeReal"), which never
// compares equal to a plain ', and several of these strings are format
// templates whose tail can't be matched literally anyway.
FOUNDATION_EXPORT NSString *BeaNormalizedCopy(NSString *text);

// Whether `needle` appears in `haystack` as a whole phrase rather than as an
// arbitrary substring - both already normalized. Guards the one-word markers
// ("sponsored"): a plain -containsString: would also fire on "unsponsored" or
// on a longer word that happens to embed it.
FOUNDATION_EXPORT BOOL BeaCopyContainsPhrase(NSString *haystack, NSString *needle);

// Every UIView at or under `root` that renders text `matches` accepts, where
// "renders text" deliberately means more than UILabel.text.
//
// SwiftUI is why. BeReal's feed draws most of its text through SwiftUI, which
// does not create a UILabel per string - it renders into one drawing view and
// publishes the text only through the UIAccessibilityContainer protocol
// (-accessibilityElements / -accessibilityElementAtIndex:), as
// UIAccessibilityElement objects that are not views at all. A scan that reads
// UILabel.text and UIView.accessibilityLabel finds nothing there, which is
// exactly how the gating-overlay hider ended up doing nothing on a real
// device even after its needles were correctly localized. When a match comes
// from an accessibility element, the UIView hosting that element is what gets
// reported, since that is the only thing in the result that can be hidden.
FOUNDATION_EXPORT void BeaCollectViewsWithMatchingText(UIView *root,
                                                       BOOL (^matches)(NSString *normalized),
                                                       NSMutableArray<UIView *> *result);
