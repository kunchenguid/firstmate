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

# A pane that printed <text> and then left a bare shell in the foreground, the
# way an agent that died mid-launch leaves its endpoint.
open_shell_pane() {  # <window> <text>
  local f="$TMP_ROOT/pane-$1.txt"
  printf '%s\n' "$2" > "$f"
  tmux new-window -d -t "$SESSION" -n "$1" "cat '$f'; exec sh" 2>/dev/null \
    || tmux new-session -d -s "$SESSION" -n "$1" "cat '$f'; exec sh" || fail "tmux shell window $1"
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

test_same_second_turn_end_is_proof() {
  reset_state
  open_pane t1 "$PI_DIALOG"
  arm_task t1 pi 1000
  touch "$STATE/t1.turn-ended"
  epoch=$(stat -f %m "$STATE/t1.turn-ended" 2>/dev/null || stat -c %Y "$STATE/t1.turn-ended")
  printf '%s %s pi\n' "$epoch" "$ARMED_GEN" > "$STATE/t1.start-pending"
  start_check_tick 1120 || fail "tick failed"
  [ "$(count_wakes)" = 0 ] || fail "turn-ended in the launch second was not accepted as proof"
  pass "turn-ended proof at the launch epoch is accepted"
}

test_launch_epoch_excludes_existing_markers() {
  local marker epoch boundary
  for marker in status turn-ended; do
    reset_state
    open_pane "e-$marker" "$PI_DIALOG"
    arm_task "e-$marker" pi 1000
    touch "$STATE/e-$marker.$marker"
    epoch=$(stat -f %m "$STATE/e-$marker.$marker" 2>/dev/null || stat -c %Y "$STATE/e-$marker.$marker")
    boundary=$(fm_start_check_launch_epoch "$STATE" "e-$marker")
    [ "$boundary" -gt "$epoch" ] || fail "$marker did not advance the launch boundary"
    printf '%s %s pi\n' "$boundary" "$ARMED_GEN" > "$STATE/e-$marker.start-pending"
    start_check_tick "$boundary"
    [ -e "$STATE/e-$marker.start-pending" ] || fail "pre-launch $marker suppressed the start wake"
    touch -t "$(date -r "$boundary" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$boundary" '+%Y%m%d%H%M.%S')" "$STATE/e-$marker.$marker"
    start_check_tick "$boundary"
    [ ! -e "$STATE/e-$marker.start-pending" ] || fail "post-boundary $marker was not accepted as proof"
  done
  pass "existing status and turn-ended markers precede the launch boundary; later proof still counts"
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

test_claude_session_end_is_not_start_proof() {
  reset_state
  open_shell_pane ce1 "claude exited"
  arm_task ce1 claude 1000
  "$ROOT/bin/fm-busy-event.sh" apply "$STATE" ce1 idle --gen "$ARMED_GEN" --source claude-hook --event SessionEnd >/dev/null \
    || fail "Claude SessionEnd apply"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"worker exited before starting"*) ;;
    *) fail "Claude SessionEnd suppressed the exited-worker wake: $START_CHECK_WAKE" ;;
  esac
  pass "Claude SessionEnd alone does not prove a start"
}

test_dead_agent_names_relaunch() {
  reset_state
  # The agent died while its trust dialog was painted, so the pane keeps that
  # text above a bare shell: the endpoint is there, the agent is not (the one
  # state relaunch accepts), and the leftover dialog must not win.
  open_shell_pane d1 "$PI_DIALOG"
  arm_task d1 pi 1000
  [ "$(fm_backend_agent_state tmux "$SESSION:d1")" = dead ] || fail "fixture: a shell-only pane is not dead"
  tmux capture-pane -p -t "$SESSION:d1" -S -40 | fm_busy_launch_prompt_parked pi \
    || fail "fixture: the leftover dialog text is not on screen"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"harness=pi; worker exited before starting); relaunch: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-control.sh d1 relaunch --note '"*"'") ;;
    *) fail "unexpected dead-agent reason: $START_CHECK_WAKE" ;;
  esac
  # A secondmate relaunch takes no note.
  reset_state
  open_shell_pane d2 "pi exited"
  arm_task d2 pi 1000
  printf 'kind=secondmate\n' >> "$STATE/d2.meta"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"worker exited before starting); relaunch: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-control.sh d2 relaunch") ;;
    *) fail "unexpected secondmate dead-agent reason: $START_CHECK_WAKE" ;;
  esac
  pass "an exited worker is named with a relaunch command that relaunch accepts for its kind"
}

