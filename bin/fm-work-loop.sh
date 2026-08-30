#!/usr/bin/env bash
# Measure free worker slots and plan parallel backlog refill for section 7's work loop.
# Usage:
#   fm-work-loop.sh status
#   fm-work-loop.sh plan [--backlog <path>] [--list <path>]
#   fm-work-loop.sh supply [--backlog <path>] [--list <path>]
#
# `status` prints one machine-readable line:
#   FM_WORK_LOOP slots=<n> occupied=<n> free=<n> real=<n> min_real=<n> shortfall=<n> homes_scanned=<n> [source=list]
#
# `real` counts only provably working workers: active run-step, or a busy pane
# while the task has not declared terminal completion. Idle done-panes with a
# live endpoint and Herdr cards that lag behind done: do not count. `shortfall`
# is how many more real
# workers the loop should try to launch before the host slot ceiling.
#
# `plan` prints up to the plan limit dispatchable task ids, one per line, skipping
# ids that already occupy a live worker slot. Below min_real it tops up toward the
# floor; once the floor is met it fills every measured free slot. Prints nothing
# when the plan limit is 0.
#
# When gitignored `config/work-loop-list` (or `--list`) exists with at least one
# task id, `plan` walks that fixed list in file order and offers only ids that are
# still tasks-axi ready, so empty slots refill without manual resupply. Without a
# non-empty list, `plan` falls back to the tasks-axi ready backlog ordering.
#
# When the ready queue is empty, a free worker slot remains, and a fixed list is
# active, `plan` and `supply` immediately reopen the next done list id or add the
# next missing id that carries a tab-separated `id<TAB>repo<TAB>title<TAB>kind`
# row, so the loop does not idle waiting for manual backlog edits.
#
# Slot measurement is owned by bin/fm-capacity-lib.sh; this command never spawns.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  sed -n '2,28{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'error: work-loop: %s\n' "$1" >&2
  exit 1
}

CMD=
BACKLOG="$DATA/backlog.md"
LIST="$CONFIG/work-loop-list"
WORK_LOOP_READY_IDS_CACHE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    status | plan | supply)
      [ -z "$CMD" ] || die "one command only"
      CMD=$1
      shift
      ;;
    --backlog)
      [ "$#" -ge 2 ] || die "--backlog requires a path"
      BACKLOG=$2
      shift 2
      ;;
    --backlog=*)
      BACKLOG=${1#--backlog=}
      shift
      ;;
    --list)
      [ "$#" -ge 2 ] || die "--list requires a path"
      LIST=$2
      shift 2
      ;;
    --list=*)
      LIST=${1#--list=}
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
[ -n "$CMD" ] || {
  usage >&2
  exit 1
}

work_loop_measure() {
  fm_capacity_measure_local "$STATE" "$FM_HOME"
  fm_capacity_measure_host_real_workers "$STATE" "$FM_HOME"
  FM_CAPACITY_SHORTFALL=$(fm_capacity_work_loop_shortfall "$FM_CAPACITY_REAL")
  FM_CAPACITY_PLAN_LIMIT=$(fm_capacity_work_loop_plan_limit \
    "$FM_CAPACITY_FREE" "$FM_CAPACITY_REAL")
}

work_loop_list_active() {
  local list=$1 line trimmed
  [ -f "$list" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line%%#*}
    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ -n "$trimmed" ] && return 0
  done < "$list"
  return 1
}

work_loop_list_line_trimmed() {
  local line=$1
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}

work_loop_list_line_id() {
  local trimmed=${1:-}
  trimmed=$(work_loop_list_line_trimmed "$trimmed")
  trimmed=${trimmed%%[[:space:]$'\t']*}
  printf '%s' "$trimmed"
}

# Parse one list row. Id-only rows leave repo/title/kind empty.
work_loop_list_parse_spec() {
  local line=$1 trimmed id repo title kind
  WORK_LOOP_SPEC_ID=
  WORK_LOOP_SPEC_REPO=
  WORK_LOOP_SPEC_TITLE=
  WORK_LOOP_SPEC_KIND=
  trimmed=$(work_loop_list_line_trimmed "$line")
  [ -n "$trimmed" ] || return 1
  IFS=$'\t' read -r id repo title kind _rest <<< "$trimmed"
  if [ -z "$repo" ] || [ -z "$title" ] || [ -z "$kind" ]; then
    WORK_LOOP_SPEC_ID=$(work_loop_list_line_id "$trimmed")
    return 0
  fi
  WORK_LOOP_SPEC_ID=$id
  WORK_LOOP_SPEC_REPO=$repo
  WORK_LOOP_SPEC_TITLE=$title
  WORK_LOOP_SPEC_KIND=$kind
  return 0
}

# Emit task ids from a fixed list file: one per line, # comments, blanks skipped.
work_loop_fixed_list_ids() {
  local list=$1 line id
  [ -f "$list" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    id=$(work_loop_list_line_id "$line")
    [ -n "$id" ] || continue
    printf '%s\n' "$id"
  done < "$list"
}

work_loop_print_status() {
  local source=
  work_loop_measure
  work_loop_list_active "$LIST" && source=' source=list'
  printf 'FM_WORK_LOOP slots=%s occupied=%s free=%s real=%s min_real=%s shortfall=%s homes_scanned=%s%s\n' \
    "$FM_CAPACITY_SLOTS" "$FM_CAPACITY_OCCUPIED" "$FM_CAPACITY_FREE" \
    "$FM_CAPACITY_REAL" "$FM_WORK_LOOP_MIN_REAL" "$FM_CAPACITY_SHORTFALL" \
    "$FM_CAPACITY_HOMES_SCANNED" "$source"
}

# Print one task id per line from a tasks-axi ready listing.
work_loop_emit_ready_ids() {
  local ready=$1
  printf '%s\n' "$ready" | awk '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; next }
    rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, a, ",")
      if (a[1] != "") print a[1]
      next
    }
    { rows = 0 }
  '
}

