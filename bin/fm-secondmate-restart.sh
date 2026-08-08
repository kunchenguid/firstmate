#!/usr/bin/env bash
# Restart one already-live LOCAL second mate with changed launch flags, keeping
# its persistent home and everything in it.
#
# Usage: fm-secondmate-restart.sh <secondmate-id>
#          [--harness <name>] [--model <name>] [--effort <level>]
#          [--backend <name>] [--remote-control|--rc|--no-remote-control]
#
# WHY THIS EXISTS
#   A launch flag can only be changed at launch, and a persistent second mate is
#   never torn down for a flag change: bin/fm-teardown.sh is retirement (it
#   removes the route and the whole home). Before this script the only way to
#   relaunch a live second mate was to retire its endpoint by hand and then run
#   bin/fm-spawn.sh --secondmate. That improvisation is what this replaces: it
#   retires the recorded endpoint through the backend's own API and relaunches
#   the same id in the same home, so the home, backlog, project clones,
#   inherited local material, durable lease, registry route, unresolved routed
#   replies, this second mate's own crewmates, and every piece of unlanded work
#   are untouched.
#
# WHAT IT DOES NOT DO
#   It never returns a treehouse lease, edits data/secondmates.md, touches
#   data/<id>/, state/pending-reply/, the home's own state/ or backlog, or the
#   second mate's crewmate endpoints. It addresses exactly one endpoint - the
#   one recorded in state/<id>.meta - so it never scans for, matches, or closes
#   anything by label or name pattern, and it performs no session-level or
#   workspace-level lifecycle call.
#
# SCOPE
#   Local routes only. A remote second mate is refused up front: its endpoint
#   lives on its configured host, --remote-control is unsupported there
#   (bin/fm-spawn.sh), and an unreachable host is unknown completion rather than
#   a dead endpoint. Reconcile a remote route on its own host.
#
# ENDPOINT RECONCILIATION (the only duplicate-agent guard on this path)
#   A --secondmate spawn skips fm-spawn's presentation block entirely, so it has
#   no existing-metadata duplicate check; the backend's same-label create refusal
#   is the only backstop. This preflight is therefore strict, and it runs under
#   the same state/.spawn-<id>.lock that fm-spawn and the Herdr session cleanup
#   use, so a concurrent spawn or restart of this id cannot interleave with it.
#   The authoritative data/secondmates.md route is validated under its shared
#   registry lock before the endpoint is touched. Both locks are handed directly
#   to fm-spawn and remain held through metadata publication or rollback, so
#   there is no unlocked relaunch gap in which another backend can publish a
#   replacement.
#   The recorded endpoint is validated by fm_backend_validate_task_endpoint and
#   then classified by fm_backend_agent_state:
#     alive    - retire it, then relaunch.
#     dead     - the endpoint exists with no agent; retire the husk, relaunch.
#     missing  - already gone; nothing to retire, relaunch straight away.
#     anything else (ambiguous, unreadable, unverified) - REFUSE, mutating
#                nothing. Zellij lands here because it has no verified recovery
#                classifier, the same reason the session-start liveness sweep
#                skips it; Orca and cmux land here too and additionally cannot
#                hold a second mate endpoint at all. Only tmux and Herdr have
#                the verified classifier this path needs.
#   fm_backend_kill's exit status is never trusted: the Herdr adapter returns 0
#   for a successful close, an unready target, AND a refused unlocked close. The
#   only gate is the post-kill re-read, which must report `missing`. A close that
#   is refused, skipped, or unconfirmed is treated as potentially still running
#   and exits non-zero without relaunching or rewriting metadata, so a contended
#   lock is a plain rerun.
#
# LAUNCH FLAGS
#   Flags are passed straight through to bin/fm-spawn.sh, which owns their
#   validation. Omitted axes are NOT replayed from the old metadata: harness,
#   model, and effort are re-resolved from config/secondmate-harness on every
#   spawn, which is what makes that pin durable, and replaying a recorded value
#   would defeat it.
#   remote_control is the deliberate exception. It has no config file, so
#   metadata is its only durable record - which is exactly why
#   bin/fm-bootstrap.sh's liveness sweep reads it back when it relaunches a dead
#   second mate. Every other axis survives a relaunch, so this one does too:
#     --remote-control (--rc)  turn it on
#     --no-remote-control      turn it off
#     neither flag             keep whatever state/<id>.meta recorded
#   Both directions are explicit; only an unflagged run inherits. Remote Control
#   stays Claude-local-only and fm-spawn still refuses it for any other harness,
#   every raw launch command, and every remote second mate. This script does not
#   change bin/fm-bootstrap.sh's own retention behavior.
#   Because the harness is re-resolved rather than replayed, an inherited
#   remote_control=1 whose second mate has since been re-pinned to a non-Claude
#   harness makes fm-spawn refuse the relaunch. The refusal names the harness
#   restriction, the previous record is restored as below, and
#   --no-remote-control is the way through.
#
# IF THE RELAUNCH FAILS
#   A failure before replacement creation restores the previous state/<id>.meta
#   snapshot. A failure after creation closes that exact replacement and restores
#   the snapshot only after its backend reports `missing`; an unconfirmed
#   replacement keeps its current ownership record and the previous snapshot for
#   reconciliation. A restored record still carries kind=secondmate and window=,
#   which lets the next locked session-start liveness sweep relaunch it and replay
#   remote_control=1 when previously enabled. The error names the retry command.
#
# On success prints: restarted <id> <spawn success line>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# retire or relaunch a direct report.
fm_refuse_if_gate_agent

