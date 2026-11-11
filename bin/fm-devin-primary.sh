#!/usr/bin/env bash
# fm-devin-primary.sh - the single owner of a Devin primary's hook mechanics:
# the quiet-daemon ensure, and the SessionStart / Stop / SessionEnd hook
# entrypoints a Devin primary registers in its own Devin config. The config
# shape and launch command are documented in docs/configuration.md "Devin
# primary", with a copyable placeholder config in
# docs/examples/devin-primary-config.json.
#
# A Devin primary is ALWAYS daemon-supervised: Devin cannot be woken from
# inside the model, so the quiet-mode daemon (bin/fm-supervise-daemon.sh,
# launched through bin/fm-afk-launch.sh) runs the watcher outside the model and
# types wakes into the primary's pane. The supervision protocol this enforces
# lives in docs/supervision-protocols/devin.md; the turn-end predicate lives in
# bin/fm-turnend-guard.sh --devin.
#
# Subcommands:
#   ensure        Make sure daemon supervision is up for this home and this
#                 pane. If state/.afk and its record already exist, run
#                 bin/fm-afk-launch.sh start --replace-mismatched (which reads
#                 the record's mode, so an existing away record stays away).
#                 Otherwise run `FM_AFK_MODE=quiet bin/fm-afk-launch.sh enter`
#                 then that `start`. --replace-mismatched restarts a live
#                 daemon left behind for another pane or primary harness (a
#                 crashed Devin, a Claude primary's quiet daemon) without
#                 ending the posture, so wakes never go to a dead pane.
#                 While the away return's catch-up gate
#                 (state/.afk-return-catchup) is pending, fm-afk-launch refuses
#                 every entry, so ensure exits 3 with a line naming
#                 bin/fm-afk-return.sh check instead of launching.
#                 Then verify a live identity-matched daemon holds this home
#                 (fm_afk_daemon_owns_supervision, bin/fm-wake-lib.sh - the
#                 same predicate the turn-end guard uses). Exit 0 with one line
#                 "<mode> daemon running: pid N supervising pane P", where
#                 <mode> is the record's real mode (fm_afk_mode) and P the
#                 captain pane the daemon terminal record names; non-zero with
#                 fm-afk-launch's diagnostic otherwise.
#   session-start Devin SessionStart hook. Reads the event JSON on stdin
#                 (source: startup|resume). Outside a genuine primary checkout
#                 (fm_primary_scope_matches, bin/fm-primary-scope-lib.sh) it is
#                 a silent no-op. Otherwise it takes the session lock through
#                 bin/fm-lock.sh (this hook is a child of the devin process, so
#                 the ancestry walk finds it), refuses the session with a
#                 "decision":"block" when the lock is held by another live
#                 session or the primary is not inside an addressable tmux or
#                 Herdr pane, runs `ensure` (a pending away-return catch-up
#                 gate admits the session with that gate's instruction instead
#                 of a daemon), warns (never blocks) when
#                 config/wedge-alarm names no reachable channel, and injects
#                 the result as SessionStart additionalContext that ends with
#                 "Run bin/fm-session-start.sh now, once." The same summary
#                 goes to stderr.
#   stop          Devin Stop hook. Reads the event JSON on stdin
#                 (prompt_id, session_id, stop_hook_active). Silent outside a
#                 genuine primary or when this session does not own the lock
#                 (fm_session_lock_owned_by_self). Self-heals once per stop:
#                 when no live identity-matched daemon holds this home it runs
#                 `ensure` and logs the result to stderr; a successful restart
#                 has just proved a live daemon, so that stop is allowed
#                 without waiting for the new watcher's first beacon.
#                 Otherwise it pipes the payload to
#                 `bin/fm-turnend-guard.sh --devin` and passes a returned block
#                 object through, prefixed with the ensure outcome when
#                 self-heal ran: a pending away-return catch-up gate names
#                 `bin/fm-afk-return.sh check` as the unblock action, since no
#                 daemon can start until that gate clears. The guard owns the per-turn block cap
#                 (state/.turnend-blocks keyed on prompt_id,
#                 FM_TURNEND_MAX_BLOCKS), so a persistently unhealthy daemon
#                 can never wedge the session.
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

cmd_ensure() {
  local out
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if [ -e "$STATE/.afk-return-catchup" ]; then
    echo "away return catch-up is pending, so the daemon stays down until its gate clears: work the return brief and run bin/fm-afk-return.sh check; quiet daemon supervision restarts at the next Stop after that" >&2
    return 3
  fi
  if [ -e "$STATE/.afk" ] && [ -f "$STATE/.afk-contract" ]; then
    # Same posture: a buffer left by a daemon that died or is being replaced
    # holds wakes it acked but never delivered; the restarted daemon owns them.
    if ! out=$("$SCRIPT_DIR/fm-afk-launch.sh" start --replace-mismatched --keep-escalations 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
  else
    if ! out=$(FM_AFK_MODE=quiet "$SCRIPT_DIR/fm-afk-launch.sh" enter 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
    if ! out=$(FM_AFK_MODE=quiet "$SCRIPT_DIR/fm-afk-launch.sh" start --replace-mismatched 2>&1); then
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
  target=$(cut -f4 "$STATE/.afk-daemon-terminal" 2>/dev/null)
  [ -n "$target" ] || target=unknown
  printf '%s daemon running: pid %s supervising pane %s\n' "$(fm_afk_mode "$STATE")" "$pid" "$target"
}

# Print one warning line when no configured wedge-alarm channel can reach the
# captain, or nothing. Mirrors the channel parsing owned by
# wedge_alarm_configured_channels / wedge_alarm_notify in
# bin/fm-supervise-daemon.sh: FM_WEDGE_ALARM_CHANNEL wins (one directive), else
# the non-empty non-comment lines of config/wedge-alarm, else "auto"; any `off`
# directive, in any position, disables every channel.
wedge_alarm_warnings() {
  local ch line found='' off=0 herdr=0 other=0
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
      auto|default) ;;
      herdr) herdr=1 ;;
      *) other=1 ;;
    esac
  done <<EOF
