#!/usr/bin/env bash
# Relaunch a REMOTE secondmate onto a new harness, model, or effort, then
# republish this parent's own route record to match what the host confirmed.
#
# Usage: fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->
#
# bin/fm-remote-secondmate-control.sh's relaunch verb runs entirely on the
# secondmate's own host and can only rewrite that host's own endpoint record;
# this parent's route record (state/<id>.meta here, marked remote_host=... to
# a different machine) is a separate file that verb has no access to. Running
# the relaunch alone therefore leaves this file naming the runtime the mate
# used to run, not the one it runs now.
#
# This wrapper is the missing other half. It runs the host-local relaunch
# through bin/fm-on.sh exactly as secondmate-provisioning documents, then reads
# the confirmed harness, model, and effort back out of the endpoint's own
# route report - the same read-back-from-the-endpoint shape bin/fm-spawn.sh
# already uses when it first records a remote route - and republishes this
# home's own metadata to match. A failed or refused relaunch leaves this
# parent's record untouched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-sol-cap-lib.sh
. "$SCRIPT_DIR/fm-sol-cap-lib.sh"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 4 ] || usage
ID=$1
HARNESS=$2
MODEL=$3
EFFORT=$4
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

SPAWN_LOCK="$STATE/.spawn-$ID.lock"
fm_lock_try_acquire "$SPAWN_LOCK" || die "another spawn or runtime switch owns $ID"
CAP_LOCK=
trap '[ -z "$CAP_LOCK" ] || fm_lock_release "$CAP_LOCK" || true; fm_lock_release "$SPAWN_LOCK" || true' EXIT

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; use bin/fm-control.sh $ID relaunch instead"

fm_sol_cap_reconcile_remote "$ID" "$STATE" "$SCRIPT_DIR" || die "cannot reconcile $ID's Sol claim"
fm_sol_cap_refuse_and_claim "$ID" secondmate "$HARNESS" "$MODEL" "$CONFIG" "$STATE" reuse || die "$FM_SOL_CAP_REFUSAL"
if [ "$FM_SOL_CLAIM_CREATED" = "$ID" ]; then
  fm_sol_cap_promote "$ID" 0 "$STATE" || die "cannot preserve $ID's delivery reservation"
fi

RELAUNCH_OUT=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh \
  relaunch "$ID" "$HARNESS" "$MODEL" "$EFFORT" </dev/null 2>&1) || {
  rc=$?
  printf '%s\n' "$RELAUNCH_OUT" >&2
  exit "$rc"
}
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
[ -n "$NEW_HARNESS" ] || die "the host's route confirmation carried no harness to record"

META_LOCK=$(fm_meta_lock_path "$META") || die "metadata lock path is invalid for $ID"
fm_lock_acquire_wait "$META_LOCK"
META_TMP=$(mktemp "$STATE/.fm-remote-relaunch-meta.XXXXXX") || {
  [ -z "$CAP_LOCK" ] || fm_lock_release "$CAP_LOCK"
CAP_LOCK=
fm_lock_release "$META_LOCK"
  die "cannot stage the updated record"
}
{
  printf 'harness=%s\n' "$NEW_HARNESS"
  printf 'model=%s\n' "$NEW_MODEL"
  printf 'effort=%s\n' "$NEW_EFFORT"
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
    *) printf '%s\n' "$line" >> "$META_TMP" ;;
  esac
done < "$META"
chmod 0600 "$META_TMP"
# The ceiling's scope comes from the captain's own declaration: a
# replacement model the declaration does not cover, on a task that already
# owns capped occupancy, publishes its model and releases the old claim
# under one admission boundary.
CAP_CAPPED=1
CAP_SCOPE_RC=0
fm_sol_cap_state_model_capped "$STATE" "$NEW_MODEL" || CAP_SCOPE_RC=$?
case "$CAP_SCOPE_RC" in
  0) CAP_CAPPED=0 ;;
  2) die "the Sol ceiling declaration could not be read, so $ID's replacement model could not be published" ;;
esac
if fm_sol_cap_has_owned_occupancy "$ID" "$STATE"; then
  CAP_ROOT=$(fm_firstmate_root_home "$(fm_sol_cap_home "$STATE")") || die "cannot resolve the Sol admission home"
  CAP_PATH=$CAP_ROOT/state/$FM_SOL_LOCK_NAME
  fm_sol_cap_lock_acquire "$CAP_PATH" "the model publication of $ID" || die "$FM_SOL_CAP_REFUSAL"
  CAP_LOCK=$CAP_PATH
fi
mv -f -- "$META_TMP" "$META"
if [ "$CAP_CAPPED" = 1 ]; then
  if [ -n "$CAP_LOCK" ]; then
    fm_sol_cap_registry_promote "$ID" remove "$STATE" || die "cannot release $ID's stopped Sol incarnation"
  else
    fm_sol_cap_promote "$ID" remove "$STATE" || die "cannot release $ID's stopped Sol incarnation"
  fi
else
  # The replacement still runs a covered model, so the row must name the
  # model that holds the slot: a row left naming the model the session ran
  # before is skipped by the count and by adoption, and the running session
  # goes uncounted. The claim keeps the row's own pid and start epoch.
  CAP_REGISTRY="$STATE/$FM_SOL_REGISTRY_NAME"
  CAP_START=$(awk -F'\t' -v id="$ID" '$1 == id {print $3; exit}' "$CAP_REGISTRY" 2>/dev/null || true)
  CAP_PID=$(awk -F'\t' -v id="$ID" '$1 == id {print $4; exit}' "$CAP_REGISTRY" 2>/dev/null || true)
  if [ -n "$CAP_START" ]; then
    fm_sol_cap_registry_claim "$CAP_REGISTRY" "$ID" "$NEW_MODEL" "$CAP_START" "$CAP_PID" ||
      die "cannot record $ID's replacement model in its registry row"
  fi
fi

[ -z "$CAP_LOCK" ] || fm_lock_release "$CAP_LOCK"
CAP_LOCK=
fm_lock_release "$META_LOCK"
