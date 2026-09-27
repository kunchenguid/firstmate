#!/usr/bin/env bash
# Self-update the running firstmate to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash.
# A tracked-files update never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/).
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh. The script does not
# re-read AGENTS.md itself; the skill performs that agent action. It prints:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#
# A fast-forward that lands changes bytes under bin/ in place, which desyncs
# the trust binding of any locally armed fm-procevent-when watch whose action
# executable lives in the updated repo; left alone, the watch's next fire
# would be wrongly refused. After the update, this script best-effort runs the
# current home's fm-procevent-when.sh rebind-all to republish those bindings
# against the new bytes; a failure there is swallowed rather than failing the
# update.
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ]; then
  if [ -n "$FF_INSTR" ]; then
    reread_firstmate="yes"
  fi
  # A fast-forward changes bin/'s bytes out from under any locally armed
  # fm-procevent-when watch's trust binding, with no tampering involved; left
  # alone, the very next fire is refused and the watch dies silently. Refresh
  # every such watch now, right after the update that broke it. FM_ROOT_OVERRIDE
  # is passed explicitly rather than relying on the script's own location: this
  # process's own FM_ROOT is the repo that was just updated, which is not
  # always where this very script file happens to live (FM_ROOT_OVERRIDE, as
  # this test suite uses to point fm-update.sh at a fixture checkout).
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-procevent-when.sh" rebind-all || true
fi

echo "reread-firstmate: $reread_firstmate"
