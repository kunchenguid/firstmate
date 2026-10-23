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
# The merge entrypoint and the main watcher may each run the guarded teardown
# for a finished direct report once the merge outcome is recorded; this library
# owns that eligibility check, the teardown call, and the resulting notice text.
# The merge outcome adds no new transport; a cleanup outcome rides the merge
# notice this library emits.
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
# shellcheck source=bin/fm-backend.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-backend.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false
# shellcheck disable=SC2034 # Public result consumed by the watcher after a poll result.
FM_MERGE_OUTCOME_CLEANUP=skipped
# shellcheck disable=SC2034 # Public result consumed by the watcher after a poll result.
FM_MERGE_OUTCOME_CLEANUP_DETAIL=
# shellcheck disable=SC2034 # Public result consumed by the watcher after a poll result.
FM_MERGE_OUTCOME_NOTICE=

fm_merge_outcome_current_state() {  # <home> <state> <task-id>
  FM_HOME=$1 FM_STATE_OVERRIDE=$2 "$_FM_MERGE_OUTCOME_LIB_DIR/fm-crew-state.sh" "$3"
}

fm_merge_outcome_run_teardown() {  # <home> <state> <task-id>
  local home=$1 state=$2 id=$3 data config root
  data=${FM_DATA_OVERRIDE:-$home/data}
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  root=${FM_ROOT_OVERRIDE:-${FM_ROOT:-$_FM_MERGE_OUTCOME_LIB_DIR/..}}
  FM_ROOT_OVERRIDE=$root FM_HOME=$home FM_STATE_OVERRIDE=$state \
    FM_DATA_OVERRIDE=$data FM_CONFIG_OVERRIDE=$config \
    "$_FM_MERGE_OUTCOME_LIB_DIR/fm-teardown.sh" "$id"
}

# Check only an already-finished direct report, then delegate all destructive
# decisions to teardown's existing guards. A missing or uncertain state remains
# on the ordinary merge-notice path.
fm_merge_outcome_auto_teardown() {  # <home> <state> <task-id> <pr-url>
  local home=$1 state=$2 id=$3 url=$4 meta="$2/$3.meta" status="$2/$3.status"
  local kind recorded_pr line current role_rc teardown_output teardown_rc summary note noted_pr
  FM_MERGE_OUTCOME_CLEANUP=skipped
  FM_MERGE_OUTCOME_CLEANUP_DETAIL=
  if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ] \
    || [ -e "$home/.fm-secondmate-parent" ] || [ -L "$home/.fm-secondmate-parent" ]; then
    return 0
  fi
  if fm_parent_channel_destination "$home" "$state" >/dev/null 2>&1; then
    return 0
  else
    role_rc=$?
    [ "$role_rc" -eq 1 ] || return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  line=$(status_current_line "$status" "$kind")
  [ "$(status_line_verb "$line")" = "done" ] || return 0
  recorded_pr=$(fm_meta_get "$meta" pr)
  [ "$recorded_pr" = "$url" ] || return 0
  note=$(status_line_note "$line")
  case "$note" in PR\ *) ;; *) return 0 ;; esac
  noted_pr=${note#PR }
  noted_pr=${noted_pr%% *}
  [ "$noted_pr" = "$url" ] || return 0
  current=$(fm_merge_outcome_current_state "$home" "$state" "$id" 2>/dev/null) || return 0
  case "$current" in 'state: done ·'*) ;; *) return 0 ;; esac

  if teardown_output=$(fm_merge_outcome_run_teardown "$home" "$state" "$id" 2>&1); then
    teardown_rc=0
  else
    teardown_rc=$?
  fi
  if [ "$teardown_rc" -eq 0 ] || [ "$teardown_rc" -eq 4 ]; then
    FM_MERGE_OUTCOME_CLEANUP=cleaned
    if [ "$teardown_rc" -eq 4 ]; then
      FM_MERGE_OUTCOME_CLEANUP_DETAIL='cleanup completed, but the returned worktree pool slot needs repair'
    fi
    return 0
  fi
  summary=$(printf '%s\n' "$teardown_output" \
    | awk '/^(REFUSED|error:)/ { last = $0 } END { print last }')
  [ -n "$summary" ] || summary=$(printf '%s\n' "$teardown_output" \
    | awk 'NF { last = $0 } END { print last }')
  summary=$(printf '%s' "$summary" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200)
  [ -n "$summary" ] || summary="teardown exited with status $teardown_rc"
  case "$teardown_rc" in
    3|6) FM_MERGE_OUTCOME_CLEANUP=refused ;;
    *)
      case "$summary" in
        REFUSED:*|*refused*|*refusal*|*refusing*) FM_MERGE_OUTCOME_CLEANUP=refused ;;
        *) FM_MERGE_OUTCOME_CLEANUP=failed ;;
      esac
      ;;
  esac
  FM_MERGE_OUTCOME_CLEANUP_DETAIL=$summary
  return 0
}

fm_merge_outcome_cleanup_notice() {  # <original-notice>
  case "$FM_MERGE_OUTCOME_CLEANUP" in
    cleaned)
      printf '%s; lane automatically cleaned up' "$1"
      [ -z "$FM_MERGE_OUTCOME_CLEANUP_DETAIL" ] \
        || printf '; %s' "$FM_MERGE_OUTCOME_CLEANUP_DETAIL"
      ;;
    refused)
      printf '%s; automatic cleanup refused: %s' "$1" "$FM_MERGE_OUTCOME_CLEANUP_DETAIL"
      ;;
    failed)
      printf '%s; automatic cleanup did not complete: %s' "$1" "$FM_MERGE_OUTCOME_CLEANUP_DETAIL"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# The one boundary for a post-merge cleanup: run the guarded teardown, then
# publish its outcome under the durable key the merge notice used, so the
# payload presented for that key carries the cleanup result.
fm_merge_outcome_cleanup_and_publish() {  # <home> <state> <task-id> <pr-url>
  local home=$1 state=$2 id=$3 url=$4 status=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" != true ] || return 0
  fm_merge_outcome_auto_teardown "$home" "$state" "$id" "$url"
  [ "$FM_MERGE_OUTCOME_CLEANUP" != skipped ] || return 0
  fm_pr_url_parse "$url" || return 2
  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  fm_wake_append check "merged-$id-$FM_PR_URL" \
    "$(fm_merge_outcome_cleanup_notice "$FM_MERGE_OUTCOME_NOTICE")" || status=1
  return "$status"
}

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
  local self_rc=0 destination='' line lock status=0 notice
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  FM_MERGE_OUTCOME_NOTICE=
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
  notice="check: merge landed: $id $FM_PR_URL$suffix"
  FM_MERGE_OUTCOME_NOTICE=$notice

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
    fm_wake_append check "merged-$id-$FM_PR_URL" "$notice" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$FM_PR_URL" || true
  return "$status"
}
