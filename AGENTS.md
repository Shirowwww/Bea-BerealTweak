# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this repository.

## What this is

MiniBea is a Theos/Logos jailbreak+sideload tweak for BeReal (iOS). It's a
curated merge of two active MiniBea forks — see `README.md` for the
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
`BeaRemoveStrayButtons` in `Tweak.x`), `BeaDownloader`, and `BeaDebug`
(the logging gate, see below).

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


## Fork-sync automation

`.github/workflows/sync-forks.yml` mirrors the two upstream forks into
`sync/nikolozi` / `sync/tqmane` and opens PRs into `main` — see
`SYNCING.md` for the full policy. The load-bearing constraint if you ever
touch this workflow or `.github/scripts/sync-one-fork.sh`: it must stay
read-only against the forks' code (`git fetch` / `git merge-tree` only,
never a checkout or execution of fork code), must never auto-merge,
auto-rebase, or auto-resolve conflicts, must keep permissions scoped to
`contents: write` + `pull-requests: write` only, and must never use
`pull_request_target`. A conflicted sync PR gets the
`needs-manual-adaptation` label and is left for a human — don't "fix" that
by adding automatic resolution.

## Where to look for more

- `README.md` — features, compatibility, install instructions.
- `MERGE_NOTES.md` — the original fork-merge decisions and reasoning.
- `KNOWN_ISSUES.md` — two open, unverified-on-device bugs (stray button,
  upload-button auto-hide) with the full history of what's been tried.
- `SYNCING.md` — day-to-day fork-sync process.
