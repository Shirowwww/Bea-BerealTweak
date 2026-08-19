# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this repository.

## What this is

MiniBea is a Theos/Logos jailbreak+sideload tweak for BeReal (iOS). It's a
curated merge of two active MiniBea forks, plus ad removal and per-camera
downloads added here — see `README.md` for the
feature list and `MERGE_NOTES.md` for exactly what was taken from each fork
and why. There is no app/server here, just the tweak's Objective-C source
and the Theos build config that turns it into a `.deb`.

## Build commands

Requires [Theos](https://theos.dev) installed and `$THEOS` set, plus an
`iPhoneOS18.0.sdk` (or compatible mirror — see `.github/workflows/build.yml`
for how CI fetches one headlessly). There is no simulator target and no
automated test suite — the tweak only runs injected into BeReal on a real
device, so "testing a change" means a clean Theos build (below), plus the
CI build workflow, plus (when the change is behavioral, not just
mechanical) manual verification on-device.

```sh
./build_release.sh   # builds all 3 variants into ./packages (see below)
```

Or drive `make` directly for a single variant while iterating:

```sh
make clean package FINALPACKAGE=1                              # rootful (arm64 + arm64e)
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless # rootless (arm64 only)
make clean package FINALPACKAGE=1 JAILED=1                      # jailed/sideload
```

`JAILED=1` changes the build meaningfully, not just the output name: it
pulls in `fishhook/` + `SideloadFix/SideloadFix.xm` and switches Logos'
hook generator to `internal` (see the comment above
`$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR` in `Makefile`) so the sideload
package has no MobileSubstrate/CydiaSubstrate dependency at all. Don't test
only the rootful build and assume jailed behaves the same — it's compiling
different files under a different hooking mechanism.

`build_ipa.sh` injects the jailed `.deb` into a
BeReal IPA to produce a sideloadable IPA. `update_and_sideload.sh`
wraps this: fast-forwards to the latest`main`, rebuilds the
jailed package fresh, then hands off to `build_ipa.sh`.

## Architecture

**`Tweak/Tweak.x`** is the entry point — one large Logos file (`%hook`/
`%orig`/`%new`/`%ctor`) covering: jailbreak-detection bypass (multiple SDK
classes, see `Tweak.h`), "Post to view"/blur bypass, the floating
download/profile-picture/upload buttons and their window-attachment +
z-ordering logic, and BeReal-version-compatibility no-ops. Classes it hooks
into (many private/undocumented BeReal classes) are forward-declared in
`Tweak.h`.

**`BeFake/`** is the fake-post subsystem (its own view controllers for
upload/location/music-picker/info, token manager, upload task) — this is
what lets a "BeFake" be composed and posted through BeReal's real upload
API rather than the actual camera.

**`Utilities/`** — cross-cutting helpers used by both `Tweak.x` and
`BeFake/`: `BeaButton` (the floating buttons, each with a stable
`accessibilityIdentifier` used to find/remove stray instances — see
`BeaRemoveStrayButtons` in `Tweak.x`), `BeaDownloader`, `BeaAdBlocker`,
`BeaLocalization` (all text, both directions — see below), and `BeaDebug`
(the logging gate, see below).

**`Utilities/Localization/BeaLocalization`** owns every string the tweak
shows *and* every string it looks for. `BeaLocalized(key)` reads the tweak's
own two-language table (en/fr, English fallback); `BeaAppLocalized(key,
fallback)` reads BeReal's own `Localisation_Localisation.bundle` by key;
`BeaSharedCopy(berealKey, ownKey)` prefers BeReal's and falls back to ours,
which is the one to reach for whenever BeReal already says the same phrase
somewhere — that gets all fifteen languages for free. Use
`python tools/ipa_inspect.py loc` to confirm a key exists before using it.
The file also holds `BeaNormalizedCopy` / `BeaCopyContainsPhrase` and the
text scanner both marker hunts share.

**`Utilities/Ads/BeaAdBlocker`** is the whole ad-removal decision layer;
`Tweak.x` only holds the hooks that call into it. It decides whether a class
belongs to the ad stack by two signals — a name match for BeReal's own
`Adverts*`/`SparkAds*` Swift modules, and `class_getImageName` for the ~18
embedded vendor SDK frameworks — and caches the answer per `Class` forever,
because the `%hook UIView` pair that calls it runs on every view insertion
anywhere in the app. **Prefer widening the framework/module lists there over
adding named `%hook`s in `Tweak.x`**: the image-name signal already covers
classes those SDKs haven't shipped yet. Note the two deliberate non-targets
documented at the top of that file (UserMessagingPlatform's consent sheet,
and Firebase Analytics hosts) — don't "fix" those without reading why.

**A class-based ad check cannot see a SwiftUI-drawn ad.** BeReal's in-feed
sponsored post (`SparkAdsPresentation.FeedDirectDealView` and friends, all
SwiftUI structs) has no per-element `UIView` and therefore no class to match.
The vendor SDK's media view inside it *was* being removed, which is exactly
what produced the reported symptom: a full-height black rectangle with the
advertiser's name and "En savoir plus" still on it.
`+removeSponsoredContentInView:` finds it by the one string BeReal puts on
every paid placement — `general_sponsored` — and collapses the card around it.
Everything about that path is deliberately fail-safe:
`+viewIsPlausibleSponsoredCard:` is checked against the marker itself as well
as every ancestor, and refuses anything that is a scroll view, is over ~1.2
screens, or holds a front+back photo pair. A marker found via the
accessibility tree reports the SwiftUI *host* view, which can be the whole
feed — collapsing that would blank the timeline, so refusing outright (ad
stays, nothing else breaks) is the correct outcome, not a bug.

**Never match BeReal's UI copy in English.** The repo owner's device is in
French, and BeReal ships fifteen languages. The "Post to view" overlay hider
looked for the literal strings `post to view` / `share yours with them` and so
did nothing at all for that user — French renders "Poste pour voir" and "Pour
voir les BeReal de tes amis, poste le tien.", which share no substring with
either. `BeaDownloader`'s `+gatingCopyNeedles` now reads the strings at runtime
from the app's own `Localisation_Localisation.bundle` by key (e.g.
`timelineCell_blurredView_title`), which is language-proof and survives a copy
rewrite. Do the same for any new text match, and normalise before comparing —
`BeaNormalizedCopy` does it, and it matters because BeReal's copy uses U+2019
apostrophes, U+00A0 before French `!?:`, and `%1$@`-style format specifiers.
The key names can be read straight out of the IPA (see below).

