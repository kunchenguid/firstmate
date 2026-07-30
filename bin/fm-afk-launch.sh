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
#   fm-afk-launch.sh start     Refresh a live daemon or reconcile a dead one,
#                              then launch a fresh non-visible backend terminal.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Publish exact stop intent, SIGTERM the daemon,
#                              flush while state/.afk remains, close the exact
#                              terminal, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#   fm-afk-launch.sh check-death
#                              Reconcile and alert on daemon loss while afk.
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
case "$FM_HOME" in
  /*) ;;
  *)
    FM_AFK_LAUNCH_HOME_INPUT=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $FM_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  case "$FM_STATE_OVERRIDE" in
    /*) ;;
    *)
      FM_AFK_LAUNCH_STATE_INPUT=$FM_STATE_OVERRIDE
      FM_STATE_OVERRIDE=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: FM_STATE_OVERRIDE directory cannot be resolved: $FM_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
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
# shellcheck source=bin/fm-afk-death-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-death-lib.sh"

FM_AFK_LAUNCH_STOP_PID=
FM_AFK_LAUNCH_STOP_IDENTITY=
FM_AFK_LAUNCH_STOP_INTENT_ACTIVE=0

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_stop_tracking_clear() {
  FM_AFK_LAUNCH_STOP_PID=
  FM_AFK_LAUNCH_STOP_IDENTITY=
  FM_AFK_LAUNCH_STOP_INTENT_ACTIVE=0
}

fm_afk_launch_stop_intent_abandon_if_live() {
  local current_identity
  [ "$FM_AFK_LAUNCH_STOP_INTENT_ACTIVE" -eq 1 ] || return 0
  fm_pid_alive "$FM_AFK_LAUNCH_STOP_PID" || return 0
  current_identity=$(fm_pid_identity "$FM_AFK_LAUNCH_STOP_PID" 2>/dev/null || true)
  if [ -n "$current_identity" ] \
    && [ "$current_identity" != "$FM_AFK_LAUNCH_STOP_IDENTITY" ]; then
    return 0
  fi
  if fm_afk_stop_intent_abandon "$FM_AFK_LAUNCH_STATE" \
    "$FM_AFK_LAUNCH_STOP_PID" "$FM_AFK_LAUNCH_STOP_IDENTITY"; then
    fm_afk_launch_stop_tracking_clear
  fi
}

fm_afk_launch_signal_exit() {
  local code=$1
  trap - HUP INT TERM
  fm_lock_release "$FM_AFK_LAUNCH_STATE/${FM_AFK_STOP_INTENT_NAME}.transition.lock" 2>/dev/null || true
  fm_afk_launch_stop_intent_abandon_if_live || true
  exit "$code"
}

fm_afk_launch_exit_cleanup() {
  fm_afk_launch_stop_intent_abandon_if_live || true
  fm_afk_launch_lock_release
}

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$FM_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$FM_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
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
      rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
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
  [ "$pid" = "$$" ] || return 0
  rm -rf "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

# tmux panes can inherit SIGTERM as ignored from their server process.
# A short-lived native resetter restores the normal disposition before execing
# the shell daemon, so its TERM/HUP cleanup traps remain observable.
fm_afk_launch_daemon_cmd() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 entry resetter perl_program
  entry=$(fm_afk_launch_entry_cmd)
  resetter=$(command -v perl 2>/dev/null) || {
    fm_afk_launch_log "perl is required to reset inherited daemon signal dispositions"
    return 1
  }
  perl_program="\$SIG{TERM} = \"DEFAULT\"; \$SIG{INT} = \"DEFAULT\"; \$SIG{HUP} = \"DEFAULT\"; exec @ARGV or die \"exec: \$!\\n\";"
  printf 'exec %q -e %q -- env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q FM_WEDGE_ALARM_CHANNEL=%q FM_WEDGE_ALARM_EXEC=%q FM_WEDGE_ALARM_TIMEOUT_SECS=%q %q' \
    "$resetter" "$perl_program" \
    "$FM_HOME" "$captain_target" "$captain_backend" "${FM_WEDGE_ALARM_CHANNEL:-}" \
    "${FM_WEDGE_ALARM_EXEC:-}" "${FM_WEDGE_ALARM_TIMEOUT_SECS:-}" "$entry"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  local pending="$FM_AFK_LAUNCH_STATE/.afk.pending.$$"
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_STATE/.afk" || { rm -f "$pending"; return 1; }
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET. The third
# field (a herdr workspace id, kept for the record's own documentation) is not
# needed to close by id, so it is discarded. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  local extra record
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; extra=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$FM_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET extra \
    < "$FM_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr) [ -n "$extra" ] ;;
    tmux) : ;;
    none) [ "$FM_AFK_REC_TARGET" = - ] && [ "$extra" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    daemon_lock_held_by_live_daemon && return 0
    fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane attempt=0
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

fm_afk_launch_check_dead_daemon() {
  local owner pid identity current_identity marker record_result intent_applies=0
  [ -e "$FM_AFK_LAUNCH_STATE/.afk" ] || return 0
  fm_afk_unexpected_exit_read "$FM_AFK_LAUNCH_STATE" && return 0
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
    if fm_afk_stop_intent_read "$FM_AFK_LAUNCH_STATE" \
      && [ "$FM_AFK_STOP_INTENT_PHASE" = published ] \
      && [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
      && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ] \
      && ! fm_afk_stop_intent_publisher_alive; then
      fm_afk_stop_intent_abandon "$FM_AFK_LAUNCH_STATE" "$pid" "$identity" || return 1
    fi
    return 0
  fi
  fm_afk_start_pending_active "$FM_AFK_LAUNCH_STATE" && return 0
  owner=$(daemon_lock_owner 2>/dev/null || true)
  pid=
  identity=MISSING
  if [ -n "$owner" ]; then
    pid=$(cat "$owner/pid" 2>/dev/null || true)
    identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  fi
  if [ -z "$pid" ]; then
    pid=$(cat "$FM_AFK_LAUNCH_STATE/.supervise-daemon.pid" 2>/dev/null || true)
  fi
  case "$pid" in ''|*[!0-9]*) pid=MISSING ;; esac
  fm_afk_death_valid_identity "$identity" || identity=MISSING
  if fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ "$identity" != MISSING ] && [ "$current_identity" = "$identity" ]; then
      return 0
    fi
  fi
  if fm_afk_stop_intent_read "$FM_AFK_LAUNCH_STATE"; then
    if { [ "$identity" != MISSING ] \
      && [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
      && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ]; } \
      || { [ -z "$owner" ] && [ "$pid" = MISSING ] \
        && [ "$FM_AFK_STOP_INTENT_PHASE" = consumed ]; }; then
      intent_applies=1
    fi
    if [ "$intent_applies" -eq 1 ]; then
      case "$FM_AFK_STOP_INTENT_PHASE" in
        consumed)
          fm_afk_launch_log "expected daemon loss observed (pid=$FM_AFK_STOP_INTENT_PID)"
          return 0
          ;;
        published)
          if fm_afk_stop_intent_publisher_alive; then
            return 0
          fi
          fm_afk_stop_intent_abandon "$FM_AFK_LAUNCH_STATE" \
            "$FM_AFK_STOP_INTENT_PID" "$FM_AFK_STOP_INTENT_IDENTITY" || true
          if fm_afk_stop_intent_read "$FM_AFK_LAUNCH_STATE" \
            && [ "$FM_AFK_STOP_INTENT_PHASE" = consumed ] \
            && [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
            && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ]; then
            fm_afk_launch_log "expected daemon loss observed (pid=$FM_AFK_STOP_INTENT_PID)"
            return 0
          fi
          ;;
      esac
    fi
  fi
  marker=$(fm_afk_unexpected_exit_path "$FM_AFK_LAUNCH_STATE")
  fm_afk_unexpected_exit_record "$FM_AFK_LAUNCH_STATE" UNTRAPPABLE "$pid" "$identity"
  record_result=$?
  case "$record_result" in
    0)
      fm_afk_launch_log "away-mode daemon loss detected (pid=$pid identity=$identity); alarm marker written"
      "$FM_AFK_LAUNCH_DIR/fm-supervise-daemon.sh" --wedge-alarm-notify \
        "away-mode daemon exited unexpectedly (signal=UNTRAPPABLE pid=$pid identity=$identity) - see $marker" "$marker"
      ;;
    2)
      return 0
      ;;
    *)
      fm_afk_launch_log "away-mode daemon loss detected (pid=$pid identity=$identity); failed to write alarm marker"
      "$FM_AFK_LAUNCH_DIR/fm-supervise-daemon.sh" --wedge-alarm-notify \
        "away-mode daemon exited unexpectedly (signal=UNTRAPPABLE pid=$pid identity=$identity) - durable marker write failed" "$marker"
      return 1
      ;;
  esac
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  fm_afk_launch_check_dead_daemon || return 1
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" \
    "$FM_AFK_LAUNCH_STATE/.supervise-daemon.start-pending" \
    "$FM_AFK_LAUNCH_STATE/.supervise-daemon.stop-intent" \
    "$FM_AFK_LAUNCH_STATE/.supervise-daemon.unexpected-exit" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged \
    .supervise-daemon.start-pending .supervise-daemon.stop-intent \
    .supervise-daemon.unexpected-exit; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane cmd label recovered create_result
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  cmd=$(fm_afk_launch_daemon_cmd "$captain_target" "$captain_backend") || return 1
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  cmd=$(fm_afk_launch_daemon_cmd "$captain_target" "$captain_backend") || return 1
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
      fm_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  fm_afk_launch_check_dead_daemon || return 1
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged \
    .supervise-daemon.start-pending .supervise-daemon.stop-intent \
    .supervise-daemon.unexpected-exit; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  fm_afk_launch_check_dead_daemon || return 1
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged \
    .supervise-daemon.start-pending .supervise-daemon.stop-intent \
    .supervise-daemon.unexpected-exit; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_start_pending_publish "$FM_AFK_LAUNCH_STATE"; then
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity publisher_pid publisher_identity result=0 read_result afk_cleared=0
  fm_afk_launch_stop_tracking_clear
  fm_afk_launch_check_dead_daemon || return 1
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    FM_AFK_LAUNCH_STOP_PID=$pid
    FM_AFK_LAUNCH_STOP_IDENTITY=$pid_identity
    FM_AFK_LAUNCH_STOP_INTENT_ACTIVE=1
    publisher_pid=${BASHPID:-$$}
    publisher_identity=$(fm_pid_identity "$publisher_pid" 2>/dev/null) || {
      fm_afk_launch_stop_tracking_clear
      return 1
    }
    if ! fm_afk_stop_intent_publish "$FM_AFK_LAUNCH_STATE" "$pid" "$pid_identity" \
      "$publisher_pid" "$publisher_identity"; then
      fm_afk_launch_stop_tracking_clear
      fm_afk_launch_log "failed to publish the exact daemon stop intent; preserving lifecycle state"
      return 1
    fi
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_stop_intent_abandon_if_live || true
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_stop_intent_abandon_if_live || true
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  else
    afk_cleared=1
  fi
  if [ "$afk_cleared" -eq 1 ]; then
    fm_afk_start_pending_clear "$FM_AFK_LAUNCH_STATE" || result=1
  fi
  if [ "$afk_cleared" -eq 1 ] && [ -n "$pid" ] \
    && fm_afk_stop_intent_matches "$FM_AFK_LAUNCH_STATE" "$pid" "$pid_identity"; then
    fm_afk_stop_intent_retire "$FM_AFK_LAUNCH_STATE" "$pid" "$pid_identity" || result=1
  fi
  fm_afk_launch_stop_tracking_clear
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result
  fm_afk_launch_lock_acquire || return 1
  trap fm_afk_launch_exit_cleanup EXIT
  trap 'fm_afk_launch_signal_exit 129' HUP
  trap 'fm_afk_launch_signal_exit 130' INT
  trap 'fm_afk_launch_signal_exit 143' TERM
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    check-death) fm_afk_launch_check_dead_daemon ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_stop_intent_abandon_if_live || result=1
  fm_afk_launch_lock_release || result=1
  trap - EXIT HUP INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
