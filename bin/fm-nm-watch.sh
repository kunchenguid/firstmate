#!/usr/bin/env bash
# fm-nm-watch.sh - the one owner of a task's pipeline-state watch
# (when-nm-state-<task-id>) and of where that watch and bin/fm-crew-state.sh
# look for the task's no-mistakes run.
#
# Usage:
#   fm-nm-watch.sh arm <task-id>
#   fm-nm-watch.sh register-clone <task-id> <absolute-clone-path>
#
# arm             Retire any existing watch for the task, then arm a fresh one
#                 polling the registered clone (nm_clone= in state/<id>.meta),
#                 else the recorded worktree. Idempotent, so a relaunch
#                 converges on the watch its original spawn armed instead of
#                 refusing. The condition is bin/fm-nm-state-condition.sh and
#                 the action rings the task's steering inbox through
#                 bin/fm-send.sh (docs/configuration.md "Pipeline-state watch").
#                 Armed --repeat because a pipeline changes state several times
#                 per run, and --edge because the condition already de-dups its
#                 own transitions (it rewrites its snapshot on every poll, true
#                 or false), so the generic repeat dedup would risk discarding
#                 a real change observed right after a restart between fires.
#                 A failure exits 1 AND appends a durable `check` wake naming
#                 the task, so a supervisor notices it; stderr alone is not.
# register-clone  Record <path> as where the task's pipeline runs (the top level
#                 of a git checkout, such as a throwaway clone an upstream
#                 workflow requires), then re-arm the watch on it. The worker
#                 runs it before its first `no-mistakes axi run` outside its
#                 worktree. A relative, missing, or non-top-level path is
#                 refused without touching the task record.
#
# FM_HOME selects the home (default: this code root); FM_STATE_OVERRIDE its state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

die() { printf 'fm-nm-watch: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '6,8p' "$0" | sed 's/^# *//' >&2; exit 2; }

load_task() {  # <task-id>
  case "${1-}" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid task id: ${1-}" ;; esac
  META="$STATE/$1.meta"
  [ -f "$META" ] || die "no task record for $1"
}

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

load_wake_lib() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

cmd_arm() {  # <task-id>
  local id=$1 dir err=''
  load_task "$id"
  dir=$(meta_value nm_clone)
  [ -n "$dir" ] || dir=$(meta_value worktree)
  if [ -z "$dir" ]; then
    err="no worktree recorded"
  else
    "$SCRIPT_DIR/fm-procevent-when.sh" retire "nm-state-$id" >/dev/null 2>&1 || true
    rm -f -- "$STATE/$id.nm-state"
    if err=$("$SCRIPT_DIR/fm-procevent-when.sh" arm "nm-state-$id" \
        --interval 45 --stable 1 --condition-timeout 60 --action-timeout 120 \
        --repeat --edge --action-env "FM_HOME=$FM_HOME" \
        --condition "$SCRIPT_DIR/fm-nm-state-condition.sh" "$dir" "$STATE/$id.nm-state" \
        --action "$SCRIPT_DIR/fm-send.sh" "$id" \
          "no-mistakes state changed: run \`no-mistakes axi status\` where your run executes, append \`resolved: run returned\`, and answer the parked gate." \
        2>&1 >/dev/null); then
      echo "armed: when-nm-state-$id (pipeline-state watch) on $dir"
      return 0
    fi
    err=$(printf '%s\n' "$err" | tail -1)
  fi
  load_wake_lib
  fm_wake_append check "nm-watch:$id" \
    "check: pipeline-state watch for $id could not be armed (${err:-unknown error}); its validation will not ring the worker - fix the cause, then run bin/fm-nm-watch.sh arm $id" \
    || printf 'fm-nm-watch: could not queue the arm-failure wake for %s\n' "$id" >&2
  printf 'warning: could not arm the pipeline-state watch for %s: %s\n' "$id" "${err:-unknown error}" >&2
  return 1
}

cmd_register_clone() {  # <task-id> <path>
  local id=$1 path=$2 top lock tmp
  load_task "$id"
  case "$path" in
    *$'\n'*) die "clone path cannot contain a newline" ;;
    /*) ;;
    *) die "clone path must be absolute: $path" ;;
  esac
  [ -d "$path" ] || die "clone path is not a directory: $path"
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || die "clone path is not a git checkout: $path"
  [ "$(cd -P -- "$path" && pwd -P)" = "$(cd -P -- "$top" && pwd -P)" ] \
    || die "clone path must be the checkout's top level ($top): $path"
  load_wake_lib
  lock=$(fm_meta_lock_path "$META") || die "cannot resolve the task record lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock the task record"
  tmp=$(mktemp "$STATE/.fm-nm-meta.XXXXXX") || { fm_lock_release "$lock"; die "cannot stage the task record"; }
  if ! { { grep -v '^nm_clone=' "$META" || true; printf 'nm_clone=%s\n' "$path"; } > "$tmp" \
      && mv -f -- "$tmp" "$META"; }; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    die "cannot update the task record"
  fi
  fm_lock_release "$lock"
  echo "registered: $id pipeline runs in $path"
  cmd_arm "$id"
}

case "${1-}" in
  arm) [ "$#" -eq 2 ] || usage; cmd_arm "$2" ;;
  register-clone) [ "$#" -eq 3 ] || usage; cmd_register_clone "$2" "$3" ;;
  *) usage ;;
esac
