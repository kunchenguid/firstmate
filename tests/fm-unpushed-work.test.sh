#!/usr/bin/env bash
# Tests for fm-unpushed-work.sh, the detector for commits that exist on one disk.
#
# The case that matters most is a never-pushed branch: it has no upstream, so an
# `@{u}` comparison reads it as clean. The second is an unreachable remote, which
# must stay silent rather than report "nothing unpushed".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-unpushed-work.sh"
TMP_ROOT=$(fm_test_tmproot fm-unpushed-work)
fm_git_identity fmtest fmtest@example.invalid

# A bare "forge" plus worktrees/<name> clones that fetched it.
ORIGIN="$TMP_ROOT/origin.git"
git init -q --bare -b main "$ORIGIN"
SEED="$TMP_ROOT/seed"
git clone -q "$ORIGIN" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b main
git -C "$SEED" commit -q --allow-empty -m base
git -C "$SEED" push -q origin main

mk_worktree() { # <name> -> path under $TMP_ROOT/wt/<name>/x/y
  local p="$TMP_ROOT/wt/$1/x/y"
  mkdir -p "$(dirname "$p")"
  git clone -q "$ORIGIN" "$p" 2>/dev/null
  printf '%s\n' "$p"
}
# Unique messages: identical empty commits hash alike and would be "already pushed".
CN=0
commit() { CN=$((CN+1)); git -C "$1" commit -q --allow-empty -m "$2 $CN"; }

GLOB="$TMP_ROOT/wt/*/*/*"
run() { OUT=$(bash "$TOOL" --glob "$GLOB" "$@" 2>"$TMP_ROOT/err"); RC=$?; }

reset_world() { rm -rf "$TMP_ROOT/wt" "$TMP_ROOT/snap"; }

test_never_pushed_branch_is_detected() {
  reset_world
  local w; w=$(mk_worktree never)
  git -C "$w" checkout -q -b fm/never-pushed
  commit "$w" "only here"
  # The trap: no upstream, so @{u} offers no comparison at all.
  git -C "$w" rev-parse --verify -q '@{u}' >/dev/null && fail "fixture unexpectedly has an upstream"
  run
  assert_equals 0 "$RC" "never-pushed scan exit"
  assert_contains "$OUT" "fm/never-pushed" "never-pushed branch named"
  assert_contains "$OUT" "$w" "never-pushed worktree named"
  assert_contains "$OUT" "Do NOT clean" "report forbids cleanup first"
  pass "a never-pushed branch is detected"
}

test_commits_ahead_of_pushed_branch_are_detected() {
  reset_world
  local w; w=$(mk_worktree ahead)
  git -C "$w" checkout -q -b fm/ahead
  commit "$w" one
  git -C "$w" push -q origin fm/ahead 2>/dev/null
  git -C "$w" fetch -q origin
  commit "$w" two
  run
  assert_contains "$OUT" "fm/ahead" "ahead branch named"
  assert_contains "$OUT" "(1 commit(s))" "only the unpushed commit counted"
  pass "commits ahead of a pushed branch are detected"
}

test_clean_worktree_is_silent() {
  reset_world
  mk_worktree clean >/dev/null
  local w; w=$(mk_worktree pushed)
  git -C "$w" checkout -q -b fm/pushed
  commit "$w" one
  git -C "$w" push -q origin fm/pushed 2>/dev/null
  git -C "$w" fetch -q origin
  run
  assert_equals 0 "$RC" "clean scan exit"
  assert_equals "" "$OUT" "clean scan prints nothing"
  pass "clean and fully pushed worktrees are silent"
}

test_finding_is_not_hidden_by_a_clean_final_slot() {
  reset_world
  local w; w=$(mk_worktree aaa)
  git -C "$w" checkout -q -b fm/first
  commit "$w" one
  mk_worktree zzz >/dev/null   # sorts last and is clean
  run
  assert_contains "$OUT" "fm/first" "finding survives a clean last slot"
  pass "a clean last slot does not swallow an earlier finding"
}

test_unreachable_remote_is_silent_and_unknown() {
  reset_world
  local fake="$TMP_ROOT/fakessh"
  printf '#!/usr/bin/env bash\nexit 255\n' > "$fake"; chmod +x "$fake"
  OUT=$(FM_UNPUSHED_SSH="$fake" bash "$TOOL" --host nowhere --snap "$TMP_ROOT/snap" 2>"$TMP_ROOT/err"); RC=$?
  assert_equals 3 "$RC" "unreachable remote exit"
  assert_equals "" "$OUT" "unreachable remote must not print an all-clear"
  assert_contains "$(cat "$TMP_ROOT/err")" "unknown" "unreachable remote says state unknown on stderr"
  # A transport that exits 0 but never completes the scan is the same unknown.
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$fake"
  OUT=$(FM_UNPUSHED_SSH="$fake" bash "$TOOL" --host nowhere 2>/dev/null); RC=$?
  assert_equals 3 "$RC" "truncated scan exit"
  assert_equals "" "$OUT" "truncated scan prints nothing"
  pass "an unreachable or truncated remote is silent and unknown, never an all-clear"
}