test_missing_endpoint_names_recovery() {
  reset_state
  open_pane keep "idle"
  arm_task g2 pi 1000
  [ "$(fm_backend_agent_state tmux "$SESSION:g2")" = missing ] || fail "fixture: an absent window is not missing"
  start_check_tick 1200 || fail "tick failed"
  case "$START_CHECK_WAKE" in
    *"worker endpoint gone before starting); recover it per stuck-crewmate-recovery after: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-crew-state.sh g2") ;;
    *) fail "unexpected missing-endpoint reason: $START_CHECK_WAKE" ;;
  esac
  case "$START_CHECK_WAKE" in *relaunch*) fail "a vanished endpoint was offered a relaunch relaunch refuses" ;; esac
  pass "a vanished endpoint points at recovery, not at a relaunch that would refuse"
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

test_codex_dialog_overrides_footer_proof() {
  reset_state
  open_pane x3 $'Do you trust the contents of this directory?\nWorking (3s • esc to interrupt)'
  arm_task x3 codex 1000
  start_check_tick 1120 || fail "tick failed"
  [ "$(count_wakes)" = 1 ] || fail "a codex trust dialog with a busy footer did not wake: $START_CHECK_WAKE"
  [ ! -e "$STATE/x3.start-pending" ] || fail "the codex dialog start record survived its wake"
  pass "a codex trust dialog overrides footer proof, while ordinary footer proof remains valid"
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

test_held_lock_defers_without_waiting() {
  local lock start elapsed
  reset_state
  open_pane h1 "$PI_DIALOG"
  arm_task h1 pi 1000
  lock=$(fm_meta_lock_path "$STATE/h1.meta") || fail "lock path"
  # A spawn or relaunch publishing this task's record holds its meta lock.
  ( fm_lock_acquire_wait "$lock"; sleep 20 ) &
  local holder=$!
  for _ in $(seq 1 50); do [ -e "$lock" ] && break; sleep 0.1; done
  start=$(date +%s)
  start_check_tick 5000 || fail "tick failed"
  elapsed=$(( $(date +%s) - start ))
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$elapsed" -lt 5 ] || fail "the tick waited ${elapsed}s on a held task lock"
  [ "$(count_wakes)" = 0 ] || fail "a record under a held lock was judged: $START_CHECK_WAKE"
  [ -e "$STATE/h1.start-pending" ] || fail "a record under a held lock was removed"
  fm_lock_release "$lock" 2>/dev/null || rm -rf -- "$lock"
  start_check_tick 5000 || fail "tick failed"
  [ "$(count_wakes)" = 1 ] || fail "the deferred record did not wake once its lock was free"
  pass "a record whose task lock is held is skipped for that poll without waiting, then judged"
}

# A remote secondmate's proof and cause are read through its route; the stub
# stands in for bin/fm-on.sh plus the host's control verbs, whose own suites
# (fm-remote-secondmate-omp, fm-remote-secondmate-lifecycle-e2e) drive them.
arm_remote() {  # <id> [record-gen]
  printf 'window=remote:%s\nharness=pi\nkind=secondmate\nremote_host=remote-mac\nremote_busy_gen=g900.1.1\n' "$1" > "$STATE/$1.meta"
  printf '1000 %s pi\n' "${2:-g900.1.1}" > "$STATE/$1.start-pending"
}

# `observe <id> --start-proof` output: the observation line, then the host's
# busy-contract verdict and the busy generation of the launch it describes.
remote_proof() {  # <observation> [verdict] [busy-gen]
  printf '%s\nverdict=%s\nbusy_gen=%s\n' "$1" "${2:-busy fm-spawn}" "${3-g900.1.1}"
}

remote_tick() {  # <proof> <state> <capture> <rc>: tick once with a stubbed route
  REMOTE_PROOF=$1 REMOTE_STATE=$2 REMOTE_CAPTURE=$3 REMOTE_RC=$4
  start_check_remote() {
    REMOTE_CALLS=$((${REMOTE_CALLS:-0} + 1))
    WATCHER_CAPTURE=
    [ "$REMOTE_RC" = 0 ] || return "$REMOTE_RC"
    case "$2" in
      observe) [ "${3:-}" = --start-proof ] && WATCHER_CAPTURE=$REMOTE_PROOF ;;
      state) WATCHER_CAPTURE=$REMOTE_STATE ;;
      capture) WATCHER_CAPTURE=$REMOTE_CAPTURE ;;
    esac
  }
  start_check_tick 1200
  local rc=$?
  unset -f start_check_remote
  return "$rc"
}

