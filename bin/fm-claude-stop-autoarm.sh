#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as both a Stop and a StopFailure
# command hook with "asyncRewake": true and an explicit multi-hour timeout.
# Claude Code fires it in the background on EVERY turn end of a Claude primary
# session - Stop for a normal end, StopFailure INSTEAD of Stop when an API
# error (usage limit, overload, auth failure, ...) ended the turn - with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &); Claude owns the process group, so its timeout/session teardown
#     kills arm and watcher together, and the hook TERMs the arm with itself.
#     HUP, TERM, and INT are translated through the ordinary durable failure
#     handoff instead of leaving the generation frozen at arming. Claude does
#     not deliver the exit 2 of a hook it terminated at the configured timeout
#     as a rewake (measured on Claude Code 2.1.278 and 2.1.281,
#     docs/verification/supervision.md), so a park that outlives that timeout
#     records the failure durably without waking an idle primary; nothing here
#     shortens a quiet park, because no-change heartbeats are absorbed without
#     closing the arm.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm attaches to that live cycle. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A refused generation exits 0 silently even after printing. A close that
#     reports no actionable reason is benign when a live identity-matched
#     watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#   - StopFailure: an API-error turn end runs every gate above unchanged, but a
#     rewake while the error persists would end in another StopFailure within
#     about a second, and a fresh watcher after downtime closes at once with a
#     rearm-resurface check, so an unbounded retry would loop. Each StopFailure
#     therefore records the episode in state/.claude-stopfailure (error class,
#     failure count, times, the last assistant message) and sets a retry time
#     that doubles per consecutive failure from FM_CLAUDE_STOPFAILURE_BACKOFF_BASE
#     (60 s) to FM_CLAUDE_STOPFAILURE_BACKOFF_CAP (1800 s); the "resets ..." text
#     of a limit message is never trusted. Every generation, whichever event
#     started it, holds any exit 2 until that retry time, with a watcher
#     cycling through the hold - the arm's, a handling successor, or one the
#     hold starts itself when a host hand-back or a failed arm left none - so
#     wakes keep queuing durably during the backoff. The hold also ends 120 s before the tracked
#     28800 s hook timeout of this hook's own lifetime, because Claude drops
#     the exit 2 of a hook it timed out and a host park may already have used
#     most of that budget. The next normal Stop of the lock-owning session
#     clears the record and ends any hold early. The payload is parsed with jq
#     only: without jq a StopFailure firing behaves as a plain Stop, with no
#     record, backoff, or non-retryable notice.
#     The classes authentication_failed, billing_error, model_not_found, and
#     invalid_request cannot heal by retrying: such a firing records the
#     episode with the capped retry time, publishes one line per episode on a
#     secondmate's parent channel (bin/fm-parent-channel-lib.sh) or, in a main
#     home with no parent channel, as one check row in its durable wake queue
#     (a failed publish is retried, then handed back to the episode), and
#     exits 0 without arming. Any earlier
#     generation still parked ends quietly at its next exit 2 rather than
#     rewaking into the same error. The record and the notice claim are
#     updated under state/.claude-stopfailure.lock.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# watcher recovery generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# The Stop hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused, both before anything
# is sourced, read, or armed. A park started from a model's tool call would be
# owned by that short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh

Claude Stop and StopFailure hook registered in .claude/settings.json; not for
manual use. It reads the hook payload on stdin and, in a primary home that
needs supervision, arms the watcher or supervision host for this session.
After an API-error turn end it holds its rewake behind an error-aware backoff.
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
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac
STOPFAILURE_RECORD="$STATE/.claude-stopfailure"
STOPFAILURE_LOCK="$STATE/.claude-stopfailure.lock"
# Both bounds stay at most an hour; HOLD_LIMIT keeps any hold inside the tracked
# 28800 s registration timeout, measured on this hook's own $SECONDS clock.
HOLD_LIMIT=$((28800 - 120))
BACKOFF_BASE=${FM_CLAUDE_STOPFAILURE_BACKOFF_BASE:-60}
case "$BACKOFF_BASE" in
  ''|*[!0-9]*|?????*) BACKOFF_BASE=60 ;;
