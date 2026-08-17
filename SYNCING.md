# Keeping this fork in sync

This repo is a manual, curated integration of two MiniBea forks - see
`MERGE_NOTES.md` for the reasoning behind what was kept, imported, or
rejected. This file covers the *ongoing* process for pulling in future
upstream changes.

## Role of `main`

`main` is the reviewed, working integration - the merged result of
`MERGE_NOTES.md`'s decisions. It only ever moves via a reviewed, merged pull
request. **Nothing automated pushes to `main` directly, ever** - not the
sync workflow, not a scheduled job, nothing.

## Role of `sync/nikolozi` and `sync/tqmane`

These two branches are pure mirrors - each one is force-updated to exactly
match the corresponding upstream fork's branch tip
(`NikoloziKhachiashvili/MiniBea@main` / `tqmane/MiniBea@main`). They are
**never** rebased onto `main`, never merged into anything automatically, and
never hand-edited - if you need to adapt something, do it in a new commit on
top when you actually merge, not by editing the mirror branch itself.

`.github/workflows/sync-forks.yml` keeps them up to date:

- Runs on `workflow_dispatch` or every 6 hours (`schedule`).
- For each fork: fetches its branch, compares the tip commit against the
  local `sync/*` branch. If unchanged, does nothing. If changed, force-
  updates `sync/*` to match, then opens (or refreshes) a PR from `sync/*`
  into `main`.
- PR titles: `sync: update from Nikolozi` / `sync: update from tqmane`.
  Labels: `upstream-sync`, `manual-review`, plus `needs-manual-adaptation`
  when the branch no longer merges cleanly into `main` (checked with
  `git merge-tree`, never an actual checkout/merge/execution of the fork's
  code).
- **No auto-merge. No automatic rebase. No automatic conflict resolution.
  No automatic code adaptation.** A conflicted PR is left open with the
  `needs-manual-adaptation` label and a comment - a human resolves it by
  hand, following the same kind of analysis in `MERGE_NOTES.md` (what to
  keep from `main`, what to take from the sync branch, what to skip).
- Runs with `contents: write` + `pull-requests: write` only - no
  `pull_request_target`, and the fork's own code is never checked out or
  executed by the workflow (only `git fetch`/`git merge-tree`, both
  read-only against the fork).

## Running a sync manually

From the GitHub UI: **Actions -> sync-forks -> Run workflow**. Or with the
GitHub CLI:

```sh
gh workflow run sync-forks.yml
```

This runs both forks' sync jobs immediately instead of waiting for the next
6-hour tick.

## Integrating a future update by hand

1. Wait for (or trigger) a `sync: update from <fork>` PR.
2. Read its diff against `main` - this is exactly `<fork>`'s own new commits
   since the last sync, nothing more.
3. Decide what actually needs pulling into `main`, using the same priorities
   as `MERGE_NOTES.md`:
   - Nikolozi is the base for downloader front/back logic, recycled-post
     handling, "Post to view"/unblur, profile-picture download, UI/BeFake
     button placement - don't replace a more advanced Nikolozi
     implementation with a simpler one from a sync branch.
   - tqmane is the source for BeReal-version compatibility, environment/
     rootless/jailed checks, and auth-capture robustness - prefer these when
     they add coverage Nikolozi doesn't have, without duplicating logic that
     risks reintroducing `KNOWN_ISSUES.md`'s bugs.
   - Never reintroduce the C-level `access()`/`stat()`/`fopen()`/`getenv()`
     hooks removed for crashing in jailed/sideloaded environments.
   - Keep runtime/network diagnostic logging behind `MINIBEA_DEBUG`
     (`Utilities/Debug/BeaDebug.h`), off by default; never log credentials.
4. Do the actual integration on a normal feature branch off `main` (e.g.
   `git checkout -b integrate/nikolozi-2026-09 main`, then
   `git merge sync/nikolozi` or cherry-pick the specific commits you want),
   resolving conflicts by hand.
5. Update `MERGE_NOTES.md` with what was pulled in and why, same as the
   original integration.
6. Open a normal PR into `main` and get it reviewed like any other change -
   the `sync/*` PR itself is never merged directly; it exists to surface the
   diff, not to be merged as-is.
