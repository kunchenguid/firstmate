#!/usr/bin/env bash
# Record a PR/MR-ready task: store one validated canonical pr=<url> and the
# provider's exact pr_head=<sha> when available, then atomically arm a static
# merge poll. The watcher source is byte-for-byte bin/fm-pr-poll.sh; task and
# PR/MR data live only in a private sidecar and are never interpolated into
# shell source. GitHub PRs, GitLab MRs, and Codebase MRs are accepted.
# For direct-PR tasks this also arms the richer no-mistakes watch; --no-watch
# skips that second watch for a caller that is about to merge immediately.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--no-watch]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
ARM_WATCH=yes
case "${3:-}" in
  '') ;;
  --no-watch) ARM_WATCH=no ;;
  *) echo "error: invalid PR check request" >&2; exit 2 ;;
esac
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

case "$PROVIDER" in
  gitlab)
    command -v glab >/dev/null 2>&1 || { echo "error: watching a GitLab merge request requires glab on PATH" >&2; exit 1; }
    ;;
  codebase)
    fm_scm_require_bytedcli || exit 1
    fm_scm_require_jq || exit 1
    ;;
esac

"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
case "$PROVIDER" in
  github)
    if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
        && fm_pr_head_valid "$REMOTE_HEAD"; then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
    ;;
  codebase)
    if [ -n "$WT" ] && [ -d "$WT" ]; then
      if REMOTE_HEAD=$(fm_scm_pr_head "$WT" "$URL" 2>/dev/null) && fm_pr_head_valid "$REMOTE_HEAD"; then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
    ;;
esac

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

fm_pr_poll_publish_prepared || { echo "error: could not publish PR poll" >&2; exit 1; }
printf 'armed: state/%s.check.sh\n' "$ID"

if [ "$ARM_WATCH" = yes ] \
  && [ "$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)" = direct-PR ]; then
  "$FM_ROOT/bin/fm-nm-watch.sh" "$ID" "$URL" || true
fi
