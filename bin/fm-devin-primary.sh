#!/usr/bin/env bash
# fm-devin-primary.sh - the single owner of a Devin primary's hook mechanics:
# the quiet-daemon ensure, and the SessionStart / Stop / SessionEnd hook
# entrypoints a Devin primary registers in its own Devin config
# (captain-private; the repo ships no tracked Devin hook files).
#
# A Devin primary is ALWAYS daemon-supervised: Devin cannot be woken from
# inside the model, so the quiet-mode daemon (bin/fm-supervise-daemon.sh,
# launched through bin/fm-afk-launch.sh) runs the watcher outside the model and
# types wakes into the primary's pane. The supervision protocol this enforces
# lives in docs/supervision-protocols/devin.md; the turn-end predicate lives in
# bin/fm-turnend-guard.sh --devin.
#
# Subcommands:
#   ensure        Make sure daemon supervision is up for this home. If
#                 state/.afk and its record already exist, run
#                 bin/fm-afk-launch.sh start (which reads the record's mode, so
#                 an existing away record stays away). Otherwise run
#                 `FM_AFK_MODE=quiet bin/fm-afk-launch.sh enter` then `start`.
#                 Then verify a live identity-matched daemon holds this home
#                 (fm_afk_daemon_owns_supervision, bin/fm-wake-lib.sh - the
#                 same predicate the turn-end guard uses). Exit 0 with one line
#                 naming the daemon pid and supervised pane; non-zero with
#                 fm-afk-launch's diagnostic otherwise.
#   session-start Devin SessionStart hook. Reads the event JSON on stdin
#                 (source: startup|resume). Outside a genuine primary checkout
#                 (fm_primary_scope_matches, bin/fm-primary-scope-lib.sh) it is
#                 a silent no-op. Otherwise it takes the session lock through
#                 bin/fm-lock.sh (this hook is a child of the devin process, so
#                 the ancestry walk finds it), refuses the session with a
#                 "decision":"block" when the lock is held by another live
#                 session or the primary is not inside an addressable tmux or
#                 Herdr pane, runs `ensure`, warns (never blocks) when
#                 config/wedge-alarm names no reachable channel, and injects
#                 the result as SessionStart additionalContext that ends with
#                 "Run bin/fm-session-start.sh now, once." The same summary
#                 goes to stderr.
#   stop          Devin Stop hook. Reads the event JSON on stdin
#                 (prompt_id, session_id, stop_hook_active). Silent outside a
#                 genuine primary or when this session does not own the lock
#                 (fm_session_lock_owned_by_self). Self-heals once per stop:
#                 when no live identity-matched daemon holds this home it runs
#                 `ensure` and logs the result to stderr. Then pipes the
#                 payload to `bin/fm-turnend-guard.sh --devin`; a returned
#                 block object is passed through (prefixed with the ensure
#                 outcome when self-heal ran) after incrementing a per-turn
#                 counter state/.devin-stop-blocks.<prompt_id>, capped at
#                 FM_DEVIN_STOP_MAX_BLOCKS (default 3), so a persistently
#                 unhealthy daemon can never wedge the session. Counter files
#                 older than a day are pruned. An allow is silent and removes
#                 this turn's counter.
#   session-end   Devin SessionEnd hook. Only when this session owns the lock,
#                 runs `bin/fm-afk-launch.sh stop`; never fails loudly, always
#                 exits 0.
#
# Every block verdict is a printed {"decision":"block","reason":...} object on
# stdout with exit 0 (exit 2 is the stderr-carried fallback when jq is absent).
# Uncertainty fails OPEN on the Stop and SessionEnd paths - a buggy hook must
# never trap the captain's session - and CLOSED on session-start, where a
# silent miss is exactly the 2026-09-08 blind supervision this file exists to
# prevent.
#
# Usage: fm-devin-primary.sh {ensure|session-start|stop|session-end}
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *)
    FM_DEVIN_HOME_INPUT=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$FM_DEVIN_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $FM_DEVIN_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

usage() {
  cat <<'EOF'
Usage: fm-devin-primary.sh {ensure|session-start|stop|session-end}

Devin primary hook mechanics. `ensure` (re)starts the quiet daemon for this
home; `session-start`, `stop`, and `session-end` are the Devin hook
entrypoints registered in the primary's own Devin config. Blocks print a
{"decision":"block","reason":...} object; allows are silent.
EOF
}

