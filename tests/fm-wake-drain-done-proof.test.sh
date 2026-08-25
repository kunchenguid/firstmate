#!/usr/bin/env bash
# tests/fm-wake-drain-done-proof.test.sh - the drain's presentation must prove a
# presented done claim against its recorded delivery and carry a loud refutation
# line when nothing backs it, so a done-without-delivery report can no longer
# read as green (four measured incidents, 2026-08-24/25). Portable regression:
# the real drain runs over crafted status logs, real throwaway git repos with a
# bare origin, and a recording fake `gh`.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-done-proof)
fm_git_identity fmtest fmtest@example.invalid

TASK=prooftask

make_gh_stub() {  # <dir>
  local d=$1
  local fb="$d/fakebin"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?GH_STUB_LOG unset}"
if [ -n "${GH_STUB_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "${GH_STUB_OUT:-[]}"
exit 0
SH
  chmod +x "$fb/gh"
}

# Case dir with state/, fakebin (tmux + crew-state + gh stubs), project repo,
# bare origin with the default branch published, and a task worktree on branch
# fm/prooftask at the base commit.
make_proof_case() {  # <name> <mode>
  local name=$1 mode=$2 dir base
  dir=$(make_case "$name")
  make_gh_stub "$dir"
  fm_git_worktree "$dir/project" "$dir/wt" "fm/$TASK"
  base=$(git -C "$dir/project" symbolic-ref --quiet --short HEAD)
  git -C "$dir/project" push -q origin "$base"
  git -C "$dir/project" fetch -q origin
  fm_write_meta "$dir/state/$TASK.meta" \
    "window=fake:fm-$TASK" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=$mode" \
    "yolo=off"
  printf '%s\n' "$dir"
}

run_drain() {  # <case-dir> [stdout-file] [stderr-file]
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" \
    > "${2:-/dev/null}" 2> "${3:-/dev/null}"
}

prime_cursor() {  # <case-dir>
  local dir=$1 status="$1/state/$TASK.status"
  printf 'working: started\n' > "$status"
  run_drain "$dir" || fail "bootstrap drain failed while priming the cursor"
}

test_refuted_done_is_loud_and_non_terminal() {
  local dir out
  dir=$(make_proof_case refute-loud no-mistakes)
  prime_cursor "$dir"
  export GH_STUB_LOG="$dir/gh.log" GH_STUB_OUT='[]'

  printf 'done: Klassenbahn abgeschlossen, 4 Commits auf fm/%s\n' "$TASK" >> "$dir/state/$TASK.status"
  append_wake "$dir/state" signal "$TASK.status" 'status change'
  run_drain "$dir" "$TMP_ROOT/refute.out" /dev/null
  out=$(cat "$TMP_ROOT/refute.out")

  assert_contains "$out" 'done WIDERLEGT - keine Lieferung am Ziel (ls-remote leer, kein PR)' \
    "the refutation is loud with its evidence"
  assert_contains "$out" "$TASK.status: done: Klassenbahn abgeschlossen" \
    "the refutation names the claimed done line"
  # U1.3b presentation-consume: one further drain invocation consumes what
  # this one presented.
  run_drain "$dir" "$TMP_ROOT/refute2.out" /dev/null
  out=$(cat "$TMP_ROOT/refute2.out")
  assert_not_contains "$out" 'signal' "the presented wake is consumable by the next drain"
  unset GH_STUB_LOG GH_STUB_OUT
  pass "a done claim without delivery is loudly refuted in the presentation"
}

gh_calls_or_zero() {  # <log>
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0'
}

