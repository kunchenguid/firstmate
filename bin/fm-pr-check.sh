#!/usr/bin/env bash
# Record a PR-ready task only after the standing independent-review gate clears:
# store one validated canonical pr=<url> and its exact reviewed pr_head=<sha>,
# then atomically arm a static merge poll.
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

# Neutralize every pre-fix poll before a review can wait.
# Hold normal migration notices until after the review line so a successful
# readiness report still leads with who independently read the exact head.
set +e
MIGRATION_OUTPUT=$("$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe)
MIGRATION_STATUS=$?
set -e
if [ "$MIGRATION_STATUS" -ne 0 ]; then
  [ -z "$MIGRATION_OUTPUT" ] || printf '%s\n' "$MIGRATION_OUTPUT"
  exit "$MIGRATION_STATUS"
fi

# This is the structural captain-readiness boundary.
# The reviewer gate inspects the current forge head, dispatches a cold
# different-family reviewer when needed, and succeeds only for a clear verdict
# bound to that exact head. Its single-line verdict is deliberately printed
# before any readiness mechanics so it can travel as the first captain-facing
# line. A pending, rejected, stale, or unresolvable review stops here without
# recording PR-ready metadata or publishing a merge poll.
REVIEW_HEAD_TMP=$(mktemp "$STATE/.fm-independent-review-head.XXXXXX") || exit 1
set +e
REVIEW_OUTPUT=$("$FM_ROOT/bin/fm-independent-review.sh" ready "$ID" "$URL" --head-file "$REVIEW_HEAD_TMP")
REVIEW_STATUS=$?
set -e
if [ -n "$REVIEW_OUTPUT" ]; then
  printf '%s\n' "$REVIEW_OUTPUT"
fi
[ -z "$MIGRATION_OUTPUT" ] || printf '%s\n' "$MIGRATION_OUTPUT"
if [ "$REVIEW_STATUS" -ne 0 ]; then
  rm -f -- "$REVIEW_HEAD_TMP"
  exit "$REVIEW_STATUS"
fi
PR_HEAD=
if ! { IFS= read -r PR_HEAD && ! IFS= read -r _EXTRA_REVIEW_HEAD; } < "$REVIEW_HEAD_TMP"; then
  rm -f -- "$REVIEW_HEAD_TMP"
  echo "error: independent review returned a malformed reviewed-head binding" >&2
  exit 1
fi
rm -f -- "$REVIEW_HEAD_TMP"
fm_pr_head_valid "$PR_HEAD" || {
  echo "error: independent review did not return an exact reviewed head" >&2
  exit 1
}

"$FM_ROOT/bin/fm-guard.sh" || true

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

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

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
