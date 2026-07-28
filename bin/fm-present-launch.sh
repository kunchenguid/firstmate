#!/usr/bin/env bash
# fm-present-launch.sh - the single owner of the PRESENT-mode supervise daemon
# TERMINAL lifecycle: launch it in a NON-VISIBLE tracked terminal per backend,
# record its exact id, tear it down by that exact id, and reconcile a leaked one
# after a crash. This is the sibling of bin/fm-afk-launch.sh (which owns the
# AWAY-mode daemon terminal); the two share the daemon binary and the captain-
# pane discovery, but are deliberately separate lifecycles - present mode never
# touches state/.afk, keeps no escalation buffer, and yields to away mode.
#
# Why this exists (docs/supervision-protocols/codex.md):
# A primary harness that CANNOT be woken by background-task completion (Codex,
# traex) misses supervision wakes while the captain is present - the watcher
# enqueues an actionable wake to state/.wake-queue and exits, but nothing starts
# a fresh model turn to drain it (contrast Claude/grok, which wake natively from
# a completed background task). This launches bin/fm-supervise-daemon.sh in
# PRESENT mode (FM_SUPERVISE_PRESENT=1) in a non-visible tracked terminal so the
# daemon can nudge the captain's pane on each actionable wake, starting the turn
# that drains the queue. The nudge is the durable fallback; the foreground
# checkpoint (bin/fm-watch-checkpoint.sh) remains the manual backstop.
#
# Correct supervisor targeting mirrors fm-afk-launch: capture the captain pane
# FIRST from the pane this script runs in, then pass it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND so the daemon (running in its own
# separate terminal) injects into the captain's pane, not its own.
#
# Usage:
#   fm-present-launch.sh start      Capture the captain pane, then (unless the
#                                   present daemon is already running) launch it
#                                   in a fresh non-visible terminal for the
#                                   detected backend and record it. Idempotent.
#   fm-present-launch.sh stop       SIGTERM the present daemon, wait for it, then
#                                   close the recorded terminal by exact id.
#   fm-present-launch.sh reconcile  Close a recorded-but-dead terminal by exact
#                                   id and drop the record (recovery after crash).
#   fm-present-launch.sh status     Print whether the present daemon is running.
#
# Supported backends: herdr, tmux (same as away mode). When no injectable
# supervisor pane resolves (an independent pty) or the backend has no injection
# primitive, start reports an honest degrade - durable notifications remain, only
# automatic injection is unavailable - and returns 3 (FM_PRESENT_DEGRADED), NOT a
# bare failure, so the caller falls back to the foreground checkpoint knowingly.
#
# Test seam: FM_PRESENT_LAUNCH_ENTRY overrides the command run in the created
# terminal (default: the daemon itself), so a topology test can run a harmless
# placeholder. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND override the captured
# captain pane/backend (an isolated lab pane in tests).
set -u

FM_PRESENT_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_PRESENT_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_PRESENT_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_PRESENT_RECORD="$FM_PRESENT_STATE/.present-daemon-terminal"
FM_PRESENT_WS_LABEL="firstmate-present-daemon"
FM_PRESENT_DAEMON="$FM_PRESENT_LAUNCH_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-backend.sh
. "$FM_PRESENT_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_PRESENT_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh owns the daemon-lock liveness helpers (daemon_lock_owner,
# daemon_lock_pid, daemon_lock_held_by_live_daemon) plus fm_pid_* via
# fm-wake-lib.sh. Reuse them here rather than re-deriving the tricky lock
# liveness logic; they read the FM_AFK_LOCK global at call time, so REPOINT it at
# the PRESENT daemon's lock immediately after sourcing. It sets `set -eu`, so
# turn errexit back off for this script's best-effort flow.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_PRESENT_LAUNCH_DIR/fm-afk-start.sh"
set +e
FM_AFK_LOCK="$FM_PRESENT_STATE/.supervise-present.lock"

fm_present_log() { printf 'fm-present-launch: %s\n' "$*" >&2; }

