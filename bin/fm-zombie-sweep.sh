#!/usr/bin/env bash
# Sweep stale locks, zombie Herdr panes, and records with no live agent.
#
# Usage:
#   fm-zombie-sweep.sh           Dry-run (default)
#   fm-zombie-sweep.sh --apply   Perform lock GC, pane close, status repair,
#                                and safe teardowns
#   fm-zombie-sweep.sh -h
#
# Lock GC removes state/*.lock.owner.* whose pid is dead and whose lock
# symlink points at that owner. A live owner and a lock without a pid are
# left untouched. Unclassifiable lock debris is reported and not removed.
# Herdr panes whose task is terminal or whose endpoint is gone close only
# through the backend close path. A meta with no status file gets one
# paused: line. Records with no live agent are listed by class; safe classes
# retire through ordinary teardown (no --force); dead worktrees with
# unlanded work print one question line each.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
APPLY=0
TEARDOWN_BIN="${FM_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --apply) APPLY=1 ;;
  '') ;;
  *) echo "error: usage: fm-zombie-sweep.sh [--apply]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "error: usage: fm-zombie-sweep.sh [--apply]" >&2; exit 2; }

LOCKS=0
PANES=0
PAUSED=0
RETIRED=0
QUESTIONS=0
NO_LIVE=0

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

report() { printf '%s\n' "$1"; }

IN_FLIGHT_IDS=' '
spawn_in_flight() {  # <id>
  local id=$1 lock
  lock="$STATE/.spawn-$id.lock"
  if fm_lock_try_acquire "$lock"; then
    fm_lock_release "$lock" || return 1
    return 1
  fi
  case "$IN_FLIGHT_IDS" in
    *" $id "*) ;;
    *)
      IN_FLIGHT_IDS="${IN_FLIGHT_IDS}${id} "
      report "in-flight: $id (spawn running)"
      ;;
  esac
  return 0
}

# --- (a) lock garbage collection -------------------------------------------

