#!/usr/bin/env bash
# Manage the data-only contender lifecycle for finished scout options.
#
# Usage:
#   fm-contender.sh await-pick <task-id>...
#   fm-contender.sh settle <picked|rejected|superseded> <task-id>...
#   fm-contender.sh list
#
# A contender is a finished scout whose report lives at data/<task-id>/report.md,
# so it has no project branch to land.  await-pick records an atomic durable
# awaiting-pick state under state/contenders/ and then runs the ordinary safe
# teardown.  Its report remains available under data/ while the worker endpoint
# and its stale notifications are removed.  settle makes a pick, rejection, or
# supersession durable long enough to survive an interrupted cleanup, then removes
# the contender record.  The policy and bounded re-roll procedure are owned by
# .agents/skills/contender-discipline/SKILL.md.
#
# FM_TEARDOWN_BIN may name a compatible teardown executable for hermetic tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
CONTESTERS="$STATE/contenders"
TEARDOWN_BIN=${FM_TEARDOWN_BIN:-"$FM_ROOT/bin/fm-teardown.sh"}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

record_path() {
  printf '%s/%s' "$CONTESTERS" "$1"
}

lock_path() {
  printf '%s/.contender-%s.lock' "$STATE" "$1"
}

write_record() {  # <id> <phase>
  local id=$1 phase=$2 dir record tmp
  dir=$CONTESTERS
  mkdir -p "$dir" || return 1
  record=$(printf 'phase=%s\nreport=data/%s/report.md\n' "$phase" "$id")
  tmp=$(umask 077; mktemp "$dir/.${id}.XXXXXX") || return 1
  if ! printf '%s' "$record" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$(record_path "$id")"
}

read_record() {  # <id>; stdout: phase
  local id=$1 path phase='' report='' line phase_count=0 report_count=0
  path=$(record_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      phase=*) phase=${line#phase=}; phase_count=$((phase_count + 1)) ;;
      report=*) report=${line#report=}; report_count=$((report_count + 1)) ;;
      *) return 1 ;;
    esac
  done < "$path" || return 1
  [ "$phase_count" -eq 1 ] && [ "$report_count" -eq 1 ] || return 1
  [ "$report" = "data/$id/report.md" ] || return 1
  case "$phase" in cleaning|awaiting-pick|picked|rejected|superseded) ;; *) return 1 ;; esac
  printf '%s\n' "$phase"
}

prepare_awaiting_pick() {  # <id>
  local id=$1 phase='' meta="$STATE/$1.meta" report="$DATA/$1/report.md"
  if [ -e "$(record_path "$id")" ]; then
    phase=$(read_record "$id") || {
      echo "error: contender record for $id is malformed; refusing lifecycle cleanup" >&2
      return 1
    }
    case "$phase" in
      awaiting-pick) return 0 ;;
      cleaning) : ;;
      *)
        echo "error: contender $id is already settled as $phase" >&2
        return 1
        ;;
    esac
  else
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
      echo "error: contender $id has no readable live task record" >&2
      return 1
    }
    grep -qx 'kind=scout' "$meta" || {
      echo "error: contender $id is not a scout; only data-only scout options may use this lifecycle" >&2
      return 1
    }
    [ -f "$report" ] && [ ! -L "$report" ] && [ -r "$report" ] || {
      echo "error: contender $id has no readable report at data/$id/report.md" >&2
      return 1
    }
    write_record "$id" cleaning || {
      echo "error: could not record contender cleanup for $id" >&2
      return 1
    }
  fi

  if [ -e "$meta" ]; then
    [ -x "$TEARDOWN_BIN" ] || {
      echo "error: contender teardown executable is unavailable: $TEARDOWN_BIN" >&2
      return 1
    }
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$TEARDOWN_BIN" "$id" || return 1
  fi
  [ ! -e "$meta" ] || {
    echo "error: contender $id cleanup did not remove its live task record" >&2
    return 1
  }
  write_record "$id" awaiting-pick || {
    echo "error: contender $id was cleaned but awaiting-pick could not be recorded" >&2
    return 1
  }
}

await_pick() {
  local id lock status
  [ "$#" -gt 0 ] || { usage >&2; return 2; }
  for id in "$@"; do
    fm_task_id_creation_valid "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
    lock=$(lock_path "$id")
    fm_lock_acquire_wait "$lock"
    status=0
    prepare_awaiting_pick "$id" || status=$?
    fm_lock_release "$lock"
    [ "$status" -eq 0 ] || return "$status"
    printf 'awaiting-pick %s data/%s/report.md\n' "$id" "$id"
  done
}

settle_one() {  # <outcome> <id>
  local outcome=$1 id=$2 phase
  if [ -e "$(record_path "$id")" ]; then
    phase=$(read_record "$id") || {
      echo "error: contender record for $id is malformed; refusing settlement" >&2
      return 1
    }
    case "$phase" in
      "$outcome")
        rm -f -- "$(record_path "$id")" || {
          echo "error: could not remove settled contender record for $id" >&2
          return 1
        }
        return 0
        ;;
      picked|rejected|superseded)
        echo "error: contender $id is already settled as $phase" >&2
        return 1
        ;;
    esac
  fi
  prepare_awaiting_pick "$id" || return 1
  phase=$(read_record "$id") || {
    echo "error: contender record for $id is malformed; refusing settlement" >&2
    return 1
  }
  [ "$phase" = awaiting-pick ] || {
    echo "error: contender $id is not awaiting a pick" >&2
    return 1
  }
  write_record "$id" "$outcome" || {
    echo "error: could not record contender $id as $outcome" >&2
    return 1
  }
  rm -f -- "$(record_path "$id")" || {
    echo "error: could not remove settled contender record for $id" >&2
    return 1
  }
}

settle() {  # <outcome> <id>...
  local outcome=$1 id lock status
  shift
  case "$outcome" in picked|rejected|superseded) ;; *) usage >&2; return 2 ;; esac
  [ "$#" -gt 0 ] || { usage >&2; return 2; }
  for id in "$@"; do
    fm_task_id_creation_valid "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
    lock=$(lock_path "$id")
    fm_lock_acquire_wait "$lock"
    status=0
    settle_one "$outcome" "$id" || status=$?
    fm_lock_release "$lock"
    [ "$status" -eq 0 ] || return "$status"
    printf '%s %s\n' "$outcome" "$id"
  done
}

list() {
  local path id phase
  [ -d "$CONTESTERS" ] || return 0
  for path in "$CONTESTERS"/*; do
    [ -e "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || {
      echo "error: malformed contender record: $path" >&2
      return 1
    }
    id=${path##*/}
    fm_task_id_creation_valid "$id" || { echo "error: invalid contender record name: $id" >&2; return 1; }
    phase=$(read_record "$id") || { echo "error: malformed contender record: $path" >&2; return 1; }
    printf '%s %s data/%s/report.md\n' "$phase" "$id" "$id"
  done
}

case "${1:-}" in
  -h|--help) usage ;;
  await-pick) shift; await_pick "$@" ;;
  settle) shift; [ "$#" -gt 0 ] || { usage >&2; exit 2; }; settle "$@" ;;
  list) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; list ;;
  *) usage >&2; exit 2 ;;
esac
