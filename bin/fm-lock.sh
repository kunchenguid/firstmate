#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_GENERATION="$STATE/.lock-generation"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

write_lock_generation() { # <owner-pid>
  local owner=$1 current_owner current_generation current_identity identity identity_hash tmp token
  local existing_lock_owned=0
  identity=$(fm_pid_identity "$owner") || return 1
  if command -v shasum >/dev/null 2>&1; then
    identity_hash=$(printf '%s' "$identity" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    identity_hash=$(printf '%s' "$identity" | sha256sum 2>/dev/null | awk '{print $1}') || return 1
  else
    return 1
  fi
  if [ -f "$LOCK" ] && [ ! -L "$LOCK" ] \
    && [ "$(cat "$LOCK" 2>/dev/null || true)" = "$owner" ]; then
    existing_lock_owned=1
  fi
  if [ "$existing_lock_owned" -eq 1 ] \
    && [ -f "$LOCK_GENERATION" ] && [ ! -L "$LOCK_GENERATION" ]; then
    current_owner=$(sed -n '2p' "$LOCK_GENERATION" 2>/dev/null || true)
    current_generation=$(sed -n '3p' "$LOCK_GENERATION" 2>/dev/null || true)
    current_identity=$(sed -n '4p' "$LOCK_GENERATION" 2>/dev/null || true)
    case "$current_generation" in *[!A-Za-z0-9._-]*|'') current_generation= ;; esac
    if [ "$current_owner" = "$owner" ] && [ -n "$current_generation" ] \
      && [ "$(sed -n '1p' "$LOCK_GENERATION" 2>/dev/null || true)" = fm-session-lock-generation-v1 ] \
      && [ "$current_identity" = "$identity_hash" ] \
      && [ "$(wc -l < "$LOCK_GENERATION" 2>/dev/null | tr -d '[:space:]')" = 4 ]; then
      return 0
    fi
  fi
  token="$(date +%s).${owner}.${RANDOM:-0}"
  tmp=$(mktemp "$STATE/.lock-generation.XXXXXX") || return 1
  if ! printf 'fm-session-lock-generation-v1\n%s\n%s\n%s\n' "$owner" "$token" "$identity_hash" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$LOCK_GENERATION"; then
    rm -f -- "$tmp"
    return 1
  fi
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
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

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    write_lock_generation "$me" || {
      echo "error: cannot publish session-lock generation; operate read-only until resolved" >&2
      exit 1
    }
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
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
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
if ! write_lock_generation "$me"; then
  rm -f "$LOCK" 2>/dev/null || true
  echo "error: cannot publish session-lock generation; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
