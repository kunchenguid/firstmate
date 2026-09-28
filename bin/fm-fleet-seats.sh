#!/usr/bin/env bash
# fm-fleet-seats.sh - fleet-wide active-worker seat pools for shared model routes.
#
# docs/configuration.md "Fleet seat pools" owns the operator contract: the
# config/fleet-seats schema, what a seat is, which homes share one pool, and
# what the refusals mean. This header owns the mechanics.
#
# A seat is one live ship or scout task record whose model belongs to a pool.
# It is an active agent slot, not an inference request: a worker holds its seat
# from reservation until its task record leaves its home (cleanup) or is
# republished on a model outside the pool (a relaunch onto another route),
# whether or not it is generating at that moment.
#
# THE AUTHORITY. Every home resolves the one fleet root with
# fm_firstmate_root_home (bin/fm-wake-lib.sh): the primary is its own root, and
# a local secondmate walks its .fm-secondmate-parent binding to the primary.
# The root's config/fleet-seats declares the pools and the root's state holds
# the reservations, so every home on this host counts against the same
# capacity under the same lock (<root>/state/.fleet-seats.lock). A home whose
# walk ends at a remote parent binding cannot reach that authority, so it
# refuses a pooled model from its own inherited config/fleet-seats rather than
# counting an unreachable pool as free.
#
# COUNTING. Under the root lock, the holders are the union, keyed by canonical
# state directory plus task id, of:
#   - every reservation in <root>/state/fleet-seats/<pool>/ that is still live:
#     its task record exists as a pooled ship or scout, or its reserving
#     process (recorded pid plus pid identity) is still running, which covers
#     a spawn that has reserved but not yet published its record. A
#     reservation that is neither is stale and is removed; a live task record
#     is never reclaimed, so recovery never preempts a running worker.
#   - every pooled ship or scout task record in the root home and in each local
#     secondmate home registered in the root's data/secondmates.md, so workers
#     launched before a pool existed are counted without any reservation.
# A task record that exists but cannot be read counts as held. A registered
# local home that exists but whose state cannot be listed refuses the
# reservation; a registered home directory that does not exist has no workers.
# Remote registry entries are never read.
#
# Usage:
#   fm-fleet-seats.sh reserve <task> --model <model> --holder-pid <pid>
#       Reserve a seat for this home's <task> when <model> belongs to a pool.
#       Prints nothing and exits 0 when no pool names the model (or no pool
#       is configured); prints "fleet-seats: reserved ..." on success. A task
#       that already holds a seat (a relaunch on the same route) keeps it even
#       when the pool is full. <holder-pid> is the long-lived reserving process
#       (bin/fm-spawn.sh passes its own pid) and must be alive.
#   fm-fleet-seats.sh status
#       Print each pool of the reachable authority as
#       "pool <name> capacity=<n> used=<n> free=<n>" followed by one
#       "  holder <state-dir> <task>" line per seat. Read-only: stale
#       reservations are omitted but not removed.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_DATA_OVERRIDE resolve the calling home as the other bin/ scripts do; they
# also select the root's own directories when the caller is the root.
# FM_FLEET_SEATS_LOCK_WAIT bounds the wait for the root lock in seconds
# (default 30).
#
# Exit status: 0 reserved, not pooled, or status printed; 2 usage error;
# 4 the pool is full; 5 the accounting authority is unreachable, unreadable,
# or misconfigured. Exit 4 and 5 both mean no seat: choose another route.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

EXIT_FULL=4
EXIT_UNAVAILABLE=5

usage() {
  echo "usage: fm-fleet-seats.sh reserve <task> --model <model> --holder-pid <pid> | status" >&2
  exit 2
}

unavailable() {
  echo "fleet-seats: no seat - $* (a pooled model is never launched without a counted seat; choose another route or repair the authority)" >&2
  exit "$EXIT_UNAVAILABLE"
}

canon_dir() { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; }

# validate_pools <file>: a readable, well-formed pool declaration, or fail.
validate_pools() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  jq -e '
    (.pools | type == "array" and length > 0)
    and all(.pools[];
      (.name | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and (.capacity | type == "number" and . >= 0 and . == floor)
      and (.models | type == "array" and length > 0
           and all(.[]; type == "string" and length > 0)))
    and ([.pools[].name] | length == (unique | length))
    and ([.pools[].models[]] | length == (unique | length))
  ' "$file" >/dev/null 2>&1
}

# pool_for_model <file> <model>: print "<name>\t<capacity>" for the pool naming it.
pool_for_model() {
  jq -r --arg m "$2" '.pools[] | select(.models | index($m)) | "\(.name)\t\(.capacity)"' "$1"
}

# pool_models <file> <pool>: one model per line.
pool_models() {
  jq -r --arg p "$2" '.pools[] | select(.name == $p) | .models[]' "$1"
}

