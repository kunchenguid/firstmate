#!/usr/bin/env bash
# Arm a no-mistakes task's registered validation-gate watcher check.
#
# The task check is a private, ordinary mode-0700 file whose complete source is
# generated from fm-validation-poll.sh and fm-nm-run-lib.sh plus one shell-quoted
# worktree literal.
# It is registered before this command returns, so the watcher can only execute
# its hash-validated snapshot. The task's one check slot belongs to this poll
# until fm-pr-check.sh records pr=; a PR-marked task is left untouched because
# the authenticated static merge poll always has priority.
#
# The command changes files only under state/. It validates task metadata before
# publishing and fails rather than replacing an unknown or unregistered check.
#
# Usage:
#   fm-validation-check.sh <task-id>
#   fm-validation-check.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TEMPLATE="$SCRIPT_DIR/fm-validation-poll.sh"
NM_RUN_LIB="$SCRIPT_DIR/fm-nm-run-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,15{s/^# \{0,1\}//;p;}' "$0"
  exit 0
fi

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid validation check request" >&2
  exit 2
fi

ID=$1
META="$STATE/$ID.meta"
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: task state is unavailable" >&2
  exit 1
}
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
[ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || {
  echo "error: validation poll template is unavailable" >&2
  exit 1
}
[ -f "$NM_RUN_LIB" ] && [ ! -L "$NM_RUN_LIB" ] || {
  echo "error: validation run attribution library is unavailable" >&2
  exit 1
}

TMP=
TRUST_TMP=
CHECK_BACKUP=
TRUST_BACKUP=
CHECK_BACKUP_PRESENT=0
TRUST_BACKUP_PRESENT=0
VALIDATION_TRANSACTION_ACTIVE=0
VALIDATION_COMMITTED=0
CHECK_SLOT_HELD=0
MIGRATION_BOUNDARY_HELD=0
validation_backup_file() {
  local source=$1 label=$2 backup
  VALIDATION_BACKUP_PATH=
  VALIDATION_BACKUP_PRESENT=0
  [ ! -e "$source" ] && [ ! -L "$source" ] && return 0
  [ -f "$source" ] && [ ! -L "$source" ] && [ "$(fm_pr_file_link_count "$source")" = 1 ] || return 1
  backup=$(mktemp "$STATE/.fm-validation-$label.XXXXXX") || return 1
  if ! cp -p -- "$source" "$backup" \
    || [ ! -f "$backup" ] || [ -L "$backup" ] \
    || [ "$(fm_pr_file_link_count "$backup")" != 1 ] \
    || [ "$(fm_pr_file_device "$backup")" != "$STATE_DEVICE" ]; then
    rm -f -- "$backup"
    return 1
  fi
  VALIDATION_BACKUP_PATH=$backup
  VALIDATION_BACKUP_PRESENT=1
}

validation_restore_file() {
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

validation_rollback() {
  local failed=0
  [ "$VALIDATION_TRANSACTION_ACTIVE" -eq 1 ] || return 0
  [ "$VALIDATION_COMMITTED" -eq 0 ] || return 0
  validation_restore_file "$CHECK" "$CHECK_BACKUP" "$CHECK_BACKUP_PRESENT" || failed=1
  if [ "$CHECK_BACKUP_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    CHECK_BACKUP=
  fi
  validation_restore_file "$TRUST" "$TRUST_BACKUP" "$TRUST_BACKUP_PRESENT" || failed=1
  if [ "$TRUST_BACKUP_PRESENT" -eq 1 ] && [ "$failed" -eq 0 ]; then
    TRUST_BACKUP=
  fi
  return "$failed"
}

cleanup() {
  local status=$?
  validation_rollback || true
  [ -z "${TMP:-}" ] || rm -f -- "$TMP"
  [ -z "${TRUST_TMP:-}" ] || rm -f -- "$TRUST_TMP"
  [ -z "${FM_CUSTOM_CHECK_TRUST_TMP:-}" ] || rm -f -- "$FM_CUSTOM_CHECK_TRUST_TMP"
  [ -z "${CHECK_BACKUP:-}" ] || rm -f -- "$CHECK_BACKUP"
  [ -z "${TRUST_BACKUP:-}" ] || rm -f -- "$TRUST_BACKUP"
  [ "$CHECK_SLOT_HELD" -ne 1 ] || fm_custom_check_slot_release
  [ "$MIGRATION_BOUNDARY_HELD" -ne 1 ] || fm_custom_check_migration_release
  return "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if ! fm_custom_check_migration_acquire "$STATE" 100; then
  echo "error: validation check publication is busy" >&2
  exit 1
fi
MIGRATION_BOUNDARY_HELD=1
if ! fm_custom_check_slot_acquire "$STATE" "$ID" 100; then
  echo "error: task check slot is busy" >&2
  exit 1
fi
CHECK_SLOT_HELD=1

[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
kind=$(grep '^kind=' "$META" | tail -1 || true)
mode=$(grep '^mode=' "$META" | tail -1 || true)
worktree=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$kind" != kind=ship ] || [ "$mode" != mode=no-mistakes ] || [ -z "$worktree" ]; then
  echo "error: task is not a no-mistakes ship" >&2
  exit 1
fi

# fm-pr-check records pr= before publishing its static poll. That marker is the
# lifecycle hand-off, including while a PR publication is being retried, so a
# validation armer can never reclaim the slot from a merge watch.
if grep -q '^pr=' "$META"; then
  fm_pr_metadata_identity_parse "$META" || {
    echo "error: task PR metadata is invalid" >&2
    exit 1
  }
  printf 'preserved: state/%s.check.sh is reserved for PR merge polling\n' "$ID"
  exit 0
fi

STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || {
  echo "error: task check path is unavailable" >&2
  exit 1
}
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || {
  echo "error: task check trust path is unavailable" >&2
  exit 1
}
if fm_validation_check_registered "$STATE" "$ID" "$NM_RUN_LIB" "$TEMPLATE"; then
  printf 'armed: state/%s.check.sh\n' "$ID"
  exit 0
fi

umask 077
validation_backup_file "$CHECK" check || exit 1
CHECK_BACKUP=$VALIDATION_BACKUP_PATH
CHECK_BACKUP_PRESENT=$VALIDATION_BACKUP_PRESENT
validation_backup_file "$TRUST" trust || exit 1
TRUST_BACKUP=$VALIDATION_BACKUP_PATH
TRUST_BACKUP_PRESENT=$VALIDATION_BACKUP_PRESENT
VALIDATION_TRANSACTION_ACTIVE=1
TMP=$(mktemp "$STATE/.fm-validation-check.XXXXXX") || exit 1
fm_validation_check_source_emit "$worktree" "$NM_RUN_LIB" "$TEMPLATE" > "$TMP" || exit 1
chmod 0700 "$TMP" || exit 1
fm_pr_private_file_valid "$TMP" 700 "$STATE_DEVICE" || exit 1
if ! fm_custom_check_trust_prepare "$STATE" "$ID" "$TMP"; then
  echo "error: could not register validation check" >&2
  exit 1
fi
TRUST_TMP=$FM_CUSTOM_CHECK_TRUST_TMP
FM_CUSTOM_CHECK_TRUST_TMP=
FM_CUSTOM_CHECK_TRUST_HASH=
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TRUST_TMP" "$TRUST" || exit 1
TRUST_TMP=
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$CHECK" || exit 1
TMP=

fm_validation_check_registered "$STATE" "$ID" "$NM_RUN_LIB" "$TEMPLATE" || {
  echo "error: validation check registration could not be verified" >&2
  exit 1
}
VALIDATION_COMMITTED=1
printf 'armed: state/%s.check.sh\n' "$ID"
