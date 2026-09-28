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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 4 ] || usage
ID=$1
HARNESS=$2
MODEL=$3
EFFORT=$4
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; use bin/fm-control.sh $ID relaunch instead"

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
mv -f -- "$META_TMP" "$META"
fm_lock_release "$META_LOCK"