$found
EOF
  if [ "$off" -eq 1 ]; then
    printf '%s\n' 'WARNING: config/wedge-alarm disables every wedge-alarm channel; if the daemon cannot deliver an escalation nobody is notified - see docs/wedge-alarm.md.'
    return 0
  fi
  if [ "$other" -eq 0 ] && [ "$herdr" -eq 0 ] && [ "$(uname)" != Darwin ]; then
    printf '%s\n' 'WARNING: config/wedge-alarm names no working channel on this platform (auto is none off macOS); a wedged daemon escalation would only leave a marker file - see docs/wedge-alarm.md.'
    return 0
  fi
  if [ "$herdr" -eq 1 ] && ! command -v herdr >/dev/null 2>&1; then
    printf '%s\n' 'WARNING: config/wedge-alarm names the herdr channel but herdr is not on PATH; a wedged daemon escalation may never reach the captain - see docs/wedge-alarm.md.'
  fi
}

cmd_session_start() {
  local lock_diag ensure_out ensure_rc warn summary
  cat >/dev/null 2>&1 || true
  mkdir -p "$STATE" 2>/dev/null || true
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

  # The pane check comes first so a refused launch never leaves a lock behind.
  if ! supervisor_pane_addressable; then
    emit_block "Firstmate on Devin: this primary is not inside a tmux or Herdr pane the daemon can supervise (no TMUX_PANE, no Herdr pane id, no FM_SUPERVISOR_TARGET). Relaunch it as \`devin --config <path-to-primary-config.json>\` from inside a tmux pane or Herdr tab in the firstmate home - see docs/configuration.md \"Devin primary\"."
  fi

  if ! lock_diag=$("$SCRIPT_DIR/fm-lock.sh" 2>&1); then
    emit_block "Firstmate on Devin: this session could not take this home's session lock ($lock_diag). If another firstmate session owns this home, exit it first."
  fi

  ensure_out=$(cmd_ensure 2>&1)
  ensure_rc=$?
  case "$ensure_rc" in
    0)
      # ensure_out holds its own stdout plus stderr; keep only the success line.
      ensure_out=$(printf '%s\n' "$ensure_out" | grep ' daemon running: ' | tail -n 1)
      [ -n "$ensure_out" ] || ensure_out='daemon running'
      ;;
    3) ;;
    *) emit_block "Firstmate on Devin: the quiet daemon could not be started - there is no other supervision path on this harness. fm-afk-launch reported: $ensure_out" ;;
  esac

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

cmd_stop() {
  local payload heal='' heal_rc guard_out reason
  payload=$(cat 2>/dev/null || true)
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || exit 0

  # Self-heal once per stop: a missing daemon is exactly the failure the Stop
  # hook exists to restart. A successful ensure has just verified a live
  # identity-matched daemon, so the stop is allowed before the new watcher's
  # first beacon; a refused or failed attempt rides in the block reason.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_afk_daemon_owns_supervision "$STATE"; then
    heal=$(cmd_ensure 2>&1)
    heal_rc=$?
    if [ "$heal_rc" -eq 0 ]; then
      printf 'fm-devin-primary stop: %s\n' "$heal" >&2
      exit 0
    fi
    if [ "$heal_rc" -eq 3 ]; then
      heal="SUPERVISION IS PAUSED: the away return's catch-up gate (state/.afk-return-catchup) is still pending, so no daemon or watcher runs and no wake reaches this pane. Run bin/fm-afk-return.sh check and work its blockers until the gate clears; ensure cannot start the daemon before then, and the next Stop after it clears restores quiet daemon supervision. "
    else
      heal="daemon restart attempt FAILED: ${heal:-no diagnostic}. "
    fi
    printf 'fm-devin-primary stop: %s\n' "$heal" >&2
  fi

  guard_out=$(printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh" --devin 2>/dev/null || true)
  [ -n "$guard_out" ] || exit 0
  if [ -n "$heal" ] && command -v jq >/dev/null 2>&1; then
    reason=$(printf '%s' "$guard_out" | jq -r 'if type == "object" then (.reason // "") else "" end' 2>/dev/null || true)
    [ -n "$reason" ] && guard_out=$(jq -cn --arg r "$heal$reason" '{decision:"block",reason:$r}')
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
