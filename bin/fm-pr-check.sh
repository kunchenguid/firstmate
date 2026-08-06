#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
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
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

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

if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
META_TMP=
CHECK_SLOT_HELD=0
MIGRATION_BOUNDARY_HELD=0
PR_HANDOFF_ACTIVE=0
PR_HANDOFF_COMMITTED=0
PR_ROLLBACK_META=
PR_ROLLBACK_CHECK=
PR_ROLLBACK_DATA=
PR_ROLLBACK_REGISTRATION=
PR_ROLLBACK_META_PRESENT=0
PR_ROLLBACK_CHECK_PRESENT=0
PR_ROLLBACK_DATA_PRESENT=0
PR_ROLLBACK_REGISTRATION_PRESENT=0

pr_check_backup_file() {
  local source=$1 label=$2 backup
  PR_CHECK_BACKUP_PATH=
  PR_CHECK_BACKUP_PRESENT=0
  [ ! -e "$source" ] && [ ! -L "$source" ] && return 0
  [ -f "$source" ] && [ ! -L "$source" ] && [ "$(fm_pr_file_link_count "$source")" = 1 ] || return 1
  backup=$(mktemp "$STATE/.fm-pr-check-$label.XXXXXX") || return 1
  if ! cp -p -- "$source" "$backup" \
    || [ ! -f "$backup" ] || [ -L "$backup" ] \
    || [ "$(fm_pr_file_link_count "$backup")" != 1 ] \
    || [ "$(fm_pr_file_device "$backup")" != "$STATE_DEVICE" ]; then
    rm -f -- "$backup"
    return 1
  fi
  PR_CHECK_BACKUP_PATH=$backup
  PR_CHECK_BACKUP_PRESENT=1
}

pr_check_restore_file() {
  local destination=$1 backup=$2 present=$3
  if [ "$present" -eq 1 ]; then
    [ -n "$backup" ] || return 1
    fm_pr_regular_destination_on_device_or_absent "$destination" "$STATE_DEVICE" || return 1
    mv -f -- "$backup" "$destination" || return 1
    return 0
  fi
  [ ! -e "$destination" ] && [ ! -L "$destination" ] && return 0
  fm_pr_regular_destination_on_device_or_absent "$destination" "$STATE_DEVICE" || return 1
  rm -f -- "$destination"
}

pr_check_rollback_discard() {
  [ -z "$PR_ROLLBACK_META" ] || rm -f -- "$PR_ROLLBACK_META"
  [ -z "$PR_ROLLBACK_CHECK" ] || rm -f -- "$PR_ROLLBACK_CHECK"
  [ -z "$PR_ROLLBACK_DATA" ] || rm -f -- "$PR_ROLLBACK_DATA"
  [ -z "$PR_ROLLBACK_REGISTRATION" ] || rm -f -- "$PR_ROLLBACK_REGISTRATION"
  PR_ROLLBACK_META=
  PR_ROLLBACK_CHECK=
  PR_ROLLBACK_DATA=
  PR_ROLLBACK_REGISTRATION=
  PR_ROLLBACK_META_PRESENT=0
  PR_ROLLBACK_CHECK_PRESENT=0
  PR_ROLLBACK_DATA_PRESENT=0
  PR_ROLLBACK_REGISTRATION_PRESENT=0
}

pr_check_rollback() {
  local failed=0
  [ "$PR_HANDOFF_ACTIVE" -eq 1 ] || return 0
  [ "$PR_HANDOFF_COMMITTED" -eq 0 ] || return 0
  pr_check_restore_file "$FM_PR_POLL_DATA_DEST" "$PR_ROLLBACK_DATA" "$PR_ROLLBACK_DATA_PRESENT" || failed=1
  if [ "$PR_ROLLBACK_DATA_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    PR_ROLLBACK_DATA=
  fi
  pr_check_restore_file "$FM_PR_POLL_REG_DEST" "$PR_ROLLBACK_REGISTRATION" "$PR_ROLLBACK_REGISTRATION_PRESENT" || failed=1
  if [ "$PR_ROLLBACK_REGISTRATION_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    PR_ROLLBACK_REGISTRATION=
  fi
  pr_check_restore_file "$FM_PR_POLL_CHECK_DEST" "$PR_ROLLBACK_CHECK" "$PR_ROLLBACK_CHECK_PRESENT" || failed=1
  if [ "$PR_ROLLBACK_CHECK_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    PR_ROLLBACK_CHECK=
  fi
  pr_check_restore_file "$META" "$PR_ROLLBACK_META" "$PR_ROLLBACK_META_PRESENT" || failed=1
  if [ "$PR_ROLLBACK_META_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    PR_ROLLBACK_META=
  fi
  return "$failed"
}

pr_check_cleanup() {
  local status=$?
  pr_check_rollback || true
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  pr_check_rollback_discard
  [ "$CHECK_SLOT_HELD" -ne 1 ] || fm_custom_check_slot_release
  [ "$MIGRATION_BOUNDARY_HELD" -ne 1 ] || fm_custom_check_migration_release
  return "$status"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
if ! fm_custom_check_migration_acquire "$STATE" 100; then
  echo "error: PR check publication is busy" >&2
  exit 1
fi
MIGRATION_BOUNDARY_HELD=1
if ! fm_custom_check_slot_acquire "$STATE" "$ID" 100; then
  echo "error: task check slot is busy" >&2
  exit 1
fi
CHECK_SLOT_HELD=1
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

fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
pr_check_backup_file "$META" meta || exit 1
PR_ROLLBACK_META=$PR_CHECK_BACKUP_PATH
PR_ROLLBACK_META_PRESENT=$PR_CHECK_BACKUP_PRESENT
pr_check_backup_file "$FM_PR_POLL_CHECK_DEST" check || exit 1
PR_ROLLBACK_CHECK=$PR_CHECK_BACKUP_PATH
PR_ROLLBACK_CHECK_PRESENT=$PR_CHECK_BACKUP_PRESENT
pr_check_backup_file "$FM_PR_POLL_DATA_DEST" data || exit 1
PR_ROLLBACK_DATA=$PR_CHECK_BACKUP_PATH
PR_ROLLBACK_DATA_PRESENT=$PR_CHECK_BACKUP_PRESENT
pr_check_backup_file "$FM_PR_POLL_REG_DEST" registration || exit 1
PR_ROLLBACK_REGISTRATION=$PR_CHECK_BACKUP_PATH
PR_ROLLBACK_REGISTRATION_PRESENT=$PR_CHECK_BACKUP_PRESENT
PR_HANDOFF_ACTIVE=1
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
PR_HANDOFF_COMMITTED=1
PR_HANDOFF_ACTIVE=0
pr_check_rollback_discard
printf 'armed: state/%s.check.sh\n' "$ID"