The same rule runs the other way for text the tweak *renders*: the BeFake
composer shipped English-only labels inside a French app. Everything
user-visible now goes through `BeaLocalization` — never write a bare `@"..."`
into a label, a placeholder, an alert or a menu title.

**Text that isn't in a `UILabel` still exists — it's in the accessibility
tree.** SwiftUI renders its `Text` into one drawing view and publishes the
string only through `UIAccessibilityContainer`
(`-accessibilityElements` / `-accessibilityElementAtIndex:`), as
`UIAccessibilityElement` objects that are **not views**. Walking `subviews`
reading `UILabel.text` and `UIView.accessibilityLabel` therefore finds
nothing, which is why the gating-overlay hider still did nothing on a real
device even after its needles were correctly localized.
`BeaCollectViewsWithMatchingText` looks in both places and reports the
hosting `UIView` for an accessibility-element match, since that is the only
thing in the result that can actually be hidden. Building that tree isn't
free, so it only runs when the cheap scan came up empty and is throttled to
~400ms; keep that shape if you add another marker hunt.

**One injected button per post, and one place that decides visibility.** The
download button used to be a single instance per Home controller anchored to
the first qualifying photo in the feed, which is why a second post on screen
had no button until the first scrolled away. `BeaSyncDownloadButtons` in
`Tweak.x` reconciles the set against every post on screen, reusing buttons by
*position in that order* rather than by anchor identity — BeReal recycles its
`UIImageView`s, so identity is not a stable key (KNOWN_ISSUES.md bug #1 is the
whole history of learning that). It runs from Home's layout pass and from the
display link at ~10Hz, because posts scroll into view without invalidating
layout.

Visibility for every injected button is decided once per displayed frame in
`-[BeaVisibilitySyncTarget bea_tick:]`. It has to be there rather than in a
layout hook for a reason that is easy to rediscover the hard way: **while a
modal is presented, Home does not lay out at all** — which is exactly when a
window-parented button must be hidden. `+[BeaButton syncAnchoredButtons]` owns
`hidden` in both directions (it is the only thing that knows whether an anchor
is still on screen); the policy only ever writes `alpha`, and UIKit's hit
testing already ignores a view at alpha 0.

**Do not mark a full-screen sheet with `+[BeaButton markAsTweakPresented:]`.**
That exemption exists for the small action sheets *anchored to a button* — the
download picker, whose own menu would otherwise hide the icon it belongs to.
Marking the settings screen with it is what left the "+" and the download arrow
floating on top of the screen that configures them.

**The "+" is a real `UIBarButtonItem`, not a view that tracks the bar.** Three
versions of it were window-parented and tried to *look* like top chrome — pinned
to the safe area, then anchored to the navigation bar's frame, then with the
inset measured from BeReal's own leading icons — and each produced its own drift
report, because a window-parented view genuinely is not part of the header: it
does not move with the bar, does not hide when the bar hides, outranks every
modal, and has no ancestor view controller. It is now appended to
`navigationBar.topItem.leftBarButtonItems`, where UIKit lays it out in the row's
own coordinate space and there is no offset left to tune. BeReal builds that bar
from SwiftUI's `.toolbar`, which republishes the array on state changes, so
attachment is **reconciled every pass** rather than done once — and the array is
never stored-and-restored, only inserted into and filtered out of, so putting our
item back can never undo something SwiftUI changed meanwhile. The old
window-parented placement survives only as the degraded path for a screen with no
navigation bar at all. Do not go back to coordinate tracking.

**`leftBarButtonItems` index 0 is not a free slot.** 0.9.4 inserted the "+" at
index 0, which is BeReal's own leading icon (add friends on the home feed) —
the platter didn't error, it just stopped rendering the icon our item
displaced, which is why a device dump showed only two items in the row instead
of three. `BeaSetUploadBarItemAttached` now appends instead of inserting at 0.
If a future screen needs the "+" positioned relative to BeReal's own items
rather than after all of them, insert at a specific index only after confirming
from a dump what already occupies index 0 on that screen — never assume it's
free.

