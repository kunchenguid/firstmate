#!/usr/bin/env bash
# Behavior tests for bin/fm-executor-poll.sh and bin/fm-executor-lib.sh: the
# structural terminal-state derivation for kind=executor tasks.
#
# The poll reads two facts and nothing the worker says: the pane shell's exit
# marker (state/<id>.executor-exit) and a live `gh pr list --head fm/<id>`
# read in the task worktree. These cases drive the real poll through the same
# --validated argument shape the watcher passes, over a real throwaway git
# worktree, a fake gh, and a fake tmux whose window inventory and foreground
# command stand in for the endpoint:
#   (a) running inside the bound                          -> silence
#   (b) running past FM_EXECUTOR_MAX_RUNTIME              -> executor-stale
#   (c) exited, open pull request on fm/<id>              -> executor-ready ... ready
#   (d) exited, draft pull request                        -> executor-ready ... draft
#   (e) exited, CLOSED pull request only, commits         -> executor-failed: committed but no PR
#   (f) exited, no pull request, branch at its base       -> executor-failed: no commits ...
#   (g) exited, gh fails                                  -> silent and non-zero (never "no PR")
#   (h) empty pull-request list                           -> never prints a literal null
#   (i) endpoint missing with no exit marker              -> read as exited
#   (j) once-only: the notified marker suppresses a repeat of the same outcome
#       for the same incarnation and lets a new incarnation or a new outcome through
#   (k) a check whose bytes differ from the tracked poll, or a non-executor meta,
#       is not recognized as an executor poll
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-executor-lib.sh"

POLL="$ROOT/bin/fm-executor-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-executor-poll)
fm_git_identity fmtest fmtest@example.invalid

# A fake gh whose `pr list` answers from FM_FAKE_GH_PRS (one "url<TAB>isDraft<TAB>state"
# row per line, filtered by the --jq the poll passes: CLOSED rows are dropped
# and an empty set prints nothing), and fails outright when FM_FAKE_GH_FAIL=1.
# A fake tmux whose window inventory is FM_FAKE_TMUX_WINDOWS and whose pane
# foreground command is FM_FAKE_TMUX_COMMAND (a shell means the process exited,
# an agent name means it is still running).
make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
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
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-zsh}"; exit 0 ;;
      *pane_tty*) exit 1 ;;
    esac
    printf 'fakepane\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/tmux"
  printf '%s\n' "$fb"
}

# A case: state/, a project with a bare origin, a worktree on fm/<id> at a
# recorded base, and an executor meta the watcher would validate.
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
    "yolo=off" "issue=7" "spawn_gen=s1000.1.1" "executor_base=$base" \
    "executor_launched=$(( $(date +%s) - 60 ))"
  chmod 0600 "$dir/state/$id.meta"
  cp "$POLL" "$dir/state/$id.check.sh"
  chmod 0600 "$dir/state/$id.check.sh"
  printf '%s\n' "$dir"
}

# Run the poll exactly as the watcher does: capture the validated record, then
# pass its fields as --validated arguments. Echoes stdout; returns the exit code.
run_poll() {  # <dir> <id>
  local dir=$1 id=$2
  fm_executor_poll_snapshot_capture "$dir/state" "$id" "$POLL" \
    || fail "the executor poll record for $id did not validate"
  PATH="$dir/fakebin:$PATH" "$POLL" --validated "$dir/state" "$id" \
    "$FM_EXECUTOR_GEN" "$FM_EXECUTOR_WORKTREE" "$FM_EXECUTOR_BACKEND" \
    "$FM_EXECUTOR_TARGET" "$FM_EXECUTOR_BASE" "$FM_EXECUTOR_LAUNCHED"
}

set_launched() {  # <dir> <id> <epoch>
  local dir=$1 id=$2 epoch=$3 tmp
  tmp="$dir/state/.meta.tmp"
  grep -v '^executor_launched=' "$dir/state/$id.meta" > "$tmp"
  printf 'executor_launched=%s\n' "$epoch" >> "$tmp"
  mv "$tmp" "$dir/state/$id.meta"
  chmod 0600 "$dir/state/$id.meta"
}

