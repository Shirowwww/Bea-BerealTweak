# Known Issues

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
