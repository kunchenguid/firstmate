#!/usr/bin/env bash
# fm-slot-audit.sh - compare each live task record that names a Treehouse pool
# slot with the slot's own evidence, and say whether the record still describes
# a slot the task holds.
#
# Why: a crewmate's pool slot is held by processes, not by a durable lease
# (bin/fm-wake-lib.sh's slot-owner claim comment owns why). A machine restart
# kills the worker's `treehouse get` subshell and a Herdr restore puts the
# restored pane back in the project directory, so a parked worker silently
# stops protecting its slot; the next `treehouse get` on the pool takes it,
# bin/fm-spawn.sh writes the new task's claim, and the parked task's
# `worktree=` line is stale from then on (observed 2026-10-02 through
# 2026-10-06 on two slots). Nothing read that stale record against the slot
# until a later teardown refused, so this audit reads it on every heartbeat
# (bin/fm-watch.sh), at spawn time before a `treehouse get` (bin/fm-spawn.sh),
# and in the session-start digest (bin/fm-session-start.sh); bin/fm-crew-state.sh
# repeats its worker= fact in each crew's state line.
#
# Usage: fm-slot-audit.sh (<task-id> | --all) [--json] [--no-pool]
#
#   <task-id>  audit one record in this home (state/<task-id>.meta).
#   --all      audit every record in this home, then every record in each local
#              Firstmate home registered below the local root
#              (bin/fm-wake-lib.sh's fm_local_firstmate_state_dirs). Every
#              line keeps the exact format below; a record's home is carried
#              only in --json (empty for this home). When that walk cannot be proved, this home is audited alone and
#              the reason is printed on stderr.
#   --json     print a JSON array of objects (task, slot, claim, claimant,
#              worker, worker_cwd, pool, verdict, home) instead of lines;
#              home is the record's Firstmate home when it is not this one.
#              Requires jq.
#   --no-pool  skip the `treehouse status --json` read; pool= prints `skipped`
#              and the verdict is computed from the claim and worker only.
#              bin/fm-crew-state.sh uses this on every state read.
#
# One line per audited record, exactly:
#
#   slot-audit: <task-id> slot=<path> claim=<claim> worker=<worker> pool=<pool> verdict=<verdict>
#
#   claim    mine | other:<task-id> | absent | unsafe - the slot's owner claim
#            (<pool>/<slot>/.fm-slot-owner) read against this record's task id
#            by bin/fm-wake-lib.sh's fm_treehouse_slot_owner_state.
#   worker   in-slot | outside:<cwd> | no-endpoint - where the recorded
#            endpoint's foreground process currently is, read through the
#            backend's own current-path probe (tmux pane_current_path, Herdr
#            foreground_cwd, the Rex, Zellij, cmux, and paseo probes). An
#            endpoint that answers no path, or a record with no window, is
#            no-endpoint. in-slot means the path is the slot or under it.
#   pool     in-use | available | dirty | leased | <other treehouse word> |
#            unlisted | unknown | missing | skipped - treehouse's own status
#            word for the slot from `treehouse status --json` run in the
#            project. unlisted: the pool listing has no row for this path.
#            unknown: treehouse or jq is unavailable or the read failed.
#            missing: the recorded path no longer exists although its pool
#            state file does.
#   verdict  ok, or a comma-separated list of every hazard that applies:
#            slot-lost          the claim names another task, the slot path
#                               is gone (pool=missing), or the record carries
#                               the slot_stale= marker a teardown wrote when
#                               the slot's claimant proved this record stale
#                               (bin/fm-teardown.sh, slot ownership): the
#                               record is stale and the task needs a fresh slot
#                               (bin/fm-control.sh <id> relaunch --fresh-slot).
#                               With --no-pool a gone path still reads
#                               pool=missing and slot-lost.
#            slot-unprotected   the claim is absent, or treehouse lists the
#                               slot as available: the next `treehouse get`
#                               on the pool can hand it out while this record
#                               still names it.
#            worker-outside-slot the recorded endpoint is somewhere other
#                               than its slot, so its processes no longer
#                               keep the pool from reusing the slot.
#            slot-lost stands alone; the other two combine.
#
# Records skipped without a line: kind=secondmate, backend=orca, a record with
# remote_host= (its slot is on another machine), and any record whose worktree
# is not under a Treehouse pool state file.
#
# Read-only: nothing here takes a lock, writes a record, touches a slot, or
# signals a process. `treehouse status` is read once per project per run.
# Exit 0 after auditing (including when nothing was audited), 2 on a usage
# error, 1 when this home's state directory cannot be read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

