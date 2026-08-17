#!/usr/bin/env bash
# Prints the shared, rule-bound task description given to both Copilot (as
# an @copilot PR comment) and Claude (as claude-code-action's `prompt`
# input) - single source of truth so the two agents get identical scope
# limits. See AGENTS.md/SYNCING.md for the rules encoded below.
#
# Usage: agent-prompt.sh <conflict|ci-fix> <pr-number> <branch> <fork-repo> <fork-branch>
set -euo pipefail

MODE="${1:?}"
PR_NUMBER="${2:?}"
BRANCH="${3:?}"
FORK_REPO="${4:?}"
FORK_BRANCH="${5:?}"

if [ "$MODE" = "conflict" ]; then
  echo "This PR (#${PR_NUMBER}) mirrors upstream fork \`${FORK_REPO}@${FORK_BRANCH}\` and no longer merges cleanly into \`main\`. Resolve the merge conflict on this branch (\`${BRANCH}\`) so it merges cleanly into \`main\`."
else
  echo "This PR (#${PR_NUMBER}) is an automated mirror of upstream fork \`${FORK_REPO}@${FORK_BRANCH}\` and its CI checks are failing on this branch's (\`${BRANCH}\`) latest commit. Look at the failing check(s) and fix whatever is causing them, without changing the intended behavior of the fork's incoming changes. If the failure looks environmental/flaky rather than a real bug, say so in a comment instead of masking it."
fi

cat <<EOF

Rules you MUST follow (repo policy - see AGENTS.md and SYNCING.md for full context):
- This repo (MiniBea) is a jailbreak/sideload tweak injected into the BeReal app on real devices. It has no test suite beyond a Theos build + the automated invariant checks - be conservative.
- Prefer main's existing behavior/architecture when in doubt; only take the incoming fork change if it's a clear, narrowly-scoped fix with no side effects you can't verify.
- Never reintroduce C-level access()/stat()/fopen()/getenv() hooks (via Logos %hookf or a fishhook rebind table) - they were deliberately removed for crashing in jailed/sideloaded environments.
- Keep verbose/data-dumping logging behind BeaLog(...)/MINIBEA_DEBUG (Utilities/Debug/BeaDebug.h) - never add a bare NSLog/os_log that could print tokens, cookies, or other PII.
- Do not touch SideloadFix/SideloadFix.xm unless the problem is literally inside that file - it's the most fragile file in the repo (CF ownership / double-free risk on the SecItem* rebinding).
- Do not change the three version-string locations (control, Tweak/Tweak.h, BeaInfoViewController.h) unless that's specifically what's broken - if you do, keep all three identical.
- Make the smallest change that fixes the problem. Do not refactor, rename, reformat, or "clean up" unrelated code.
- Do not weaken, skip, or disable any CI check (build step or the invariants script) to make it pass - fix the actual cause.
- If you cannot do this safely within these constraints, do not guess or make a partial/incorrect change - leave the code as-is and explain what's blocking you instead.
EOF
