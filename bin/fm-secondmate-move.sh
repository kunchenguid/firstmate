#!/usr/bin/env bash
# fm-secondmate-move.sh - move a LOCAL persistent second mate onto another
# runtime backend, keeping its home, records, and backlog exactly as they are.
#
# Usage: fm-secondmate-move.sh <secondmate-id> --backend <name>
#
# A second mate's home holds its state, backlog, charter, and projects; this
# home's state/<id>.meta only names the endpoint its agent runs in. A move
# therefore never touches the home. It stops the agent, closes the old
# endpoint, and respawns the mate through the one owner every recovery already
# uses - `bin/fm-spawn.sh <id> --secondmate` - with the target backend passed
# explicitly. The record that spawn republishes IS the move; nothing is
# hand-edited.
#
# The whole sequence runs under the mate's liveness lock
# (bin/fm-secondmate-liveness-lib.sh), so neither the session-start sweep nor
# the watcher's liveness tick can respawn the mate on its old backend between
# the stop and the new launch:
#   1. the recorded endpoint is probed;
#   2. an alive agent is stopped with `bin/fm-control.sh <id> exit`, which
#      proves the stop or refuses (a pending composer, an endpoint it cannot
#      prove absent, a backend with no recovery-grade classifier), and the
#      mate is probed again;
#   3. only a dead or confidently missing endpoint proceeds: a dead one is
#      closed, and the respawn lands on the target backend through
#      fm_secondmate_liveness_relaunch with that backend named, which records
#      the attempt and its outcome in the ordinary relaunch ledger.
# An ambiguous, unreadable, or unverified endpoint refuses before anything is
# stopped. A mate recorded with no endpoint at all is simply launched on the
# target backend. A remote mate is refused: its backend belongs to its host
# (docs/remote-secondmates.md).
#
# The target must be a spawn-capable backend that hosts second mates
# (bin/fm-backend.sh's FM_BACKEND_SECONDMATE), checked before anything is
# stopped. A launch that fails after the stop leaves the mate with no agent
# and its record unchanged - exactly the state the ordinary liveness recovery
# repairs on its next pass - and the failure says so plainly.
#
# Prints `moved <id> from=<old-backend> to=<new-backend>` followed by the
# spawn's own `spawned ...` line. Exit status: 0 moved; 1 refused or failed,
# with the message naming the state the mate was left in; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,41{s/^# \{0,1\}//;p;}' "$0"
}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

ID=
TARGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --backend)
      [ "$#" -ge 2 ] || { echo "error: --backend requires a value" >&2; exit 2; }
      TARGET=$2
      shift 2
      ;;
    --backend=*)
      TARGET=${1#--backend=}
      shift
      ;;
    -*)
      echo "error: unexpected argument '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one second mate id is expected" >&2; exit 2; }
      ID=${1#fm-}
      shift
      ;;
  esac
done
[ -n "$ID" ] && [ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $ID" >&2; exit 2 ;; esac
[ -d "$STATE" ] || die "state dir '$STATE' is missing; fm-secondmate-move cannot resolve second mates for FM_HOME '$FM_HOME'"

# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no task record for $ID in $STATE; a move needs the mate's own record"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || die "task $ID is not a second mate; fm-secondmate-move moves kind=secondmate records only"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -z "$REMOTE_HOST" ] || die "second mate $ID is placed on remote host $REMOTE_HOST, whose backend is its own; a local move is refused (docs/remote-secondmates.md)"

# Every target check runs before the agent is stopped, so an impossible move
# costs nothing.
fm_backend_validate_spawn "$TARGET" || exit 1
fm_backend_secondmate_supported "$TARGET" \
  || die "backend=$TARGET does not support --secondmate spawns yet (secondmate-capable: $FM_BACKEND_SECONDMATE)"
fm_backend_runtime_check "$TARGET" || exit 1
OLD_BACKEND=$(fm_backend_of_meta "$META")
[ "$OLD_BACKEND" != "$TARGET" ] || die "second mate $ID is already recorded on backend=$TARGET; to restart it in place use bin/fm-control.sh $ID relaunch"

first_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

fm_secondmate_liveness_lock "$ID" \
  || die "another liveness check or recovery is in progress for second mate $ID; retry once it finishes"
trap 'fm_secondmate_liveness_unlock "$ID"' EXIT

fm_secondmate_liveness_probe "$META" "$ID" poll
case "$FM_SM_LIVE_STATUS" in
  silent)
    # No endpoint recorded: nothing to stop or close, only the launch below.
    ;;
  alive)
    if ! EXIT_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-control.sh" "$ID" exit 2>&1); then
      die "second mate $ID's agent on $OLD_BACKEND could not be proven stopped, so nothing was moved and its record is unchanged: $(first_line "$EXIT_OUT")"
    fi
    fm_secondmate_liveness_probe "$META" "$ID" poll
    [ "$FM_SM_LIVE_STATUS" = relaunchable ] \
      || die "after the stop, second mate $ID's endpoint reads '$FM_SM_LIVE_STATE' rather than agent-free, so the move stops here with its record unchanged and no replacement launched"
    ;;
  relaunchable)
    ;;
  *)
    die "second mate $ID's endpoint cannot be classified ($FM_SM_LIVE_REASON); nothing was stopped or moved"
    ;;
esac

if fm_secondmate_liveness_relaunch "$META" "$ID" "" "$TARGET"; then
  printf 'moved %s from=%s to=%s\n' "$ID" "$OLD_BACKEND" "$TARGET"
  printf '%s\n' "$FM_SM_LIVE_OUT" | grep '^spawned ' || true
  exit 0
fi
[ "$FM_SM_LIVE_STATUS" != skipped ] || die "$FM_SM_LIVE_REASON"
die "second mate $ID could not be launched on $TARGET after its $OLD_BACKEND agent was stopped; no agent is running, its home and record are unchanged, and the next liveness recovery will respawn it: $(first_line "$FM_SM_LIVE_OUT")"
