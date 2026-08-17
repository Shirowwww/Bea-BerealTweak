# Merge Notes - MiniBea fork integration

Integration of [NikoloziKhachiashvili/MiniBea](https://github.com/NikoloziKhachiashvili/MiniBea)
(base) with relevant improvements from [tqmane/MiniBea](https://github.com/tqmane/MiniBea),
both forked from the common upstream [yandevelop/MiniBea](https://github.com/yandevelop/MiniBea).

- **Merge-base of all three:** `2e6f985` ("Bump version") - the tip of
  `yandevelop/MiniBea main`. Both forks branched from this exact commit and
  upstream hasn't moved since, confirmed via `git merge-base` on all three
  pairs.
- **Base kept:** Nikolozi's `main` (85 commits since the merge-base),
  merged into this repo with full history via
  `git merge --allow-unrelated-histories nikolozi/main`.
- **Version:** `0.4.0-merged` (`control`, `Tweak.h`'s `TWEAK_VERSION`, and
  `BeaInfoViewController.h`'s copy - previously a stale, unrelated `1.3.7`
  that never matched `control` even before this merge).

## Why Nikolozi as the base

Nikolozi's fork (32 commits over Nikolozi's own history) rebuilt the
download-button/unblur/gating logic around generic, dynamically-resolved
hooks (`UIViewController.viewDidLayoutSubviews` + recursive view scanning)
instead of hardcoding BeReal's Swift-mangled class names, with real
front+back photo pair detection, per-post local-container scoping, a
profile-picture download button, and a documented, carefully-reasoned
history of trial and error (see `KNOWN_ISSUES.md`). tqmane's fork (40
commits) instead hard-hooks several specific view classes directly
(`SDAnimatedImageView`, `UIImageView`, `DoubleMediaViewUIKitLegacyImpl`),
each independently adding their own download button - and its own
downloader (`BeaDownloader.m`) only ever saves a *single* image, not the
front+back pair. Per the task brief, Nikolozi's implementation is strictly
more advanced in this area and was not replaced.

## What was imported from tqmane

- **BeReal 4.58+ jailbreak-check class.** `BeaJailbreakCheck`
  (`_TtC6BeReal14JailbreakCheck`) is BeReal's own new jailbreak-detection
  class as of 4.58.0 - absent from Nikolozi's fork entirely. Hooked in
  `Tweak.x`, resolved dynamically in `%ctor` (no-ops safely if absent on
  older BeReal versions), same pattern Nikolozi already used for
  `AdvertsDataNativeViewContainer`.
- **Wider ad/analytics-SDK jailbreak-detection bypass.** Added `SHKDeviceInfo`
  (Shake), `ADJDeviceInfo` (Adjust), `GADDeviceInfo` (Google Ads),
  `FBAdUtility` (Meta), a generic `UIDevice.isJailbroken` fallback, a
  `UIApplication.canOpenURL:` scheme block for `cydia`/`sileo`/`zebra`/
  `filza`/`undecimus`/`activator`, plus `PAGDeviceHelper.isJailBroken` and
  `STKDevice.isDebug` (Nikolozi only had the other methods on those two
  classes).
- **Rootless/jailed environment checks - `NSFileManager` coverage.**
  tqmane's `isBlockedPath` (pure C, no ObjC - matters because it runs from
  hooks that must stay safe very early) replaces Nikolozi's narrower version:
  adds a `BeReal.app`-path allowlist and many more blocked prefixes/paths,
  including the `/var/jb/...`-prefixed rootless variants of the same
  jailbreak-app paths. Also widened from Nikolozi's single
  `fileExistsAtPath:` hook to tqmane's full set: `fileExistsAtPath:
  isDirectory:`, `isReadableFileAtPath:`, `isWritableFileAtPath:`,
  `attributesOfItemAtPath:error:`, `destinationOfSymbolicLinkAtPath:error:`,
  `contentsOfDirectoryAtPath:error:`.
- **BeReal 4.58+ blur-state hooks.** `BlurStateUseCaseImpl` and
  `NewDoubleMediaViewModel` (both new in 4.58.0) forced to report
  "not blurred", *alongside* (not instead of) Nikolozi's existing `CAFilter`
  gaussianBlur-radius fallback hook - per the brief, this is exactly the
  "complementary hook for recent versions" case, not a replacement.
- **Auth-header capture robustness.** `setAllHTTPHeaderFields:` now always
  refreshes the captured token (tqmane's fix - handles mid-session token
  refresh; Nikolozi's original only ever captured once via a `!headers`
  guard) and a new `setValue:forHTTPHeaderField:` hook covers the case where
  BeReal's networking sets `Authorization`/`bereal-device-id` one header at a
  time instead of via a full dictionary. Neither hook logs header *values*.
- **Rootless packaging (`Makefile`).** tqmane's
  `ifeq ($(THEOS_PACKAGE_SCHEME),rootless) ARCHS = arm64` conditional. This
  was a real gap: Nikolozi's CI workflow already invokes
  `THEOS_PACKAGE_SCHEME=rootless`, but Nikolozi's own `Makefile` had no
  matching `ARCHS` conditional, so that "rootless" build was silently still
  compiling both `arm64` and `arm64e` rather than following Procursus/
  rootless packaging convention.
- **Build flag robustness (`Makefile`).** `-fno-modules
  -Wno-module-import-in-extern-c` (`CFLAGS`) and `-fno-modules` (`CCFLAGS`),
  which avoid clang module-map conflicts against an out-of-Xcode SDK.
- **`build_release.sh`.** Replaced with tqmane's version: `set -euo
  pipefail`, portable `sed -i` (works on both BSD/macOS and GNU/Linux, not
  just macOS), `mkdir -p ./packages` before building, and an interactive
  y/n prompt before invoking `build_ipa.sh` instead of calling it
  unconditionally.
- **`build_ipa.sh` / CI robustness.** Added `set -euo pipefail` and an
  upfront tool-presence check (mirroring tqmane's `cyan` check) before
  invoking the injector.
- **CI: `FAKEROOT=` env var.** tqmane found this necessary on arm64e
  (Apple Silicon) GitHub runners; added defensively to the existing
  Nikolozi-based workflow.
- **Import-path robustness.** `SideloadFix.h` now imports
  `../fishhook/fishhook.h` (an explicit relative path) instead of
  `fishhook/fishhook.h`, matching tqmane.
- **In-app version display fix.** `BeaInfoViewController.h`'s own
  `TWEAK_VERSION` was hardcoded to a stale, unrelated `1.3.7` that never
  matched `control`'s version in *either* fork - this predates the fork
  split (present already at the merge-base). Fixed to match the real
  version, guarded with `#ifndef` (tqmane's pattern) so the two copies can't
  silently drift apart again as easily.

