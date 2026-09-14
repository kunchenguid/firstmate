#!/usr/bin/env bash
# Codex Stop-owned watcher auto-arm (async hook).
#
# Registered in tracked .codex/hooks.json as a Stop command hook with
# "async": true and an explicit multi-hour timeout. Codex fires it on every Stop
# of a Codex primary session. It owns routine tokenless watcher continuity for
# Codex primaries (main home and marked secondmate homes), replacing the old
# model-driven foreground checkpoint, which only supervised while the model
# remembered to relaunch it and therefore ended blind on any ordinary final
# reply.
#
# It is the Codex sibling of bin/fm-claude-stop-autoarm.sh and keeps that
# script's ownership model unchanged - same scope, identity, AFK, need,
# single-flight generation, and attended-alarm rules, and the same foreground arm
# of bin/fm-watch-arm.sh inside the hook's own process tree. Exactly one thing
# differs, because Codex and Claude differ there:
#
#   Claude delivers the wake by exiting 2 with the banner on stderr.
#   Codex DISCARDS an async hook's exit status and stderr entirely (verified,
#   codex-cli 0.154.0: an async Stop hook that exits 2 produces no continuation),
#   so this hook delivers the wake by queueing it as an ordinary user message
#   into the same Codex thread instead:
#
#     codex queue --thread <session_id> --message <banner>
#
#   The thread id is the `session_id` Codex hands every Stop hook in its
#   payload. Verified on codex-cli 0.154.0: a queued message reaches an IDLE TUI
#   session within seconds, is held and delivered after the current turn when
#   the session is working, and preserves submission order.
#
#   The thread store is per-CODEX_HOME, so the queue call has to run with the
#   same CODEX_HOME as the session it addresses. Nothing sets it here on purpose:
#   this hook runs inside the primary's own process tree and inherits whatever
#   CODEX_HOME that primary uses, which is the only value that can be right.
#
# Why async rather than a synchronous park: a synchronous Stop hook DOES get its
# exit-2 continuation delivered, but it holds the turn open for its whole
# duration, so the captain's own next message waits behind the park. Async keeps
# the turn boundary free and moves the wake onto the queue channel.
#
# DELIVERY IS BEST EFFORT, and nothing here may claim otherwise. `codex queue`
# exits 0 after accepting a message for a thread whose session is already gone
# (verified), so a zero exit is not proof the model was woken. That is safe
# because the wake itself is durable independently of this hook: the wake queue
# keeps every actionable row until the handling turn runs its own
# --ack-through, so a push that lands nowhere is re-presented at the next drain,
# and bin/fm-turnend-guard.sh remains the synchronous backstop. No at-least-once,
# no-loss, or exactly-once delivery is provided or implied.
#
# Ownership rules, identical to the Claude hook:
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     A dead numeric owner is recovered through bin/fm-lock.sh and re-verified;
#     a live owner, missing lock, malformed lock, or unresolved ancestry stays
#     inert, so a competing session never arms or wakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER queues a wake (rechecked at delivery time so a
#     mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: exactly one GENERATION owner arms per event epoch through
#     the state/.codex-autoarm-epoch ledger (fm_autoarm_claim_open /
#     fm_autoarm_claim_next in bin/fm-wake-lib.sh own that contract). Ownership
#     is re-verified before every arm invocation, ledger write, and delivery, and
#     a superseded generation goes completely silent without queueing anything.
#     FM_AUTOARM_PREFIX is what keeps this ledger separate from Claude's.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &), so Codex owns the process
#     group and its teardown reaps arm and watcher together.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times. Only an
#     exhausted failure with no verified watcher queues one operator notice per
#     failure episode, deduplicated by state/.codex-autoarm-failure-notified, so
#     a broken mechanism says so once instead of storming the thread. That
#     marker is created inside the owned ledger write BEFORE the push, so a
#     marker that cannot be created suppresses the push rather than announcing
#     without a dedupe key; a push the CLI then rejects removes it again, so the
#     next Stop retries the notice exactly once more.
#
# This hook never writes to stdout and never blocks the Stop decision: Codex
# ignores both for an async hook. Every uncertainty - unresolvable ancestry,
# malformed lock state, missing codex binary, absent session id - exits 0 and
# leaves continuity to the synchronous guard and the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Selects this harness's own single-flight ledger, micro-mutex, and failure
# markers in bin/fm-wake-lib.sh. Set before any fm_autoarm_* call.
FM_AUTOARM_PREFIX=.codex-autoarm
OWNER_LOCK="$STATE/$FM_AUTOARM_PREFIX.lock"
FAILURE_NOTICE="$STATE/$FM_AUTOARM_PREFIX-failure-notified"
FAILURE_ALARM="$STATE/$FM_AUTOARM_PREFIX-failure-alarmed"
AUTOARM_ATTEMPTS=2

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before its
# terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace owns that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once, so a slow writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)

# --- payload: a Codex Stop event carrying the thread to wake ------------------
# Only Codex reads .codex/hooks.json, so this is a correctness read rather than
# a host standdown: without a session id there is nothing to queue into, and
# arming a watcher whose wake can never be delivered would be worse than
# standing down and leaving the synchronous guard to block.
command -v jq >/dev/null 2>&1 || exit 0
THREAD=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and (.session_id | type) == "string" then .session_id else empty end
' 2>/dev/null || true)
case "$THREAD" in
  ''|*[!0-9A-Za-z-]*) exit 0 ;;
esac
command -v codex >/dev/null 2>&1 || exit 0

