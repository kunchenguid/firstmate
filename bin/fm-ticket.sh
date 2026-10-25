#!/usr/bin/env bash
# fm-ticket.sh - record one task's ticket truth on the fleet board now.
#
# The board is the sign-off board named by config/fleet-board, whose tickets the
# tickets-sync add-on publishes from this home's backlog and lane records. This
# is the fork-side call the lifecycle makes, so a merge, a dispatch, a cleanup or
# a release cut records what it knows at the moment it happens instead of leaning
# on whoever remembers to write a status line before the next poll.
#
# Usage: fm-ticket.sh <task-id> [--stage WORD] [--state WORD] [--pr URL] [--release TEXT]
#   --stage    queued | building | review | merging | done
#   --state    queued | "in progress" | "on hold" | done   (done also sets 100%)
#   --pr       the delivered PR's full URL; "" clears the linked PRs
#   --release  this ticket's target release
#
# The writer is addons/tickets-sync/ticket.py, installed at
# ${XDG_DATA_HOME:-$HOME/.local/share}/fm-tickets-sync/tickets-sync/ticket.py
# (FM_TICKETS_TICKET overrides the path).
# When the add-on is not installed, or this home has no fleet board, this does
# nothing and exits 0: the board is optional and the poll owns creating tickets.
# A failure names its cause on stderr and exits 1, so callers guard the call and
# a board problem never fails a merge, a spawn or a cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '/^# Usage:/,/^#   --release/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|--*) usage >&2; exit 2 ;;
esac
TASK=$1
shift
case "$TASK" in
  *[!A-Za-z0-9._-]*|'') echo "fm-ticket: invalid task id: $TASK" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || case "$1" in
  --stage|--state|--pr|--release) ;;
  *) usage >&2; exit 2 ;;
esac

WRITER="${FM_TICKETS_TICKET:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/fm-tickets-sync/tickets-sync/ticket.py}"
[ -f "$WRITER" ] || exit 0
[ -e "$CONFIG/fleet-board" ] || exit 0

if ! command -v python3 >/dev/null 2>&1; then
  echo 'fm-ticket: python3 is required to write a ticket' >&2
  exit 1
fi
FM_HOME=$FM_HOME exec python3 "$WRITER" "$TASK" "$@"
