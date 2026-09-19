#!/usr/bin/env bash
# fm-worktree-drift.sh: a live ship or scout worker whose foreground directory
# is outside its recorded worktree is caught and relaunched into the worktree.
#
# Hermetic: a stubbed session provider models a resumed agent whose own cwd is
# the primary checkout while the pane's shell sits in the worktree (the shape a
# restored Herdr pane has after a reboot). Pins:
#   1. scan reports only a positively live worker confirmed outside its
#      worktree on two reads, and names the primary checkout when that is where
#      it is.
#   2. repair relaunches it through fm-control into the worktree, and never
#      writes the primary checkout it drifted into.
#   3. repair re-registers a PR merge poll that stopped authenticating.
#   4. a refused relaunch is reported once, not retried in a loop.
#   5. --wake publishes the outcome to the durable wake queue, and a second
#      concurrent repair stands down.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

DRIFT="$ROOT/bin/fm-worktree-drift.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-drift)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
TASK_TMPS=()

drift_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap drift_cleanup EXIT

# The lifecycle-modelling tmux stub from tests/fm-control-relaunch.test.sh,
# except that the pane's current path is the running agent's own directory
# (fake/agent-cwd) while an agent runs and the shell's (fake/cwd) otherwise; a
# fake/agent-cwd-then replaces the agent's directory after the next read.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          cat "$D/cwd" > "$D/agent-cwd"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ "$(cat "$D/command")" = zsh ]; then cat "$D/cwd"; else cat "$D/agent-cwd"; fi
          printf '\n'
          [ ! -f "$D/agent-cwd-then" ] || mv "$D/agent-cwd-then" "$D/agent-cwd"
          exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/gh"
  chmod +x "$fb/gh"
}

# new_case <name> -> a case dir with a primary checkout, its task worktree, and
# a live claude ship task t1 whose agent runs in <agent-dir> (default: the
# primary checkout).
new_case() {  # <name> [kind]
  local dir="$TMP_ROOT/$1-$RANDOM" kind=${2:-ship}
  mkdir -p "$dir/home/state" "$dir/home/data/t1" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' fm-t1 > "$dir/fake/windows"
  make_tmux_stub "$dir"
  fm_git_worktree "$dir/proj" "$dir/wt" task-t1
  printf '%s\n' '# Task' "## Captain's intent" 'Keep working.' '' '## Firstmate spec' 'Stay in the worktree.' \
    > "$dir/home/data/t1/brief.md"
  {
    echo "window=fmses:fm-t1"
    echo "endpoint_task_id=t1"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-drift-t1"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/t1.meta"
  TASK_TMPS+=("/tmp/fm-drift-t1")
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf '%s' "$dir/proj" > "$dir/fake/agent-cwd"
  printf '%s\n' "$dir"
}

run_drift() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_WORKTREE_DRIFT_CONFIRM_SECS=0 \
    "$DRIFT" "$@" 2>&1
}

# Every entry, size, mtime, and inode of the primary checkout, including its
# .git, except the two paths every linked worktree legitimately shares with it:
# .git/worktrees/ (the worktree's own administrative state) and
# .git/info/exclude (where the task's spawn idempotently hides its own hook
# files; a real task wrote those lines at first spawn, this fixture never did).
primary_snapshot() {  # <case-dir>
  (cd "$1/proj" && find . \( -path ./.git/worktrees -o -path ./.git/info/exclude \) -prune -o -print0 | sort -z \
    | xargs -0 stat -c '%n %s %Y %i' \
    && git --no-optional-locks status --porcelain --ignored)
}

# --- 1. scan -----------------------------------------------------------------

test_scan_reports_a_live_worker_in_the_primary_checkout() {
  local dir out
  dir=$(new_case scan-primary)
  out=$(run_drift "$dir" scan)
  assert_equals "$(printf 'drift\tt1\t%s\t%s\tprimary' "$dir/proj" "$dir/wt")" "$out" \
    "a live worker in the primary checkout is drift, named as the primary"
  pass "scan: a live worker running in the primary checkout is reported"
}

test_scan_ignores_a_worker_in_or_beneath_its_worktree() {
  local dir out
  dir=$(new_case scan-inside)
  printf '%s' "$dir/wt" > "$dir/fake/agent-cwd"
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "a worker in its worktree is not drift"
  mkdir -p "$dir/wt/sub"
  printf '%s' "$dir/wt/sub" > "$dir/fake/agent-cwd"
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "a worker beneath its worktree is not drift"
  pass "scan: a worker in or beneath its worktree is left alone"
}