# Print a Devin block object and exit 0; without jq, stderr plus exit 2 blocks
# the same way per the vendor hook contract.
emit_block() {  # <reason>
  local reason=$1
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" '{decision:"block",reason:$r}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

# The primary's own pane must be a target the daemon can type into: a tmux
# pane, a Herdr pane, or an explicit FM_SUPERVISOR_TARGET (the launch seam the
# daemon itself reads first).
supervisor_pane_addressable() {
  [ -n "${TMUX_PANE:-}" ] && return 0
  [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] && return 0
  [ -n "${FM_SUPERVISOR_TARGET:-}" ] && return 0
  return 1
}

# Print the pane the daemon supervises, for the ensure success line and the
# session-start context. Falls back to "unknown" rather than failing.
supervised_pane() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s\n' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  discover_supervisor_target 2>/dev/null || printf 'unknown\n'
}

cmd_ensure() {
  local out
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if [ -e "$STATE/.afk" ] && [ -f "$STATE/.afk-contract" ]; then
    if ! out=$("$SCRIPT_DIR/fm-afk-launch.sh" start 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
  else
    if ! out=$(FM_AFK_MODE=quiet "$SCRIPT_DIR/fm-afk-launch.sh" enter 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
    if ! out=$(FM_AFK_MODE=quiet "$SCRIPT_DIR/fm-afk-launch.sh" start 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
  fi
  # The daemon writes its identity lock at startup, just after `start`
  # returns; poll the same predicate the guard uses for a bounded window
  # (mirroring fm_afk_launch_wait_ready's cadence) before declaring failure.
  local attempt=0
  while [ "$attempt" -lt 100 ]; do
    fm_afk_daemon_owns_supervision "$STATE" && break
    attempt=$((attempt + 1))
    sleep 0.05
  done
  if ! fm_afk_daemon_owns_supervision "$STATE"; then
    echo "fm-devin-primary: no live identity-matched daemon holds this home after launch" >&2
    return 1
  fi
  local pid target
  pid=$(cat "$STATE/.supervise-daemon.lock/pid" 2>/dev/null || printf 'unknown')
  target=$(supervised_pane)
  printf 'quiet daemon running: pid %s supervising pane %s\n' "$pid" "$target"
}

# Print one warning line when no configured wedge-alarm channel can reach the
# captain, or nothing. Mirrors the channel parsing owned by
# wedge_alarm_configured_channels / wedge_alarm_notify in
# bin/fm-supervise-daemon.sh: FM_WEDGE_ALARM_CHANNEL wins (one directive), else
# the non-empty non-comment lines of config/wedge-alarm, else "auto".
wedge_alarm_warnings() {
  local ch line found='' off=0 auto=0 herdr=0 other=0
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    found=$FM_WEDGE_ALARM_CHANNEL
  elif [ -f "$CONFIG/wedge-alarm" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      found="${found:+$found
}$line"
    done < "$CONFIG/wedge-alarm"
  fi
  [ -n "$found" ] || found='auto'
  while IFS= read -r ch; do
    case "$ch" in
      off) off=1 ;;
      auto|default) auto=1 ;;
      herdr) herdr=1 ;;
      *) other=1 ;;
    esac
  done <<EOF
$found
EOF
  if [ "$off" -eq 1 ] && [ "$auto" -eq 0 ] && [ "$herdr" -eq 0 ] && [ "$other" -eq 0 ]; then
    printf '%s\n' 'WARNING: config/wedge-alarm disables every wedge-alarm channel; if the daemon cannot deliver an escalation nobody is notified - see docs/wedge-alarm.md.'
    return 0
  fi
  if [ "$other" -eq 0 ] && [ "$herdr" -eq 0 ] && [ "$off" -eq 0 ] \
    && [ "$(uname)" != Darwin ]; then
    printf '%s\n' 'WARNING: config/wedge-alarm names no working channel on this platform (auto is none off macOS); a wedged daemon escalation would only leave a marker file - see docs/wedge-alarm.md.'
    return 0
  fi
  if [ "$herdr" -eq 1 ] && ! command -v herdr >/dev/null 2>&1; then
    printf '%s\n' 'WARNING: config/wedge-alarm names the herdr channel but herdr is not on PATH; a wedged daemon escalation may never reach the captain - see docs/wedge-alarm.md.'
  fi
}