ID=
REMOTE_CONTROL=inherit
SPAWN_ARGS=()
# Kept verbatim so a failure can hand back the operator's OWN invocation: after
# a rollback the restored record no longer implies the flags they asked for, so
# a retry hint without them would silently do something else.
INVOCATION=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote-control|--rc) REMOTE_CONTROL=on ;;
    --no-remote-control) REMOTE_CONTROL=off ;;
    --harness|--model|--effort|--backend)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      SPAWN_ARGS+=("$1" "$2")
      shift
      ;;
    --harness=*|--model=*|--effort=*|--backend=*)
      SPAWN_ARGS+=("${1%%=*}" "${1#*=}")
      ;;
    -*)
      echo "error: unknown flag '$1'; see fm-secondmate-restart.sh --help" >&2
      exit 2
      ;;
    *)
      [ -z "$ID" ] || { echo "error: unexpected extra argument '$1'; restart one second mate at a time" >&2; exit 2; }
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: fm-secondmate-restart.sh <secondmate-id> [flags]; see --help" >&2; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: no local second mate record for '$ID' at $META; nothing to restart" >&2
  exit 1
}
grep -qx 'kind=secondmate' "$META" 2>/dev/null || {
  echo "error: task $ID is not a second mate; this path restarts persistent second mates only" >&2
  exit 1
}
# One task-scoped lock and the authoritative route lock span the full restart.
RESTART_LOCK="$STATE/.spawn-$ID.lock"
REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
RESTART_LOCK_HELD=0
REGISTRY_LOCK_HELD=0
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
release_restart_locks() {
  if [ "$REGISTRY_LOCK_HELD" = 1 ]; then
    REGISTRY_LOCK_HELD=0
    fm_lock_release "$REGISTRY_LOCK" || true
  fi
  if [ "$RESTART_LOCK_HELD" = 1 ]; then
    RESTART_LOCK_HELD=0
    fm_lock_release "$RESTART_LOCK" || true
  fi
}
trap release_restart_locks EXIT
if ! fm_lock_try_acquire "$RESTART_LOCK"; then
  echo "error: another spawn or restart is already changing second mate $ID; nothing was changed" >&2
  exit 1
fi
RESTART_LOCK_HELD=1
RESTART_LOCK_OWNER=$FM_LOCK_OWNER_DIR
if ! fm_lock_acquire_wait "$REGISTRY_LOCK"; then
  echo "error: secondmate registry could not be locked; nothing was changed" >&2
  exit 1
fi
REGISTRY_LOCK_HELD=1
REGISTRY_LOCK_OWNER=$FM_LOCK_OWNER_DIR

META_HOME=$(fm_meta_get "$META" home)
if [ -z "$META_HOME" ] || ! secondmate_registry_validate_bindings \
  "$DATA/secondmates.md" secondmate_registry_path_key "$ID"; then
  echo "error: cannot reconcile second mate $ID with its authoritative registry route: ${SECONDMATE_REGISTRY_ERROR:-recorded home is missing}; nothing was changed" >&2
  exit 1