# --- scope: genuine primary checkout only -------------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm -------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home stays byte-for-byte inert. Missing or malformed locks are
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

# --- AFK: the away daemon owns the watcher and triage; never queue a wake -----
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ----------------------------------------------
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim -------------------------------------------
# Codex does not deduplicate async hook firings, so exactly one generation owner
# arms and delivers per event epoch: every firing defers to a live open claim,
# and a stuck, dead, identity-mismatched, or finished claim is superseded by
# taking the next generation rather than being unlocked or revoked.
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

# Deliver <banner> into this Codex thread as an ordinary user message, but only
# while this generation still owns the claim and the home is still awake. The
# ledger write is the commit point: a losing generation neither writes nor
# queues, so one event epoch yields exactly one wake turn.
#
# A rewake row also records the live session-lock pid and the watcher recovery
# generation it belongs to, exactly as bin/fm-claude-stop-autoarm.sh does, and
# refuses on the same terms: a rewake that cannot be bound is worse than no
# rewake at all, because fm_autoarm_midturn_healthy rejects a row with no
# recovery generation, so bin/fm-guard.sh would cry supervision-off on the very
# handling turn the binding exists to protect. Refusing costs nothing the wake
# queue does not already hold, and the synchronous guard still owns the next
# turn end.
#
# That protection is real only because two things hold in bin/fm-wake-lib.sh, and
# this row is worth nothing without either: fm_supervision_model maps codex to
# autoarm, and fm_watcher_supervision_verdict selects THIS home's prefix before
# consulting the predicate, so the claim is read from .codex-autoarm-epoch rather
# than Claude's ledger.
#
# With a marker argument the marker is created inside the same owned ledger
# write, so it commits before the push and a marker that cannot be created
# refuses instead of announcing something nothing can deduplicate. A rejected
# push then removes it, leaving the next Stop free to retry.
#
# The write has to precede the push because it is the single-flight gate: a
# superseded generation is refused there and so never pushes at all. That
# ordering means a REJECTED push leaves a row describing a wake nobody received,
# and for a rewake that row is read by both guards as proof recovery is owned -
# the turn-end guard would allow the very stop it exists to block. So a rejected
# push rewrites the row to failed-suppressed, which neither guard accepts as
# recovery (bin/fm-turnend-guard.sh's autoarm_owns_recovery falls through it, and
# fm_autoarm_midturn_healthy demands outcome=rewake). Only the owning generation
# can make that correction, and a correction refused as superseded needs none:
# a newer generation already owns the ledger.
#
# That correction is the one write here whose failure cannot be shrugged off, so
# its status is never discarded: a contended micro-mutex is retried over the same
# bounded budget fm_autoarm_write_owned itself uses, because the alternative is a
# row claiming a delivery that did not happen. Return 3 says exactly that - the
# push was rejected AND the row still claims recovery - so the state is named
# rather than silently indistinguishable from an ordinary rejected push.
autoarm_deliver() {  # <outcome> <banner> [marker-file]
  local outcome=$1 banner=$2 marker=${3:-} session_pid='' recovery='' fixed i=0
  fm_autoarm_still_owner "$STATE" "$MY_GEN" || return 1
  [ -e "$STATE/.afk" ] && return 1
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    [ -n "$session_pid" ] || return 2
  fi
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery" || return 1
  if ! codex queue --thread "$THREAD" --message "$banner" >/dev/null 2>&1; then
    [ -z "$marker" ] || rm -f -- "$marker" 2>/dev/null || true
    while :; do
      fm_autoarm_write_owned "$STATE" "$MY_GEN" failed-suppressed >/dev/null 2>&1
      fixed=$?
      [ "$fixed" -eq 1 ] || break
      [ "$i" -lt 20 ] || break
      sleep 0.02
      i=$((i + 1))
    done
    [ "$fixed" -eq 1 ] && return 3
    return 1
  fi
  return 0
}

# Best-effort ownership-checked record for paths where supersession changes
# nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Relay cadence: source the generated config so a Relay instance polls at its
# own cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child and propagates the wake reason on
# close. Every non-actionable close is checked against the same identity-matched
# live watcher and fresh-beacon predicate the turn-end guard uses before it is
# retried or reported as a failure.
OUT=
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.codex-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, Relay opted out):
# nothing left to supervise, so close quietly instead of waking the model.
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
  elif [ "$RESET_RC" -ne 2 ]; then
    autoarm_record failed-suppressed
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's one attended fail-open,
# do not queue another wake that could defeat it: a queued message reaches an idle
# TUI session in seconds, which starts a turn.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  REASONS=
  [ -n "$OUT" ] && REASONS=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8)
  BANNER=$(printf '%s\n%s\n%s\n' \
    'firstmate watcher wake - one supervision event needs a handling turn now.' \
    "$REASONS" \
    'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh or bin/fm-watch-checkpoint.sh after an ordinary wake.')
  autoarm_deliver rewake "$BANNER" || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify once per continuous failure episode. A broken automatic mechanism has
# to be visible, but repeating it on every Stop would storm the thread, so the
# marker is what makes the notice a once-per-episode event, and the push is
# gated on it: no dedupe key, no announcement.
if [ ! -e "$FAILURE_NOTICE" ]; then
  DETAIL=
  [ -n "$OUT" ] && DETAIL=$(grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8)
  NOTICE=$(printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n%s\nDo not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' \
    "$attempt" "$DETAIL")
  autoarm_deliver failed "$NOTICE" "$FAILURE_NOTICE" || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
autoarm_record failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
