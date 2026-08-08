#!/usr/bin/env bash
# Cursor Stop-hook adapter for a firstmate primary or secondmate turn-end guard.
#
# Cursor's `stop` hook does not honour exit code 2 as a forced continuation.
# A stop hook that exits 2 with a rendered stderr banner simply ends the turn,
# so the shared guard's blind-turn signal must be translated into the mechanism
# cursor does honour: a JSON body on stdout with a `followup_message`.
#
# This adapter is a thin translation layer over the shared hook-arm primitive
# (bin/fm-hook-arm-lib.sh). It parses the Cursor payload, calls the canonical
# arm+classify operation, applies a bounded continuation counter, and renders
# the outcome as {} or a followup_message. The arm lifecycle, actionable-wake
# classification, and healthy-watcher verification are owned once by the
# shared primitive.
#
# docs/supervision-protocols/cursor.md is the single owner of the counter
# algorithm: chain keys, both budgets, what counts as progress, and how the
# ceilings clear. Read it before changing any bound here.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-hook-arm-lib.sh
. "$SCRIPT_DIR/fm-hook-arm-lib.sh"

MAX_BUDGET=1000000

clamp_digits() {  # <digits> <ceiling> -> <digits, saturated at ceiling>
  local value=$1 ceiling=$2
  while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = 0 ]; do
    value=${value#0}
  done
  if [ "${#value}" -gt "${#ceiling}" ] \
    || { [ "${#value}" -eq "${#ceiling}" ] && [[ "$value" -gt "$ceiling" ]]; }; then
    value=$ceiling
  fi
  printf '%s' "$value"
}

normalize_budget() {
  local value=$1 default=$2
  case "$value" in ''|*[!0-9]*|0) value=$default ;; esac
  value=$(clamp_digits "$value" "$MAX_BUDGET")
  [ "$value" != 0 ] || value=$default
  printf '%s' "$value"
}

BLOCK_BUDGET=$(normalize_budget "${FM_CURSOR_TURNEND_BLOCK_BUDGET:-3}" 3)
WAKE_BUDGET=$(normalize_budget "${FM_CURSOR_WAKE_CHAIN_BUDGET:-5}" 5)
TOTAL_BUDGET=$((BLOCK_BUDGET + WAKE_BUDGET))

# The shared guard always sees stop_hook_active false, so a continuation whose
# supervision need is real still re-arms. A malformed payload passes through
# unchanged so the guard's own validation decides.
NORMALIZED=$(printf '%s' "$PAYLOAD" | jq -c '
  if type != "object" then . else . + {stop_hook_active: false, stopHookActive: false} end
' 2>/dev/null) || NORMALIZED=$PAYLOAD

ROOT=${CURSOR_WORKSPACE_ROOT:-${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}

# --- session identity derivation (Cursor-specific) ---------------------------

cursor_parent_identity() {
  local pid=${PPID:-} proc_root stat_line starttime
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null || true)
    read -r -a stat_fields <<< "${stat_line##*)}"
    if [ "${#stat_fields[@]}" -ge 20 ]; then
      starttime=${stat_fields[19]}
      case "$starttime" in
        ''|*[!0-9]*) ;;
        *) printf 'proc:%s:%s' "$pid" "$starttime"; return 0 ;;
      esac
    fi
  fi
  starttime=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  if [ -n "$starttime" ]; then
    printf 'ps:%s:%s' "$pid" "$starttime"
    return 0
  fi
  return 1
}

SESSION=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then empty
  elif (.conversation_id | type) == "string" and .conversation_id != "" then .conversation_id
  elif (.session_id | type) == "string" and .session_id != "" then .session_id
  else empty end
' 2>/dev/null) || SESSION=
if [ -z "$SESSION" ] && [ -n "${CURSOR_CONVERSATION_ID:-}" ]; then
  SESSION=$CURSOR_CONVERSATION_ID
fi
if [ -z "$SESSION" ]; then
  SESSION_SCOPE=$(printf '%s' "$PAYLOAD" | jq -cS '
    if type != "object" then .
    else del(.loop_count, .stop_hook_active, .stopHookActive) end
  ' 2>/dev/null) || SESSION_SCOPE=
  SESSION_TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '
    if type == "object" and (.transcript_path | type) == "string" and .transcript_path != ""
    then .transcript_path else empty end
  ' 2>/dev/null) || SESSION_TRANSCRIPT=
  if [ -z "$SESSION_TRANSCRIPT" ]; then
    if SESSION_PARENT=$(cursor_parent_identity); then
      SESSION_SCOPE=$(printf '%s\037%s' "$SESSION_PARENT" "$SESSION_SCOPE")
    fi
  fi
  SESSION_KEY=$(printf '%s\037%s' "$ROOT" "$SESSION_SCOPE" \
    | cksum 2>/dev/null | awk '{print $1 ":" $2}')
  [ -n "$SESSION_KEY" ] || SESSION_KEY="root:$ROOT"
  SESSION="fallback:$SESSION_KEY"
fi
SESSION_KEY=$(printf '%s' "$SESSION" | cksum 2>/dev/null | awk '{print $1 ":" $2}')
[ -n "$SESSION_KEY" ] || SESSION_KEY="root:$ROOT"
CHAIN_FILE="$STATE/.cursor-turnend-chain-$SESSION_KEY"
LOOP_COUNT_VALUE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and has("loop_count")
     and ((.loop_count | type) == "number") and .loop_count >= 0
     and .loop_count == (.loop_count | floor)
  then .loop_count else empty end
' 2>/dev/null) || LOOP_COUNT_VALUE=
LOOP_COUNT=0
LOOP_COUNT_VALID=0
case "$LOOP_COUNT_VALUE" in
  ''|*[!0-9]*) ;;
  *) LOOP_COUNT=$LOOP_COUNT_VALUE; LOOP_COUNT_VALID=1 ;;
