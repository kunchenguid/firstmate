# shellcheck shell=bash
# Owner of the watcher cycle ledger's record format and every read of it.
# Usage: . bin/fm-watch-cycle-lib.sh
#
# bin/fm-watch-arm.sh appends one tab-separated record per observed watcher
# cycle to state/.watch-cycle-exits.log and owns the arm-side lifecycle state
# machine, rotation, and locking. This library owns the parts two different
# processes must agree on: where the ledger lives, how a field is sanitized, and
# which classified reasons mean "this cycle closed because the watcher had a real
# wake to deliver".
#
# A cycle's reason is ACTIONABLE when it carries the "actionable-" prefix
# (actionable-signal, actionable-stale, actionable-check, actionable-heartbeat),
# written by the arm that OWNED the watcher child and read its wake output. Every
# other reason - unexpected-clean-exit, nonzero-exit, signal-exit,
# confirmation-timeout, arm-interrupted, attached-cycle-ended, lock-replaced -
# means the observer could not account for the close.
#
# That asymmetry is the reason this library exists. Only the owning arm can see a
# cycle's wake output, so an arm merely ATTACHED to that same watcher, and the
# PreToolUse continuity gate looking at the home afterwards, otherwise have no way
# to tell a delivered wake apart from a watcher that vanished. Reading the owner's
# own record is what keeps both of them from reporting a healthy close as a
# supervision failure.
#
# Readers:
#   bin/fm-watch-arm.sh                  attached-close classification
#   bin/fm-continuity-pretool-check.sh   explained post-wake gap
#
# Every query is evidence-based and fails toward "not explained": a missing,
# unreadable, or truncated ledger returns false, so an absent record can never
# silence an alarm or open a gate.

FM_CYCLE_LOG_NAME=.watch-cycle-exits.log

# fm_cycle_log_path <state-dir>
fm_cycle_log_path() {
  printf '%s/%s' "$1" "$FM_CYCLE_LOG_NAME"
}

# fm_cycle_clean_field <value>
# Records are one line of tab-separated fields, so a value can carry neither a
# tab nor a newline, and is bounded so one pathological field cannot dominate
# the size cap.
fm_cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

# fm_cycle_pid_closed_actionably <state-dir> <watcher-pid> <not-before-epoch>
# True when the ledger records that <watcher-pid>'s cycle closed with a delivered
# actionable reason at or after <not-before-epoch>.
#
# The floor is what makes this safe against PID reuse: a caller passes the moment
# it began following that watcher, so an old record from an unrelated process
# that happened to reuse the number can never answer for the current cycle.
fm_cycle_pid_closed_actionably() {
  local log=''
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  log=$(fm_cycle_log_path "$1")
  [ -f "$log" ] || return 1
  awk -v want="$2" -v floor="$3" '
    BEGIN { FS = "\t" }
    {
      pid = ""; ended = ""; reason = ""
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^watcher_pid=/) pid = substr($i, 13)
        else if ($i ~ /^ended_at=/) ended = substr($i, 10)
        else if ($i ~ /^reason=/) reason = substr($i, 8)
      }
      if (pid != want) next
      if (ended !~ /^[0-9]+$/ || ended + 0 < floor + 0) next
      if (reason ~ /^actionable-/) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$log" 2>/dev/null
}

# fm_cycle_close_explained <state-dir> <max-age-seconds>
# True when the most recently ended watcher cycle closed with a delivered
# actionable reason within <max-age-seconds>.
#
# "Most recently ended" is resolved per watcher PID, not per record: one cycle
# produces several records when more than one arm observed it, and only the
# owner's record carries the reason. A later cycle that ended any other way wins
# and makes this false, so a watcher that closed actionably and was then replaced
# by one that died cannot keep answering for the home. A tie at the same second
# between different watchers is treated as unexplained.
fm_cycle_close_explained() {
  local log='' now=''
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  log=$(fm_cycle_log_path "$1")
  [ -f "$log" ] || return 1
  now=$(date +%s)
  awk -v now="$now" -v maxage="$2" '
    BEGIN { FS = "\t"; latest = -1 }
    {
      pid = ""; ended = ""; reason = ""
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^watcher_pid=/) pid = substr($i, 13)
        else if ($i ~ /^ended_at=/) ended = substr($i, 10)
        else if ($i ~ /^reason=/) reason = substr($i, 8)
      }
      if (pid == "" || pid == "none") next
      if (ended !~ /^[0-9]+$/) next
      e = ended + 0
      if (!(pid in last) || e > last[pid]) last[pid] = e
      if (reason ~ /^actionable-/) actionable[pid] = 1
      if (e > latest) latest = e
    }
    END {
      if (latest < 0) exit 1
      if (now - latest > maxage + 0) exit 1
      for (p in last) {
        if (last[p] == latest && !(p in actionable)) exit 1
      }
      exit 0
    }
  ' "$log" 2>/dev/null
}
