#!/usr/bin/env bash
# Relaunch a REMOTE secondmate onto a new harness, model, or effort, then
# republish this parent's own route record to match what the host confirmed.
#
# Usage: fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|-> [--expect-generation <gen>]
#
# bin/fm-remote-secondmate-control.sh's relaunch verb runs entirely on the
# secondmate's own host and can only rewrite that host's own endpoint record;
# this parent's route record (state/<id>.meta here, marked remote_host=... to
# a different machine) is a separate file that verb has no access to. Running
# the relaunch alone therefore leaves this file naming the runtime the mate
# used to run, not the one it runs now.
#
# This wrapper is the missing other half, and the whole parent side of one
# replacement transaction. It holds this home's supervisor lifecycle episode
# for the mate (bin/fm-secondmate-liveness-lib.sh) from before the fleet seat
# reservation through publication, so no liveness recovery, spawn, or other
# relaunch of the same mate can interleave. Under the task metadata lock it
# reserves the replacement generation's seat naming the generation it
# replaces, dispatches it with that generation as the host operation token,
# runs the host-local relaunch through bin/fm-on.sh exactly as
# secondmate-provisioning documents, and applies the host's token-scoped
# disposition through the same decoder every remote seat path uses
# (bin/fm-fleet-seats.sh reconcile-remote). Only a confirmed start republishes
# this home's harness, model, effort, and seat generation, read back from the
# endpoint's own route report; a refused relaunch leaves this parent's record
# untouched and releases only its own candidate, and an unknown outcome keeps
# the candidate counted for reconciliation. Nothing is ever cancelled by task
# id alone.
#
# --expect-generation refuses (exit 6, nothing touched) when this record now
# names another launch generation, so a restart whose persistence belonged to an
# earlier incarnation never stops a newer one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

EXPECT_GENERATION=
case "$#" in
  4) ;;
  6) [ "$5" = --expect-generation ] || usage; [ -n "$6" ] || { echo "error: missing expected generation; nothing was changed" >&2; exit 6; }; EXPECT_GENERATION=$6 ;;
  *) usage ;;
esac
ID=$1
HARNESS=$2
MODEL=$3
EFFORT=$4
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$EXPECT_GENERATION" in *[!A-Za-z0-9._-]*) die "invalid expected generation: $EXPECT_GENERATION" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; use bin/fm-control.sh $ID relaunch instead"

LIFECYCLE_JOINED=0
META_LOCK=
ROUTE_FILE=
cleanup() {
  [ -z "$ROUTE_FILE" ] || rm -f "$ROUTE_FILE"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
  [ "$LIFECYCLE_JOINED" = 0 ] || fm_supervisor_lifecycle_release "$STATE" "$ID" || true
}
trap cleanup EXIT

lifecycle_rc=0
fm_supervisor_lifecycle_adopt "$STATE" "$ID" || lifecycle_rc=$?
case "$lifecycle_rc" in
  0) ;;
  1)
    fm_supervisor_lifecycle_acquire "$STATE" "$ID" 30 \
      || die "another lifecycle episode for secondmate $ID is running (pid ${FM_LOCK_HELD_PID:-unknown}); nothing was changed"
    LIFECYCLE_JOINED=1
    ;;
  *) die "the inherited lifecycle carrier for secondmate $ID does not verify against its live episode; nothing was changed" ;;
esac
META_LOCK=$(fm_meta_lock_path "$META") || die "metadata lock path is invalid for $ID"
fm_lock_acquire_wait_max "$META_LOCK" 30 || { META_LOCK=; die "metadata for $ID stayed locked"; }

seats() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-fleet-seats.sh" "$@"
}

# The seat ledger, not this record, is the authority for which generation is
# running: after a failed publication the record can still name an older one,
# and a later relaunch must replace the confirmed generation, not that stale
# projection.
PREV_GEN=$(fm_meta_get "$META" remote_spawn_gen)
[ -n "$PREV_GEN" ] || PREV_GEN=$(fm_meta_get "$META" fleet_seat_generation)
LEDGER_GEN=$(seats show "$ID" 2>/dev/null \
  | jq -r '[.incarnations[] | select(.lifecycle == "reserved" or .lifecycle == "confirmed")] | ((map(select(.lifecycle == "confirmed")) | last) // last) | .generation // empty' 2>/dev/null || true)
[ -z "$LEDGER_GEN" ] || PREV_GEN=$LEDGER_GEN
if [ -n "$EXPECT_GENERATION" ] && [ "$PREV_GEN" != "$EXPECT_GENERATION" ]; then
  echo "error: generation-mismatch: remote secondmate $ID now records generation '${PREV_GEN:-none}', not the expected $EXPECT_GENERATION; nothing was changed" >&2
  exit 6
fi
if [ -n "$LEDGER_GEN" ]; then
  seats reclaim "$ID" --generation "$LEDGER_GEN" >&2 \
    || die "remote secondmate $ID's ledger predecessor is unresolved; nothing was changed"
fi
[ -n "$PREV_GEN" ] || PREV_GEN=-
NEW_GEN="s$(date +%s).$$.$RANDOM"

SEAT_OUT=$(seats reserve "$ID" --generation "$NEW_GEN" --previous-generation "$PREV_GEN" --kind secondmate \
  --harness "$HARNESS" --model "$MODEL" --holder-pid "$$") \
  || { echo 'relaunch_failure=prelaunch' >&2; die "remote secondmate $ID has no fleet seat for model $MODEL"; }
