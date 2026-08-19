# Known Issues

## The tap that never arrived, and an ad blocker nobody could prove ran (2026-08-19, 0.9.4)

### Every premise of the media unlock was true and it still did nothing

The 0.9.3 diagnostics report closed off, from the device, every explanation the
last three rounds had reached for. Two `BeaMediaTapOverlay`s existed, framed
exactly over the two photos, as the last two subviews of the post card. The post
was correctly seen as gated ("BeReal gestures view held disabled"). The gating
layer pass had found and hidden its six layers. `Overlay re-orders: 0/s now,
peak 0/s, 0 total` - SwiftUI never once re-appended a view after ours, so the
sibling order everything depended on was stable, not contested.

And `[window hitTest:centreOfMainPhoto]` answered
`_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer`: the feed's scroll
content container, several levels *above* the card. `-hitTest:withEvent:` never
descends into a view whose ancestor declined the point, so the touch was being
refused somewhere between the window and the card - by one of BeReal's views, on
a path our overlay is not even on. Nothing about the overlay could have fixed
that, which is why three rounds of making the overlay more correct changed
nothing.

A `UIView` refuses a point for four documented reasons - `hidden`,
`alpha < 0.01`, `userInteractionEnabled == NO`, `-pointInside:withEvent:` - plus
a fifth indistinguishable from outside: an overridden `-hitTest:` returning nil
or choosing another branch. `userInteractionEnabled` is the one thing already
force-set to YES on the card and every ancestor, ten times a second, immediately
before the probe runs; the other four had never been looked at. Rather than pick
one, the report now walks the whole chain from window to overlay and prints all
five per link, stopping at the first that breaks it (`Hit chain break:`). The
next report answers this instead of narrowing it.

The fix does not wait for that answer, because it does not depend on it: a tap
that cannot be routed by descent is routed by a recognizer that does not descend.
One `UITapGestureRecognizer` on the `UIWindow` sees every touch the window
delivers to anything. Its delegate accepts a touch only inside a registered
overlay's rect and only when nothing control-like (or `Bea*`-prefixed - the
tweak's own window-parented download button sits in the photo's corner) won the
hit test, and it recognises simultaneously with everything and cancels nothing,
so on any other screen, or any other point, it is inert. This is deliberately
not the window-*parented view* the rules forbid: no view is added, nothing
outranks a modal, no z-order is involved.

### "Ad requests blocked: 0" was never evidence of anything

The same report was read as "the ad toggle does nothing". There are four ad
switches driving four unrelated mechanisms, and the report could not distinguish
any of the three ways it could have looked like that:

- **there was no ad on screen.** The most likely reading, and the one the report
  could not support or refute. `Ad SDKs loaded:` now reads dyld's image list, so
  "no third-party ad SDK is even in this process" is a stated fact. BeReal's own
  SwiftUI-drawn sponsored post is caught by a different mechanism again, and that
  one can only be judged from a report captured while such a post is visible.
- **the needle was corrupt.** `general_sponsored = "SponsorisÃ©"` in the shared
  file is UTF-8 read as Latin-1, and if the *string in memory* were that, the
  sponsored scan could never match anything in any language. The summary prints
  the needle's UTF-8 bytes now (`c3 a9` correct, `c3 83 c2 a9` double-encoded),
  and the report file carries a BOM so a reader cannot guess Latin-1 at it.
- **the protocol was in nobody's session.** Registering an `NSURLProtocol`
  reaches only `NSURLConnection` and `[NSURLSession sharedSession]`, and
  swizzling the two configuration factories misses any configuration built
  before `%ctor` ran or reassigned afterwards - with no error, and with exactly
  this symptom. `+[NSURLSession sessionWithConfiguration:...]` is the last point
  at which that is fixable, so it is now both repaired and counted there:
  `URL sessions seen: N (M repaired)`.

## The freeze, and the settings screen that erased itself (2026-08-19, 0.9.3)

Two device reports against 0.9.2, one mechanism each, and neither is a tuning
problem.

### Writing UIKit state from inside a layout pass