# Resolve the authority for the calling home. Sets ROOT_REMOTE=1 when the walk
# ends at a remote parent binding, else ROOT_STATE / ROOT_CONFIG / ROOT_DATA.
resolve_authority() {
  local home_canon root
  ROOT_REMOTE=0
  ROOT_STATE='' ROOT_CONFIG='' ROOT_DATA=''
  home_canon=$(canon_dir "$FM_HOME") || return 1
  root=$(fm_firstmate_root_home "$home_canon") || return 1
  if [ -e "$root/.fm-secondmate-parent" ] || [ -L "$root/.fm-secondmate-parent" ]; then
    fm_secondmate_parent_record_parse "$root/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ] || return 1
    ROOT_REMOTE=1
    return 0
  fi
  if [ "$root" = "$home_canon" ]; then
    ROOT_STATE=$STATE ROOT_CONFIG=$CONFIG ROOT_DATA=$DATA
  else
    ROOT_STATE=$root/state ROOT_CONFIG=$root/config ROOT_DATA=$root/data
  fi
}

# meta_state <meta> <models-file>: "pooled", "other", "absent", or "unreadable".
meta_state() {
  local meta=$1 models=$2 kind model
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    echo absent
    return
  fi
  [ -f "$meta" ] && [ -r "$meta" ] || { echo unreadable; return; }
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  model=$(sed -n 's/^model=//p' "$meta" | tail -1)
  case "$kind" in secondmate) echo other; return ;; esac
  if [ -n "$model" ] && grep -Fxq -- "$model" "$models"; then
    echo pooled
  else
    echo other
  fi
}

# holder_alive <pid> <identity>: the reserving process is still the same process.
holder_alive() {
  local pid=$1 identity=$2 now
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] || return 0
  now=$(fm_pid_identity "$pid") || return 0
  [ "$now" = "$identity" ]
}

record_field() { sed -n "s/^$2=//p" "$1" | head -1; }

