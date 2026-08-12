#!/usr/bin/env bash
# Grok-owned persistent watcher arm.
#
# Grok bills a model turn whenever one tracked background command completes.
# Run this script, rather than fm-watch-arm.sh directly, as Grok's tracked
# background command. It keeps that one command alive across an arm close that
# has no durable wake row, no open decision, no pending recovery episode, and
# no failure. A close with any of those actionable facts returns immediately so
# Grok's native task-completed notification still wakes the model.
#
# This owner never drains or acknowledges work. Queue rows, decision records,
# and recovery episodes retain their existing owners. It only performs bounded
# read-side classification after the child arm has already closed. If that
# classification cannot be completed safely, it fails loudly instead of hiding
# a possible wake. Before every child arm it also requires the same live harness
# pid to own the session lock, normal supervision need, and no away-mode flag.
# Losing any of those conditions leaves this tracked task dormant instead of
# mutating fleet state or completing an empty task.
#
# FM_GROK_WATCH_ARM_SCRIPT, FM_GROK_WATCH_IDLE_POLL, and
# FM_GROK_WATCH_OUTPUT_MAX_BYTES are deterministic test seams. Production uses
# the sibling fm-watch-arm.sh, a one-second idle poll, and a 65536-byte cap.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ARM="${FM_GROK_WATCH_ARM_SCRIPT:-$SCRIPT_DIR/fm-watch-arm.sh}"
IDLE_POLL=${FM_GROK_WATCH_IDLE_POLL:-1}
OUTPUT_MAX_BYTES=${FM_GROK_WATCH_OUTPUT_MAX_BYTES:-65536}
CHILD_TERM_GRACE=${FM_GROK_WATCH_CHILD_TERM_GRACE:-1}
RECOVERY_MARKER="$STATE/.watcher-down"

case "$OUTPUT_MAX_BYTES" in
  ''|*[!0-9]*|0)
    echo 'watcher: FAILED - Grok continuity output cap must be a positive integer'
    exit 1
    ;;
esac
case "$CHILD_TERM_GRACE" in
  ''|*[!0-9.]*|.*|*.*.*)
    echo 'watcher: FAILED - Grok continuity child TERM grace must be a positive number'
    exit 1
    ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

case "${1:-}" in
  '') ;;
  -h|--help)
    printf 'Usage: %s\n' "$(basename "$0")"
    printf 'Run one persistent Grok tracked background watcher task.\n'
    exit 0
    ;;
  *)
    printf 'usage: %s\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac

mkdir -p "$STATE"
SESSION_OWNER=$(cat "$STATE/.lock" 2>/dev/null || true)

child=
reader=
stream_dir=

child_tree_pids() {
  local root=$1 frontier=$1 next pid ppid
  printf '%s\n' "$root"
  while [ -n "$frontier" ]; do
    next=
    while read -r pid ppid; do
      case " $frontier " in
        *" $ppid "*)
          printf '%s\n' "$pid"
          next="$next $pid"
          ;;
      esac
    done <<EOF
$(ps -eo pid=,ppid= 2>/dev/null)
EOF
    frontier=${next# }
  done
}

child_tree_identities() {
  local root=$1 pid identity
  child_tree_pids "$root" | while read -r pid; do
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || continue
    printf '%s\t%s\n' "$pid" "$identity"
  done
}

signal_identity_records() {
  local records=$1 signal=$2 pid expected current mismatch=0
  while IFS=$'\t' read -r pid expected; do
    [ -n "$pid" ] && [ -n "$expected" ] || continue
    current=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ "$current" != "$expected" ]; then
      mismatch=1
      continue
    fi
    kill -"$signal" "$pid" 2>/dev/null || true
  done < "$records"
  return "$mismatch"
}

