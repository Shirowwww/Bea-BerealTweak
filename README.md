# MiniBea

A jailbreak/sideload tweak for BeReal - remove ads, view posts without posting
your own ("Post to view" bypass), download post photos and profile pictures,
and post fake BeReals with custom photos, caption, audience, location, and
music (BeFake).

This repo is a maintained, curated merge of two active MiniBea forks. It is
not itself a fork on GitHub (repo history was merged in directly, see below)
but is meant to be used and tracked exactly like one.

- **Base:** [NikoloziKhachiashvili/MiniBea](https://github.com/NikoloziKhachiashvili/MiniBea)
- **Merged in:** [tqmane/MiniBea](https://github.com/tqmane/MiniBea)
- **Common upstream:** [yandevelop/MiniBea](https://github.com/yandevelop/MiniBea)

See [`MERGE_NOTES.md`](MERGE_NOTES.md) for exactly what was kept, imported,
or rejected from each fork and why.

## Features

- **No ads.** BeReal 4.88 serves ads three ways and all three are covered -
  see [Ad removal](#ad-removal) for what exactly is blocked and the one
  thing that deliberately isn't.
- **Post to view bypass** - view friends' BeReals without having posted
  your own first, and without the blur BeReal applies to gated posts. BeReal
  4.88 draws that overlay entirely in CALayers (no views, no text a scan can
  read), so the whole cluster is found by the scrim it is painted on and
  hidden together - scrim, eye icon, both text lines and the button.
- **Unlocked media on a gated post** - tap either photo to open it full
  screen, pinch to zoom, drag to pan, tap the inset thumbnail to swap which
  one is large, and drag down to close. BeReal's own photo gestures on that
  post are re-enabled first, so where they work they are what you get.
  Strictly local: nothing tells BeReal you posted, no post is fabricated, and
  no request is changed - the photos were already decoded and on screen.
- **Download button** on every post - saves both photos by default. **Touch
  and hold it** to choose *Both photos*, *Back camera only*, or *Front
  camera only*; the choice sticks and a plain tap then saves just that.
  Which photo is which is read from BeReal's own CDN paths
  (`-primary` = back, `-secondary` = front), so it stays correct even after
  you tap a post to swap which camera is shown large.
- **Profile picture download** - a second download button on friends'
  profile screens.
- **BeFake** - post a fake BeReal from any two photos, with caption,
  **audience (friends / friends of friends / everyone)**, location, retake
  counter, late flag, and Spotify "currently listening" attachment. The
  composer scrolls and moves out from under the keyboard, you can swap the
  two photos or long-press one to clear it, Send stays disabled until both
  slots are filled, and failures now report BeReal's actual error instead of
  `(null), (null), (null)`.
- **A settings screen for all of it** - long-press the "+", long-press the
  download button, or hold two fingers anywhere on the feed. Every switch
  takes effect immediately and undoes itself when turned back off; only
  "Read SwiftUI text" still needs a relaunch. It also shares a diagnostics
  report, which is the fastest way to answer "why isn't this working on my
  device".
- **BeReal 4.88 compatible** - see [Compatibility](#compatibility).
- **Rootful, rootless, and jailed (sideload) builds**, all produced by the
  same `Makefile`/CI.
- Verbose network/runtime diagnostic logging exists but is **off by
  default** - see [Debug logging](#debug-logging) below.

## Compatibility

- BeReal 4.88.0 and later, and 4.58.x.
  4.88 renamed two things this tweak matched against by exact name, and both
  are handled by matching that survives either spelling:
  - `HomeViewHostingController` stopped being a generic Swift class, so its
    ObjC runtime name went from
    `_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_` to plain
    `BeReal.HomeViewHostingController`. The old exact-string comparison could
    never match that, which silently removed **both** floating buttons (post
    download and the BeFake "+") from the app with no error anywhere. Now
    matched as a substring.
  - `BlurStateUseCaseImpl` moved from the `FeedsFeatureDomain` module to
    `CoreFeedDomain`. Both names are tried, first one found wins.
- iOS 14.0+, `arm64`/`arm64e`.
- Rootful jailbreaks (Dopamine/palera1n rootful, unc0ver, etc.), rootless
  jailbreaks (Dopamine rootless, palera1n rootless), and non-jailbroken
  sideloading (via a `JAILED=1`).

## Ad removal

BeReal 4.88 bundles roughly 18 third-party ad SDKs (AppLovin MAX plus its
ByteDance/InMobi/Moloco/PubMatic/Verve mediation adapters, GoogleMobileAds,
PAGAdSDK, HyBid, VungleAds, VoodooAdn, AppHarbr, OpenWrap, two OMSDK
viewability kits) alongside two of its own in-house ad stacks: the
`Adverts*` Swift modules and the separate `SparkAds*` one (Spotlight, FoF
ads, direct deals). [`Utilities/Ads/BeaAdBlocker.m`](Utilities/Ads/BeaAdBlocker.m)
takes all of them out at four layers:

| Layer | What it stops |
| --- | --- |
| Named hooks on BeReal's own advert container views | The in-feed ad slot, including collapsing the empty space it would leave |
| A generic `UIView` hook that identifies ad views by which framework binary their class came from | Every vendor SDK's banner/MREC/native view, without naming a single one of their classes |
| Refusing `presentViewController:` / `makeKeyAndVisible` for ad controllers and windows | Full-screen interstitials |
| An `NSURLProtocol` that fails requests to ad/mediation hosts | The ad ever loading in the first place, so the slot is never filled and nothing has to be hidden after the fact |

**Not blocked, on purpose:** Google's `UserMessagingPlatform` (the one-time
GDPR consent sheet). It isn't an ad, and blocking a consent flow risks the
app waiting forever on a callback that can then never arrive. Firebase
Analytics endpoints are likewise left alone - taking them down can take
Firebase Messaging (push notifications) with them.

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

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for full detail:

1. A stray/duplicate download button can appear. Last reproduced on BeReal
   4.58 and not re-tested since the 4.88 class-name fix above, which changes
   which controller the button code runs on in the first place.
2. ~~The BeFake "+" button doesn't hide in sync with the nav row.~~ Closed:
   the button is now always visible while the feed is on screen, because the
   sync attempt was what made it disappear entirely on some devices.

## Credits

- [yandevelop](https://github.com/yandevelop/MiniBea) - original MiniBea.
- [NikoloziKhachiashvili](https://github.com/NikoloziKhachiashvili/MiniBea) -
  this repo's base: rewritten downloader, "Post to view"/unblur, profile
  picture download, BeFake UI, modern button placement.
- [tqmane](https://github.com/tqmane/MiniBea) - BeReal 4.58+ and
  rootless/jailed compatibility improvements merged in.
- [fishhook](https://github.com/facebook/fishhook) (vendored, BSD-licensed)
  - dynamic symbol rebinding used by the sideload/jailed build.
