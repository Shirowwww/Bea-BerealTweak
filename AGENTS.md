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
that exists.

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

**Version string** lives in three places that must move together:
`control`'s `Version:` field, `Tweak/Tweak.h`'s `TWEAK_VERSION` define, and
`BeFake/ViewControllers/InfoViewController/BeaInfoViewController.h`'s copy
(guarded by `#ifndef TWEAK_VERSION` so it can never silently diverge from
`Tweak.h`'s definition — but it still needs updating by hand alongside it).

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