esac
BACKOFF_BASE=$((10#$BACKOFF_BASE))
{ [ "$BACKOFF_BASE" -ge 1 ] && [ "$BACKOFF_BASE" -le 3600 ]; } || BACKOFF_BASE=60
BACKOFF_CAP=${FM_CLAUDE_STOPFAILURE_BACKOFF_CAP:-1800}
case "$BACKOFF_CAP" in
  ''|*[!0-9]*|?????*) BACKOFF_CAP=1800 ;;
esac
BACKOFF_CAP=$((10#$BACKOFF_CAP))
[ "$BACKOFF_CAP" -le 3600 ] || BACKOFF_CAP=1800
[ "$BACKOFF_CAP" -ge "$BACKOFF_BASE" ] || BACKOFF_CAP=$BACKOFF_BASE

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
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- which turn end fired this hook -------------------------------------------
# StopFailure replaces Stop when an API error ended the turn (header). The
# payload is parsed with jq only; without jq a StopFailure firing is treated as
# a plain Stop, like the pi-code and foreign-host gates, so its backoff needs jq.
STOPFAILURE=0
STOPFAILURE_ERROR=
STOPFAILURE_MESSAGE=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  if [ "$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // "" | strings' 2>/dev/null)" = StopFailure ]; then
    STOPFAILURE=1
    STOPFAILURE_ERROR=$(printf '%s' "$PAYLOAD" | jq -r '.error // "" | strings' 2>/dev/null || true)
    STOPFAILURE_MESSAGE=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // "" | strings' 2>/dev/null || true)
  fi
fi
if [ "$STOPFAILURE" -eq 1 ]; then
  case "$STOPFAILURE_ERROR" in
    ''|*[!a-z_]*) STOPFAILURE_ERROR=unknown ;;
  esac
  STOPFAILURE_MESSAGE=$(printf '%s' "$STOPFAILURE_MESSAGE" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-300)
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- StopFailure episode record and backoff (header "StopFailure") -------------
# One key=value line per field; written whole through a temp file and rename.
stopfailure_field() {  # <field>
  sed -n "s/^$1=//p" "$STOPFAILURE_RECORD" 2>/dev/null | head -n 1
}

# A normal Stop of the lock-owning session proves the API answered again.
stopfailure_reset() {
  [ "$STOPFAILURE" -eq 1 ] || rm -f "$STOPFAILURE_RECORD" 2>/dev/null || true
}

# The record's read-modify-write and the once-per-episode notice claim are one
# critical section, so concurrent firings neither lose a count nor both notify.
stopfailure_lock() {
  local i=0
  while ! fm_lock_try_acquire "$STOPFAILURE_LOCK"; do
    [ "$i" -lt 100 ] || return 1
    sleep 0.05
    i=$((i + 1))
  done
}

# Record this StopFailure as the next consecutive failure of the episode and
# set its retry time. Sets STOPFAILURE_RETRYABLE (1 or 0) and
# STOPFAILURE_NOTIFY (1 when this firing claimed the episode's one notice).
STOPFAILURE_RETRYABLE=1
STOPFAILURE_NOTIFY=0
stopfailure_record_locked() {
  local now count first delay i tmp notified
  now=$(date +%s)
  count=$(stopfailure_field count)
  case "$count" in ''|*[!0-9]*|?????????*) count=0 ;; esac
  count=$((10#$count + 1))
  first=$(stopfailure_field first_at)
  case "$first" in ''|*[!0-9]*) first=$now ;; esac
  notified=$(stopfailure_field notified)
  [ "$notified" = 1 ] || notified=0
  case "$STOPFAILURE_ERROR" in
    authentication_failed|billing_error|model_not_found|invalid_request)
      STOPFAILURE_RETRYABLE=0
      delay=$BACKOFF_CAP
      if [ "$notified" -eq 0 ]; then
        notified=1
        STOPFAILURE_NOTIFY=1
      fi
      ;;
    *)
      STOPFAILURE_RETRYABLE=1
      delay=$BACKOFF_BASE
      i=1
      while [ "$i" -lt "$count" ] && [ "$delay" -lt "$BACKOFF_CAP" ]; do
        delay=$((delay * 2))
        i=$((i + 1))
      done
      [ "$delay" -le "$BACKOFF_CAP" ] || delay=$BACKOFF_CAP
      ;;
  esac
  tmp=$(mktemp "$STATE/.claude-stopfailure.XXXXXX") || return 1
  {
    printf 'error=%s\n' "$STOPFAILURE_ERROR"
    printf 'retryable=%s\n' "$STOPFAILURE_RETRYABLE"
    printf 'count=%s\n' "$count"
    printf 'first_at=%s\n' "$first"
    printf 'last_at=%s\n' "$now"
    printf 'delay=%s\n' "$delay"
    printf 'retry_at=%s\n' "$((now + delay))"
    printf 'notified=%s\n' "$notified"
    printf 'message=%s\n' "$STOPFAILURE_MESSAGE"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STOPFAILURE_RECORD" || { rm -f "$tmp"; return 1; }
}

stopfailure_record() {
  local rc=0
  stopfailure_lock || return 1
  stopfailure_record_locked || rc=$?
  fm_lock_release "$STOPFAILURE_LOCK"
  return "$rc"
}

# Give the notice claim back so a later firing of the episode retries it.
stopfailure_unclaim() {
  stopfailure_lock || return 0
  sed 's/^notified=1$/notified=0/' "$STOPFAILURE_RECORD" > "$STOPFAILURE_RECORD.tmp.$$" 2>/dev/null \
    && mv -f "$STOPFAILURE_RECORD.tmp.$$" "$STOPFAILURE_RECORD" 2>/dev/null \
    || rm -f "$STOPFAILURE_RECORD.tmp.$$" 2>/dev/null || true
  fm_lock_release "$STOPFAILURE_LOCK"
}

# A failure that retrying cannot heal gets one line per episode on a
# secondmate's parent channel, or one check row in a main home's wake queue. The
# claim was taken with the record, so only the firing that holds it publishes;
# a failed append is retried here (exit 0 follows, so no later firing would),
# and an undelivered notice is handed back to the episode.
stopfailure_notify_once() {
  local attempt=0 rc
  [ "$STOPFAILURE_NOTIFY" -eq 1 ] || return 0
  # shellcheck source=bin/fm-parent-channel-lib.sh
  if ! . "$SCRIPT_DIR/fm-parent-channel-lib.sh" 2>/dev/null; then
    stopfailure_unclaim
    return 0
  fi
  while :; do
    rc=0
    fm_parent_channel_report "$FM_HOME" "$STATE" \
      "blocked: secondmate turn ended on Claude API error $STOPFAILURE_ERROR, which retrying cannot fix; supervision in this home stays paused until the credential or configuration is fixed and the mate is steered (state/.claude-stopfailure)" \
      || rc=$?
    if [ "$rc" -eq 1 ]; then
      rc=0
      fm_wake_append check "claude-stopfailure:$(stopfailure_field first_at)" \
        "check: Claude API error $STOPFAILURE_ERROR ended the primary turn; retrying cannot fix it, so automatic supervision stays paused until the credential or configuration is fixed (state/.claude-stopfailure)" \
        || rc=4
    fi
    case "$rc" in
      0) return 0 ;;
      4) [ "$attempt" -lt 2 ] || break ;;
      *) break ;;
    esac
    attempt=$((attempt + 1))
    sleep 1
  done
  stopfailure_unclaim
}

