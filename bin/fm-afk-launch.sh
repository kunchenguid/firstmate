#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon lifecycle and any
# compatibility terminal it needs.
# It records exact ownership, tears a terminal down by exact id, and reconciles
# a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct compatibility-targeting: a terminal-backed daemon would discover its
# own pane, so this captures the captain pane first and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND for legacy injection delivery.
# Native tracked launches use task completion and never inspect a pane.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon while
#                              state/.afk is still present, wait for it, close the
#                              recorded terminal by exact id, then clear
#                              state/.afk last. Native delivery preserves its
#                              buffer for catch-up; compatibility injection may
#                              perform its final guarded flush during cleanup.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_NAMESPACE_GUARD="$FM_AFK_LAUNCH_STATE/.afk-launch.namespace.guard"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_state_prepare() {
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  [ -d "$FM_AFK_LAUNCH_STATE" ] && [ ! -L "$FM_AFK_LAUNCH_STATE" ]
}

FM_AFK_LAUNCH_LOCK_TOKEN=

fm_afk_launch_path_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%B' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%W' "$1" 2>/dev/null
  fi
}

fm_afk_launch_file_size() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z' "$1" 2>/dev/null
  else
    stat -c '%s' "$1" 2>/dev/null
  fi
}

fm_afk_launch_copy_bounded() {  # <source> <destination>
  local source=$1 destination=$2 expected actual pending cap=1048576
  expected=$(fm_afk_launch_file_size "$source") || return 1
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected" -le "$cap" ] || return 1
  pending=$(mktemp "$destination.pending.XXXXXX") || return 1
  if ! fm_afk_safe_control_copy "$source" "$pending" "$cap" 2>/dev/null; then
    rm -f "$pending"
    return 1
  fi
  actual=$(LC_ALL=C wc -c < "$pending" | tr -d '[:space:]') || {
    rm -f "$pending"
    return 1
  }
  if [ "$actual" != "$expected" ] \
    || [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$destination" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_read_control() {
  local file=$1 snapshot bytes cap=4096
  snapshot=$({
    fm_afk_safe_control_read "$file" "$cap" 2>/dev/null || exit 1
    printf '\034'
  }) || return 1
  case "$snapshot" in *$'\034') ;; *) return 1 ;; esac
  snapshot=${snapshot%$'\034'}
  bytes=$(printf '%s' "$snapshot" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$cap" ] || return 1
  printf '%s' "$snapshot"
}

fm_afk_launch_directory_owned() {  # <directory>
  [ "$(fm_afk_launch_directory_owner_state "$1")" = alive ]
}

fm_afk_launch_pid_existence_state() {  # <pid> -> exists | absent | unknown
  local pid=$1
  case "$pid" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  python3 -c '
import os
import sys

try:
    os.kill(int(sys.argv[1]), 0)
except ProcessLookupError:
    print("absent")
except (PermissionError, ValueError, OSError):
    print("unknown")
else:
    print("exists")
' "$pid" 2>/dev/null || printf 'unknown\n'
}

fm_afk_launch_directory_owner_state() {  # <directory> -> alive | dead | unknown
  local directory=$1 pid expected actual existence
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  pid=$(fm_afk_launch_read_control "$directory/pid") || { printf 'unknown\n'; return 0; }
  expected=$(fm_afk_launch_read_control "$directory/pid-identity") || { printf 'unknown\n'; return 0; }
  case "$pid" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  [ -n "$expected" ] || { printf 'unknown\n'; return 0; }
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || {
    existence=$(fm_afk_launch_pid_existence_state "$pid")
    if [ "$existence" = absent ]; then printf 'dead\n'; else printf 'unknown\n'; fi
    return 0
  }
  if [ "$actual" = "$expected" ]; then printf 'alive\n'; else printf 'dead\n'; fi
}

fm_afk_launch_lock_owned() {
  fm_afk_launch_directory_owned "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_directory_identity() {  # <directory>
  local directory=$1 path_identity confirmed_identity token token_state
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  path_identity=$(fm_afk_launch_path_identity "$directory") || return 1
  # Filesystems can reuse an inode within the birth-time stat's one-second
  # precision, so bind the path identity to this directory generation's token.
  # A missing legacy token is a real, distinct state; an unreadable or unsafe
  # token is an identity failure, never silently equivalent to a missing one.
  if [ -L "$directory/token" ]; then
    return 1
  elif [ -e "$directory/token" ]; then
    token=$(fm_afk_launch_read_control "$directory/token") || return 1
    token_state="present:${#token}:$token"
  else
    token_state=missing
  fi
  confirmed_identity=$(fm_afk_launch_path_identity "$directory") || return 1
  [ "$confirmed_identity" = "$path_identity" ] || return 1
  printf '%s:%s\n' "$path_identity" "$token_state"
}

fm_afk_launch_lock_identity() {
  fm_afk_launch_directory_identity "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_atomic_rename() {
  if command -v node >/dev/null 2>&1; then
    node -e 'try { require("node:fs").renameSync(process.argv[1], process.argv[2]); } catch { process.exit(1); }' "$1" "$2"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' "$1" "$2"
  else
    return 1
  fi
}

fm_afk_launch_reclaim_owned() {
  fm_afk_launch_directory_owned "$1"
}