test_scan_names_an_unrelated_directory_as_outside() {
  local dir out
  dir=$(new_case scan-outside)
  mkdir -p "$dir/elsewhere"
  printf '%s' "$dir/elsewhere" > "$dir/fake/agent-cwd"
  out=$(run_drift "$dir" scan)
  assert_equals "$(printf 'drift\tt1\t%s\t%s\toutside' "$dir/elsewhere" "$dir/wt")" "$out" \
    "a directory outside both checkouts is drift, named as outside"
  pass "scan: a worker outside both its worktree and the primary is reported as outside"
}

test_scan_ignores_a_directory_that_changes_before_the_confirming_read() {
  local dir out
  dir=$(new_case scan-transient)
  printf '%s' "$dir/wt" > "$dir/fake/agent-cwd-then"
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "a single read outside the worktree is not drift"
  pass "scan: a directory read once outside the worktree and then inside it is not drift"
}

test_scan_ignores_a_dead_agent_and_a_secondmate() {
  local dir out
  dir=$(new_case scan-dead)
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "a dead endpoint is recovery's case, not drift"
  dir=$(new_case scan-mate secondmate)
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "a secondmate is not a ship or scout worker"
  pass "scan: a dead agent and a secondmate are not treated as drift"
}

# --- 2. repair ---------------------------------------------------------------

test_repair_relaunches_into_the_worktree_and_never_writes_the_primary() {
  local dir out rc before after
  dir=$(new_case repair)
  before=$(primary_snapshot "$dir")
  out=$(run_drift "$dir" repair); rc=$?
  expect_code 0 "$rc" "repair should succeed"$'\n'"$out"
  assert_contains "$out" "WORKTREE_DRIFT: task t1's worker was running in the primary checkout $dir/proj" \
    "the outcome names the primary checkout"
  assert_contains "$out" "it was relaunched into its worktree" "the outcome names the relaunch"
  assert_grep "/exit" "$dir/fake/literal" "the drifted agent must be stopped"
  assert_equals "$dir/wt" "$(cat "$dir/fake/agent-cwd")" "the replacement must run in the worktree"
  assert_equals complete "$(grep '^phase=' "$dir/home/state/t1.control-relaunch" | tail -1 | cut -d= -f2)" \
    "the relaunch transaction should complete"
  assert_grep "never run anything in $dir/proj" "$dir/home/data/t1/brief.md" \
    "the replacement is told where the old session was"
  out=$(run_drift "$dir" scan)
  assert_equals "" "$out" "after repair the worker is no longer drift"
  after=$(primary_snapshot "$dir")
  assert_equals "$before" "$after" "the primary checkout must never be written"
  pass "repair: a drifted worker is relaunched into its worktree and the primary checkout is untouched"
}

test_repair_does_nothing_when_no_worker_drifted() {
  local dir out
  dir=$(new_case repair-clean)
  printf '%s' "$dir/wt" > "$dir/fake/agent-cwd"
  out=$(run_drift "$dir" repair)
  assert_equals "" "$out" "a clean fleet prints nothing"
  assert_equals "" "$(cat "$dir/fake/literal")" "a clean fleet sends nothing"
  pass "repair: a fleet with no drift is left alone"
}

# --- 3. PR poll ----------------------------------------------------------------

test_repair_reregisters_a_pr_poll_that_stopped_authenticating() {
  local dir out rc
  dir=$(new_case repair-poll)
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/example/repo/pull/7 2>&1); rc=$?
  expect_code 0 "$rc" "the PR poll should arm"$'\n'"$out"
  printf 'decisions_reviewed=1\n' >> "$dir/home/state/t1.meta"
  ! fm_pr_poll_artifacts_valid "$dir/home/state" t1 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "fixture: a record line after pr= should stop the poll authenticating"
  out=$(run_drift "$dir" repair); rc=$?
  expect_code 0 "$rc" "repair should succeed"$'\n'"$out"
  assert_contains "$out" "its PR merge poll for https://github.com/example/repo/pull/7 was re-registered" \
    "the outcome names the re-registration"
  fm_pr_poll_artifacts_valid "$dir/home/state" t1 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the relaunched lane's PR poll must authenticate again"
  pass "repair: a PR merge poll that stopped authenticating is re-registered after the relaunch"
}

test_repair_leaves_an_authenticated_pr_poll_alone() {
  local dir out rc reg_before
  dir=$(new_case repair-poll-ok)
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/example/repo/pull/8 >/dev/null 2>&1
  reg_before=$(cat "$dir/home/state/t1.pr-poll-registration")
  out=$(run_drift "$dir" repair); rc=$?
  expect_code 0 "$rc" "repair should succeed"$'\n'"$out"
  assert_not_contains "$out" "re-register" "an authenticated poll needs no re-registration"
  assert_equals "$reg_before" "$(cat "$dir/home/state/t1.pr-poll-registration")" \
    "an authenticated poll's registration is untouched"
  fm_pr_poll_artifacts_valid "$dir/home/state" t1 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the relaunched lane's PR poll must still authenticate"
  pass "repair: an armed PR poll that still authenticates is kept as is"
}

