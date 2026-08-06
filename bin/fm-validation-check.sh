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
CHECK_SLOT_HELD=0
MIGRATION_BOUNDARY_HELD=0
cleanup() {
  [ -z "${TMP:-}" ] || rm -f -- "$TMP"
  [ "$CHECK_SLOT_HELD" -ne 1 ] || fm_custom_check_slot_release
  [ "$MIGRATION_BOUNDARY_HELD" -ne 1 ] || fm_custom_check_migration_release
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
TMP=$(mktemp "$STATE/.fm-validation-check.XXXXXX") || exit 1
fm_validation_check_source_emit "$worktree" "$NM_RUN_LIB" "$TEMPLATE" > "$TMP" || exit 1
chmod 0700 "$TMP" || exit 1
fm_pr_private_file_valid "$TMP" 700 "$STATE_DEVICE" || exit 1
if ! fm_custom_check_register_source "$STATE" "$ID" "$TMP"; then
  echo "error: could not register validation check" >&2
  exit 1
fi
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$CHECK" || exit 1
TMP=

fm_validation_check_registered "$STATE" "$ID" "$NM_RUN_LIB" "$TEMPLATE" || {
  echo "error: validation check registration could not be verified" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