TARGET_ID=
ALL=0
JSON=0
NO_POOL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) ALL=1 ;;
    --json) JSON=1 ;;
    --no-pool) NO_POOL=1 ;;
    --*)
      echo "fm-slot-audit: unknown option $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$TARGET_ID" ]; then
        echo "fm-slot-audit: one task id at most" >&2
        exit 2
      fi
      TARGET_ID=$1
      ;;
  esac
  shift
done
if [ "$ALL" = 1 ] && [ -n "$TARGET_ID" ]; then
  echo "fm-slot-audit: pass a task id or --all, not both" >&2
  exit 2
fi
if [ "$ALL" = 0 ] && [ -z "$TARGET_ID" ]; then
  usage >&2
  exit 2
fi
[ -d "$STATE" ] || {
  echo "fm-slot-audit: state directory $STATE is not readable" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ -n "$TARGET_ID" ] && ! fm_task_id_path_safe "$TARGET_ID"; then
  echo "fm-slot-audit: '$TARGET_ID' is not a valid task id" >&2
  exit 2
fi
if [ "$JSON" = 1 ] && ! command -v jq >/dev/null 2>&1; then
  echo "fm-slot-audit: --json needs jq" >&2
  exit 2
fi

canonical_dir() {  # <path> -> physical path, or failure when it is not a directory
  [ -n "$1" ] && [ -d "$1" ] || return 1
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# The endpoint's current working directory through the backend's own probe, or
# empty when the backend has no probe or the endpoint answers nothing.
audit_current_path() {  # <backend> <target> <label>
  local backend=$1 target=$2 label=$3
  [ -n "$target" ] || return 0
  fm_backend_source "$backend" 2>/dev/null || return 0
  case "$backend" in
    tmux) fm_backend_tmux_current_path "$target" 2>/dev/null ;;
    herdr) fm_backend_herdr_current_path "$target" 2>/dev/null ;;
    zellij) fm_backend_zellij_current_path "$target" "$label" 2>/dev/null ;;
    cmux) fm_backend_cmux_current_path "$target" "$label" 2>/dev/null ;;
    paseo) fm_backend_paseo_current_path "$target" "$label" 2>/dev/null ;;
    rex) fm_backend_rex_current_path "$target" "$label" 2>/dev/null ;;
    *) return 0 ;;
  esac
}