test_remote_scan_reports_through_the_transport() {
  reset_world
  mk_worktree aaa >/dev/null   # sorts first and is clean
  local w; w=$(mk_worktree remote)
  git -C "$w" checkout -q -b fm/remote-only
  commit "$w" one
  local fake="$TMP_ROOT/fakessh"
  # Behaves like ssh: drop the options and host, join the rest and run it through a shell.
  # shellcheck disable=SC2016 # The fake ssh expands $1 and $* at runtime.
  printf '#!/usr/bin/env bash\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' > "$fake"; chmod +x "$fake"
  OUT=$(FM_UNPUSHED_SSH="$fake" bash "$TOOL" --host boxy --glob "$GLOB" 2>/dev/null); RC=$?
  assert_equals 0 "$RC" "remote scan exit"
  assert_contains "$OUT" "boxy" "report names the host"
  assert_contains "$OUT" "fm/remote-only" "report names the branch"
  pass "a remote scan reports findings from the far side"
}

test_same_branch_is_reported_once_until_it_clears() {
  reset_world
  local w; w=$(mk_worktree dedupe)
  git -C "$w" checkout -q -b fm/dedupe
  commit "$w" one
  run --snap "$TMP_ROOT/snap"
  assert_contains "$OUT" "fm/dedupe" "first sweep reports"
  commit "$w" two
  run --snap "$TMP_ROOT/snap"
  assert_equals "" "$OUT" "an extra commit on the same branch does not repeat"
  git -C "$w" push -q origin fm/dedupe 2>/dev/null; git -C "$w" fetch -q origin
  run --snap "$TMP_ROOT/snap"
  assert_equals "" "$OUT" "pushed branch is silent"
  commit "$w" three
  run --snap "$TMP_ROOT/snap"
  assert_contains "$OUT" "fm/dedupe" "a branch that goes unpushed again reports again"
  pass "a branch is reported once, and again only after it clears"
}

test_unknown_scan_keeps_the_snapshot() {
  reset_world
  local w; w=$(mk_worktree keep)
  git -C "$w" checkout -q -b fm/keep
  commit "$w" one
  run --snap "$TMP_ROOT/snap"
  local fake="$TMP_ROOT/fakessh"; printf '#!/usr/bin/env bash\nexit 255\n' > "$fake"; chmod +x "$fake"
  FM_UNPUSHED_SSH="$fake" bash "$TOOL" --host nowhere --snap "$TMP_ROOT/snap" >/dev/null 2>&1
  run --snap "$TMP_ROOT/snap"
  assert_equals "" "$OUT" "outage in between does not re-raise the branch"
  pass "a transport failure leaves the dedupe record alone"
}

test_unreadable_worktree_is_reported_not_skipped() {
  reset_world
  local w; w=$(mk_worktree broken)
  rm -rf "$w/.git"
  printf 'gitdir: %s\n' "$TMP_ROOT/gone" > "$w/.git"
  mk_worktree clean >/dev/null
  run
  assert_equals 0 "$RC" "unreadable worktree scan exit"
  assert_contains "$OUT" "$w" "unreadable worktree named"
  assert_contains "$OUT" "cannot read" "unreadable worktree says why"
  pass "a worktree git cannot read is reported, never read as clean"
}

test_detached_head_is_reported_once_as_it_moves() {
  reset_world
  local w; w=$(mk_worktree detached)
  commit "$w" one
  git -C "$w" checkout -q --detach
  run --snap "$TMP_ROOT/snap"
  assert_contains "$OUT" "(detached)" "first sweep reports the detached worktree"
  commit "$w" two
  run --snap "$TMP_ROOT/snap"
  assert_equals "" "$OUT" "a new commit on a detached HEAD does not repeat"
  pass "a detached worktree is reported once even as HEAD moves"
}

test_truncated_branch_ref_is_reported() {
  reset_world
  local w; w=$(mk_worktree truncated)
  git -C "$w" checkout -q -b fm/crashed
  commit "$w" one
  : > "$w/.git/refs/heads/fm/crashed"
  run
  assert_equals 0 "$RC" "truncated ref scan exit"
  assert_contains "$OUT" "$w" "crash-damaged worktree named"
  assert_contains "$OUT" "cannot read" "crash-damaged worktree says why"
  pass "a crash-truncated branch ref is reported, never read as clean"
}

test_never_pushed_branch_is_detected
test_commits_ahead_of_pushed_branch_are_detected
test_clean_worktree_is_silent
test_finding_is_not_hidden_by_a_clean_final_slot
test_unreachable_remote_is_silent_and_unknown
test_remote_scan_reports_through_the_transport
test_same_branch_is_reported_once_until_it_clears
test_unknown_scan_keeps_the_snapshot
test_unreadable_worktree_is_reported_not_skipped
test_detached_head_is_reported_once_as_it_moves
test_truncated_branch_ref_is_reported
