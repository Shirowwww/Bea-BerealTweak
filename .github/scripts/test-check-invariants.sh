#!/usr/bin/env bash
# Exercises check-invariants.sh against synthetic fixture repos so a change
# to the checker itself can be trusted: each known-bad case must fail, the
# known-good case must pass. This is the actual regression test for the
# guardrail the sync-fallback automation relies on - see AGENTS.md/SYNCING.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check-invariants.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

# Lay down the minimal set of files check-invariants.sh actually reads.
scaffold() {
  local dir="$1" version="$2"
  mkdir -p "$dir/Tweak" "$dir/BeFake/ViewControllers/InfoViewController" "$dir/Utilities/Debug"
  cat > "$dir/control" <<EOF
Package: com.yan.minibea
Version: $version
EOF
  cat > "$dir/Tweak/Tweak.h" <<EOF
#define TWEAK_VERSION @"$version"
EOF
  cat > "$dir/BeFake/ViewControllers/InfoViewController/BeaInfoViewController.h" <<EOF
#ifndef TWEAK_VERSION
#define TWEAK_VERSION @"$version"
#endif
EOF
  cat > "$dir/Utilities/Debug/BeaDebug.h" <<'EOF'
#define BeaLog(fmt, ...) do { if (BeaDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
EOF
  cat > "$dir/Tweak/Tweak.x" <<'EOF'
%hook SomeClass
- (void)someMethod {
  %orig;
}
%end
EOF
  (cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t \
    && git add -A && git commit -q -m base)
}

run_case() {
  local name="$1" expect="$2" dir="$3"; shift 3
  local out rc
  out=$(cd "$dir" && "$CHECKER" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$expect" = "pass" ] && [ "$rc" -ne 0 ]; then
    echo "FAIL [$name]: expected pass, checker exited $rc"; echo "$out"; FAILURES=$((FAILURES+1))
  elif [ "$expect" = "fail" ] && [ "$rc" -eq 0 ]; then
    echo "FAIL [$name]: expected failure, checker exited 0"; FAILURES=$((FAILURES+1))
  else
    echo "ok   [$name]"
  fi
}

# 1. Clean fixture must pass.
d="$WORK/clean"; scaffold "$d" "0.4.0-merged"
run_case "clean fixture" pass "$d"

# 2. Mismatched version strings must fail.
d="$WORK/version-mismatch"; scaffold "$d" "0.4.0-merged"
sed -i 's/0.4.0-merged/0.4.1-merged/' "$d/Tweak/Tweak.h"
run_case "version mismatch" fail "$d"

# 3. Reintroducing a forbidden %hookf on access() must fail.
d="$WORK/forbidden-hookf"; scaffold "$d" "0.4.0-merged"
cat >> "$d/Tweak/Tweak.x" <<'EOF'
%hookf(int, access, const char *path, int mode) {
  return %orig;
}
EOF
run_case "forbidden %hookf(access)" fail "$d"

# 4. Reintroducing a fishhook rebind of getenv must fail.
d="$WORK/forbidden-rebind"; scaffold "$d" "0.4.0-merged"
cat >> "$d/Tweak/Tweak.x" <<'EOF'
// rebinding table entry
static struct rebinding rb[] = { {"getenv", (void*)hook_getenv, (void**)&orig_getenv} };
EOF
run_case "forbidden rebind(getenv)" fail "$d"

# 5. A new bare NSLog added on top of a clean base must fail with --diff-base.
d="$WORK/bare-nslog"; scaffold "$d" "0.4.0-merged"
BASE_SHA=$(cd "$d" && git rev-parse HEAD)
cat >> "$d/Tweak/Tweak.x" <<'EOF'
%new
- (void)dumpTokens {
  NSLog(@"token=%@", self.authToken);
}
EOF
(cd "$d" && git add -A && git commit -q -m "add bare NSLog")
run_case "new bare NSLog (diff-scoped)" fail "$d" --diff-base "$BASE_SHA"

# 6. Same new-NSLog diff, but WITHOUT --diff-base, must pass (not checked).
run_case "new bare NSLog, no diff-base given" pass "$d"

# 7. A new hardcoded-looking secret must fail with --diff-base. Built from
# two halves at runtime so this line itself doesn't trip the same check
# when this very script's diff is scanned.
d="$WORK/hardcoded-secret"; scaffold "$d" "0.4.0-merged"
BASE_SHA=$(cd "$d" && git rev-parse HEAD)
FAKE_TOKEN_PREFIX="ghp_"
FAKE_TOKEN_BODY="1234567890123456789012345678901234"
printf 'static NSString *leaked = @"%s%s";\n' "$FAKE_TOKEN_PREFIX" "$FAKE_TOKEN_BODY" >> "$d/Tweak/Tweak.x"
(cd "$d" && git add -A && git commit -q -m "add secret-looking literal")
run_case "hardcoded secret (diff-scoped)" fail "$d" --diff-base "$BASE_SHA"

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test case(s) failed."
  exit 1
fi
echo "All test-check-invariants.sh cases passed."
