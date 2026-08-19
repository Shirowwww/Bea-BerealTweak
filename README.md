# MiniBea

A jailbreak/sideload tweak for BeReal - remove ads, view posts without posting
your own ("Post to view" bypass), download post photos and profile pictures,
and post fake BeReals with custom photos, caption, audience, location, and
music (BeFake).

This repo is a maintained fork of [yandevelop/MiniBea](https://github.com/yandevelop/MiniBea),
the original MiniBea, with ad removal, per-camera downloads, a reworked
BeFake composer, and fixes for BeReal 4.88 added on top.

AI-assisted contributions (Claude Code and similar) are welcome here, as
long as changes are reviewed and tested on-device before being merged. See
`AGENTS.md` if you're contributing with AI assistance.

## Features

- **No ads** - blocks BeReal's own ad stack, ~18 vendor ad SDKs, and
  in-feed sponsored cards. See [Ad removal](#ad-removal).
- **Post to view bypass** - view friends' BeReals without posting your own
  first, no blur.
- **Unlocked media on a gated post** - tap a photo to open it full screen,
  pinch to zoom, drag to pan. Strictly local: no post is fabricated and no
  request is changed.
- **Download button** on every post, saving both photos by default.
  Touch-and-hold to pick *Both*, *Back only*, or *Front only*.
- **BeFake** - post a fake BeReal from any two photos, with caption,
  audience (friends / friends of friends / everyone), location, retake
  counter, late flag.
- **A settings screen for all of it** - long-press the "+", long-press the
  download button, or hold two fingers anywhere on the feed. Switches take
  effect immediately and undo themselves when turned back off, and it
  shares an on-device diagnostics report.
- **Rootful, rootless, and jailed (sideload) builds**, all from the same
  `Makefile`/CI.

## Compatibility

- BeReal 4.88.0 and later, and 4.58.x.
- iOS 14.0+, `arm64`/`arm64e`.
- Rootful jailbreaks (Dopamine/palera1n rootful, unc0ver, etc.), rootless
  jailbreaks (Dopamine rootless, palera1n rootless), and non-jailbroken
  sideloading (via `JAILED=1`).

## Ad removal

[`Utilities/Ads/BeaAdBlocker.m`](Utilities/Ads/BeaAdBlocker.m) removes ads at
four layers: named hooks on BeReal's own ad container views, a generic view
hook that identifies vendor SDK ad views by framework rather than by class
name, refusing to present full-screen interstitials, and an `NSURLProtocol`
that blocks ad/mediation network requests outright.

**Not blocked, on purpose:** Google's `UserMessagingPlatform` (the one-time
GDPR consent sheet) and Firebase Analytics - blocking either risks breaking
something unrelated (a stuck callback, lost push notifications).

## Installing

Grab the right `.deb` for your setup from the
[latest release](../../releases/latest):

- **Rootful** jailbreak - the `arm64_arm64e` (no suffix) package via
  Sileo/Zebra.
- **Rootless** jailbreak - the `_rootless`/`iphoneos-arm64` package via
  Sileo/Zebra.
- **Sideload (no jailbreak)** - the `_jailed` package, injected into your
  own already-decrypted BeReal IPA with a tool like
  [cyan/pyzule-rw](https://github.com/asdfzxcvbn/pyzule-rw) or azule, then
  installed with Sideloadly/AltStore/etc. `build_ipa.sh` automates this step
  locally if you already have `azule` installed and a decrypted IPA on hand.

## Building from source

Requires [Theos](https://theos.dev) and Xcode's `iPhoneOS18.0.sdk` (or a
mirror - see `.github/workflows/build.yml` for how CI fetches one without a
full Xcode install).

```sh
./build_release.sh   # builds jailed, rootful, and rootless packages into ./packages
./build_ipa.sh        # optional, local-only: injects the jailed .deb into a decrypted IPA you supply
```

If you already have a decrypted BeReal IPA and just want the latest tweak
patched into it, `update_and_sideload.sh` does the whole thing in one
command: pulls the latest `main`, rebuilds a fresh jailed package, then runs
`build_ipa.sh` for you.

```sh
./update_and_sideload.sh
```

Or drive `make` directly:

```sh
make clean package FINALPACKAGE=1                              # rootful
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless # rootless
make clean package FINALPACKAGE=1 JAILED=1                      # jailed/sideload
```

## Debug logging

Runtime/network diagnostic logging is compiled in but **disabled by
default**. Set `MINIBEA_DEBUG=1` in the process environment before BeReal
launches to enable it. See
[`Utilities/Debug/BeaDebug.h`](Utilities/Debug/BeaDebug.h).

## Known issues

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md). Currently open: a stray/duplicate
download button can appear (last reproduced on BeReal 4.58).

## Contributing

Issues and PRs are welcome, including PRs written with AI assistance.

- Read [`AGENTS.md`](AGENTS.md) first - it documents this codebase's
  non-obvious traps (silent failures, hit-testing quirks, SwiftUI vs. UIKit
  boundaries).
- CI (`.github/workflows/build.yml`) is the only thing that type-checks this
  repo before a device test - make sure it's green.
- For anything behavior-affecting, say in the PR description how it was
  tested (device model, jailbreak/sideload, BeReal version).

## Credits

- [yandevelop](https://github.com/yandevelop/MiniBea) - original MiniBea.
- [fishhook](https://github.com/facebook/fishhook) (vendored, BSD-licensed)
  - dynamic symbol rebinding used by the sideload/jailed build.

## License

MIT - see [`LICENSE`](LICENSE). Not affiliated with or endorsed by BeReal;
no BeReal source, assets, or proprietary material is included here.
