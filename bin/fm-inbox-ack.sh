#!/usr/bin/env bash
# fm-inbox-ack.sh - acknowledge firstmate steering records the safe way.
#
# The acknowledgement rule and the inbox layout both live in
# bin/fm-task-inbox-lib.sh (fm_task_inbox_acknowledge); this script is only the
# command-line face of it, so a worker never has to hand-roll the handling and
# the two can never drift apart. It exists because hand-rolled handling loses
# instructions: a worker's own `rm`, its `mv *.msg handled/` sweep, or a tidy-up
# glob inside the inbox can destroy a record it never read.
#
# What the acknowledgement does, per record:
#   1. Refuses a name that is not a sequence, so a typo cannot touch anything.
#   2. Reports a record that is already acknowledged instead of failing, so a
#      re-run after a lost reply is harmless.
#   3. Moves the record into handled/ - the acknowledgement itself - or, when the
#      worker already deleted the visible name, acknowledges it from the hidden
#      link instead of reporting it missing.
#   4. Retires the record's hidden link, which is what lets the watcher tell a
#      genuine acknowledgement from a record a worker deleted.
#
# It never deletes an unread record and never touches a record it was not given.
#
# Usage:
#   fm-inbox-ack.sh <state-dir> <task-id> <record>...
#     <state-dir>  the home's state directory, usually $FM_HOME/state
#     <task-id>    the task whose inbox you are acknowledging
#     <record>     a record path, or its bare sequence ("035" or "035.msg")
#
# Exits nonzero when any named record could not be acknowledged.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$ROOT/fm-task-inbox-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Exits/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

die() { printf 'fm-inbox-ack: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 3 ] || { usage; exit 2; }
STATE=$1
TASK=$2
shift 2

case "$STATE" in ''|*/) STATE=${STATE%/} ;; esac
[ -n "$STATE" ] || { usage; exit 2; }
[ -d "$STATE" ] || die "no state directory at $STATE"

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$LIB" || die "cannot load the steering-inbox contract from $LIB"

fm_task_inbox_acknowledge "$STATE" "$TASK" "$@" || exit 1