FM_AFK_LAUNCH_RECLAIM_TEST_SEEN=:
fm_afk_launch_reclaim_test_handshake() {  # <phase>
  local phase=$1 response ready_fd proceed_fd
  [ -n "${FM_AFK_LAUNCH_RECLAIM_TEST_READY:-}" ] \
    && [ -n "${FM_AFK_LAUNCH_RECLAIM_TEST_PROCEED:-}" ] || return 0
  case ":${FM_AFK_LAUNCH_RECLAIM_TEST_PHASES:-}:" in *":$phase:"*) ;; *) return 0 ;; esac
  case "$FM_AFK_LAUNCH_RECLAIM_TEST_SEEN" in *":$phase:"*) return 0 ;; esac
  ready_fd=$FM_AFK_LAUNCH_RECLAIM_TEST_READY
  proceed_fd=$FM_AFK_LAUNCH_RECLAIM_TEST_PROCEED
  case "$ready_fd:$proceed_fd" in
    *[!0-9:]*|:*) return 1 ;;
  esac
  [ "$ready_fd" -ge 3 ] 2>/dev/null && [ "$ready_fd" -le 255 ] \
    && [ "$proceed_fd" -ge 3 ] 2>/dev/null && [ "$proceed_fd" -le 255 ] || return 1
  [ "$ready_fd" != "$proceed_fd" ] || return 1
  FM_AFK_LAUNCH_RECLAIM_TEST_SEEN="${FM_AFK_LAUNCH_RECLAIM_TEST_SEEN}${phase}:"
  printf '%s\n' "$phase" >&"$ready_fd" || return 1
  IFS= read -r -t 5 -u "$proceed_fd" response || return 1
  [ "$response" = proceed ]
}

FM_AFK_LAUNCH_NAMESPACE_GUARD_PID=
FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=
FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD=0
# The canonical lock pathname cannot itself fence a rename-away gap. Keep a
# sibling inode permanently named. The mutating shell opens fd 17; a short-lived
# helper validates and flocks that inherited open-file description, then exits
# before mutation. The shell's duplicate keeps the flock until guarded work is
# complete, and a crashed shell releases it in the kernel. There is no second
# stale-lock protocol and helper death cannot unlock an active mutator.
fm_afk_launch_namespace_guard_release() {
  local result=0
  if [ -n "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" ]; then
    kill "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" 2>/dev/null || true
    wait "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" 2>/dev/null || result=1
  fi
  { exec 17>&-; } 2>/dev/null || true
  { exec 18>&-; } 2>/dev/null || true
  [ -z "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR" ] \
    || rm -rf "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR" 2>/dev/null || result=1
  FM_AFK_LAUNCH_NAMESPACE_GUARD_PID=
  FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=
  FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD=0
  return "$result"
}

fm_afk_launch_namespace_guard_acquire() {
  local ready response helper_status=0
  [ -z "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" ] \
    && [ "$FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD" -eq 0 ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c '
import os
import stat
import sys

if not hasattr(os, "O_NOFOLLOW"):
    raise RuntimeError("namespace guard requires O_NOFOLLOW")
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise RuntimeError("namespace guard is not a regular file")
finally:
    os.close(fd)
' "$FM_AFK_LAUNCH_NAMESPACE_GUARD" 2>/dev/null || return 1
  exec 17<> "$FM_AFK_LAUNCH_NAMESPACE_GUARD" || return 1
  FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-namespace-guard.XXXXXX") \
    || { exec 17>&-; return 1; }
  ready="$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR/ready"
  mkfifo "$ready" || { exec 17>&-; rm -rf "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR"; FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=; return 1; }
  exec 18<> "$ready" \
    || { exec 17>&-; rm -rf "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR"; FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=; return 1; }
  python3 -c '
import fcntl
import os
import stat
import sys

held = os.fstat(17)
named = os.lstat(sys.argv[1])
if not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode):
    raise RuntimeError("namespace guard is not a regular file")
if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
    raise RuntimeError("namespace guard pathname changed before flock")
fcntl.flock(17, fcntl.LOCK_EX)
confirmed = os.lstat(sys.argv[1])
if (held.st_dev, held.st_ino) != (confirmed.st_dev, confirmed.st_ino):
    raise RuntimeError("namespace guard pathname changed while acquiring flock")
try:
    os.write(1, b"ready\n")
finally:
    for leaf in ("ready", "error"):
        try:
            os.unlink(os.path.join(sys.argv[2], leaf))
        except FileNotFoundError:
            pass
    try:
        os.rmdir(sys.argv[2])
    except FileNotFoundError:
        pass
' "$FM_AFK_LAUNCH_NAMESPACE_GUARD" "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR" >&18 18>&- \
    2> "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR/error" &
  FM_AFK_LAUNCH_NAMESPACE_GUARD_PID=$!
  if ! IFS= read -r -t 5 -u 18 response || [ "$response" != ready ]; then
    fm_afk_launch_namespace_guard_release >/dev/null 2>&1 || true
    return 1
  fi
  wait "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" || helper_status=$?
  FM_AFK_LAUNCH_NAMESPACE_GUARD_PID=
  { exec 18>&-; } 2>/dev/null || true
  rm -rf "$FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR" 2>/dev/null || helper_status=1
  FM_AFK_LAUNCH_NAMESPACE_GUARD_DIR=
  if [ "$helper_status" -ne 0 ]; then
    { exec 17>&-; } 2>/dev/null || true
    return 1
  fi
  FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD=1
}

