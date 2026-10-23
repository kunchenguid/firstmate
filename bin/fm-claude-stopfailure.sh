#!/usr/bin/env bash
# Claude StopFailure supervision recovery (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a StopFailure command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code runs
# StopFailure INSTEAD of Stop when a turn ends in an API error (overloaded, rate
# limit, DNS failure, connection refused, the machine sleeping mid-response).
# Stop owns the turn-end guard and the watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh), so an API-error end of the handling turn that
# an actionable wake created leaves the home with no watcher, no re-arm, and no
# alarm until a human types again (issue #2940). This hook closes that gap
# without another model turn:
#
#   - Scope, identity, AFK, and need: exactly the auto-arm's gates. A child
#     worktree, a foreign session lock, an away home, an idle home, or a home
#     with a live identity-matched watcher and a fresh beacon exits 0 silently.
#   - Recovery: wait with bounded exponential backoff and probe the API
#     endpoint with a tokenless reachability check (no model request), then exit
#     2 so the harness rewakes the idle session. The rewake handling turn runs
#     bin/fm-wake-drain.sh, and its ordinary Stop re-arms the watcher through the
#     auto-arm, which stays the only arm owner. Claude delivers the exit 2 of a
#     StopFailure asyncRewake hook to an idle session (measured on Claude Code
#     2.1.308, docs/verification/supervision.md), despite the hooks reference
#     calling StopFailure output ignored.
#   - No loop: state/.claude-stopfailure-episode counts the rewakes this
#     hook delivered since the last clean Stop. Each rewake waits twice as long as
#     the one before, up to the backoff cap. A clean Stop by the owning session (the
#     auto-arm removes the record) ends the episode and makes a still-waiting
#     hook stand down, and a newer StopFailure supersedes an older waiting one by
#     taking the next generation.
#   - Alert: an episode that has gone FM_GUARD_GRACE seconds without a clean
#     Stop, or whose error needs a human (authentication, billing), publishes the
#     typed downtime recovery episode (state/.watcher-down, which the next drain
#     presents as WATCHER DOWN) and raises one active alert through the
#     config/wedge-alarm channels (bin/fm-wedge-alarm-lib.sh), repeated at most
#     once per FM_STOPFAILURE_REALERT_SECS while the session stays down.
#     docs/wedge-alarm.md owns the channel contract.
#
# It never prints to stdout: exit 0 is silent, and exit 2 carries the rewake
# banner on stderr. On any uncertainty it exits 0 and leaves continuity to the
# next Stop and the alert.
#
# Environment (tests and tuning):
#   FM_GUARD_GRACE                 seconds before an unrecovered episode alerts
#   FM_STOPFAILURE_BACKOFF_BASE    first backoff in seconds (default 10)
#   FM_STOPFAILURE_BACKOFF_CAP     longest backoff in seconds (default 300)
#   FM_STOPFAILURE_MAX_WAIT        seconds one firing waits before standing down,
#                                  below the registered hook timeout (default 28000);
#                                  after an unrecovered wait the alert has fired
#                                  and the session waits for a human message
#   FM_STOPFAILURE_REALERT_SECS    minimum seconds between alerts (default 3600)
#   FM_STOPFAILURE_PROBE_CMD       reachability seam: a shell command whose exit 0
#                                  means the API is reachable (default: curl
#                                  against ANTHROPIC_BASE_URL or the public API)
#
# The hook passes no arguments, so any argument means a manual run: -h or --help
# prints usage and an unknown argument is refused, both before anything is read.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stopfailure.sh

Claude StopFailure hook registered in .claude/settings.json; not for manual use.
It reads the StopFailure payload on stdin and, in a primary home that needs
supervision, waits for the API to return and rewakes the session, or alerts the
captain through config/wedge-alarm.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EPISODE="$STATE/.claude-stopfailure-episode"
LOG="$STATE/.claude-stopfailure.log"
WEDGE_ALARM_TITLE="firstmate: supervision is OFF"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"

GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Positive integer from env var $1, else default $2.
num_env() {
  local value=${!1:-}
  case "$value" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) printf '%s' "$value" ;;
  esac
}
BACKOFF_BASE=$(num_env FM_STOPFAILURE_BACKOFF_BASE 10)
BACKOFF_CAP=$(num_env FM_STOPFAILURE_BACKOFF_CAP 300)
MAX_WAIT=$(num_env FM_STOPFAILURE_MAX_WAIT 28000)
REALERT_SECS=$(num_env FM_STOPFAILURE_REALERT_SECS 3600)

# Diagnostic trail for the alert channels and decisions, capped so a long outage
# cannot grow it without bound. wedge_alarm_notify reports channel failures
# through this function.
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
  fi
}

# Consume the payload once so a slow writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor and pi-code load the tracked Claude settings, have no asyncRewake, and
# would await this hook inside their own turn end, so a long wait here would hold
# that turn open (the wedge docs/turnend-guard.md records for the Stop auto-arm).
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_hook_payload_is_pi_code "$PAYLOAD" && exit 0

# --- scope and identity: the auto-arm's gates ---------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$STATE/.afk" ] && exit 0
fm_supervision_needed "$STATE" "$GRACE" || exit 0

ensure_session_owner() {
  fm_session_lock_owned_by_self "$STATE" && return 0
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = stale ] || return 1
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || return 1
  fm_session_lock_owned_by_self "$STATE"
}
ensure_session_owner || exit 0
TRUSTED_SESSION=$(fm_session_lock_trusted_session_id 2>/dev/null || true)
SESSION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
DEADLINE_CHECK=0
EPISODE_LOCK="$STATE/.claude-stopfailure-update.lock"
if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
  exit 0
fi

# --- error class ----------------------------------------------------------------
ERROR_TYPE=unknown
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  ERROR_TYPE=$(printf '%s' "$PAYLOAD" | jq -r '.error // "unknown" | tostring' 2>/dev/null || printf unknown)
fi
case "$ERROR_TYPE" in
  ''|*[!A-Za-z0-9_-]*) ERROR_TYPE=unknown ;;
esac
# Waiting cannot fix a credential or billing failure, so those alert at once.
NEEDS_HUMAN=0
case "$ERROR_TYPE" in
  authentication_failed|billing_error) NEEDS_HUMAN=1 ;;
esac

# --- episode record ---------------------------------------------------------------
# session=<session id> first=<epoch of first failure> attempts=<rewakes delivered>
# alerted=<epoch of last alert, 0 = never> gen=<claim generation>
NOW=$(date +%s)
# The episode belongs to one Claude session: its id is stable across the handling
# turns this hook rewakes, while the harness pid is the fallback for a payload
# without one.
SESSION_KEY=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SESSION_KEY=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty | tostring' 2>/dev/null || true)
fi
case "$SESSION_KEY" in
  ''|*[!A-Za-z0-9._-]*) SESSION_KEY=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true) ;;
esac

episode_get() {  # <key>
  sed -n "s/^$1=//p" "$EPISODE" 2>/dev/null | head -n 1
}

episode_write() {  # <first> <attempts> <alerted> <gen>
  local tmp
  tmp=$(mktemp "$STATE/.claude-stopfailure-episode.XXXXXX") || return 1
  if printf 'session=%s\nfirst=%s\nattempts=%s\nalerted=%s\ngen=%s\n' \
    "$SESSION_KEY" "$1" "$2" "$3" "$4" > "$tmp"; then
    mv -f "$tmp" "$EPISODE" && return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

fm_lock_acquire_wait "$EPISODE_LOCK"
FIRST=$NOW
ATTEMPTS=0
ALERTED=0
GEN=0
# A record from another session (or a corrupt one) is a different episode.
if [ -f "$EPISODE" ] && [ "$(episode_get session)" = "$SESSION_KEY" ]; then
  FIRST=$(episode_get first)
  ATTEMPTS=$(episode_get attempts)
  ALERTED=$(episode_get alerted)
  GEN=$(episode_get gen)
  case "$FIRST$ATTEMPTS$ALERTED$GEN" in
    ''|*[!0-9]*) FIRST=$NOW; ATTEMPTS=0; ALERTED=0; GEN=0 ;;
  esac
