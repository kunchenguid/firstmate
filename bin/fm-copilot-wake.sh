#!/usr/bin/env bash
# Wake an idle GitHub Copilot CLI primary when the watcher has an event.
#
# Copilot has no asynchronous rewake, and a parked agentStop hook leaves the pane
# deaf to typing, Escape, Ctrl-C and /exit (docs/verification/copilot.md "Parked
# hooks"), so nothing waits inside a turn boundary. This one detached process
# keeps bin/fm-watch-arm.sh running as a tracked child and, while the durable
# wake queue holds an unacknowledged row, types the record-backed doorbell owned
# by bin/fm-operational-input.sh into the primary's own pane. Every typed prompt
# resets Copilot's cap of eight stop-hook continuations, so a chain of wakes is
# not capped.
#
# Usage:
#   fm-copilot-wake.sh start              start or find the wake process and
#                                         confirm a live watcher; one status line
#   fm-copilot-wake.sh run                the loop itself (start launches it)
#   fm-copilot-wake.sh revive             start the loop again if it is gone and
#                                         the pane is idle; silent no-op otherwise
#   fm-copilot-wake.sh turn <busy|idle> <event>
#                                         record a turn boundary from a native
#                                         hook; the payload is on stdin
#
# A ring needs both of these to pass, each from its existing owner:
#   - no turn runs: the busy record says idle (bin/fm-busy-lib.sh, written by the
#     tracked userPromptSubmitted, agentStop and sessionEnd hooks through the
#     `turn` subcommand). agentStop never fires on an interrupted turn and no
#     hook reports the cancel, but the session transcript (events.jsonl, found
#     through the sessionId the busy hook records) gets an `abort` event within
#     about 0.1 s. A busy record whose transcript ends in an abort, with no later
#     user.message, passes at once; without a readable transcript it passes after
#     FM_COPILOT_WAKE_INTERRUPT_GRACE seconds. Either way the pane must also no
#     longer draw Copilot's busy footer (fm_busy_lines_match in
#     bin/fm-composer-lib.sh);
#   - the composer reads exactly `empty` (bin/fm-composer-lib.sh). A half-written
#     operator line reads `pending` and an unrecognized screen, such as a picker,
#     reads `unknown`; both wait.
# Terminal input has no compare-and-type, so the doorbell is typed and submitted
# in one step guarded as late as the backend allows: on tmux the cursor read
# before the composer check is re-tested inside the server just before the paste
# (paste-buffer -p, then Enter, in one command list), on Herdr the composer is
# re-read just before one `pane run`. A keystroke that lands before the guard
# makes the ring refuse and leaves the draft alone. Measured with Copilot
# 1.0.109 (docs/verification/copilot.md), the window in which a key still merges
# with the doorbell fell from about 0.7 s to about 5-10 ms on tmux and 10-30 ms
# on Herdr. What remains is Copilot's own echo time: a key already written to the
# pane but not yet drawn, which no screen read can see. That merge is submitted
# with the doorbell and cannot be closed from outside Copilot.
#
# The queue is the only delivery proof. A row stays until the session acknowledges
# it with bin/fm-wake-drain.sh --ack-through, so a wake that waits, a doorbell
# whose Enter is swallowed, and a crash of this process lose nothing. An
# unacknowledged head row is re-rung after FM_COPILOT_WAKE_GRACE seconds, doubling
# up to FM_COPILOT_WAKE_MAX; a new head row starts over. A doorbell left unsent in
# the composer gets Enter only and is never retyped.
#
# A running loop keeps the code it started with, so it re-executes itself, under
# the same pid, once a pass finds the script file changed (a self-update).
#
# The loop does not restart itself, so the userPromptSubmitted hook (`turn busy
# user-prompt-submit`) starts it again when work needs supervision and the lock's
# pid is dead, and bin/fm-turnend-guard-copilot.sh blocks a stop for the same
# reason. The orphaned watcher it leaves behind calls `revive` on every poll,
# which starts the loop again on the same two conditions plus an idle pane, so an
# unattended crash heals without a prompt. The log is appended to and trimmed in
# place to its newest FM_COPILOT_WAKE_LOG_MAX bytes.
#
# It stands down when away mode starts, whose daemon owns the watcher, and when
# the pane's agent exits. A tmux or Herdr pane is supported, found through
# bin/fm-supervisor-target-lib.sh; start refuses any other backend. Its log is
# state/.copilot-wake.log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
# The busy-contract id of the primary's turn record; a dotfile so no *.meta or
# task glob ever reads it as a task.
ID=.copilot-primary
LOCK=$(fm_copilot_wake_lock_dir "$STATE")
LOG="$STATE/.copilot-wake.log"

