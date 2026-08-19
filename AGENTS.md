# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this repository.

## What this is

MiniBea is a Theos/Logos jailbreak+sideload tweak for BeReal (iOS): ad
removal, "Post to view" bypass, per-camera downloads, and a fake-post
composer (BeFake). See `README.md` for the feature list. There is no
app/server here, just the tweak's Objective-C source and the Theos build
config that turns it into a `.deb`.

## Build commands

Requires [Theos](https://theos.dev) installed and `$THEOS` set, plus an
`iPhoneOS18.0.sdk` (or compatible mirror — see `.github/workflows/build.yml`
for how CI fetches one headlessly). There is no simulator target and no
automated test suite — the tweak only runs injected into BeReal on a real
device, so "testing a change" means a clean Theos build, plus the CI build
workflow, plus (for behavioral changes) manual verification on-device.

```sh
./build_release.sh   # builds all 3 variants into ./packages
```

Or drive `make` directly for a single variant:

```sh
make clean package FINALPACKAGE=1                              # rootful (arm64 + arm64e)
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless # rootless (arm64 only)
make clean package FINALPACKAGE=1 JAILED=1                      # jailed/sideload
```

`JAILED=1` pulls in `fishhook/` + `SideloadFix/SideloadFix.xm` and switches
Logos' hook generator to `internal`, so the sideload package has no
MobileSubstrate/CydiaSubstrate dependency. It compiles different files under
a different hooking mechanism — don't assume a rootful-only test covers it.

`build_ipa.sh` injects the jailed `.deb` into a BeReal IPA to produce a
sideloadable IPA. `update_and_sideload.sh` wraps this: pulls latest `main`,
rebuilds the jailed package, then runs `build_ipa.sh`.

## Architecture

- **`Tweak/Tweak.x`** — the entry point, one large Logos file covering
  jailbreak-detection bypass, "Post to view"/blur bypass, the floating
  buttons' window-attachment and z-ordering, and version-compatibility
  shims. Hooked classes are forward-declared in `Tweak.h`.
- **`BeFake/`** — the fake-post subsystem (upload/location/music-picker/info
  view controllers, token manager, upload task): composes a "BeFake" and
  posts it through BeReal's real upload API.
- **`Utilities/Button/BeaButton`** — the floating buttons. Window-parented
  (to out-rank a gated post's lock overlay), which means no ancestor view
  controller and no participation in UIKit's normal presentation z-order —
  visibility is decided once per frame in `BeaVisibilitySyncTarget`, not in
  a layout hook, because a presented modal doesn't trigger layout at all.
  Position by frame (`-convertRect:toView:`), never by constraint, across a
  scroll view boundary — scrolling changes `bounds` origin, not frame, so a
  constrained button doesn't track it.
- **`Utilities/Downloader/BeaDownloader`** — per-camera/profile-picture
  download, and the "Post to view" gating-overlay hider. BeReal 4.88 draws
  that overlay in `CALayer`s with no backing views, so it's found by
  stacking order (a background-filled layer covering most of the photo,
  plus everything non-view-backed above it) rather than by size.
- **`Utilities/Ads/BeaAdBlocker`** — the whole ad-removal decision layer.
  Classifies views by class-name match (`Adverts*`/`SparkAds*`) and by
  `class_getImageName` against ~18 vendor SDK frameworks, caches per
  `Class`. Also removes BeReal's own SwiftUI-drawn sponsored feed cards by
  the `general_sponsored` string marker, and blocks ad network requests via
  a per-request-checked `NSURLProtocol`. Two deliberate non-targets are
  documented at the top of the file (UMP consent sheet, Firebase Analytics)
  — don't "fix" those without reading why.
- **`Utilities/Localization/BeaLocalization`** — every string the tweak
  shows *and* every string it matches against BeReal's own UI, in both
  directions. `BeaAppLocalized` reads BeReal's own string table by key,
  `BeaSharedCopy` prefers it and falls back to the tweak's own two-language
  table. Never hardcode an English literal to render or to match — BeReal
  ships fifteen languages, and some UI text only exists in the accessibility
  tree (SwiftUI `Text` has no `UILabel`), which `BeaCollectViewsWithMatchingText`
  also scans.
- **`Utilities/Media/`** — `BeaMediaUnlock` (re-enables BeReal's own photo
  gestures on a gated post) and `BeaMediaViewer` (local zoom/pan viewer).
  Routed through a single `UITapGestureRecognizer` on the window rather than
  per-view hit testing, because UIKit's hit test never resumes at an earlier
  sibling once a deeper view in the chain declines the touch.
- **`Utilities/Settings/`** — `BeaSettings` (NSUserDefaults-backed switches)
  and `BeaSettingsViewController` (a plain `UIScrollView`/`UIStackView`
  screen, not a `UITableView` — there's nothing to recycle and self-sizing
  cells were a repeated source of layout bugs). Reached by long-pressing the
  "+", long-pressing the download button, or a two-finger hold anywhere.
  Every behavior that has ever needed a second device-testing round gets a
  switch here, and every switch must be reversible live (record what it
  replaced; don't just gate the apply path).
- **`Utilities/Diagnostics/BeaDiagnostics`** — the on-device report the
  settings screen shares: what resolved, what the last scan found, rate
  counters, and the view hierarchy. Reach for this instead of guessing.
- **`Utilities/Runtime/`** — `BeaRuntime` (restore guards so a suspend/resume
  cycle can't rewrite the user's own switches) and `BeaOwnership` (marks the
  tweak's own screens so its scanners skip them — the settings screen quotes
  BeReal's own copy, which the gating/sponsored scanners would otherwise
  strip out of the tweak's own UI).
- **`SideloadFix/`** — `JAILED=1`-only. Makes a sideloaded (non-jailbroken)
  install pass BeReal's jailbreak checks via `fishhook`-rebound `SecItem*`
  calls. Careful with Core Foundation ownership here (`CFRelease` every
  `CFDictionaryCreateMutableCopy`, `__bridge_transfer` on anything from
  `SecItemCopyMatching`/`SecItemAdd`) — most likely file to leak or
  double-free if touched carelessly.
- **`Utilities/Debug/BeaDebug`** — gates all verbose logging (request
  bodies, view dumps, class surveys — some of which can include tokens/PII)
  behind `MINIBEA_DEBUG=1` in the process environment. New verbose logging
  goes through `BeaLog(...)`, never a bare `NSLog`.

## A few hard-won invariants

- **Never mutate a view from inside a layout pass.** `viewDidLayoutSubviews`
  fires for every controller and re-triggers itself if a hook writes back
  into the hierarchy from there. Reconcile on your own schedule (a display
  link, rate-limited), not on SwiftUI's.
- **Match BeReal's own class names as substrings, not exact mangled names.**
  Generic Swift class names change shape between BeReal versions, and a
  class that silently moves module should be looked up by trying each
  candidate — an exact-string match that stops matching disables a feature
  with no error anywhere.
- **Every injected button is reconciled by position, not by anchor
  identity** — BeReal recycles its image views, so identity isn't a stable
  key (see `KNOWN_ISSUES.md`).
- **Never spoof post state to unlock local UI.** Media unlock only touches
  views/gestures/images already on screen — no fabricated post, no rewritten
  request, `HasPostedUseCaseImpl` is deliberately not hooked.
- **Degrade to working, never to nothing**, when a lookup misses — keep the
  button and skip the nicety rather than hiding the whole feature.

## Commit conventions

Commit under your own identity, with a short, plain commit message
describing the change. Don't add `Co-Authored-By` trailers, session/agent
links, or any other mention of the tool that made the change — commits in
this repo read as ordinary commits regardless of whether a human or an AI
assistant wrote them.

## Where to look for more

- `README.md` — features, compatibility, install instructions.
- `KNOWN_ISSUES.md` — the one still-open bug (stray/duplicate download
  button) and its history.
- `tools/` — the IPA inspection and sideload-injection scripts used below.

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

Two traps worth knowing before you trust a negative result:

- **A generic Swift class's runtime name is not in the binary** — it's
  assembled at runtime. Search for the bare type name and match substrings.
- **`NSStringFromClass` returns the mangled name**
  (`_TtC11AdvertsData16AppLovinMRECView`), not the demangled form Swift's
  overlay gives. `objc_getClass()` accepts either; code that matches on a
  name should tolerate both.

Endpoints can be checked unauthenticated:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://mobile-l7.bereal.com/api/content/posts/upload-url
```

401 means the route wants a token, 403 is the app's own middleware, 404
means it's gone — don't read anything into which of 401/403 comes back.

## Building and shipping without a Mac

CI is the only thing that type-checks this repo on a machine without Theos.
`.github/workflows/build.yml` runs on every push and builds all three
variants; budget ~5 minutes per round trip.

```sh
git push
gh run list --branch main --limit 1
gh run view <id> --log | grep -E 'error:|warning:'   # expect zero of both
```

Don't merge on a red build, and don't assume a change is fine because it
"looks like" the code next to it — Logos generates real code from `%hook`.

### Producing a sideload IPA without a Mac

`build_ipa.sh` needs azule/macOS. `tools/` reimplements the same steps in
Python for a `JAILED=1` build, which has no CydiaSubstrate dependency so a
plain load-command insert is sufficient:

```sh
gh run download <id> -n minibea-packages -D pkgs
python tools/extract_deb.py pkgs/*_jailed.deb extract
python tools/patch_ipa.py "BeReal IPA/BeReal_v4.88.0_Legal.ipa" \
    extract/MiniBea.dylib "BeReal IPA/BeReal_patched.ipa"
```

Verify before handing an IPA over:

```python
import zipfile, sys; sys.path.insert(0, 'tools'); import macho
z = zipfile.ZipFile(ipa); exe = z.read('Payload/BeReal.app/BeReal')
for off, _ in macho.slices(exe):
    i = macho.describe(exe, off)
    assert i['cryptid'] == 0 and any('MiniBea' in d for d in i['dylibs'])
assert z.testzip() is None
```

## Diagnosing a "it still doesn't work" report

This codebase fails silently by construction — an exact class-name match
that stops matching, an English-only string compare, a window-parented view
UIKit can't find a controller for. None of it crashes or logs.

1. **Ask a few precise, mutually-exclusive questions before writing code**
   ("is the button invisible or visible-but-inert?", "which build is
   installed?"). Device round trips are the expensive resource, not tokens.
2. **Prefer degrading to working over failing closed** — see the invariant
   above.
3. `MINIBEA_DEBUG=1` in the process environment turns on verbose `[Bea*]`
   logging; off by default because some of it can include tokens/PII.

## Editing conventions

- Source files are LF in-repo; git converts on a Windows checkout.
- The version string lives in `Utilities/BeaVersion.h` and `control`'s
  `Version:` field — bump both together when shipping a new build.
