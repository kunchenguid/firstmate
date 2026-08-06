#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
META="$STATE/$ID.meta"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CHECK_SLOT_HELD=0
check_register_cleanup() {
  fm_pr_poll_cleanup
  [ "$CHECK_SLOT_HELD" -ne 1 ] || fm_custom_check_slot_release
}
trap check_register_cleanup EXIT
trap 'exit 1' HUP INT TERM
if ! fm_custom_check_slot_acquire "$STATE" "$ID" 100; then
  echo "error: task check slot is busy" >&2
  exit 1
fi
CHECK_SLOT_HELD=1

if [ -e "$META" ] || [ -L "$META" ]; then
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || {
    echo "error: task metadata is unavailable" >&2
    exit 1
  }
  if grep -q '^pr=' "$META"; then
    fm_pr_metadata_identity_parse "$META" || {
      echo "error: task PR metadata is invalid" >&2
      exit 1
    }
    if ! fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh"; then
      fm_pr_poll_prepare "$STATE" "$ID" "$FM_PR_META_PROVIDER" "$FM_PR_META_URL" \
        "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
        || { echo "error: could not restore PR merge polling" >&2; exit 1; }
      fm_pr_poll_publish_prepared \
        || { echo "error: could not restore PR merge polling" >&2; exit 1; }
    fi
    printf 'preserved: state/%s.check.sh is reserved for PR merge polling\n' "$ID"
    exit 0
  fi
fi

[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_custom_check_register_source "$STATE" "$ID" "$CHECK" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
