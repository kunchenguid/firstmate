#!/usr/bin/env bash
# fm-relay-ledger-lib.sh - the record of steers sent to a worker while that
# worker still owed the captain an open needs-decision.
#
# ONE owner of the unclosed-relay contract (docs/captain-hold-lifecycle.md
# "Unclosed relays"). A captain answer relayed to a worker through
# bin/fm-send.sh closes its decision only when the send names the key with
# --resolve-key. A send that names neither --resolve-key nor --keep-open for an
# open needs-decision leaves that decision open behind a steer that may have
# been the answer, and the next conversation turn asks the captain again.
# bin/fm-send.sh appends one line per such key here; `bin/fm-captain-hold.sh
# unclosed` folds the ledger against the live decision set, and
# bin/fm-wake-drain.sh prints what is still open as UNCLOSED RELAYS.
#
# Layout: <state-dir>/<task>.unclosed-relay, one line per unclosed key:
#   <epoch>\t<key>\t<inbox-record-name>
# The file is append-only and safe to delete. A line matters only while its key
# is still an open needs-decision opened BEFORE the relay, so answering the
# decision, or the worker reopening a key later, retires it without any rewrite.
# Teardown removes the file with the rest of the task's runtime state.
#
# Requires bin/fm-classify-lib.sh (status_open_decisions, _fm_open_set_verb,
# status_line_at_epoch, status_line_verb, _fm_decision_key) to be sourced.

fm_relay_ledger_path() {  # <state-dir> <task-id>
  printf '%s/%s.unclosed-relay\n' "$1" "$2"
}

# Append one unclosed key. The ledger is a hint for a human-owned reconcile, so
# a failed append is reported to the caller and never undoes the delivered steer.
fm_relay_ledger_append() {  # <state-dir> <task-id> <key> <inbox-record-path>
  local path
  path=$(fm_relay_ledger_path "$1" "$2")
  [ ! -L "$path" ] || return 1
  printf '%s\t%s\t%s\n' "$(date +%s)" "$3" "${4##*/}" >> "$path"
}

# Epoch of the newest status line that opened <key> with needs-decision; 0 when
# that line carries no readable stamp.
fm_relay_ledger_opened_at() {  # <status-file> <key>
  local line at opened=0
  while IFS= read -r line; do
    [ "$(status_line_verb "$line")" = needs-decision ] || continue
    [ "$(_fm_decision_key "$line")" = "$2" ] || continue
    if at=$(status_line_at_epoch "$line") && [ -n "$at" ]; then
      opened=$at
    else
      opened=0
    fi
  done < <(grep -F "[key=$2]" "$1" 2>/dev/null)
  printf '%s\n' "$opened"
}

# Print "<task>\t<key>\t<first-relay-epoch>\t<relay-count>" for every ledger key
# whose decision is still an open needs-decision that predates the relay. Prints
# nothing when every relayed steer was followed by a close.
fm_relay_ledger_unclosed() {  # <state-dir>
  local state=$1 ledger task status open key opened first count seen
  for ledger in "$state"/*.unclosed-relay; do
    [ -f "$ledger" ] && [ ! -L "$ledger" ] || continue
    task=${ledger##*/}
    task=${task%.unclosed-relay}
    status="$state/$task.status"
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    open=$(status_open_decisions "$status" 2>/dev/null) || continue
    [ -n "$open" ] || continue
    seen=
    while IFS=$'\t' read -r _ key _; do
      [ -n "$key" ] || continue
      case " $seen " in *" $key "*) continue ;; esac
      [ "$(_fm_open_set_verb "$open" "$key")" = needs-decision ] || continue
      opened=$(fm_relay_ledger_opened_at "$status" "$key")
      first=
      count=0
      while IFS=$'\t' read -r e k _; do
        [ "$k" = "$key" ] || continue
        case "$e" in ''|*[!0-9]*) continue ;; esac
        [ "$e" -ge "$opened" ] || continue
        [ -n "$first" ] || first=$e
        count=$((count + 1))
      done < "$ledger"
      seen="$seen $key"
      [ "$count" -gt 0 ] || continue
      printf '%s\t%s\t%s\t%s\n' "$task" "$key" "$first" "$count"
    done < "$ledger"
  done
}
