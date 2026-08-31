#!/usr/bin/env bash
# AGY (Antigravity CLI) Stop-hook adapter for a firstmate PRIMARY session.
#
# Registered in the tracked .agents/hooks.json under the "Stop" event. AGY runs
# hook commands SYNCHRONOUSLY and blocks its execution loop while they run, with
# no asyncRewake flag, no exit-2 rewake channel, and no loop_limit. The only
# documented re-entry channel is the hook's stdout JSON: printing
# {"decision":"continue","reason":"<system message>"} re-enters the loop with
# the reason injected as a system message. This adapter therefore follows the
# notify-and-arm model, never a Cursor-style park:
#   1. scope to a genuine primary checkout (main home or marked secondmate home)
#      via bin/fm-primary-scope-lib.sh - child crew/scout task worktrees stay a
#      silent no-op;
#   2. when supervision is needed and no live watcher holds the home, run
#      bin/fm-watch-arm.sh in the FOREGROUND of this hook's process tree (never
#      a fire-and-forget shell `&`, whose child is reaped the moment the hook
#      returns), exactly as bin/fm-claude-stop-autoarm.sh does for Claude and
#      bin/fm-turnend-guard-cursor.sh does for Cursor;
#   3. when the arm closes with an actionable wake, print the wake as one
#      {"decision":"continue","reason":...} so the AGY session gets a handling
#      turn - the watcher's own wake is the notification, and continuing only on
#      a real wake keeps the loop bounded by real fleet events;
#   4. when the arm cannot establish a watcher, print one bounded repair notice
#      (FM_AGY_TURNEND_BLOCK_BUDGET per conversation) instead of ending blind;
#   5. every path exits 0 and prints exactly one JSON object on stdout - AGY has
#      no exit-2 channel, so the stdout object is the only decision surface.
#
# State markers owned here (all inert to the watcher's signal scan, which only
# reads *.status and *.turn-ended):
#   state/.agy-turnend-epoch   one-line record of this Stop event: outcome,
#                              conversation id, termination reason, fullyIdle.
#   state/.agy-turnend-blocks  consecutive repair-nag counter per conversation.
#
# The Stop payload carries `conversationId`, `fullyIdle`, `terminationReason`,
# and `executionNum` (verified from the AGY hooks contract). fullyIdle reports
# whether AGY's own background tasks are done; it is recorded, never gated on,
# because firstmate's watcher supervises the FLEET, not AGY's task list.
#
# See .agents/skills/harness-adapters/references/harness/agy.md for the harness
# contract and the live-probe checklist; docs/turnend-guard.md owns the shared
# turn-end guard semantics this adapter implements.
#
# Usage:
#   <Stop JSON on stdin> | bin/fm-turnend-guard-agy.sh
#
# Env overrides (all optional):
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE   - fixture/testing overrides
#   FM_GUARD_GRACE                                 - watcher freshness window (300)
#   FM_AGY_TURNEND_ATTEMPTS                        - bounded arm attempts (2)
#   FM_AGY_TURNEND_BLOCK_BUDGET                    - bounded repair nags (3)
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || { printf '{}\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }

# Strict payload extract: any malformed or mistyped field fails the whole
# extract and stands the guard down (exit 0, no arming).
CID=''
IDLE=''
TERM=''
read -r CID IDLE TERM <<EOF2
$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("conversationId") and ((.conversationId | type) != "string") then error("conversationId")
  elif has("fullyIdle") and ((.fullyIdle | type) != "boolean") then error("fullyIdle")
  elif has("terminationReason") and ((.terminationReason | type) != "string") then error("terminationReason")
  else
    [ (.conversationId // ""), ((.fullyIdle // false) | tostring), (.terminationReason // "") ]
    | @tsv
  end
' 2>/dev/null)
EOF2
[ -n "${CID:-}" ] && [ -n "${TERM:-}" ] && [ -n "${IDLE:-}" ] || { printf '{}\n'; exit 0; }
case "$CID" in ''|*[!A-Za-z0-9._-]*) CID=unknown ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=300 ;; esac
ATTEMPTS=${FM_AGY_TURNEND_ATTEMPTS:-2}
case "$ATTEMPTS" in 1|2|3) : ;; *) ATTEMPTS=2 ;; esac
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

# --- scope to a genuine PRIMARY checkout ------------------------------------
# A secondmate home runs its own primary session and is force-included by its
# marker; only unmarked linked task worktrees (crewmate/scout) stay inert. An
# inert worktree must exit before any marker write.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || { printf '{}\n'; exit 0; }

# --- session ownership -------------------------------------------------------
# AGY is not yet a verified harness for bin/fm-session-lock-lib.sh's ancestry
# walk, so use the same plain ancestry membership test bin/fm-sessionstart-nudge.sh
# uses. Stand down only for a LIVE lock held by a foreign process: that session
# owns arming. A live lock named by an ancestor of this hook, a dead lock, a
# malformed lock, or an absent lock all proceed, because a stale lock must not
# hold supervision down and the watcher's own singleton makes concurrent arming
# safe.
lock_held_by_foreign_session() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$lock_pid" ] && return 1
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  return 0
}
lock_held_by_foreign_session && { printf '{}\n'; exit 0; }