fm_afk_launch_restore_quarantine() {  # <quarantine> <destination> <path-identity>
  local quarantine=$1 destination=$2 expected=$3 actual restored
  [ -d "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
  actual=$(fm_afk_launch_path_identity "$quarantine") || return 1
  [ "$actual" = "$expected" ] || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  fm_afk_launch_atomic_rename "$quarantine" "$destination" || return 1
  restored=$(fm_afk_launch_path_identity "$destination") || return 1
  [ "$restored" = "$expected" ]
}

FM_AFK_LAUNCH_TRANSACTION_QUARANTINE=
FM_AFK_LAUNCH_TRANSACTION_DESTINATION=
FM_AFK_LAUNCH_TRANSACTION_IDENTITY=
fm_afk_launch_transaction_begin() {  # <quarantine> <destination> <path-identity>
  FM_AFK_LAUNCH_TRANSACTION_QUARANTINE=$1
  FM_AFK_LAUNCH_TRANSACTION_DESTINATION=$2
  FM_AFK_LAUNCH_TRANSACTION_IDENTITY=$3
}

fm_afk_launch_transaction_clear() {
  FM_AFK_LAUNCH_TRANSACTION_QUARANTINE=
  FM_AFK_LAUNCH_TRANSACTION_DESTINATION=
  FM_AFK_LAUNCH_TRANSACTION_IDENTITY=
}

fm_afk_launch_transaction_rollback() {
  [ -n "$FM_AFK_LAUNCH_TRANSACTION_QUARANTINE" ] || return 0
  if [ -d "$FM_AFK_LAUNCH_TRANSACTION_QUARANTINE" ] \
    && [ ! -L "$FM_AFK_LAUNCH_TRANSACTION_QUARANTINE" ] \
    && [ ! -e "$FM_AFK_LAUNCH_TRANSACTION_DESTINATION" ]; then
    fm_afk_launch_restore_quarantine \
      "$FM_AFK_LAUNCH_TRANSACTION_QUARANTINE" \
      "$FM_AFK_LAUNCH_TRANSACTION_DESTINATION" \
      "$FM_AFK_LAUNCH_TRANSACTION_IDENTITY" || return 1
  elif [ -e "$FM_AFK_LAUNCH_TRANSACTION_QUARANTINE" ] \
    || [ ! -e "$FM_AFK_LAUNCH_TRANSACTION_DESTINATION" ]; then
    return 1
  fi
  fm_afk_launch_transaction_clear
}

fm_afk_launch_remove_owned_reclaim() {  # <reclaim> <token>
  local reclaim=$1 expected_token=$2 identity confirmed quarantine quarantined_identity token
  identity=$(fm_afk_launch_directory_identity "$reclaim") || return 1
  token=$(fm_afk_launch_read_control "$reclaim/token") || return 1
  [ "$token" = "$expected_token" ] || return 1
  quarantine="${reclaim}.release.${expected_token}.$$.$RANDOM"
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
  confirmed=$(fm_afk_launch_directory_identity "$reclaim") || return 1
  [ "$confirmed" = "$identity" ] || return 1
  fm_afk_launch_atomic_rename "$reclaim" "$quarantine" || return 1
  quarantined_identity=$(fm_afk_launch_directory_identity "$quarantine") || {
    confirmed=$(fm_afk_launch_path_identity "$quarantine" 2>/dev/null || true)
    [ -z "$confirmed" ] || fm_afk_launch_restore_quarantine "$quarantine" "$reclaim" "$confirmed" >/dev/null 2>&1 || true
    return 1
  }
  token=$(fm_afk_launch_read_control "$quarantine/token") || {
    confirmed=$(fm_afk_launch_path_identity "$quarantine" 2>/dev/null || true)
    [ -z "$confirmed" ] || fm_afk_launch_restore_quarantine "$quarantine" "$reclaim" "$confirmed" >/dev/null 2>&1 || true
    return 1
  }
  if [ "$quarantined_identity" != "$identity" ] || [ "$token" != "$expected_token" ]; then
    confirmed=$(fm_afk_launch_path_identity "$quarantine" 2>/dev/null || true)
    [ -z "$confirmed" ] || fm_afk_launch_restore_quarantine "$quarantine" "$reclaim" "$confirmed" >/dev/null 2>&1 || true
    return 1
  fi
  rm -rf "$quarantine"
}

FM_AFK_LAUNCH_LOCK_INCOMPLETE=0
FM_AFK_LAUNCH_LOCK_LAST_IDENTITY=
fm_afk_launch_lock_try_guarded() {  # <attempt> <ownerless-grace>; 0 acquired, 2 retry
  local i=$1 ownerless_grace=$2 identity quarantine quarantine_identity lock_path_identity
  local stale_identity claimed_identity candidate claim_candidate reclaim reclaim_identity reclaim_path_identity
  local confirmed_reclaim_identity owned_reclaim_identity reclaim_quarantine reclaim_quarantine_identity
  local token reclaim_token owner_state reclaim_owner_state
  if [ -L "$FM_AFK_LAUNCH_LOCK" ] \
    || { [ -e "$FM_AFK_LAUNCH_LOCK" ] && [ ! -d "$FM_AFK_LAUNCH_LOCK" ]; }; then
    fm_afk_launch_log "refusing unsafe launcher lock: $FM_AFK_LAUNCH_LOCK"
    return 1
  fi
  if [ ! -e "$FM_AFK_LAUNCH_LOCK" ]; then
    candidate=$(mktemp -d "$FM_AFK_LAUNCH_LOCK.candidate.XXXXXX" 2>/dev/null) || return 2
    token=${candidate##*.candidate.}
    identity=$(fm_pid_identity "$$" 2>/dev/null) || { rm -rf "$candidate"; return 1; }
    if [ -z "$identity" ] \
      || ! printf '%s' "$$" > "$candidate/pid" \
      || ! printf '%s' "$identity" > "$candidate/pid-identity" \
      || ! printf '%s' "$token" > "$candidate/token"; then
      rm -rf "$candidate"
      return 1
    fi
    FM_AFK_LAUNCH_LOCK_TOKEN=$token
    if fm_afk_launch_atomic_rename "$candidate" "$FM_AFK_LAUNCH_LOCK"; then
      if [ "$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/token" 2>/dev/null || true)" = "$token" ]; then
        return 0
      fi
      FM_AFK_LAUNCH_LOCK_TOKEN=
      return 1
    fi
    FM_AFK_LAUNCH_LOCK_TOKEN=
    rm -rf "$candidate" 2>/dev/null || true
    return 2
  fi

  stale_identity=$(fm_afk_launch_lock_identity) || return 2
  if [ "$stale_identity" != "$FM_AFK_LAUNCH_LOCK_LAST_IDENTITY" ]; then
    FM_AFK_LAUNCH_LOCK_INCOMPLETE=0
    FM_AFK_LAUNCH_LOCK_LAST_IDENTITY=$stale_identity
  fi
  if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
    FM_AFK_LAUNCH_LOCK_INCOMPLETE=$((FM_AFK_LAUNCH_LOCK_INCOMPLETE + 1))
    [ "$FM_AFK_LAUNCH_LOCK_INCOMPLETE" -ge $((ownerless_grace * 20)) ] || return 2
  else
    FM_AFK_LAUNCH_LOCK_INCOMPLETE=0
  fi
  owner_state=$(fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || echo unknown)
  [ "$owner_state" = dead ] || return 2

  reclaim="$FM_AFK_LAUNCH_LOCK/.reclaim"
  if [ -L "$reclaim" ] || { [ -e "$reclaim" ] && [ ! -d "$reclaim" ]; }; then
    fm_afk_launch_log "refusing unsafe launcher reclaim directory: $reclaim"
    return 1
  fi
  if [ -d "$reclaim" ]; then
    reclaim_owner_state=$(fm_afk_launch_directory_owner_state "$reclaim" 2>/dev/null || echo unknown)
    [ "$reclaim_owner_state" = dead ] \
      && [ "$(fm_path_age "$reclaim" 2>/dev/null || echo 0)" -ge "$ownerless_grace" ] || return 2
    reclaim_identity=$(fm_afk_launch_directory_identity "$reclaim") || return 2
    fm_afk_launch_reclaim_test_handshake abandoned-before-revalidate || return 1
    claimed_identity=$(fm_afk_launch_lock_identity 2>/dev/null || true)
    confirmed_reclaim_identity=$(fm_afk_launch_directory_identity "$reclaim" 2>/dev/null || true)
    owner_state=$(fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || echo unknown)
    reclaim_owner_state=$(fm_afk_launch_directory_owner_state "$reclaim" 2>/dev/null || echo unknown)
    if [ -z "$claimed_identity" ] || [ "$claimed_identity" != "$stale_identity" ] \
      || [ "$owner_state" != dead ] || [ -z "$confirmed_reclaim_identity" ] \
      || [ "$confirmed_reclaim_identity" != "$reclaim_identity" ] \
      || [ "$reclaim_owner_state" != dead ] \
      || [ "$(fm_path_age "$reclaim" 2>/dev/null || echo 0)" -lt "$ownerless_grace" ]; then
      fm_afk_launch_reclaim_test_handshake abandoned-revalidation-rejected || return 1
      return 2
    fi
    reclaim_path_identity=$(fm_afk_launch_path_identity "$reclaim") || return 2
    fm_afk_launch_reclaim_test_handshake abandoned-after-revalidate || return 1
    reclaim_quarantine="$FM_AFK_LAUNCH_LOCK/.reclaim.stale.$$.$RANDOM"
    [ ! -e "$reclaim_quarantine" ] && [ ! -L "$reclaim_quarantine" ] || return 2
    fm_afk_launch_transaction_begin "$reclaim_quarantine" "$reclaim" "$reclaim_path_identity"
    if ! fm_afk_launch_atomic_rename "$reclaim" "$reclaim_quarantine"; then
      fm_afk_launch_transaction_clear
      return 2
    fi
    reclaim_quarantine_identity=$(fm_afk_launch_path_identity "$reclaim_quarantine" 2>/dev/null || true)
    [ -z "$reclaim_quarantine_identity" ] \
      || FM_AFK_LAUNCH_TRANSACTION_IDENTITY=$reclaim_quarantine_identity
    if ! fm_afk_launch_reclaim_test_handshake abandoned-after-quarantine; then
      fm_afk_launch_transaction_rollback >/dev/null 2>&1 || true
      return 1
    fi
    confirmed_reclaim_identity=$(fm_afk_launch_directory_identity "$reclaim_quarantine" 2>/dev/null || true)
    if [ -n "$reclaim_quarantine_identity" ] \
      && [ "$confirmed_reclaim_identity" = "$reclaim_identity" ]; then
      rm -rf "$reclaim_quarantine" || return 1
      fm_afk_launch_transaction_clear
    elif [ -n "$reclaim_quarantine_identity" ] \
      && fm_afk_launch_restore_quarantine "$reclaim_quarantine" "$reclaim" "$reclaim_quarantine_identity"; then
      fm_afk_launch_transaction_clear
      fm_afk_launch_reclaim_test_handshake abandoned-quarantine-restored || return 1
    else
      fm_afk_launch_log "could not restore changed abandoned launcher reclaim"
      return 1
    fi
    return 2
  fi

  reclaim_token="$$.$RANDOM.$i"
  claim_candidate="$FM_AFK_LAUNCH_LOCK/.reclaim-candidate.$reclaim_token"
  mkdir "$claim_candidate" 2>/dev/null || return 2
  identity=$(fm_pid_identity "$$" 2>/dev/null) || { rm -rf "$claim_candidate"; return 1; }
  if [ -z "$identity" ] \
    || ! printf '%s' "$$" > "$claim_candidate/pid" \
    || ! printf '%s' "$identity" > "$claim_candidate/pid-identity" \
    || ! printf '%s' "$reclaim_token" > "$claim_candidate/token" \
    || ! fm_afk_launch_atomic_rename "$claim_candidate" "$reclaim"; then
    rm -rf "$claim_candidate" 2>/dev/null || true
    return 2
  fi
  owned_reclaim_identity=$(fm_afk_launch_directory_identity "$reclaim") || {
    fm_afk_launch_remove_owned_reclaim "$reclaim" "$reclaim_token" >/dev/null 2>&1 || true
    return 2
  }
  claimed_identity=$(fm_afk_launch_lock_identity 2>/dev/null || true)
  owner_state=$(fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || echo unknown)
  if [ "$claimed_identity" != "$stale_identity" ] || [ "$owner_state" != dead ]; then
    fm_afk_launch_remove_owned_reclaim "$reclaim" "$reclaim_token" >/dev/null 2>&1 || true
    return 2
  fi
  fm_afk_launch_reclaim_test_handshake claimed-before-revalidate || return 1
  claimed_identity=$(fm_afk_launch_lock_identity 2>/dev/null || true)
  confirmed_reclaim_identity=$(fm_afk_launch_directory_identity "$reclaim" 2>/dev/null || true)
  owner_state=$(fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || echo unknown)
  if [ "$claimed_identity" != "$stale_identity" ] || [ "$owner_state" != dead ] \
    || [ "$confirmed_reclaim_identity" != "$owned_reclaim_identity" ] \
    || [ "$(fm_afk_launch_read_control "$reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ]; then
    fm_afk_launch_remove_owned_reclaim "$reclaim" "$reclaim_token" >/dev/null 2>&1 || true
    return 2
  fi
  lock_path_identity=$(fm_afk_launch_path_identity "$FM_AFK_LAUNCH_LOCK") || return 2
  fm_afk_launch_reclaim_test_handshake claimed-after-revalidate || return 1
  quarantine="$FM_AFK_LAUNCH_LOCK.stale.$reclaim_token"
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 2
  fm_afk_launch_transaction_begin "$quarantine" "$FM_AFK_LAUNCH_LOCK" "$lock_path_identity"
  if ! fm_afk_launch_atomic_rename "$FM_AFK_LAUNCH_LOCK" "$quarantine"; then
    fm_afk_launch_transaction_clear
    return 2
  fi
  quarantine_identity=$(fm_afk_launch_path_identity "$quarantine" 2>/dev/null || true)
  [ -z "$quarantine_identity" ] || FM_AFK_LAUNCH_TRANSACTION_IDENTITY=$quarantine_identity
  if [ -z "$quarantine_identity" ]; then
    fm_afk_launch_transaction_rollback >/dev/null 2>&1 || true
    return 1
  fi
  if ! fm_afk_launch_reclaim_test_handshake claimed-after-quarantine; then
    fm_afk_launch_transaction_rollback >/dev/null 2>&1 || true
    return 1
  fi
  claimed_identity=$(fm_afk_launch_directory_identity "$quarantine" 2>/dev/null || true)
  confirmed_reclaim_identity=$(fm_afk_launch_directory_identity "$quarantine/.reclaim" 2>/dev/null || true)
  if [ "$claimed_identity" != "$stale_identity" ] \
    || [ "$confirmed_reclaim_identity" != "$owned_reclaim_identity" ] \
    || [ "$(fm_afk_launch_read_control "$quarantine/.reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ]; then
    fm_afk_launch_log "launcher lock changed while reclaiming it"
    if ! fm_afk_launch_restore_quarantine "$quarantine" "$FM_AFK_LAUNCH_LOCK" "$quarantine_identity"; then
      fm_afk_launch_log "could not restore changed launcher lock generation from $quarantine"
      return 1
    fi
    fm_afk_launch_transaction_clear
    fm_afk_launch_reclaim_test_handshake claimed-quarantine-restored || return 1
    return 2
  fi
  [ "$quarantine_identity" = "$lock_path_identity" ] || {
    fm_afk_launch_restore_quarantine "$quarantine" "$FM_AFK_LAUNCH_LOCK" "$quarantine_identity" || return 1
    fm_afk_launch_transaction_clear
    return 2
  }
  rm -rf "$quarantine" || return 1
  fm_afk_launch_transaction_clear
  FM_AFK_LAUNCH_LOCK_INCOMPLETE=0
  return 2
}

fm_afk_launch_lock_acquire() {
  local i ownerless_grace result
  ownerless_grace=${FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS:-1}
  case "$ownerless_grace" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_launch_state_prepare || return 1
  FM_AFK_LAUNCH_LOCK_INCOMPLETE=0
  FM_AFK_LAUNCH_LOCK_LAST_IDENTITY=
  for i in $(seq 1 200); do
    fm_afk_launch_namespace_guard_acquire || return 1
    fm_afk_launch_lock_try_guarded "$i" "$ownerless_grace"
    result=$?
    fm_afk_launch_namespace_guard_release || return 1
    case "$result" in
      0) return 0 ;;
      2) sleep 0.05 ;;
      *) return 1 ;;
    esac
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release_guarded() {
  local pid token result=0
  fm_afk_launch_transaction_rollback || result=1
  [ -d "$FM_AFK_LAUNCH_LOCK" ] && [ ! -L "$FM_AFK_LAUNCH_LOCK" ] || return "$result"
  pid=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  token=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/token" 2>/dev/null || true)
  if [ "$pid" = "$$" ] && [ -n "$FM_AFK_LAUNCH_LOCK_TOKEN" ] && [ "$token" = "$FM_AFK_LAUNCH_LOCK_TOKEN" ]; then
    rm -rf "$FM_AFK_LAUNCH_LOCK" || result=1
    [ "$result" -ne 0 ] || FM_AFK_LAUNCH_LOCK_TOKEN=
  fi
  return "$result"
}

