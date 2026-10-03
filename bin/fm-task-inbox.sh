#!/usr/bin/env bash
# fm-task-inbox.sh - the worker's batched receive-and-ack for its steering
# inbox.
#
# Usage: fm-task-inbox.sh take [<inbox-dir>]
#        fm-task-inbox.sh ack --through <NNN> [<inbox-dir>]
#
# `take` prints every waiting record in numeric sequence order and changes
# nothing. Its last line names the highest sequence it printed:
#   === acknowledge after acting: ack --through <NNN> ===
# `ack --through <NNN>` then moves every waiting record up to and including
# that sequence into handled/, in one call. So a worker spends two calls on any
# number of waiting messages instead of a list, a read per message, and a move
# per message.
#
# Read and acknowledgement stay separate on purpose: the move is the only
# delivery signal the watcher reads (bin/fm-task-inbox-lib.sh owns the record
# format, the handled/ contract, and the re-ring ladder), so a worker that
# crashes or is relaunched after `take` but before acting still finds the
# instruction waiting, and the doorbell keeps ringing for it. Acknowledging
# only through the printed sequence means a record that arrived after `take`
# is never acknowledged unread. This script adds no state of its own.
#
# <inbox-dir> defaults to "$FM_TASK_INBOX", which bin/fm-spawn.sh exports into
# every launch.
#
# Output: `take` prints each record as a `=== <NNN>.msg ===` line followed by
# its exact enqueued text, ending with a newline, then the acknowledge line.
# An empty or absent inbox prints `no waiting messages`. `ack` prints
# `acknowledged <count>`.
#
# Exit status: 0 on success; 1 when a record could not be read or moved, after
# an error naming it (a record not moved stays waiting and rings again); 2 for
# a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

# Waiting records as "<seq>\t<basename>" lines in numeric sequence order.
waiting_records() {  # <inbox-dir>
  local f n
  for f in "$1"/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    printf '%s\t%s\n' "$n" "${f##*/}"
  done | sort -n
}

take() {  # <inbox-dir>
  local dir=$1 records seq name body last=''
  records=$(waiting_records "$dir")
  if [ -z "$records" ]; then
    echo 'no waiting messages'
    return 0
  fi
  while IFS="$(printf '\t')" read -r seq name; do
    if ! body=$(fm_task_inbox_body "$dir/$name" && printf x); then
      echo "error: cannot read inbox record $dir/$name; it stays waiting" >&2
      return 1
    fi
    body=${body%x}
    printf '=== %s ===\n%s' "$name" "$body"
    case "$body" in *$'\n') ;; *) printf '\n' ;; esac
    last=${name%.msg}
  done <<EOF
$records
EOF
  printf '=== acknowledge after acting: ack --through %s ===\n' "$last"
}

ack() {  # <inbox-dir> <through-seq>
  local dir=$1 through=$2 records seq name count=0
  records=$(waiting_records "$dir")
  if [ -n "$records" ]; then
    mkdir -p "$dir/handled" || {
      echo "error: cannot create $dir/handled" >&2
      return 1
    }
    while IFS="$(printf '\t')" read -r seq name; do
      [ "$seq" -le "$through" ] || break
      mv "$dir/$name" "$dir/handled/$name" || {
        echo "error: cannot acknowledge $dir/$name; it stays waiting and will ring again" >&2
        return 1
      }
      count=$((count + 1))
    done <<EOF
$records
EOF
  fi
  echo "acknowledged $count"
}

resolve_inbox() {  # [<inbox-dir>]
  INBOX=${1:-${FM_TASK_INBOX:-}}
  [ -n "$INBOX" ] || { echo "error: no inbox named and FM_TASK_INBOX is unset" >&2; exit 2; }
}

case "${1:-}" in
  take)
    [ "$#" -le 2 ] || { usage >&2; exit 2; }
    resolve_inbox "${2:-}"
    take "$INBOX"
    ;;
  ack)
    [ "${2:-}" = --through ] && [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
    THROUGH=$(fm_task_inbox_seq_of "$3.msg") || {
      echo "error: --through needs a record sequence such as 007, got: $3" >&2
      exit 2
    }
    resolve_inbox "${4:-}"
    ack "$INBOX" "$THROUGH"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