mark_exited() {  # <dir> <id> [code]
  printf '%s\n' "${3:-0}" > "$1/state/$2.executor-exit"
}

test_running_inside_bound_is_silent() {
  local dir out rc
  dir=$(make_case running exec-a1)
  out=$(FM_FAKE_TMUX_WINDOWS=fm-exec-a1 FM_FAKE_TMUX_COMMAND=opencode run_poll "$dir" exec-a1); rc=$?
  expect_code 0 "$rc" "a running executor polls cleanly"
  [ -z "$out" ] || fail "a running executor inside the bound must stay silent, got: $out"
  pass "a running executor inside the runtime bound is silent"
}

test_running_past_bound_is_stale() {
  local dir out rc
  dir=$(make_case stale exec-b1)
  set_launched "$dir" exec-b1 "$(( $(date +%s) - 7200 - 600 ))"
  out=$(FM_FAKE_TMUX_WINDOWS=fm-exec-b1 FM_FAKE_TMUX_COMMAND=opencode run_poll "$dir" exec-b1); rc=$?
  expect_code 0 "$rc" "a stale executor polls cleanly"
  assert_contains "$out" "executor-stale: running 10m past the bound" "the stale line names minutes past the bound"
  # The bound is env-overridable; a larger bound makes the same age quiet again.
  out=$(FM_EXECUTOR_MAX_RUNTIME=36000 FM_FAKE_TMUX_WINDOWS=fm-exec-b1 FM_FAKE_TMUX_COMMAND=opencode run_poll "$dir" exec-b1)
  [ -z "$out" ] || fail "FM_EXECUTOR_MAX_RUNTIME did not widen the bound, got: $out"
  # A shell-only pane with no exit marker is a launch transient, not an exit:
  # it stays running and so still hits the stale bound rather than reading failed.
  out=$(FM_FAKE_TMUX_WINDOWS=fm-exec-b1 FM_FAKE_TMUX_COMMAND=zsh run_poll "$dir" exec-b1)
  assert_contains "$out" "executor-stale:" "a shell-only pane without an exit marker is still running"
  pass "a running executor past FM_EXECUTOR_MAX_RUNTIME reports stale, once the bound is exceeded"
}

test_exited_with_open_pr_is_ready() {
  local dir out rc log
  dir=$(make_case ready exec-c1)
  log="$dir/gh.log"
  mark_exited "$dir" exec-c1
  out=$(FM_FAKE_GH_LOG="$log" FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/41\tfalse\tOPEN' \
    FM_FAKE_TMUX_WINDOWS=fm-exec-c1 run_poll "$dir" exec-c1); rc=$?
  expect_code 0 "$rc" "a ready executor polls cleanly"
  [ "$out" = "executor-ready: PR https://github.com/o/r/pull/41 ready" ] \
    || fail "expected the ready line with the exact URL, got: $out"
  grep -q -- '--head fm/exec-c1' "$log" || fail "the pull request read must be scoped to the task branch"
  pass "an exited executor with an open pull request on fm/<id> reports ready"
}

test_exited_with_draft_pr_reports_draft() {
  local dir out
  dir=$(make_case draft exec-d1)
  mark_exited "$dir" exec-d1
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/42\ttrue\tOPEN' FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_poll "$dir" exec-d1)
  [ "$out" = "executor-ready: PR https://github.com/o/r/pull/42 draft" ] \
    || fail "expected the draft line, got: $out"
  # OPEN outranks MERGED, and a CLOSED (bounced) pull request never counts.
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/40\tfalse\tCLOSED\nhttps://github.com/o/r/pull/39\tfalse\tMERGED\nhttps://github.com/o/r/pull/43\tfalse\tOPEN' \
    FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_poll "$dir" exec-d1)
  [ "$out" = "executor-ready: PR https://github.com/o/r/pull/43 ready" ] \
    || fail "an open pull request must outrank merged and closed ones, got: $out"
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/39\tfalse\tMERGED' FM_FAKE_TMUX_WINDOWS=fm-exec-d1 run_poll "$dir" exec-d1)
  [ "$out" = "executor-ready: PR https://github.com/o/r/pull/39 ready" ] \
    || fail "a merged pull request still reads ready for recording, got: $out"
  pass "draft, open-over-merged, and closed-never-counts are honored"
}