**The gating overlay is not a view.** BeReal 4.88 draws the "Poste pour voir"
scrim, both text lines and the CTA button straight into `CALayer`s: SwiftUI only
materializes a `UIView` for content it bridges to UIKit (the photos, the "..."
button, `RealComponents.UIMainMediaGesturesView`), and a plain
`ZStack { scrim; Text; Text; Button }` gets none. A device report of "0
marker(s) found" next to a screenshot of the overlay is the *expected* answer
from a view/accessibility scan, not evidence that the needles are wrong. When
that scan finds nothing, `hideGatingOverlaysInView:` falls back to the drawing
layers over the post's own photo (delegate not a `UIView`, drawn above the photo
in the same sublayer array, no more than ~1.6x its area). The diagnostics report
dumps the layer tree for exactly this reason — reach for that before theorising.

**Find the gating overlay by its scrim, never by size.** The layer pass used
to collect any drawing layer between 5% and 160% of the photo's area. Against a
real 402x536 photo the scrim (100%) was the only part of the overlay that
passed: the eye icon is 0.7%, the title 1.1%, the body 2.6%, the CTA pill 2.4%
and its label 1.0% - all under the 5% floor meant to skip "decorations". That is
the whole of the "gating still visible after the background went" report. The
cluster is now defined by stacking order instead: find a background-filled layer
above the photo in the card's sublayers covering at least half of it, and take
it plus every non-view-backed layer above it that stays inside the photo's rect.
That needs no size threshold and cannot reach what BeReal drew *below* the scrim
(the header, the front-camera placeholder), which is content the overlay dims
rather than part of it. Detection deliberately does not skip already-hidden
layers - after the first pass the scrim is one the tweak hid, and treating that
as "not gated" is what left the rest of the overlay on screen forever.

**A marker found in the accessibility tree is not an overlay you may hide.**
The view pass widened from a marker and used "does this contain the photo?" only
as a *stop* condition, never as a verdict on the view it settled on - so when the
marker itself contained the photo (which is what happens when the string was
published by the hosting view for the whole feed) it hid the timeline. It now
refuses any overlay that holds a qualifying photo or covers more than 60% of the
window, exactly as `+viewIsPlausibleSponsoredCard:` already did, and falls
through to the layer pass. Relatedly, the two passes are no longer either/or:
the layer pass runs whenever the view pass did not actually take something off
the screen, because "the text scan found something" and "the overlay was hidden"
are different facts, and conflating them is why turning *on* "read SwiftUI text"
could make the gating hider do less.

**A switch that only gates the apply path is not reversible.** Three of the ad
switches read their key only where the effect is applied. `sizeThatFits:` and
`intrinsicContentSize` on the three `Adverts*` containers returned `CGSizeZero`
unconditionally, so BeaAdBlocker could restore a view's frame and those two kept
reporting it as zero-sized for the life of the process; interstitials and ad
windows were likewise refused unconditionally. Anything that answers a question
on behalf of the ad blocker has to read the switch at the moment it answers, not
at the moment it was installed - the `NSURLProtocol` has done this per request
from the start and is the model. And one switch owns one undo category: sharing
`BeaSuppressionCategorySponsoredCard` between "remove sponsored posts" and
"collapse the card around a removed ad" meant turning either off restored the
other's work, which is exactly what makes a bisection useless.

**Unlocking media is a UIKit-level job, not a Swift one.** BeReal 4.88 does
ship full-screen expand and pinch-zoom - `ExpandTransitionDelegate`,
`ExpandTransitionAnimator`, `PinchPanGestureModifier`, and a
`beRealPrimaryMediaZoomEnabled` feature-flag key next to
`BeRealMediaPrimaryMediaZoomValue`. None of it is reachable: they are Swift
types with no `@objc` surface, driven through SwiftUI view modifiers behind a
server-side flag, with no selector to send and no controller to present.
`%hook`ing `NewDoubleMediaViewModel` for `isBlurred`/`blurred` is in the same
category - those hooks add methods nothing ever calls. What *is* reachable is
what bridges to UIKit: both photos are real `SDAnimatedImageView`s already
holding decoded `UIImage`s, and a view of our own can be put on top of them.
`BeaMediaUnlock` adds the tap target and `BeaMediaViewer` is the viewer, scoped
to gated posts only - on a normal post BeReal's own gestures already work and a
second tap handler is interference.

**`-hitTest:withEvent:` does not fall through to earlier siblings.** This is the
whole of the second "media unlock still does not work" report. The build before
0.9.2 put a tap recognizer on the photo and held
`RealComponents.UIMainMediaGesturesView` (its sibling, identical frame, later in
the list) at `userInteractionEnabled = NO`, expecting the touch to reach the
photo underneath. Hit testing returns the deepest view that claims the point in
the **last branch that claims it at all**; it never resumes searching earlier
siblings when a deeper view declines. Disabling the innermost gestures view only
promoted its still-interactive SwiftUI wrappers — same frame — to being the
result, and a recognizer in the *photo* branch is neither that view nor an
ancestor of it, so UIKit never delivered the touch to it. Tapping did nothing at
all. The tap target is now a `BeaMediaTapOverlay` of ours, added as the **last
subview of the post card** and framed over each photo (largest first, so the
inset front camera ends up on top and wins inside its own rect). Last sibling
wins outright, which needs nothing from BeReal's own interaction flags. The
gestures view is still held disabled while the post is gated, but now only as
defence in depth: if SwiftUI rebuilds the card between two reconcile passes, the
worst case has to be "the tap does nothing", never "the tap opens the composer",
which is what BeReal binds to that view on a gated post.