`%hook UIViewController -viewDidLayoutSubviews` runs for *every* controller in
the app, and 0.9.2 made it, for the home feed, also set
`navigationItem.leftBarButtonItems`. That assignment lays the navigation bar
out and makes SwiftUI re-publish its `.toolbar`, which invalidates the hosting
controller's layout - and brings UIKit straight back into the same hook, inside
the same commit. Every iteration of that loop then ran the three full-tree
scans the hook already did unconditionally (qualifying photos, gating markers,
sponsored markers, each a recursive walk of a SwiftUI tree thousands of nodes
deep), and each of *those* hides or removes views, which dirties layout again.

It is not a deadlock, which is why the three-finger suspend could still be
recognised: the run loop kept turning, each turn just took seconds. Suspending
the tweak stopped it because every one of those scans, and the bar-item
reconcile, reads `+[BeaSettings effectiveBoolForKey:]` and returns immediately
while suspended.

What distinguishes this from the other candidate - the media tap overlays
calling `-bringSubviewToFront:` on a card SwiftUI keeps re-appending to - is
where each one is driven from. The overlay reorder runs from the display link,
outside any layout pass, so it can cost at most one extra layout per tick, ten
a second, and cannot re-enter itself. The bar item ran *during* layout, and was
the only thing in 0.9.2 that could. The overlay reorder was still wrong (twenty
forced card layouts a second to re-establish an order that keeps changing back)
and is now rate-limited to 2Hz per card, but it was not the freeze.

Both are now counted permanently, so the next report answers this from the
device instead of from an argument: the diagnostics summary carries bar-item
re-inserts, overlay re-orders, layout passes and full-tree scans as a live
per-second rate, a peak and a total, and anything past a threshold logs a
`[BeaLoop]` line whether or not verbose logging is on.

The rules that came out of it: nothing of ours mutates a view from inside a
layout pass (a re-entrancy guard enforces it, not a convention); the full-tree
scans are rate-limited per controller to ~10Hz instead of running once per
layout; the "+" is reconciled only from the display link; and
`-bringSubviewToFront:` is only ever called when the order is actually wrong.

The "+" also has the opposite safety net now. If SwiftUI's toolbar turns out to
drop our bar item on most passes for several seconds running, that is a fight
no rate-limit can win - it just loses more slowly - so the button falls back to
the documented window-parented placement for the rest of the session and the
report says why. That is measured from the counter, not guessed.

### The settings screen was eaten by its own scanners

Reported three times, "fixed" twice by arguing with `UITableView` about
self-sizing cells, and finally closed by replacing the table with a scroll view
and a stack - after which the screen rendered completely empty. None of that
was ever the mechanism.

This tweak's screens are ordinary UIKit views inside BeReal's window, and two
of its scanners hunt for BeReal's localized copy anywhere under a view
controller's root view. The settings screen explains what each switch does, so
it renders that copy verbatim:

    settings.gating_hide          fr = "Masquer le voile « Poste pour voir »"
    settings.ads_sponsored_detail fr = "... la mention « Sponsorisé »."

`Poste pour voir` is `timelineCell_blurredView_title`; `Sponsorisé` is
`general_sponsored`. The gating hider found the first, walked up to the row's
card and stripped every non-button view inside it; the sponsored remover found
the second and collapsed the card around it. Both did exactly what they exist
to do, to the wrong screen. With a table that showed up as blank rows and gaps
the height of the rows that should have been in them - which is precisely what
the second report described and what made "the table measured correctly and
still drew nothing" so hard to place.

Every scan now prunes anything of ours: the class-name prefix every class in
this project carries, plus an explicit mark on the root view of anything the
tweak presents (`BeaOwnership.h`), and the layout hook returns immediately for
a `Bea*` controller. Do not "fix" a tweak screen that renders wrong by adjusting
its constraints before checking whether the tweak ate it.

## Four device reports, four mechanisms replaced (2026-08-19, 0.9.2)

Every one of these had already been "fixed" at least once by tuning the
mechanism it used. In each case the mechanism was the bug.

### The "+" was never part of the top chrome

Three successive versions of this button were a `UIView` parented to the
`UIWindow` that tried to look like it belonged to BeReal's header: constrained
to the window safe area, then anchored to the navigation bar's frame and
re-placed every displayed frame, then with the inset measured from BeReal's own
leading icons rather than assumed. Each produced its own drift report. The
diagnostics from 0.9.1 say it plainly - resolved anchor `UINavigationBar`,
actual button a direct child of `UIWindow`.

