#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
# Prints "registered: state/<id>.check.sh" on success. Exit 2 rejects a missing
# or malformed <id>; exit 1 reports an unusable state directory, check file,
# trust path, or a host with neither shasum nor sha256sum on PATH.
#
# This header is the owner of the custom-check file requirements that AGENTS.md
# section 7 delegates here. Registration writes state/<id>.check-trust (mode
# 0600) holding two lines, the literal version tag fm-custom-check-v1 and the
# check's current lowercase-hex SHA-256, and the watcher refuses to execute any
# check whose trust record is missing, malformed, or no longer matching. Deleting
# the trust record therefore un-registers the check, but that alone does not
# retire it: remove state/<id>.check.sh too, or the watcher keeps reporting it as
# unauthenticated on every sweep.
#
# state/<id>.check.sh must be:
#   - an ordinary regular file, never a symlink;
#   - mode exactly 0700;
#   - a single hard link (link count exactly 1);
#   - on the same device as the state directory, which must itself be a real
#     directory rather than a symlink.
# The trust record must satisfy the same four conditions at mode 0600. All of
# them are re-verified on every watcher sweep, so a check that later gains a
# link, changes mode, or moves across devices stops running.
#
# Registration binds the check's bytes, so ANY later edit invalidates it and the
# check must be re-registered before the watcher will execute it again. A stale
# or unregistered check is not silently skipped: the watcher wakes firstmate with
# "check: rejected unauthenticated state checks: ..." so the gap is visible. That
# same wake also covers an invalid X-mode relay shim, so it is not exclusively a
# custom-check signal.
#
# The watcher never executes state/<id>.check.sh in place. It copies the file to
# a private mode-0600 snapshot, re-hashes the snapshot against the trust record,
# and runs that snapshot under `bash`, so the check cannot be swapped between
# verification and execution.
#
# state/<id>.check.sh is also where bin/fm-pr-check.sh publishes the merge poll,
# at mode 0600, and the watcher tries poll validation before the custom path. One
# task id therefore carries either an armed merge poll or a custom check, never
# both: registering over an armed poll fails because the published poll is not
# mode 0700.
#
# Behavior the check itself must honor:
#   - Print nothing when firstmate should not wake. ANY non-empty output is a
#     wake, and the whole output is embedded in the wake reason, so it must be a
#     single line to keep that reason readable.
#   - Finish within FM_CHECK_TIMEOUT seconds (default 30, owned by
#     bin/fm-watch.sh and documented in docs/configuration.md). On timeout the
#     check's process group is killed, but output already written still counts as
#     a wake, so never emit a partial line before the decision is final.
#   - Expect to be polled no more often than FM_CHECK_INTERVAL (default 300s,
#     lowered to 30s in X-mode homes), not once per watcher cycle.
#   - Stay level-triggered and idempotent. The first check in glob order that
#     prints output ends the whole watcher cycle, so any later check waits
#     another full interval; a check that reports a condition only once can lose
#     that edge entirely.
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
