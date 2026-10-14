#!/usr/bin/env bash
# Devin `Stop` hook adapter for a firstmate PRIMARY session: the park model.
#
# Registered in tracked .devin/hooks.v1.json. Devin runs this hook SYNCHRONOUSLY
# and awaits it at every turn boundary for up to its registered timeout
# (28800s), so one script owns both halves of Devin primary supervision:
#
#   PARK      while supervision is needed, foreground bin/fm-watch-arm.sh and
#             hold the turn boundary open until the watcher closes with an
#             actionable wake, then return that wake as one follow-up. No model
#             tokens are spent while parked. The next turn end parks again, so
#             the arm/re-arm loop is hook-owned, never model-memory-owned.
#   BACKSTOP  when the park cannot establish supervision, return the shared
#             turn-end guard's repair instruction as a bounded follow-up.
#
# THE WAKE CHANNEL IS A BLOCK DECISION. Devin maps a Stop hook's stdout
# {"decision":"block","reason":<text>} to one forced continuation inside the
# SAME turn, with the reason delivered to the model verbatim (verified live,
# devin 3000.11.3); exit 2 plus stderr is an equivalent channel this adapter
# does not need. Every path exits 0 and the only output is at most one
# decision object on stdout. The continuation shares the turn's prompt_id and
# fires no UserPromptSubmit, which is what the loop counter below keys on.
# Refuse to arm if its output capture cannot be created; never discard a wake.
# docs/turnend-guard.md:16 accepts one bounded follow-up as an equal
# alternative to blocking, which is the same primitive the Cursor park uses.
#
# CAPTAIN STAND-DOWN. While this hook is parked, a captain message typed plus
# Enter lands in Devin's visible queue and only drains AFTER the hook exits
# without a block (verified live). Every poll tick therefore reads this
# session's own pane - tmux via $TMUX/$TMUX_PANE, herdr via
# $HERDR_ENV/$HERDR_PANE_ID, resolved by bin/fm-supervisor-target-lib.sh - and
# stands down silently when a queue or pending-cancel marker is rendered,
# ending the park so the queue drains and the message runs as its own turn.
# Before emitting a post-arm block, check the pane again under the owner lock.
# The next turn end parks again. When the pane cannot be located or read at
# park start the adapter does NOT park blind - the captain would be locked out
# for the whole hook timeout - and instead spends one bounded repair follow-up
# on the missing pane and exits.
#
# LOOP BOUNDING. Devin's payload carries only a boolean stop_hook_active, but
# prompt_id is constant across block continuations and rotates on each real
# user prompt (verified live). state/.devin-park-loops records
# session/prompt/count: every emitted block increments the count for that
# prompt, a new prompt_id resets it. FM_DEVIN_TURNEND_LOOP_CEILING (default
# 180) emits one loud notice at exactly the ceiling and goes silent above it.
# Repair nags are bounded separately by FM_DEVIN_TURNEND_BLOCK_BUDGET (default
# 3) per session.
#
# SUPERSESSION. Each invocation publishes itself as the park owner in
# state/.devin-park-owner; once a newer stop has claimed the baton, an older
# park still running stands down without emitting. Newest stop wins; the arm's
# own singleton keeps any overlap from starting a second watcher.
#
# HOOK TIMEOUT SEMANTICS. Devin kills only the hook's own shell at timeout and
# orphans its children (verified live: a slept-in hook died at the default 60s
# while its `sleep` child kept running). The arm child this park leaves in
# that edge case is not lost: the next park's arm attaches to the surviving
# healthy watcher cycle, and the poll trap kills a still-tracked child on
# every ordinary exit path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
OWNER="$STATE/.devin-park-owner"
OWNER_LOCK="$STATE/.devin-park-owner.lock"
BUDGET_FILE="$STATE/.turnend-devin-blocks"
LOOPS_FILE="$STATE/.devin-park-loops"

LOOP_CEILING=${FM_DEVIN_TURNEND_LOOP_CEILING:-180}
BLOCK_BUDGET=${FM_DEVIN_TURNEND_BLOCK_BUDGET:-3}
ARM_ATTEMPTS=${FM_DEVIN_PARK_ATTEMPTS:-2}
POLL=${FM_DEVIN_PARK_POLL:-2}
LOCK_ATTEMPTS=${FM_DEVIN_LOCK_ATTEMPTS:-50}
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac

# Captain-activity pane markers, all plain text and theme-independent (devin
# 3000.11.3 renders no SGR in its composer at all, verified live in the light
# theme): the queued-message banner and its composer hint mean a message is
# waiting to drain, and `(esc again to interrupt)` on the `Typing` spinner row
# means the captain pressed Escape once while the hook was parked (verified,
# round-3 captures, devin 3000.11.3) - either way the park ends so the turn can
# close and the pending input or cancel can take effect.
# The verdict is computed ONLY on the bottom composer region: trailing blank
# rows are dropped, then the last FM_DEVIN_STANDDOWN_ROWS lines - the spinner
# row, queue banner, composer row, and footer sit there in every verified
# layout - are matched with line-anchored patterns. The transcript above can
# legitimately print the same strings inside tool output, where they render
# indented or behind a ` │ ` gutter, so an unanchored whole-screen match would
# stand the park down on ordinary work.
FM_DEVIN_STANDDOWN_ROWS=${FM_DEVIN_STANDDOWN_ROWS:-12}
case "$FM_DEVIN_STANDDOWN_ROWS" in ''|*[!0-9]*|0) FM_DEVIN_STANDDOWN_ROWS=12 ;; esac

# Reads one pane capture on stdin; returns 0 when a bottom-region row carries a
# captain-activity marker.
fm_devin_pane_stands_down() {
  awk -v rows="$FM_DEVIN_STANDDOWN_ROWS" '
    { buf[NR] = $0; if (NF) last = NR }
    END {
      start = last - rows + 1
      if (start < 1) start = 1
      for (i = start; i <= last; i++) {
        line = buf[i]
        if (line ~ /^❭ Press Enter to send queued messages now/) exit 0
        if (line ~ /^[[:space:]]*(─)+ [0-9]+ queued ─/) exit 0
        if (line ~ /^[^[:space:]]/ && line !~ /^│/ && line ~ /Typing ·.*\(esc again to interrupt\)/) exit 0
      }
      exit 1
    }'
}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# A malformed payload is uncertainty, not a reason to park: fail open and let
# the pull guard report the problem on the next fleet command.
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=unknown ;; esac
PROMPT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.prompt_id // "unknown"' 2>/dev/null || printf 'unknown')
case "$PROMPT_ID" in ''|*[!A-Za-z0-9._-]*) PROMPT_ID=unknown ;; esac

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_acquire_bounded() {  # <lock>
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

# The per-prompt block counter. Devin keeps invoking this hook for every
# block-driven continuation, so count is a real loop bound even though the
# payload carries no loop_count of its own.
loops_prepare() {
  local session prompt count=0
  session=$(sed -n '1s/^session=//p' "$LOOPS_FILE" 2>/dev/null || true)
  prompt=$(sed -n '2s/^prompt=//p' "$LOOPS_FILE" 2>/dev/null || true)
  count=$(sed -n '3s/^count=//p' "$LOOPS_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$session" = "$SESSION_ID" ] && [ "$prompt" = "$PROMPT_ID" ] || count=0
  LOOPS_COUNT=$((count + 1))
}

loops_next() {
  local tmp="$LOOPS_FILE.tmp.$$" status=0
  [ ! -d "$LOOPS_FILE" ] || return 1
  printf 'session=%s\nprompt=%s\ncount=%s\n' "$SESSION_ID" "$PROMPT_ID" "$LOOPS_COUNT" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$LOOPS_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  [ "$status" -eq 0 ] || return 1
}

# Emit exactly one block decision and stop, bounded by the per-prompt loop
# ceiling: at exactly the ceiling the session gets one loud notice instead,
# and above it the adapter goes quiet so the loop cannot run unbounded.
emit_block() {  # <kind> <body> [reset-budget]
  local kind=$1 body=$2 reset_budget=${3-} encoded response count
  lock_acquire_bounded "$OWNER_LOCK" || exit 0
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  loops_prepare
  count=$LOOPS_COUNT
  [ "$count" -gt "$LOOP_CEILING" ] && {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  if [ "$count" -eq "$LOOP_CEILING" ]; then
    kind=turn-end-guard
    body="FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $count consecutive hook-driven continuations without a captain message, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
  fi
  fm_operational_input_encode "$kind" "$body" encoded || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  response=$(jq -n --arg m "$encoded" '{"decision":"block","reason":$m}' 2>/dev/null) || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  if [ "$PANE_READY" -eq 1 ] && ! pane_allows_block; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  if [ "$reset_budget" = reset-budget ] && ! budget_reset; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  loops_next || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

budget_read() {
  local session count
  BUDGET_COUNT=0
  [ -f "$BUDGET_FILE" ] || return 0
  session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$session" = "$SESSION_ID" ] && BUDGET_COUNT=$count
  return 0
}

budget_write() {  # <count>
  local tmp="$BUDGET_FILE.tmp.$$" status=0
  [ ! -d "$BUDGET_FILE" ] || return 1
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$1" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null
}

budget_reset_if_ours() {
  lock_acquire_bounded "$OWNER_LOCK" || exit 0
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  budget_reset || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  fm_lock_release "$OWNER_LOCK"
}

emit_repair_followup() {  # <reason> <arm-tail> <attempt>
  local reason=$1 arm_tail=$2 attempt_count=$3 count body encoded response
  lock_acquire_bounded "$OWNER_LOCK" || exit 0
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  budget_read
  [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  count=$((BUDGET_COUNT + 1))
  body="TURN WOULD END BLIND - supervision is off. The hook-owned watcher park could not establish a live cycle after $attempt_count bounded attempts (nag $count of $BLOCK_BUDGET).
$arm_tail

$reason"
  loops_prepare
  if [ "$LOOPS_COUNT" -gt "$LOOP_CEILING" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  if [ "$LOOPS_COUNT" -eq "$LOOP_CEILING" ]; then
    body="FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $LOOPS_COUNT consecutive hook-driven continuations without a captain message, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
  fi
  fm_operational_input_encode turn-end-guard "$body" encoded || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  response=$(jq -n --arg m "$encoded" '{"decision":"block","reason":$m}' 2>/dev/null) || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  if [ "$PANE_READY" -eq 1 ] && ! pane_allows_block; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  budget_write "$count" || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  loops_next || {
    fm_lock_release "$OWNER_LOCK"
    exit 0
  }
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

# --- park ownership ----------------------------------------------------------
# Last arrival wins. The short owner lock serializes publication with only the
# final ownership, away-mode, output, and repair-budget commit.
claim_park() {
  local seq tmp
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$OWNER_LOCK"
  return 0
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_self "$STATE"
}

# --- own-pane captain stand-down ---------------------------------------------
# The hook's own pane is located once: $TMUX_PANE (or an explicit
# FM_SUPERVISOR_TARGET) selects tmux, $HERDR_ENV=1 plus $HERDR_PANE_ID selects
# herdr. FM_DEVIN_PANE_READ is the test seam: a command used instead of the
# backend read, so CI can drive the stand-down and the unreadable-pane repair
# paths without a multiplexer.
PANE_BACKEND=
PANE_TARGET=
pane_locate() {
  local target backend
  target=$(discover_supervisor_target 2>/dev/null) && {
    backend=$(discover_supervisor_backend 2>/dev/null) || return 1
    PANE_TARGET=$target
    PANE_BACKEND=$backend
    return 0
  }
  return 1
}

pane_read() {
  if [ -n "${FM_DEVIN_PANE_READ:-}" ]; then
    $FM_DEVIN_PANE_READ
    return $?
  fi
  [ -n "$PANE_BACKEND" ] || return 1
  fm_backend_visible_capture "$PANE_BACKEND" "$PANE_TARGET" 2>/dev/null
}

pane_capture() {
  PANE_CAPTURE=$(pane_read 2>/dev/null) || return 1
  [ -n "$PANE_CAPTURE" ]
}

# A final capture under the owner lock closes the gap between the last poll
# and block emission. An unreadable pane also releases the turn for user input.
pane_allows_block() {
  pane_capture || return 1
  ! printf '%s\n' "$PANE_CAPTURE" | fm_devin_pane_stands_down
}

# Only the lock-owning session may arm or wake. A prior session that died
# leaving its numeric harness pid behind is the one recoverable
# case, delegated to bin/fm-lock.sh so acquisition keeps its single owner.
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in ''|*[!0-9]*) exit 0 ;; esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) exit 0 ;; esac

PARK_SEQ=
claim_park || exit 0

# Away mode owns the watcher and its own triage; never park and never wake.
[ -e "$STATE/.afk" ] && exit 0

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  exit 0
fi

# X mode cadence: an opted-in home polls Relay at its generated cadence.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# A park with no readable pane would hold the turn boundary while the captain's
# typed input sits in Devin's queue undelivered - a lockout for the whole hook
# timeout. Spend one bounded repair follow-up instead of parking blind.
PANE_CAPTURE=
PANE_READY=0
if { [ -n "${FM_DEVIN_PANE_READ:-}" ] || pane_locate; } && pane_capture; then
  PANE_READY=1
else
  emit_repair_followup \
    'the Devin primary park needs this session running in a tmux or herdr pane it can read (no TMUX_PANE or HERDR_PANE_ID was usable); relaunch the primary under tmux or herdr, or the park will stand down at every turn end' \
    '' 0
fi

# --- the park ----------------------------------------------------------------
# The arm runs as a tracked child of THIS hook process, which stays alive and
# waits on it - never a fire-and-forget shell `&`, whose child would be reaped
# the moment the hook returned, leaving no watcher at all. Polling rather than
# blocking in `wait` is what lets a superseded park or a captain stand-down end
# the wait promptly instead of surfacing a duplicate wake minutes later.
ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
STAND_DOWN=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'

# Never leave an arm child or its capture file behind, on any exit path.
trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  current_session_still_ours || exit 0
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.devin-park-output.XXXXXX") || ARM_OUT=
  if [ -z "$ARM_OUT" ]; then
    # Never consume a watcher close without a channel that preserves its wake.
    emit_repair_followup \
      'cannot create the watcher output capture file; repair the state directory before retrying supervision' \
      '' "$((attempt - 1))"
  fi
  "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    # Stand down for a newer stop's claim, for away mode taking over the
    # watcher, or for captain input queued in this pane: ending the park is
    # what lets the queued message (or a pending cancel) take effect.
    if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
      STAND_DOWN=1
      break
    fi
    if ! pane_capture || printf '%s\n' "$PANE_CAPTURE" | fm_devin_pane_stands_down; then
      STAND_DOWN=1
      break
    fi
    sleep "$POLL"
  done
  if [ "$STAND_DOWN" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null
    ARM_PID=
    exit 0
  fi
  wait "$ARM_PID" 2>/dev/null
  ARM_PID=

  # Both block paths take one final pane capture under the owner lock so
  # input queued at watcher close can drain before any continuation.

  # Away mode may have been entered while parked: the daemon owns triage now.
  [ -e "$STATE/.afk" ] && exit 0

  ACTIONABLE=0
  if [ -n "$ARM_OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

# The need may have vanished while parked - the fleet was torn down, or Relay
# was opted out. Nothing left to supervise, so end the turn quietly.
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  emit_block watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop-hook park owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake." reset-budget
fi

# A verified live cycle with a fresh beacon is positive recovery even though this
# park closed without a wake of its own: the next turn end parks again.
if [ "$HEALTHY" -eq 1 ]; then
  budget_reset_if_ours
  exit 0
fi

# The park could not establish supervision. Ask the SHARED predicate whether
# this turn would genuinely end blind, rather than deciding that here a second
# time: bin/fm-turnend-guard.sh owns the block decision and its banner for every
# harness, and --devin tells it this is Devin's own registration rather than a
# Claude-compatibility duplicate.
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-devin.XXXXXX") || exit 0
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --devin 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
[ "$GUARD_RC" -eq 2 ] || exit 0

# Bounded so a persistent failure nags a few times and then stops, instead of
# turning every turn end into another unproductive continuation.
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
ARM_TAIL=
[ -n "$ARM_OUT" ] && ARM_TAIL=$(grep -E '^watcher:' "$ARM_OUT" 2>/dev/null | head -4)
emit_repair_followup "$REASON" "$ARM_TAIL" "$attempt"