POLL=${FM_COPILOT_WAKE_POLL:-2}
RING_GRACE=${FM_COPILOT_WAKE_GRACE:-60}
RING_MAX=${FM_COPILOT_WAKE_MAX:-1800}
INTERRUPT_GRACE=${FM_COPILOT_WAKE_INTERRUPT_GRACE:-120}
START_WAIT=${FM_COPILOT_WAKE_START_WAIT:-30}
LOG_MAX=${FM_COPILOT_WAKE_LOG_MAX:-262144}
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$RING_GRACE" in ''|*[!0-9]*|0) RING_GRACE=60 ;; esac
case "$RING_MAX" in ''|*[!0-9]*|0) RING_MAX=1800 ;; esac
case "$INTERRUPT_GRACE" in ''|*[!0-9]*) INTERRUPT_GRACE=120 ;; esac
case "$LOG_MAX" in ''|*[!0-9]*|0) LOG_MAX=262144 ;; esac
case "$START_WAIT" in ''|*[!0-9]*|0) START_WAIT=30 ;; esac

WAKE_BODY='firstmate watcher wake - supervision events are queued. Run bin/fm-wake-drain.sh first, handle every wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. bin/fm-copilot-wake.sh owns watcher continuity, so do not run bin/fm-watch-arm.sh after an ordinary wake.'

usage() {
  sed -n '/^# Usage:/,/^# A ring needs/{ /^# A ring needs/d; s/^# \{0,1\}//; p; }' "$0" >&2
  exit 2
}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

cmd_turn() {  # <busy|idle> <event>
  local payload sid
  case "${1:-}" in busy|idle) ;; *) usage ;; esac
  [ -n "${2:-}" ] || usage
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  payload=$(cat 2>/dev/null || true)
  # A subagent raises its own events, and its stop would close the parent's turn.
  case "$payload" in *'"parentAgentId":"'*) return 0 ;; esac
  # The session's own transcript records an interrupt as an `abort` event that no hook reports.
  if [ "$1" = busy ]; then
    sid=$(printf '%s' "$payload" | jq -r '.sessionId // empty' 2>/dev/null)
    case "$sid" in ''|*[!A-Za-z0-9._-]*) ;; *) printf '%s\n' "${COPILOT_HOME:-$HOME/.copilot}/session-state/$sid/events.jsonl" > "$STATE/$ID.transcript" ;; esac
  fi
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$1" --current-gen \
    --source copilot-hook --event "$2" >/dev/null 2>&1 || true
  [ "$2" != user-prompt-submit ] || restart_if_gone || true
}

load_libs() {
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
}

watcher_live() { fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; }

# Trim the log in place to its newest LOG_MAX bytes: the running loop holds it open
# in append mode, so a replaced file would swallow its later lines.
cap_log() {
  local tmp
  [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt "$LOG_MAX" ] || return 0
  tmp=$(tail -c "$LOG_MAX" "$LOG" 2>/dev/null; printf x) || return 0
  printf '%s' "${tmp%x}" > "$LOG"
}

# The pane this session types into, or nonzero when there is none: sets BACKEND and TARGET.
find_pane() {
  local backend target
  backend=$(discover_supervisor_backend) || backend=
  target=$(discover_supervisor_target) || target=
  case "$backend" in tmux|herdr) ;; *) backend= ;; esac
  [ -n "$backend" ] && fm_backend_target_exists "$backend" "$target" || return 1
  BACKEND=$backend
  TARGET=$target
}