# collect_holders <pool> <models-file> <remove-stale 0|1>: print "<state>\t<task>" per seat.
collect_holders() {
  local pool=$1 models=$2 remove_stale=$3 dir f st task pid ident verdict line home home_state meta id
  dir="$ROOT_STATE/fleet-seats/$pool"
  if [ -d "$dir" ]; then
    for f in "$dir"/*.seat; do
      [ -f "$f" ] || continue
      st=$(record_field "$f" state)
      task=$(record_field "$f" task)
      pid=$(record_field "$f" pid)
      ident=$(record_field "$f" pid_identity)
      if [ -z "$st" ] || [ -z "$task" ]; then
        [ "$remove_stale" -eq 0 ] || rm -f "$f"
        continue
      fi
      verdict=$(meta_state "$st/$task.meta" "$models")
      case "$verdict" in
        pooled|unreadable) printf '%s\t%s\n' "$st" "$task" ;;
        *)
          if holder_alive "$pid" "$ident"; then
            printf '%s\t%s\n' "$st" "$task"
          elif [ "$remove_stale" -eq 1 ]; then
            rm -f "$f"
          fi
          ;;
      esac
    done
  fi
  {
    canon_dir "$ROOT_STATE" || return 1
    if [ -e "$ROOT_DATA/secondmates.md" ]; then
      [ -f "$ROOT_DATA/secondmates.md" ] && [ -r "$ROOT_DATA/secondmates.md" ] || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '- '*) ;; *) continue ;; esac
        secondmate_registry_parse_line "$line" || continue
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
        home=$SECONDMATE_REGISTRY_HOME
        [ -d "$home" ] || continue
        [ -d "$home/state" ] || continue
        canon_dir "$home/state" || return 1
      done < "$ROOT_DATA/secondmates.md"
    fi
  } > "$SCAN_HOMES" || return 1
  while IFS= read -r home_state; do
    [ -r "$home_state" ] && [ -x "$home_state" ] || return 1
    for meta in "$home_state"/*.meta; do
      [ -e "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
      verdict=$(meta_state "$meta" "$models")
      case "$verdict" in pooled|unreadable) printf '%s\t%s\n' "$home_state" "$id" ;; esac
    done
  done < "$SCAN_HOMES"
}

CMD=${1:-}
shift 2>/dev/null || true
TASK='' MODEL='' HOLDER=''
case "$CMD" in
  reserve)
    TASK=${1:-}
    shift 2>/dev/null || true
    case "$TASK" in ''|.*|*[!A-Za-z0-9._-]*) usage ;; esac
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) MODEL=${2:-}; shift 2 || usage ;;
        --holder-pid) HOLDER=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$HOLDER" ] || usage
    ;;
  status) [ "$#" -eq 0 ] || usage ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || unavailable "jq is not installed"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-seats.XXXXXX") || unavailable "cannot create a scratch directory"
SCAN_HOMES=$TMPD/homes
LOCK_HELD=
cleanup() {
  [ -z "$LOCK_HELD" ] || fm_lock_release "$LOCK_HELD" || true
  rm -rf "$TMPD"
}
trap cleanup EXIT

if ! resolve_authority; then
  # The binding is unusable; only this home's own copy can say whether the
  # model is pooled at all.
  if [ "$CMD" = reserve ] && [ -e "$CONFIG/fleet-seats" ]; then
    validate_pools "$CONFIG/fleet-seats" || unavailable "config/fleet-seats is malformed in $CONFIG"
    [ -z "$(pool_for_model "$CONFIG/fleet-seats" "$MODEL")" ] && exit 0
  elif [ "$CMD" = reserve ]; then
    exit 0
  fi
  unavailable "this home's fleet root cannot be resolved from its secondmate parent binding"
fi

if [ "$ROOT_REMOTE" -eq 1 ]; then
  if [ "$CMD" = status ]; then
    unavailable "this home's fleet root is on another host"
  fi
  [ -e "$CONFIG/fleet-seats" ] || exit 0
  validate_pools "$CONFIG/fleet-seats" || unavailable "config/fleet-seats is malformed in $CONFIG"
  POOL_LINE=$(pool_for_model "$CONFIG/fleet-seats" "$MODEL")
  [ -n "$POOL_LINE" ] || exit 0
  unavailable "model $MODEL is in pool ${POOL_LINE%%$'\t'*}, whose accounting lives in the fleet root on another host"
fi

POOLS=$ROOT_CONFIG/fleet-seats
if [ ! -e "$POOLS" ] && [ ! -L "$POOLS" ]; then
  [ "$CMD" = status ] && echo "fleet-seats: no pools configured"
  exit 0
fi
validate_pools "$POOLS" || unavailable "$POOLS is malformed (see docs/configuration.md \"Fleet seat pools\")"

if [ "$CMD" = status ]; then
  jq -r '.pools[] | "\(.name)\t\(.capacity)"' "$POOLS" > "$TMPD/pools"
  while IFS=$'\t' read -r name cap; do
    pool_models "$POOLS" "$name" > "$TMPD/models"
    collect_holders "$name" "$TMPD/models" 0 > "$TMPD/holders" || unavailable "a fleet home's task records cannot be read"
    sort -u "$TMPD/holders" -o "$TMPD/holders"
    used=$(wc -l < "$TMPD/holders" | tr -d ' ')
    free=$((cap - used))
    [ "$free" -ge 0 ] || free=0
    echo "pool $name capacity=$cap used=$used free=$free"
    while IFS=$'\t' read -r st task; do
      echo "  holder $st $task"
    done < "$TMPD/holders"
  done < "$TMPD/pools"
  exit 0
fi

POOL_LINE=$(pool_for_model "$POOLS" "$MODEL")
[ -n "$POOL_LINE" ] || exit 0
POOL=${POOL_LINE%%$'\t'*}
CAP=${POOL_LINE#*$'\t'}
fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
CALLER_STATE=$(canon_dir "$STATE") || unavailable "this home's state directory $STATE is missing"
pool_models "$POOLS" "$POOL" > "$TMPD/models"

[ -d "$ROOT_STATE" ] || unavailable "the fleet root state directory $ROOT_STATE is missing"
mkdir -p "$ROOT_STATE/fleet-seats/$POOL" 2>/dev/null || unavailable "cannot create $ROOT_STATE/fleet-seats/$POOL"
LOCK=$ROOT_STATE/.fleet-seats.lock
fm_lock_acquire_wait_max "$LOCK" "${FM_FLEET_SEATS_LOCK_WAIT:-30}" \
  || unavailable "the fleet seat lock $LOCK stayed held by pid ${FM_LOCK_HELD_PID:-unknown}"
LOCK_HELD=$LOCK

collect_holders "$POOL" "$TMPD/models" 1 > "$TMPD/holders" || unavailable "a fleet home's task records cannot be read"
sort -u "$TMPD/holders" -o "$TMPD/holders"
USED=$(wc -l < "$TMPD/holders" | tr -d ' ')
KEY=$(printf '%s\t%s' "$CALLER_STATE" "$TASK")
if ! grep -Fxq -- "$KEY" "$TMPD/holders" && [ "$USED" -ge "$CAP" ]; then
  echo "fleet-seats: pool $POOL is full ($USED of $CAP seats held); task $TASK gets no seat for model $MODEL - choose an overflow route or wait for a holder to finish" >&2
  while IFS=$'\t' read -r st task; do
    echo "  holder $st $task" >&2
  done < "$TMPD/holders"
  exit "$EXIT_FULL"
fi

SEAT_NAME=$(printf '%s' "$KEY" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
SEAT=$ROOT_STATE/fleet-seats/$POOL/$SEAT_NAME.seat
IDENTITY=$(fm_pid_identity "$HOLDER" 2>/dev/null || true)
{
  echo "state=$CALLER_STATE"
  echo "task=$TASK"
  echo "model=$MODEL"
  echo "pid=$HOLDER"
  printf 'pid_identity=%s\n' "$IDENTITY"
  echo "reserved_at=$(date +%s)"
} > "$SEAT.tmp.$$" || unavailable "cannot write $SEAT"
mv -f "$SEAT.tmp.$$" "$SEAT" || unavailable "cannot publish $SEAT"
if grep -Fxq -- "$KEY" "$TMPD/holders"; then
  echo "fleet-seats: reserved pool=$POOL task=$TASK (already held) used=$USED capacity=$CAP"
else
  echo "fleet-seats: reserved pool=$POOL task=$TASK used=$((USED + 1)) capacity=$CAP"
fi
