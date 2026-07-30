#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
#
# This header is the owner of the custom-check file requirements that AGENTS.md
# section 7 delegates here. Registration writes state/<id>.check-trust (mode
# 0600) holding the check's current SHA-256, and the watcher refuses to execute
# any check whose trust record is missing or no longer matches.
#
# state/<id>.check.sh must be:
#   - an ordinary regular file, never a symlink;
#   - mode exactly 0700 (fm_pr_private_file_valid "$CHECK" 700);
#   - a single hard link (link count exactly 1);
#   - on the same device as the state directory, which must itself be a real
#     directory rather than a symlink.
# The same four conditions are re-verified on every watcher sweep, so a check
# that later gains a link, changes mode, or moves across devices stops running.
#
# Registration binds the check's bytes, so ANY later edit invalidates it and the
# check must be re-registered before the watcher will execute it again. A stale
# or unregistered check is not silently skipped: the watcher wakes firstmate with
# "check: rejected unauthenticated state checks: ..." so the gap is visible.
#
# The watcher never executes state/<id>.check.sh in place. It copies the file to
# a private mode-0600 snapshot, re-hashes the snapshot against the trust record,
# and runs that snapshot under `bash`, so the check cannot be swapped between
# verification and execution.
#
# Behavior the check itself must honor:
#   - Print nothing when firstmate should not wake. ANY non-empty output is a
#     wake, and the whole output is embedded in the wake reason, so it must be a
#     single line to keep that reason readable.
#   - Finish within FM_CHECK_TIMEOUT seconds (default 30, owned by
#     bin/fm-watch.sh and documented in docs/configuration.md). On timeout the
#     check's process group is killed, but output already written still counts as
#     a wake, so never emit a partial line before the decision is final.
#   - Expect to be polled no more often than FM_CHECK_INTERVAL (default 300s),
#     not once per watcher cycle.
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
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
