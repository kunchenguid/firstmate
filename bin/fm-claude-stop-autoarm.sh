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
#   - Identity: only when THIS process proves the state/.lock owner through its
#     harness ancestry or Claude's exact owner-and-root-bound daemon metadata.
#     When an existing numeric owner fails the shared live, non-zombie harness
#     predicate, the hook delegates guarded recovery to bin/fm-lock.sh and then
#     re-verifies ownership. A competing live owner, missing lock, malformed
#     lock, or unresolved ownership remains inert and never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
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
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
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
#     hook. An exhausted arm failure or an eligible claim/publication failure
#     with no verified watcher emits one last-resort notice per failure episode;
#     later consecutive failures still exit 2 to guarantee the next Stop-owned
#     retry without repeating notice, until the synchronous guard has consumed
#     its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, while state/.claude-autoarm-failure-epochs records
# claim failures independently of a contended claim mutex, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The episode-fenced marker directory
# state/.claude-autoarm-failure-notified atomically deduplicates the last-resort notice,
# and the reset/session-owner-scoped state/.claude-autoarm-failure-alarmed
# bounds the attended fail-open and suppresses later automatic continuation in
# that unresolved episode without affecting a successor session.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# A competing live owner and missing or malformed session-lock state remain
# inert, while an eligible stale-owner recovery or generation-claim failure
# records a failed epoch and marker without depending on the contended claim
# mutex.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
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
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

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

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
SESSION_AUTHENTICATED=1
FAILURE_SUPPRESSION_OWNER_PID=
LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in
  ''|*[!0-9]*) exit 0 ;;
esac

autoarm_trace_session_probe() {  # <lock-pid>
  [ -n "${FM_CLAUDE_AUTOARM_TRACE:-}" ] || return 0
  local lock_pid=$1 ancestry pid in_ancestry=0 bridge=0 owned=0
  ancestry=$(fm_harness_ancestry_pids 2>/dev/null || true)
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && in_ancestry=1
  done <<EOF
$ancestry
EOF
  fm_claude_daemon_spawned_by_lock_owner "$lock_pid" "$FM_ROOT" \
    && bridge=1
  fm_session_lock_owned_by_self "$STATE" "$FM_ROOT" \
    && owned=1
  {
    printf 'autoarm_trace hook_pid=%s lock_pid=%s foreground_owner_in_hook_ancestry=%s spawned_by_authorizes_lock_owner=%s session_lock_owned_by_self=%s\n' \
      "$$" "$lock_pid" "$in_ancestry" "$bridge" "$owned"
  } >>"$FM_CLAUDE_AUTOARM_TRACE" 2>/dev/null || true
}

autoarm_trace_session_probe "$LOCK_PID"

SESSION_OWNER_PID=$LOCK_PID
FAILURE_SUPPRESSION_OWNER_PID=$SESSION_OWNER_PID
if ! fm_session_lock_owned_by_self "$STATE" "$FM_ROOT"; then
  SESSION_AUTHENTICATED=0
  FAILURE_SUPPRESSION_OWNER_PID=
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
  if FAILURE_CLAIMANT_PID=$(fm_claude_daemon_spawned_by_session_owner "$FM_ROOT" 2>/dev/null); then
    FAILURE_SUPPRESSION_OWNER_PID=$FAILURE_CLAIMANT_PID
  elif ! fm_claude_daemon_in_session_ancestry \
    && FAILURE_CLAIMANT_PID=$(fm_harness_ancestry_pid 2>/dev/null); then
    FAILURE_SUPPRESSION_OWNER_PID=$FAILURE_CLAIMANT_PID
  fi
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

CLAIM_BASELINE=$(fm_autoarm_claim_signature "$STATE")

autoarm_session_still_owned() {
  [ "$SESSION_AUTHENTICATED" -eq 1 ] \
    && _fm_autoarm_session_authorized \
      "$STATE" "$FM_ROOT" "$SESSION_OWNER_PID" bound
}