**Being the last sibling only wins the hit test if the ancestors let the descent
get there.** 0.9.3's report proved every premise of the fix above and the tap
still did nothing: two `BeaMediaTapOverlay`s, correctly framed, last two subviews
of the card, `Overlay re-orders: 0 total` (so SwiftUI never re-appended over
them) — and `[window hitTest:centreOfPhoto]` answering
`HostingScrollView.PlatformGroupContainer`, several levels *above* the card.
`-hitTest:` never reaches a view whose ancestor declined the point, so the
refusal was one of BeReal's own views and nothing about ours could fix it. A
`UIView` refuses for exactly four reasons — `hidden`, `alpha < 0.01`,
`userInteractionEnabled == NO`, `-pointInside:withEvent:` — plus a fifth that
looks identical from outside, an overridden `-hitTest:` that returns nil or picks
another branch. All five now go in the report, per link, window to overlay, with
the first break marked (`Hit chain break:` in the summary): that is a fact read
off the device, not the sixth theory in a row. It is behind
`BeaDebugLoggingEnabled()` and throttled to 1Hz — it costs one `hitTest:` per
level.

**The chain walk stopping at the first break threw away the evidence for what
broke.** 0.9.4's `+recordHitChainToOverlay:` returned as soon as it found a
reason, so the flags on every link *past* the break were never printed — which
are exactly the ones that would confirm or rule out the SwiftUI card as the
culprit versus something further down. It now keeps walking to the end of the
chain and only records the *first* break as the answer (a later link's own
reason is a downstream symptom, not a second independent cause). Do not
reintroduce the early return.

**When descent is the problem, stop routing the tap by descent.** The fix that
does not depend on which of the five it turns out to be is a single
`UITapGestureRecognizer` on the `UIWindow`: it receives every touch the window
delivers, whatever declined it on the way down.
`-gestureRecognizer:shouldReceiveTouch:` accepts only a point inside a
registered overlay's rect and not on a `UIControl`, a button-traited view or one
of the tweak's own `Bea*` views (it never cancels touches, so accepting a
control's touch would fire the control *and* the viewer); it recognises
simultaneously with everything. Note what this is **not**: no view is added to
the window, so it does not outrank a modal and the rule against window-parented
tap targets still stands. The overlay's own recognizer stays as the preferred
path, and both go through one `+presentViewerForPhoto:inWindow:` with a 0.4s
guard so one finger can never open two viewers.

**Never spoof post state to unlock local UI.** Not `HasPosted`, not a fabricated
post, not a rewritten request. Every symbol the unlock touches is a `UIView`, a
`UIGestureRecognizer` or a `UIImage` already on screen; from BeReal's side it is
indistinguishable from a screenshot. `BeReal.HasPostedUseCaseImpl` is visible in
the binary and is deliberately not hooked.

**Media unlock and a kept gating CTA are two features fighting for the same
touch.** A 0.9.5 report: with tap-to-see on, BeReal's own "Post a BeReal." CTA
(the one `settings.gating_keep_cta` keeps visible on a gated post) stopped
responding; turning tap-to-see off fixed it. Two mechanisms in this file are
each independently capable of causing that, and no device round trip has
isolated which: `+holdGesturesOverlayDisabledInContainer:` unconditionally
disables `UIMainMediaGesturesView`, which the header comment above
`BeaMediaGesturesClassNameFragment` already documents as "whatever BeReal binds
to tap this view on a gated post - the post/camera flow" (plausibly the same
action the CTA triggers); separately, `BeaMediaTapOverlay` is the *last*
subview of the post card, covering the whole photo - the exact "last sibling
wins the hit test" mechanism this file relies on for its own tap target could
just as easily be swallowing a touch meant for the CTA's own sibling view. The
fix (`+[BeaDownloader gatingCTAIsKeptForPhoto:inCard:]`, checked in
`+syncPostWithContainer:mainPhoto:root:`) doesn't pick one: any post whose CTA
is currently kept skips both the tap overlay and the disabled-gestures hold
entirely, the same "not gated" path already used for an unlocked post. If a
future report narrows this to one specific mechanism, the other guard can come
back off - but don't remove either without evidence, since removing the wrong
one reintroduces the bug with no error anywhere.

**The settings screen is not a `UITableView`.** Two device reports described the
same symptoms — rows missing entirely, tall blank gaps exactly where a row should
be, sections split in two, text starting under the navigation bar — and two
rounds of fixes both argued with `estimatedRowHeight` (`0`, then
`UITableViewAutomaticDimension`). Neither worked, and the second report's gaps
were the same height as the rows meant to be in them, which says the table had
measured correctly and still drew nothing there. Self-sizing cells are the wrong
mechanism for a dozen static rows of a title over a two-to-five-line explanation:
nothing is recycled, no scrolling performance is at stake, and every failure mode
is specific to the estimate-then-correct machinery. It is a `UIScrollView` +
`UIStackView` of plain `BeaSettingsRowView`s now, laid out by ordinary Auto
Layout with the label chain pinned top to bottom, so a row's height *is* its
content. Closed the same way bug #2 was — by deleting the mechanism, not by
tuning it. Do not reintroduce a table here.

**A view controller built with `-init` has no bounds yet.** The diagnostics
summary pushed correctly and showed an empty screen because its `UITextView` was
created with `initWithFrame:screen.view.bounds` before that view had ever been in
a hierarchy, and an autoresizing mask cannot grow a zero-sized view - it
distributes a superview's size *change* proportionally, and every proportion of
zero is zero. Pin with constraints.

