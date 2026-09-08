#!/usr/bin/env bash
# Retire an intentional custom watcher check and its trust binding.
# Usage: fm-check-unregister.sh <id>
# Pass only the id. An unset FM_STATE_OVERRIDE selects FM_HOME/state; an
# explicitly empty override, an invalid id, or a resolved state path that is
# not an existing non-symlink directory is refused before removal.
# Each existing named artifact must be an ordinary single-link file on the
# state directory's device; only <id>.check.sh and <id>.check-trust are removed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check unregistration" >&2
  exit 2
fi

ID=$1

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
STATE_DEVICE=$(fm_pr_file_device "$STATE") || {
  echo "error: state directory is unavailable" >&2
  exit 1
}

for artifact in "$CHECK" "$TRUST"; do
  [ -e "$artifact" ] || [ -L "$artifact" ] || continue
  if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
    || [ "$(fm_pr_file_device "$artifact")" != "$STATE_DEVICE" ] \
    || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
    echo "error: custom check is unsafe to remove" >&2
    exit 1
  fi
done

rm -f -- "$CHECK" "$TRUST" || {
  echo "error: custom check could not be removed" >&2
  exit 1
}
printf 'unregistered: state/%s.check.sh\n' "$ID"
