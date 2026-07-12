#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local i incomplete=0
  mkdir -p "$FM_AFK_LAUNCH_STATE"
  for i in $(seq 1 200); do
    if mkdir "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
      printf '%s' "$$" > "$FM_AFK_LAUNCH_LOCK/pid"
      fm_pid_identity "$$" > "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null || true
      return 0
    fi
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || true
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] && rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || true
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  mkdir -p "$FM_AFK_LAUNCH_STATE"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$FM_AFK_LAUNCH_RECORD"
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET. The third
# field (a herdr workspace id, kept for the record's own documentation) is not
# needed to close by id, so it is discarded. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET _ \
    < "$FM_AFK_LAUNCH_RECORD"
  [ -n "$FM_AFK_REC_BACKEND" ] && [ -n "$FM_AFK_REC_TARGET" ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). Best-effort. The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 0
      # pane close removes the pane; its tab (and this daemon's dedicated
      # single-tab workspace) go with it. Exact pane id only.
      fm_backend_herdr_kill "$target"
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null || true
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 0
      ;;
  esac
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  if fm_afk_launch_record_read; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"
    rm -f "$FM_AFK_LAUNCH_RECORD" 2>/dev/null || true
  fi
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd pane_list pane_count
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$FM_AFK_LAUNCH_WS_LABEL" --no-focus 2>/dev/null) || {
    fm_afk_launch_log "herdr workspace create failed in session '$session'"; return 1; }
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    fm_afk_launch_log "could not parse workspace/pane id from herdr workspace create"
    if [ -n "$pane" ]; then
      fm_backend_herdr_kill "$session:$pane"
    elif [ -n "$wsid" ]; then
      pane_list=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null || true)
      pane_count=$(printf '%s' "$pane_list" | jq '[.result.panes[]?] | length' 2>/dev/null || true)
      if [ "$pane_count" = 1 ]; then
        pane=$(printf '%s' "$pane_list" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null)
        [ -n "$pane" ] && fm_backend_herdr_kill "$session:$pane"
      fi
    fi
    return 1
  fi
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    fm_backend_herdr_kill "$session:$pane"
    return 1
  fi
  fm_afk_launch_record_write herdr "$session:$pane" "$wsid"
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  session="fm-afk-daemon-$hash"
  # Drop any leaked same-named daemon session first (exact id only).
  tmux kill-session -t "$session" 2>/dev/null || true
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    return 1
  fi
  fm_afk_launch_record_write tmux "$session" ""
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    date '+%s' > "$FM_AFK_LAUNCH_STATE/.afk"
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  [ -f "$FM_AFK_LAUNCH_STATE/.afk" ] && had_afk=1 && cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk"
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ] && cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact"
  done
  fm_afk_launch_reconcile
  fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"
  date '+%s' > "$FM_AFK_LAUNCH_STATE/.afk"

  case "$captain_backend" in
    herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
    tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
    *)
      fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
      result=1
      ;;
  esac
  if [ "$result" -ne 0 ]; then
    rm -f "$FM_AFK_LAUNCH_STATE/.afk" "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
      "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged"
    [ "$had_afk" -eq 1 ] && cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk"
    for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
      [ -e "$backup/$artifact" ] && cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact"
    done
  fi
  rm -rf "$backup"
  return "$result"
}

fm_afk_launch_stop() {
  local pid i
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null || true)
  fi
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  # (2) Close the daemon's own terminal by exact id.
  if fm_afk_launch_record_read; then
    fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"
    rm -f "$FM_AFK_LAUNCH_RECORD" 2>/dev/null || true
  fi
  # (3) Clear the away-mode flag LAST.
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" 2>/dev/null || true
  fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
}

fm_afk_launch_main() {
  local result
  fm_afk_launch_lock_acquire || return 1
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
