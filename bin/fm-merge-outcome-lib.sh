#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh in the same
#     "<state> [key=<slug>]: <note>" shape the charter contract defines;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
#
# A confirmed merge is also the moment a deploy-managed project can go live, so
# this operation hands off to bin/fm-deploy-trigger.sh once the outcome is
# recorded. That handoff runs after the lock is released, only on a first
# observation, and never changes what this function returns: a caller that has
# already merged reads a non-zero return as "the merge landed and the record did
# not", which a failed deploy is not. A project with no deploy policy makes the
# handoff a no-op, so this changes nothing for a home that deploys nothing.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-backlog-transition-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin>
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin>
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  local data config backlog_file frontier='' wake_payload
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  # A merging PR is how a `blocked-by` dependency clears, so this outcome is
  # itself a frontier-changing event: carry the ready frontier along with it
  # rather than let it wait for the next session start. Never let a failed
  # probe (manual backend, incompatible tasks-axi, unreadable backlog) turn
  # into a failure of the outcome report itself. Derived from $home alone,
  # never an ambient FM_DATA_OVERRIDE/FM_CONFIG_OVERRIDE, the same way the
  # parent-channel resolution below is: an override inherited from an
  # unrelated parent process must never point this home's frontier probe at
  # another home's backlog.
  data="$home/data"
  config="$home/config"
  if backlog_file=$(fm_backlog_file "$data" 2>/dev/null); then
    :
  else
    backlog_file="${data%/}/backlog.md"
  fi
  if ! fm_backlog_backend_manual "$config"; then
    frontier=$(fm_ready_frontier_text "$backlog_file") || frontier=''
  fi

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    # The frontier is time-varying and fm_parent_channel_append_once dedupes
    # on an exact whole-line match, guarding the retry the header above
    # describes ("a failed commit stays eligible for at-least-once retry").
    # Appending the frontier here would break that match on a retry whose
    # ready set moved between attempts, risking a duplicated upward line. The
    # frontier is attached only to the local wake below, whose key is
    # invariant.
    line="done [key=merged-$id]: merged $id $FM_PR_URL"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    wake_payload="check: merge landed: $id $FM_PR_URL"
    if [ -n "$frontier" ]; then
      wake_payload="$wake_payload
$frontier"
    fi
    fm_wake_append check "merged-$id-$FM_PR_URL" "$wake_payload" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  if [ "$status" -eq 0 ] && [ -x "$_FM_MERGE_OUTCOME_LIB_DIR/fm-deploy-trigger.sh" ]; then
    "$_FM_MERGE_OUTCOME_LIB_DIR/fm-deploy-trigger.sh" "$home" "$state" "$id" || true
  fi
  return "$status"
}
