#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# The identity record this writes into is the task's meta while the task is
# live, and the durable landing record bin/fm-teardown.sh leaves behind once the
# task is released with its request still unlanded, so releasing a worker before
# its request lands no longer ends the watch. When neither exists - a task
# released before landing records did - the record is rebuilt from a forge read
# of the request itself. A request the forge cannot resolve refuses instead.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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
# A live task records into its meta. A task released before its pull request
# landed has only the durable landing record bin/fm-teardown.sh left behind, and
# a task released before landing records existed has neither - the pull request
# is then the only authority for its own identity, so the record is rebuilt from
# a forge read rather than from anything the caller asserted. A request the forge
# cannot resolve still refuses: absence is never treated as evidence.
RECONSTRUCTED=0
if ! RECORD=$(fm_pr_identity_record_path "$STATE" "$ID"); then
  if ! fm_pr_forge_view "$URL"; then
    echo "error: task metadata is unavailable" >&2
    echo "No record for task $ID, and $URL could not be resolved at its forge." >&2
    exit 1
  fi
  RECONSTRUCTED_HEAD=$FM_PR_FORGE_HEAD
  if ! fm_pr_landing_record_write "$STATE" "$ID" "$URL" "$RECONSTRUCTED_HEAD" ""; then
    echo "error: task landing record could not be written" >&2
    exit 1
  fi
  RECORD=$(fm_pr_identity_record_path "$STATE" "$ID") || {
    echo "error: task metadata is unavailable" >&2
    exit 1
  }
  RECONSTRUCTED=1
  printf 'rebuilt: state/%s.landing from %s\n' "$ID" "$URL"
fi
if [ ! -f "$RECORD" ] || [ -L "$RECORD" ] || [ "$(fm_pr_file_link_count "$RECORD")" != 1 ]; then
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

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$RECORD" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$RECONSTRUCTED" = 1 ]; then
  # The rebuild above already asked the forge for this exact pull request.
  PR_HEAD=$RECONSTRUCTED_HEAD
elif [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
elif fm_pr_forge_view "$URL"; then
  # A released task has no worktree left to resolve the request from, so the
  # head comes straight from the request. This also recovers the head for a live
  # task whose worktree is already gone, which previously recorded none.
  PR_HEAD=$FM_PR_FORGE_HEAD
fi

RECORD_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$RECORD_TMP" ] || rm -f -- "$RECORD_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

RECORD_DEVICE=$(fm_pr_file_device "$RECORD") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$RECORD_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
RECORD_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$RECORD_TMP" || exit 1 ;;
  esac
done < "$RECORD"
printf 'pr=%s\n' "$URL" >> "$RECORD_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$RECORD_TMP" || exit 1
chmod 0600 "$RECORD_TMP" || exit 1
fm_pr_private_file_valid "$RECORD_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$RECORD_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$RECORD" "$STATE_DEVICE" || exit 1
mv -f -- "$RECORD_TMP" "$RECORD" || exit 1
RECORD_TMP=
fm_pr_private_file_valid "$RECORD" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$RECORD" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
