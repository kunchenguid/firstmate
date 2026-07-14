#!/usr/bin/env bash
# Durable captain-attention lifecycle for a firstmate primary.
#
# `arm` records a stable semantic identity before firstmate yields with a
# question that genuinely needs the captain's response. The primary harness's
# turn-end seam calls `publish`; it claims and emits at most one notification for that
# identity. The user-input seam calls `clear` before the response turn starts.
# Clearing retains the last-notified identity so a Stop retry, supervision wake,
# or restatement of the same still-pending question cannot replay the sound.
# A genuinely new question must use a new identity.
#
# State is owned by $FM_HOME/state/.captain-wait (or FM_STATE_OVERRIDE), so
# separate firstmate and secondmate homes never share dedupe state.
# Claiming is persisted before the external effect, so a failed notifier is
# observable but never retried for the same identity. The notification boundary
# is injectable with FM_CAPTAIN_ATTENTION_EXEC=<path>;
# the executable receives the wait identity as argv[1]. Tests always inject a
# recorder. Production defaults to one macOS Notification Center sound and
# falls back to a terminal bell when osascript is unavailable. This channel is
# intentionally separate from fm-supervise-daemon.sh's urgent wedge alarm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WAIT_DIR="$STATE/.captain-wait"
LOCK="$STATE/.captain-wait.lock"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-captain-wait.sh arm <wait-id> | publish | clear

  arm ID   Record the stable identity of a genuine pending captain question.
  publish  Claim the pending identity and notify once; repeated calls are silent.
  clear    Resolve the pending wait without forgetting its notification claim.

State is home-scoped under FM_HOME/state/.captain-wait. Set
FM_CAPTAIN_ATTENTION_EXEC=/path/to/command to inject a notifier; it receives the
wait identity as argv[1]. Use "discard" to suppress the external effect.
Without an override, macOS receives one Notification Center sound; other hosts
fall back to a terminal bell. This channel never uses wedge-alarm state.
EOF
}

usage_error() {
  usage >&2
  exit 2
}

lock_acquire() {
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK"' EXIT HUP INT TERM
}

atomic_write() { # <path> <value>
  local path=$1 value=$2 tmp
  tmp="$WAIT_DIR/.tmp.$$"
  printf '%s\n' "$value" > "$tmp" || return 1
  mv "$tmp" "$path"
}

notify_captain() { # <wait-id>
  local wait_id=$1 exec_path=${FM_CAPTAIN_ATTENTION_EXEC:-}
  if [ -n "$exec_path" ]; then
    [ "$exec_path" = discard ] && return 0
    "$exec_path" "$wait_id"
    return
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript \
      -e 'on run argv' \
      -e 'display notification "Firstmate is waiting for your response." with title "firstmate: captain response needed" sound name "Glass"' \
      -e 'end run' \
      -- "$wait_id" >/dev/null
    return
  fi
  printf '\a' 2>/dev/null >/dev/tty
}

cmd=${1:-}
case "$cmd" in
  -h|--help)
    [ "$#" -eq 1 ] || usage_error
    usage
    ;;
  arm)
    wait_id=${2:-}
    [ "$#" -eq 2 ] || usage_error
    [ -n "$wait_id" ] && [ "${#wait_id}" -le 128 ] || usage_error
    case "$wait_id" in *[!A-Za-z0-9._:-]*) usage_error ;; esac
    lock_acquire || exit 1
    mkdir -p "$WAIT_DIR" || exit 1
    atomic_write "$WAIT_DIR/pending" "$wait_id"
    ;;
  publish)
    [ "$#" -eq 1 ] || usage_error
    [ -f "$WAIT_DIR/pending" ] || exit 0
    lock_acquire || exit 1
    [ -f "$WAIT_DIR/pending" ] || exit 0
    IFS= read -r wait_id < "$WAIT_DIR/pending" || exit 0
    last=
    [ ! -f "$WAIT_DIR/last-notified" ] || IFS= read -r last < "$WAIT_DIR/last-notified" || true
    [ "$wait_id" != "$last" ] || exit 0
    # Claim before the non-transactional external effect. If the notifier emits
    # and then fails (or this process dies), a Stop retry must not replay sound.
    atomic_write "$WAIT_DIR/last-notified" "$wait_id" || exit 1
    notify_captain "$wait_id"
    ;;
  clear)
    [ "$#" -eq 1 ] || usage_error
    [ -d "$WAIT_DIR" ] || exit 0
    lock_acquire || exit 1
    rm -f "$WAIT_DIR/pending"
    ;;
  *) usage_error ;;
esac
