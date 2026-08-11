#!/usr/bin/env bash
# Report whether a tracked primary-session integration may act in this checkout.
# Usage: fm-primary-scope.sh [--root <directory>] [--state <directory>]
#
# Exit 0 means the supplied checkout is a genuine primary Firstmate home.
# Exit 1 means it is inert, including every unmarked linked task worktree.
# The predicate itself is owned by bin/fm-primary-scope-lib.sh.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 1
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}

usage() {
  printf '%s\n' 'Usage: fm-primary-scope.sh [--root <directory>] [--state <directory>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -gt 1 ] || { usage >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    --state)
      [ "$#" -gt 1 ] || { usage >&2; exit 2; }
      STATE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$ROOT" "$STATE"
