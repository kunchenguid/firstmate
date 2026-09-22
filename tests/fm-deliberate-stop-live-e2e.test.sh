#!/usr/bin/env bash
# tests/fm-deliberate-stop-live-e2e.test.sh - LIVE coverage for the durable
# deliberate-stop marker (firstmate issue #5004) against a REAL tmux server on a
# private socket. The hermetic suites (fm-control.test.sh, fm-watch-triage.test.sh,
# fm-daemon.test.sh, fm-teardown.test.sh, fm-control-relaunch.test.sh) pin the
# same contracts with a stubbed endpoint; this guard is the one place the marker's
# end-to-end behavior is driven against the real product + real tmux.
#
# Its reason to exist is the validation gap issue #5004 surfaced: a marker that
# only a stub can't see, or a watcher that parks a marker but still escalates the
# real pane, would pass every hermetic test. The scenarios below stand the real
# control plane, watcher, and endpoint up and assert on the marker file and the
# watcher's actual output.
#
# Real tmux only; no model tokens are spent, so the guard is default-on wherever
# tmux exists and self-skips otherwise (fm_live_gate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on tmux

CONTROL="$ROOT/bin/fm-control.sh"
WATCH="$ROOT/bin/fm-watch.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-deliberate-stop-live-$$"
SESSION="live"
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-deliberate-stop-live.XXXXXX")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-deliberate-stop-state.XXXXXX")

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$SHIM_DIR" "$TMP"
}
trap cleanup EXIT

# Transparent `tmux` shim: every bare `tmux ...` the product runs targets the
# private socket, never the host's real sessions.
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "could not start the private tmux server"

# A finished-style idle pane: the worker printed a terminal status line and then
# sat quietly at a shell. This is exactly the home the report described.
new_pane() {  # <window-name> [command]
  local w=$1 cmd=${2:-"bash -c 'printf \"done: investigation finished\\n\$ \"; exec bash'"}
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$w" "$cmd" \
    || fail "could not create pane $w"
}

# ---------------------------------------------------------------------------
# Scenario A/B: the real control plane records the durable marker on a verified
# stop and refuses to record one on an unprovable endpoint.
# ---------------------------------------------------------------------------
write_meta() {  # <home> <id> <window>
  local home=$1 id=$2 window=$3
  mkdir -p "$home/state" "$home/data/$id"
  printf '# brief\n' > "$home/data/$id/brief.md"
  {
    echo "window=$window"
    echo "endpoint_task_id=$id"
    echo "worktree=$TMP"
    echo "project=$TMP"
    echo "harness=claude"
    echo "kind=ship"
  } > "$home/state/$id.meta"
}

test_control_exit_records_marker_on_a_verified_stop_and_refuses_without_one() {
  local home out rc
  new_pane fm-task1

  home="$TMP/home-stop"
  write_meta "$home" task1 "$SESSION:fm-task1"
  out=$(FM_HOME="$home" FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.2 \
    FM_CONTROL_EXIT_WAIT=0.2 "$CONTROL" task1 exit 2>&1); rc=$?
  expect_code 0 "$rc" "the verified stop should succeed"$'\n'"$out"
  [ -f "$home/state/task1.deliberate-stop" ] \
    || fail "a verified stop did not record the durable deliberate-stop marker"
  [ -n "$(cat "$home/state/task1.deliberate-stop")" ] \
    || fail "the deliberate-stop marker is empty"

  # An absent tmux endpoint is unprovable and must be refused: no marker.
  home="$TMP/home-refuse"
  new_pane fm-task2
  write_meta "$home" task2 "$SESSION:fm-task2"
  # Remove the window so the endpoint is genuinely absent/unprovable.
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:fm-task2" >/dev/null 2>&1 || true
  out=$(FM_HOME="$home" FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.2 \
    FM_CONTROL_EXIT_WAIT=0.2 "$CONTROL" task2 exit 2>&1); rc=$?
  expect_code 1 "$rc" "an unprovable endpoint must refuse"$'\n'"$out"
  [ ! -e "$home/state/task2.deliberate-stop" ] \
    || fail "a refused stop recorded a deliberate-stop marker"
  pass "live: a verified tmux stop records the deliberate-stop marker; an unprovable endpoint records none"
}

