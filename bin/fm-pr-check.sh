#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, carry the valid captain-authorized
# override receipts forward when the recorded PR is unchanged, then atomically
# arm a static merge poll. Those receipts are the missing_review_override_ts=
# line and the red_override_ts=, red_override_pr=, red_override_head= and
# red_override_condition= lines in state/<id>.meta, each carried forward only
# while pr= is unchanged.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_PR_CHECK_HOME_EXPLICIT=false
[ -z "${FM_HOME:-}" ] || FM_PR_CHECK_HOME_EXPLICIT=true
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

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

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

pr_check_cleanup() {
  fm_pr_poll_cleanup
  fm_pr_meta_cleanup
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

pr_check_meta_identity_matches() {
  [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
    && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
    && [ "$FM_PR_META_NUMBER" = "$NUMBER" ]
}

# The receipt outlives a refresh of the same pull request, but it was authorized
# against that one PR: re-pointing the task elsewhere drops it rather than
# asserting an override the new PR never received, and says so, because losing a
# captain authorization is exactly as reportable as applying one. The shared
# parser requires it to follow pr=, so it is re-emitted after the identity lines
# rather than left in place, and a malformed value is dropped without a notice
# because no authorization it could name was ever readable.
# Every field below is read to be re-emitted, so the read and the rewrite are
# one transaction: without the lock held across both, a concurrent metadata
# writer can publish between them and this rewrite silently drops its fields.
fm_pr_meta_lock "$META" \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
PRIOR_PR=$(sed -n 's/^pr=//p' "$META" | tail -n 1)
OVERRIDE_TS=$(sed -n 's/^missing_review_override_ts=//p' "$META" | tail -n 1)
META_LINES=("pr=$URL")
[ -z "$PR_HEAD" ] || META_LINES+=("pr_head=$PR_HEAD")
if fm_pr_override_ts_valid "$OVERRIDE_TS"; then
  if [ "$PRIOR_PR" = "$URL" ]; then
    META_LINES+=("missing_review_override_ts=$OVERRIDE_TS")
  else
    echo "warning: discarding the captain-authorized missing-Review override recorded for ${PRIOR_PR:-another pull request}; $URL needs its own authorization" >&2
  fi
fi
# The non-green override is one receipt across four lines, so a partial or
# self-inconsistent set carries nothing forward rather than a half-record.
RED_TS=$(sed -n 's/^red_override_ts=//p' "$META" | tail -n 1)
RED_PR=$(sed -n 's/^red_override_pr=//p' "$META" | tail -n 1)
RED_HEAD=$(sed -n 's/^red_override_head=//p' "$META" | tail -n 1)
RED_CONDITION=$(sed -n 's/^red_override_condition=//p' "$META" | tail -n 1)
if fm_pr_override_ts_valid "$RED_TS" && fm_pr_head_valid "$RED_HEAD" \
  && [ -n "$RED_CONDITION" ] && [ "$RED_PR" = "$PRIOR_PR" ]; then
  if [ "$PRIOR_PR" = "$URL" ]; then
    META_LINES+=("red_override_ts=$RED_TS" "red_override_pr=$RED_PR" \
      "red_override_head=$RED_HEAD" "red_override_condition=$RED_CONDITION")
  else
    echo "warning: discarding the captain-authorized non-green merge override recorded for ${PRIOR_PR:-another pull request}; $URL needs its own authorization" >&2
  fi
fi
fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-meta \
  pr:pr_head:missing_review_override_ts:red_override_ts:red_override_pr:red_override_head:red_override_condition \
  pr_check_meta_identity_matches "${META_LINES[@]}" \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
fm_pr_meta_unlock

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). An implicit checkout fallback is not a home
# identity and never publishes through markers it happens to contain. A main
# home has no channel and this is a silent no-op there. The poll is armed either
# way; a channel that cannot be written is reported as actionable, and
# bin/fm-inactive-reconcile.sh still delivers the child's own ready line on the
# next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
if [ "$FM_PR_CHECK_HOME_EXPLICIT" = true ]; then
  fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
else
  READY_RC=1
fi
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
OWNER_RC=0
OWNER_ERR=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pipeline.sh" reconcile "$ID" 2>&1 >/dev/null) || OWNER_RC=$?
if [ "$OWNER_RC" -ne 0 ]; then
  OWNER_ERR=$(printf '%s' "$OWNER_ERR" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  printf 'warning: pipeline record for %s was not reconciled (rc=%s): %s\n' \
    "$ID" "$OWNER_RC" "$OWNER_ERR" >&2
fi
printf 'armed: state/%s.check.sh\n' "$ID"