## Conflicts resolved

- **`Tweak.h`/`Tweak.x` class declarations and hooks** - textually
  incompatible (Nikolozi rewrote large parts of the file around a different
  architecture). Resolved by hand: kept every one of Nikolozi's declarations
  and hooks unchanged, and added tqmane's additions as new, independent
  blocks (see above) rather than attempting a textual diff/patch merge.
- **`isBlockedPath`** - both forks changed this function differently
  (Nikolozi kept it ObjC-ish with `NSString`; tqmane rewrote it pure-C with
  a wider list). Took tqmane's version outright since it's a strict superset
  with a clear safety rationale (must run before the ObjC runtime is fully
  settled).
- **`NSMutableURLRequest` auth capture** - both forks touch
  `setAllHTTPHeaderFields:`. Took tqmane's "always refresh" behavior over
  Nikolozi's "capture once" guard, and additionally kept both forks' `[BeaNet]`/
  `[BeaTokenManager]` wiring intact rather than picking one wholesale.
- **`control` `Version`/`Description`** - straightforward, took tqmane's
  4.58.0-aware description text, with our own new version number.
- **`Makefile` `TARGET` SDK version** - Nikolozi targets `iPhoneOS18.0.sdk`
  (deliberately, with matching CI infrastructure to fetch that exact SDK
  version - see `build.yml`); tqmane targets `16.5`. Kept Nikolozi's `18.0`
  as the base per "keep Nikolozi's jailed strategy if still compatible", and
  layered tqmane's `ARCHS`/rootless conditional and extra `CFLAGS` on top
  rather than reverting the SDK target.

## Explicitly NOT imported from tqmane (and why)

- **Per-view download-button hooks** (`%hook DoubleMediaViewUIKitLegacyImpl`,
  the `SDImageHooks` group on `SDAnimatedImageView`, the `UIImageViewHooks`
  group on plain `UIImageView`). These duplicate functionality Nikolozi's
  `BeaDownloader`/`viewDidLayoutSubviews` already provides more thoroughly
  (front+back pair, dedupe, local-container scoping), and running both
  mechanisms side by side would very plausibly make `KNOWN_ISSUES.md` bug #1
  (stray/duplicate download button) *worse*, not better - each mechanism
  would be independently capable of adding its own button to the same
  photo.