# Exit code for an EXPECTED structural degrade: this primary cannot be woken by
# automatic injection here (no injectable supervisor pane resolves, or the
# supervisor backend has no non-visible injection primitive), yet durable
# queueing is unaffected - wakes are still enqueued and drained by the foreground
# checkpoint. Distinct from 1 (a genuine launch failure to repair) so the caller
# reports the honest fallback instead of a bare error, and distinct from 0 so it
# never looks like the daemon started.
FM_PRESENT_DEGRADED=3

# Report the honest degrade rather than failing silently or injecting into an
# unverified pane. Durable notifications keep working; only automatic turn
# injection is unavailable, so supervision falls back to the bounded foreground
# checkpoint. <reason> names why injection is off. Writing a marked nudge into an
# arbitrary pty would NOT be a reliable wake, so this deliberately does not try.
fm_present_report_degraded() {  # <reason>
  fm_present_log "durable notifications available (wakes are queued and never lost); automatic turn injection unavailable - $1; using the foreground checkpoint fallback (bin/fm-watch-checkpoint.sh). To enable automatic injection, run the primary inside tmux or herdr, or set FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND."
}

fm_present_usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch execs the daemon in
# present mode; a test overrides it with a harmless placeholder.
fm_present_entry_cmd() {
  printf '%s' "${FM_PRESENT_LAUNCH_ENTRY:-$FM_PRESENT_DAEMON}"
}

fm_present_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$FM_PRESENT_STATE" || return 1
  pending=$(mktemp "$FM_PRESENT_STATE/.present-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_PRESENT_RECORD" || { rm -f "$pending"; return 1; }
}

# Read the recorded terminal into FM_PRESENT_REC_BACKEND/FM_PRESENT_REC_TARGET.
# The third field (a herdr workspace id) is documentation only. Returns 1 when
# no record exists, 2 when the record is malformed.
fm_present_record_read() {
  local extra record
  FM_PRESENT_REC_BACKEND=""; FM_PRESENT_REC_TARGET=""; extra=""
  [ -f "$FM_PRESENT_RECORD" ] || return 1
  record=$(cat "$FM_PRESENT_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_PRESENT_REC_BACKEND FM_PRESENT_REC_TARGET extra \
    < "$FM_PRESENT_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_PRESENT_REC_BACKEND" ] || [ -z "$FM_PRESENT_REC_TARGET" ]; then
    fm_present_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_PRESENT_REC_BACKEND" in
    herdr) [ -n "$extra" ] ;;
    tmux) : ;;
    *) return 2 ;;
  esac || { fm_present_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

# Close a recorded terminal by EXACT id (never a broad sweep).
fm_present_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      session=${target%%:*}; pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      fm_tmux kill-session -t "$target" 2>/dev/null
      ;;
    *)
      fm_present_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_present_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}; pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1); result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(fm_tmux has-session -t "$target" 2>&1); result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    *) return 1 ;;
  esac
}

