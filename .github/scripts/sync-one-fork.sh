#!/usr/bin/env bash
# Shared body for the sync-forks workflow, run once per fork (nikolozi,
# tqmane) with FORK_REPO/FORK_BRANCH/SYNC_BRANCH/PR_TITLE set by the caller.
# See SYNCING.md for the policy this implements.
set -euo pipefail

: "${FORK_REPO:?}" "${FORK_BRANCH:?}" "${SYNC_BRANCH:?}" "${PR_TITLE:?}" "${GH_TOKEN:?}"

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

if [ "$FORK_SHA" = "$CURRENT_SHA" ]; then
  echo "No change upstream - nothing to do."
  exit 0
fi

echo "== Fork moved, updating $SYNC_BRANCH =="
# The sync branch is a pure mirror of the fork's branch tip - no rebase, no
# merge, no adaptation. It intentionally does NOT touch main.
git push origin "fork/${FORK_BRANCH}:refs/heads/${SYNC_BRANCH}" --force

echo "== Checking mergeability against main (no checkout, no execution of fork code) =="
git fetch origin main --quiet
CONFLICTED=false
# git merge-tree computes the merge purely in-memory (no working tree, no
# branch update, no code from either side ever runs) - this is only used to
# decide which label/comment to apply, never to actually merge anything.
if ! git merge-tree --write-tree "origin/main" "origin/${SYNC_BRANCH}" >/tmp/merge-tree-out.txt 2>&1; then
  CONFLICTED=true
fi
echo "Conflicted: $CONFLICTED"

echo "== Ensuring labels exist =="
gh label create "upstream-sync" --color "0e8a16" --description "Automated fork sync" --force >/dev/null 2>&1 || true
gh label create "manual-review" --color "fbca04" --description "Needs a human look before merging" --force >/dev/null 2>&1 || true
gh label create "needs-manual-adaptation" --color "d93f0b" --description "Sync branch conflicts with main - manual adaptation required" --force >/dev/null 2>&1 || true

PR_NUMBER=$(gh pr list --head "$SYNC_BRANCH" --base main --state open --json number --jq '.[0].number // empty')

BODY=$(cat <<EOF
Automated mirror of [\`${FORK_REPO}@${FORK_BRANCH}\`](https://github.com/${FORK_REPO}/tree/${FORK_BRANCH}), tip \`${FORK_SHA}\`.

This PR is opened/updated by \`.github/workflows/sync-forks.yml\` on a schedule (every 6h) or via \`workflow_dispatch\`. It never auto-merges, never rebases, and never resolves conflicts automatically - see \`SYNCING.md\` for how to integrate it manually.
EOF
)

if [ -z "$PR_NUMBER" ]; then
  echo "== Opening new PR =="
  gh pr create \
    --title "$PR_TITLE" \
    --body "$BODY" \
    --base main \
    --head "$SYNC_BRANCH" \
    --label "upstream-sync" \
    --label "manual-review"
  PR_NUMBER=$(gh pr list --head "$SYNC_BRANCH" --base main --state open --json number --jq '.[0].number')
else
  echo "== Updating existing PR #$PR_NUMBER (body only - the branch push above already refreshed its diff) =="
  gh pr edit "$PR_NUMBER" --body "$BODY"
fi

if [ "$CONFLICTED" = "true" ]; then
  gh pr edit "$PR_NUMBER" --add-label "needs-manual-adaptation"
  gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
:warning: \`${SYNC_BRANCH}\` (now at \`${FORK_SHA}\`) no longer merges cleanly into \`main\`.

This needs a manual adaptation - see \`SYNCING.md\` for the integration steps. The workflow will not attempt to resolve this automatically.
EOF
)"
else
  # Not conflicted (any more) - drop a stale label rather than leave a wrong
  # signal on the PR. This only edits the label, never the code/branches.
  gh pr edit "$PR_NUMBER" --remove-label "needs-manual-adaptation" >/dev/null 2>&1 || true
fi

echo "Done: PR #$PR_NUMBER"
