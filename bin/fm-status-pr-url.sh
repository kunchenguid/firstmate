#!/usr/bin/env bash
# fm-status-pr-url.sh - print a task's recorded PR URL, or nothing.
#
# Usage: fm-status-pr-url.sh <task-id>
#
# Reads state/<task-id>.meta through fm-pr-lib.sh's own
# fm_pr_metadata_identity_parse, the canonical pr= reader every merge and
# PR-status path already uses, instead of re-deriving the parse here. Prints
# the recorded PR URL on stdout when a valid pr= line is present, otherwise
# prints nothing and still exits 0: no recorded PR is not a failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') usage >&2; exit 2 ;;
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

if fm_pr_metadata_identity_parse "$STATE/$1.meta"; then
  printf '%s\n' "$FM_PR_META_URL"
fi
exit 0
