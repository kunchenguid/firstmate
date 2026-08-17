#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha>, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
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
validate_task_metadata_fields() {
  if ! fm_pr_task_delivery_metadata_valid "$META" "$PROVIDER" "$HOST"; then
    case "$FM_PR_DELIVERY_ERROR" in
      invalid-issue-key) echo "error: task metadata carries an invalid issue key" >&2 ;;
      invalid-delivery-rule) echo "error: task metadata carries an invalid delivery rule" >&2 ;;
      *) echo "error: task metadata carries invalid delivery fields" >&2 ;;
    esac
    return 1
  fi
  ISSUE_KEY=$FM_PR_DELIVERY_ISSUE_KEY
  DELIVERY_TITLE_RULE=$FM_PR_DELIVERY_TITLE_RULE
  DELIVERY_LINK_RULE=$FM_PR_DELIVERY_LINK_RULE
  WT=$FM_PR_DELIVERY_WORKTREE
  DELIVERY_RULE=$FM_PR_DELIVERY_RULE
}

validate_provider_delivery_fields() {
FM_PR_PROVIDER_TITLE=$PR_TITLE
FM_PR_PROVIDER_BODY=$PR_BODY
  if ! fm_pr_task_delivery_provider_fields_valid; then
    case "$FM_PR_DELIVERY_ERROR" in
      provider-fields) echo "error: could not read PR title and body for delivery validation" >&2 ;;
      title-mismatch) echo "error: PR title does not match the declared delivery rule" >&2 ;;
      body-link-mismatch) echo "error: PR body does not link the expected issue" >&2 ;;
      *) echo "error: provider delivery fields are invalid" >&2 ;;
    esac
    return 1
fi
}

load_and_validate_provider_fields() {
PR_HEAD=
PR_TITLE=
PR_BODY=
if ! fm_pr_provider_fields_load "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$WT" 1; then
  if [ "$DELIVERY_RULE" = 1 ]; then
    echo "error: could not read PR title and body for delivery validation" >&2
  else
    echo "error: provider PR head is unavailable or invalid" >&2
  fi
  return 1
fi
PR_TITLE=$FM_PR_PROVIDER_TITLE
PR_BODY=$FM_PR_PROVIDER_BODY
PR_HEAD=$FM_PR_PROVIDER_HEAD
validate_provider_delivery_fields
}

validate_task_metadata_fields || exit 1
INITIAL_ISSUE_KEY=$ISSUE_KEY
INITIAL_DELIVERY_TITLE_RULE=$DELIVERY_TITLE_RULE
INITIAL_DELIVERY_LINK_RULE=$DELIVERY_LINK_RULE
INITIAL_WT=$WT

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

load_and_validate_provider_fields || exit 1

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
validate_task_metadata_fields || exit 1
[ "$ISSUE_KEY" = "$INITIAL_ISSUE_KEY" ] \
  && [ "$DELIVERY_TITLE_RULE" = "$INITIAL_DELIVERY_TITLE_RULE" ] \
  && [ "$DELIVERY_LINK_RULE" = "$INITIAL_DELIVERY_LINK_RULE" ] \
  && [ "$WT" = "$INITIAL_WT" ] || {
    echo "error: task metadata changed during PR validation" >&2
    exit 1
  }
validate_provider_delivery_fields || exit 1

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
load_and_validate_provider_fields || exit 1
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
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

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
printf 'armed: state/%s.check.sh\n' "$ID"
