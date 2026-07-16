#!/usr/bin/env bash
# Tests for the merge-poll wake matrix that bin/fm-pr-check.sh arms.
#
# fm-pr-check.sh no longer interpolates task data into a generated check.sh;
# it arms a byte-for-byte copy of bin/fm-pr-poll.sh backed by a private sidecar
# (url/owner/repo/number). The wake decision therefore lives entirely in
# bin/fm-pr-poll.sh, so this file exercises that poll program directly against a
# sidecar. The security/artifact aspects of arming (validation, atomic publish,
# non-interpolation, migration, watcher-bounded wakes) are owned by
# tests/fm-pr-check-security.test.sh.
#
# The watcher's check contract: the poll prints one line iff firstmate should
# wake; silence keeps sleeping. It wakes on the two outcomes that require a
# supervisor act:
#   - ready-to-merge (OPEN + mergeStateStatus=CLEAN): the direct-PR + yolo
#     signal for firstmate to perform the merge itself.
#   - merged (state=MERGED): post-merge confirmation for teardown.
# Silence must cover every interim and not-ready state (pending UNSTABLE,
# blocked BLOCKED, behind BEHIND, dirty DIRTY, empty mergeStateStatus, gh
# failure) so the watcher does not spam wakes while CI is in flight or the PR
# cannot be merged.
#
# Matrix:
#   (a) ready-to-merge: OPEN + CLEAN -> "ready-to-merge"
#   (b) merged: MERGED + CLEAN -> "merged"
#   (c) merged: MERGED + empty status -> "merged" (any post-merge status)
#   (d) interim UNSTABLE: OPEN + UNSTABLE -> silence
#   (e) blocked: OPEN + BLOCKED -> silence
#   (f) behind: OPEN + BEHIND -> silence
#   (g) dirty: OPEN + DIRTY -> silence
#   (h) empty mergeStateStatus: OPEN + (blank) -> silence
#   (i) gh failure -> silence
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)
PR_URL="https://github.com/example/repo/pull/7"

# Build a sandbox that mirrors what fm-pr-check.sh arms: a byte-for-byte copy of
# bin/fm-pr-poll.sh as the check program, its private sidecar with the validated
# provider/url/host/path/number, and a fakebin gh that answers
# `gh pr view URL --json state,mergeStateStatus -q '.state + " " + .mergeStateStatus'`
# with the named pair, exactly as the real gh -q filter would print it.
# Args: case_name pr_state merge_state_status [fail]. Echoes the case dir.
make_case() {
  local name=$1 pr_state=$2 merge_state=$3 fail=${4:-0} case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  cp "$POLL" "$case_dir/state/task-x1.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n' github "$PR_URL" github.com example/repo 7 > "$case_dir/state/task-x1.pr-poll"
  chmod 0700 "$case_dir/state/task-x1.check.sh"
  chmod 0600 "$case_dir/state/task-x1.pr-poll"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    [ "$fail" = 0 ] || exit 1
    printf '%s %s\n' "$pr_state" "$merge_state"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

# Execute the armed poll under the case's fakebin gh and echo its output.
run_poll() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh"
}

test_ready_to_merge_open_clean() {
  local case_dir out
  case_dir=$(make_case ready-clean OPEN CLEAN)
  out=$(run_poll "$case_dir")
  [ "$out" = "ready-to-merge" ] \
    || fail "ready-clean: expected 'ready-to-merge', got '$out'"
  pass "OPEN + CLEAN triggers ready-to-merge wake"
}

test_merged_clean() {
  local case_dir out
  case_dir=$(make_case merged-clean MERGED CLEAN)
  out=$(run_poll "$case_dir")
  [ "$out" = "merged" ] \
    || fail "merged-clean: expected 'merged', got '$out'"
  pass "MERGED + CLEAN triggers merged confirmation wake"
}

test_merged_any_status() {
  local case_dir out
  case_dir=$(make_case merged-empty MERGED "")
  out=$(run_poll "$case_dir")
  [ "$out" = "merged" ] \
    || fail "merged-empty: expected 'merged' for any post-merge status, got '$out'"
  pass "MERGED with empty status still triggers merged wake"
}

test_interim_unstable_silent() {
  local case_dir out
  case_dir=$(make_case unstable OPEN UNSTABLE)
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "unstable: expected silence, got '$out'"
  pass "OPEN + UNSTABLE (pending checks) stays silent"
}

test_blocked_silent() {
  local case_dir out
  case_dir=$(make_case blocked OPEN BLOCKED)
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "blocked: expected silence, got '$out'"
  pass "OPEN + BLOCKED stays silent"
}

test_behind_silent() {
  local case_dir out
  case_dir=$(make_case behind OPEN BEHIND)
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "behind: expected silence, got '$out'"
  pass "OPEN + BEHIND stays silent"
}

test_dirty_silent() {
  local case_dir out
  case_dir=$(make_case dirty OPEN DIRTY)
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "dirty: expected silence, got '$out'"
  pass "OPEN + DIRTY stays silent"
}

test_empty_merge_state_silent() {
  local case_dir out
  case_dir=$(make_case empty-merge OPEN "")
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "empty-merge: expected silence, got '$out'"
  pass "OPEN with empty mergeStateStatus stays silent"
}

test_gh_failure_silent() {
  local case_dir out
  case_dir=$(make_case gh-fail OPEN CLEAN 1)
  out=$(run_poll "$case_dir")
  [ -z "$out" ] \
    || fail "gh-fail: expected silence on gh failure, got '$out'"
  pass "gh failure stays silent (no wake on an unreadable PR)"
}

test_ready_to_merge_open_clean
test_merged_clean
test_merged_any_status
test_interim_unstable_silent
test_blocked_silent
test_behind_silent
test_dirty_silent
test_empty_merge_state_silent
test_gh_failure_silent