test_delivered_done_runs_through_unchanged() {
  local dir out
  dir=$(make_proof_case green-push direct-PR)
  prime_cursor "$dir"
  export GH_STUB_LOG="$dir/gh.log"

  git -C "$dir/wt" commit -q --allow-empty -m "the fix"
  git -C "$dir/wt" push -q origin "fm/$TASK"
  printf 'done: PR https://example.invalid/1 checks green\n' >> "$dir/state/$TASK.status"
  append_wake "$dir/state" signal "$TASK.status" 'status change'
  run_drain "$dir" "$TMP_ROOT/green.out" "$TMP_ROOT/green.err"
  out=$(cat "$TMP_ROOT/green.out")

  assert_not_contains "$out" 'WIDERLEGT' "a delivered claim is not refuted"
  assert_contains "$out" "wake annotation:" "the ordinary annotation still carries the event"
  [ "$(gh_calls_or_zero "$dir/gh.log")" = "0" ] || fail "gh ran although ls-remote already delivered"
  unset GH_STUB_LOG
  pass "a done claim backed by an origin branch passes unchanged and skips the PR probe"
}

test_local_only_committed_passes_empty_branch_refuted() {
  local dir out
  dir=$(make_proof_case local-pair local-only)
  prime_cursor "$dir"

  # The committed branch delivers; the presentation stays silent about it.
  git -C "$dir/wt" commit -q --allow-empty -m "the fix"
  printf 'done: fertig im Zweig\n' >> "$dir/state/$TASK.status"
  append_wake "$dir/state" signal "$TASK.status" 'status change'
  run_drain "$dir" "$TMP_ROOT/local-green.out" /dev/null
  out=$(cat "$TMP_ROOT/local-green.out")
  assert_contains "$out" "wake annotation:" "the committed local-only claim was annotated"
  assert_not_contains "$out" 'WIDERLEGT' "a committed local-only branch is not refuted"

  # A second task on an EMPTY branch is the loud failure: branch from the base
  # commit, not from prooftask's now-carried work.
  git -C "$dir/wt" checkout -q -b fm/emptytask \
    "$(git -C "$dir/project" symbolic-ref --quiet --short HEAD)"
  fm_write_meta "$dir/state/emptytask.meta" \
    "window=fake:fm-emptytask" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf 'working: started\n' > "$dir/state/emptytask.status"
  run_drain "$dir" /dev/null /dev/null
  printf 'done: angeblich fertig\n' >> "$dir/state/emptytask.status"
  append_wake "$dir/state" signal 'emptytask.status' 'status change'
  run_drain "$dir" "$TMP_ROOT/local-empty.out" /dev/null
  out=$(cat "$TMP_ROOT/local-empty.out")
  assert_contains "$out" 'done WIDERLEGT - keine Lieferung am Ziel (leerer Zweig fm/emptytask im Worktree)' \
    "an empty local-only branch is loudly refuted"
  pass "local-only delivery follows the committed-work rule in both directions"
}

test_no_probe_outside_the_done_case() {
  local dir out logcount
  dir=$(make_proof_case no-probe no-mistakes)
  prime_cursor "$dir"
  export GH_STUB_LOG="$dir/gh.log" GH_STUB_OUT='[]'

  printf 'working: rebased onto main\n' >> "$dir/state/$TASK.status"
  append_wake "$dir/state" signal "$TASK.status" 'progress note'
  run_drain "$dir" "$TMP_ROOT/noprobe.out" /dev/null
  out=$(cat "$TMP_ROOT/noprobe.out")

  assert_contains "$out" "wake annotation:" "the non-done event was annotated as usual"
  assert_not_contains "$out" 'WIDERLEGT' "no refutation for a working line"
  logcount=$(gh_calls_or_zero "$dir/gh.log")
  [ "$logcount" = "0" ] || fail "gh probed outside the done case ($logcount calls)"
  unset GH_STUB_LOG GH_STUB_OUT
  pass "non-done lines are annotated without any delivery probe"
}

test_main() {
  test_refuted_done_is_loud_and_non_terminal
  test_delivered_done_runs_through_unchanged
  test_local_only_committed_passes_empty_branch_refuted
  test_no_probe_outside_the_done_case
}

test_main
echo "all fm-wake-drain-done-proof tests passed"
