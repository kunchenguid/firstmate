#!/usr/bin/env bash
# Shared resolution of the merge authority a task's merge ran under, so the
# durable merge ledger can name it on every path a merge can land on.
#
# The away-posture record (state/.afk-contract) and the task's own recorded
# yolo posture are the only sources. Nothing here reads chat, the record's
# verbatim words, or its clause prose: bin/fm-afk-contract.sh owns the record's
# schema and its mechanical `grants` list of task ids, and the task's `yolo=`
# line is a structured metadata field.
#
# Two callers share this one answer so the attended merge and the merge poll
# cannot disagree about what permitted a merge:
#   - bin/fm-pr-merge.sh turns it into the away-merge gate, with its own
#     refusal wording, before any forge call.
#   - bin/fm-watch.sh turns it into the ledger tag on a merge its poll
#     detected, including one the forge queued and landed after the merge call
#     returned.
# Resolution itself authorizes nothing. It reports what the records say and
# leaves every merge gate to bin/fm-pr-merge.sh, so a caller that only wants
# the ledger tag cannot become a second path to a merge.
#
# Sourced by those two scripts and by tests. No side effects on source beyond
# its sourced libraries.

_FM_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-afk-contract.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_REASON=

# fm_merge_authority_resolve <home> <state> <meta> <task-id>
#
# Sets FM_MERGE_AUTHORITY to the authority that admits this task's merge while
# the away-posture record exists: yolo when the task's recorded posture is on,
# or away-grant when the record's grant list names the task id. With no
# away-posture record the merge is attended, there is no standing authority to
# name, and the value stays empty.
#
# Returns 0 when the records answer the question and 1 when they do not.
# FM_MERGE_AUTHORITY_REASON says which case it is:
#   attended           no away-posture record; FM_MERGE_AUTHORITY is empty
#   granted            FM_MERGE_AUTHORITY names yolo or away-grant
#   record-unreadable  the record exists but could not be read
#   grants-unreadable  the record's grant list could not be read
#   not-granted        the record exists and neither source admits this task
#   invalid            the request itself was incomplete
# Every case but `granted` leaves FM_MERGE_AUTHORITY empty, so a caller that
# only records the answer tags nothing rather than tagging a merge no record
# admits, and a caller that gates on it refuses on anything but a clear answer.
fm_merge_authority_resolve() {  # <home> <state> <meta> <task-id>
  local home=${1-} state=${2-} meta=${3-} id=${4-}
  local yolo='' grants grant
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_AUTHORITY=
  FM_MERGE_AUTHORITY_REASON='invalid'
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$meta" ] && [ -n "$id" ] || return 1

  if ! fm_afk_contract_present "$state"; then
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    FM_MERGE_AUTHORITY_REASON='record-unreadable'
    return 1
  fi
  if [ -f "$meta" ]; then
    yolo=$(grep '^yolo=' "$meta" | tail -1 | cut -d= -f2- || true)
  fi
  if [ "$yolo" = on ]; then
    FM_MERGE_AUTHORITY='yolo'
    FM_MERGE_AUTHORITY_REASON='granted'
    return 0
  fi
  grants=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" grants 2>/dev/null) || {
    FM_MERGE_AUTHORITY_REASON='grants-unreadable'
    return 1
  }
  while IFS= read -r grant; do
    [ "$grant" = "$id" ] || continue
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    FM_MERGE_AUTHORITY='away-grant'
    FM_MERGE_AUTHORITY_REASON='granted'
    return 0
  done <<EOF
$grants
EOF
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_AUTHORITY_REASON='not-granted'
  return 1
}