cmd_session_start() {
  local lock_diag ensure_out warn summary
  cat >/dev/null 2>&1 || true
  mkdir -p "$STATE" 2>/dev/null || true
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

  # The pane check comes first so a refused launch never leaves a lock behind.
  if ! supervisor_pane_addressable; then
    emit_block "Firstmate on Devin: this primary is not inside a tmux or Herdr pane the daemon can supervise (no TMUX_PANE, no Herdr pane id, no FM_SUPERVISOR_TARGET). Relaunch it inside tmux or Herdr, for example through config/devin-firstmate.sh."
  fi

  if ! lock_diag=$("$SCRIPT_DIR/fm-lock.sh" 2>&1); then
    emit_block "Firstmate on Devin: this session could not take this home's session lock ($lock_diag). If another firstmate session owns this home, exit it first."
  fi

  if ! ensure_out=$(cmd_ensure 2>&1); then
    emit_block "Firstmate on Devin: the quiet daemon could not be started - there is no other supervision path on this harness. fm-afk-launch reported: $ensure_out"
  fi
  # ensure_out holds its own stdout plus stderr; keep only the success line.
  ensure_out=$(printf '%s\n' "$ensure_out" | grep 'quiet daemon running' | tail -n 1)
  [ -n "$ensure_out" ] || ensure_out='quiet daemon running'

  warn=$(wedge_alarm_warnings)

  summary="Firstmate on Devin: lock acquired; $ensure_out."
  [ -n "$warn" ] && summary="$summary $warn"
  summary="$summary Run bin/fm-session-start.sh now, once."
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "$summary" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
  else
    printf '%s\n' "$summary"
  fi
  printf '%s\n' "$summary" >&2
  exit 0
}

# Per-turn block counter, keyed on the Stop payload's prompt_id so a new turn
# gets a fresh budget; prune files older than a day.
devin_stop_counter_prune() {
  [ -d "$STATE" ] || return 0
  find "$STATE" -maxdepth 1 -name '.devin-stop-blocks.*' -mtime +0 -delete 2>/dev/null || true
}

cmd_stop() {
  local payload prompt_id counter count max_blocks heal heal_note guard_out reason
  payload=$(cat 2>/dev/null || true)
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || exit 0

  if command -v jq >/dev/null 2>&1; then
    prompt_id=$(printf '%s' "$payload" | jq -r '.prompt_id // .session_id // "unknown"' 2>/dev/null || printf 'unknown')
  else
    prompt_id=unknown
  fi
  prompt_id=$(printf '%s' "$prompt_id" | tr -cd 'A-Za-z0-9._-')
  [ -n "$prompt_id" ] || prompt_id=unknown

  devin_stop_counter_prune
  max_blocks=${FM_DEVIN_STOP_MAX_BLOCKS:-3}
  case "$max_blocks" in ''|*[!0-9]*|0) max_blocks=3 ;; esac
  counter="$STATE/.devin-stop-blocks.$prompt_id"
  count=$(cat "$counter" 2>/dev/null || printf '0')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -lt "$max_blocks" ] || exit 0

  # Self-heal once per stop: a missing daemon is exactly the failure the Stop
  # hook exists to restart, and the attempt result rides in the block reason.
  heal=
  heal_note=
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_afk_daemon_owns_supervision "$STATE"; then
    if heal=$(cmd_ensure 2>&1); then
      heal_note="quiet daemon restart attempt: $heal. "
      printf 'fm-devin-primary stop: %s\n' "$heal" >&2
    else
      heal_note="quiet daemon restart attempt FAILED: $heal. "
      printf 'fm-devin-primary stop: ensure failed: %s\n' "$heal" >&2
    fi
  fi

  guard_out=$(printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh" --devin 2>/dev/null || true)
  if [ -z "$guard_out" ]; then
    rm -f "$counter" 2>/dev/null || true
    exit 0
  fi
  printf '%s\n' "$((count + 1))" > "$counter" 2>/dev/null || true
  if [ -n "$heal_note" ] && command -v jq >/dev/null 2>&1; then
    reason=$(printf '%s' "$guard_out" | jq -r 'if type == "object" then (.reason // "") else "" end' 2>/dev/null || true)
    [ -n "$reason" ] && guard_out=$(jq -cn --arg r "$heal_note$reason" '{decision:"block",reason:$r}')
  fi
  printf '%s\n' "$guard_out"
  exit 0
}

cmd_session_end() {
  cat >/dev/null 2>&1 || true
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" 2>/dev/null || exit 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" 2>/dev/null || exit 0
  "$SCRIPT_DIR/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
  exit 0
}

case "${1:-}" in
  ensure) cmd_ensure ;;
  session-start) cmd_session_start ;;
  stop) cmd_stop ;;
  session-end) cmd_session_end ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
