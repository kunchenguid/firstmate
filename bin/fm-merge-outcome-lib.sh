#!/usr/bin/env bash
# Shared durable, supervisor-facing publication of a PR's TERMINAL outcome.
#
# Two outcomes travel this one path, because both change whether a task's own
# `done:` record is still true:
#   merged           the PR landed.
#   closed-unmerged  the PR was closed WITHOUT merging. When the task holds a
#                    terminal `done:` record, that record has silently stopped
#                    being true, and reporting the contradiction is the failure
#                    this carries. The poll is armed at PR registration, well
#                    before any terminal claim, so this outcome is also reached
#                    with no claim on record; the publication then reports the
#                    close plainly rather than inventing a claim to contradict.
#
# Publishing is only half of it: this is also where the task's DURABLE verdict
# record is corrected, because this is the one site that observes the outcome
# and every later gate reads that record rather than re-observing. A close
# records `contradicted` for the standing claim; a merge marks an established
# claim `stale`, because the world moved past what was established. See
# bin/fm-done-claim-lib.sh for the three shapes of terminal evidence and the
# write precedence that keeps them apart.
#
# Both a merge performed by this home and either outcome detected by its existing
# poll use this operation, so neither depends on an agent remembering it.
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
# Normal operation deduplicates the task's latest canonical PR identity AND
# outcome through the notification marker owned by bin/fm-pr-lib.sh, so a closed
# PR is reported once and a later reopen-and-merge of that same PR still reports
# its own outcome. Main-home wake keys also include that PR identity so distinct
# PRs for a reused task remain distinct in queue presentation. The outcome is
# published before the marker is committed, so a failed commit stays eligible for
# at-least-once retry and may rarely duplicate rather than leave an outcome silent.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-done-claim-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-done-claim-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false
# true only when this call durably recorded a verdict for the task's standing
# claim. A caller that retires the poll on the strength of the outcome having
# been RECORDED reads this rather than the return code, which is also 0 when
# there was no claim to record anything about.
# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_VERDICT_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [<outcome>]
#
# <origin> says who observed the outcome, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's poll detected the outcome, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
#
# <outcome> defaults to merged; closed-unmerged publishes the contradiction.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [<outcome>]
  local home=$1 state=$2 id=$3 url=$4 origin=$5 outcome=${6:-merged}
  local self_rc=0 destination='' line lock status=0 wake_note claimed=0
  local provider host path number claim_state='' claim_probe='' claim_hash=''
  local claim_verdict='' claim_reason=''
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_MERGE_OUTCOME_VERDICT_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  fm_pr_poll_outcome_valid "$outcome" || return 2
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  # A merge is a completion; a close without merge is a blocker, because the
  # task still holds a done record the forge no longer supports. The verbs
  # differ for exactly that reason and are both known status verbs.
  #
  # Whether the task holds such a record is a fact to read, not to assume: the
  # poll is armed at PR registration (bin/fm-pr-check.sh), long before any
  # terminal claim, so a PR closed while the worker is still working has no done
  # record to contradict. Asserting one would make this publication itself the
  # unfounded claim the whole verdict path exists to stop. Read in a subshell so
  # the claim globals a caller may be holding are left alone.
  claim_probe=$(fm_done_claim_status "$state" "$id" >/dev/null 2>&1 \
    && printf '%s\t%s' "$FM_DONE_CLAIM_STATE" \
      "$(fm_done_claim_hash "$FM_DONE_CLAIM_LINE" 2>/dev/null || true)")
  claim_state=${claim_probe%%$'\t'*}
  claim_hash=${claim_probe#*$'\t'}
  [ "$claim_hash" != "$claim_probe" ] || claim_hash=
  # An unreadable claim state is treated as no claim: the weaker wording is
  # true either way, while the stronger one would not be.
  case "$claim_state" in ''|none) ;; *) claimed=1 ;; esac

  # This is the only site in the fleet that OBSERVES a PR reach a terminal
  # state, and the durable verdict record is what every later gate reads. Those
  # two came apart once already: a claim established while the PR was open kept
  # its `verified` record after the PR was closed unmerged, so cleanup passed on
  # a record the forge had already falsified. Recording here, inside the funnel,
  # is what stops observing and recording from separating again.
  #
  # Which verdict follows from which outcome is the three-shape distinction
  # bin/fm-done-claim-lib.sh states: a close without merge is positive evidence
  # of falsity and records `contradicted`; a merge is the world CHANGING under a
  # verdict that was true when it was made, which records `stale` so the next
  # gate re-verifies against the world that now exists. The verifier is
  # deliberately not re-run here: that would couple every merge to forge and
  # validation-run reads, and would only relocate the outage question one layer
  # up.
  #
  # Both arms act only when a terminal claim is actually on record. The poll is
  # armed at PR registration, long before any claim, so inventing a verdict for
  # a task that has asserted nothing would make this publication itself the
  # unfounded claim the whole verdict path exists to stop.
  if [ "$claimed" -eq 1 ] && [ -n "$claim_hash" ]; then
    if [ "$outcome" != merged ]; then
      claim_verdict=contradicted
      claim_reason="$FM_PR_URL was closed without merging, so this task is not done"
    elif [ "$claim_state" = verified ]; then
      claim_verdict=stale
      claim_reason="$FM_PR_URL merged after this claim was established, so what was established no longer describes the world; re-run bin/fm-verify-done.sh $id"
    fi
  fi
  if [ "$outcome" = merged ]; then
    wake_note="check: merge landed: $id $FM_PR_URL"
  elif [ "$claimed" -eq 1 ]; then
    wake_note="check: PR closed without merging, contradicting the done record: $id $FM_PR_URL"
  else
    wake_note="check: PR closed without merging: $id $FM_PR_URL"
  fi
  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    if [ "$outcome" = merged ]; then
      line="done [key=merged-$id]: merged $id $FM_PR_URL"
    elif [ "$claimed" -eq 1 ]; then
      line="blocked [key=closed-unmerged-$id]: $id claims done but $FM_PR_URL was closed without merging"
    else
      line="blocked [key=closed-unmerged-$id]: $id had its PR $FM_PR_URL closed without merging"
    fi
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
    "$provider" "$host" "$path" "$number" "$outcome"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "$outcome-$id-$FM_PR_URL" "$wake_note" || status=1
  fi
  # After the report, never in front of it. This write can fail for reasons that
  # have nothing to do with the outcome - a symlink planted at the verdict path,
  # a full or read-only state directory - and gating the publication on it would
  # turn a closed-unmerged observation, the exact rot this whole path exists to
  # catch, into no parent line, no captain wake, and (on the poll path, through
  # bin/fm-watch.sh's fatal non-zero handling) a dead watcher. Publishing first
  # is the same order the marker already uses, for the same reason: both
  # publications are key-deduplicated, so an at-least-once retry cannot
  # duplicate. A failure here still sets status, so the retry happens; it simply
  # no longer has a veto over the report.
  if [ -n "$claim_verdict" ]; then
    if fm_done_verdict_write "$state" "$id" "$claim_verdict" "$claim_hash" "$claim_reason"; then
      # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
      FM_MERGE_OUTCOME_VERDICT_RECORDED=true
    else
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" "$outcome" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
