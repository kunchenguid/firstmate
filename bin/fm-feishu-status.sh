#!/usr/bin/env bash
# Render the private Feishu channel status without message bodies, stable user
# or chat identifiers, session paths, or credentials.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

case "${1:-summary}" in
  summary)
    exec env FM_HOME="$FM_HOME" node "$SCRIPT_DIR/fm-feishu-state.mjs" status --public
    ;;
  bootstrap)
    exec env FM_HOME="$FM_HOME" node "$SCRIPT_DIR/fm-feishu-state.mjs" status --public --line --active-only
    ;;
  -h|--help|help)
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
    ;;
  *)
    printf 'usage: fm-feishu-status.sh [summary|bootstrap]\n' >&2
    exit 2
    ;;
esac
