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
# (bin/fm-backend.sh's FM_BACKEND_SECONDMATE) and must be ready to launch one:
# its own CLI and toolchain present, and for hc and rex its core or server
# reachable, through the same adapter checks fm-spawn runs. All of that is
# checked before anything is stopped. Recovery keeps a local mate on its
# recorded backend (PR #8082), so a completed move needs no config/backend
# change to last. The record is snapshotted before the launch; a launch that
# fails after the stop has its previous record put back under the record's
# meta lock, so the next liveness recovery respawns the mate on its previous,
# recorded backend; a different record found in place by then is left alone.
# The failure says which of those happened.
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
  sed -n '2,/^set -u/{/^#/{s/^# \{0,1\}//;p;};}' "$0"
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

# Every target check runs before the agent is stopped, so an impossible move
# costs nothing.
fm_backend_validate_spawn "$TARGET" || exit 1
fm_backend_secondmate_supported "$TARGET" \
  || die "backend=$TARGET does not support --secondmate spawns yet (secondmate-capable: $FM_BACKEND_SECONDMATE)"
fm_backend_runtime_check "$TARGET" || exit 1
# The target's own tools (bin/fm-backend.sh's per-backend set, minus
# treehouse: a second mate launches in its home, never a leased worktree),
# then the reachability check fm-spawn runs before it opens an endpoint.
for TOOL in $(fm_backend_required_tools "$TARGET"); do
  [ "$TOOL" = treehouse ] || fm_backend_required_tool_available "$TARGET" "$TOOL" \
    || die "backend=$TARGET needs '$TOOL', which is not available here; nothing was stopped or moved"
done
case "$TARGET" in
  hc) fm_backend_hc_container_ensure >/dev/null || die "backend=hc is not ready to launch second mate $ID; nothing was stopped or moved" ;;
  rex) fm_backend_rex_local_server_ensure || die "backend=rex is not ready to launch second mate $ID; nothing was stopped or moved" ;;
esac
OLD_BACKEND=$(fm_backend_of_meta "$META")
[ "$OLD_BACKEND" != "$TARGET" ] || die "second mate $ID is already recorded on backend=$TARGET; to restart it in place use bin/fm-control.sh $ID relaunch"

first_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '/^error: /{p;q;}')
  [ -n "$line" ] || line=$1
  printf '%s\n' "$line" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
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

# A fresh spawn that fails rolls its record back, which removes this mate's
# existing one; the snapshot puts it back so liveness recovery still finds it.
SNAPSHOT="$STATE/.$ID.meta.move.$$"
cp -p "$META" "$SNAPSHOT" || die "could not snapshot second mate $ID's record before the launch; nothing was moved and its record is unchanged"
trap 'rm -f "$SNAPSHOT"; fm_secondmate_liveness_unlock "$ID"' EXIT
if fm_secondmate_liveness_relaunch "$META" "$ID" "" "$TARGET"; then
  printf 'moved %s from=%s to=%s\n' "$ID" "$OLD_BACKEND" "$TARGET"
  printf '%s\n' "$FM_SM_LIVE_OUT" | grep '^spawned ' || true
  exit 0
fi
# The restore runs under the record's meta lock, the one every record writer
# (fm-spawn, fm-control) publishes under, and only fills the gap the failed
# fresh spawn's rollback left: a record present by then was published by
# another writer, so it is left exactly as it is.
META_LOCK=$(fm_meta_lock_path "$META") && fm_lock_acquire_wait "$META_LOCK" \
  || die "second mate $ID could not be launched on $TARGET and its record lock could not be taken to put the previous record back; restore it from $SNAPSHOT: $(first_line "$FM_SM_LIVE_OUT")"
if [ ! -e "$META" ] && [ ! -L "$META" ]; then
  cp -p "$SNAPSHOT" "$META.move.$$" && mv -f "$META.move.$$" "$META" || {
    fm_lock_release "$META_LOCK" || true
    trap 'fm_secondmate_liveness_unlock "$ID"' EXIT
    die "second mate $ID could not be launched on $TARGET and its previous record could not be put back; restore it from $SNAPSHOT: $(first_line "$FM_SM_LIVE_OUT")"
  }
elif ! cmp -s "$SNAPSHOT" "$META"; then
  fm_lock_release "$META_LOCK" || true
  die "second mate $ID could not be launched on $TARGET after its $OLD_BACKEND agent was stopped, and a different record for it is now in place (published by another writer since, or left by the launch's own incomplete cleanup); that record was left as it is and the previous one was not put back: $(first_line "$FM_SM_LIVE_OUT")"
fi
fm_lock_release "$META_LOCK" || true
[ "$FM_SM_LIVE_STATUS" != skipped ] || die "$FM_SM_LIVE_REASON"
die "second mate $ID could not be launched on $TARGET after its $OLD_BACKEND agent was stopped; its home is unchanged and its previous record (backend=$OLD_BACKEND) is in place, so the next liveness recovery respawns it on $OLD_BACKEND: $(first_line "$FM_SM_LIVE_OUT")"
