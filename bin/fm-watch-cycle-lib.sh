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
# unreadable, noncanonical, ambiguous, or truncated ledger returns false, so an
# absent record can never silence an alarm or open a gate.

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

fm_cycle_query() {
  local log='' final_newline='' now=''
  log=$(fm_cycle_log_path "$1")
  [ -s "$log" ] || return 1
  final_newline=$(tail -c 1 "$log" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$final_newline" = 1 ] || return 1
  now=$(date +%s)
  awk -v mode="$2" -v want_pid="${3:-}" -v want_cycle="${4:-}" -v now="$now" -v maxage="${5:-0}" '
    BEGIN { FS = "\t"; invalid = 0 }
    {
      if (NF == 12 &&
          $1 ~ /^arm_pid=[0-9][0-9]*$/ &&
          $2 ~ /^watcher_pid=[0-9][0-9]*$/ &&
          $3 ~ /^origin=(started|attached)$/ &&
          $4 ~ /^started_at=[0-9][0-9]*$/ &&
          $5 ~ /^ended_at=[0-9][0-9]*$/ &&
          $6 ~ /^exit_code=([0-9][0-9]*|unknown)$/ &&
          $7 ~ /^signal=.+$/ &&
          $8 ~ /^reason=(actionable-(signal|stale|check|heartbeat)|unexpected-clean-exit|nonzero-exit|signal-exit|confirmation-timeout|arm-interrupted|attached-cycle-ended|lock-replaced)$/ &&
          $9 ~ /^beacon_age=[0-9][0-9]*$/ &&
          $10 ~ /^lock_before=.+$/ &&
          $11 ~ /^lock_after=.+$/ &&
          $12 ~ /^successor=(none|(started|attached):[0-9][0-9]*)$/) {
        if (saw_current) invalid = 1
        next
      }
      saw_current = 1
      if (NF != 13 ||
          $1 !~ /^arm_pid=[0-9][0-9]*$/ ||
          $2 !~ /^watcher_pid=[0-9][0-9]*$/ ||
          $3 !~ /^cycle_id=.+$/ ||
          $4 !~ /^origin=(started|attached)$/ ||
          $5 !~ /^started_at=[0-9][0-9]*$/ ||
          $6 !~ /^ended_at=[0-9][0-9]*$/ ||
          $7 !~ /^exit_code=([0-9][0-9]*|unknown)$/ ||
          $8 !~ /^signal=.+$/ ||
          $9 !~ /^reason=(actionable-(signal|stale|check|heartbeat)|unexpected-clean-exit|nonzero-exit|signal-exit|confirmation-timeout|arm-interrupted|attached-cycle-ended|lock-replaced)$/ ||
          $10 !~ /^beacon_age=[0-9][0-9]*$/ ||
          $11 !~ /^lock_before=.+$/ ||
          $12 !~ /^lock_after=.+$/ ||
          $13 !~ /^successor=(none|(started|attached):[0-9][0-9]*)$/) {
        invalid = 1
        next
      }

      pid = substr($2, 13)
      cycle = substr($3, 10)
      origin = substr($4, 8)
      started = substr($5, 12) + 0
      ended = substr($6, 10) + 0
      reason = substr($9, 8)

      if (cycle == "none" || ended < started) {
        invalid = 1
        next
      }
      if ((cycle in cycle_pid) && cycle_pid[cycle] != pid) {
        invalid = 1
        next
      }
      cycle_pid[cycle] = pid
      seen[cycle] = 1

      if (origin == "started") {
        owner_count[cycle] += 1
        owner_started[cycle] = started
        owner_ended[cycle] = ended
        owner_reason[cycle] = reason
      }
    }
    END {
      if (invalid) exit 1
      for (cycle in seen) {
        if (owner_count[cycle] != 1) exit 1
      }

      if (mode == "instance") {
        if (want_pid !~ /^[0-9][0-9]*$/ || want_cycle == "" || want_cycle == "none") exit 1
        if (!(want_cycle in seen) || cycle_pid[want_cycle] != want_pid) exit 1
        exit owner_reason[want_cycle] ~ /^actionable-/ ? 0 : 1
      }

      if (mode != "latest" || maxage !~ /^[0-9][0-9]*$/) exit 1
      latest = -1
      latest_cycle = ""
      tied = 0
      for (cycle in seen) {
        if (owner_started[cycle] > latest) {
          latest = owner_started[cycle]
          latest_cycle = cycle
          tied = 0
        } else if (owner_started[cycle] == latest) {
          tied = 1
        }
      }
      if (latest < 0 || tied) exit 1
      age = now - owner_ended[latest_cycle]
      if (age < 0 || age > maxage + 0) exit 1
      exit owner_reason[latest_cycle] ~ /^actionable-/ ? 0 : 1
    }
  ' "$log" 2>/dev/null
}

# fm_cycle_instance_closed_actionably <state-dir> <watcher-pid> <cycle-id>
fm_cycle_instance_closed_actionably() {
  fm_cycle_query "$1" instance "$2" "$3"
}

# fm_cycle_close_explained <state-dir> <max-age-seconds>
# True when the most recently ended watcher cycle closed with a delivered
# actionable reason within <max-age-seconds>.
#
# "Most recent" is resolved by the owning row's cycle start, not observer
# completion: one cycle produces several records when more than one arm observed
# it, and only the owner's record carries the reason.
fm_cycle_close_explained() {
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  fm_cycle_query "$1" latest '' '' "$2"
}
