#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# Refuses when bin/fm-dod-lib.sh will not accept the named head as reachable
# outside the worker's disposable copy; in no-mistakes mode a forge-reported
# head is that named head and is already stored on the forge.
# A refusal that names a state of the pull request itself - that its forge tooling
# is missing, that it is a draft - names its
# reason on stderr and records it as this task's fm_dod_pr_refusal_reason, which
# is what restores the lost-work alarm a ready report waits out; a later record
# clears it; a run that reaches the delivery gate refreshes a stored cause to what
# it observed, because the check that stated it has since passed, and leaves the
# verdict alone. The named-head refusal is printed without a record: this step asked
# the reader about a report it built, so that refusal cannot tell an unsaved head
# from the recording window this step exists to close.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Gerrit change URL
# are all accepted, including a merge request or change on a self-hosted
# instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
# Once this pull request and this task are identified, a refusal the reader can
# consult is recorded for bin/fm-dod-lib.sh before this script exits, which is
# what turns a ready report back into the lost-work alarm instead of waiting out
# a window; the next successful record clears it. Recording can only restore a
# refusal the gate already makes, never accept a claim it would refuse, so it is
# kept to the lanes that reader consults: a ship record on github or gitlab that
# is not local-only. Any other refusal just exits, since a record there is state
# nothing reads until teardown. Refusals of this script's own inputs are not here
# because no pull request or task is identified to record against yet. A run that
# reaches the delivery gate passed every check that could state a cause, so it
# refreshes a stored cause to what it saw instead of leaving one it disproved;
# pr_check_refusal_lane is the one lane rule for both writes.
pr_check_refusal_lane() {
  [ "${KIND:-ship}" = ship ] && [ "$MODE" != local-only ] || return 1
  case "$PROVIDER" in
    github|gitlab) return 0 ;;
  esac
  return 1
}

pr_check_refuse_pr() {  # <reason>
  printf 'error: %s\n' "$1" >&2
  if pr_check_refusal_lane; then
    # A refusal nobody recorded reads to the next reader as a pull request still
    # waiting on its record, which is the pause this step exists to tell apart from
    # the lost-work alarm. The verdict stops the record either way, so a write that
    # cannot store the cause says so here rather than exiting quietly on it.
    fm_dod_pr_refusal_write "$STATE" "$ID" "$URL" "$1" \
      || printf 'error: could not record the refusal above for %s: a later read will see a record wait instead of this cause\n' "$URL" >&2
  fi
  exit 1
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A secondmate is a persistent worker, not a delivery lane: it never owns a
# pull request of its own. A URL reported on its routed status channel belongs
# to a task inside the mate's own home, which records and watches it there;
# arming a merge watch here would queue the mate itself for teardown as landed
# work once that pull request merges.
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$KIND" = secondmate ]; then
  pr_check_refuse_pr "$ID is a secondmate, not a delivery lane - $URL was reported on its status channel but belongs to a task in the mate's own home, which arms its own merge watch"
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a watch with no CLI on PATH to read it. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# change that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
# The Gerrit poll also needs jq, because Gerrit's status has to be read out of a
# structured record rather than off a rendered line: the tool's own table prints
# a change's subject before its status, and a subject is free text.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  pr_check_refuse_pr "watching a GitLab merge request requires glab on PATH"
fi
if [ "$PROVIDER" = gerrit ]; then
  if ! command -v gerrit-axi >/dev/null 2>&1; then
    pr_check_refuse_pr "watching a Gerrit change requires gerrit-axi on PATH"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    pr_check_refuse_pr "watching a Gerrit change requires jq on PATH"
  fi
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    pr_check_refuse_pr "$URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate"
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head, and neither does a Gerrit task: a Gerrit
# revision names one patch set, every amend or rebase is a new patch set, and
# bin/fm-review-diff.sh has no Gerrit path to resolve a current head with, so a
# recorded revision would silently become the reviewed content. Both consumers
# already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh fetches a pull request head from the remote when none is
# recorded and otherwise diffs the local branch, which is the current content.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
# The gate is asked about the ready report this task's worker was told to give;
# on a Gerrit change both publishing modes report the same published line.
case "$PROVIDER:$MODE" in
  gerrit:*) DONE_LINE="done: PR $URL published for review" ;;
  *:no-mistakes|*:) DONE_LINE="done: PR $URL checks green" ;;
  *) DONE_LINE="done: PR $URL" ;;
esac
if { [ -z "$PR_HEAD" ] || ! fm_dod_forge_head_is_named_head "$MODE"; }; then
  GATE_RC=0
  GATE_REASON=$(fm_dod_accept_ship_done "${KIND:-ship}" "$MODE" "$WT" "$PROJECT" \
    "$DONE_LINE" "$STATE" "$ID" "$META") || GATE_RC=$?
  # Either non-zero verdict stops recording here, and neither becomes a record of
  # its own: this step asked the reader about a report it built, so it cannot tell
  # an unsaved head from the recording window this step exists to close, and a
  # record of that verdict would turn the window into the durable lost-work alarm.
  # The wait is printed as a wait and stores nothing. A refusing run keeps the error
  # treatment and brings the cause an earlier run stored up to date, because it passed
  # every check that could state one: the record stands until a successful record
  # clears it, and the cause a refusing run states is always the current one.
  if [ "$GATE_RC" -ne 0 ]; then
    if [ "$GATE_RC" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ]; then
      printf '%s\n' "$GATE_REASON" >&2
      # The wait leaves as the wait. A caller reading this script's status has to
      # tell waiting on the record apart from a refused recording, and only the
      # status the delivery gate returned itself says which.
      exit "$FM_DOD_RC_WAIT_PR_RECORD"
    fi
    # A stored cause quotes what the run that wrote it observed, so the record is
    # brought to what this run saw and the cause the gate quoted is replaced with
    # the one the record now carries. The gate's verdict itself is the one this run
    # already has: it is not asked again. Where there was nothing to refresh, or the
    # record names another pull request, the gate's own line is stated as it came.
    if pr_check_refusal_lane && fm_dod_pr_refusal_refresh "$STATE" "$ID" "$URL" \
        "the delivery gate did not accept this run's ready report" \
      && GATE_CAUSE=$(fm_dod_pr_refusal_reason "$STATE" "$ID" "$URL"); then
      case "$GATE_REASON" in
        *' was refused: '*) GATE_REASON="${GATE_REASON%% was refused: *} was refused: $GATE_CAUSE" ;;
      esac
    fi
    printf 'error: %s\n' "$GATE_REASON" >&2
    exit 1
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
# The pull request is now recorded, so any earlier refusal naming it is spent. A
# record naming a different pull request belongs to another report's verdict, so the
# clearing is scoped by the identity the record itself carries. A record this run
# could not read or could not remove is how a refusal outlives the pull request that
# caused it, so that is reported rather than swallowed.
pr_check_refusal_clear=0
fm_dod_pr_refusal_remove "$STATE" "$ID" "$URL" || pr_check_refusal_clear=$?
if [ "$pr_check_refusal_clear" -eq 2 ]; then
  printf 'error: %s is recorded and the refusal record for it could not be cleared: a later read will raise the lost-work alarm for a pull request that is already recorded\n' "$URL" >&2
  exit 1
fi

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
# The merge-time re-record is not a new review-ready PR, so it writes nothing.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || [ "${FM_PR_CHECK_MERGE:-}" = 1 ] \
  || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" pr_ready "$ID" "$URL" || true
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
