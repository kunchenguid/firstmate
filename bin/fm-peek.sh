#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or an explicit target - a herdr pane id, or a
#   tmux session:window for a pre-cutover pane still being drained.
#
# Reads go through bin/fm-herdr.sh. Agents run in herdr and it is the only
# surface firstmate spawns onto, so there is no driver to choose.
#
# THE DRAIN. Crewmates spawned before the herdr cutover live in tmux windows and
# their meta has no `mux=herdr` line. Those must stay readable until they are
# torn down: a watcher that cannot read a live crewmate is blind, and some of
# that work carries unlanded commits. fm_herdr_resolve marks them, and only
# those take the legacy tmux read below. Nothing new ever does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-herdr.sh
. "$SCRIPT_DIR/fm-herdr.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

fm_herdr_resolve "$1" "$STATE" || exit 1
N=${2:-40}

if [ "$FM_HERDR_DRAIN" = 1 ]; then
  # DRAIN ONLY - byte-identical to the pre-cutover read. Delete this branch when
  # fm_herdr_drain_pending reports no pre-cutover meta is left in any home.
  tmux capture-pane -p -t "$FM_HERDR_TARGET" -S -"$N"
else
  # A failed read must not look like a quiet crewmate. Peek is the first step of
  # the stale-wake and stuck-crewmate playbooks, so exiting non-zero with no
  # output told the operator nothing about a pane that may simply be gone.
  if ! fm_herdr_read "$FM_HERDR_TARGET" "$N"; then
    echo "error: could not read $FM_HERDR_TARGET; the pane may be gone, the id wrong, or the server down" >&2
    exit 1
  fi
fi