# `treehouse status --json` for one project, read once per project per run.
POOL_CACHE_PROJECT=
POOL_CACHE_JSON=
POOL_CACHE_OK=0
audit_pool_status() {  # <project> <canonical-slot> <recorded-worktree>
  local project=$1 slot=$2 recorded=$3 status
  if [ "$NO_POOL" = 1 ]; then
    printf 'skipped'
    return 0
  fi
  if [ "$POOL_CACHE_PROJECT" != "$project" ]; then
    POOL_CACHE_PROJECT=$project
    POOL_CACHE_JSON=
    POOL_CACHE_OK=0
    if command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
       && POOL_CACHE_JSON=$(CDPATH='' cd -- "$project" 2>/dev/null && treehouse status --json 2>/dev/null) \
       && printf '%s' "$POOL_CACHE_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
      POOL_CACHE_OK=1
    fi
  fi
  if [ "$POOL_CACHE_OK" != 1 ]; then
    printf 'unknown'
    return 0
  fi
  status=$(printf '%s' "$POOL_CACHE_JSON" | jq -r --arg slot "$slot" --arg recorded "$recorded" '
    [.[] | select((.path == $slot) or (.path == $recorded))]
    | if length == 0 then "unlisted"
      else (.[0].status // "unknown" | tostring) end' 2>/dev/null) || status=unknown
  status=$(printf '%s' "$status" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  [ -n "$status" ] || status=unknown
  printf '%s' "$status"
}

JSON_ROWS=
emit_record() {  # <id> <slot> <claim> <claimant> <worker> <worker-cwd> <pool> <verdict> <home-suffix>
  local id=$1 slot=$2 claim=$3 claimant=$4 worker=$5 worker_cwd=$6 pool=$7 verdict=$8 home=$9
  local claim_field=$claim worker_field=$worker line
  [ "$claim" != other ] || claim_field="other:$claimant"
  [ "$worker" != outside ] || worker_field="outside:$worker_cwd"
  line="slot-audit: $id slot=$slot claim=$claim_field worker=$worker_field pool=$pool verdict=$verdict"
  if [ "$JSON" = 1 ]; then
    JSON_ROWS="$JSON_ROWS$(jq -n -c --arg task "$id" --arg slot "$slot" --arg claim "$claim" \
      --arg claimant "$claimant" --arg worker "$worker" --arg worker_cwd "$worker_cwd" \
      --arg pool "$pool" --arg verdict "$verdict" --arg home "$home" \
      '{task: $task, slot: $slot, claim: $claim, claimant: $claimant, worker: $worker,
        worker_cwd: $worker_cwd, pool: $pool, verdict: $verdict, home: $home}')"$'\n'
  else
    printf '%s\n' "$line"
  fi
}

audit_record() {  # <meta-path> <home-suffix>
  local meta=$1 home=$2 id kind backend worktree project slot pool_dir claim claimant
  local target label cwd cwd_real worker worker_cwd pool verdict
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  id=$(basename "$meta" .meta)
  fm_task_id_path_safe "$id" || return 0
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" != orca ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  worktree=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  [ -n "$worktree" ] || return 0
  pool_dir=$(dirname "$(dirname "$worktree")")
  if slot=$(canonical_dir "$worktree"); then
    fm_treehouse_pool_slot "$project" "$worktree" || return 0
    pool=$(audit_pool_status "$project" "$slot" "$worktree")
  else
    [ -f "$pool_dir/treehouse-state.json" ] || return 0
    slot=$worktree
    pool=missing
  fi
  claimant=
  if [ "$pool" = missing ]; then
    claim=absent
  else
    fm_treehouse_slot_owner_state "$slot" "$id"
    claim=$FM_TREEHOUSE_SLOT_OWNER
    claimant=$FM_TREEHOUSE_SLOT_OWNER_ID
  fi
  target=$(fm_backend_target_of_meta "$meta")
  label="fm-$id"
  worker=no-endpoint
  worker_cwd=
  if [ -n "$target" ]; then
    cwd=$(audit_current_path "$backend" "$target" "$label" | head -n 1)
    if [ -n "$cwd" ]; then
      cwd_real=$(canonical_dir "$cwd") || cwd_real=$cwd
      case "$cwd_real" in
        "$slot"|"$slot"/*) worker=in-slot ;;
        *) worker=outside; worker_cwd=$cwd ;;
      esac
    fi
  fi
  if [ "$claim" = other ] || [ "$pool" = missing ] || fm_slot_stale_marker_names "$meta" "$slot"; then
    verdict="slot-lost"
  else
    verdict=
    if [ "$claim" = absent ] || [ "$pool" = available ]; then
      verdict="slot-unprotected"
    fi
    if [ "$worker" = outside ]; then
      verdict="${verdict:+$verdict,}worker-outside-slot"
    fi
    [ -n "$verdict" ] || verdict=ok
  fi
  emit_record "$id" "$slot" "$claim" "$claimant" "$worker" "$worker_cwd" "$pool" "$verdict" "$home"
}

audit_state_dir() {  # <state-dir> <home-suffix>
  local state_dir=$1 home=$2 meta
  for meta in "$state_dir"/*.meta; do
    audit_record "$meta" "$home"
  done
}

if [ -n "$TARGET_ID" ]; then
  if [ ! -f "$STATE/$TARGET_ID.meta" ]; then
    echo "fm-slot-audit: no task record for $TARGET_ID in $STATE" >&2
    exit 1
  fi
  audit_record "$STATE/$TARGET_ID.meta" ""
else
  audit_state_dir "$STATE" ""
  if fm_local_firstmate_state_dirs "$STATE"; then
    for other_state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
      [ "$other_state" != "$STATE" ] && [ ! "$other_state" -ef "$STATE" ] || continue
      [ -d "$other_state" ] || continue
      audit_state_dir "$other_state" "${other_state%/state}"
    done
  else
    echo "fm-slot-audit: audited this home only - $FM_LOCAL_FIRSTMATE_ERROR" >&2
  fi
fi

if [ "$JSON" = 1 ]; then
  if [ -n "$JSON_ROWS" ]; then
    printf '%s' "$JSON_ROWS" | jq -s '.'
  else
    printf '[]\n'
  fi
fi
exit 0