[ -z "$SEAT_OUT" ] || printf '%s\n' "$SEAT_OUT" >&2
SEAT_TRACKED=0
case "$SEAT_OUT" in 'fleet-seats: reserved '*|'fleet-seats: recorded '*) SEAT_TRACKED=1 ;; esac

RELAUNCH_ARGS=(relaunch "$ID" "$HARNESS" "$MODEL" "$EFFORT")
[ -z "$EXPECT_GENERATION" ] || RELAUNCH_ARGS+=(--expect-generation "$EXPECT_GENERATION")
if [ "$SEAT_TRACKED" -eq 1 ]; then
  ROUTE_FILE=$(umask 077 && mktemp "$STATE/.seat-route-$ID.XXXXXX") || die "cannot stage the seat route for $ID"
  if ! { jq -cn --arg host "$REMOTE_HOST" --arg root "$(fm_meta_get "$META" remote_root)" \
      --arg home "$(fm_meta_get "$META" home)" --arg op "$NEW_GEN" \
      '{placement: "remote", backend: "herdr", target: null, home: $home, host: $host,
        remote_root: $root, spawn_gen: null, operation: $op}' > "$ROUTE_FILE" \
    && seats dispatch "$ID" --generation "$NEW_GEN" --route-file "$ROUTE_FILE" >/dev/null; }; then
    seats release "$ID" --generation "$NEW_GEN" --reason prelaunch >/dev/null 2>&1 || true
    echo 'relaunch_failure=prelaunch' >&2
    die "remote secondmate $ID relaunch was not dispatched: its fleet seat could not record the host operation"
  fi
  RELAUNCH_ARGS+=(--operation "$NEW_GEN" --previous "$PREV_GEN")
fi

rc=0
RELAUNCH_OUT=$(fm_run_timed 300 "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh \
  "${RELAUNCH_ARGS[@]}" </dev/null 2>&1) || rc=$?

DISPOSITION=
if [ "$SEAT_TRACKED" -eq 1 ]; then
  RESPONSE=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^seat_disposition=//p' | tail -1)
  if [ -n "$RESPONSE" ] && printf '%s\n' "$RESPONSE" > "$ROUTE_FILE"; then
    seat_rc=0
    seats reconcile-remote "$ID" --generation "$NEW_GEN" --response-file "$ROUTE_FILE" >&2 || seat_rc=$?
    [ "$seat_rc" -ne 0 ] || DISPOSITION=$(printf '%s\n' "$RESPONSE" | jq -r '.disposition // empty' 2>/dev/null || true)
  fi
  if [ "$rc" -eq 6 ]; then
    printf '%s\n' "$RELAUNCH_OUT" >&2
    exit 6
  fi
  if [ "$DISPOSITION" != started ]; then
    printf '%s\n' "$RELAUNCH_OUT" >&2
    case "$DISPOSITION" in
      prelaunch) die "the host refused the relaunch of $ID before touching its agent; its fleet seat candidate was released" ;;
      cancelled) die "the relaunch of $ID stopped its agent but launched no replacement; its route is preserved for recovery" ;;
      *) die "the relaunch outcome of $ID is unknown; its fleet seat candidate $NEW_GEN stays counted for reconciliation" ;;
    esac
  fi
elif [ "$rc" -ne 0 ]; then
  printf '%s\n' "$RELAUNCH_OUT" >&2
  exit "$rc"
fi
printf '%s\n' "$RELAUNCH_OUT"

# The confirmed identity comes from the route block the host prints after a
# successful relaunch, never from the human-readable "relaunched ..." summary
# line: a relaunch onto "default" prints that literal word there, while the
# endpoint's own record - and this parent's, to match it - store an empty
# field for "no explicit pin".
[ "$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^schema=//p' | tail -1)" \
  = fm-remote-secondmate-control.v1 ] \
  || die "the host relaunched $ID but reported no route confirmation to record"
NEW_HARNESS=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^harness=//p' | tail -1)
NEW_MODEL=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^model=//p' | tail -1)
NEW_EFFORT=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^effort=//p' | tail -1)
NEW_REMOTE_GEN=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^spawn_gen=//p' | tail -1)
[ -n "$NEW_HARNESS" ] || die "the host's route confirmation carried no harness to record"

META_TMP=$(mktemp "$STATE/.fm-remote-relaunch-meta.XXXXXX") || {
  die "cannot stage the updated record"
}
{
  printf 'harness=%s\n' "$NEW_HARNESS"
  printf 'model=%s\n' "$NEW_MODEL"
  printf 'effort=%s\n' "$NEW_EFFORT"
  if [ "$SEAT_TRACKED" -eq 1 ]; then
    printf 'fleet_seat_generation=%s\n' "$NEW_GEN"
  fi
  [ -z "$NEW_REMOTE_GEN" ] || printf 'remote_spawn_gen=%s\n' "$NEW_REMOTE_GEN"
} >> "$META_TMP"
# Every other line is preserved in its original relative order after the
# refreshed harness/model/effort. A pr= line's own identity block (pr_head=
# and the x_* fields fm_pr_metadata_identity_parse allows after it) must stay
# LAST in the record: that parser rejects any other key following pr=, so
# writing harness/model/effort after it would break PR movement monitoring on
# a task that already had one armed.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    harness=*|model=*|effort=*) ;;
    remote_spawn_gen=*) ;;
    fleet_seat_generation=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" ;;
  esac
done < "$META"
chmod 0600 "$META_TMP"
mv -f -- "$META_TMP" "$META"
