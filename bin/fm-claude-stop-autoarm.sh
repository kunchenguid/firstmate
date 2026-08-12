#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#     A recorded owner that is one of Claude Code's shared infrastructure
#     processes is stale but NOT claimable: it names no session, and claiming on
#     it during the identity-narrowing migration window would let one session
#     take a home another live session is using.
#     ANY decline reached with NO resolvable ancestry of this hook's own is a
#     fault rather than a decision, because ownership is then unknowable rather
#     than disproved; it is recorded in
#     state/.claude-autoarm-unresolved-ancestry and cleared on the next claim or
#     on any reasoned decline, so a permanently unclaimable home cannot look like
#     routine silence. The record is written only once the AFK and need gates
#     have passed, so an idle or away home stays byte-for-byte inert.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model, recording the unresolvable-ancestry case so that guard can name it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe.
cat >/dev/null 2>&1 || true

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Durable record of the one inert case that is NOT a decision this hook made
# about a competing session: a firing whose own session ancestry cannot be
# resolved at all, so ownership is unknowable rather than disproved. Written
# only in that case and cleared on the next successful claim or on any decline
# this firing could actually reason about, so it is self-healing and idempotent.
# bin/fm-turnend-guard.sh reads it to name the real condition instead of
# reporting a generic "the auto-arm did not claim".
# The record carries WHICH lock condition this firing declined on, so the guard
# can say something true rather than assuming the worst case:
#   live-owner    a recorded owner that this firing verified is a live harness,
#                 and the ONLY condition that supplies a pid, because it is the
#                 only one where that pid names a genuine competing session.
#   infra-lock    a recorded owner that resolves to Claude Code's shared
#                 infrastructure, which names no session at all.
#   unclaimable   no usable recorded owner, or a recovery that did not establish
#                 ownership; any pid involved is one this firing already proved
#                 is not a live harness.
# Reporting a shared-daemon pid or an already-dead pid as a live competing
# session would be a confident misdiagnosis, and the freshness bound cannot catch
# it because that bounds only the record's own age, never the pid's liveness.
UNRESOLVED="$STATE/.claude-autoarm-unresolved-ancestry"
record_unresolved_ancestry() {  # <condition> [<live-owner-pid>]
  local tmp="$UNRESOLVED.tmp.$$"
  printf 'owner_pid=%s condition=%s updated_at=%s\n' "${2:-none}" "$1" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$UNRESOLVED" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# The ONE exit taken by every identity decline, so the diagnosis cannot drift
# between them. What distinguishes a decision from a fault is not WHICH decline
# was reached but whether this firing could see its own session at all: with a
# resolvable ancestry every decline is a reasoned refusal and any older record is
# stale, while with no resolvable ancestry the firing knows nothing about who
# owns this home, cannot ever claim it, and would otherwise repeat that silence
# on every Stop forever. That is true of a missing or malformed lock and of a
# failed or unverifiable recovery exactly as it is of a live recorded owner, so
# all of them record it.
# The AFK and need gates are applied FIRST so an idle or away home stays
# byte-for-byte inert: nothing here is worth diagnosing while no supervision is
# owed, and the guard only ever reads this record on a turn it is blocking.
decline() {  # <condition> [<live-owner-pid>]
  [ -e "$STATE/.afk" ] && exit 0
  fm_supervision_needed "$STATE" "$GRACE" || exit 0
  if fm_harness_ancestry_pids >/dev/null 2>&1; then
    rm -f "$UNRESOLVED" 2>/dev/null || true
  else
    record_unresolved_ancestry "$@"
  fi
  exit 0
}

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
#
# A LIVE recorded owner outside this ancestry has two very different causes that
# must not be collapsed into the same silent exit. Either another firstmate
# session genuinely owns this home, which is a correct and permanent refusal, or
# this firing simply cannot see its own session: Claude Code hosts an asyncRewake
# hook inside the shared worker chain of its per-user daemon, whose ancestry
# never contains the session pid that state/.lock records. That second case is
# unknowable ownership, not a competing session, and left silent it pins the home
# forever - every later firing repeats the same refusal, the epoch ledger never
# advances, and the synchronous guard can only report that nobody claimed.
#
# A recorded owner that resolves to Claude Code's shared infrastructure is a
# third case and the only one that is neither: such a pid can only have been
# written by a pre-narrowing firstmate, it names no session, and it must not be
# treated as a dead owner either, because a dead owner is claimable and claiming
# on it would let one session take a home another live session is using.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) decline unclaimable ;;
  esac
  fm_harness_pid_is_infra "$LOCK_PID" && decline infra-lock
  fm_harness_pid_alive "$LOCK_PID" && decline live-owner "$LOCK_PID"
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || decline unclaimable
  fm_session_lock_owned_by_self "$STATE" || decline unclaimable
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

rm -f "$UNRESOLVED" 2>/dev/null || true
write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
OUT=
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

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
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  if fm_failure_episode_reset "$STATE"; then
    write_epoch clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  [ -e "$FAILURE_ALARM" ] && exit 0
  exit 2
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  write_epoch rewake
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop.
if [ ! -e "$FAILURE_NOTICE" ]; then
  write_epoch failed
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  : > "$FAILURE_NOTICE" 2>/dev/null || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
write_epoch failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
