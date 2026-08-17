#!/usr/bin/env bash
# Guardrail checks for anything landing on main (manually, via sync, or via
# an agent-authored fix commit) - see AGENTS.md/SYNCING.md for the rules
# this encodes. Exits non-zero on the first violation found; prints all
# violations it finds in a given check before exiting.
#
# Usage: check-invariants.sh [--diff-base <git-ref>]
#
# --diff-base scopes the logging/secret checks (which would false-positive
# against pre-existing code) to only lines added since that ref. Without it,
# only the absolute checks (forbidden hooks, version consistency) run.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DIFF_BASE=""
if [ "${1:-}" = "--diff-base" ]; then
  DIFF_BASE="${2:?--diff-base requires a git ref}"
fi

FAILED=0
fail() {
  echo "::error::$1"
  FAILED=1
}

echo "== Checking forbidden C-level hooks are not reintroduced =="
# See Tweak.h / Tweak.x / SYNCING.md: access()/stat()/fopen()/getenv() were
# removed for crashing in jailed/sideloaded environments and must never come
# back, whether via Logos %hookf or a fishhook rebind_symbols table.
if grep -rEn --include='*.x' --include='*.xm' \
    '%hookf\([^,]*,\s*(access|stat|lstat|fopen|getenv)\b' . 2>/dev/null; then
  fail "Found a %hookf on access()/stat()/lstat()/fopen()/getenv() - these are deliberately not hooked, see Tweak.h."
fi
if grep -rEni --include='*.x' --include='*.xm' --include='*.m' --include='*.mm' --include='*.c' --include='*.cpp' \
    'rebind' . 2>/dev/null | grep -E '"(access|stat|lstat|fopen|getenv)"'; then
  fail "Found a fishhook rebind table entry targeting access/stat/lstat/fopen/getenv."
fi

echo "== Checking version string consistency =="
CONTROL_VERSION=$(grep -E '^Version:' control | sed 's/^Version:[[:space:]]*//' | tr -d '\r\n')
TWEAK_H_VERSION=$(grep -oE '#define TWEAK_VERSION @"[^"]+"' Tweak/Tweak.h | grep -oE '"[^"]+"' | tr -d '"')
INFO_VC_VERSION=$(grep -oE '#define TWEAK_VERSION @"[^"]+"' BeFake/ViewControllers/InfoViewController/BeaInfoViewController.h | grep -oE '"[^"]+"' | tr -d '"')

echo "control: $CONTROL_VERSION | Tweak.h: $TWEAK_H_VERSION | BeaInfoViewController.h: $INFO_VC_VERSION"

if [ -z "$CONTROL_VERSION" ] || [ -z "$TWEAK_H_VERSION" ] || [ -z "$INFO_VC_VERSION" ]; then
  fail "Could not extract one of the three version strings - has a file been restructured?"
elif [ "$CONTROL_VERSION" != "$TWEAK_H_VERSION" ] || [ "$CONTROL_VERSION" != "$INFO_VC_VERSION" ]; then
  fail "Version strings diverged: control=$CONTROL_VERSION Tweak.h=$TWEAK_H_VERSION BeaInfoViewController.h=$INFO_VC_VERSION - these three must move together (see AGENTS.md)."
fi

if [ -n "$DIFF_BASE" ]; then
  echo "== Checking added lines against ${DIFF_BASE} for ungated logging =="
  # New verbose/data-dumping logging must go through BeaLog(...), not a bare
  # NSLog/os_log - see Utilities/Debug/BeaDebug.h. Existing bare NSLog calls
  # predate this rule and are intentionally not flagged here.
  ADDED_LOG_LINES=$(git diff "${DIFF_BASE}...HEAD" -- '*.m' '*.mm' '*.x' '*.xm' \
      ':(exclude)Utilities/Debug/BeaDebug.h' 2>/dev/null \
    | grep -E '^\+[^+]' \
    | grep -E '\b(NSLog|os_log)\s*\(' | grep -v 'BeaLog(' || true)
  if [ -n "$ADDED_LOG_LINES" ]; then
    fail "New logging call(s) added outside BeaLog(...)/MINIBEA_DEBUG gating:
$ADDED_LOG_LINES"
  fi

  echo "== Checking added lines against ${DIFF_BASE} for obvious hardcoded secrets =="
  ADDED_SECRET_LINES=$(git diff "${DIFF_BASE}...HEAD" 2>/dev/null \
    | grep -E '^\+[^+]' \
    | grep -E 'ghp_[A-Za-z0-9]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY-----' || true)
  if [ -n "$ADDED_SECRET_LINES" ]; then
    fail "New line(s) look like a hardcoded credential/private key:
$ADDED_SECRET_LINES"
  fi
else
  echo "(no --diff-base given, skipping diff-scoped logging/secret checks)"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "::error::Invariant check failed - see above."
  exit 1
fi
echo "All invariant checks passed."