# True while a retryable episode's retry time is still ahead.
stopfailure_hold_pending() {
  local retry_at
  [ -e "$STOPFAILURE_RECORD" ] || return 1
  [ "$(stopfailure_field retryable)" = 0 ] && return 1
  retry_at=$(stopfailure_field retry_at)
  case "$retry_at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -lt "$retry_at" ]
}

# The arm pid of the newest cycle the lifecycle ledger closed without a
# successor: the closed cycle a hold's successor links to when the hook itself
# ran no arm (the supervision host owns its cycles).
last_closed_arm_pid() {
  awk -F '\t' '$NF == "successor=none" && $1 ~ /^arm_pid=[0-9]+$/ { pid = substr($1, 9) }
    END { if (pid != "") print pid }' "$STATE/.watch-cycle-exits.log" 2>/dev/null
}

# A hold needs a verified watcher cycling through it: the arm, the host's
# hand-back, or a failed arm can each leave none, so start the handling
# successor of the closed cycle unless one is already beating.
stopfailure_cover_hold() {
  local predecessor
  stopfailure_hold_pending || return 0
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" && return 0
  predecessor=${CLOSED_ARM_PID:-}
  [ -n "$predecessor" ] || predecessor=$(last_closed_arm_pid)
  start_handling_successor "${predecessor:-$$}" || true
}

