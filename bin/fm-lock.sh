#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# Usage: fm-lock.sh                 acquire with the established behavior
#        fm-lock.sh status          print holder and liveness; always exit 0
#        fm-lock.sh session-start   bind already-initialized SessionStart state
#                                   before acquiring the lock
#        fm-lock.sh --help          print this contract
#
# `session-start` requires the effective state directory to exist already and
# physically binds it before probe, claim, lock publication, and verification.
# It never creates FM_HOME, state, or a missing FM_STATE_OVERRIDE: initialize a
# canonical primary home first with `fm-home-init.sh <home>`, then run
# SessionStart. Any state-path identity change during the transaction refuses
# rather than following the new target, and removes from the bound state only
# this attempt's claim plus a lock this same attempt published; a lock an
# earlier acquisition of this session already held is left in place, so a
# refusal never frees the original home for a second session. The ordinary
# no-argument and status paths retain their prior mkdir and lock behavior for
# Wake, guards, secondmates, and other callers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
STATE_INPUT=$STATE
MODE=acquire
case "${1:-}" in
  '') ;;
  status) MODE=status ;;
  session-start) MODE=session-start ;;
  -h|--help)
    sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-lock.sh" | sed 's/^# \{0,1\}//; $d'
    exit 0
    ;;
  *)
    printf 'fm-lock: unknown argument: %s\n' "$1" >&2
    printf 'usage: fm-lock.sh [status|session-start]\n' >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: fm-lock.sh [status|session-start]\n' >&2
  exit 2
}

SESSION_START_BOUND=0
BOUND_STATE_PATH=
CALLER_PWD=$(pwd -P 2>/dev/null || true)

state_error() {
  local detail=${1:-}
  if [ -n "$detail" ]; then
    printf 'error: cannot use session-lock state directory %s; %s; operate read-only until resolved\n' \
      "$STATE_INPUT" "$detail" >&2
  else
    printf 'error: cannot create session-lock state directory %s; operate read-only until resolved\n' \
      "$STATE_INPUT" >&2
  fi
  return 1
}

absolute_from_caller() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$CALLER_PWD" "$1" ;;
  esac
}

trim_trailing_slashes() {
  local path=$1
  while [ "$path" != / ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  printf '%s\n' "$path"
}

session_start_binding_current() {
  [ "$SESSION_START_BOUND" -eq 1 ] || return 0
  [ -d "$BOUND_STATE_PATH" ] && [ "$BOUND_STATE_PATH" -ef . ]
}

bind_existing_state() {
  local state_abs parent base physical_parent lookup
  state_abs=$(absolute_from_caller "$STATE_INPUT") || return 1
  state_abs=$(trim_trailing_slashes "$state_abs") || return 1
  parent=$(dirname "$state_abs") || return 1
  base=$(basename "$state_abs") || return 1
  CDPATH='' cd -P -- "$parent" 2>/dev/null || return 1
  physical_parent=$(pwd -P 2>/dev/null) || return 1
  lookup="$physical_parent/$base"
  [ -d "$lookup" ] || return 1
  CDPATH='' cd -P -- "$lookup" 2>/dev/null || return 1
  [ "$lookup" -ef . ] || return 1
  BOUND_STATE_PATH=$lookup
  SESSION_START_BOUND=1
  STATE=.
  LOCK=./.lock
}

initialize_session_start_state() {
  [ -d "$STATE_INPUT" ] || return 1
  bind_existing_state
}

if [ "$MODE" = session-start ]; then
  if [ -z "$CALLER_PWD" ] || ! initialize_session_start_state; then
    state_error 'session-start requires an initialized home and existing state'
    exit 1
  fi
else
  mkdir -p "$STATE" 2>/dev/null || { state_error; exit 1; }
fi

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "$MODE" = status ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
session_start_binding_current || {
  state_error 'session-start home or state identity changed before the lock probe'
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
session_start_binding_current || {
  state_error 'session-start home or state identity changed during the lock probe'
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
if [ "$MODE" = session-start ] && [ "${FM_STATE_OVERRIDE+x}" = x ]; then
  FM_LOCK_SAVED_STATE_OVERRIDE=$FM_STATE_OVERRIDE
  unset FM_STATE_OVERRIDE
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  FM_STATE_OVERRIDE=$FM_LOCK_SAVED_STATE_OVERRIDE
  unset FM_LOCK_SAVED_STATE_OVERRIDE
else
  . "$SCRIPT_DIR/fm-wake-lib.sh"
fi
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

# Set only when THIS invocation published the lock into the bound state, and
# only when no lock of this session was already there. A lock naming this
# harness that predates the write belongs to an earlier acquisition of the same
# session: removing it on refusal would leave the original home unlocked while
# that session is still running, so a second session could claim it.
SESSION_LOCK_PUBLISHED=0

session_lock_names_me() {
  local owner
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  owner=$(cat "$LOCK" 2>/dev/null || true)
  [ "$owner" = "$me" ]
}

remove_own_session_lock() {
  [ "$SESSION_LOCK_PUBLISHED" -eq 1 ] || return 0
  session_lock_names_me || return 0
  rm -f "$LOCK" 2>/dev/null || true
}

refuse_changed_binding() {
  remove_own_session_lock
  release_claim_lock
  state_error 'session-start home or state identity changed during lock acquisition'
  exit 1
}

publish_session_lock() {
  local inherited=0
  session_start_binding_current || return 2
  if session_lock_names_me; then inherited=1; fi
  { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null || return 1
  [ "$inherited" -eq 1 ] || SESSION_LOCK_PUBLISHED=1
  return 0
}

verify_session_lock_publication() {
  written=$(cat "$LOCK" 2>/dev/null) || return 2
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] && [ "$written" = "$me" ] || return 1
  session_start_binding_current || return 3
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    session_start_binding_current || refuse_changed_binding
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
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
session_start_binding_current || refuse_changed_binding

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
publish_session_lock
publish_rc=$?
if [ "$publish_rc" -eq 2 ]; then
  refuse_changed_binding
elif [ "$publish_rc" -ne 0 ]; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
verify_session_lock_publication
verify_rc=$?
case "$verify_rc" in
  0) ;;
  1)
    echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
    exit 1
    ;;
  2)
    echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
    exit 1
    ;;
  3) refuse_changed_binding ;;
esac
release_claim_lock
echo "lock acquired: harness pid $me"