test_remote_secondmate_reads_route() {
  reset_state
  # Restore the real route helper after each stubbed tick.
  local real
  real=$(declare -f start_check_remote)
  # A busy observation proves; so does the host's own busy record for this
  # launch, which is all a mate that starts and settles silently leaves (the
  # stock secondmate charter writes no status line at start); so does a
  # parent-mirrored status write.
  arm_remote early
  printf '1190 g900.1.1 pi\n' > "$STATE/early.start-pending"
  REMOTE_CALLS=0
  remote_tick "$(remote_proof busy)" alive '' 0 || fail "tick failed"; eval "$real"
  [ "$REMOTE_CALLS" = 0 ] || fail "a remote route was read before its deadline"
  [ -e "$STATE/early.start-pending" ] || fail "a pre-deadline record was removed without local proof"
  arm_remote r1
  remote_tick "$(remote_proof busy)" alive '' 0 || fail "tick failed"; eval "$real"
  [ ! -e "$STATE/r1.start-pending" ] || fail "a busy remote observation did not count as proof"
  arm_remote r8
  remote_tick "$(remote_proof idle 'idle pi-ext')" alive '' 0 || fail "tick failed"; eval "$real"
  [ ! -e "$STATE/r8.start-pending" ] || fail "a silently settled remote mate's busy record did not count as proof"
  arm_remote r5
  printf 'done: started\n' > "$STATE/r5.status"
  remote_tick "$(remote_proof idle)" alive '' 0 || fail "tick failed"; eval "$real"
  [ ! -e "$STATE/r5.start-pending" ] || fail "a parent-side status write did not count as proof"
  # A record from an earlier launch of the route is dropped without a wake.
  arm_remote r6 g800.1.1
  remote_tick "$(remote_proof idle)" alive "$PI_DIALOG" 0 || fail "tick failed"; eval "$real"
  [ ! -e "$STATE/r6.start-pending" ] || fail "a superseded remote record was kept"
  [ "$(count_wakes)" = 0 ] || fail "a started or superseded remote mate woke"
  # A started-looking verdict from another launch proves nothing.
  arm_remote r9
  remote_tick "$(remote_proof idle 'idle pi-ext' g700.1.1)" alive '' 0 || fail "tick failed"; eval "$real"
  [ -n "$START_CHECK_WAKE" ] || fail "another launch's busy record counted as proof"
  # The spawn seed, or only the observation line, proves nothing.
  arm_remote r2
  arm_remote z10
  REMOTE_CALLS=0
  remote_tick "$(remote_proof idle)" alive "$PI_DIALOG" 0 || fail "tick failed"; eval "$real"
  [ "$REMOTE_CALLS" = 3 ] || fail "the tick continued route reads after queuing a wake"
  case "$START_CHECK_WAKE" in
    "check: start r2: no start signal 200s after spawn (harness=pi; on screen on remote-mac: Pi project-trust dialog \"Trust project folder?\"); accept: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-send.sh r2 --key Enter") ;;
    *) fail "unexpected remote dialog reason: $START_CHECK_WAKE" ;;
  esac
  arm_remote r3
  remote_tick '' '' '' 255 || fail "tick failed"; eval "$real"
  case "$START_CHECK_WAKE" in
    "check: start r3: no start signal 200s after spawn (harness=pi; remote host remote-mac); inspect: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-crew-state.sh r3") ;;
    *) fail "an unreachable host did not wake generically: $START_CHECK_WAKE" ;;
  esac
  arm_remote r4
  remote_tick idle missing "$PI_DIALOG" 0 || fail "tick failed"; eval "$real"
  case "$START_CHECK_WAKE" in
    *"remote worker on remote-mac exited or its endpoint is gone before starting); recover it per secondmate-provisioning after: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-crew-state.sh r4") ;;
    *) fail "a vanished remote endpoint was not sent to recovery: $START_CHECK_WAKE" ;;
  esac
  [ "$(count_wakes)" = 4 ] || fail "expected one wake per unstarted remote launch"
  # The real route wrapper bounds observe, state, and capture independently.
  reset_state
  arm_remote r7
  arm_remote r8
  mkdir -p "$TMP_ROOT/hanging-route"
  printf '#!/bin/sh\nsleep 5\n' > "$TMP_ROOT/hanging-route/fm-on.sh"
  chmod +x "$TMP_ROOT/hanging-route/fm-on.sh"
  ln -s "$ROOT/bin/fm-crew-state.sh" "$TMP_ROOT/hanging-route/fm-crew-state.sh"
  local saved_script_dir=$SCRIPT_DIR start elapsed
  SCRIPT_DIR=$TMP_ROOT/hanging-route
  # Three whole seconds, so a clock-second boundary inside the tick cannot spend
  # the budget before the deferred record gets its turn.
  FM_START_CHECK_ROUTE_SECS=3
  START_CHECK_ROUTE_SECS=3
  start=$(date +%s)
  start_check_tick 1200 || fail "tick failed for a timed-out route"
  elapsed=$(($(date +%s) - start))
  SCRIPT_DIR=$saved_script_dir
  [ "$elapsed" -lt 6 ] || fail "timed-out remote route stalled the tick for ${elapsed}s"
  case "$START_CHECK_WAKE" in
    "check: start r7: no start signal 200s after spawn (harness=pi; remote host remote-mac); inspect: FM_HOME=$FM_HOME $TMP_ROOT/hanging-route/fm-crew-state.sh r7") ;;
    *) fail "a timed-out remote route was treated as proof or death: $START_CHECK_WAKE" ;;
  esac
  [ "$(count_wakes)" = 1 ] || fail "timed-out route did not queue exactly one generic wake"
  [ -e "$STATE/r8.start-pending" ] || fail "the later due record was not deferred to the next poll"
  start=$(date +%s)
  start_check_tick 1200 || fail "the deferred remote record did not get its next-poll turn"
  elapsed=$(($(date +%s) - start))
  [ "$elapsed" -lt 6 ] || fail "the next remote route stalled the tick for ${elapsed}s"
  [ ! -e "$STATE/r8.start-pending" ] || fail "the deferred record was not judged on the next poll"
  [ "$(count_wakes)" = 2 ] || fail "the deferred remote record did not queue its wake"
  pass "remote route calls share a bounded poll budget and later records wait for the next poll"
}