fi
MY_GEN=$((GEN + 1))
episode_write "$FIRST" "$ATTEMPTS" "$ALERTED" "$MY_GEN" || { fm_lock_release "$EPISODE_LOCK"; exit 0; }
fm_lock_release "$EPISODE_LOCK"

# True while this firing still owns the episode: the record exists with this
# generation (a clean Stop removes it, a newer StopFailure replaces it).
still_owner() {
  [ "$(episode_get session)" = "$SESSION_KEY" ] || return 1
  [ "$(episode_get first)" = "$FIRST" ] || return 1
  [ "$DEADLINE_CHECK" -eq 1 ] || [ "$(episode_get gen)" = "$MY_GEN" ]
}

# True while this firing should keep working: the same conditions the gates above
# checked, re-verified because the wait spans minutes to hours.
still_needed() {
  still_owner || return 1
  [ ! -e "$STATE/.afk" ] || return 1
  if [ "$DEADLINE_CHECK" -eq 1 ]; then
    if [ -n "$TRUSTED_SESSION" ]; then
      [ "$(fm_session_lock_recorded_session_id "$STATE")" = "$TRUSTED_SESSION" ] || return 1
    else
      [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$SESSION_PID" ] || return 1
    fi
  else
    ensure_session_owner || return 1
  fi
  fm_supervision_needed "$STATE" "$GRACE" || return 1
  ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"
}

# Rewrite the episode with new counters, only while this firing still owns it.
episode_update() {
  local status=1
  fm_lock_acquire_wait "$EPISODE_LOCK"
  if still_owner; then
    ATTEMPTS=$(( $(episode_get attempts) + 1 ))
    ALERTED=$(episode_get alerted)
    episode_write "$FIRST" "$ATTEMPTS" "$ALERTED" "$MY_GEN" && status=0
  fi
  fm_lock_release "$EPISODE_LOCK"
  return "$status"
}

# --- alert ----------------------------------------------------------------------
raise_alert() {  # <reason>
  local reason=$1 now summary marker="$STATE/.watcher-down"
  fm_lock_acquire_wait "$EPISODE_LOCK"
  if ! still_needed; then
    fm_lock_release "$EPISODE_LOCK"
    return 0
  fi
  now=$(date +%s)
  ATTEMPTS=$(episode_get attempts)
  ALERTED=$(episode_get alerted)
  if [ "$ALERTED" -gt 0 ] && { [ "$DEADLINE_CHECK" -eq 1 ] || [ $((now - ALERTED)) -lt "$REALERT_SECS" ]; }; then
    fm_lock_release "$EPISODE_LOCK"
    return 0
  fi
  if ! episode_write "$FIRST" "$ATTEMPTS" "$now" "$(episode_get gen)"; then
    fm_lock_release "$EPISODE_LOCK"
    return 0
  fi
  ALERTED=$now
  fm_lock_release "$EPISODE_LOCK"
  fm_recovery_marker_publish "$marker" downtime >/dev/null 2>&1 || true
  log "alert: $reason (error=$ERROR_TYPE attempts=$ATTEMPTS)"
  summary="A Claude turn ended on an API error ($ERROR_TYPE) and firstmate supervision is OFF: $reason. Queued wakes are preserved; open the session to resume."
  wedge_alarm_notify "$summary" "$marker"
}

# --- reachability ---------------------------------------------------------------
# Tokenless: one HTTP request to the API endpoint, never a model request. Any
# response below 500 proves the endpoint answers (a 4xx for a bare GET is the
# normal reply); no response, a timeout, or a 5xx does not. A provider whose
# endpoint this hook cannot name (Bedrock, Vertex, Foundry), or a host without
# curl, cannot be probed, so it counts as reachable and bounded backoff paces recovery.
api_reachable() {
  local base code
  if [ -n "${FM_STOPFAILURE_PROBE_CMD:-}" ]; then
    sh -c "$FM_STOPFAILURE_PROBE_CMD" >/dev/null 2>&1
    return $?
  fi
  if [ -n "${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}${CLAUDE_CODE_USE_FOUNDRY:-}" ]; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 0
  base=${ANTHROPIC_BASE_URL:-https://api.anthropic.com}
  code=$(curl -s -o /dev/null --connect-timeout 5 -m 10 -w '%{http_code}' "$base" 2>/dev/null) || return 1
  case "$code" in
    [1-4][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- immediate cases ----------------------------------------------------------------
if [ "$NEEDS_HUMAN" -eq 1 ]; then
  raise_alert "the error needs the captain (waiting cannot fix it)"
  exit 0
fi

# --- recovery loop ------------------------------------------------------------------
START=$NOW
DELAY=$BACKOFF_BASE
i=0
while [ "$i" -lt "$ATTEMPTS" ] && [ "$DELAY" -lt "$BACKOFF_CAP" ]; do
  DELAY=$((DELAY * 2))
  i=$((i + 1))
done
[ "$DELAY" -le "$BACKOFF_CAP" ] || DELAY=$BACKOFF_CAP

# Sleep until epoch $1, in short steps so a clean Stop, a newer StopFailure, or a
# vanished need ends this wait promptly.
nap_until() {
  local until=$1 now step
  while :; do
    still_needed || return 1
    now=$(date +%s)
    [ "$now" -lt "$until" ] || return 0
    step=$((until - now))
    [ "$step" -le 5 ] || step=5
    sleep "$step"
  done
}

if [ "$GEN" -eq 0 ] && [ "$ALERTED" -eq 0 ]; then
  (
    trap '' HUP
    DEADLINE_CHECK=1
    ALERT_AT=$((FIRST + GRACE))
    while :; do
      still_owner || exit 0
      remaining=$((ALERT_AT - $(date +%s)))
      [ "$remaining" -gt 0 ] || break
      [ "$remaining" -le 5 ] || remaining=5
      sleep "$remaining"
    done
    raise_alert "the session did not recover within ${GRACE}s of the API error"
  ) </dev/null >/dev/null 2>&1 &
  disown "$!"
fi

while :; do
  WAKE_AT=$(( $(date +%s) + DELAY ))
  nap_until "$WAKE_AT" || exit 0
  [ $(( $(date +%s) - START )) -lt "$MAX_WAIT" ] || exit 0
  if api_reachable; then
    still_needed || exit 0
    [ "$(episode_get alerted)" = 0 ] || raise_alert "automatic resumes continue to end in API errors"
    episode_update || exit 0
    log "rewake: API reachable after error=$ERROR_TYPE (rewake $ATTEMPTS)"
    {
      printf 'firstmate Claude turn ended on an API error (%s) while supervision was needed, and the API answers again - this wake resumes the home.\n' "$ERROR_TYPE"
      printf 'Run bin/fm-wake-drain.sh first, handle every queued wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. This turn ending arms the next needed cycle through the Stop hook - do NOT run bin/fm-watch-arm.sh.\n'
    } >&2
    exit 2
  fi
  # Still down: keep the captain informed at the rate limit, then back off.
  [ "$(episode_get alerted)" = 0 ] || raise_alert "the API is still unreachable"
  DELAY=$((DELAY * 2))
  [ "$DELAY" -le "$BACKOFF_CAP" ] || DELAY=$BACKOFF_CAP
done