fm_afk_launch_lock_release() {
  local result=0
  # EXIT/TERM may land after publication but before the guarded attempt returns.
  # In that case the current shell already owns the sibling guard; reacquiring
  # it would self-deadlock, so clean the exact token while fd 17 still retains
  # the kernel lock and then close that descriptor normally.
  if [ "$FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD" -eq 1 ]; then
    fm_afk_launch_lock_release_guarded || result=1
    fm_afk_launch_namespace_guard_release || result=1
    return "$result"
  fi
  fm_afk_launch_namespace_guard_acquire || return 1
  fm_afk_launch_lock_release_guarded || result=1
  fm_afk_launch_namespace_guard_release || result=1
  return "$result"
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  fm_afk_launch_state_prepare || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  if [ -L "$FM_AFK_LAUNCH_RECORD" ] || { [ -e "$FM_AFK_LAUNCH_RECORD" ] && [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; }; then
    fm_afk_launch_log "refusing unsafe daemon-terminal record destination: $FM_AFK_LAUNCH_RECORD"
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  local destination="$FM_AFK_LAUNCH_STATE/.afk" pending
  fm_afk_launch_state_prepare || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    fm_afk_launch_log "refusing unsafe away-mode flag destination: $destination"
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$destination" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_herdr_identity_pack() {  # <workspace-id> <label>
  local workspace=$1 label=$2
  case "$workspace$label" in *$'\t'*|*$'\n'*|*'|'*) return 1 ;; esac
  [ -n "$workspace" ] && [ -n "$label" ] || return 1
  printf '%s|%s\n' "$workspace" "$label"
}