gc_locks() {
  local owner pid lock actual
  [ -d "$STATE" ] || return 0
  for owner in "$STATE"/*.lock.owner.* "$STATE"/.*.lock.owner.*; do
    [ -d "$owner" ] && [ ! -L "$owner" ] || continue
    pid=$(cat "$owner/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        report "unclassified: lock owner $(basename "$owner") has no pid; left untouched"
        continue
        ;;
    esac
    if fm_pid_alive "$pid"; then
      continue
    fi
    lock=""
    for cand in "$STATE"/* "$STATE"/.*; do
      [ -L "$cand" ] || continue
      actual=$(readlink "$cand" 2>/dev/null || true)
      [ "$actual" = "$owner" ] || continue
      lock=$cand
      break
    done
    if [ -z "$lock" ]; then
      report "unclassified: lock owner $(basename "$owner") pid $pid is dead with no pointing symlink; left untouched"
      continue
    fi
    LOCKS=$((LOCKS + 1))
    report "lock-gc: $(basename "$lock") pid $pid dead"
    if [ "$APPLY" -eq 1 ]; then
      rm -f "$lock"
      fm_lock_discard_owner "$owner"
    fi
  done
}

# --- (c) missing status ----------------------------------------------------

repair_missing_status() {
  local meta id status
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_task_id_path_safe "$id" || continue
    spawn_in_flight "$id" && continue
    status="$STATE/$id.status"
    if [ -e "$status" ]; then
      continue
    fi
    PAUSED=$((PAUSED + 1))
    report "paused-repair: $id missing status"
    if [ "$APPLY" -eq 1 ]; then
      printf 'paused: missing status file; endpoint dead\n' > "$status"
    fi
  done
}

# --- live agent + retire classes ------------------------------------------

agent_gone() {  # <meta> <id>
  local meta=$1 id=$2 backend target state
  if [ -n "${FM_ZOMBIE_LIVE_IDS:-}" ]; then
    case " $FM_ZOMBIE_LIVE_IDS " in
      *" $id "*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  backend=$(meta_field "$meta" backend)
  [ "$backend" = herdr ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  target=$FM_BACKEND_VALIDATED_TARGET
  state=$(fm_backend_agent_state herdr "$target")
  case "$state" in dead|missing) return 0 ;; *) return 1 ;; esac
}

classify_idle() {  # <id> <meta> -> merged|report|worktree-gone|unlanded|skip
  local id=$1 meta=$2 kind wt last verb pr report
  kind=$(meta_field "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" != secondmate ] || { printf 'skip\n'; return 0; }
  wt=$(meta_field "$meta" worktree)
  last=$(last_status_line "$STATE/$id.status")
  verb=$(status_line_verb "$last")
  pr=$(meta_field "$meta" pr)
  if [ "$kind" = scout ]; then
    report="$DATA/$id/report.md"
    if [ -f "$report" ] && [ ! -L "$report" ]; then
      printf 'report\n'
      return 0
    fi
  fi
  if [ "$verb" = "done" ] && [ -n "$pr" ]; then
    printf 'merged\n'
    return 0
  fi
  if [ -n "$wt" ] && [ ! -e "$wt" ]; then
    printf 'worktree-gone\n'
    return 0
  fi
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if git -C "$wt" status --porcelain 2>/dev/null | grep -q .; then
      printf 'unlanded\n'
      return 0
    fi
  fi
  printf 'worktree-gone\n'
}

close_herdr_if_needed() {  # <id> <meta>
  local id=$1 meta=$2 backend target
  backend=$(meta_field "$meta" backend)
  [ "$backend" = herdr ] || return 0
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 0
  target=$FM_BACKEND_VALIDATED_TARGET
  PANES=$((PANES + 1))
  report "pane-close: $id"
  [ "$APPLY" -eq 1 ] || return 0
  if [ -n "${FM_ZOMBIE_KILL_BIN:-}" ]; then
    "$FM_ZOMBIE_KILL_BIN" "$id" || true
  elif fm_backend_source herdr; then
    fm_backend_herdr_kill "$target"
  fi
}

sweep_records() {
  local meta id class
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_task_id_path_safe "$id" || {
      report "unclassified: $id (unsafe id)"
      continue
    }
    spawn_in_flight "$id" && continue
    agent_gone "$meta" "$id" || continue
    NO_LIVE=$((NO_LIVE + 1))
    close_herdr_if_needed "$id" "$meta"
    class=$(classify_idle "$id" "$meta")
    case "$class" in
      merged|report|worktree-gone)
        report "retire-candidate: $id class=$class"
        if [ "$APPLY" -eq 1 ]; then
          if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
              FM_TEARDOWN_GUARD_DONE=1 "$TEARDOWN_BIN" "$id" >/dev/null 2>&1; then
            RETIRED=$((RETIRED + 1))
            report "retired: $id"
          else
            QUESTIONS=$((QUESTIONS + 1))
            report "needs-decision: zombie $id teardown refused for class $class"
          fi
        else
          RETIRED=$((RETIRED + 1))
        fi
        ;;
      unlanded)
        QUESTIONS=$((QUESTIONS + 1))
        report "needs-decision: zombie $id dead worktree with unlanded work"
        ;;
      skip) ;;
      *)
        report "unclassified: $id class=$class"
        ;;
    esac
  done
}

[ -d "$STATE" ] || {
  printf 'zombie-sweep locks=0 panes=0 paused=0 retired=0 questions=0 no-live-agent=0\n'
  exit 0
}

gc_locks
repair_missing_status
sweep_records
printf 'zombie-sweep locks=%s panes=%s paused=%s retired=%s questions=%s no-live-agent=%s\n' \
  "$LOCKS" "$PANES" "$PAUSED" "$RETIRED" "$QUESTIONS" "$NO_LIVE"
exit 0
