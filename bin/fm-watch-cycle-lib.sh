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
# cycle's wake output, so an arm merely ATTACHED to that same watcher otherwise
# has no way to tell a delivered wake apart from a watcher that vanished.
# Reading the owner's own record keeps both verdicts honest.
#
# Readers:
#   bin/fm-watch-arm.sh   attached-close classification
#
# Every query is evidence-based and fails toward "not explained": a missing,
# unreadable, noncanonical, ambiguous, or truncated ledger returns false, so an
# absent record can never change the attached arm's unexplained-close claim.

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

# One canonical parser owns every ledger read so the schema has one owner.
fm_cycle_query() {
  local log='' final_newline='' now=''
  log=$(fm_cycle_log_path "$1")
  [ -s "$log" ] || return 1
  final_newline=$(tail -c 1 "$log" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$final_newline" = 1 ] || return 1
  now=$(date +%s)
  awk -v mode="$2" -v want_pid="${3:-}" -v floor="${4:-}" \
    -v want_lock="${5:-}" -v now="$now" '
    BEGIN { FS = "\t" }
    {
      if (NF != 12 ||
          $1 !~ /^arm_pid=[0-9][0-9]*$/ ||
          $2 !~ /^watcher_pid=[0-9][0-9]*$/ ||
          $3 !~ /^origin=(started|attached)$/ ||
          $4 !~ /^started_at=[0-9][0-9]*$/ ||
          $5 !~ /^ended_at=[0-9][0-9]*$/ ||
          $6 !~ /^exit_code=([0-9][0-9]*|unknown)$/ ||
          $7 !~ /^signal=.+$/ ||
          $8 !~ /^reason=(actionable-(signal|stale|check|heartbeat)|unexpected-clean-exit|nonzero-exit|signal-exit|confirmation-timeout|arm-interrupted|attached-cycle-ended|lock-replaced)$/ ||
          $9 !~ /^beacon_age=[0-9][0-9]*$/ ||
          $10 !~ /^lock_before=.+$/ ||
          $11 !~ /^lock_after=.+$/ ||
          $12 !~ /^successor=(none|(started|attached):[0-9][0-9]*)$/) {
        invalid = 1
        next
      }
      pid = substr($2, 13)
      origin = substr($3, 8)
      started = substr($4, 12) + 0
      ended = substr($5, 10) + 0
      reason = substr($8, 8)
      lock_before = substr($10, 13)
      if (ended < started || started > now + 0 || ended > now + 0) {
        invalid = 1
        next
      }
      if (mode == "instance" && pid == want_pid && origin == "started" &&
          ended >= floor + 0 && lock_before == want_lock) {
        matches += 1
        matched_reason = reason
      }
    }
    END {
      if (invalid) exit 1
      if (mode == "instance") {
        if (want_pid !~ /^[0-9][0-9]*$/ ||
            floor !~ /^[0-9][0-9]*$/ ||
            want_lock == "" ||
            matches != 1) exit 1
        exit matched_reason ~ /^actionable-/ ? 0 : 1
      }
      exit 1
    }
  ' "$log" 2>/dev/null
}

# fm_cycle_pid_closed_actionably <state-dir> <watcher-pid> <not-before-epoch> <lock-identity>
# True when exactly one complete owner record says the exact watcher instance
# closed for a delivered wake at or after <not-before-epoch>.
fm_cycle_pid_closed_actionably() {
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$4" ] || return 1
  fm_cycle_query "$1" instance "$2" "$3" "$4"
}
