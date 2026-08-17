# Keeping this fork in sync

This repo is a manual, curated integration of two MiniBea forks - see
`MERGE_NOTES.md` for the reasoning behind what was kept, imported, or
rejected. This file covers the *ongoing* process for pulling in future
upstream changes.

## Policy history

Until 2026-08-17, this automation never auto-merged and never auto-resolved
anything - every sync PR was reviewed and integrated by hand. That changed
by explicit repo-owner request: sync now auto-merges when mergeable and CI
is green, and falls back to AI agents (Copilot, then Claude) when it isn't.
The sections below describe the current behavior; the manual path at the
bottom still exists for whatever the automation can't resolve.

## Role of `main`

`main` is the reviewed, working integration - the merged result of
`MERGE_NOTES.md`'s decisions. It only ever moves via a merged pull request
that passed the `build` and `invariants` required status checks (branch
protection is configured on `main` for exactly this). Nothing - not the
sync workflow, not a fallback agent, not a scheduled job - pushes to `main`
directly; they all go through that gate.

## Role of `sync/nikolozi` / `sync/tqmane` vs `auto/nikolozi` / `auto/tqmane`

**`sync/*`** is a pure mirror - force-updated to exactly match the
corresponding upstream fork's branch tip
(`NikoloziKhachiashvili/MiniBea@main` / `tqmane/MiniBea@main`). It is
**never** rebased onto `main`, never merged into anything automatically, and
never hand-edited - not even by a fallback agent. If you need to adapt
something, do it on `auto/*` or a normal feature branch, never here.

**`auto/*`** is the actual PR head branch into `main`. Each sync cycle
resets it (force-push) to the fresh `sync/*` tip, then a fallback agent may
add commits on top of it if the merge conflicts or CI fails. Resetting it on
every cycle is deliberate: a new fork commit means any in-flight agent fix
was solving yesterday's problem, so it's discarded and re-attempted clean.

## What `.github/workflows/sync-forks.yml` does

Runs on `workflow_dispatch` or every 6 hours (`schedule`). For each fork:

1. Fetches the fork's branch, compares its tip against the local `sync/*`
   branch. If unchanged, does nothing.
2. If changed: force-updates `sync/*` to match, then force-updates `auto/*`
   to the same tip (discarding any previous agent attempt).
3. Checks mergeability of `auto/*` into `main` with `git merge-tree` - purely
   in-memory, no checkout, no execution of fork code.
4. Opens (or refreshes) a PR from `auto/*` into `main`. Labels:
   `upstream-sync`, `manual-review`, plus `needs-manual-adaptation` when
   conflicted.
