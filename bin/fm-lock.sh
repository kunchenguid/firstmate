#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes a numeric local pid, a tagged Windows pid, or an opaque launch-bound
# native owner identity.
#
# Line 1 of state/.lock is the owning session's identity, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh. Process-backed
# sessions record a verified harness identity that lives as long as the
# firstmate session, unlike the transient subshell PID of any one tool call;
# the experimental native launcher records its opaque generation instead. For
# a Claude session that proves a trusted session id the anchor is CLAUDE_PID,
# the model-loop process, so a shared transient daemon or a front-end that
# outlives the session never keeps a dead session's lock alive. Every reader
# consumes the complete first line as one owner identity.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation never rewrites line 1 while the recorded owner is positively
# live, because bin/fm-startup-network.sh compares that identity across its
# deferred sweeps; a proven-dead recorded owner is reclaimed and rewritten to
# this session's anchor.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#        fm-lock.sh native-admission-predicate
#                             exit 0 only when no owner excludes a native launch
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, owner identity) is owned by the shared session-lock lib so the
# Claude Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_lock_owner_label() {
  case "$1" in
    native:*) printf 'native owner identity %s' "$1" ;;
    *) printf 'harness pid %s' "$1" ;;
  esac
}

fm_lock_holder_label() {
  case "$1" in
    native:*) printf 'native owner identity %s' "$1" ;;
    *) printf 'pid %s' "$1" ;;
  esac
}

fm_lock_conflict_message() {
  local owner_rc recorded
  if ! fm_session_pid_valid "$1"; then
    printf 'error: session lock owner is unrecognized; operate read-only until resolved'
    return 0
  fi
  if fm_harness_pid_alive "$1"; then
    case "$1" in
      native:*) printf 'error: another live firstmate session holds the lock (native owner identity %s); operate read-only until resolved' "$1" ;;
      *)
        if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
          printf 'error: another live firstmate session holds the lock (pid %s, session %s); operate read-only until resolved' "$1" "$recorded"
        else
          printf 'error: another live firstmate session holds the lock (pid %s); operate read-only until resolved' "$1"
        fi
        ;;
    esac
    return 0
  else
    owner_rc=$?
  fi
  if [ "$owner_rc" -ne 1 ]; then
    printf 'error: another firstmate session may hold the lock (%s); operate read-only until resolved' "$(fm_lock_holder_label "$1")"
    return 0
  fi
  return 1
}

fm_lock_native_admission_proves_dead() {
  local wanted=${1#native:} list=${FM_NATIVE_PROVEN_DEAD_GENERATIONS:-} generation found=1
  local IFS=,
  [ -n "$list" ] || return 1
  case "$list" in ,*|*,|*,,*) return 2 ;; esac
  for generation in $list; do
    [ "${#generation}" -eq 32 ] || return 2
    case "$generation" in *[!0-9a-f]*) return 2 ;; esac
    [ "$generation" != "$wanted" ] || found=0
  done
  return "$found"
}

if [ "${1:-}" = "native-admission-predicate" ]; then
  [ "$#" -eq 1 ] || {
    echo "usage: fm-lock.sh native-admission-predicate" >&2
    exit 2
  }
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    exit 0
  fi
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a readable regular file; native launch refused" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; native launch refused" >&2
    exit 1
  }
  if ! fm_session_pid_valid "$old"; then
    echo "error: session lock owner is unrecognized; native launch refused" >&2
    exit 1
  fi
  case "$old" in
    native:*)
      if fm_lock_native_admission_proves_dead "$old"; then
        exit 0
      else
        dead_rc=$?
      fi
      if [ "$dead_rc" -eq 2 ]; then
        echo "error: native dead-generation evidence is unrecognized; native launch refused" >&2
        exit 1
      fi
      ;;
  esac
  if conflict=$(fm_lock_conflict_message "$old"); then
    echo "$conflict" >&2
    exit 1
  fi
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if ! fm_session_pid_valid "$old"; then
    echo "lock: held by unrecognized owner with unknown health"
  else
    if fm_harness_pid_alive "$old"; then
      echo "lock: held by live $(fm_lock_owner_label "$old")"
    else
      owner_rc=$?
      if [ "$owner_rc" -eq 1 ]; then
        echo "lock: stale ($(fm_lock_holder_label "$old") dead or not a harness)"
      else
        case "$old" in
          native:*) echo "lock: held by native owner with unconfirmed health $old" ;;
          *) echo "lock: held by owner with unconfirmed health ($(fm_lock_holder_label "$old"))" ;;
        esac
      fi
    fi
  fi
  exit 0
fi

me=$(fm_session_lock_anchor_pid) || {
  if fm_win_boundary_applies; then
    # Here the parent link does not reach the harness at all, so "not in the
    # ancestry" would describe the wrong problem and send the reader hunting a
    # process tree that can never contain the answer.
    echo "error: cannot identify this harness session on Windows: it publishes no session pid this build recognizes (see FM_WIN_HARNESS_PID_VARS in bin/fm-session-lock-lib.sh); operate read-only until resolved" >&2
  else
    echo "error: cannot locate harness process in ancestry" >&2
  fi
  exit 1
}
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

# This session already holds the lock under identity $1. Line 1 stays exactly
# as recorded while that owner is live; only the sidecar is refreshed, under the
# claim lock, so a /clear re-key inside the same process replaces the old id.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-owner>
  local recorded waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: $(fm_lock_owner_label "$recorded")"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if conflict=$(fm_lock_conflict_message "$old"); then
    echo "$conflict" >&2
    exit 1
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

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ]; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ "$old" != "$me" ] && conflict=$(fm_lock_conflict_message "$old"); then
      echo "$conflict" >&2
      exit 1
    fi
  fi
fi
# The sidecar goes first: a fresh owner beside a previous session's id would let
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
echo "lock acquired: $(fm_lock_owner_label "$me")"
