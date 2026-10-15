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
#     appended through bin/fm-parent-channel-lib.sh under its channel contract;
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
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-timeout-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is away, attended, or external (the retired yolo and
# away-grant values are still accepted for a persisted authority written before
# the words model landed). Away, external, and the retired tags are appended to
# the ledger line; attended remains untagged. The merge entrypoint supplies its
# authority after forge acceptance, while the poll supplies the persisted
# identity-bound value or external when no matching record proves that this
# home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    away|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
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
    fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$FM_PR_URL" || true
  [ "$status" -ne 0 ] || fm_merge_post_hook "${FM_CONFIG_OVERRIDE:-$home/config}" "$home" "$id" "$state/$id.meta" - "$FM_PR_URL" >&2
  return "$status"
}

# The optional home post-merge hook (docs/configuration.md "Post-merge hook").
# When <config>/post-merge exists and is executable, a confirmed merge runs
# `post-merge <task-id> <worktree|-> <head|-> <pr-url|->` once with FM_HOME set,
# under FM_POST_MERGE_TIMEOUT seconds (default 120). The merge has already
# landed, so the hook never changes the caller's result: its output is printed
# and a failure or timeout is reported, never returned.
fm_merge_post_hook() {  # <config-dir> <home> <id> <meta> <head|-> <pr-url|->
  local hook=$1/post-merge worktree out rc=0 seconds=${FM_POST_MERGE_TIMEOUT:-120}
  [ -e "$hook" ] || [ -L "$hook" ] || return 0
  [ -x "$hook" ] || { echo "post-merge hook skipped: $hook is not executable"; return 0; }
  case $seconds in ''|0*|*[!0-9]*) seconds=120 ;; esac
  worktree=$(sed -n 's/^worktree=//p' "$4" 2>/dev/null | tail -1)
  out=$(fm_run_timed "$seconds" env FM_HOME="$2" "$hook" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || echo "post-merge hook failed (exit $rc); the merge stands"
  return 0
}
