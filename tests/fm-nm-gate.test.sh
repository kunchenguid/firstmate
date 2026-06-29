#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-gate.sh - the no-mistakes gate refresh helper.
#
# The gate is shared by a project's main clone and every treehouse worktree of
# it (no-mistakes keys one gate per origin URL). An older no-mistakes installed a
# post-receive hook with a RELATIVE gate path, so a worktree push failed with
# "invalid gate path: ." and no run was created. The fix is to re-run the
# idempotent `no-mistakes init` to refresh the hook. This helper does exactly
# that, guarded and best-effort, so a stale or absent gate never blocks a spawn.
# These cases pin every branch hermetically with a fake `no-mistakes`:
#   (a) usage error (no arg)                         -> exit 2
#   (b) usage error (too many args)                  -> exit 2
#   (c) non-directory / non-git path                 -> skip, exit 0
#   (d) git repo without an origin remote            -> skip, exit 0
#   (e) git repo + origin + no-mistakes installed    -> refreshed (init invoked)
#   (f) no-mistakes not on PATH                       -> skip, exit 0
#   (g) `no-mistakes init` fails                      -> warning, exit 0 (non-fatal)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM_GATE="$ROOT/bin/fm-nm-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-gate)
mkdir -p "$TMP_ROOT"
fm_git_identity fmtest fmtest@example.invalid

# A fakebin whose `no-mistakes init` records that it ran (so we can prove the
# helper invoked the refresh) and honors FM_FAKE_NM_INIT_RC for the failure case.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = init ]; then
  printf 'init-ran\n' >> "$FM_FAKE_NM_INIT_LOG"
  exit "${FM_FAKE_NM_INIT_RC:-0}"
fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A git repo with one commit; origin added only when requested.
make_repo() {  # <dir> [origin-bare]
  local dir=$1 origin=${2:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  if [ -n "$origin" ]; then
    git -C "$dir" init -q --bare "$origin"
    git -C "$dir" remote add origin "file://$origin"
  fi
}

# (a) no arg -> usage error, exit 2
out=$("$NM_GATE" 2>&1); rc=$?
expect_code 2 "$rc" "no-arg should exit 2"
assert_contains "$out" "usage:" "no-arg should print usage"

# (b) too many args -> usage error, exit 2
out=$("$NM_GATE" a b 2>&1); rc=$?
expect_code 2 "$rc" "too-many-args should exit 2"

# (c) non-git directory -> skip, exit 0
NONGIT="$TMP_ROOT/plain"
mkdir -p "$NONGIT"
out=$("$NM_GATE" "$NONGIT" 2>&1); rc=$?
expect_code 0 "$rc" "non-git dir should exit 0"
assert_contains "$out" "skipped" "non-git dir should be skipped"
assert_contains "$out" "not a git repository" "non-git dir reason"

# (d) git repo without origin -> skip, exit 0
NOORIGIN="$TMP_ROOT/noorigin"
make_repo "$NOORIGIN"
out=$("$NM_GATE" "$NOORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "no-origin repo should exit 0"
assert_contains "$out" "no origin remote" "no-origin reason"

# (e) git repo + origin + fake no-mistakes -> refreshed, init actually invoked
WITHORIGIN="$TMP_ROOT/withorigin"
make_repo "$WITHORIGIN" "$TMP_ROOT/origin.git"
FB=$(make_fakebin "$TMP_ROOT")
export FM_FAKE_NM_INIT_LOG="$TMP_ROOT/init.log"
: > "$FM_FAKE_NM_INIT_LOG"
out=$(PATH="$FB:$PATH" "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "healthy refresh should exit 0"
assert_contains "$out" "refreshed" "healthy path should report refreshed"
assert_grep "init-ran" "$FM_FAKE_NM_INIT_LOG" "no-mistakes init must be invoked"

# (f) no-mistakes not installed -> skip, exit 0 (PATH without the fakebin or real binary)
out=$(PATH="/usr/bin:/bin" "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "missing no-mistakes should exit 0"
assert_contains "$out" "no-mistakes not installed" "missing-binary reason"

# (g) no-mistakes init fails -> warning, still exit 0 (non-fatal)
: > "$FM_FAKE_NM_INIT_LOG"
out=$(PATH="$FB:$PATH" FM_FAKE_NM_INIT_RC=1 "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "init failure must stay non-fatal (exit 0)"
assert_contains "$out" "warning" "init failure should warn"

pass "fm-nm-gate.sh: usage, skip, refresh, and non-fatal failure paths hold"