fm_afk_launch_herdr_identity_parse() {  # <packed-identity>
  local packed=$1
  case "$packed" in *'|'*) ;; *) return 1 ;; esac
  FM_AFK_HERDR_WORKSPACE=${packed%%|*}
  FM_AFK_HERDR_LABEL=${packed#*|}
  [ -n "$FM_AFK_HERDR_WORKSPACE" ] && [ -n "$FM_AFK_HERDR_LABEL" ] \
    && [ "$FM_AFK_HERDR_LABEL" != "$packed" ]
}

fm_afk_launch_herdr_identity_state() {  # <target> <packed-identity>
  local target=$1 packed=$2 session pane workspaces panes out code
  fm_afk_launch_herdr_identity_parse "$packed" || { printf 'unknown'; return 0; }
  session=${target%%:*}
  pane=${target#*:}
  [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || { printf 'unknown'; return 0; }
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { printf 'unknown'; return 0; }
  if ! printf '%s\n' "$workspaces" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  if printf '%s\n' "$workspaces" | jq -e --arg id "$FM_AFK_HERDR_WORKSPACE" --arg want_label "$FM_AFK_HERDR_LABEL" \
    'any(.result.workspaces[]?; (.workspace_id | tostring) == $id and .label == $want_label)' >/dev/null 2>&1; then
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$FM_AFK_HERDR_WORKSPACE" 2>/dev/null) \
      || { printf 'unknown'; return 0; }
    if ! printf '%s\n' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
      printf 'unknown'
      return 0
    fi
    if printf '%s\n' "$panes" | jq -e --arg pane "$pane" \
      'any(.result.panes[]?; (.pane_id | tostring) == $pane)' >/dev/null 2>&1; then
      printf 'match'
      return 0
    fi
  elif printf '%s\n' "$workspaces" | jq -e --arg id "$FM_AFK_HERDR_WORKSPACE" \
    'any(.result.workspaces[]?; (.workspace_id | tostring) == $id)' >/dev/null 2>&1; then
    printf 'mismatch'
    return 0
  fi
  if out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1); then
    printf 'mismatch'
    return 0
  fi
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ "$code" = pane_not_found ]; then printf 'absent'; else printf 'unknown'; fi
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET and
# FM_AFK_REC_EXTRA. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  local record hash expected_prefix
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; FM_AFK_REC_EXTRA=""
  if [ -L "$FM_AFK_LAUNCH_RECORD" ] \
    || { [ -e "$FM_AFK_LAUNCH_RECORD" ] && [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; }; then
    fm_afk_launch_log "daemon terminal record is not a real regular file; refusing to act on it"
    return 2
  fi
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_RECORD") || record=""
  if [ -z "$record" ] || [ -L "$FM_AFK_LAUNCH_RECORD" ] || [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; then
    fm_afk_launch_log "daemon terminal record changed while reading; refusing to act on it"
    return 2
  fi
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET FM_AFK_REC_EXTRA <<< "$record" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr) fm_afk_launch_herdr_identity_parse "$FM_AFK_REC_EXTRA" ;;
    herdr-plan) [ -n "$FM_AFK_REC_EXTRA" ] ;;
    tmux)
      hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
      expected_prefix="fm-afk-daemon-$hash-"
      if ! printf '%s\n' "$FM_AFK_REC_TARGET" | grep -Eq "^${expected_prefix}[0-9]+-[0-9]+-[0-9]+$"; then
        fm_afk_launch_log "recorded tmux target '$FM_AFK_REC_TARGET' does not belong to this Firstmate home; refusing to act on it"
        return 2
      fi
      ;;
    none) [ "$FM_AFK_REC_TARGET" = - ] && [ "$FM_AFK_REC_EXTRA" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-}
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = match ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "=$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} session pane out result
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = absent ]
      ;;
    tmux)
      out=$(tmux has-session -t "=$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eqi "can't find session|no server running on|failed to connect to server|error connecting to .*\((No such file or directory|Connection refused)\)"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_herdr_plan_absent() {  # <session> <label>
  local session=$1 label=$2 workspaces
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg want "$label" \
    '(.result.workspaces | type) == "array" and all(.result.workspaces[]?; .label != $want)' >/dev/null 2>&1
}