**"Is a tweak screen up?" must be a fact, not an inference.**
`BeaHasPresentedModal` needs a window to walk from and resolves it through the
home feed, so before Home has been seen - or on a screen it was never part of -
it quietly answers "nothing presented" and a window-parented button sits on top
of the settings screen. `+[BeaButton setTweakScreenVisible:]` is raised by the
settings *navigation controller* (not the settings view controller: pushing the
summary takes that one off the window while a tweak screen is still up) and is
checked first by the per-frame policy.

**The navigation bar the "+" goes into must be provably outside the feed.** The
search enumerates every `UINavigationBar` candidate rather than taking whichever
a depth-first walk reached first, skips any bar with a `UIScrollView` ancestor,
and requires a laid-out, full-width bar in the top third of the window. That
matters more now than when the button merely tracked the bar's frame, because a
bar item is inserted into whatever `topItem` that bar has. The diagnostics report
prints which of the two hosting modes is in use.

**Never mutate a view from inside a layout pass.** `%hook UIViewController
-viewDidLayoutSubviews` fires for every controller in the app, and everything
under it - hiding a gating overlay, collapsing a sponsored card, adding a
button, and in 0.9.2 setting `navigationItem.leftBarButtonItems` - invalidates
layout and brings UIKit straight back into the same hook within the same
commit. That is the 0.9.2 freeze: not a deadlock (the three-finger suspend was
still recognised, so the run loop was turning), but one commit doing three
full-tree scans of a SwiftUI hierarchy per controller per iteration until it
settled. A re-entrancy guard in that hook enforces this now, the three scans are
rate-limited per controller to ~10Hz rather than running once per layout, the
"+" is reconciled only from the display link, and `-bringSubviewToFront:` is
called only when the order is actually wrong. **You cannot reconcile against
SwiftUI on its own schedule** - reconcile on yours, and measure the difference.

**Instrument the loop, do not argue about it.** "Which of the two things that
mutate SwiftUI's view state is spinning?" is unanswerable from a device: both
are invisible, neither logs, and the symptom of either is the same stopped UI.
`BeaDiagnostics` now carries permanent rate counters - bar-item re-inserts,
overlay re-orders, layout passes, full-tree scans - each as a live per-second
rate, a peak and a total, plus the reconcile pass duration, and each logs a
`[BeaLoop]` line past a threshold whether or not verbose logging is on. The
"+" uses its own counter as the trigger for giving up on bar-item hosting: if
SwiftUI's toolbar drops the item on most passes for several seconds, no
rate-limit wins that fight, so it degrades to the documented window-parented
placement for the session and the report says why.

**The tweak's own UI is inside BeReal's window, and the scanners cannot see the
difference.** The settings screen quotes BeReal's copy to explain what each
switch does - « Poste pour voir » is `timelineCell_blurredView_title`,
« Sponsorisé » is `general_sponsored` - so the gating hider stripped the text
out of its own rows and the sponsored remover collapsed its own cards. Three
device reports (missing rows, gaps the exact height of the missing rows, and
finally a completely empty screen) were all this, and two of them were answered
by arguing with `UITableView` about self-sizing cells. Every scan prunes
anything of ours now, by the `Bea*` class prefix and by an explicit mark on the
root view of anything the tweak presents (`Utilities/Runtime/BeaOwnership.h`),
and the layout hook returns immediately for a `Bea*` controller. Before
adjusting a tweak screen's constraints, check whether the tweak ate it.

**Diagnostics must not be on a hot path.** `-[UIWindow hitTest:withEvent:]` in
the media-unlock probe ran once per gated post per reconcile pass, ten times a
second, to fill in one line of a report nobody was reading; `hitTest:` walks the
whole window and can force layout. It is behind `BeaDebugLoggingEnabled()` now.
Anything that answers a question for the report, rather than for a behaviour,
belongs behind that switch.

**Every switch has to be undoable, live.** Most of them were one-way doors:
turning "remove ad views" off changed nothing until relaunch, because the ad was
already gone and the hook that removes it only fires on insertion.
`BeaSettings` posts `BeaSettingsDidChangeNotification`; whoever owns a behaviour
owns its undo (`BeaSuppressionRecord` in `BeaAdBlocker`, `BeaGatingEdit` in
`BeaDownloader`). Anything that hides, removes or rewrites one of BeReal's own
views must record the state it replaced. The ad-network `NSURLProtocol` is
registered unconditionally and reads its switch **per request** rather than once
at launch, for the same reason. Only the accessibility bundles still need a
relaunch.

**A registered `NSURLProtocol` is not a protocol that is in anybody's session,
and "0 requests blocked" cannot tell you which.**
`+[NSURLProtocol registerClass:]` only reaches `NSURLConnection` and
`[NSURLSession sharedSession]`; every SDK builds its own session from its own
configuration, which is why `+installNetworkBlocking` swizzles
`defaultSessionConfiguration`/`ephemeralSessionConfiguration`. That is necessary
and not sufficient: a configuration built before `%ctor` ran keeps the
`protocolClasses` it was born with, and an owner that *assigns*
`configuration.protocolClasses = [...]` after asking for a default one drops us
silently. Both look exactly like "there were no ad requests". So
`+[NSURLSession sessionWithConfiguration:...]` is swizzled too — the last point
at which the list is still fixable, since the session copies the configuration
there — and it both re-inserts the protocol and *counts*: the report says how
many sessions were seen and how many had to be repaired. Don't reason about that
number, read it. Background configurations are still deliberately untouched
(custom protocols there are documented undefined behaviour).