esac
LOOP_COUNT_POSITIVE=0
case "$LOOP_COUNT" in *[1-9]*) LOOP_COUNT_POSITIVE=1 ;; esac

CHAIN_SESSION=
CHAIN_TOTAL=0
CHAIN_FAIL=0
CHAIN_WAKE=0
CHAIN_REASON=
CHAIN_REASONS=()
CHAIN_HAS_REASONS=0

normalize_counter() {
  local value=$1
  case "$value" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  clamp_digits "$value" "$TOTAL_BUDGET"
}

chain_load() {
  local key value
  [ -f "$CHAIN_FILE" ] || { CHAIN_TOTAL=0; return 0; }
  CHAIN_TOTAL=
  CHAIN_REASONS=()
  CHAIN_HAS_REASONS=0
  while IFS='=' read -r key value; do
    case "$key" in
      session) CHAIN_SESSION=$value ;;
      total) CHAIN_TOTAL=$value ;;
      fail) CHAIN_FAIL=$value ;;
      wake) CHAIN_WAKE=$value ;;
      reason) CHAIN_REASON=$(fm_hook_arm_canonical_reason "$value") ;;
      wake_reason)
        value=$(fm_hook_arm_canonical_reason "$value")
        CHAIN_REASONS+=("$value")
        CHAIN_HAS_REASONS=1
        ;;
    esac
  done < "$CHAIN_FILE"
  CHAIN_FAIL=$(normalize_counter "$CHAIN_FAIL")
  CHAIN_WAKE=$(normalize_counter "$CHAIN_WAKE")
  case "$CHAIN_TOTAL" in ''|*[!0-9]*) CHAIN_TOTAL=$((CHAIN_FAIL + CHAIN_WAKE)) ;; esac
  CHAIN_TOTAL=$(normalize_counter "$CHAIN_TOTAL")
  if [ "$CHAIN_HAS_REASONS" -eq 0 ] && [ -n "$CHAIN_REASON" ]; then
    CHAIN_REASONS=("$CHAIN_REASON")
  fi
  if [ "$CHAIN_SESSION" != "$SESSION" ] || {
    [ "$LOOP_COUNT_VALID" -eq 1 ] && [ "$LOOP_COUNT" = 0 ];
  }; then
    CHAIN_TOTAL=0
    CHAIN_FAIL=0
    CHAIN_WAKE=0
    CHAIN_REASON=
    CHAIN_REASONS=()
  fi
}

