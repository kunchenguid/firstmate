#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes. Cursor calls
# this guard back with --cursor from bin/fm-turnend-guard-cursor.sh and renders
# exit 2 as one bounded follow-up, because exit 2 is a silent no-op on Cursor's
# stop step; without that flag a Cursor-shaped payload is the Claude-settings
# duplicate Cursor also loads, and this guard stands down.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Away mode (state/.afk): the away-mode daemon owns supervision and runs the
# watcher one-shot, restarting it after every wake, so the watch lock is
# regularly unheld at a turn boundary with nothing wrong. A live
# identity-matched daemon holding this home, plus a fresh beacon, is what
# proves supervision there - see fm_afk_daemon_owns_supervision in
# bin/fm-wake-lib.sh. The beacon freshness test there uses AFK_GRACE
# (fm_poll_derived_grace, docs/turnend-guard.md "Guard grace and the poll
# cadence"), not the flat $GRACE every other check on this page uses: the
# daemon starts a fresh one-shot watcher only after it finishes handling the
# previous wake, and that handling can legitimately run past a flat 300s
# window under load (a slow registered check, a busy supervisor pane) with the
# daemon perfectly healthy throughout. The strict watcher predicate and $GRACE
# are unchanged everywhere else, including for a dead daemon pid or a beacon
# older than AFK_GRACE, which still block.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon - or, in away mode, a
#      live identity-matched daemon with a fresh beacon - allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (a live OPEN generation claim in the
#      state/.claude-autoarm-epoch ledger - fm_autoarm_claim_open - or a legacy
#      build's lock-holding claim under the legacy abandonment proof) or to
#      record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one recovery turn;
#      the first fresh exhausted-failure epoch preserves the bounded progression,
#      while later fresh failed epochs consume it instead of resetting it;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open only for an already verified failure episode. The budget
#      charges each event epoch once, and it also charges every re-block
#      against an epoch the auto-arm never advanced past the previous
#      re-block (budget_account_current_epoch owns that rule), so an inert
#      hook that leaves the ledger frozen cannot hold the guard in an
#      unbounded re-block loop below that override.
#   4. one case cannot be repaired from inside the session at all: state/.lock
#      names a LIVE harness process outside this session's ancestry
#      (bin/fm-session-lock-lib.sh), so the session is read-only by the
#      session-start contract, may not arm or repair supervision, and its own
#      auto-arm exits without claiming. Re-blocking it past the budget only
#      wedges a session that cannot act (2026-09-12: ~30 blocked turns). Once
#      the budget above is spent and no verified failure episode exists, the
#      guard therefore releases the turn with an OWNERSHIP-UNRESOLVED
#      escalation: a systemMessage naming the live owner, the supervision need,
#      and that this is not a completion attestation. Every re-block on that
#      path already told the model it is read-only and must report to the
#      captain. A dead owner, a missing lock, or a malformed lock is not this
#      case and keeps blocking, because the session can still take the lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
CURSOR_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    --cursor) CURSOR_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude|--cursor]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

# A Cursor primary also loads the tracked Claude settings, and Cursor's own
# registration owns its turn boundary through bin/fm-turnend-guard-cursor.sh,
# which calls this guard back with --cursor. Without that flag a Cursor-delivered
# payload is the Claude-compatibility duplicate and must not create a second
# continuation path (docs/turnend-guard.md "Harness integrations").
if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  exit 0
fi

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  fm_lock_try_acquire "$BUDGET_LOCK" || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  fm_lock_release "$BUDGET_LOCK"
}

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ]; then
  [ -e "$FAILURE_NOTICE" ] || budget_reset
  exit 0
fi
# One owner of the "supervision is on, let this turn end" exit contract, shared
# by every proof of supervision below.
allow_supervised_stop() {
  [ "$CLAUDE_MODE" -eq 1 ] || exit 0
  fm_failure_episode_reset "$STATE" && exit 0
  exit 2
}

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  allow_supervised_stop
fi

# Away mode transfers supervision ownership from the watcher to the away-mode
# daemon, which runs the watcher one-shot and starts its replacement after every
# wake (bin/fm-supervise-daemon.sh). A turn boundary regularly lands in that
# hand-off, when no watcher process holds the lock and nothing is wrong, so
# requiring one here alarmed on healthy away-mode supervision. A live
# identity-matched daemon holding this home is the right owner to test for.
# The beacon half of the predicate still applies: a daemon that stops
# restarting its watcher still blocks once the beacon passes grace, and a home
# with no daemon and no watcher blocks exactly as before. It uses AFK_GRACE
# (poll-cadence-derived, see the comment above) instead of the flat $GRACE
# every other check on this page uses, so a daemon that is genuinely still
# cycling - just slower than a fixed 300s window - is not misread as down.
AFK_GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
if [ "$(fm_path_age "$STATE/.last-watcher-beat")" -lt "$AFK_GRACE" ] \
  && fm_afk_daemon_owns_supervision "$STATE"; then
  allow_supervised_stop