It is now a real `UIBarButtonItem` on `navigationBar.topItem`'s
`leftBarButtonItems`. UIKit lays it out in the row's own coordinate space, a
modal covers it like any other bar content, and there is no offset left to
tune. BeReal builds that bar from SwiftUI's `.toolbar`, which republishes the
array on state changes, so attachment is reconciled on every ~10Hz pass - a
pointer comparison against a two-or-three element array. The window-parented
placement survives only as the degraded path for a screen with no navigation
bar at all.

### Hit-testing does not fall through to earlier siblings

The media unlock put a tap recognizer on the `SDAnimatedImageView` and held
`RealComponents.UIMainMediaGesturesView`'s `userInteractionEnabled` at `NO`,
expecting the touch to reach the photo underneath. `-hitTest:withEvent:` does
not work that way: it returns the deepest view that claims the point in the
*last* branch that claims it at all, and never resumes searching earlier
siblings. Disabling the innermost gestures view only promoted its
still-interactive SwiftUI wrappers - identical frame - to being the result. The
touch landed in the gestures branch; a recognizer in the photo branch is
neither that view nor an ancestor of it, so UIKit never delivered it. Tapping a
gated photo did nothing at all.

The tap target is now a `BeaMediaTapOverlay` of our own, added as the last
subview of the post card and framed over each photo. The last sibling wins
outright, so it needs nothing from BeReal's own interaction flags. The gestures
view is still held disabled while the post is gated, now as defence in depth:
if SwiftUI rebuilds the card between two passes, the worst case must be "the
tap does nothing", never "the tap opens the composer".

### The scroll fade watched the wrong scroll view

