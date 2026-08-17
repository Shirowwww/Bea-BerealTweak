# Known Issues

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
filter device logs for `[BeaDiag]`/`[Bea]`) specifically logging the stray
button's own anchor view's class, frame, and identity whenever it's created,
plus whether it matches any button already tracked for the real, correctly-
positioned post. Get one real device log capture before changing code again.

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