fi

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
      printf '●  %s registered custom check(s), but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_CHECKS" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
    fi
    if [ -n "${LOCK_REFUSED_PID:-}" ]; then
      printf '●  Another live session (harness pid %s) holds this home'"'"'s session lock, so this session is read-only: do not arm, steer, or repair supervision from here - report this to the captain now (bin/fm-lock.sh status names the owner).\n' "$LOCK_REFUSED_PID"
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns recovery for this event epoch before consuming one of
# Claude's bounded continuations.
# Session-lock identity is needed only on this path, so the other harness
# adapters' fixtures need not carry it.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
#
# Budget accounting, under the budget lock. Sets COUNT (the session's
# consumed continuations, including this one) and BUDGET_INITIALIZED_FAILURE.
# The ledger's epoch identity is what is charged: a new epoch charges once,
# and an epoch this same invocation already charged is never charged again,
# because the wait loop above can observe one fresh terminal epoch many times
# before the block decision. Across Stops the two callers differ:
#   - observe (the allow paths in autoarm_owns_recovery): seeing an
#     already-charged epoch again is free - it is the same claim, seen again.
#   - block (the re-block path): a re-block against the epoch the previous
#     re-block already charged is a new consumed continuation, because the
#     auto-arm advanced nothing between the two Stops - it did not participate
#     at all, which is exactly the absence this budget bounds. Charging only
#     epoch changes let an inert hook (identity-gated, never fired, or failing
#     before its generation claim) freeze the ledger and the count together,
#     so the guard re-blocked without limit and the attended fail-open below
#     never became reachable.
BUDGET_CHARGED_EPOCH=
budget_account_current_epoch() {  # [observe|block]
  local mode=${1:-observe} current_epoch outcome old_session old_count old_epoch tmp initialized charged
  fm_lock_try_acquire "$BUDGET_LOCK" || return 1
  current_epoch=$(sed -n '1s/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  initialized=0
  charged=0
  COUNT=0
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    if [ "$old_session" = "$SESSION_ID" ]; then
      COUNT=$old_count
      if [ -n "$current_epoch" ] && [ "$old_epoch" = "$current_epoch" ]; then
        if [ "$mode" = block ] && [ "$BUDGET_CHARGED_EPOCH" != "$current_epoch" ]; then
          COUNT=$((COUNT + 1))
          charged=1
        fi
      else
        COUNT=$((COUNT + 1))
        charged=1
      fi
    fi
  fi
  if [ ! -f "$BUDGET_FILE" ] || [ "${old_session:-}" != "$SESSION_ID" ]; then
    charged=1
    case "$outcome" in
      failed|failed-suppressed)
        if [ -e "$FAILURE_NOTICE" ]; then
          initialized=1
          COUNT=0
        else
          COUNT=1
        fi
        ;;
      *) COUNT=1 ;;
    esac
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$current_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  [ "$charged" -eq 0 ] || BUDGET_CHARGED_EPOCH=$current_epoch
  BUDGET_INITIALIZED_FAILURE=$initialized
  fm_lock_release "$BUDGET_LOCK"
  return 0
}

autoarm_owns_recovery() {
  local pid role outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  # A live OPEN generation claim owns recovery: the ledger names a live,
  # identity-matched owner still arming that is not stuck (fm_autoarm_claim_open
  # in bin/fm-wake-lib.sh owns that predicate). A finished, dead,
  # identity-mismatched, or stuck claim deliberately fails it and falls
  # through, because treating such a claim as ownership is what let a dead
  # watcher go unnoticed for turn after turn; the outcome cases below still
  # cover a claim that finished moments ago, so a genuine handoff is not
  # duplicated, while a stale one now reaches the block.
  if fm_autoarm_claim_open "$STATE" "$GRACE"; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  # Legacy shim: a pre-generation build's claim holds the owner lock with the
  # autoarm role for its whole cycle; defer to it under the legacy abandonment
  # proof so an upgrade mid-session cannot double-arm.
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if fm_pid_alive "$pid" && [ "$role" = autoarm ] \
    && ! fm_autoarm_claim_abandoned "$STATE" "$GRACE"; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    rewake)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ]; then
        [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
        return 0
      fi
      ;;
    failed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        [ "$BUDGET_INITIALIZED_FAILURE" -eq 1 ] && return 0
      fi
      ;;
    failed-suppressed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        :
      fi
      ;;
  esac
  return 1
}