# A record whose route read would start after this poll's shared budget is
# spent is neither proven nor judged: it waits for the next poll, so a slow
# but healthy route never turns into a false start wake for the next mate.
test_spent_route_budget_defers_remote_record() {
  reset_state
  local real saved_secs=$START_CHECK_ROUTE_SECS
  real=$(declare -f start_check_remote)
  arm_remote b1
  arm_remote b2
  # Budgets are whole seconds; 3 survives a clock-second boundary in the next
  # tick, and the 4s answer below always spends it in this one.
  START_CHECK_ROUTE_SECS=3
  start_check_remote() {  # b1 answers slowly but proves its start
    WATCHER_CAPTURE=
    case "$1:$2" in
      b1:observe) sleep 4; WATCHER_CAPTURE=$(remote_proof busy) ;;
      b2:observe) WATCHER_CAPTURE=$(remote_proof idle) ;;
      *) return 1 ;;
    esac
  }
  start_check_tick 1200 || fail "tick failed"
  [ ! -e "$STATE/b1.start-pending" ] || fail "the slow but started remote mate was not cleared"
  [ -e "$STATE/b2.start-pending" ] || fail "a record past the spent route budget was judged in the same poll"
  [ "$(count_wakes)" = 0 ] || fail "a spent route budget produced a start wake: $START_CHECK_WAKE"
  start_check_tick 1200 || fail "tick failed"
  [ ! -e "$STATE/b2.start-pending" ] || fail "the deferred remote record was not judged on the next poll"
  [ "$(count_wakes)" = 1 ] || fail "the deferred unstarted remote record did not wake on the next poll"
  eval "$real"
  START_CHECK_ROUTE_SECS=$saved_secs
  pass "a remote record past the poll's spent route budget waits for the next poll instead of waking"
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
  FM_POLL=1 FM_START_CHECK_SECS=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
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
  test_same_second_turn_end_is_proof \
  test_launch_epoch_excludes_existing_markers \
  test_pi_dialog_named_once \
  test_claude_dialog_has_no_key \
  test_claude_session_end_is_not_start_proof \
  test_dead_agent_names_relaunch \
  test_missing_endpoint_names_recovery \
  test_pending_composer_names_submit \
  test_no_signal_names_inspect \
  test_codex_footer_and_status_are_proof \
  test_codex_dialog_overrides_footer_proof \
  test_stale_records_are_dropped \
  test_secondmate_launch_is_checked \
  test_held_lock_defers_without_waiting \
  test_remote_secondmate_reads_route \
  test_spent_route_budget_defers_remote_record \
  test_one_wake_per_poll \
  test_watcher_loop_single_named_wake