fm_afk_launch_plan_grace_elapsed() {
  local mtime now
  [ -f "$FM_AFK_LAUNCH_RECORD" ] && [ ! -L "$FM_AFK_LAUNCH_RECORD" ] || return 1
  mtime=$(fm_path_mtime "$FM_AFK_LAUNCH_RECORD") || return 1
  now=$(date '+%s') || return 1
  case "$mtime:$now" in *[!0-9:]*) return 1 ;; esac
  [ $((now - mtime)) -ge 60 ]
}

fm_afk_launch_close_recorded() {
  local close_result=0 recovered wsid pane packed
  if [ "$FM_AFK_REC_BACKEND" = herdr-plan ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA") || {
      if fm_afk_launch_plan_grace_elapsed \
        && fm_afk_launch_herdr_plan_absent "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"; then
        rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
        fm_afk_launch_log "planned herdr daemon workspace was never created; cleared its expired intent"
        return 0
      fi
      fm_afk_launch_log "planned herdr daemon workspace is not yet recoverable; preserving its unique label"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
    packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$FM_AFK_REC_EXTRA") || return 1
    fm_afk_launch_record_write herdr "$FM_AFK_REC_TARGET:$pane" "$packed" || return 1
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$FM_AFK_REC_TARGET:$pane"
    FM_AFK_REC_EXTRA=$packed
  fi
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = match ]
      ;;
    tmux)
      tmux has-session -t "=$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} i
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target" "$extra"
    return
  fi
  for i in $(seq 1 100); do
    daemon_lock_held_by_live_daemon && return 0
    fm_afk_launch_terminal_alive "$backend" "$target" "$extra" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target" "$extra"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target" "$extra"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    FM_AFK_REC_EXTRA=$extra
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane i
  for i in $(seq 1 20); do
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    fm_afk_launch_copy_bounded "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ] || [ -L "$backup/$artifact" ]; then
      fm_afk_launch_copy_bounded "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd label recovered create_result packed
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  if ! fm_afk_launch_record_write herdr-plan "$session" "$label"; then
    fm_afk_launch_log "failed to persist planned herdr daemon workspace '$label'"
    return 1
  fi
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$label") || return 1
    if fm_afk_launch_record_write herdr "$session:$pane" "$packed"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      FM_AFK_REC_EXTRA=$packed
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$label") || return 1
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_STATE_OVERRIDE=%q FM_AFK_STATE_PREPARED=1 FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$FM_AFK_LAUNCH_STATE" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$packed"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane" "$packed"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    FM_AFK_REC_EXTRA=$packed
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$packed" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_STATE_OVERRIDE=%q FM_AFK_STATE_PREPARED=1 FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$FM_AFK_LAUNCH_STATE" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if fm_afk_launch_terminal_absent tmux "$session"; then
      if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
        fm_afk_launch_log "failed to remove absent planned tmux daemon record after creation failure"
      fi
    else
      fm_afk_launch_log "tmux creation outcome is unconfirmed; preserving exact session '$session' for reconciliation"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_target_status captain_backend captain_backend_status backup artifact had_afk=0 result=0
  # Capture the captain pane FIRST, before creating anything.
  if captain_target=$(discover_supervisor_target); then captain_target_status=0; else captain_target_status=$?; fi
  if captain_backend=$(discover_supervisor_backend); then captain_backend_status=0; else captain_backend_status=$?; fi
  [ -n "$captain_target" ] || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  [ -n "$captain_backend" ] || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }
  if [ "$captain_target_status" -ne 0 ] || [ "$captain_backend_status" -ne 0 ]; then
    fm_afk_launch_log "using legacy supervisor fallback $captain_backend:$captain_target"
  fi

  fm_afk_launch_state_prepare || return 1

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk" ] || [ -L "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ] || [ -L "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  elif [ "$had_afk" -eq 0 ]; then
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native_locked() {
  local backup artifact had_afk=0 result=0 record_result
  fm_afk_launch_state_prepare || return 1
  if fm_afk_native_process_live; then
    fm_afk_launch_record_read
    record_result=$?
    [ "$record_result" -ne 2 ] || return 1
    if [ "$record_result" -eq 1 ]; then
      fm_afk_launch_record_write none - native || return 1
    fi
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "native daemon process already starting or active; refreshed away-mode flag"
    return 0
  fi
  if [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 1 ]; then
    fm_afk_launch_log "native daemon process marker does not identify an away-mode daemon; refusing refresh"
    return 1
  fi
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk" ] || [ -L "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ] || [ -L "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ] && [ "$had_afk" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ] && ! fm_afk_launch_flag_write; then
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_handoff_lock_acquire() {
  local wait_seconds=${FM_AFK_NATIVE_HANDOFF_LOCK_WAIT_SECONDS:-10} attempts attempt=0
  case "$wait_seconds" in ''|*[!0-9]*) wait_seconds=10 ;; esac
  attempts=$((wait_seconds * 10))
  while ! fm_lock_try_acquire "$FM_AFK_NATIVE_HANDOFF_LOCK"; do
    if [ "$attempt" -ge "$attempts" ]; then
      fm_afk_launch_log "native handoff lock remained busy at $FM_AFK_NATIVE_HANDOFF_LOCK; refusing lifecycle change, retry after the active handoff finishes"
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
}

fm_afk_launch_start_native() {
  local result
  fm_afk_launch_handoff_lock_acquire || return 1
  fm_afk_launch_start_native_locked
  result=$?
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
  return "$result"
}

fm_afk_launch_stop_locked() {
  local pid pid_identity current_identity native_identity=0 result=0 read_result
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon while state/.afk is still present.
  # Terminal-backed compatibility delivery may make its final guarded flush in
  # cleanup, while native reap-wake preserves the buffer for firstmate's catch-up.
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  elif { [ "$read_result" -eq 1 ] || [ "$FM_AFK_REC_BACKEND" = none ]; } && fm_afk_native_process_live; then
    pid=$FM_AFK_NATIVE_PID
    pid_identity=$(fm_afk_native_process_identity "$pid") || return 1
    native_identity=1
  elif [ -e "$FM_AFK_NATIVE_PROCESS" ]; then
    if fm_afk_native_process_live; then
      fm_afk_launch_log "live native daemon process conflicts with the recorded terminal; preserving lifecycle state"
      return 1
    fi
    if [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 1 ]; then
      fm_afk_launch_log "native daemon process marker does not identify an away-mode daemon; refusing to signal pid=${FM_AFK_NATIVE_RECORD_PID:-unknown}"
      return 1
    fi
    rm -f "$FM_AFK_NATIVE_PROCESS" || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    if [ "$native_identity" -eq 1 ]; then
      current_identity=$(fm_afk_native_process_identity "$pid" 2>/dev/null) || {
        fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
        return 1
      }
    else
      current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
        fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
        return 1
      }
    fi
    if [ -z "$current_identity" ]; then
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    fi
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  rm -f "$FM_AFK_NATIVE_PROCESS" || result=1
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local result
  fm_afk_launch_handoff_lock_acquire || return 1
  fm_afk_launch_stop_locked
  result=$?
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
  return "$result"
}

fm_afk_launch_main() {
  local result
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_afk_launch_lock_acquire
  result=$?
  if [ "$result" -ne 0 ]; then
    trap - EXIT INT TERM
    return "$result"
  fi
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