autoarm_alarm_current() {
  [ -n "$FAILURE_SUPPRESSION_OWNER_PID" ] || return 1
  fm_autoarm_failure_alarm_current \
    "$STATE" "$FAILURE_NOTICE" "$FAILURE_ALARM" \
    "$FAILURE_SUPPRESSION_OWNER_PID" "$SESSION_OWNER_PID"
}

autoarm_notice_current() {
  fm_autoarm_failure_notice_current \
    "$STATE" "$FAILURE_NOTICE" "$SESSION_OWNER_PID"
}

autoarm_claim_failure() {  # <reason> [baseline]
  local reason=$1 baseline=${2:-$CLAIM_BASELINE} failure_rc authority=bound
  [ "$SESSION_AUTHENTICATED" -eq 1 ] || authority=stale
  autoarm_alarm_current && exit 0
  fm_autoarm_claim_failure_commit \
    "$STATE" "$baseline" failed "$FAILURE_NOTICE" \
    "$FM_ROOT" "$SESSION_OWNER_PID" "$authority" "$FAILURE_SUPPRESSION_OWNER_PID"
  failure_rc=$?
  case "$failure_rc" in
    0|3)
      autoarm_alarm_current && exit 0
      if [ "$failure_rc" -eq 0 ] \
        || [ "$FAILURE_SUPPRESSION_OWNER_PID" != "$SESSION_OWNER_PID" ]; then
        {
          printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism could not claim recovery: %s.\n' "$reason"
          printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook claim path before ending blind.\n'
        } >&2
      fi
      exit 2
      ;;
    4) exit 0 ;;
  esac
  exit 0
}