retire_child_tree() {
  local root=$1 seed=${2:-} i=0 records current incomplete=0
  records=$(mktemp "$STATE/.grok-retire.XXXXXX") || return 1
  printf '%s\n' "$(cat "$seed" 2>/dev/null || true)" \
    "$(cat "${FM_GROK_WATCH_RETIRE_TEST_SEED:-/dev/null}" 2>/dev/null || true)" \
    "$(child_tree_identities "$root")" \
    | awk -F '\t' 'NF >= 2 && !seen[$1 FS $2]++' > "$records"
  signal_identity_records "$records" TERM || incomplete=1
  while fm_pid_alive "$root" && [ "$i" -lt 20 ]; do
    sleep "$(awk -v grace="$CHILD_TERM_GRACE" 'BEGIN { print grace / 20 }')"
    i=$((i + 1))
  done
  current="$records.current"
  printf '%s\n' "$(cat "$records")" "$(child_tree_identities "$root")" \
    | awk -F '\t' 'NF >= 2 && !seen[$1 FS $2]++' > "$current"
  mv "$current" "$records"
  signal_identity_records "$records" KILL || incomplete=1
  wait "$root" 2>/dev/null || true
  rm -f "$records"
  [ "$incomplete" -eq 0 ]
}

cleanup_cycle() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    retire_child_tree "$child" || true
  fi
  if [ -n "$reader" ] && fm_pid_alive "$reader"; then
    kill -TERM "$reader" 2>/dev/null || true
    wait "$reader" 2>/dev/null || true
  fi
  if [ -n "$stream_dir" ]; then
    rm -rf "$stream_dir" 2>/dev/null || true
  fi
  child=
  reader=
  stream_dir=
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_signal() {
  local rc=$1
  trap - HUP TERM INT
  cleanup_cycle
  exit "$rc"
}

trap 'handle_signal 129' HUP
trap 'handle_signal 143' TERM
trap 'handle_signal 130' INT
trap cleanup_cycle EXIT

CLASSIFY_FAILURE=

# Exit 0 when durable state requires a Grok model wake, 1 when the close is
# genuinely empty, and 2 when the read-side verdict cannot be established.
durable_action_pending() {
  local i open token
  CLASSIFY_FAILURE=

  i=0
  while ! fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; do
    if [ "$i" -ge 20 ]; then
      CLASSIFY_FAILURE='wake queue lock remained unavailable'
      return 2
    fi
    sleep 0.05
    i=$((i + 1))
  done
  if [ -s "$FM_WAKE_QUEUE" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"

  open=$(scan_open_decisions "$STATE") || {
    CLASSIFY_FAILURE='open-decision scan failed'
    return 2
  }
  [ -z "$open" ] || return 0

  if ! fm_recovery_marker_snapshot "$RECOVERY_MARKER"; then
    CLASSIFY_FAILURE='recovery marker snapshot failed'
    return 2
  fi
  token=$FM_RECOVERY_MARKER_TOKEN
  if [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ]; then
    case "$token" in
      acked:*) ;;
      pending:*) return 0 ;;
      *)
        CLASSIFY_FAILURE='recovery marker is unreadable or malformed'
        return 2
        ;;
    esac
  fi

  return 1
}

wait_until_needed() {
  while [ -e "$STATE/.afk" ] || ! fm_supervision_needed "$STATE" || ! session_owner_is_still_valid; do
    sleep "$IDLE_POLL"
  done
}

session_owner_is_still_valid() {
  local current
  case "$SESSION_OWNER" in ''|*[!0-9]*) return 1 ;; esac
  current=$(cat "$STATE/.lock" 2>/dev/null || true)
  [ "$current" = "$SESSION_OWNER" ] || return 1
  fm_harness_pid_alive "$SESSION_OWNER"
}