test_exited_with_commits_and_no_pr_is_failed() {
  local dir out
  dir=$(make_case committed exec-e1)
  git -C "$dir/wt" commit -q --allow-empty -m "executor work"
  mark_exited "$dir" exec-e1
  # A bounced (CLOSED) pull request is the only one on the branch: it does not count.
  out=$(FM_FAKE_GH_PRS=$'https://github.com/o/r/pull/44\tfalse\tCLOSED' FM_FAKE_TMUX_WINDOWS=fm-exec-e1 run_poll "$dir" exec-e1)
  [ "$out" = "executor-failed: committed but no PR" ] || fail "expected the committed-no-PR line, got: $out"
  pass "an exited executor with commits but no open pull request reports committed but no PR"
}

test_exited_with_no_commits_is_failed_before_commit() {
  local dir out
  dir=$(make_case nocommit exec-f1)
  mark_exited "$dir" exec-f1 1
  out=$(FM_FAKE_GH_PRS='' FM_FAKE_TMUX_WINDOWS=fm-exec-f1 run_poll "$dir" exec-f1)
  [ "$out" = "executor-failed: no commits and no PR (verify likely failed before commit)" ] \
    || fail "expected the no-commits line, got: $out"
  pass "an exited executor at its base with no pull request reports the pre-commit failure"
}

test_gh_failure_is_silent_and_nonzero() {
  local dir out rc
  dir=$(make_case ghfail exec-g1)
  mark_exited "$dir" exec-g1
  out=$(FM_FAKE_GH_FAIL=1 FM_FAKE_TMUX_WINDOWS=fm-exec-g1 run_poll "$dir" exec-g1); rc=$?
  [ "$rc" -ne 0 ] || fail "a gh failure must exit non-zero"
  [ -z "$out" ] || fail "a gh failure must print nothing (never read as no PR), got: $out"
  pass "a gh failure is silent and non-zero rather than a failed verdict"
}

test_empty_pr_list_never_prints_null() {
  local dir out
  dir=$(make_case emptylist exec-h1)
  mark_exited "$dir" exec-h1
  out=$(FM_FAKE_GH_PRS='' FM_FAKE_TMUX_WINDOWS=fm-exec-h1 run_poll "$dir" exec-h1)
  assert_not_contains "$out" null "an empty pull-request list must never render a literal null"
  out=$(FM_FAKE_GH_PRS='' PATH="$dir/fakebin:$PATH" fm_executor_pr_lookup "$dir/wt" exec-h1)
  [ -z "$out" ] || fail "fm_executor_pr_lookup printed something for an empty list: $out"
  pass "an empty pull-request list is exactly nothing"
}

test_missing_endpoint_without_marker_reads_exited() {
  local dir out
  dir=$(make_case missing exec-i1)
  git -C "$dir/wt" commit -q --allow-empty -m "executor work"
  # No exit marker, and the window is gone from the inventory.
  out=$(FM_FAKE_GH_PRS='' FM_FAKE_TMUX_WINDOWS=other-window run_poll "$dir" exec-i1)
  [ "$out" = "executor-failed: committed but no PR" ] \
    || fail "a missing endpoint with no marker must read as exited, got: $out"
  pass "an authoritatively missing endpoint reads as exited even without the exit marker"
}