# Hold an impending exit 2 until the episode's retry time, whichever event
# started this generation, with a watcher cycling meanwhile. Ends early when a
# normal Stop cleared the record or this generation lost ownership (its commit
# then refuses anyway), and never runs into the hook timeout (HOLD_LIMIT). An
# episode that is not retryable ends the generation quietly instead: the wake
# stays durable, and a rewake cannot heal what the notice already reported.
# After a real wait, AFK or a vanished need is honored here exactly as at the
# end of the arm cycle. With "watched", the wait happens only when a healthy
# watcher is verified after the cover attempt: the first failure notice of an
# episode is the only way to tell the model its supervision is down, so it is
# never held behind a backoff nothing is covering.
stopfailure_backoff() {  # [watched]
  local waited=0 hold=1
  stopfailure_cover_hold
  if [ "${1:-}" = watched ] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    hold=0
  fi
  while [ "$hold" -eq 1 ] && stopfailure_hold_pending; do
    [ "$SECONDS" -lt "$HOLD_LIMIT" ] || break
    fm_autoarm_still_owner "$STATE" "$MY_GEN" || break
    waited=1
    sleep 1
  done
  if [ -e "$STOPFAILURE_RECORD" ] && [ "$(stopfailure_field retryable)" = 0 ]; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  [ "$waited" -eq 1 ] || return 1
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if ! need_supervision; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  return 0
}

[ "$RECOVER_SESSION_LOCK" -eq 1 ] || stopfailure_reset

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
  stopfailure_reset
fi

# --- StopFailure: record the episode before any claim ---------------------------
# Recording precedes the claim so a still-parked generation this firing defers
# to applies the same backoff before its own exit 2.
if [ "$STOPFAILURE" -eq 1 ]; then
  stopfailure_record || exit 0
  if [ "$STOPFAILURE_RETRYABLE" -eq 0 ]; then
    stopfailure_notify_once
    exit 0
  fi
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid recovery
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# A superseded generation remains silent, and an episode whose attended
# fail-open was already consumed must not restart automatic continuation.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" && exit 2
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child this hook waits on, never a fire-and-forget shell
# & whose child would be reaped when the hook returned: this hook process tree
# is the harness-owned lifecycle. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within the arm's own confirmation budget plus slack. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  SUCCESSOR_FAILURE=
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
    SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
    return 1
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_WATCH_PREDECESSOR_ARM_PID=$1 FM_GUARD_GRACE="$GRACE" \
    nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  deadline=$(( $(date +%s) + budget + 2 ))
  while :; do
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      rm -f "$out" 2>/dev/null || true
      return 0
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
  rm -f "$out" 2>/dev/null || true
  [ -z "$line" ] || line=" ($line)"
  SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
  return 1
}

OUT=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    HOST_RC=0
    FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
  else
    run_arm "$OUT"
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break
  if [ "$HOST_MODE" -eq 1 ]; then
    # The host stood down because this session or generation no longer owns
    # supervision: whoever does owns continuity now.
    if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
      autoarm_record clean
      rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    # A host that died without a close may have left its cycle running with
    # no owner to deliver the close; retrying lets the next host stop what it
    # left and own a fresh cycle, which the healthy-watcher predicate cannot.
    if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
      [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      OUT=
      continue
    fi
    # A failed hand-back cannot be dismissed just because its successor
    # watcher is healthy: the close is still undelivered.
    [ "$HOST_RC" -eq 0 ] || break
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  autoarm_record clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  stopfailure_backoff
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    [ -e "$FAILURE_ALARM" ] && exit 0
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # The host owns its own successors, and a hand-back can leave none; the
  # backoff below starts one when it has to hold.
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  stopfailure_backoff
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    if [ "$HOST_MODE" -eq 1 ]; then
      [ -n "$OUT" ] && awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null
    else
      [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    fi
    if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
      && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
      printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
    fi
    [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  if autoarm_commit rewake; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    LOST_HANDBACK_COMMITTED=0
    if [ ! -e "$FAILURE_NOTICE" ]; then
      printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
      autoarm_commit failed "$FAILURE_NOTICE" && LOST_HANDBACK_COMMITTED=1
    else
      autoarm_commit failed-suppressed && LOST_HANDBACK_COMMITTED=1
    fi
    if [ "$LOST_HANDBACK_COMMITTED" -eq 1 ]; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  stopfailure_backoff watched
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
stopfailure_backoff
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
