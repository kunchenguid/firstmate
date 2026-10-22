#!/usr/bin/env bash
# Narrow Dashboard owner for an explicit task archive request.
#
# Usage: fm-dashboard-archive.sh <task-id> --expect-state <queued|in_flight>
#   --expect-updated-at <timestamp> --expect-spawn-gen <generation|none>
#
# The canonical task record owner performs the archive transition first.
# Existing task retirement then owns endpoint, volatile record and Treehouse
# cleanup. A cleanup refusal is reported separately and never rolls back or
# mislabels the explicit business archive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

id=${1-}
[ -n "$id" ] || exit 2
shift
expected_state=
expected_updated_at=
expected_generation=
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || exit 2
  case "$1" in
    --expect-state) expected_state=$2 ;;
    --expect-updated-at) expected_updated_at=$2 ;;
    --expect-spawn-gen) expected_generation=$2 ;;
    *) exit 2 ;;
  esac
  shift 2
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_valid_id "$id" || exit 2
case "$expected_state" in queued|in_flight) ;; *) exit 2 ;; esac
[ -n "$expected_updated_at" ] || exit 2
case "$expected_generation" in
  none) ;;
  ''|.*|*[!A-Za-z0-9._-]*) exit 2 ;;
esac
[ "$(fm_lease_actor)" = main ] || {
  printf '%s\n' 'REFUSED: Dashboard archive belongs to MAIN' >&2
  exit 6
}

lock="$STATE/.dashboard-archive-$id.lock"
fm_lock_try_acquire "$lock" || {
  printf 'REFUSED: another archive or lifecycle action is running for task %s\n' "$id" >&2
  exit 75
}
trap 'fm_lock_release "$lock"; fm_lease_guard_release' EXIT
fm_lease_guard "$id" 'Dashboard task archive' || exit $?

record=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" progress "$id") || exit $?
current_state=$(printf '%s' "$record" | jq -r '.state // empty') || exit 1
meta="$STATE/$id.meta"
current_generation=none
if [ -e "$meta" ] || [ -L "$meta" ]; then
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    printf 'REFUSED: task %s has unsafe execution metadata\n' "$id" >&2
    exit 75
  }
  current_generation=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
  [ -n "$current_generation" ] || {
    printf 'REFUSED: task %s has no exact execution generation\n' "$id" >&2
    exit 75
  }
fi
if [ "$current_state" != archived ] || [ "$current_generation" != none ]; then
  [ "$current_generation" = "$expected_generation" ] || {
    printf 'REFUSED: task %s execution generation changed since the dashboard snapshot\n' "$id" >&2
    exit 75
  }
fi

case "$current_state" in
  queued|in_flight)
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" archive "$id" \
      --expect-state "$expected_state" --expect-updated-at "$expected_updated_at" || exit $?
    ;;
  archived) ;;
  *)
    printf 'REFUSED: task %s is no longer Waiting or Processing\n' "$id" >&2
    exit 75
    ;;
esac

if [ "$current_generation" = none ]; then
  jq -cn --arg id "$id" \
    '{taskId:$id,archive:"archived",cleanup:"completed",message:"Archived; no task resources were recorded."}'
  exit 0
fi

retire_out=$(mktemp)
retire_err=$(mktemp)
trap 'rm -f "$retire_out" "$retire_err"; fm_lock_release "$lock"; fm_lease_guard_release' EXIT
retire_rc=0
executor=$(sed -n 's/^executor=//p' "$meta" | tail -1)
case "${executor:-local-agent}" in
  local-agent)
    retire_args=(--expect-spawn-gen "$current_generation")
    ;;
  cloud-worker|remote-agent)
    retire_args=()
    ;;
  *)
    printf 'REFUSED: task %s has an unsupported executor\n' "$id" >&2
    exit 75
    ;;
esac
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-task-retire.sh" "$id" "${retire_args[@]+"${retire_args[@]}"}" \
  >"$retire_out" 2>"$retire_err" || retire_rc=$?
if [ "$retire_rc" -ne 0 ]; then
  detail=$(tail -n 1 "$retire_err")
  jq -cn --arg id "$id" --arg detail "$detail" \
    '{taskId:$id,archive:"archived",cleanup:"pending",message:("Archived; resource cleanup remains pending: " + $detail)}'
  exit 0
fi

detail=$(grep -E '^teardown .* complete \(exact pane absent; copy=' "$retire_out" | tail -n 1 || true)
[ -n "$detail" ] || detail=$(tail -n 1 "$retire_out")
case "$(cat "$retire_out")" in
  *copy=retained-*) cleanup=retained ;;
  *) cleanup=completed ;;
esac
jq -cn --arg id "$id" --arg cleanup "$cleanup" --arg detail "$detail" \
  '{taskId:$id,archive:"archived",cleanup:$cleanup,message:(if $cleanup=="retained" then "Archived; the task endpoint was cleaned up and the copy was retained to preserve unlanded or unverified work." else "Archived; task resources and the Treehouse workspace were cleaned up." end),detail:$detail}'