test_once_only_notified_marker() {
  local dir state line key
  dir=$(make_case onceonly exec-j1); state="$dir/state"
  line='executor-failed: committed but no PR'
  key=$(fm_executor_outcome_key "$line") || fail "outcome key not derived"
  [ "$key" = failed-no-pr ] || fail "unexpected outcome key: $key"
  ! fm_executor_outcome_already_notified "$state" exec-j1 s1000.1.1 "$key" \
    || fail "a never-notified outcome read as notified"
  fm_executor_outcome_mark_notified "$state" exec-j1 s1000.1.1 "$key" || fail "marking failed"
  fm_executor_outcome_already_notified "$state" exec-j1 s1000.1.1 "$key" \
    || fail "the marked outcome did not read as notified"
  ! fm_executor_outcome_already_notified "$state" exec-j1 s1000.1.1 ready-ready \
    || fail "a different outcome for the same incarnation read as notified"
  ! fm_executor_outcome_already_notified "$state" exec-j1 s2000.2.2 "$key" \
    || fail "a new incarnation's repeat of the outcome read as notified"
  [ "$(fm_pr_file_mode "$state/exec-j1.executor-notified")" = 600 ] || fail "marker must be private"
  fm_executor_incarnation_records_remove "$state" exec-j1 || fail "record removal failed"
  [ ! -e "$state/exec-j1.executor-notified" ] || fail "record removal left the notified marker"
  ! fm_executor_outcome_key merged >/dev/null \
    || fail "an unrelated check line must not map to an executor outcome key"
  pass "one wake per (incarnation, outcome): the notified marker suppresses only exact repeats"
}

test_snapshot_capture_refuses_foreign_check_or_kind() {
  local dir state
  dir=$(make_case capture exec-k1); state="$dir/state"
  fm_executor_poll_snapshot_capture "$state" exec-k1 "$POLL" || fail "a valid executor record did not validate"
  [ "$FM_EXECUTOR_GEN" = s1000.1.1 ] || fail "spawn_gen not captured"
  [ "$FM_EXECUTOR_TARGET" = fmses:fm-exec-k1 ] || fail "endpoint target not captured"
  [ "$FM_EXECUTOR_BACKEND" = tmux ] || fail "absent backend= must read as tmux"
  printf '\n# altered\n' >> "$state/exec-k1.check.sh"
  ! fm_executor_poll_snapshot_capture "$state" exec-k1 "$POLL" \
    || fail "a check whose bytes differ from the tracked poll validated"
  cp "$POLL" "$state/exec-k1.check.sh"; chmod 0600 "$state/exec-k1.check.sh"
  sed -i.bak 's/^kind=executor$/kind=ship/' "$state/exec-k1.meta" && rm -f "$state/exec-k1.meta.bak"
  ! fm_executor_poll_snapshot_capture "$state" exec-k1 "$POLL" \
    || fail "a ship task's record validated as an executor poll"
  sed -i.bak 's/^kind=ship$/kind=executor/; s/^executor_base=.*/executor_base=nothex/' "$state/exec-k1.meta" \
    && rm -f "$state/exec-k1.meta.bak"
  ! fm_executor_poll_snapshot_capture "$state" exec-k1 "$POLL" \
    || fail "a malformed base commit validated"
  pass "only a byte-identical poll over a well-formed executor record is dispatched"
}

test_poll_rejects_direct_invocation_shapes() {
  local out rc
  out=$("$POLL" 2>&1); rc=$?
  expect_code 0 "$rc" "a bare invocation exits 0"
  [ -z "$out" ] || fail "a bare invocation must print nothing, got: $out"
  out=$("$POLL" --validated a b 2>&1); rc=$?
  expect_code 0 "$rc" "a short argument list exits 0"
  [ -z "$out" ] || fail "a short argument list must print nothing, got: $out"
  "$POLL" --help | grep -q 'executor-ready' || fail "--help must print the header"
  pass "the poll is inert outside the watcher's validated argument shape"
}

test_running_inside_bound_is_silent
test_running_past_bound_is_stale
test_exited_with_open_pr_is_ready
test_exited_with_draft_pr_reports_draft
test_exited_with_commits_and_no_pr_is_failed
test_exited_with_no_commits_is_failed_before_commit
test_gh_failure_is_silent_and_nonzero
test_empty_pr_list_never_prints_null
test_missing_endpoint_without_marker_reads_exited
test_once_only_notified_marker
test_snapshot_capture_refuses_foreign_check_or_kind
test_poll_rejects_direct_invocation_shapes