chain_store() {
  local tmp
  [ -d "$STATE" ] || return 1
  tmp="$CHAIN_FILE.$$"
  if ! {
    printf 'session=%s\ntotal=%s\nfail=%s\nwake=%s\nreason=%s\n' \
      "$SESSION" "$1" "$2" "$3" "$4"
    if [ "${#CHAIN_REASONS[@]}" -gt 0 ]; then
      printf 'wake_reason=%s\n' "${CHAIN_REASONS[@]}"
    fi
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$CHAIN_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

fallback_total_from_loop_count() {
  local value
  value=$(clamp_digits "$1" "$TOTAL_BUDGET")
  if [ "$value" = "$TOTAL_BUDGET" ]; then
    printf '%s' "$TOTAL_BUDGET"
  else
    printf '%s' "$((value + 1))"
  fi
}

allow_stop() {
  local reason
  rm -f "$CHAIN_FILE" 2>/dev/null || true
  if reason=$(fm_hook_arm_interrupted_park_reason "$STATE"); then
    jq -cn --arg msg "$reason" '{followup_message:$msg}'
    exit 0
  fi
  printf '{}\n'
  exit 0
}

chain_load

if ! ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX"); then
  ERR="$STATE/.cursor-turnend-error.$$"
  if ! : > "$ERR" 2>/dev/null; then
    printf '{"followup_message":"TURN WOULD END BLIND: Cursor stop-hook supervision could not allocate temporary state. Repair .cursor/hooks.json registration and watcher startup before ending blind."}\n'
    exit 0
  fi
fi
ARM_OUT=
ARM_ACTIONABLE=0
WAKE_REASON=
ARM_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor-arm.XXXXXX") || ARM_OUT=
trap 'rm -f "$ERR" "$ARM_OUT"' EXIT

printf '%s' "$NORMALIZED" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || allow_stop

# --- canonical arm + classify (shared primitive) -----------------------------
# shellcheck source=/dev/null
[ -f "$ROOT/config/x-mode.env" ] && . "$ROOT/config/x-mode.env"
if [ -n "$ARM_OUT" ]; then
  fm_hook_arm_foreground "$STATE" "$ARM_OUT"
  cat "$ARM_OUT" >&2
  if fm_hook_arm_has_actionable "$ARM_OUT"; then
    WAKE_REASON=$(fm_hook_arm_wake_reason "$ARM_OUT")
    WAKE_REASON=$(fm_hook_arm_canonical_reason "$WAKE_REASON")
    ARM_ACTIONABLE=1
  fi
else
  fm_hook_arm_foreground "$STATE" /dev/null
fi

# Re-run the guard against the post-arm state: a healthy watcher or vanished
# need allows the turn; an actionable arm close needs a wake even though no
# watcher remains; only an arm failure or untyped close keeps the blind banner.
printf '%s' "$NORMALIZED" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || allow_stop

# --- bounded continuation counter (Cursor-specific) --------------------------
if [ "$ARM_ACTIONABLE" -eq 1 ]; then
  if [ "$WAKE_REASON" = "$CHAIN_REASON" ]; then
    COUNT=$((CHAIN_WAKE + 1))
  else
    COUNT=1
  fi
  WAKE_SEEN=0
  if [ "${#CHAIN_REASONS[@]}" -gt 0 ]; then
    for KNOWN_REASON in "${CHAIN_REASONS[@]}"; do
      if [ "$KNOWN_REASON" = "$WAKE_REASON" ]; then
        WAKE_SEEN=1
        break
      fi
    done
  fi
  TOTAL=$CHAIN_TOTAL
  if [ "$WAKE_SEEN" -eq 1 ]; then
    TOTAL=$((TOTAL + 1))
  else
    CHAIN_REASONS+=("$WAKE_REASON")
  fi
  if ! chain_store "$TOTAL" 0 "$COUNT" "$WAKE_REASON"; then
    if [ "$LOOP_COUNT_POSITIVE" -eq 1 ]; then
      FALLBACK_TOTAL=$(fallback_total_from_loop_count "$LOOP_COUNT")
      [ "$FALLBACK_TOTAL" -gt "$TOTAL" ] && TOTAL=$FALLBACK_TOTAL
    else
      TOTAL=$TOTAL_BUDGET
    fi
  fi
  if [ "$TOTAL" -ge "$TOTAL_BUDGET" ]; then
    rm -f "$CHAIN_FILE" 2>/dev/null || true
    REASON="firstmate watcher wake - the bounded stop-hook chain reached its diagnostic ceiling. Run bin/fm-wake-drain.sh first, handle the wake, and investigate the repeated supervision cycle."
  elif [ "$COUNT" -gt "$WAKE_BUDGET" ]; then
    rm -f "$CHAIN_FILE" 2>/dev/null || true
    REASON="firstmate watcher wake - the same wake reason has now repeated $COUNT times without clearing. Run bin/fm-wake-drain.sh first, handle the wake, and investigate why it keeps re-firing."
  else
    REASON='firstmate watcher wake - one supervision event needs a handling turn now. Run bin/fm-wake-drain.sh first and handle the wake. Stop-hook-owned continuity re-arms the next needed cycle automatically; do not manually arm the watcher.'
  fi
else
  COUNT=$((CHAIN_FAIL + 1))
  TOTAL=$((CHAIN_TOTAL + 1))
  NEXT_FAIL=$COUNT
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] && NEXT_FAIL=0
  if ! chain_store "$TOTAL" "$NEXT_FAIL" 0 ''; then
    if [ "$LOOP_COUNT_POSITIVE" -eq 1 ]; then
      FALLBACK_TOTAL=$(fallback_total_from_loop_count "$LOOP_COUNT")
      [ "$FALLBACK_TOTAL" -gt "$TOTAL" ] && TOTAL=$FALLBACK_TOTAL
    else
      TOTAL=$TOTAL_BUDGET
    fi
  fi
  REASON=$(cat "$ERR" 2>/dev/null || true)
  [ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
  if [ "$TOTAL" -ge "$TOTAL_BUDGET" ]; then
    rm -f "$CHAIN_FILE" 2>/dev/null || true
    REASON="${REASON}"$'\n'"Cursor stop-hook arm still fails after the bounded chain. Repair .cursor/hooks.json registration and watcher startup before ending blind."
  elif [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
    REASON="${REASON}"$'\n'"Cursor stop-hook arm has failed repeatedly. Repair .cursor/hooks.json registration and watcher startup before ending blind."
  fi
fi
REASON=$(printf '%s' "$REASON" | tr '\n' ' ')
jq -cn --arg msg "$REASON" '{followup_message:$msg}'
exit 0
