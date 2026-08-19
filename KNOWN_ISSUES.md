# Known Issues

## 1. Stray/duplicate download button

**Symptom:** a download button can occasionally show up somewhere it
shouldn't (originally seen stuck near the nav bar, mostly off-screen). Last
reproduced on BeReal 4.58, and not re-confirmed since the 4.88 class-name
fix changed which controller the button code runs on in the first place
(see `AGENTS.md`, "Match BeReal's own class names as substrings").

**Mitigation in place:** `BeaRemoveStrayButtons` in `Tweak/Tweak.x` runs
before each floating button is (re)created and removes any existing view
under the window carrying that button's `accessibilityIdentifier` that
isn't the one currently tracked. This doesn't fix the root cause, but keeps
a stray button from persisting once its kind is next recreated.

**If picked back up:** get a real device log first (`MINIBEA_DEBUG=1`,
filter for `[BeaDiag]`/`[Bea]`) capturing the stray button's anchor view
class, frame, and identity at creation time, rather than guessing again.

## 2. BeFake "+" doesn't hide in sync with the nav row

Closed: the button is now always visible while the feed is on screen,
because the sync attempt (tracking the nav row's own hide/show animation)
was what made it disappear entirely on some devices instead.