# ---------------------------------------------------------------------------
# Scenario C-F: the real watcher parks a deliberately stopped finished pane on
# the bounded recheck cadence, never the wedge ladder - idle, busy, and churning.
# ---------------------------------------------------------------------------
watch_state() {  # <name> <window> <status-line>
  local name=$1 w=$2 st=$3 state="$TMP/state-$1"
  mkdir -p "$state"
  printf 'window=%s\nkind=ship\nbackend=tmux\nharness=pi\n' "$w" > "$state/$name.meta"
  printf '%s\n' "$st" > "$state/$name.status"
  # Declare the pre-existing status already seen through the production
  # signature owner, so the per-poll signal scan does not fire on it.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT" "$state" "$state/$name.status"
  printf '%s\n' "$state"
}

run_watch() {  # <state> <cadence> <out> <err>
  FM_STATE_OVERRIDE="$1" FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WEDGE_ALARM_EXEC=discard FM_PAUSE_RESURFACE_SECS="$2" \
    exec "$WATCH" > "$3" 2> "$4"
}

# Run the watcher for a bounded number of cycles, then stop it and report
# whether it was still alive (an absorb keeps it blocking).
watch_absorb() {  # <state> <cadence> <out> <err> <seconds>
  local pid i
  run_watch "$1" "$2" "$3" "$4" &
  pid=$!
  local alive=1
  i=0
  while [ "$i" -lt $(( ${5} * 10 )) ]; do
    kill -0 "$pid" 2>/dev/null || { alive=0; break; }
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$alive" -eq 1 ]
}

# Wait for the watcher to exit on a wake, bounded.
watch_until_exit() {  # <state> <cadence> <out> <err> <ticks>
  local pid i
  run_watch "$1" "$2" "$3" "$4" &
  pid=$!
  i=0
  while [ "$i" -lt "$5" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

KEY_STOP="live_fm-live-stop"
KEY_BUSY="live_fm-live-busy"
KEY_CHURN="live_fm-live-churn"

test_watcher_parks_a_deliberately_stopped_idle_pane() {
  local state out err
  new_pane fm-live-stop
  state=$(watch_state live-stop "$SESSION:fm-live-stop" "done: investigation finished")
  printf '%s\n' "$(date +%s)" > "$state/live-stop.deliberate-stop"

  # Fresh stop: absorbed, no wake, no wedge timer.
  out="$TMP/a.out"; err="$TMP/a.err"
  watch_absorb "$state" 999 "$out" "$err" 6 \
    || fail "the watcher exited for a freshly parked finished task (should absorb): $(cat "$out")"
  [ ! -s "$out" ] || fail "a freshly parked finished task printed a wake during absorb"
  [ ! -e "$state/.stale-since-$KEY_STOP" ] || fail "a fresh deliberate-stop absorb started the wedge timer"

  # Past the cadence: re-surfaces once as a bounded recheck, never a wedge.
  rm -f "$state/.deliberate-stop-resurfaced-$KEY_STOP" "$state/.stale-$KEY_STOP" \
    "$state/.stale-since-$KEY_STOP" "$state/.watcher-down" "$state/.wake-queue" \
    "$state/.wake-queue.seq" "$state/.watch-deliveries.log"
  touch -d "@$(( $(date +%s) - 500 ))" "$state/live-stop.deliberate-stop"
  out="$TMP/b.out"; err="$TMP/b.err"
  watch_until_exit "$state" 240 "$out" "$err" 200 \
    || fail "the watcher did not re-surface a parked task past the cadence"
  grep -F "deliberately stopped" "$out" >/dev/null \
    || fail "the re-surface was not labeled a deliberate-stop recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a deliberately parked task was mislabeled a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$KEY_STOP" ] || fail "a deliberate-stop recheck used the wedge timer"
  pass "live: the watcher absorbs a fresh deliberate stop and re-surfaces it on the bounded cadence"
}

test_watcher_parks_a_deliberately_stopped_busy_pane() {
  local state out err gen
  new_pane fm-live-busy "bash -c 'printf \"Working... (7200.4s)\\n\"; exec bash'"
  state=$(watch_state live-busy "$SESSION:fm-live-busy" "done: investigation finished")
  # No completed turn: age the spawn record past the busy-turn bound, and record
  # a real busy incarnation so the semantic verdict is busy.
  touch -t 200001010000 "$state/live-busy.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" live-busy)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" live-busy busy --gen "$gen" \
    --source pi-ext --event agent-start
  printf '%s\n' "$(date +%s)" > "$state/live-busy.deliberate-stop"

  out="$TMP/c.out"; err="$TMP/c.err"
  watch_absorb "$state" 999 "$out" "$err" 8 \
    || fail "a deliberately stopped busy pane was escalated: $(cat "$out")"
  [ ! -s "$out" ] || fail "a deliberately stopped busy pane printed a wake: $(cat "$out")"
  [ ! -e "$state/.stale-since-$KEY_BUSY" ] || fail "a deliberately stopped busy pane started the wedge timer"
  [ ! -e "$state/.wedge-escalations-$KEY_BUSY" ] || fail "a deliberately stopped busy pane incremented the escalation counter"

  # Past the cadence the parked busy pane still re-surfaces on the pause cadence.
  rm -f "$state/.deliberate-stop-resurfaced-$KEY_BUSY" "$state/.stale-$KEY_BUSY" \
    "$state/.stale-since-$KEY_BUSY" "$state/.watcher-down" "$state/.wake-queue" \
    "$state/.wake-queue.seq" "$state/.watch-deliveries.log"
  touch -d "@$(( $(date +%s) - 500 ))" "$state/live-busy.deliberate-stop"
  out="$TMP/d.out"; err="$TMP/d.err"
  watch_until_exit "$state" 240 "$out" "$err" 200 \
    || fail "a deliberately stopped busy pane did not re-surface past the cadence"
  grep -F "deliberately stopped" "$out" >/dev/null \
    || fail "the busy recheck was not labeled a deliberate-stop recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a deliberately stopped busy pane was mislabeled a possible wedge: $(cat "$out")"
  pass "live: the watcher parks a deliberately stopped busy pane on the bounded recheck cadence"
}