# Launch the loop detached, in its own process group away from the caller's pipes so
# it outlives a tool call or hook (the shape bin/fm-claude-stop-autoarm.sh uses for
# its detached arm). Sets WAKE_PID.
launch_run() {
  local monitor_was_on=0
  cap_log
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_SUPERVISOR_BACKEND=$BACKEND FM_SUPERVISOR_TARGET=$TARGET \
    nohup "$SCRIPT_DIR/fm-copilot-wake.sh" run </dev/null >>"$LOG" 2>&1 &
  WAKE_PID=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
}

# Every path that starts the loop is called from a running turn (a tool call or a prompt
# hook), so a missing busy-gen record is armed first: without one, the turn events that
# follow cannot apply and the pane never reads idle.
arm_turn_record() {
  [ -f "$(fm_busy_gen_path "$STATE" "$ID")" ] \
    || "$SCRIPT_DIR/fm-busy-event.sh" arm "$STATE" "$ID" --state busy --source fm-recovery --event wake-start >/dev/null 2>&1
}

# A prompt starts a turn, so a wake loop that died since the last one is started
# again when work needs supervision. Quiet and best effort: the hook never fails.
# With `idle` (the watcher's revive) the pane must also be between turns, so a
# busy turn or a half-written composer line is never restarted over.
restart_if_gone() {  # [idle]
  [ ! -e "$STATE/.afk" ] || return 0
  load_libs
  ! fm_pid_alive "$(cat "$LOCK/pid" 2>/dev/null || true)" || return 0
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_supervision_needed "$STATE" "$GRACE" || return 0
  find_pane || return 0
  if [ "${1:-}" = idle ]; then
    pane_idle && [ "$(FM_COMPOSER_HARNESS=copilot fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null)" = empty ] || return 0
    log 'restarting: the wake process was gone while the pane was idle' >> "$LOG"
  else
    log 'restarting: the wake process was gone at a prompt' >> "$LOG"
  fi
  [ "${1:-}" = idle ] || arm_turn_record || return 0
  launch_run
}

cmd_start() {
  local pid deadline
  [ -d "$STATE" ] || { echo "copilot wake: FAILED - no state directory at $STATE"; exit 1; }
  load_libs
  if [ -e "$STATE/.afk" ]; then
    echo 'copilot wake: not started - away mode owns supervision'
    return 0
  fi
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if ! fm_pid_alive "$pid"; then
    if ! find_pane; then
      echo "copilot wake: FAILED - needs a live tmux or Herdr pane for this session; start Copilot with bin/fm-copilot-primary.sh (backend=none, target=none)"
      exit 1
    fi
    arm_turn_record || { echo 'copilot wake: FAILED - could not arm the turn record'; exit 1; }
    launch_run
    pid=$WAKE_PID
  fi
  deadline=$(( $(date +%s) + START_WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if watcher_live; then
      echo "copilot wake: running pid=$pid (live watcher pid=$FM_WATCHER_HEALTHY_PID)"
      return 0
    fi
    fm_pid_alive "$pid" || break
    sleep 0.2
  done
  echo "copilot wake: FAILED - no live watcher confirmed; see $LOG"
  exit 1
}

# 0 iff the newest prompt-or-abort event in the turn's transcript is an abort.
turn_aborted() {
  local transcript
  transcript=$(cat "$STATE/$ID.transcript" 2>/dev/null) && [ -f "$transcript" ] || return 1
  [ "$(tail -n 500 "$transcript" | grep -o -E '^\{"type":"(user\.message|abort)"' | tail -n 1)" = "$FM_COPILOT_ABORT_EVENT" ] # shortcut: last 500 lines only, upgrade if one cancelled turn writes more
}

# 0 iff no turn is running; the header owns the interrupted-turn exception.
pane_idle() {
  local verdict
  verdict=$(fm_busy_classify_live "$BACKEND" "$TARGET" copilot "$ID" "$STATE")
  case "$verdict" in
    idle\ *) return 0 ;;
    busy\ *)
      # A negative age is a file time after a backward clock jump: treat it as old.
      turn_aborted || [ "$(fm_path_age "$(fm_busy_record_path "$STATE" "$ID")")" -ge "$INTERRUPT_GRACE" ] \
        || [ "$(fm_path_age "$(fm_busy_record_path "$STATE" "$ID")")" -lt 0 ] || return 1
      fm_backend_capture "$BACKEND" "$TARGET" 12 2>/dev/null | fm_busy_lines_match copilot && return 1
      return 0
      ;;
  esac
  return 1
}