autoarm_session_current_or_fail() {  # <reason>
  local reason=$1 current_owner failure_baseline
  autoarm_session_still_owned && return 0
  current_owner=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ "$SESSION_AUTHENTICATED" -eq 1 ] \
    && [ "$current_owner" = "$SESSION_OWNER_PID" ] \
    && ! fm_harness_pid_alive "$SESSION_OWNER_PID"; then
    failure_baseline=$(fm_autoarm_claim_signature "$STATE")
    SESSION_AUTHENTICATED=0
    autoarm_claim_failure "$reason" "$failure_baseline"
  fi
  return 1
}

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  RECOVERY_RESULT=$("$SCRIPT_DIR/fm-lock.sh" --autoarm 2>/dev/null) \
    || autoarm_claim_failure 'stale session lock recovery failed'
  case "$RECOVERY_RESULT" in
    'lock acquired: harness pid '*) SESSION_OWNER_PID=${RECOVERY_RESULT##* } ;;
    *) SESSION_OWNER_PID= ;;
  esac
  case "$SESSION_OWNER_PID" in
    ''|*[!0-9]*) autoarm_claim_failure 'stale session lock recovery did not publish a valid owner' ;;
  esac
  SESSION_AUTHENTICATED=1
  autoarm_session_current_or_fail 'recovered session owner died before authentication completed' || exit 0
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. Bounded contention with a bare hold uses the independent
# failure-publication path, while a role-carrying hold is a legacy lock-holding
# claim from a pre-generation build (or the guard's own terminal-check), which
# the legacy shim defers to while genuinely deciding and reclaims once when
# proven abandoned.
autoarm_session_current_or_fail 'authenticated session owner died before generation claim' || exit 0
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
autoarm_session_current_or_fail 'authenticated session owner died before generation publication' || exit 0
fm_autoarm_claim_next "$STATE" "$GRACE" "$FM_ROOT" "$SESSION_OWNER_PID" bound
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  autoarm_session_current_or_fail \
    'authenticated session owner died during generation claim' || exit 0
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  case "$ROLE" in
    autoarm)
      if fm_autoarm_claim_abandoned "$STATE" "$GRACE"; then
        autoarm_session_current_or_fail 'authenticated session owner died before legacy claim recovery' || exit 0
        fm_autoarm_release_abandoned "$STATE" "$GRACE" \
          || autoarm_claim_failure 'abandoned legacy auto-arm claim could not be released'
        autoarm_session_current_or_fail 'authenticated session owner died before recovered generation claim' || exit 0
        fm_autoarm_claim_next "$STATE" "$GRACE" "$FM_ROOT" "$SESSION_OWNER_PID" bound
        CLAIM_RC=$?
        if [ "$CLAIM_RC" -ne 0 ]; then
          autoarm_session_current_or_fail \
            'authenticated session owner died during recovered generation claim' || exit 0
          [ "$CLAIM_RC" -eq 2 ] && exit 0
          autoarm_claim_failure 'generation claim failed after releasing abandoned legacy claim'
        fi
      elif fm_autoarm_legacy_claim_active "$STATE" "$GRACE"; then
        exit 0
      else
        autoarm_claim_failure 'legacy auto-arm claim did not publish a matching ledger'
      fi
      ;;
    terminal-check)
      exit 0
      ;;
    *)
      autoarm_claim_failure 'generation claim could not be recorded'
      ;;
  esac
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || autoarm_claim_failure 'generation claim produced no owner generation'

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Verified supersession makes the caller go silent, while an
# unavailable terminal write publishes an independent failure before the
# caller continues. The harness discards collected stderr on exit 0, so even an
# already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  local commit_rc failure_rc terminal_baseline pid
  autoarm_session_current_or_fail 'authenticated session owner died before terminal commit' || return 2
  if [ -n "${2:-}" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" "$2" "$FM_ROOT" "$SESSION_OWNER_PID" bound
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" '' "$FM_ROOT" "$SESSION_OWNER_PID" bound
  fi
  commit_rc=$?
  autoarm_session_current_or_fail 'authenticated session owner died during terminal commit' || return 2
  [ "$commit_rc" -ne 0 ] || return 0
  [ "$commit_rc" -ne 2 ] || return 2
  autoarm_alarm_current && return 2
  pid=${BASHPID:-$$}
  terminal_baseline="$MY_GEN:$pid:arming"
  fm_autoarm_claim_failure_commit \
    "$STATE" "$terminal_baseline" failed "$FAILURE_NOTICE" \
    "$FM_ROOT" "$SESSION_OWNER_PID" bound "$FAILURE_SUPPRESSION_OWNER_PID"
  failure_rc=$?
  case "$failure_rc" in
    0|3)
      autoarm_alarm_current && return 2
      if [ "$failure_rc" -eq 0 ]; then
        {
          printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism could not commit its terminal outcome.\n'
          printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook commit path before ending blind.\n'
        } >&2
      fi
      return 0
      ;;
    2|4) return 2 ;;
  esac
  return 1
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  autoarm_session_still_owned || return 0
  fm_autoarm_write_owned \
    "$STATE" "$MY_GEN" "$1" '' "$FM_ROOT" "$SESSION_OWNER_PID" bound \
    >/dev/null 2>&1 || true
}

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
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! autoarm_session_current_or_fail 'authenticated session owner died before watcher arm' \
    || ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
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
    autoarm_record afk
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
  autoarm_record clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  if ! autoarm_session_current_or_fail 'authenticated session owner died before watcher reset' \
    || ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  fm_autoarm_reset_owned "$STATE" "$MY_GEN" "$FM_ROOT" "$SESSION_OWNER_PID" bound
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
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    autoarm_alarm_current && exit 0
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if autoarm_alarm_current; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! autoarm_session_current_or_fail 'authenticated session owner died before actionable handoff' \
    || ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  if autoarm_commit rewake; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if ! autoarm_notice_current; then
  if ! autoarm_session_current_or_fail 'authenticated session owner died before failure handoff' \
    || ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
