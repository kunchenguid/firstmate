#!/usr/bin/env bash
# Fresh compute-capacity probe, worker-slot budget, and host routing.
# Usage:
#   fm-capacity.sh probe
#   fm-capacity.sh slots
#   fm-capacity.sh route
#   fm-capacity.sh spawn-gate [--task-id <id>]
#
# `probe` prints one fresh local measurement plus configured preferred/fallback
# reachability, suitability, the CPU-headroom reading each probe returned,
# derived slots, the live occupied count across the local firstmate homes on
# this host, free count, and the host-bound routing verdict. `slots` prints only the local slot budget, including homes_scanned so
# the host-scoped occupancy is auditable. `route` prints only the host-bound
# routing verdict. `spawn-gate` exits 0 when a new independent ship/scout worker
# may start, and 1 when it must wait; it never interrupts a running worker.
# --task-id refuses when that id already occupies a slot, and probe, slots, and
# route reject the flag rather than ignoring it.
#
# Optional session pins: --preferred <ssh> --fallback <ssh>
# [--preferred-kind gpu|cpu] [--fallback-kind gpu|cpu]. Each pin overrides only
# its own field of config/compute-hosts.json for this invocation, so pinning the
# preferred host keeps the configured fallback, and an unknown kind is rejected
# rather than coerced. The script header of bin/fm-capacity-lib.sh owns the
# formula. This command does not choose a harness or model.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'error: capacity: %s\n' "$1" >&2
  exit 1
}

CMD=
TASK_ID=
TASK_ID_GIVEN=
while [ "$#" -gt 0 ]; do
  case "$1" in
    probe | slots | route | spawn-gate)
      [ -z "$CMD" ] || die "one command only"
      CMD=$1
      shift
      ;;
    --task-id)
      [ "$#" -ge 2 ] || die "--task-id requires a value"
      TASK_ID=$2
      TASK_ID_GIVEN=1
      shift 2
      ;;
    --task-id=*)
      TASK_ID=${1#--task-id=}
      TASK_ID_GIVEN=1
      shift
      ;;
    --preferred)
      [ "$#" -ge 2 ] || die "--preferred requires a value"
      FM_CAPACITY_PREFERRED_SSH=$2
      shift 2
      ;;
    --preferred=*)
      FM_CAPACITY_PREFERRED_SSH=${1#--preferred=}
      shift
      ;;
    --fallback)
      [ "$#" -ge 2 ] || die "--fallback requires a value"
      FM_CAPACITY_FALLBACK_SSH=$2
      shift 2
      ;;
    --fallback=*)
      FM_CAPACITY_FALLBACK_SSH=${1#--fallback=}
      shift
      ;;
    --preferred-kind)
      [ "$#" -ge 2 ] || die "--preferred-kind requires a value"
      FM_CAPACITY_PREFERRED_KIND=$2
      shift 2
      ;;
    --preferred-kind=*)
      FM_CAPACITY_PREFERRED_KIND=${1#--preferred-kind=}
      shift
      ;;
    --fallback-kind)
      [ "$#" -ge 2 ] || die "--fallback-kind requires a value"
      FM_CAPACITY_FALLBACK_KIND=$2
      shift 2
      ;;
    --fallback-kind=*)
      FM_CAPACITY_FALLBACK_KIND=${1#--fallback-kind=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done
[ -n "$CMD" ] || { usage >&2; exit 2; }
if [ "$TASK_ID_GIVEN" = 1 ] && [ "$CMD" != spawn-gate ]; then
  die "--task-id applies only to spawn-gate"
fi

load_hosts_or_die() {
  fm_capacity_load_hosts "$CONFIG" || die "${FM_CAPACITY_CONFIG_ERROR:-invalid compute-hosts config}"
}

print_slots() {
  fm_capacity_measure_local "$STATE" "$FM_HOME"
  printf 'slots=%s\n' "$FM_CAPACITY_SLOTS"
  printf 'occupied=%s\n' "$FM_CAPACITY_OCCUPIED"
  printf 'free=%s\n' "$FM_CAPACITY_FREE"
  printf 'homes_scanned=%s\n' "$FM_CAPACITY_HOMES_SCANNED"
  printf 'nproc=%s\n' "$FM_CAPACITY_LOCAL_NPROC"
  printf 'mem_avail_mb=%s\n' "${FM_CAPACITY_LOCAL_MEM_MB:-unknown}"
  printf 'load1=%s\n' "${FM_CAPACITY_LOCAL_LOAD1:-unknown}"
}

print_route() {
  load_hosts_or_die
  fm_capacity_route_hosts
  printf 'route=%s\n' "$FM_CAPACITY_ROUTE"
  printf 'route_host=%s\n' "$FM_CAPACITY_ROUTE_HOST"
  printf 'route_reason=%s\n' "$FM_CAPACITY_ROUTE_REASON"
  printf 'preferred_ssh=%s\n' "${FM_CAPACITY_PREF_SSH:-}"
  printf 'preferred_reachable=%s\n' "$FM_CAPACITY_PREF_REACHABLE"
  printf 'preferred_suitable=%s\n' "$FM_CAPACITY_PREF_SUITABLE"
  printf 'preferred_cpu=%s\n' "$FM_CAPACITY_PREF_LOAD"
  printf 'fallback_ssh=%s\n' "${FM_CAPACITY_FALL_SSH:-}"
  printf 'fallback_reachable=%s\n' "$FM_CAPACITY_FALL_REACHABLE"
  printf 'fallback_suitable=%s\n' "$FM_CAPACITY_FALL_SUITABLE"
  printf 'fallback_cpu=%s\n' "$FM_CAPACITY_FALL_LOAD"
}

print_probe() {
  printf 'generated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  print_slots
  print_route
}

case "$CMD" in
  probe) print_probe ;;
  slots) print_slots ;;
  route) print_route ;;
  spawn-gate)
    fm_capacity_allow_new_worker "$STATE" "${TASK_ID:-}" ship 0 "$FM_HOME"
    ;;
esac