while :; do
  wait_until_needed
  completion_rc=
  completion_failure=

  stream_dir=$(mktemp -d "$STATE/.grok-watch-arm.XXXXXX") || {
    echo 'watcher: FAILED - Grok continuity could not allocate its arm output stream'
    exit 1
  }
  mkfifo "$stream_dir/stream" || {
    echo 'watcher: FAILED - Grok continuity could not create its arm output stream'
    exit 1
  }
  : > "$stream_dir/capture"
  : > "$stream_dir/overflow"

  set -m
  "$ARM" > "$stream_dir/stream" 2>&1 &
  child=$!
  set +m
  (
    captured=0
    emitted=0
    while :; do
      : > "$stream_dir/chunk"
      dd bs=4096 count=1 of="$stream_dir/chunk" 2>/dev/null || true
      bytes=$(wc -c < "$stream_dir/chunk" | tr -d '[:space:]')
      [ "$bytes" -gt 0 ] || break
      remaining=$((OUTPUT_MAX_BYTES - captured))
      if [ "$bytes" -gt "$remaining" ]; then
        head -c "$remaining" "$stream_dir/chunk" >> "$stream_dir/capture"
        child_tree_identities "$child" > "$stream_dir/overflow-pids"
        printf 'watcher: FAILED - Grok continuity arm output exceeded %s bytes\n' "$OUTPUT_MAX_BYTES" > "$stream_dir/overflow"
        break
      fi
      captured=$((captured + bytes))
      cat "$stream_dir/chunk" >> "$stream_dir/capture"
      complete=$(wc -l < "$stream_dir/capture" | tr -d '[:space:]')
      if [ "$complete" -gt "$emitted" ]; then
        sed -n "$((emitted + 1)),${complete}p" "$stream_dir/capture" \
          | awk '/^watcher: started / || /^watcher: attached /'
        emitted=$complete
      fi
    done < "$stream_dir/stream"
  ) &
  reader=$!
  while fm_pid_alive "$child" && [ ! -s "$stream_dir/overflow" ]; do
    sleep 0.02
  done
  if [ -s "$stream_dir/overflow" ]; then
    if ! retire_child_tree "$child" "$stream_dir/overflow-pids"; then
      printf 'watcher: FAILED - Grok continuity arm output exceeded %s bytes; exact child retirement was incomplete\n' "$OUTPUT_MAX_BYTES" > "$stream_dir/overflow"
    fi
  fi
  wait "$child"
  rc=$?
  child=
  wait "$reader" 2>/dev/null || true
  reader=
  awk '!/^watcher: started / && !/^watcher: attached /' "$stream_dir/capture" > "$stream_dir/terminal"

  if [ -s "$stream_dir/overflow" ]; then
    rc=1
    completion_failure=$(cat "$stream_dir/overflow")
    completion_rc=1
  elif [ "$rc" -ne 0 ] || grep -q '^watcher: FAILED' "$stream_dir/terminal" 2>/dev/null; then
    if [ "$rc" -eq 0 ]; then rc=1; fi
    completion_failure=$(grep -m 1 '^watcher: FAILED' "$stream_dir/terminal" 2>/dev/null || true)
    if [ -z "$completion_failure" ]; then
      completion_failure="watcher: FAILED - Grok continuity arm exited $rc"
    fi
    completion_rc=$rc
  else
    if [ -e "$STATE/.afk" ] || ! fm_supervision_needed "$STATE" || ! session_owner_is_still_valid; then
      rm -rf "$stream_dir"
      stream_dir=
      wait_until_needed
      continue
    fi
    durable_action_pending
    verdict=$?
    case "$verdict" in
      0) completion_rc=0 ;;
      1) ;;
      *)
        completion_rc=1
        completion_failure="watcher: FAILED - Grok continuity could not classify a completed arm: $CLASSIFY_FAILURE"
        ;;
    esac
  fi

  if [ -n "$completion_rc" ]; then
    if [ -e "$STATE/.afk" ] || ! fm_supervision_needed "$STATE" || ! session_owner_is_still_valid; then
      if [ "$completion_rc" -ne 0 ] \
        && ! fm_wake_append_preserving_recovery check "grok-transfer-failure:${stream_dir##*.}" "$completion_failure"; then
        while :; do sleep "$IDLE_POLL"; done
      fi
      rm -rf "$stream_dir"
      stream_dir=
      wait_until_needed
      continue
    fi
    cat "$stream_dir/terminal"
    if [ -n "$completion_failure" ] \
      && ! grep -q '^watcher: FAILED' "$stream_dir/terminal" 2>/dev/null; then
      printf '%s\n' "$completion_failure"
    fi
    rm -rf "$stream_dir"
    stream_dir=
    exit "$completion_rc"
  fi

  rm -rf "$stream_dir"
  stream_dir=
done
