#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh on kind=executor tasks.
#
# An executor writes no status line and arms no busy hook, so its current state
# comes from bin/fm-executor-lib.sh's structural classifier, the same reader the
# watcher's executor poll runs. These cases pin the four states through the
# real helper over a throwaway git worktree, a fake gh, a fake tmux, and a fake
# no-mistakes that records every call so the suite can prove no run lookup is
# ever attributed to an executor:
#   (a) process alive                                  -> working · executor
#   (b) exited with a pull request (open, draft, merged) -> done · executor · PR ...
#   (c) exited without a pull request (no commits; commits) -> failed · executor
#   (d) liveness unreadable, or gh unavailable          -> unknown · executor
#   (e) FM_CREW_STATE_NO_FORGE=1 on an exited executor  -> unknown, never a guess
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state-executor)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && exit 1
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "${FM_FAKE_GH_PRS:-}" | while IFS=$'\t' read -r url draft state; do
      [ -n "$url" ] || continue
      [ "$state" != CLOSED ] || continue
      printf '%s\t%s\t%s\n' "$url" "$draft" "$state"
    done
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_TMUX_UNREADABLE:-0}" = 1 ] && { printf 'no current client\n' >&2; exit 1; }
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-zsh}"; exit 0 ;;
      *pane_tty*) exit 1 ;;
    esac
    printf '%%1\n'; exit 0 ;;
  capture-pane) printf 'all quiet\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_NM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_NM_LOG"
exit 0
SH
  chmod +x "$fb/gh" "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

make_case() {  # <name> <id> -> echoes case dir
  local name=$1 id=$2 dir base
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_fakebin "$dir" >/dev/null
  fm_git_worktree "$dir/project" "$dir/wt" "fm/$id"
  base=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/wt" \
    "project=$dir/project" "harness=opencode" "kind=executor" "mode=direct-PR" \
    "yolo=off" "issue=4" "spawn_gen=s1000.1.1" "executor_base=$base" \
    "executor_launched=$(( $(date +%s) - 120 ))"
  printf '%s\n' "$dir"
}

run_crew_state() {  # <dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_FAKE_NM_LOG="$1/nm.log" "$CREW_STATE" "$2"
}

test_running_executor_reads_working() {
  local d out
  d=$(make_case working exec-w1)
  out=$(FM_FAKE_TMUX_WINDOWS=fm-exec-w1 FM_FAKE_TMUX_COMMAND=opencode run_crew_state "$d" exec-w1)
  assert_contains "$out" "state: working" "alive process -> working"
  assert_contains "$out" "source: executor" "the source is the executor classifier"
  assert_contains "$out" "running 2m" "the detail names the run time"
  [ ! -s "$d/nm.log" ] || fail "an executor must never consult no-mistakes: $(cat "$d/nm.log")"
  # A shell-only pane with no exit marker is the launch transient, still working.
  out=$(FM_FAKE_TMUX_WINDOWS=fm-exec-w1 FM_FAKE_TMUX_COMMAND=zsh run_crew_state "$d" exec-w1)
  assert_contains "$out" "state: working" "a shell-only pane without an exit marker is still working"
  pass "a running executor reads working from the executor source and never attributes a run"
}

test_exited_with_pr_reads_done() {
  local d out
  d=$(make_case ready exec-d1)
  printf '0\n' > "$d/state/exec-d1.executor-exit"
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/8\tfalse\tOPEN' FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_crew_state "$d" exec-d1)
  [ "$out" = "state: done · source: executor · PR https://github.com/o/r/pull/8 ready" ] \
    || fail "expected the done line with the PR URL, got: $out"
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/8\ttrue\tOPEN' FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_crew_state "$d" exec-d1)
  assert_contains "$out" "PR https://github.com/o/r/pull/8 draft" "a draft is named as a draft"
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/8\tfalse\tMERGED' FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_crew_state "$d" exec-d1)
  [ "$out" = "state: done · source: executor · PR https://github.com/o/r/pull/8 merged" ] \
    || fail "a merged pull request also reads done, got: $out"
  [ ! -s "$d/nm.log" ] || fail "an executor must never consult no-mistakes"
  pass "an exited executor with a pull request reads done, naming the URL and its draft, ready, or merged state"
}

test_exited_without_pr_reads_failed() {
  local d out
  d=$(make_case failed exec-f1)
  printf '1\n' > "$d/state/exec-f1.executor-exit"
  out=$(FM_FAKE_GH_PRS='' FM_FAKE_TMUX_WINDOWS=fm-exec-f1 run_crew_state "$d" exec-f1)
  [ "$out" = "state: failed · source: executor · no commits and no PR (verify likely failed before commit)" ] \
    || fail "expected the pre-commit failure, got: $out"
  git -C "$d/wt" commit -q --allow-empty -m "executor work"
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/9\tfalse\tCLOSED' FM_FAKE_TMUX_WINDOWS=fm-exec-f1 run_crew_state "$d" exec-f1)
  [ "$out" = "state: failed · source: executor · committed but no PR" ] \
    || fail "expected the committed-no-PR failure (a bounced PR never counts), got: $out"
  pass "an exited executor without an open pull request reads failed with the exact failure shape"
}

test_unreadable_liveness_and_gh_failure_read_unknown() {
  local d out
  d=$(make_case unknown exec-u1)
  out=$(FM_FAKE_TMUX_UNREADABLE=1 run_crew_state "$d" exec-u1)
  assert_contains "$out" "state: unknown" "unreadable liveness -> unknown"
  assert_contains "$out" "source: executor" "still attributed to the executor source"
  assert_contains "$out" "liveness unreadable" "the detail names the unreadable endpoint"
  assert_not_contains "$out" "failed" "an unreadable endpoint is never read as a failure"
  printf '0\n' > "$d/state/exec-u1.executor-exit"
  out=$(FM_FAKE_GH_FAIL=1 FM_FAKE_TMUX_WINDOWS=fm-exec-u1 run_crew_state "$d" exec-u1)
  assert_contains "$out" "state: unknown" "gh failure -> unknown"
  assert_contains "$out" "pull-request read failed" "the detail names the failed read"
  out=$(FM_CREW_STATE_NO_FORGE=1 FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/8\tfalse\tOPEN' FM_FAKE_TMUX_WINDOWS=fm-exec-u1 run_crew_state "$d" exec-u1)
  assert_contains "$out" "state: unknown" "no-forge mode never guesses an exited executor's outcome"
  assert_contains "$out" "FM_CREW_STATE_NO_FORGE" "the detail names the skipped read"
  pass "unreadable liveness, a failed pull-request read, and no-forge mode all read unknown, never a guess"
}

test_running_executor_reads_working
test_exited_with_pr_reads_done
test_exited_without_pr_reads_failed
test_unreadable_liveness_and_gh_failure_read_unknown