# The last guard runs where the input lands. On tmux the paste and its Enter
# run in one server command list that first checks the cursor still sits where
# the empty-composer read saw it; on Herdr a fresh composer read precedes one
# `pane run` that types and submits together.
submit_guarded() {  # <text> <tmux-cursor>
  case "$BACKEND" in
    tmux) fm_backend_tmux_paste_submit_if_cursor "$TARGET" "$1" "$2" ;;
    herdr)
      fm_backend_herdr_target_ready "$TARGET" || return 1
      [ "$(FM_COMPOSER_HARNESS=copilot fm_backend_composer_state herdr "$TARGET" 2>/dev/null)" = empty ] || return 1
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$1" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# 0 iff the doorbell was typed, or its unsent copy was given Enter.
ring_once() {
  local composer doorbell cursor=
  pane_idle || return 1
  # Read before the composer, so a keystroke after this read moves the cursor.
  [ "$BACKEND" != tmux ] || cursor=$(fm_backend_tmux_cursor "$TARGET" 2>/dev/null) || return 1
  composer=$(FM_COMPOSER_HARNESS=copilot fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null)
  case "$composer" in
    empty) ;;
    pending)
      [ -n "$LAST_LINE" ] || return 1
      FM_COMPOSER_HARNESS=copilot fm_task_inbox_composer_holds "$BACKEND" "$TARGET" "$LAST_LINE" || return 1
      fm_backend_send_key "$BACKEND" "$TARGET" Enter >/dev/null 2>&1 || return 1
      log 'ring: resubmitted an unsent doorbell'
      return 0
      ;;
    *) return 1 ;;
  esac
  fm_operational_record_write "$STATE" watcher "$WAKE_BODY" doorbell || return 1
  if ! submit_guarded "$doorbell" "$cursor"; then
    log 'ring: the composer changed before the doorbell landed'
    return 1
  fi
  LAST_LINE=$doorbell
  log "ring: typed the doorbell (head=$RING_HEAD)"
}

ring_tick() {
  local head now delay
  head=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { print $2; exit }' "$FM_WAKE_QUEUE" 2>/dev/null)
  if [ "$head" != "$RING_HEAD" ]; then
    RING_HEAD=$head
    RING_COUNT=0
    NEXT_RING=0
  fi
  [ -n "$head" ] || return 0
  now=$(date +%s)
  # A clock stepped back would otherwise hold the next ring for the size of the step.
  [ "$NEXT_RING" -le $((now + RING_MAX)) ] || NEXT_RING=$now
  [ "$now" -ge "$NEXT_RING" ] || return 0
  ring_once || return 0
  delay=$RING_GRACE
  [ "$RING_COUNT" -lt 16 ] && delay=$(( RING_GRACE << RING_COUNT ))
  { [ "$RING_COUNT" -lt 16 ] && [ "$delay" -lt "$RING_MAX" ]; } || delay=$RING_MAX
  RING_COUNT=$((RING_COUNT + 1))
  NEXT_RING=$((now + delay))
}

