#!/usr/bin/env bash
# The spawn start check: bin/fm-spawn.sh arms STATE/<id>.start-pending, and
# bin/fm-watch.sh's start_check_tick turns a launch with no start proof into one
# named `check: start` wake at FM_START_CHECK_SECS, while the stale path stays
# quiet for that pane. Real fm-spawn, real busy records, a real private tmux
# server and real panes; no harness process and no model call.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-start-check)

command -v tmux >/dev/null 2>&1 || {
  printf '1..0 # SKIP tmux is not installed\n'
  exit 0
}

LAB_HOME="$TMP_ROOT/lab"
mkdir -p "$LAB_HOME"
"$ROOT/bin/fm-lab-home.sh" create "$LAB_HOME" >/dev/null || fail "lab home create failed"
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB_HOME") || fail "lab tmux dir failed"
export TMUX_TMPDIR="$LAB_TMUX_DIR"
SESSION=fm-start-check
# fm-spawn stages each task's temp root at the fixed /tmp/fm-<id>, outside the
# registered temp root, so the spawn case uses a per-run id and removes it here.
SPAWN_ID="startcheck$$"
start_check_cleanup() {
  chmod -R u+w /tmp/fm-"$SPAWN_ID" /tmp/fm-"$SPAWN_ID"+* 2>/dev/null || true
  rm -rf /tmp/fm-"$SPAWN_ID" /tmp/fm-"$SPAWN_ID"+*
  tmux kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB_HOME" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap start_check_cleanup EXIT

export FM_HOME="$LAB_HOME" FM_STATE_OVERRIDE="$LAB_HOME/state" FM_CONFIG_OVERRIDE="$LAB_HOME/config"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

PI_DIALOG='Trust project folder?
This folder contains project-local extensions.
> Trust
  Do not trust (this session only)'
CLAUDE_DIALOG='Quick safety check: Is this a project you created or one you trust?
> 1. Yes, I trust this folder
  2. No, exit
Enter to confirm · Esc to cancel'

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

reset_state() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf -- "${STATE:?}"/* "$STATE"/.[!.]*
  START_CHECK_WAKE=
}

# A real pane that prints <text> and then sits in a non-shell, non-agent
# process, the way a launch parked on a dialog looks to the endpoint probes.
open_pane() {  # <window> <text>
  local f="$TMP_ROOT/pane-$1.txt"
  printf '%s\n' "$2" > "$f"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-window -d -t "$SESSION" -n "$1" "cat '$f'; exec sleep 600" || fail "tmux window $1"
  else
    tmux new-session -d -s "$SESSION" -n "$1" "cat '$f'; exec sleep 600" || fail "tmux session"
  fi
  sleep 0.3
}

# <id> recorded on window <id> with <harness>; an armed busy seed for the
# harnesses fm-spawn arms, and a start-pending record spawned at <epoch>.
arm_task() {  # <id> <harness> <epoch>
  local id=$1 harness=$2 epoch=$3 gen=-
  case "$harness" in
    pi | claude) gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id") || fail "busy arm $id" ;;
  esac
  {
    printf 'window=%s:%s\n' "$SESSION" "$id"
    printf 'harness=%s\nkind=ship\nbackend=tmux\n' "$harness"
    [ "$gen" = - ] || printf 'busy_gen=%s\n' "$gen"
  } > "$STATE/$id.meta"
  printf '%s %s %s\n' "$epoch" "$gen" "$harness" > "$STATE/$id.start-pending"
  ARMED_GEN=$gen
}

test_spawn_arms_marker() {
  local case_dir home proj wt fakebin out harness gen line
  for harness in pi codex; do
    case_dir="$TMP_ROOT/spawn-$harness"
    home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
    fakebin=$(make_spawn_fakebin "$case_dir/fake" pi codex)
    fm_test_spawn_home "$home" "$harness"
    fm_git_worktree "$proj" "$wt" "wt-$harness"
    fm_test_spawn_brief "$home" "$SPAWN_ID"
    out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$SPAWN_ID" "$proj" --mode no-mistakes --yolo off 2>&1) \
      || fail "$harness spawn failed: $out"
    [ -f "$home/state/$SPAWN_ID.start-pending" ] || fail "$harness spawn did not arm the start check"
    line=$(cat "$home/state/$SPAWN_ID.start-pending")
    gen=$(fm_meta_get "$home/state/$SPAWN_ID.meta" busy_gen)
    case "$line" in
      [0-9]*" ${gen:--} $harness") ;;
      *) fail "$harness start record is not '<epoch> ${gen:--} $harness': $line" ;;
    esac
    [ "$harness" != pi ] || [ -n "$gen" ] || fail "pi spawn recorded no busy generation"
  done
  pass "spawn arms a start record carrying the launch's busy generation (pi) or none (codex)"
}

test_proof_before_deadline_is_silent() {
  reset_state
  open_pane p1 "$PI_DIALOG"
  arm_task p1 pi 1000
  "$ROOT/bin/fm-busy-event.sh" apply "$STATE" p1 busy --gen "$ARMED_GEN" --source pi-ext --event agent-start >/dev/null \
    || fail "pi-ext busy apply"
  start_check_tick 1010 || fail "tick failed"
  [ ! -e "$STATE/p1.start-pending" ] || fail "a pi-ext record did not count as a start proof"
  start_check_tick 2000 || fail "tick failed"
  [ "$(count_wakes)" = 0 ] || fail "a started worker produced a start wake"
  pass "a hook-written record before the deadline removes the record silently"
}

test_pi_dialog_named_once() {
  local reason
  reset_state
  open_pane p2 "$PI_DIALOG"
  arm_task p2 pi 1000
  start_check_tick 1119 || fail "tick failed"
  [ "$(count_wakes)" = 0 ] || fail "start wake fired before the deadline"
  [ -e "$STATE/p2.start-pending" ] || fail "the record was dropped before the deadline"
  start_check_tick 1120 || fail "tick failed"
  [ "$(count_wakes)" = 1 ] || fail "deadline did not queue exactly one wake"
  reason=$START_CHECK_WAKE
  case "$reason" in
    "check: start p2: no start signal 120s after spawn (harness=pi; on screen: Pi project-trust dialog \"Trust project folder?\"); accept: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-send.sh p2 --key Enter") ;;
    *) fail "unexpected pi start reason: $reason" ;;
  esac
  case "$reason" in *aptain*) fail "the start wake implies a captain approval: $reason" ;; esac
  [ ! -e "$STATE/p2.start-pending" ] || fail "the record survived its wake"
  [ -s "$STATE/.stale-$(window_key "$SESSION:p2")" ] || fail "the named screen was not marked for the stale path"
  start_check_tick 1300 || fail "tick failed"
  [ "$(count_wakes)" = 1 ] || fail "a second start wake fired"
  pass "a parked Pi trust dialog wakes once at the deadline with its name and the Enter command"
}

test_claude_dialog_has_no_key() {
  reset_state
  open_pane c1 "$CLAUDE_DIALOG"
  arm_task c1 claude 1000
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"harness=claude; on screen: Claude workspace-trust dialog); no key accepts it: answer it in endpoint $SESSION:c1"*) ;;
    *) fail "unexpected claude start reason: $START_CHECK_WAKE" ;;
  esac
  case "$START_CHECK_WAKE" in *--key*) fail "a decline-preselected dialog was given a key route" ;; esac
  pass "a Claude dialog is named without a key route"
}

test_dead_agent_names_relaunch() {
  reset_state
  open_pane keep "idle"
  arm_task d1 pi 1000
  [ "$(fm_backend_agent_alive tmux "$SESSION:d1")" = dead ] || fail "fixture: missing window is not dead"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"harness=pi; worker exited before starting); relaunch: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-control.sh d1 relaunch --note '"*"'") ;;
    *) fail "unexpected dead-agent reason: $START_CHECK_WAKE" ;;
  esac
  # A secondmate relaunch takes no note.
  reset_state
  open_pane keep "idle"
  arm_task d2 pi 1000
  printf 'kind=secondmate\n' >> "$STATE/d2.meta"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"worker exited before starting); relaunch: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-control.sh d2 relaunch") ;;
    *) fail "unexpected secondmate dead-agent reason: $START_CHECK_WAKE" ;;
  esac
  pass "an exited worker is named with a relaunch command that relaunch accepts for its kind"
}

test_pending_composer_names_submit() {
  local reason
  reset_state
  open_pane q1 "some unsubmitted brief"
  arm_task q1 pi 1000
  # The composer classifier has its own suites; this case pins only the
  # wording, so the stub lives in a subshell and never leaks into later cases.
  reason=$(
    fm_backend_composer_state() { printf pending; }
    start_check_tick 1200 >/dev/null || exit 1
    printf '%s' "$START_CHECK_WAKE"
  ) || fail "tick failed"
  case "$reason" in
    *"instructions typed but not submitted); submit: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-send.sh q1 --key Enter") ;;
    *) fail "unexpected pending reason: $reason" ;;
  esac
  pass "a brief left in the composer is named with the submit command"
}

test_no_signal_names_inspect() {
  local verdict
  reset_state
  open_pane g1 "grok screen with no footer"
  arm_task g1 grok 1000
  # The divergence that makes this case meaningful: the rendered-text fallback
  # reads this pane idle, and idle from it must not count as a start.
  verdict=$(fm_busy_classify_meta "$STATE/g1.meta" g1 "$STATE")
  [ "$verdict" = "idle grok-regex" ] || fail "fixture: expected idle grok-regex, got $verdict"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    "check: start g1: no start signal 200s after spawn (harness=grok); inspect: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-crew-state.sh g1") ;;
    *) fail "unexpected no-signal reason: $START_CHECK_WAKE" ;;
  esac
  pass "no signal at all still wakes, and rendered-text idle is not a start proof"
}

test_codex_footer_and_status_are_proof() {
  reset_state
  open_pane x1 "Working (3s • esc to interrupt)"
  arm_task x1 codex 1000
  open_pane x2 "codex composer"
  arm_task x2 codex 1000
  printf 'working [at=1]: started\n' > "$STATE/x2.status"
  touch -t 203001010000 "$STATE/x2.status"
  start_check_tick 1200 || fail "tick failed"
  [ "$(count_wakes)" = 0 ] || fail "a started codex worker produced a start wake: $START_CHECK_WAKE"
  [ ! -e "$STATE/x1.start-pending" ] || fail "the codex busy footer did not count as a start proof"
  [ ! -e "$STATE/x2.start-pending" ] || fail "a status line written after spawn did not count as a start proof"
  pass "a codex busy footer and a status line written after spawn each prove the start"
}

test_stale_records_are_dropped() {
  reset_state
  open_pane m1 "$PI_DIALOG"
  arm_task m1 pi 1000
  printf '1000 g-old.1.1 pi\n' > "$STATE/m1.start-pending"
  printf '1000 - pi\n' > "$STATE/m2.start-pending"
  printf 'garbage\n' > "$STATE/m3.start-pending"
  start_check_tick 5000 || fail "tick failed"
  [ "$(count_wakes)" = 0 ] || fail "a superseded record woke: $START_CHECK_WAKE"
  [ ! -e "$STATE/m1.start-pending" ] || fail "a generation-mismatched record survived"
  [ ! -e "$STATE/m2.start-pending" ] || fail "a record without a task survived"
  [ ! -e "$STATE/m3.start-pending" ] || fail "a malformed record survived"
  pass "records of a superseded launch, a removed task, or malformed content are dropped silently"
}

test_secondmate_launch_is_checked() {
  reset_state
  open_pane s1 "$PI_DIALOG"
  arm_task s1 pi 1000
  printf 'kind=secondmate\n' >> "$STATE/s1.meta"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    "check: start s1: no start signal 200s after spawn (harness=pi; on screen: Pi project-trust dialog"*) ;;
    *) fail "a parked secondmate launch did not wake: $START_CHECK_WAKE" ;;
  esac
  pass "a secondmate launch, exempt from the stale path, still gets its start check"
}

test_one_wake_per_poll() {
  reset_state
  open_pane a1 "$PI_DIALOG"
  open_pane a2 "$PI_DIALOG"
  arm_task a1 pi 1000
  arm_task a2 pi 1000
  start_check_tick 1200 || fail "tick failed"
  [ "$(count_wakes)" = 1 ] || fail "one poll queued more than one start wake"
  start_check_tick 1200 || fail "tick failed"
  [ "$(count_wakes)" = 2 ] || fail "the second due launch did not wake on the next poll"
  pass "two due launches wake on consecutive polls, one each"
}

# The real watcher loop: the parked pane is stale from the second poll, yet the
# only wake is the named start wake at the deadline.
test_watcher_loop_single_named_wake() {
  local out="$TMP_ROOT/watch.out" pid i=0 rows
  reset_state
  open_pane w1 "$PI_DIALOG"
  arm_task w1 pi "$(date +%s)"
  FM_POLL=1 FM_START_CHECK_SECS=10 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q '^check: start w1: no start signal [0-9]*s after spawn (harness=pi; on screen: Pi project-trust dialog' "$out" \
    || fail "the watcher did not exit on the named start wake: $(cat "$out")"
  rows=$(count_wakes)
  [ "$rows" = 1 ] || fail "expected exactly one queued wake, got $rows: $(cat "$FM_WAKE_QUEUE")"
  grep -q 'absorbed stale (start check pending)' "$TRIAGE_LOG" \
    || fail "the stale path did not absorb the parked pane before the deadline"
  pass "the real watcher loop absorbs the parked pane and wakes once, named, at the deadline"
}

fm_test_run \
  test_spawn_arms_marker \
  test_proof_before_deadline_is_silent \
  test_pi_dialog_named_once \
  test_claude_dialog_has_no_key \
  test_dead_agent_names_relaunch \
  test_pending_composer_names_submit \
  test_no_signal_names_inspect \
  test_codex_footer_and_status_are_proof \
  test_stale_records_are_dropped \
  test_secondmate_launch_is_checked \
  test_one_wake_per_poll \
  test_watcher_loop_single_named_wake