5. **If mergeable:** enables GitHub's native auto-merge
   (`gh pr merge --auto --merge`), which waits for the `build` and
   `invariants` required checks and merges automatically once both pass. If
   a check fails, `.github/workflows/sync-fallback.yml` (triggered by that
   check's own completion) takes over - see below.
6. **If conflicted:** immediately asks the fallback agents (see below) to
   resolve it, in the same job, before returning.

## The fallback agents

`.github/actions/agent-fallback/` (a composite action) implements both the
conflict path (step 6 above, called from `sync-forks.yml`) and the
CI-failure path (`sync-fallback.yml`, triggered when `build` or
`invariants` completes with `conclusion: failure` on an `auto/*` branch).
The task/rules text both agents get is generated once by
`.github/scripts/agent-prompt.sh` (no reintroducing the removed C-level
hooks, keep logging gated behind `BeaLog`/`MINIBEA_DEBUG`, don't touch
`SideloadFix.xm` unless that's literally where the problem is, don't touch
the three version-string locations unless that's the problem, smallest
change possible, don't weaken/skip any CI check to make it pass). Both
paths:

1. Post that task as a comment on the PR mentioning `@copilot`, then wait
   (poll, 10 minutes default) for a new commit to land on the branch.
   Requires the Copilot coding agent to be enabled for this repo
   (Business/Enterprise/Pro+); if it's not enabled or Copilot doesn't
   engage, nothing happens within the timeout and step 2 fires.
2. If Copilot didn't push anything, check out the branch and run
   `anthropics/claude-code-action` (Sonnet 5) **directly as a step in the
   same job** - not via an `@claude` PR comment, because a comment posted
   with the workflow's own `GITHUB_TOKEN` can't trigger another Actions
   workflow (GitHub's own loop-prevention rule), so a comment-relay design
   would silently never fire. Claude edits the checked-out working tree;
   the next step commits and pushes if anything changed. Requires the
   `ANTHROPIC_API_KEY` repository secret.
3. If neither produced a new commit, label the PR `needs-manual-adaptation`,
   comment explaining both agents were tried, and stop.

Either agent's fix commit re-triggers `build`/`invariants` on the new SHA;
if they pass, the auto-merge enabled in step 5 above takes it from there -
no workflow explicitly "retries" a merge, GitHub does that natively once the
required checks go green.

**Bounded, not looping:** each PR gets at most one Copilot-then-Claude
attempt per fork-commit tip, tracked with the `agent-attempted` label.
A PR that's still red after that stays red (and gets
`needs-manual-adaptation`) until either a human intervenes or the upstream
fork moves again, which resets `auto/*` and clears both labels for a fresh
attempt.

## Required one-time repo setup

- Branch protection on `main`: required status checks `build` and
  `invariants`, no required review count (matches the "full auto-merge"
  policy above) - configured via the GitHub API, not checked into this repo.
- Repository setting "Allow auto-merge" enabled.
- `ANTHROPIC_API_KEY` secret set (Settings → Secrets and variables →
  Actions) for the Claude step in `.github/actions/agent-fallback`.
- Copilot coding agent enabled for this repo, if you want the Copilot-first
  step to ever actually fire (otherwise every conflict/CI-failure goes
  straight to Claude after one wasted 10-minute wait - harmless but slower;
  lower the action's `copilot-timeout-seconds` input in the two call sites
  if you'd rather skip the wait entirely without enabling Copilot).

## Cost note

This repo builds on macOS runners (private repo billing, not the free tier
public repos get) and now potentially triggers extra `build`/`invariants`
runs per agent fix commit, on top of the existing 6-hourly schedule. Not
unbounded (the one-attempt-per-tip cap above), but worth knowing before
leaving this unattended for a long stretch.

## The safety net: `check-invariants.sh`

`.github/scripts/check-invariants.sh` runs as the `invariants` required
check on every PR into `main` - manual or automated, agent-authored or not.
It checks, independent of the Theos build:

- No reintroduction of the C-level `access()`/`stat()`/`fopen()`/`getenv()`
  hooks (via Logos `%hookf` or a fishhook rebind table) - removed upstream
  for crashing in jailed/sideloaded environments, see `Tweak.h`.
- `control`'s `Version:`, `Tweak.h`'s `TWEAK_VERSION`, and
  `BeaInfoViewController.h`'s copy all still match.
- No newly-added bare `NSLog`/`os_log` call outside `BeaLog(...)` gating
  (diff-scoped against the PR base, so it only flags *new* violations, not
  the pre-existing bare `NSLog` calls already in the codebase).
- No newly-added line that looks like a hardcoded credential or private key.

`.github/scripts/test-check-invariants.sh` is this script's own regression
test (synthetic fixtures, one per rule) - run it after changing
`check-invariants.sh`, and add a case for any new rule.

## Integrating a future update by hand

This is the fallback path for anything the automation above leaves with
`needs-manual-adaptation`, or anything you'd rather just do yourself.

1. Find the `sync: update from <fork>` PR (head `auto/<fork>`).
2. Read its diff against `main`.
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
   the `auto/*` PR itself is never merged as-is once you've done this; close
   it once your hand-integrated PR merges.

## Running a sync manually

From the GitHub UI: **Actions -> sync-forks -> Run workflow**. Or with the
GitHub CLI:

```sh
gh workflow run sync-forks.yml
```

This runs both forks' sync jobs immediately instead of waiting for the next
6-hour tick.