# fm_backend_tmux_agent_state needs a named session:window, and this target is the
# pane id from $TMUX_PANE, so read the pane's foreground argv[0] list directly;
# a Herdr pane gives the same list through its own process-info read.
# A foreground list without Copilot must repeat before it counts, because a
# transient read can come back empty or partial.
agent_gone() {
  local names name
  if ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
    return 0
  fi
  case "$BACKEND" in
    herdr) names=$(fm_backend_herdr_foreground_argv0s "$TARGET" 2>/dev/null) ;;
    *) names=$(fm_backend_tmux_foreground_argv0s "$TARGET" 2>/dev/null) ;;
  esac
  while IFS= read -r name; do
    [ "${name##*/}" != copilot ] || { GONE_POLLS=0; return 1; }
  done <<NAMES
$names
NAMES
  GONE_POLLS=$((GONE_POLLS + 1))
  [ "$GONE_POLLS" -ge 5 ]
}

# One tracked arm at a time. A close leaves its wake in the durable queue, and
# the next arm names the closed one so it does not announce that wake again.
arm_tick() {
  local status=0 now
  if [ -n "$ARM_PID" ]; then
    kill -0 "$ARM_PID" 2>/dev/null && return 0
    wait "$ARM_PID" 2>/dev/null || status=$?
    if [ "$status" -eq 0 ]; then
      ARM_FAILS=0
      PREDECESSOR=$ARM_PID
    else
      ARM_FAILS=$((ARM_FAILS + 1))
      PREDECESSOR=
      NEXT_ARM=$(( $(date +%s) + ARM_FAILS * ARM_FAILS ))
      log "arm: closed with status $status (failure $ARM_FAILS)"
    fi
    ARM_PID=
  fi
  now=$(date +%s)
  [ "$NEXT_ARM" -le $((now + ARM_FAILS * ARM_FAILS)) ] || NEXT_ARM=$now
  [ "$now" -ge "$NEXT_ARM" ] || return 0
  if [ -n "$PREDECESSOR" ]; then
    FM_WATCH_PREDECESSOR_ARM_PID=$PREDECESSOR "$SCRIPT_DIR/fm-watch-arm.sh" &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" &
  fi
  ARM_PID=$!
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_run() {
  [ -z "$ARM_PID" ] || { kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; }
  fm_lock_release "$LOCK"
}

# Changes whenever the script file is rewritten or replaced, as an update does.
script_sig() { cksum < "$SCRIPT_DIR/fm-copilot-wake.sh" 2>/dev/null; }

cmd_run() {
  local sig now_sig
  load_libs
  BACKEND=${FM_SUPERVISOR_BACKEND:-tmux}
  TARGET=${FM_SUPERVISOR_TARGET:-}
  [ -n "$TARGET" ] || { log 'stopped: no target pane'; exit 1; }
  fm_lock_try_acquire "$LOCK" || { log "already running: pid ${FM_LOCK_HELD_PID:-unknown}"; exit 0; }
  ARM_PID=
  PREDECESSOR=
  ARM_FAILS=0
  NEXT_ARM=0
  RING_HEAD=
  RING_COUNT=0
  NEXT_RING=0
  LAST_LINE=
  GONE_POLLS=0
  trap cleanup_run EXIT
  trap 'exit 0' TERM INT HUP
  log "started: target=$TARGET"
  sig=$(script_sig)
  while :; do
    now_sig=$(script_sig)
    if [ -n "$now_sig" ] && [ "$now_sig" != "$sig" ]; then
      log 'restarting: script updated'
      cleanup_run
      exec "$SCRIPT_DIR/fm-copilot-wake.sh" run
    fi
    if [ -e "$STATE/.afk" ]; then
      log 'stopped: away mode owns supervision'
      exit 0
    fi
    if agent_gone; then
      log 'stopped: the pane agent is gone'
      exit 0
    fi
    cap_log
    arm_tick
    ring_tick
    sleep "$POLL"
  done
}

case "${1:-}" in
  start) cmd_start ;;
  run) cmd_run ;;
  revive) restart_if_gone idle; exit 0 ;;
  turn) shift; cmd_turn "$@" ;;
  *) usage ;;
esac