fm_present_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}; pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      fm_tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_present_close_recorded() {
  local close_result=0
  fm_present_close_terminal "$FM_PRESENT_REC_BACKEND" "$FM_PRESENT_REC_TARGET" || close_result=$?
  if fm_present_terminal_absent "$FM_PRESENT_REC_BACKEND" "$FM_PRESENT_REC_TARGET"; then
    rm -f "$FM_PRESENT_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_present_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_present_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

# Wait until the present daemon holds its lock (or, under the test-entry seam,
# until the terminal is merely alive).
fm_present_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 i
  if [ -n "${FM_PRESENT_LAUNCH_ENTRY:-}" ]; then
    fm_present_terminal_alive "$backend" "$target"
    return
  fi
  for i in $(seq 1 100); do
    daemon_lock_held_by_live_daemon && return 0
    fm_present_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

# Launch the daemon in a non-visible herdr workspace (--no-focus) in the
# CAPTAIN's session, so it can inject into the captain pane which lives there.
fm_present_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd label
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_present_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_present_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_PRESENT_LAUNCH_LABEL:-"$FM_PRESENT_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    fm_present_log "herdr create did not yield an exact workspace/pane id"
    return 1
  fi
  entry=$(fm_present_entry_cmd)
  cmd=$(printf 'exec env FM_SUPERVISE_PRESENT=1 FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_present_record_write herdr "$session:$pane" "$wsid"; then
    fm_present_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_present_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_present_log "failed to run present daemon in herdr pane $session:$pane; closing it"
    FM_PRESENT_REC_BACKEND=herdr; FM_PRESENT_REC_TARGET="$session:$pane"
    fm_present_close_recorded || true
    return 1
  fi
  if ! fm_present_wait_ready herdr "$session:$pane"; then
    fm_present_log "present daemon did not become ready; closing $session:$pane"
    FM_PRESENT_REC_BACKEND=herdr; FM_PRESENT_REC_TARGET="$session:$pane"
    fm_present_close_recorded
    return 1
  fi
  fm_present_log "present daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split of the captain's
# window). tmux pane ids are server-global, so the daemon reaches the captain
# pane by its %id from this separate session.
fm_present_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-present-daemon-$hash-$nonce"
  entry=$(fm_present_entry_cmd)
  # FM_TMUX_SOCKET is handed over explicitly so the daemon addresses the SAME
  # tmux server this launcher resolved, instead of re-deriving one from its own
  # detached session's environment (bin/fm-tmux-lib.sh).
  cmd=$(printf 'exec env FM_SUPERVISE_PRESENT=1 FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q FM_TMUX_SOCKET=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$(fm_tmux_socket)" "$entry")
  if ! fm_present_record_write tmux "$session" ""; then
    fm_present_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! fm_tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_present_log "failed to create detached tmux daemon session '$session'"
    rm -f "$FM_PRESENT_RECORD" || fm_present_log "failed to remove planned tmux daemon record"
    return 1
  fi
  if ! fm_present_wait_ready tmux "$session"; then
    fm_present_log "present daemon did not become ready; closing tmux session '$session'"
    FM_PRESENT_REC_BACKEND=tmux; FM_PRESENT_REC_TARGET="$session"
    fm_present_close_recorded
    return 1
  fi
  fm_present_log "present daemon launched in detached tmux session '$session', supervising $captain_target"
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live present
# daemon owns it, close the leaked terminal by exact id and drop the record.
fm_present_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_present_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_present_log "reconciling leaked daemon terminal ${FM_PRESENT_REC_BACKEND}:${FM_PRESENT_REC_TARGET}"
    fm_present_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_present_start() {
  local captain_target captain_backend result=0
  if daemon_lock_held_by_live_daemon; then
    fm_present_log "present daemon already running; nothing to do"
    return 0
  fi
  captain_target=$(discover_supervisor_target) || {
    fm_present_report_degraded "no injectable supervisor pane resolved (this primary is on an independent pty, not tmux/herdr)"
    return "$FM_PRESENT_DEGRADED"; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_present_report_degraded "no injectable supervisor backend resolved (this primary is on an independent pty, not tmux/herdr)"
    return "$FM_PRESENT_DEGRADED"; }
  mkdir -p "$FM_PRESENT_STATE"
  # Clear a leaked terminal from a prior crashed daemon before launching a new one.
  fm_present_reconcile || return 1
  case "$captain_backend" in
    herdr) fm_present_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
    tmux)  fm_present_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
    *)
      fm_present_report_degraded "supervisor backend '$captain_backend' has no non-visible injection primitive (supported: herdr, tmux)"
      result="$FM_PRESENT_DEGRADED"
      ;;
  esac
  return "$result"
}

fm_present_stop() {
  local pid pid_identity current_identity result=0 read_result
  fm_present_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_present_log "malformed daemon terminal record; refusing to stop"
    return 1
  fi
  pid=""; pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_present_log "failed to signal present daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_present_log "could not confirm present daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_present_log "present daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  if [ "$read_result" -eq 0 ]; then
    fm_present_close_recorded || result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_present_log "present daemon stopped; terminal torn down"
  else
    fm_present_log "present daemon stop incomplete; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_present_status() {
  local pid
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null || true)
    printf 'present daemon: running pid=%s\n' "$pid"
    return 0
  fi
  printf 'present daemon: not running\n'
  return 1
}

fm_present_main() {
  case "${1:-start}" in
    start) fm_present_start ;;
    stop) fm_present_stop ;;
    reconcile) fm_present_reconcile ;;
    status) fm_present_status ;;
    -h|--help|help) fm_present_usage ;;
    *) fm_present_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_present_main "$@"
fi