# --- 4. refused relaunch --------------------------------------------------------

test_a_refused_relaunch_is_reported_once_and_not_retried() {
  local dir out before
  dir=$(new_case refused)
  printf 'half-typed text' > "$dir/fake/composer"
  before=$(primary_snapshot "$dir")
  out=$(run_drift "$dir" repair)
  assert_contains "$out" "relaunching it into its worktree FAILED" "a refused relaunch is reported"
  assert_contains "$out" "bin/fm-control.sh t1 exit" "the report names the stop command"
  assert_present "$dir/home/state/.worktree-drift-failed-t1" "the failed episode is recorded"
  out=$(run_drift "$dir" repair)
  assert_equals "" "$out" "the same failed drift is not retried or re-reported"
  printf '%s' "$dir/wt" > "$dir/fake/agent-cwd"
  run_drift "$dir" repair >/dev/null
  assert_absent "$dir/home/state/.worktree-drift-failed-t1" "a worker back in its worktree closes the episode"
  printf '%s\n' "$dir/proj" > "$dir/home/state/.worktree-drift-failed-gone"
  run_drift "$dir" repair >/dev/null
  assert_absent "$dir/home/state/.worktree-drift-failed-gone" "a failed episode outlives no task record, so a reused id starts clean"
  assert_equals "$before" "$(primary_snapshot "$dir")" "the primary checkout must never be written"
  pass "repair: a refused relaunch is reported once and closes when the worker is back in its worktree"
}

# --- 5. wake queue and single flight --------------------------------------------

test_wake_publishes_the_outcome_durably() {
  local dir out
  dir=$(new_case wake)
  out=$(run_drift "$dir" repair --wake)
  assert_contains "$out" "WORKTREE_DRIFT: task t1's worker was running" "the outcome still prints"
  assert_grep $'\tcheck\tworktree-drift-t1\tWORKTREE_DRIFT: task t1' "$dir/home/state/.wake-queue" \
    "the outcome is a durable check wake"
  pass "repair --wake: the outcome is published to the durable wake queue"
}

test_a_second_concurrent_repair_stands_down() {
  local dir out
  dir=$(new_case single)
  mkdir "$dir/home/state/.worktree-drift.lock"
  printf '%s\n' "$$" > "$dir/home/state/.worktree-drift.lock/pid"
  out=$(run_drift "$dir" repair)
  assert_equals "WORKTREE_DRIFT: repair already under way" "$out" "a held lock stands the second repair down"
  assert_equals "" "$(cat "$dir/fake/literal")" "the second repair sends nothing"
  pass "repair: a second concurrent repair stands down without touching the worker"
}

# --- 6. callers ------------------------------------------------------------------

test_the_watcher_relaunches_a_drifted_worker_and_wakes() {
  local dir out pid i=0 before
  dir=$(new_case watcher)
  before=$(primary_snapshot "$dir")
  out="$dir/watch.out"
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_WORKTREE_DRIFT_CONFIRM_SECS=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do
    /bin/sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_grep "check: worktree-drift: WORKTREE_DRIFT: task t1's worker was running in the primary checkout" "$out" \
    "the watcher wakes naming the drift and its outcome"$'\n'"$(cat "$out")"
  assert_equals "$dir/wt" "$(cat "$dir/fake/agent-cwd")" "the watcher's repair runs the replacement in the worktree"
  assert_equals "$before" "$(primary_snapshot "$dir")" "the primary checkout must never be written"
  pass "watcher: a drifted worker is relaunched into its worktree and surfaced as a check wake"
}

test_scan_reports_a_live_worker_in_the_primary_checkout
test_scan_ignores_a_worker_in_or_beneath_its_worktree
test_scan_names_an_unrelated_directory_as_outside
test_scan_ignores_a_directory_that_changes_before_the_confirming_read
test_scan_ignores_a_dead_agent_and_a_secondmate
test_repair_relaunches_into_the_worktree_and_never_writes_the_primary
test_repair_does_nothing_when_no_worker_drifted
test_repair_reregisters_a_pr_poll_that_stopped_authenticating
test_repair_leaves_an_authenticated_pr_poll_alone
test_a_refused_relaunch_is_reported_once_and_not_retried
test_wake_publishes_the_outcome_durably
test_a_second_concurrent_repair_stands_down
test_the_watcher_relaunches_a_drifted_worker_and_wakes