work_loop_ready_ids() {
  local ready err
  [ -f "$BACKLOG" ] || return 0
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    die "tasks-axi backlog backend is required for plan; got $(fm_backlog_backend_value "$CONFIG")"
  fi
  if ! ready=$(tasks-axi ready --file "$BACKLOG" 2>&1); then
    die "tasks-axi ready failed: $ready"
  fi
  work_loop_emit_ready_ids "$ready"
}

work_loop_ready_ids_cached() {
  if [ -z "$WORK_LOOP_READY_IDS_CACHE" ]; then
    WORK_LOOP_READY_IDS_CACHE=$(work_loop_ready_ids)
  fi
  printf '%s\n' "$WORK_LOOP_READY_IDS_CACHE"
}

work_loop_id_is_ready() {
  local id=$1 rid
  while IFS= read -r rid; do
    [ "$rid" = "$id" ] && return 0
  done < <(work_loop_ready_ids_cached)
  return 1
}

work_loop_ready_queue_empty() {
  local head
  head=$(work_loop_ready_ids_cached | sed -n '/./{p;q;}')
  [ -z "$head" ]
}

work_loop_task_backlog_state() {
  local id=$1 state
  [ -f "$BACKLOG" ] || {
    printf '%s' 'missing'
    return 0
  }
  state=$(tasks-axi show "$id" --file "$BACKLOG" 2>/dev/null | awk '/^  state:/{print $2; exit}')
  if [ -z "$state" ]; then
    printf '%s' 'missing'
    return 0
  fi
  printf '%s' "$state"
}

work_loop_invalidate_ready_cache() {
  WORK_LOOP_READY_IDS_CACHE=
}

# Re-queue one known list item when the ready queue is empty.
work_loop_supply_one() {
  local line id state
  work_loop_list_active "$LIST" || return 1
  work_loop_ready_queue_empty || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    work_loop_list_parse_spec "$line" || continue
    id=$WORK_LOOP_SPEC_ID
    [ -n "$id" ] || continue
    fm_capacity_task_occupies_slot "$STATE" "$id" && continue
    state=$(work_loop_task_backlog_state "$id")
    case "$state" in
      missing)
        [ -n "$WORK_LOOP_SPEC_REPO" ] && [ -n "$WORK_LOOP_SPEC_TITLE" ] && [ -n "$WORK_LOOP_SPEC_KIND" ] || continue
        tasks-axi add "$id" "$WORK_LOOP_SPEC_TITLE" --repo "$WORK_LOOP_SPEC_REPO" \
          --kind "$WORK_LOOP_SPEC_KIND" --file "$BACKLOG" >/dev/null \
          || die "tasks-axi add failed for $id"
        work_loop_invalidate_ready_cache
        printf '%s\n' "$id"
        return 0
        ;;
      done)
        tasks-axi reopen "$id" --file "$BACKLOG" >/dev/null \
          || die "tasks-axi reopen failed for $id"
        work_loop_invalidate_ready_cache
        printf '%s\n' "$id"
        return 0
        ;;
    esac
  done < "$LIST"
  return 1
}

work_loop_ensure_ready_supply() {
  work_loop_list_active "$LIST" || return 0
  work_loop_ready_queue_empty || return 0
  work_loop_supply_one >/dev/null || true
}

work_loop_plan_candidate_ids() {
  local id
  if work_loop_list_active "$LIST"; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      work_loop_id_is_ready "$id" || continue
      printf '%s\n' "$id"
    done < <(work_loop_fixed_list_ids "$LIST")
    return 0
  fi
  work_loop_ready_ids
}

work_loop_print_plan() {
  local free=$1 id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_capacity_task_occupies_slot "$STATE" "$id" && continue
    printf '%s\n' "$id"
    n=$((n + 1))
    [ "$n" -lt "$free" ] || return 0
  done < <(work_loop_plan_candidate_ids)
}

case "$CMD" in
  status)
    work_loop_print_status
    ;;
  plan)
    work_loop_measure
    [ "$FM_CAPACITY_PLAN_LIMIT" -gt 0 ] || exit 0
    work_loop_ensure_ready_supply
    work_loop_print_plan "$FM_CAPACITY_PLAN_LIMIT"
    ;;
  supply)
    work_loop_measure
    [ "$FM_CAPACITY_PLAN_LIMIT" -gt 0 ] || exit 0
    id=$(work_loop_supply_one) || exit 0
    printf 'FM_WORK_LOOP supplied=%s\n' "$id"
    ;;
esac
