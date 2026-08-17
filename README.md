# MiniBea

A jailbreak/sideload tweak for BeReal - view posts without posting your own
("Post to view" bypass), download post photos and profile pictures, and post
fake BeReals with custom photos, caption, location, and music (BeFake).

This repo is a maintained, curated merge of two active MiniBea forks, kept
in sync with both going forward. It is not itself a fork on GitHub (repo
history was merged in directly, see below) but is meant to be used and
tracked exactly like one.

- **Base:** [NikoloziKhachiashvili/MiniBea](https://github.com/NikoloziKhachiashvili/MiniBea)
- **Merged in:** [tqmane/MiniBea](https://github.com/tqmane/MiniBea)
- **Common upstream:** [yandevelop/MiniBea](https://github.com/yandevelop/MiniBea)

See [`MERGE_NOTES.md`](MERGE_NOTES.md) for exactly what was kept, imported,
or rejected from each fork and why, and [`SYNCING.md`](SYNCING.md) for how
this repo stays up to date with both forks going forward.

## Features

- **Post to view bypass** - view friends' BeReals without having posted
  your own first, and without the blur BeReal applies to gated posts.
- **Download button** on every post - saves both the front and back camera
  photos to your Photos library.
- **Profile picture download** - a second download button on friends'
  profile screens.
- **BeFake** - post a fake BeReal from any two photos, with caption,
  location, retake counter, late flag, and Spotify "currently listening"
  attachment.
- **BeReal 4.58+ compatible** - jailbreak-detection bypass covers BeReal's
  own new check plus several ad/analytics SDKs, and file-system checks
  cover both rootful and rootless (`/var/jb/...`) jailbreak layouts.
- **Rootful, rootless, and jailed (sideload) builds**, all produced by the
  same `Makefile`/CI.
- Verbose network/runtime diagnostic logging exists but is **off by
  default** - see [Debug logging](#debug-logging) below.

## Compatibility

- BeReal 4.58.0 and later (older versions should still work; the newer
  compatibility hooks no-op safely when their target classes don't exist).
- iOS 14.0+, `arm64`/`arm64e`.
- Rootful jailbreaks (Dopamine/palera1n rootful, unc0ver, etc.), rootless
  jailbreaks (Dopamine rootless, palera1n rootless), and non-jailbroken
  sideloading (via a `JAILED=1`).

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
  installed with Sideloadly/AltStore/etc. `build_ipa.sh` automates this
  step locally if you already have `azule` installed and a decrypted IPA on
  hand.

## Building from source

Requires [Theos](https://theos.dev) and Xcode's `iPhoneOS18.0.sdk` (or a
mirror of it - see `.github/workflows/build.yml` for how CI fetches one
without a full Xcode install). Or via Github.

```sh
./build_release.sh   # builds jailed, rootful, and rootless packages into ./packages
./build_ipa.sh        # optional, local-only: injects the jailed .deb into a decrypted IPA you supply
```

If you already have a decrypted BeReal IPA and just want the latest
tweak patched into it, `update_and_sideload.sh` does the whole thing in one
command: pulls the latest reviewed code on `main` (including whatever's been
merged in from both upstream forks), rebuilds a fresh jailed package, then
runs `build_ipa.sh` for you.

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

Runtime and network diagnostic logging (`[BeaNet]`, `[BeaDiag]`,
`[BeaClassDump]` - request/response bodies, view-hierarchy dumps, full
loaded-class surveys) is compiled in but **disabled by default**. Set
`MINIBEA_DEBUG=1` in the process environment before BeReal launches to
re-enable it. See [`Utilities/Debug/BeaDebug.h`](Utilities/Debug/BeaDebug.h).

## Known issues

Two open bugs, both under active investigation with best-effort (not yet
device-verified) mitigations applied - see
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for full detail:

1. A stray/duplicate download button can appear.
2. The BeFake "+" upload button doesn't always hide in sync with the feed's
   own nav row auto-hide on scroll.

## Credits

- [yandevelop](https://github.com/yandevelop/MiniBea) - original MiniBea.
- [NikoloziKhachiashvili](https://github.com/NikoloziKhachiashvili/MiniBea) -
  this repo's base: rewritten downloader, "Post to view"/unblur, profile
  picture download, BeFake UI, modern button placement.
- [tqmane](https://github.com/tqmane/MiniBea) - BeReal 4.58+ and
  rootless/jailed compatibility improvements merged in.
- [fishhook](https://github.com/facebook/fishhook) (vendored, BSD-licensed)
  - dynamic symbol rebinding used by the sideload/jailed build.