fi
if [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 1 ]; then
  echo "error: second mate $ID is a remote route; its endpoint lives on its configured host and must be reconciled there, not restarted locally" >&2
  exit 1
fi
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  echo "error: second mate $ID has remote route metadata that conflicts with its authoritative local registry route; refusing an ambiguous endpoint without changing it" >&2
  exit 1
fi
if ! secondmate_registry_validate_bindings \
  "$DATA/secondmates.md" secondmate_registry_path_key "$ID" "$META_HOME"; then
  echo "error: cannot reconcile second mate $ID with its authoritative registry route: $SECONDMATE_REGISTRY_ERROR; nothing was changed" >&2
  exit 1
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET

AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null) || AGENT_STATE=unreadable
case "$AGENT_STATE" in
  alive|dead)
    fm_backend_kill "$BACKEND" "$TARGET" 2>/dev/null || true
    CONFIRMED=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null) || CONFIRMED=unreadable
    if [ "$CONFIRMED" != missing ]; then
      echo "error: the existing $BACKEND endpoint for second mate $ID is not confirmed gone after its close (state=$CONFIRMED); it may still be running, so nothing else was changed. Rerun this command once the close can complete." >&2
      exit 1
    fi
    ;;
  missing)
    : # Already gone; there is nothing to retire before the relaunch.
    ;;
  *)
    echo "error: the recorded $BACKEND endpoint for second mate $ID reads as $AGENT_STATE, not a state that licenses replacing it; refusing to risk a duplicate agent. Nothing was changed." >&2
    exit 1
    ;;
esac

# The endpoint is gone and cannot be un-killed, so the previous record is the
# rollback: restoring it keeps the second mate recoverable by the session-start
# liveness sweep if the relaunch below fails.
META_BACKUP="$STATE/.secondmate-restart-$ID.meta.bak"
cp "$META" "$META_BACKUP" || {
  echo "error: could not snapshot the record for second mate $ID; refusing to relaunch without a recoverable record" >&2
  exit 1
}

case "$REMOTE_CONTROL" in
  on) SPAWN_ARGS+=(--remote-control) ;;
  off) : ;;
  inherit) grep -qx 'remote_control=1' "$META_BACKUP" 2>/dev/null && SPAWN_ARGS+=(--remote-control) || : ;;
esac

if ! rm -f -- "$META" || [ -e "$META" ] || [ -L "$META" ]; then
  mv -f "$META_BACKUP" "$META" 2>/dev/null || true
  echo "error: could not clear the retired record for second mate $ID before relaunch; refusing without an unambiguous replacement boundary" >&2
  exit 1
fi

if SPAWN_OUT=$(FM_SPAWN_RESTART_TASK_LOCK_OWNER="$RESTART_LOCK_OWNER" \
  FM_SPAWN_RESTART_REGISTRY_LOCK_OWNER="$REGISTRY_LOCK_OWNER" \
  "$FM_ROOT/bin/fm-spawn.sh" "$ID" --secondmate ${SPAWN_ARGS[@]+"${SPAWN_ARGS[@]}"} 2>&1); then
  rm -f "$META_BACKUP" 2>/dev/null || true
  printf 'restarted %s %s\n' "$ID" "$(printf '%s\n' "$SPAWN_OUT" | tail -1)"
  exit 0
fi

printf '%s\n' "$SPAWN_OUT" >&2
RETRY="$FM_ROOT/bin/fm-secondmate-restart.sh ${INVOCATION[*]}"
if [ ! -e "$META_BACKUP" ]; then
  echo "error: second mate $ID was retired but its relaunch failed; its previous record was restored, so its home, backlog, work, and its own crewmates are untouched and the next session start relaunches it. Retry now with: $RETRY" >&2
elif fm_lock_points_to_owner "$RESTART_LOCK" "$RESTART_LOCK_OWNER" \
  && [ "$(cat "$RESTART_LOCK_OWNER/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ] \
  && mv -f "$META_BACKUP" "$META" 2>/dev/null; then
  echo "error: second mate $ID was not relaunched; its previous record was restored before lock handoff, so its home, backlog, work, and its own crewmates are untouched. Retry now with: $RETRY" >&2
else
  echo "error: second mate $ID was retired, its relaunch failed, and its previous record could not be safely restored from $META_BACKUP without current task ownership; its home and work are untouched. Reconcile the current owner before retrying with: $RETRY" >&2
fi
exit 1