**Rule out "there was no ad on screen" before touching the ad code at all.**
A report with `Last sponsored scan: 0 marker(s)`, `Ad views suppressed: 0` and
`Ad requests blocked: 0` is what a perfectly working ad blocker looks like on a
feed with no ad in it, and three of the four ad switches drive unrelated
mechanisms, so "the ad toggle does nothing" is not one symptom. `Ad SDKs
loaded:` answers the prior question from dyld's image list (a framework can be
loaded without any of its classes ever being asked for): none loaded means
nothing on screen was a third-party ad, and the sponsored scan — which is the
only one that catches BeReal's *own* SwiftUI-drawn paid post — has to be judged
against a report captured while such a post is visible. Ask for that report
first.

**A diagnostics report that mangles accented text is a broken instrument.** The
report has always been written as UTF-8, and a 0.9.3 one still came back reading
`general_sponsored = "SponsorisÃ©"` — UTF-8 read as Latin-1. That has two very
different causes: if the *string in memory* is that, `BeaCopyContainsPhrase` is
matching against a broken needle and the sponsored scan can never hit anything;
if only the shared file reads that way, the scan is fine. The summary prints the
needle's UTF-8 bytes so that is one line rather than another round of theories
(`c3 a9` for `é` is correct; `c3 83 c2 a9` is double-encoded), and
`+writeFullReport` now emits a BOM, because a `.txt` without one is guessed at
by whatever opens it.

**More than one way into the settings screen.** It can switch off the "+", which
used to be the only entry point — an unrecoverable switch on a sideloaded
install. There are now three: long-press the "+", long-press the download button
and pick "MiniBea settings", or hold two fingers anywhere
(`+installFallbackGestureOnWindow:`, `cancelsTouchesInView = NO` so it can never
swallow a touch BeReal wanted).

**Never position a window-parented view with constraints to a view inside a
scroll view.** Both photo buttons live on the window and have to appear in a
corner of a photo several levels down inside the feed. Doing that with
`NSLayoutConstraint`s to the photo's own anchors is the direct cause of two
long-running bugs. Scrolling moves content by changing the scroll view's
`bounds` origin, which is *not* a layout change of the photo's frame in its
superview, so the solver is never asked to re-place the button and it sits
where the photo was. Worse, when the photo is recycled out of the hierarchy the
two views stop sharing a common ancestor, UIKit deactivates those constraints,
and the now-unconstrained button lands at the origin — that is the "stuck in
the top-left corner near the nav bar" artifact filed as KNOWN_ISSUES.md bug #1
and blamed for years on duplicate buttons. `-[BeaButton attachToAnchor:...]`
places by frame from `-convertRect:toView:` once per displayed frame instead;
`convertRect:` accounts for scroll offsets, and a missing anchor reports itself
missing rather than silently dropping the button somewhere.

