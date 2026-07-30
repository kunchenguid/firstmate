# shellcheck shell=bash
# Atomic watcher-cycle result handoff shared by fm-watch.sh and fm-watch-arm.sh.
#
# The watcher publishes one fixed, atomic actionable result record before its
# EXIT trap releases state/.watch.lock.
# An attached arm reads that record only for the exact watcher PID and process
# identity it followed.
# A missing, malformed, or identity-mismatched record is never actionable, so
# watcher death and handoff failure remain loud failures.
#
# state/.watch-cycle-exits.log is a bounded best-effort diagnostic ledger.
# Its owning arm writes only after the watcher exits, so it is intentionally not
# a correctness dependency for delivering an attached arm's wake.

FM_WATCH_CYCLE_RESULT_NAME=.watch-cycle-result

fm_watch_cycle_result_path() {
  printf '%s/%s' "$1" "$FM_WATCH_CYCLE_RESULT_NAME"
}

fm_watch_cycle_identity_hex() {
  printf '%s' "$1" | od -An -v -tx1 2>/dev/null | tr -d '[:space:]'
}

fm_watch_cycle_reason_is_actionable() {
  case "$1" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_watch_cycle_result_publish_actionable() {  # <state-dir> <watcher-pid> <pid-identity> <reason>
  local state_dir=$1 watcher_pid=$2 pid_identity=$3 reason=$4
  local result identity_hex tmp
  case "$watcher_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$pid_identity" ] || return 1
  fm_watch_cycle_reason_is_actionable "$reason" || return 1
  identity_hex=$(fm_watch_cycle_identity_hex "$pid_identity") || return 1
  case "$identity_hex" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  result=$(fm_watch_cycle_result_path "$state_dir")
  tmp="$result.tmp.${BASHPID:-$$}"
  (
    umask 077
    {
      printf 'version=1\twatcher_pid=%s\tidentity_hex=%s\tstate=actionable\n' \
        "$watcher_pid" "$identity_hex"
      printf '%s\n' "$reason"
    } > "$tmp" || exit 1
    chmod 0600 "$tmp" || exit 1
    mv -f "$tmp" "$result"
  ) || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

fm_watch_cycle_result_read_actionable() {  # <state-dir> <watcher-pid> <pid-identity>
  local result record newline header reason identity_hex expected_header
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$3" ] || return 1
  identity_hex=$(fm_watch_cycle_identity_hex "$3") || return 1
  result=$(fm_watch_cycle_result_path "$1")
  record=$(cat "$result" 2>/dev/null) || return 1
  newline='
'
  case "$record" in *"$newline"*) ;; *) return 1 ;; esac
  header=${record%%"$newline"*}
  reason=${record#*"$newline"}
  expected_header=$(printf 'version=1\twatcher_pid=%s\tidentity_hex=%s\tstate=actionable' "$2" "$identity_hex")
  [ "$header" = "$expected_header" ] || return 1
  fm_watch_cycle_reason_is_actionable "$reason" || return 1
  printf '%s\n' "$reason"
}