test_watcher_rechecks_a_deliberately_stopped_churning_pane() {
  local state out err
  cat > "$TMP/churn.sh" <<'CHURN'
#!/usr/bin/env bash
i=0
while :; do
  i=$((i + 1))
  printf 'finished, footer tick %s\n' "$i"
  sleep 0.1
done
CHURN
  chmod +x "$TMP/churn.sh"
  new_pane fm-live-churn "bash -c 'exec \"$TMP/churn.sh\"'"
  state=$(watch_state live-churn "$SESSION:fm-live-churn" "done: investigation finished")
  printf '%s\n' "$(date +%s)" > "$state/live-churn.deliberate-stop"
  touch -d "@$(( $(date +%s) - 500 ))" "$state/live-churn.deliberate-stop"

  out="$TMP/e.out"; err="$TMP/e.err"
  watch_until_exit "$state" 240 "$out" "$err" 200 \
    || fail "a churning deliberately parked task was never rechecked: $(cat "$out")"
  grep -F "deliberately stopped" "$out" >/dev/null \
    || fail "the churning recheck was not labeled a deliberate-stop recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a churning deliberately parked task was mislabeled a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$KEY_CHURN" ] || fail "a churning deliberate-stop recheck used the wedge timer"
  pass "live: a churning deliberately parked pane still gets the bounded deliberate-stop recheck"
}

test_watcher_still_surfaces_a_markerless_finished_pane() {
  local state out err
  new_pane fm-live-nomarker
  state=$(watch_state live-nomarker "$SESSION:fm-live-nomarker" "done: investigation finished")
  # No deliberate-stop marker: the same finished idle pane must still take the
  # ordinary terminal-stale path, so the marker is what parks it.
  out="$TMP/f.out"; err="$TMP/f.err"
  watch_until_exit "$state" 240 "$out" "$err" 200 \
    || fail "the watcher did not surface a marker-less finished task as terminal stale"
  grep -Fx "stale: $SESSION:fm-live-nomarker" "$out" >/dev/null \
    || fail "a marker-less finished task did not surface as an ordinary terminal stale: $(cat "$out")"
  pass "live: removing the marker returns the finished task to ordinary terminal-stale supervision"
}

# ---------------------------------------------------------------------------
# Scenario G: teardown retires the marker for a real task, so no stale marker
# survives the task it parked.
# ---------------------------------------------------------------------------
test_teardown_clears_the_deliberate_stop_marker() {
  local c fb out rc
  new_pane fm-task-x1
  c="$TMP/td-case"; fb="$c/fakebin"
  mkdir -p "$c/state" "$c/config" "$c/data/task-x1" "$fb"
  # Stub only the external providers (worktree pool + forge); tmux and git are real.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf 'count: 0 (showing first 0)\npull_requests[]: []\n'; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1 ;; esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) shift; [ "${1:-}" = status ] && printf ''; exit 0 ;;
  runs) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb"/*

  git init -q --bare "$c/origin.git"
  git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/_seed" 2>/dev/null
  git -C "$c/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$c/_seed" push -q origin main
  rm -rf "$c/_seed"
  git clone -q "$c/origin.git" "$c/project"
  git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
  touch "$c/state/.last-watcher-beat"
  cat > "$c/state/task-x1.meta" <<META