- **`MainTabBarController`-based BeFake upload button**
  (`setupBeFakeUploadButton`/`handleBeFakeUploadTap`, nav-bar-logo heuristic
  search). Nikolozi's window-attached button with `CADisplayLink`
  visibility sync (see `BeaVisibilitySyncTarget` in `Tweak.x`) is the more
  advanced implementation the brief asked to keep; tqmane's simpler
  logo-adjacent placement was evaluated and not imported, though see
  `KNOWN_ISSUES.md` bug #2 for a specific idea it did surface.
- **Legacy `MediaViewHosting`/`DoubleMediaViewLegacy` hooks**
  (`LegacySwiftHooks` group). Same reasoning as the per-view download-button
  hooks above - Nikolozi's generic view-hierarchy scan already covers older
  BeReal versions without needing per-class-name hooks, since it doesn't
  hardcode which container class the photos live in.
- **In-app "update available" nag** (`checkForLatestVersion` in
  `BeaUploadViewController.m`, added back by tqmane). Nikolozi's commit
  `41360c9` explicitly removed this ("drop update nag"). tqmane's copy
  also pings `api.github.com/repos/yandevelop/Bea/releases/latest` - a
  different repo entirely from any of the three being integrated here, and
  an unprompted outbound network call on every upload-screen open.
  Deliberately left removed.
- **C-level `access()`/`stat()`/`fopen()`/`getenv()` jailbreak-detection
  hooks.** Present in tqmane's *earlier* history but removed by tqmane
  itself (commit `985c746`, "Remove C-level system call hooks... to prevent
  crashes") before the commit this merge is based on. Not reintroduced, per
  the brief - `isBlockedPath` and the `NSFileManager` ObjC hooks are the
  full extent of the file-system bypass in this merge.
- **`package-lock.json`** (present in tqmane's tree, root of an npm
  `lockfileVersion: 3` with zero dependencies). Stray artifact, not
  relevant to an Objective-C/Theos project. Not imported.
- **`cyan`/pyzule-rw as the IPA injector.** tqmane's `build_ipa.sh` uses
  `cyan` instead of Nikolozi's `azule`. Investigated: `azule` ships from
  `asdfzxcvbn/pyzule`, which is deprecated upstream in favor of
  `pyzule-rw`'s `cyan` command - a real, legitimate reason to eventually
  switch. Not switched in this merge because Nikolozi's
  CydiaSubstrate-thinning post-processing step (`thin_macho.py`, the actual
  fix for on-device signing failures) is built and tested against azule's
  exact IPA output layout, and `cyan`'s equivalent output wasn't verified
  here. Documented as a follow-up in `build_ipa.sh` itself.

## Known bugs re-checked against tqmane (per the task brief)

Both of Nikolozi's two open bugs in `KNOWN_ISSUES.md` were re-examined
against tqmane's code for a "simple, clear" fix. Neither had one - see the
"Checked against the tqmane fork" notes added to `KNOWN_ISSUES.md` itself
for the reasoning on each:

1. **Stray/duplicate download button** - tqmane's architecture is
   different enough that it neither explains nor fixes this; importing it
   would risk making it worse (see above). Left documented, unresolved.
2. **BeFake `+` button doesn't sync with the nav row's scroll auto-hide** -
   no direct fix, but comparing the two forks surfaced a concrete, untried
   next experiment (re-parenting the button into the nav-row platter view
   instead of the window, so it inherits the hide animation for free
   instead of needing `CADisplayLink` polling). Not applied without a real
   device to verify against - Nikolozi's own history shows this exact area
   has bitten the project before. Documented in `KNOWN_ISSUES.md`.

## Debug/runtime logging

Nikolozi's `[BeaNet]` (full request/response logging, including bodies),
`[BeaDiag]` (view-hierarchy dumps), and `[BeaClassDump]` (full loaded-class/
method survey) logging ran unconditionally. All of it - plus the
`~127k`-class `URLSession` delegate-callback swizzling scan that powered
`[BeaNet]`'s delegate-based capture - is now gated behind a single
`MINIBEA_DEBUG` environment-variable check (`Utilities/Debug/BeaDebug.h`,
`BeaLog(...)` macro), **off by default**. Set `MINIBEA_DEBUG=1` in the
process environment to re-enable it for active debugging. None of this
logging ever printed credential *values* even before this change (only
"captured headers" status lines); the profile-picture-capture feature
itself (`BeaCaptureFriendProfilePictures`) is unaffected by the flag since
it's a real feature, not a diagnostic.

## Builds

See the PR/final report for rootful/rootless/jailed build results in this
environment (no macOS/Xcode/Theos toolchain available in this Linux
container - full `make package` cannot run here; what could be verified is
noted separately).
