#!/usr/bin/env bash
# fm-cs-relay.sh - bridge a codespace crewmate's status/turn-end signals back to
# this firstmate home's local state/ dir, so the existing file-mtime watcher
# backbone (fm-watch.sh) works unchanged for codespace-backed crewmates.
#
# Why a relay: the crewmate runs INSIDE the codespace, so its status appends and
# turn-end touches happen on the codespace filesystem, not in firstmate's local
# state/. This relay holds ONE persistent SSH stream that tails a single remote
# event file and demultiplexes it locally:
#   - a line "TURN-ENDED"            -> touch  state/<id>.turn-ended
#   - any other non-empty line       -> append state/<id>.status
# The crewmate brief points status appends and the turn-end hook at the same
# remote file (~/.fm/<id>.events), so one stream carries both signal kinds and
# the local files keep their existing meaning for the watcher.
#
# Usage:
#   fm-cs-relay.sh <task-id> <codespace>     # run the live relay (blocks)
#   fm-cs-relay.sh --demux <task-id>         # read events on stdin, demux (testable)
# The live relay's source command can be overridden for offline testing via
#   FM_CS_RELAY_SOURCE_CMD='<cmd that streams events to stdout>'
# which lets test/cs-relay-test.sh simulate the remote with a local tail -F.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-cs-lib.sh
. "$SCRIPT_DIR/fm-cs-lib.sh"

# Remote event file path inside the codespace (HOME-relative there).
FM_CS_REMOTE_EVENTS_DIR="${FM_CS_REMOTE_EVENTS_DIR:-.fm}"
TURNEND_MARK="${FM_CS_TURNEND_MARK:-TURN-ENDED}"

# demux: read event lines on stdin, route each to the local status/turn-end file.
# Side-effect free except for the two target files; deterministic and unit-tested.
cs_relay_demux() {
  local id=$1 line status_file turnend_file
  status_file="$STATE/$id.status"
  turnend_file="$STATE/$id.turn-ended"
  mkdir -p "$STATE"
  while IFS= read -r line; do
    case "$line" in
      "") continue ;;
      "$TURNEND_MARK") : > "$turnend_file"; touch "$turnend_file" ;;
      *) printf '%s\n' "$line" >> "$status_file" ;;
    esac
  done
}

# remote_source_cmd: the command whose stdout is the event stream. Real runs tail
# the remote events file over SSH (creating it first so tail -F has a target);
# tests inject FM_CS_RELAY_SOURCE_CMD instead.
remote_source_cmd() {
  local id=$1 cs=$2
  if [ -n "${FM_CS_RELAY_SOURCE_CMD:-}" ]; then
    eval "$FM_CS_RELAY_SOURCE_CMD"
    return
  fi
  cs_ssh "$cs" -- "mkdir -p '$FM_CS_REMOTE_EVENTS_DIR'; touch '$FM_CS_REMOTE_EVENTS_DIR/$id.events'; exec tail -n +1 -F '$FM_CS_REMOTE_EVENTS_DIR/$id.events'"
}

main() {
  case "${1:-}" in
    --demux)
      [ -n "${2:-}" ] || { echo "usage: fm-cs-relay.sh --demux <task-id>" >&2; exit 2; }
      cs_relay_demux "$2"
      ;;
    "")
      echo "usage: fm-cs-relay.sh <task-id> <codespace> | --demux <task-id>" >&2
      exit 2
      ;;
    *)
      local id=$1 cs=${2:-}
      [ -n "$cs" ] || { echo "usage: fm-cs-relay.sh <task-id> <codespace>" >&2; exit 2; }
      # Stream the remote events through the demux. If the SSH stream drops, the
      # caller (spawn-installed relay supervisor) restarts us; we do not loop here
      # so a torn-down codespace lets the relay exit cleanly.
      remote_source_cmd "$id" "$cs" | cs_relay_demux "$id"
      ;;
  esac
}
main "$@"