window=$SESSION:fm-task-x1
endpoint_task_id=task-x1
worktree=$c/wt
project=$c/project
kind=ship
mode=local-only
spawn_gen=td-live
META
  printf '%s\n' "$(date +%s)" > "$c/state/task-x1.deliberate-stop"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$c/state" \
    FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" \
    PATH="$SHIM_DIR:$fb:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 --force 2>&1); rc=$?
  expect_code 0 "$rc" "the forced teardown should complete"$'\n'"$out"
  [ ! -e "$c/state/task-x1.deliberate-stop" ] \
    || fail "teardown left the deliberate-stop marker behind"
  [ ! -e "$c/state/task-x1.meta" ] || fail "teardown left the task record behind"
  pass "live: teardown retires the deliberate-stop marker for a real task"
}

# ---------------------------------------------------------------------------
# Scenario H: a real relaunch replaces the stopped worker and clears the marker;
# a relaunch whose replacement cannot be launched retains the parked stop, so a
# still-stopped task is never misclassified as a running replacement.
# ---------------------------------------------------------------------------
relaunch_case() {  # <id> <brief-body> -> echoes <home> <worktree> on two lines
  local id=$1 body=$2 c
  c="$TMP/rl-$id"
  mkdir -p "$c/home/state" "$c/home/data/$id" "$c/user-home"
  git init -q "$c/proj"
  git -C "$c/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$c/proj" worktree add -q -b "task-$id" "$c/wt"
  printf '%s' "$body" > "$c/home/data/$id/brief.md"
  {
    echo "window=$SESSION:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$c/wt"
    echo "project=$c/proj"
    echo "harness=pi"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$c/home/state/$id.meta"
  printf '%s\n' "$(date +%s)" > "$c/home/state/$id.deliberate-stop"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -c "$c/wt" -n "fm-$id" \
    "bash -c 'exec bash'" || fail "could not create relaunch pane fm-$id"
  printf '%s\n%s\n' "$c/home" "$c/wt"
}

test_relaunch_clears_on_success_and_retains_on_abort() {
  command -v pi >/dev/null 2>&1 || return 0
  local home out rc

  # Success: the replacement launches in the same worktree and the marker clears.
  home=$(relaunch_case rl1 $'# Task\n## Captain\'s intent\nExercise relaunch live and confirm the replacement is supervised normally.\n\n## Firstmate spec\nReplace the stopped agent in the same endpoint and worktree.\n' | sed -n 1p)
  out=$(env -u HERDR_ENV FM_SPAWN_NO_GUARD=1 HOME="$TMP/rl-rl1/user-home" \
    FM_HOME="$home" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=3 \
    timeout 90 "$CONTROL" rl1 relaunch --note "resume live test" 2>&1); rc=$?
  expect_code 0 "$rc" "the live relaunch should succeed"$'\n'"$out"
  [ ! -e "$home/state/rl1.deliberate-stop" ] \
    || fail "a delivered relaunch did not clear the deliberate-stop marker"

  # Abort: a brief the launch owner refuses stops the worker but delivers no
  # replacement, so the parked stop must survive.
  home=$(relaunch_case rl2 $'# Task\n## Captain\'s intent\nNo Firstmate spec subsection here.\n' | sed -n 1p)
  out=$(env -u HERDR_ENV FM_SPAWN_NO_GUARD=1 HOME="$TMP/rl-rl2/user-home" \
    FM_HOME="$home" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=3 \
    timeout 90 "$CONTROL" rl2 relaunch --note "resume live test" 2>&1); rc=$?
  expect_code 1 "$rc" "a refused replacement launch should fail the relaunch"$'\n'"$out"
  [ -e "$home/state/rl2.deliberate-stop" ] \
    || fail "an aborted relaunch cleared the parked deliberate-stop marker"
  pass "live: a real relaunch clears the marker and an aborted relaunch retains the parked stop"
}

test_control_exit_records_marker_on_a_verified_stop_and_refuses_without_one
test_watcher_parks_a_deliberately_stopped_idle_pane
test_watcher_parks_a_deliberately_stopped_busy_pane
test_watcher_rechecks_a_deliberately_stopped_churning_pane
test_watcher_still_surfaces_a_markerless_finished_pane
test_teardown_clears_the_deliberate_stop_marker
test_relaunch_clears_on_success_and_retains_on_abort