`BeaHideButtonsWhileScrolling` was on and did nothing. The feed is two nested
`SwiftUI.HostingScrollView`s with *identical* bounds - an outer horizontal
pager (Mes Amis / Amis d'Amis) wrapping the vertical timeline - and "the
largest scroll view under Home" is a tie that the recursion broke in favour of
the ancestor. Dragging the timeline vertically never sets `isDragging` on the
horizontal pager, so the answer was always NO.

There is no single correct scroll view to identify here. It now collects every
scroll view under Home (cached, re-collected at most twice a second) and
answers YES if any is dragging or decelerating, which is also the honest form
of the question being asked.

### Self-sizing table cells, twice

Two rounds of reports described rows missing, blank gaps, split sections and
text under the navigation bar; two rounds of fixes argued about
`estimatedRowHeight` (`0`, then `UITableViewAutomaticDimension`). The second
report's gaps were the same height as the rows meant to be in them, which says
the table had measured correctly and still drew nothing.

The screen is a dozen static rows of a title over a two-to-five-line
explanation. There is no recycling to gain and no scroll performance to
protect, and every failure mode is specific to the estimate-then-correct
machinery. It is now a `UIScrollView` + `UIStackView` of plain views, laid out
by ordinary Auto Layout. Closed the same way bug #2 was: by deleting the
mechanism.

## A master runtime suspend, not a check in every file (2026-08-19, 0.9.2)

Hold three fingers for ~2s and every visible or behavioural part of the tweak
stops; hold again and the user's own configuration comes back. It is
deliberately not a new condition threaded through a dozen call sites - that is
exactly how the ad switches became one-way doors. It suspends the *switches*:
`+[BeaSettings effectiveBoolForKey:]` answers NO for every suspendable key
while `+[BeaRuntime isSuspended]` is on, and flipping it posts the ordinary
`BeaSettingsDidChangeNotification` for each of those keys, so every undo path
that already existed runs unchanged.

Nothing is persisted and no stored preference is read or written. The
jailbreak-detection bypass is deliberately *not* suspended: switching it off
mid-session would not restore native behaviour, it would get a sideloaded
install logged out, and it changes nothing anyone can see.

## One button per post, and one place that decides visibility (2026-08-19)

Three reports, one shape: the injected buttons did not belong to anything.

- There was exactly **one** download button per Home controller, anchored to
  the first qualifying photo in the whole feed. With two posts on screen the
  second had no button at all until the first scrolled far enough away to stop
  counting as prominent. `BeaSyncDownloadButtons` now reconciles the set
  against every post currently on screen, reusing buttons by position in that
  order rather than by anchor identity — BeReal recycles its `UIImageView`s, so
  identity is not a stable key for anything (that is the whole history below).
- The "+" was pinned to the *window's* safe area, which is a fixed offset from
  the screen. When iOS 26's chrome moved BeReal's header row, the button stayed
  where it was. It is now anchored to the `UINavigationBar`'s live frame with
  the same per-frame placement the download buttons use.
- Both stayed visible on top of the settings sheet, because that screen was
  marked with `+[BeaButton markAsTweakPresented:]` — an exemption that exists
  for the small action sheets *anchored to a button* (hiding the button under
  its own menu is the bug that marker was added for). A full sheet must not be
  marked. Visibility for every injected button is now decided once per frame in
  `-[BeaVisibilitySyncTarget bea_tick:]`, which is also the only place that can
  observe a modal going up: while one is presented, Home does not lay out at
  all, so a `-viewDidLayoutSubviews` hook cannot react to it.

`+syncAnchoredButtons` owns `hidden` (both directions — it is the only thing
that knows whether a button's anchor is still on screen) and the per-frame
policy only writes `alpha`. UIKit's hit testing already ignores a view at alpha
0, so a faded button is untappable as well as invisible, and the two writers
cannot fight.

## The gating overlay is not a view, and never was (2026-08-19)

A device report of "0 marker(s) found" alongside a screenshot that plainly
says **Poste pour voir** finally settled this. The full view dump for a gated
post contains the header row, the "..." button, both photos and
`RealComponents.UIMainMediaGesturesView` — and nothing else. No scrim, no
title, no body line, no CTA button, and no accessibility element carrying any
of that text either.

That is normal SwiftUI, not a broken scan: SwiftUI only materializes a `UIView`
for content it has to bridge to UIKit, and draws a plain
`ZStack { scrim; Text; Text; Button }` straight into `CALayer`s. **A scan that
walks views and accessibility elements cannot see it, however correct its
needles are.**

Two changes follow:

1. When the view/accessibility scan finds nothing, `hideGatingOverlaysInView:`
   falls back to the drawing layers stacked over the post's own photo — layers
   whose delegate is not a `UIView` (so both photos, the gesture view and every
   control are excluded outright), drawn above the photo in the same sublayer
   array, and no more than ~1.6x its area. Every guard is there to make the
   failure mode "the overlay stays" rather than "the feed goes blank".
2. The diagnostics report now dumps the **layer** tree alongside the view tree.
   That is the half of the screen the report could not show, and on 4.88 it is
   where most of the feed actually is.

## Switches have to be undoable (2026-08-19)

Most of them were one-way doors: turning "remove ad views" off changed nothing
until relaunch, because the ad was already gone and the only hook that could
have put it back fires on *insertion*. `BeaSettings` now posts
`BeaSettingsDidChangeNotification`, every collapse records the state it
replaced (`BeaSuppressionRecord`, `BeaGatingEdit`), and the ad-network
`NSURLProtocol` is registered unconditionally and reads its switch **per
request** instead of once at launch. Only the accessibility bundles still need
a relaunch, because they have to be `dlopen`'d before SwiftUI builds its trees.

A switch that cannot be un-flipped is worse than no switch: it turns "turn it
off and tell me what changes" into "reinstall".

## Bugs #1 and #2 traced to one mechanism (2026-08-19)

The stray download button "stuck in the top-left corner near the nav bar"
(bug #1) and the "+" behaving oddly during a drag (bug #2) were both
consequences of positioning a window-parented button with
`NSLayoutConstraint`s pointing at a photo inside the feed's scroll view:

- Scrolling changes the scroll view's `bounds` origin, which is not a layout
  change of the photo's frame in its superview, so the constraint solver never
  re-places the button. Every "the button is attached to the wrong post"
  report is this.
- When BeReal recycles the photo out of the hierarchy, the button and the
  photo stop sharing a common ancestor and UIKit deactivates those constraints
  for us. The button is then entirely unconstrained and lands at the window
  origin — the top-left artifact, which was never a duplicate button at all.
  Three rounds of duplicate-button theories (see the history below) were
  chasing the wrong mechanism.

`-[BeaButton attachToAnchor:corner:inset:]` now places by frame from
`-convertRect:toView:` once per displayed frame, and hides the button when its
anchor is gone. **Unverified on a real device.**

Separately, the scroll-linked fade read `UIScrollView.isTracking`, which is
already YES on finger-down — holding a finger anywhere on the feed made the
"+" disappear until you let go. The fade now reads `isDragging ||
isDecelerating` and is **off by default**, behind a switch. Do not turn it back
on by default: it has taken four rounds and has never once been the behaviour
that was asked for.

## The ad card and the gating overlay may never have been readable

Both features find their target by matching BeReal's own copy, and both look
in the accessibility tree because BeReal's feed is SwiftUI and draws its text
without creating a UILabel. What the previous round missed is that the code
vending those elements lives in `/System/Library/AccessibilityBundles/`, which
UIKit only loads when an assistive client attaches — so in a normal process
the scans had nothing to read regardless of how correct the needles were. See
`+[BeaSettings loadAccessibilityBundlesIfEnabled]`.

Two things follow, both shipped:

1. The sponsored card now also gets collapsed by walking up from a *removed ad
   view* (`+collapseCardAroundRemovedAdInContainer:`), which needs no text at
   all and is bounded by the same `viewIsPlausibleSponsoredCard:` guard.
2. The diagnostics report says whether the bundles loaded, whether the string
   table resolved, and how many markers the last scan found — so the next
   round starts from data instead of another theory.

Also fixed: the 400 ms throttle on the expensive accessibility pass was a
single global timestamp shared by both scans, and they run from the same
layout pass — whichever asked first took the slot and the other was answered
"nothing found" permanently. It is now per-scan.

## Bug #2 re-approached from the scroll view instead (2026-08-18)

The user's remaining complaint about the "+" was that it stays put while you
drag down through the timeline, sitting on top of whatever post is sliding
past. Three rounds were spent trying to read that state off
`UIKit.NavigationBarPlatterContainer_v2` (see the history below) and none of
them worked.

`bea_tick:` now asks the feed's own `UIScrollView` instead — `isTracking ||
isDragging || isDecelerating` — and eases the button's alpha to 0 while that
is true. No private class is involved, so the failure mode when nothing is
found is "not scrolling", i.e. the button stays visible, which is what the
note below requires. The platter is still consulted when it happens to exist,
but only to take the *minimum* of the two alphas; it can no longer decide the
button is gone. The scroll view is cached weakly and re-resolved at most twice
a second, since this runs on the display link. **Unverified on a real device.**

## Bug #2 closed by removing the feature it depended on (2026-08-18)

The upload "+" button no longer tries to sync with the nav row's scroll-hide
at all when it can't. It turned out the sync attempt was worse than the bug:
`bea_tick:` set `hidden = YES` whenever
`UIKit.NavigationBarPlatterContainer_v2` couldn't be found, so on a device
where that private class doesn't exist the button was invisible permanently.
It is now always window-parented and visible whenever Home is on screen; the
platter is consulted only to mirror the row's opacity when it happens to
exist. A button that stays put while the row hides is a cosmetic imperfection
and is not worth another round of this. **Do not re-introduce a code path that
can hide the button when a private class lookup fails.**

## Read this first (2026-08-18)

Both bugs below were investigated against BeReal **4.58**, and every attempted
fix was reasoned about on the assumption that the button code was running at
all. On **4.88** it was not: `HomeViewHostingController` stopped being a
generic Swift class, so its ObjC runtime name changed from
`_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_` to plain
`BeReal.HomeViewHostingController`, and the exact-string comparison in
`Tweak.x` could never match it. Neither floating button (post download, BeFake
"+") was created anywhere on 4.88, with no crash and no log to say so. That is
fixed (substring match, see `BeaHomeViewHostingControllerClassName`).

This matters for the two bugs below because it means **neither has been
observed on a build where the fix is present**. Before spending another round
on either, re-test on 4.88 first: the symptoms may be different, gone, or (for
bug #1) may have had a different cause all along - a stray button appearing
while the tracked controller never matched is a meaningfully different picture
than the one those investigations assumed.

Deliberately deprioritized for now per explicit user decision (2026-08-14) -
download-button photo accuracy was the higher priority and is confirmed
correct as of commit 9a8af4b. Revisit these when there's time to gather real
device diagnostic data rather than guessing further.

## 1. Stray/duplicate download button still appears

**Symptom:** A download button shows up somewhere it shouldn't - originally
reported as stuck in the top-left corner near the nav bar, mostly off-screen.
Confirmed still present after commit 9a8af4b, which scoped all download-button
logic (search, creation, staleness) to only run on
`HomeViewHostingController`'s own `viewDidLayoutSubviews` pass.

**What's been tried, in order:**
1. Required `localContainerForAnchor:` to find a genuine front+back pair
   before creating a button, not just any single qualifying image
   (`04609e6`) - fixed one cause, not this one.
2. Required the anchor to be displayed at near-full post width, not just any
   on-screen overlap (`fabbbd8` / `4f5b110`) - ruled out grid-view thumbnails
   and small chrome elements as anchors.
3. Tracked buttons globally by which photo (anchor view) they're attached to,
   instead of per-controller, on the theory that `MainTabBarController` gets
   its own independent `viewDidLayoutSubviews` call and - since its view
   contains the exact same post content as a descendant of
   `HomeViewHostingController` - was independently rediscovering the same
   anchor and creating its own duplicate button (`41360c9`). This *did* clear
   the originally-reported corner artifact, but introduced a worse
   regression: BeReal recycles `UIImageView` instances as the feed scrolls,
   and the anchor-keyed map treated a recycled view as "already has a
   button" without ever refreshing which post it actually searches - causing
   wrong photos to download, some posts to get no button at all, and (still)
   duplicate buttons in other cases.
4. Reverted the global map back to per-controller tracking, scoped to only
   run when `self`'s class matches `HomeViewHostingController`'s exact
   mangled name (`_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_`),
   which should have independently fixed the original
   MainTabBarController-duplication theory without the global map's new
   risks (`9a8af4b`). **User confirmed download accuracy is correct again,
   but the stray/duplicate button symptom is still present.**

**What this means:** the MainTabBarController-independent-discovery theory
from step 3 may not be the (sole) actual cause, since scoping the whole block
to Home-only should have eliminated it entirely if it were. Either there's a
different root cause producing a visually similar symptom, or something about
Home's own single-button tracking still has a gap (e.g. the same
view-recycling behavior that broke the global map in step 3 might affect the
per-controller model too, just manifesting differently).

**Next step, if picked back up:** don't guess again - re-add targeted
`os_log` diagnostics (the pattern used successfully throughout this project:
filter device logs for `[BeaDiag]`/`[Bea]` with `MINIBEA_DEBUG=1` set, see
`Utilities/Debug/BeaDebug.h`) specifically logging the stray button's own
anchor view's class, frame, and identity whenever it's created, plus whether
it matches any button already tracked for the real, correctly-positioned
post. Get one real device log capture before changing code again.

**Checked against the tqmane fork (2026-08-17 merge):** no fix - tqmane's
button-placement code is a fundamentally different mechanism (per-view
hooks on `SDAnimatedImageView`/`UIImageView`/`DoubleMediaViewUIKitLegacyImpl`
that each independently add their own button, rather than this file's single
per-controller anchor tracking), so nothing there explains or fixes this
bug. Importing those hooks alongside the existing logic was considered and
rejected - see `MERGE_NOTES.md` - since running both mechanisms at once
would almost certainly make stray/duplicate buttons *more* likely, not
less.

**Defensive mitigation added (2026-08-17):** `BeaRemoveStrayButtons` in
`Tweak.x` now runs right before each of the three floating buttons
(download, profile-picture, upload) is created, and removes any existing
view under `window` carrying that button's `accessibilityIdentifier`
(defined in `BeaButton.m`) that isn't the one this controller is already
tracking - since a genuinely-tracked button never reaches the "create a new
one" branch in the first place, anything found there is by construction
orphaned. This doesn't identify or fix the root cause above (still unknown
without device logs), but should stop an orphaned button from ever
persisting past the next time its kind is (re)created - i.e. it should turn
"a stray button appears and stays" into, at worst, "a stray button flickers
briefly before the next legitimate creation clears it." Unverified on a
real device.

## 2. Upload button doesn't hide when the nav row auto-hides on scroll

**Symptom:** The feed's own "Liquid Glass" nav row (add-friend icon,
wordmark, notification bell) hides itself when scrolling down and reappears
on scrolling up. The upload "+" button we add next to it does not hide/show
in sync - it just stays visible the whole time.

**What's been tried:**
1. Polling the platter's (`UIKit.NavigationBarPlatterContainer_v2`) `.hidden`
   / `.alpha` / on-screen state inside `viewDidLayoutSubviews` (`91bbcb5`
   through `41360c9`) - never worked, most likely because
   `viewDidLayoutSubviews` only fires when layout is invalidated, and a
   scroll-hide animation driven by `transform`/`alpha` doesn't invalidate
   layout at all, so the hook may simply never re-fire during it.
2. Replaced polling with a `CADisplayLink` reading the platter's live
   `presentationLayer` every frame instead, added to
   `NSRunLoopCommonModes` so it keeps firing during active scroll tracking
   (`b1ae137`). Still didn't work.
3. Suspected `CALayer.opacity` doesn't compound into descendant layers' own
   property values, so if the fade is applied to an *ancestor* of the platter
   rather than the platter itself, reading the platter's own
   `presentationLayer.opacity` would always misreport 1.0. Added
   `BeaEffectiveOpacity` to walk the full ancestor chain up to the window,
   multiplying live opacities together (`9a8af4b`). **User confirmed this
   still doesn't work.**

**What this means:** the hide mechanism likely isn't opacity-based at all
(ruling out hypothesis 3), or the `CADisplayLink` isn't actually observing
the right view, or isn't firing when expected despite `NSRunLoopCommonModes`.
Genuinely unclear without live data at this point.

**Next step, if picked back up:** same as above - get real diagnostic data
before another blind attempt. Candidates: log the platter's frame/opacity/
hidden state from the display link tick at intervals during a manual scroll
test, to see whether the values themselves are ever changing at all (rules
in/out whether the display link is even running and finding the right view).

**Checked against the tqmane fork (2026-08-17 merge):** no direct fix, but a
real, untried lead surfaced by comparing the two forks' approaches. tqmane's
own upload button never has this problem in the first place, because it's
added as a plain subview *inside* the nav row's own view hierarchy
(`[logoContainer addSubview:uploadButton]`) rather than attached to the
window - it inherits whatever transform/alpha animation BeReal applies to
hide/show that row for free, no polling or `CADisplayLink` needed at all.
This file's button lives on the window instead specifically so it can
out-rank a gated post's lock overlay (see the comment above
`BeaDownloadButtonKey` in `Tweak.x`) - but that overlay only ever covers an
individual post's photo, never the nav row itself, so the upload button may
not actually need window-level attachment for that reason. Re-parenting it
to `UIKit.NavigationBarPlatterContainer_v2` (already located via
`BeaFindViewByClassName`) instead of `window`, with constraints relative to
the platter instead of `window.safeAreaLayoutGuide`, is a concrete next
experiment - not applied in this merge because Nikolozi's own commit history
(`91bbcb5` "Add the upload + button, anchored to the real nav-bar platter"
through `bf6310c` "Fix upload button landing off-screen") already shows
platter-relative positioning has bitten this project before, and getting
the constraint math right needs a real device to verify, not a guess.

**Fix attempted (2026-08-17):** the button is now added as a real subview
of the platter (`[platter addSubview:uploadButton]`, constraints relative to
`platter.leadingAnchor`/`platter.topAnchor`) whenever the platter can be
found on the Home controller's first layout pass, exactly the re-parenting
idea above - `BeaVisibilityDisplayLink`'s `bea_tick:` now skips its
window-only sync logic entirely once the button's superview isn't the
window. Falls back to the previous window-attached + display-link-synced
behavior if the platter isn't found (e.g. an older BeReal layout), so this
shouldn't regress anything even if the platter-parented path turns out to
still not work. **Unverified on a real device** - the exact positioning
constants (leading +64, top +8) are carried over from the window-relative
version on the assumption that the platter's own bounding box tracks the
screen edges closely enough (per the existing comment on
`BeaHomeViewHostingControllerClassName`/`BeaFindViewByClassName`), which
needs confirming against an actual screenshot. If the button ends up
mispositioned or the platter rejects/reflows around the injected subview,
reverting to pure window-attachment (delete the `if (platter)` branch,
always take the `else`) is the safe rollback.
