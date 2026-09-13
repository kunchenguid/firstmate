#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
set -u

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
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
if fm_pr_dir_mode_incapable "$STATE"; then
  # A mode-incapable device cannot express "was already private" at all, so
  # that signal is unavailable here regardless of what this script does; the
  # deliberate act of registering IS the operator's trust decision. Binding to
  # current bytes is this script's whole job, so registration is also the
  # moment such a device seals the check's signature.
  fm_pr_secure_file "$CHECK" 700 "$STATE" "$STATE_DEVICE" \
    || { echo "error: custom check is unavailable" >&2; exit 1; }
  fm_pr_private_file_valid "$CHECK" 700 "$STATE" "$STATE_DEVICE" \
    || { echo "error: custom check is unavailable" >&2; exit 1; }
else
  # Unchanged from before this device gained a signature fallback: the check
  # must already be mode 700 when this script is asked to trust it, so a
  # stray or carelessly-permissioned file is refused rather than silently
  # tightened on its way in.
  fm_pr_private_file_valid "$CHECK" 700 "$STATE" "$STATE_DEVICE" \
    || { echo "error: custom check is unavailable" >&2; exit 1; }
fi
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP" "$TMP.fm-sig"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
fm_pr_secure_file "$TMP" 600 "$STATE" "$STATE_DEVICE" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
mv -f -- "$TMP.fm-sig" "$TRUST.fm-sig" 2>/dev/null || true
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST" "$TRUST.fm-sig"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
