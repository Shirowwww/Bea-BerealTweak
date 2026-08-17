#!/usr/bin/env bash
# Shared body for the sync-forks workflow, run once per fork (nikolozi,
# tqmane) with FORK_REPO/FORK_BRANCH/SYNC_BRANCH/PR_TITLE set by the caller.
# Mirrors the fork, opens/refreshes the PR, and reports mergeability via
# GITHUB_OUTPUT - the calling workflow decides what to do about a conflict
# (ask the fallback agents) or a clean merge (enable auto-merge). See
# SYNCING.md for the policy this implements.
set -euo pipefail

: "${FORK_REPO:?}" "${FORK_BRANCH:?}" "${SYNC_BRANCH:?}" "${PR_TITLE:?}" "${GH_TOKEN:?}"

# The PR that's actually opened/merged is headed at AUTO_BRANCH, not
# SYNC_BRANCH. SYNC_BRANCH stays a pure, never-hand-edited mirror of the
# fork (force-pushed every cycle) so a fallback agent's fix commits have
# somewhere safe to live without being wiped by the next sync tick or lost
# entirely if the fork moves again mid-review.
AUTO_BRANCH="auto/${SYNC_BRANCH#sync/}"

emit() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

REPO_URL="https://github.com/${FORK_REPO}.git"

git config user.name "sync-forks[bot]"
git config user.email "actions@github.com"

echo "== Fetching ${FORK_REPO}@${FORK_BRANCH} =="
git remote add fork "$REPO_URL" 2>/dev/null || git remote set-url fork "$REPO_URL"
# Read-only fetch of one branch - never checked out, never executed.
git fetch fork "$FORK_BRANCH" --quiet
FORK_SHA=$(git rev-parse fork/"$FORK_BRANCH")
echo "Fork tip: $FORK_SHA"

git fetch origin "$SYNC_BRANCH" --quiet 2>/dev/null || true
if git rev-parse --verify "origin/$SYNC_BRANCH" >/dev/null 2>&1; then
  CURRENT_SHA=$(git rev-parse "origin/$SYNC_BRANCH")
else
  CURRENT_SHA=""
fi
echo "Current $SYNC_BRANCH tip: ${CURRENT_SHA:-<branch does not exist yet>}"

emit "auto_branch" "$AUTO_BRANCH"
emit "fork_sha" "$FORK_SHA"

if [ "$FORK_SHA" = "$CURRENT_SHA" ]; then
  echo "No change upstream - nothing to do."
  emit "moved" "false"
  emit "conflicted" "false"
  emit "pr_number" ""
  exit 0
fi
emit "moved" "true"

echo "== Fork moved, updating $SYNC_BRANCH =="
# The sync branch is a pure mirror of the fork's branch tip - no rebase, no
# merge, no adaptation, ever (not even by a fallback agent). It intentionally
# does NOT touch main.
git push origin "fork/${FORK_BRANCH}:refs/heads/${SYNC_BRANCH}" --force

echo "== Resetting $AUTO_BRANCH to the new $SYNC_BRANCH tip =="
# New fork commits invalidate any in-flight agent fix from a previous cycle
# (it was resolving conflicts/CI against an old tip) - start clean.
git push origin "fork/${FORK_BRANCH}:refs/heads/${AUTO_BRANCH}" --force

echo "== Checking mergeability against main (no checkout, no execution of fork code) =="
git fetch origin main --quiet
CONFLICTED=false
# git merge-tree computes the merge purely in-memory (no working tree, no
# branch update, no code from either side ever runs) - this is only used to
# decide which label/comment to apply, never to actually merge anything.
if ! git merge-tree --write-tree "origin/main" "origin/${AUTO_BRANCH}" >/tmp/merge-tree-out.txt 2>&1; then
  CONFLICTED=true
fi
echo "Conflicted: $CONFLICTED"
emit "conflicted" "$CONFLICTED"

echo "== Ensuring labels exist =="
gh label create "upstream-sync" --color "0e8a16" --description "Automated fork sync" --force >/dev/null 2>&1 || true
gh label create "manual-review" --color "fbca04" --description "Needs a human look before merging" --force >/dev/null 2>&1 || true
gh label create "needs-manual-adaptation" --color "d93f0b" --description "Sync branch conflicts with main - manual adaptation required" --force >/dev/null 2>&1 || true

PR_NUMBER=$(gh pr list --head "$AUTO_BRANCH" --base main --state open --json number --jq '.[0].number // empty')

BODY=$(cat <<EOF
Automated mirror of [\`${FORK_REPO}@${FORK_BRANCH}\`](https://github.com/${FORK_REPO}/tree/${FORK_BRANCH}), tip \`${FORK_SHA}\` (mirrored verbatim on \`${SYNC_BRANCH}\`).

This PR is opened/updated by \`.github/workflows/sync-forks.yml\` on a schedule (every 6h) or via \`workflow_dispatch\`, from \`${AUTO_BRANCH}\` (a working copy that a fallback agent may commit to - \`${SYNC_BRANCH}\` itself is never touched). If it merges cleanly and CI (\`build\` + \`invariants\`) passes, it auto-merges into \`main\`. If not, Copilot then Claude (Sonnet 5) are asked to fix it, bound by the rules in \`AGENTS.md\`; after both are tried once, an unresolved PR is left with \`needs-manual-adaptation\` for a human - see \`SYNCING.md\`.
EOF
)

if [ -z "$PR_NUMBER" ]; then
  echo "== Opening new PR =="
  gh pr create \
    --title "$PR_TITLE" \
    --body "$BODY" \
    --base main \
    --head "$AUTO_BRANCH" \
    --label "upstream-sync" \
    --label "manual-review"
  PR_NUMBER=$(gh pr list --head "$AUTO_BRANCH" --base main --state open --json number --jq '.[0].number')
else
  echo "== Updating existing PR #$PR_NUMBER (body only - the branch push above already refreshed its diff) =="
  gh pr edit "$PR_NUMBER" --body "$BODY"
fi
emit "pr_number" "$PR_NUMBER"

# Fresh fork commit -> fresh cycle: drop any leftover state from a previous
# attempt against the old tip so the fallback agents get to try again.
gh pr edit "$PR_NUMBER" --remove-label "agent-attempted" >/dev/null 2>&1 || true

if [ "$CONFLICTED" = "true" ]; then
  gh pr edit "$PR_NUMBER" --add-label "needs-manual-adaptation"
  gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
:warning: \`${AUTO_BRANCH}\` (from \`${SYNC_BRANCH}\` at \`${FORK_SHA}\`) no longer merges cleanly into \`main\`. Asking Copilot, then Claude, to resolve it - see \`SYNCING.md\`.
EOF
)"
else
  gh pr edit "$PR_NUMBER" --remove-label "needs-manual-adaptation" >/dev/null 2>&1 || true
fi

echo "Done: PR #$PR_NUMBER (conflicted=$CONFLICTED)"