# --- diagnostics and bounded repair bookkeeping ------------------------------

record_marker() {  # <outcome>
  local outcome=$1 tmp detail
  detail="outcome=$outcome conversation=$CID termination=$TERM fully_idle=$IDLE"
  tmp="$STATE/.agy-turnend-epoch.tmp.$$"
  printf '%s\n' "$detail" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATE/.agy-turnend-epoch" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

BUDGET_COUNT=0
budget_read() {
  local conversation count
  BUDGET_COUNT=0
  [ -f "$STATE/.agy-turnend-blocks" ] || return 0
  conversation=$(sed -n '1s/^conversation=//p' "$STATE/.agy-turnend-blocks" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$STATE/.agy-turnend-blocks" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$conversation" = "$CID" ] && BUDGET_COUNT=$count
}

budget_write() {  # <count>
  local tmp="$STATE/.agy-turnend-blocks.tmp.$$"
  printf 'conversation=%s\ncount=%s\n' "$CID" "$1" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATE/.agy-turnend-blocks" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

budget_reset() {
  rm -f "$STATE/.agy-turnend-blocks" 2>/dev/null || true
}

# --- decide whether a watcher is needed --------------------------------------
# Away mode owns the watcher and its own triage; never arm and never wake.
if [ -e "$STATE/.afk" ]; then
  record_marker afk
  printf '{}\n'
  exit 0
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset
  record_marker no-need
  printf '{}\n'
  exit 0
fi

if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
  budget_reset
  record_marker healthy
  printf '{}\n'
  exit 0
fi

# --- the arm -----------------------------------------------------------------
# The arm runs as a tracked child of THIS hook process and stays alive for its
# whole cycle - never a fire-and-forget shell `&`, whose child would be reaped
# the moment the hook returned, leaving no watcher. A genuine wake is productive
# work, so it does not consume the repair budget: a wake delivery resets the
# counter; only consecutive unproductive repair nags are bounded.

emit_continue() {  # <encoded-body>
  local body=$1 response
  response=$(jq -cn --arg r "$body" '{decision:"continue",reason:$r}' 2>/dev/null) || { printf '{}\n'; exit 0; }
  printf '%s\n' "$response"
  exit 0
}

emit_wake() {  # <wake-lines> <arm-tail>
  local wake_lines=$1 arm_tail=$2 body encoded
  body="firstmate watcher wake - one supervision event needs a handling turn now.
$wake_lines
$arm_tail
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."
  fm_operational_input_encode watcher "$body" encoded || { printf '{}\n'; exit 0; }
  emit_continue "$encoded"
}

emit_repair() {  # <attempt-count> <arm-tail>
  local attempt_count=$1 arm_tail=$2 need_desc body encoded
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    need_desc="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    need_desc="$FM_SUP_SOURCES process-event source(s) registered"
  else
    need_desc="queued wake(s) pending"
  fi
  body="TURN WOULD END BLIND - supervision is off. The AGY Stop hook could not establish a live watcher after $attempt_count bounded attempt(s): $need_desc, last beacon $FM_SUP_BEACON_DESC, no live watcher with a fresh beacon verified.
$arm_tail
Repair the automatic Stop hook and watcher startup according to the session-start operating block before ending blind."
  fm_operational_input_encode turn-end-guard "$body" encoded || { printf '{}\n'; exit 0; }
  emit_continue "$encoded"
}

OUT=
ARM_TAIL=
attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.agy-arm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # Away mode may have appeared mid-cycle: the daemon owns triage now.
  if [ -e "$STATE/.afk" ]; then
    [ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null || true
    record_marker afk
    printf '{}\n'
    exit 0
  fi

  if [ -n "$OUT" ] && grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null; then
    WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null | head -8)
    ARM_TAIL=$(grep -E '^watcher:' "$OUT" 2>/dev/null | head -4)
    [ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null || true
    budget_reset
    record_marker wake
    emit_wake "$WAKE" "$ARM_TAIL"
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    [ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null || true
    budget_reset
    record_marker attached
    printf '{}\n'
    exit 0
  fi
  [ -n "$OUT" ] && ARM_TAIL=$(grep -E '^watcher:' "$OUT" 2>/dev/null | head -4)
  [ "$attempt" -lt "$ATTEMPTS" ] || break
  [ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null || true
  OUT=
done
[ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null || true
OUT=

# The arm genuinely failed to establish supervision. Nag a bounded number of
# times per conversation, then go silent so a broken hook cannot wedge the
# session loop forever; the pull guard still reports on the next fleet command.
budget_read
if [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ]; then
  budget_write $((BUDGET_COUNT + 1))
  record_marker repair
  emit_repair "$attempt" "$ARM_TAIL"
fi
record_marker budget-exhausted
printf '{}\n'
exit 0