terminal_fail_open() {
  local pid role old_session old_count
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  failure_episode_verified || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  # A live open generation claim is a concurrent recovery decision to step
  # aside for, exactly like the legacy live-owner case below.
  fm_autoarm_claim_open "$STATE" "$GRACE" && return 2
  if ! fm_lock_try_acquire "$OWNER_LOCK"; then
    pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
    role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
    # Same legacy abandonment test as autoarm_owns_recovery: a claim whose
    # ledger entry is already terminal, or whose recorded pid-identity no
    # longer matches the live pid, is not a concurrent owner to step aside
    # for. Stepping aside for one here allows the stop silently, and the
    # episode's one attended alarm would never fire, so clear the abandoned
    # claim and let this decision finish instead. Failing to clear it
    # re-blocks rather than allowing.
    if fm_pid_alive "$pid" && [ "$role" = autoarm ] \
      && ! fm_autoarm_claim_abandoned "$STATE" "$GRACE"; then
      return 2
    fi
    fm_autoarm_release_abandoned "$STATE" "$GRACE" || return 1
    fm_lock_try_acquire "$OWNER_LOCK" || return 1
  fi
  if ! fm_lock_set_role "$OWNER_LOCK" terminal-check; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if ! fm_lock_try_acquire "$BUDGET_LOCK"; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if [ "$role" != terminal-check ] || [ "$old_session" != "$SESSION_ID" ] \
    || [ "$old_count" -le "$BLOCK_BUDGET" ] || ! failure_episode_verified \
    || [ -e "$FAILURE_ALARM" ]; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    if ! fm_failure_episode_reset "$STATE" held; then
      fm_lock_release "$BUDGET_LOCK"
      fm_lock_release "$OWNER_LOCK"
      return 1
    fi
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 2
  fi
  # Re-check for a live open generation claim now that both locks are held: a
  # claimant that published "arming" between the pre-check above and the lock
  # acquisition is active recovery, and alarming over it would fire the
  # episode's one attended fail-open while a continuation is under way.
  if fm_autoarm_claim_open "$STATE" "$GRACE"; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 2
  fi
  if ! (set -C; : > "$FAILURE_ALARM") 2>/dev/null; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$BUDGET_LOCK"
  fm_lock_release "$OWNER_LOCK"
  return 0
}

failure_episode_verified() {
  local outcome
  [ ! -e "$STATE/.afk" ] || return 1
  [ -e "$FAILURE_NOTICE" ] || return 1
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    failed|failed-suppressed) return 0 ;;
    *) return 1 ;;
  esac
}

need_desc() {
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    printf '%s task(s) in flight' "$FM_SUP_IN_FLIGHT"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    printf '%s process-event source(s) registered' "$FM_SUP_SOURCES"
  elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
    printf '%s registered custom check(s)' "$FM_SUP_CHECKS"
  else
    printf 'X-mode relay polling active'
  fi
}

# Sets LOCK_REFUSED_PID when state/.lock names a live harness process outside
# this session's ancestry: the one condition the session cannot repair. A dead
# owner, a missing lock, or a malformed lock leaves it empty.
LOCK_REFUSED_PID=
lock_refused_owner() {
  local lock_pid
  LOCK_REFUSED_PID=
  fm_session_lock_owned_by_self "$STATE" && return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_pid_alive "$lock_pid" || return 1
  LOCK_REFUSED_PID=$lock_pid
}

i=0
while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
  if autoarm_owns_recovery; then
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      fm_failure_episode_reset "$STATE" || exit 2
    fi
    exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
if autoarm_owns_recovery; then
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || exit 2
  fi
  exit 0
fi

# The auto-arm genuinely failed to establish: consume the bounded re-block
# budget before considering the verified one-time attended fail-open.
lock_refused_owner || true
budget_account_current_epoch block || block_stop
terminal_fail_open
terminal_status=$?
if [ "$terminal_status" -eq 0 ]; then
  printf '{"systemMessage":"FIRSTMATE SUPERVISION IS GENUINELY DOWN: %s, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."}\n' "$(need_desc)"
  exit 0
fi
[ "$terminal_status" -eq 2 ] && exit 0

# --- ownership-unresolved escalation --------------------------------------------
# The budget is spent, no verified failure episode exists, and the lock is
# held by another live session: this session cannot own supervision by
# contract, so re-blocking cannot lead anywhere. Release the turn to the
# operator with the evidence, explicitly not as a completion attestation. The
# owning session's own guard, the attended alarm, and every marker stay
# untouched; a healthy watcher, a dead owner, or away mode never reaches here,
# and a verified failure episode keeps its own attended shape above (one
# alarm, then attended re-blocks) even under a foreign owner.
if [ -n "$LOCK_REFUSED_PID" ] && [ "$COUNT" -gt "$BLOCK_BUDGET" ] && [ ! -e "$STATE/.afk" ] \
  && ! failure_episode_verified; then
  printf '{"systemMessage":"FIRSTMATE CANNOT ESTABLISH SUPERVISION OWNERSHIP: %s and no watcher beacon is fresh (last beat: %s), but another live session (harness pid %s) holds this home'"'"'s session lock, so this session is read-only by contract and has already been blocked %s times. The turn is released to the operator; this is NOT a completion attestation, and supervision of that work is unverified from this session. The lock-holding session'"'"'s own turn-end guard is responsible - run bin/fm-lock.sh status to see the owner."}\n' \
    "$(need_desc)" "$FM_SUP_BEACON_DESC" "$LOCK_REFUSED_PID" "$BLOCK_BUDGET"
  exit 0
fi
block_stop
