#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. Line 1 keeps its whole-line pid format because
# every other reader takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation never rewrites line 1 while the recorded pid is alive, because
# bin/fm-startup-network.sh compares that pid across its deferred sweeps; a dead
# recorded pid is reclaimed and rewritten to this session's anchor.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
#        fm-lock.sh take-over --expect-pid PID --expect-session codex:ID|none
#                             Explicitly replace an idle shared Codex daemon
#                             lock after matching its exact pid and sidecar.
#                             Refuses while a watcher is live or either lock
#                             or watcher beacon was recently active. This is
#                             the guarded recovery when a Desktop thread ends
#                             but its shared daemon remains alive.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held)
      if fm_session_lock_shared_codex_pid "$FM_LOCK_INSPECT_PID"; then
        recorded=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
        [ -n "$recorded" ] || recorded=none
        case "$recorded" in
          none)
            echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID (managed Codex daemon; session none)"
            echo "recovery after verified idle: bin/fm-lock.sh take-over --expect-pid $FM_LOCK_INSPECT_PID --expect-session none"
            ;;
          codex:*)
            codex_id=${recorded#codex:}
            case "$codex_id" in
              ''|*[!A-Za-z0-9_-]*) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID (managed Codex daemon; unrecognized sidecar)" ;;
              *)
                echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID (managed Codex daemon; session $recorded)"
                echo "recovery after verified idle: bin/fm-lock.sh take-over --expect-pid $FM_LOCK_INSPECT_PID --expect-session $recorded"
                ;;
            esac
            ;;
          *) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID (managed Codex daemon; unrecognized sidecar)" ;;
        esac
      else
        echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID"
      fi
      ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

TAKEOVER=0
EXPECT_PID=
EXPECT_SESSION=
if [ "${1:-}" = take-over ]; then
  [ "$#" -eq 5 ] && [ "$2" = --expect-pid ] && [ "$4" = --expect-session ] || {
    echo "usage: fm-lock.sh take-over --expect-pid PID --expect-session codex:ID|none" >&2
    exit 2
  }
  TAKEOVER=1
  EXPECT_PID=$3
  EXPECT_SESSION=$5
  case "$EXPECT_PID" in ''|*[!0-9]*) echo "error: expected pid must be numeric" >&2; exit 2 ;; esac
  case "$EXPECT_SESSION" in
    none) ;;
    codex:*)
      codex_id=${EXPECT_SESSION#codex:}
      case "$codex_id" in ''|*[!A-Za-z0-9_-]*) echo "error: expected session must be codex:ID or none" >&2; exit 2 ;; esac
      ;;
    *) echo "error: expected session must be codex:ID or none" >&2; exit 2 ;;
  esac
elif [ "$#" -ne 0 ]; then
  echo "usage: fm-lock.sh [status|take-over --expect-pid PID --expect-session codex:ID|none]" >&2
  exit 2
fi

me=$(fm_session_lock_anchor_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ "$TAKEOVER" -eq 1 ]; then
  fm_session_lock_trusted_session_id >/dev/null || {
    echo "error: take-over requires a verified Claude session or Codex thread identity" >&2
    exit 1
  }
fi
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive; only the sidecar is refreshed, under the
# claim lock, so a /clear re-key inside the same process replaces the old id.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_owned_by_self "$STATE"; then
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

takeover_preflight() {
  local old recorded watcher_pid quiet=${FM_LOCK_TAKEOVER_QUIET_SECONDS:-300}
  case "$quiet" in ''|*[!0-9]*) die_takeover "FM_LOCK_TAKEOVER_QUIET_SECONDS must be numeric" ;; esac
  [ "$quiet" -ge 60 ] && [ "$quiet" -le 3600 ] || die_takeover "quiet interval must be 60-3600 seconds"
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || die_takeover "session lock is missing or unsafe"
  old=$(cat "$LOCK" 2>/dev/null) || die_takeover "session lock is unreadable"
  [ "$old" = "$EXPECT_PID" ] || die_takeover "session lock pid changed"
  recorded=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
  [ -n "$recorded" ] || recorded=none
  [ "$recorded" = "$EXPECT_SESSION" ] || die_takeover "session identity changed"
  fm_session_lock_shared_codex_pid "$old" || die_takeover "recorded owner is not a live managed Codex daemon"
  fm_harness_pid_alive "$old" || die_takeover "recorded owner cannot be verified"
  if [ -e "$STATE/.watch.lock" ] || [ -L "$STATE/.watch.lock" ]; then
    [ -d "$STATE/.watch.lock" ] && [ ! -L "$STATE/.watch.lock" ] \
      || die_takeover "watcher lock is unsafe"
    [ -f "$STATE/.watch.lock/pid" ] && [ ! -L "$STATE/.watch.lock/pid" ] \
      || die_takeover "watcher identity is unreadable"
    watcher_pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null) \
      || die_takeover "watcher identity is unreadable"
    case "$watcher_pid" in ''|*[!0-9]*) die_takeover "watcher identity is malformed" ;; esac
    if fm_pid_alive "$watcher_pid"; then
      die_takeover "a watcher is still live; stop or wait for its own handoff"
    fi
  fi
  [ ! -L "$STATE/.last-watcher-beat" ] || die_takeover "watcher beacon is unsafe"
  [ "$(fm_path_age "$LOCK")" -ge "$quiet" ] || die_takeover "session lock is still recent"
  [ "$(fm_path_age "$STATE/.last-watcher-beat")" -ge "$quiet" ] || die_takeover "watcher beacon is still recent"
}

die_takeover() { echo "error: take-over refused: $1" >&2; exit 1; }

refuse_live_owner() {  # <recorded-pid>
  local recorded
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

if [ "$TAKEOVER" -eq 0 ] && [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if fm_harness_pid_alive "$old"; then
    refuse_live_owner "$old"
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ "$TAKEOVER" -eq 1 ]; then
  takeover_preflight
fi

if [ "$TAKEOVER" -eq 0 ] && { [ -e "$LOCK" ] || [ -L "$LOCK" ]; }; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if ! fm_session_lock_owned_by_self "$STATE" && fm_harness_pid_alive "$old"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if ! fm_session_lock_owned_by_self "$STATE" && fm_harness_pid_alive "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
commit_lock_session
release_claim_lock
if [ "$TAKEOVER" -eq 1 ]; then
  echo "lock taken over: prior managed Codex daemon pid $EXPECT_PID; harness pid $me"
else
  echo "lock acquired: harness pid $me"
fi