**`UIScrollView.isTracking` is not "is scrolling", and there is no single feed
scroll view to read it from.** `isTracking` is YES the moment a finger lands,
before any movement, which made the "+" vanish for as long as you held a finger
anywhere on the feed; use `isDragging || isDecelerating`. The second half is what
made the fade switch do nothing at all afterwards: the feed is **two nested
`SwiftUI.HostingScrollView`s with identical bounds** — an outer horizontal pager
(Mes Amis / Amis d'Amis) wrapping the vertical timeline — so "the largest scroll
view under Home" is a tie, and the recursion broke it in favour of the ancestor.
Dragging the timeline vertically never sets `isDragging` on a horizontal pager.
`BeaFeedIsScrolling` now collects *every* scroll view under Home (cached,
re-collected at most twice a second) and answers YES if any of them is dragging
or decelerating. Do not go back to picking one.

**SwiftUI's text is invisible without the accessibility bundles.** The note
below about the accessibility tree is correct but incomplete, and the missing
half is why the gating hider still did nothing after being taught to read it:
the code that vends those elements lives in
`/System/Library/AccessibilityBundles/*.axbundle`, which UIKit only loads when
an assistive client attaches. In a normal process `-accessibilityElements`
answers nil no matter what the needles say. `+[BeaSettings
loadAccessibilityBundlesIfEnabled]` `dlopen`s them from `%ctor`. It is behind a
switch because it changes UIKit's behaviour rather than the tweak's, and the
diagnostics report says whether it worked — "the scan found nothing" and "the
scan could never have found anything" are otherwise indistinguishable.

**A view parented to a `UIWindow` has no ancestor view controller.** Both
floating buttons live on the window on purpose (to out-rank a gated post's
lock overlay). That silently breaks anything UIKit resolves by walking up to a
controller: `UIButton.menu` long-press did nothing at all, because the context
menu interaction had nothing to present from. Present sheets/menus explicitly
from `window.rootViewController`'s top-most presented controller instead.

**"Is anything presented?" is not the same question as "is something of
BeReal's presented?"** Both floating buttons are hidden while a modal is up,
because a window-parented view doesn't respect presentation z-ordering. The
download button's own long-press picker is itself a presented sheet, so the
naive test hid the button the instant its own menu opened — long press worked,
the sheet appeared, the icon under it vanished. Sheets the tweak puts up are
marked with `+[BeaButton markAsTweakPresented:]` and skipped by
`BeaHasPresentedModal`. Mark a new sheet only if the buttons should stay
visible behind it; the BeFake composer deliberately isn't marked.

**Don't let a missing private UIKit class turn into an invisible feature.**
The "+" button was pinned hidden whenever
`UIKit.NavigationBarPlatterContainer_v2` wasn't found, so a *cosmetic*
scroll-sync being unavailable removed the button entirely. Degrade to the
plain behaviour, never to nothing.

**Match BeReal's own class names as substrings, not exact mangled names.**
4.88 renamed `HomeViewHostingController` (generic → plain, so the whole
`_TtGC...` spelling changed) and moved `BlurStateUseCaseImpl` from
`FeedsFeatureDomain` to `CoreFeedDomain`. Both broke *silently* — an
exact-string comparison that no longer matches disables a feature with no
error anywhere, which is far harder to notice than a crash. Where a class
genuinely moved module, `%ctor` tries each candidate name and takes the first
that exists. (For the record, the 4.88 binary still ships
`_TtC18FeedsFeatureDomain20BlurStateUseCaseImpl` and *no* `CoreFeedDomain`
implementation — only the protocol moved. The candidate list covers both, which
is the point of writing it that way.)

**`SideloadFix/`** — only compiled into the `JAILED=1` build. Makes a
sideloaded (not actually jailbroken) install look jailbroken enough to pass
BeReal's checks: bundle ID/keychain-access-group spoofing via `fishhook`-
rebound `SecItem*` C functions, using Core Foundation Create/Copy ownership
rules correctly (`CFRelease` every `CFDictionaryCreateMutableCopy`,
`__bridge_transfer` on anything from `SecItemCopyMatching`/`SecItemAdd`) —
be careful here, this is the file most likely to leak or double-free if
touched carelessly.

**Debug logging is off by default, on purpose.** `Utilities/Debug/BeaDebug.h`
gates all verbose `[BeaNet]`/`[BeaDiag]`/`[BeaClassDump]`-style logging
(request/response bodies, view-hierarchy dumps, full class surveys — some
of which can include auth tokens/PII) behind `MINIBEA_DEBUG=1` in the
process environment, checked once via `dispatch_once`. Any new verbose or
data-dumping log must go through `BeaLog(...)`, not a bare `NSLog`/`os_log`
— this ships to end users, not just active development.

**`Utilities/Media/`** — `BeaMediaUnlock` (re-enables BeReal's own
`UIMainMediaGesturesView` recognizers on a gated post, records what it changed,
and adds one tap recognizer per photo) and `BeaMediaViewer` (the local
zoom/pan/swap screen the tap opens). Both are scoped to gated posts through
`+[BeaDownloader photoIsGated:inCard:]`, which is the same evidence the overlay
hider acts on — see the two media rules above before changing either.

**`Utilities/Settings/`** — `BeaSettings` (NSUserDefaults-backed switches,
registered with explicit defaults in `+load`) and `BeaSettingsViewController`,
reached by long-pressing the floating "+" or from the BeFake composer's menu.
Every behaviour that has ever needed a second device-testing round is a switch
there. That is not feature creep: this codebase fails silently, a sideloaded
user's only other recovery is waiting for another IPA, and a switch turns a bug
report into a bisection. Anything new that can hide or remove one of BeReal's
own views should get one.

**`Utilities/Diagnostics/BeaDiagnostics`** — the report the settings screen
shares: what resolved (string table, accessibility bundles, home controller
class), what the last scan actually found, the counters, and the full view
hierarchy including published accessibility elements. Reach for this instead of
guessing at the view tree; the device round trip is the expensive resource, not
the tokens. Verbose logging is now a switch there too (`MINIBEA_DEBUG=1` still
works, but a sideloaded install has no way to set it).

**Do not put a long report in a `UIAlertController`.** Its message label does
not scroll and is laid out to fit whatever it is given; handed the ~1.5KB
diagnostics summary it produced an alert taller than the screen with its own
dismiss button off the bottom edge — reported as "a large empty modal that
cannot be dismissed". The summary is a pushed `UITextView` now.

**Version string** lives in `Utilities/BeaVersion.h` and in `control`'s
`Version:` field. It used to be spread across three files with a `#ifndef`
guard that could not actually keep them in step — separate translation units —
and the Info screen had silently drifted to a stale `1.3.7`.

## Commit conventions

Commit as the repo owner's identity (`Shirow
<61913454+Shirowwww@users.noreply.github.com>`), with a short, plain commit
message describing the change. Don't add `Co-Authored-By` trailers,
session/agent links, or any other mention of the tool that made the change —
commits in this repo read as ordinary human commits.

## Where to look for more

- `README.md` — features, compatibility, install instructions.
- `MERGE_NOTES.md` — the original fork-merge decisions and reasoning.
- `KNOWN_ISSUES.md` — the one still-open bug (stray/duplicate download
  button), the full history of what's been tried on it, and why the
  upload-button auto-hide bug was closed by deleting the mechanism instead of
  fixing it. Read it before touching button placement or visibility.
- `tools/` — the IPA inspection and sideload-injection scripts the two
  sections below are built on.

## Investigating: read the IPA before writing a hook

Almost nothing about BeReal's internals should be guessed. A decrypted IPA
lives in `BeReal IPA/` (gitignored), and `tools/ipa_inspect.py` answers most
questions off it in seconds — no device, no Mac, no jailbreak:

```sh
IPA="BeReal IPA/BeReal_v4.88.0_Legal.ipa"
python tools/ipa_inspect.py frameworks "$IPA"                  # embedded SDK inventory
python tools/ipa_inspect.py classes    "$IPA" 'AdvertsData'    # class symbols
python tools/ipa_inspect.py strings    "$IPA" 'content/posts'  # endpoints, module names
python tools/ipa_inspect.py loc        "$IPA" '^Post to view$' # UI copy → key → 15 languages
```

Every non-obvious fact this tweak relies on came from one of those: the ad SDK
list in `BeaAdBlocker.m` (`frameworks`), the `-primary`/`-secondary` CDN
convention the download picker uses (`strings`), the 4.88 class renames
(`classes`), and the gating-overlay keys (`loc`).

Two traps worth knowing before you trust a negative result:

- **A generic Swift class's runtime name is not in the binary.** It's assembled
  at runtime, so `_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_` appears
  nowhere in `strings` output even while the class exists. Search for the bare
  type name (`HomeViewHostingController`) and match substrings at runtime.
- **Different sections, different spellings.** `NSStringFromClass` in
  Objective-C returns the *mangled* name (`_TtC11AdvertsData16AppLovinMRECView`),
  not the demangled `AdvertsData.AppLovinMRECView` that Swift's overlay gives.
  `objc_getClass()` accepts either, because the Swift runtime installs a
  lookup hook. Code that matches on a name should tolerate both — see
  `BeaAdBlocker`'s `uncachedVerdictForClass:`, which checks both spellings.

### Probing the server without an account

Endpoints can be checked unauthenticated:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://mobile-l7.bereal.com/api/content/posts/upload-url
```

401 or 403 means the route exists and just wants a token; 404 means it's gone.
Don't read anything into *which* of 401/403 comes back — 401 (text/plain) is
the auth gateway rejecting, 403 (JSON) is the app's own middleware, and which
one answers depends only on route config. This is how BeFake's upload
endpoints were confirmed still live on 4.88 rather than migrated to the
Protobuf/gRPC surface the binary also contains.

## Building and shipping without a Mac

The dev machine is Windows with no Theos and no compiler, so **CI is the only
thing that ever type-checks this repo**. `.github/workflows/build.yml` runs on
every push and builds all three variants; budget ~5 minutes per round trip.

```sh
git push                                   # the only compile check that exists
gh run list --branch main --limit 1
gh run view <id> --log | grep -E 'error:|warning:'   # expect zero of both
```

Do not merge on a red build, and do not assume a change is fine because it
"looks like" the code next to it — Logos generates real code from `%hook`,
and its failure modes (a `%new` method that can't be message-sent without a
declaration, `%orig` on a method the class doesn't implement) only show up
here.

### Producing a sideload IPA locally

`build_ipa.sh` needs azule/macOS and cannot run here. The Windows path uses
the scripts in `tools/`, and works because the `JAILED=1` build has no
CydiaSubstrate dependency — so a plain load-command insert is all that's
needed:

```sh
gh run download <id> -n minibea-packages -D pkgs
python tools/extract_deb.py pkgs/*_jailed.deb extract   # .deb is an ar archive
python tools/patch_ipa.py "BeReal IPA/BeReal_v4.88.0_Legal.ipa" \
    extract/MiniBea.dylib "BeReal IPA/BeReal_4.88.0+minibea.ipa"
```

`patch_ipa.py` rewrites the dylib's `LC_ID_DYLIB` to
`@executable_path/Frameworks/MiniBea.dylib`, appends an `LC_LOAD_DYLIB` into
the app binary's existing header padding (no file offsets shift), drops the
app's now-stale `_CodeSignature`, and rezips preserving each entry's attributes.
The user re-signs with Sideloadly/AltStore. `tools/macho.py` holds the Mach-O
surgery; `thin_macho.py` at the repo root is a *different* tool (fat-slice
stripping for `build_ipa.sh`'s azule path) and isn't part of this flow.

Verify before handing an IPA over — a silently broken one wastes a whole
device-testing round:

```python
import zipfile, sys; sys.path.insert(0, 'tools'); import macho
z = zipfile.ZipFile(ipa); exe = z.read('Payload/BeReal.app/BeReal')
for off, _ in macho.slices(exe):
    i = macho.describe(exe, off)
    assert i['cryptid'] == 0 and any('MiniBea' in d for d in i['dylibs'])
assert z.testzip() is None
```

## Diagnosing a "it still doesn't work" report

This codebase fails silently by construction — an exact class-name match that
stops matching, an English-only string compare on a French device, a
window-parented view UIKit can't find a controller for. None of them crash or
log. Two habits follow:

1. **Ask a few precise, mutually-exclusive questions before writing code.**
   One round of "is the button invisible, or visible but inert?" / "is the ad
   a full page or a block?" / "which build is installed?" separated four
   distinct root causes that would otherwise have taken four build-and-flash
   cycles to isolate. Device round trips are the expensive resource here, not
   tokens.
2. **Prefer degrading to working over failing closed.** Every silent-failure
   bug found so far came from code that disabled a feature when a lookup
   missed. If a private class isn't found, keep the button and skip the
   nicety; if a localized string can't be resolved, fall back to the English
   literal.

For anything that needs real runtime data, `MINIBEA_DEBUG=1` in the process
environment turns on `[Bea*]` logging (see `Utilities/Debug/BeaDebug.h`); it is
off by default because some of it can include tokens and PII.

## Editing conventions

- Source files are LF in-repo; git converts on a Windows checkout. `AGENTS.md`
  uses em dashes (—), `README.md` uses plain hyphens — match the file you're in.
- The version string lives in **three** files that must move together (see
  Architecture above). Bump it whenever you hand the user a new build, so
  "which build are you on?" is answerable.
