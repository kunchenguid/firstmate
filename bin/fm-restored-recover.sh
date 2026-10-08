#!/usr/bin/env bash
# fm-restored-recover.sh - put this home's restored workers back where their
# work is, after a machine restart.
#
# Usage: fm-restored-recover.sh [--dry-run]
#
# WHY. Herdr persists its session layout and, on restart, resumes each pane's
# recorded agent session (`claude --resume <id>`) in the pane's saved cwd. That
# cwd is the pane's TOP shell's directory, and a ship or scout pane's top shell
# sits in the project's primary checkout: `treehouse get` enters the task
# worktree in a nested shell, and no cd typed into that nested shell, nor an OSC 7
# report, reaches the saved layout (docs/verification/runtime-backends.md
# "Herdr restart resumes agents in the top shell's directory"). So after a
# reboot a worker comes back alive but in the primary checkout, where Claude
# Code often parks it on a startup gate such as the external CLAUDE.md imports
# consent. Nothing about that state is visible as `dead` or `missing`, so the
# ordinary dead-endpoint recovery never fires.
#
# WHAT. For every local direct report recorded in this home (ship, scout, or
# secondmate) on a backend with a recovery-grade agent-state classifier (tmux,
# herdr), whose agent reads `alive`, this sweep relaunches it through
# `bin/fm-control.sh <id> relaunch` when either holds:
#   - its viewport shows a harness startup gate (fm_composer_startup_dialog), or
#   - its foreground process runs outside its recorded worktree, read twice a
#     moment apart so a transient read cannot trigger it.
# A drifted endpoint is relaunched only on Herdr, whose relaunch moves the pane
# back into the worktree; elsewhere it is reported rather than stopped.
# The relaunch owns everything else: the checkpoint that proves the worktree and
# its unlanded work are intact, stopping the old agent without answering any
# gate, entering the recorded worktree, and launching the replacement there
# with a progress note appended to the worker's instructions. A secondmate's
# charter is never rewritten, so its note stays parent-side evidence.
# Relaunches run concurrently; their output is replayed in task order.
#
# Every other state is left alone: `dead` and `missing` endpoints keep their own
# recovery paths (the secondmate liveness sweep and stuck-crewmate recovery),
# and an unreadable path, an unreadable viewport, or any non-`alive` verdict
# never triggers a relaunch. Remote secondmates are skipped by name.
#
# OUTPUT, one line per affected task, nothing for a healthy fleet:
#   BOOTSTRAP_INFO: worker <id> was <cause>; relaunched in its recorded worktree <path>
#   RESTORED_WORKER: <id>: was <cause>; relaunch failed: <first error line>
#   RESTORED_WORKER: <id>: was <cause>; not relaunched: a <backend> relaunch cannot move its endpoint back into <path>
#   RESTORED_WORKER: <id>: was <cause>; not relaunched (dry run)
# Exit status is 0 unless the home itself cannot be read.
#
# bin/fm-bootstrap.sh runs this in its deferred network phase beside the dead
# secondmate relaunch, so it runs once per locked session start and never on the
# blocking path. Running it by hand from the lock-owning session is safe: each
# relaunch takes fm-control's per-task lock, and a healthy worker is a no-op.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
esac

[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || {
  echo "error: FM_HOME must name this firstmate home" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"

RECHECK_DELAY=${FM_RESTORED_RECOVER_RECHECK:-1}

real_dir() {  # <path>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# outside_worktree <seen> <worktree-real>: true when <seen> resolves to a
# directory that is neither the worktree nor inside it. An unresolvable path
# is not evidence of anything.
outside_worktree() {  # <seen> <worktree-real>
  local seen
  [ -n "$1" ] || return 1
  seen=$(real_dir "$1") || return 1
  case "$seen/" in
    "$2"/*) return 1 ;;
  esac
  return 0
}

# drifted <backend> <target> <worktree-real>: true when the endpoint runs
# outside the worktree on two reads a moment apart, and prints what it saw.
drifted() {  # <backend> <target> <worktree-real>
  local seen
  seen=$(fm_backend_current_path "$1" "$2" 2>/dev/null) || return 1
  outside_worktree "$seen" "$3" || return 1
  sleep "$RECHECK_DELAY"
  seen=$(fm_backend_current_path "$1" "$2" 2>/dev/null) || return 1
  outside_worktree "$seen" "$3" || return 1
  printf '%s' "$seen"
}

# restored_cause <backend> <target> <worktree-real>: why this alive agent needs
# a relaunch, as "<drifted 0|1><TAB><cause>", or nothing.
restored_cause() {  # <backend> <target> <worktree-real>
  local backend=$1 target=$2 wt_real=$3 screen gate seen
  gate=
  if fm_backend_visible_capture_supported "$backend" \
    && screen=$(fm_backend_visible_capture "$backend" "$target" 2>/dev/null); then
    gate=$(fm_composer_startup_dialog "$screen") || gate=
  fi
  if seen=$(drifted "$backend" "$target" "$wt_real"); then
    if [ -n "$gate" ]; then
      printf '1\tparked on the %s in %s instead of its recorded worktree' "$gate" "$seen"
    else
      printf '1\trunning in %s instead of its recorded worktree' "$seen"
    fi
  elif [ -n "$gate" ]; then
    printf '0\tparked on the %s' "$gate"
  else
    return 1
  fi
}

relaunch_note() {  # <cause> <worktree>
  printf '%s\n' \
    "The machine restarted, and your terminal came back with your previous session resumed but $1." \
    "Firstmate stopped that copy without answering any prompt and relaunched you in your recorded worktree $2." \
    "Every committed and uncommitted change there is exactly as you left it." \
    "Re-read these instructions, run git status and git log to see where the work stands, and continue from there."
}

# recover_one <meta> <id>: print at most one line for this task.
recover_one() {  # <meta> <id>
  local meta=$1 id=$2 kind wt wt_real backend target cause drift out rc first
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in ship|scout|secondmate) ;; *) return 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] || return 0
  wt_real=$(real_dir "$wt") || return 0
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 0
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in tmux|herdr) ;; *) return 0 ;; esac
  [ "$(fm_backend_agent_state "$backend" "$target")" = alive ] || return 0
  cause=$(restored_cause "$backend" "$target" "$wt_real") || return 0
  drift=${cause%%$'\t'*}
  cause=${cause#*$'\t'}
  [ -n "$cause" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "RESTORED_WORKER: $id: was $cause; not relaunched (dry run)"
    return 0
  fi
  # Only a Herdr relaunch moves a drifted endpoint back into its worktree
  # (bin/fm-spawn.sh --relaunch); any other backend would stop the agent and
  # then refuse to launch outside the worktree, so it is reported instead.
  if [ "$drift" = 1 ] && [ "$backend" != herdr ]; then
    echo "RESTORED_WORKER: $id: was $cause; not relaunched: a $backend relaunch cannot move its endpoint back into $wt"
    return 0
  fi
  rc=0
  out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
    --note "$(relaunch_note "$cause" "$wt")" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "BOOTSTRAP_INFO: worker $id was $cause; relaunched in its recorded worktree $wt"
  else
    first=$(printf '%s\n' "$out" | grep -m1 '^error: ' || printf '%s\n' "$out" | sed -n '1p')
    echo "RESTORED_WORKER: $id: was $cause; relaunch failed: ${first#error: }"
  fi
}

OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-restored-recover.XXXXXX") || {
  echo "error: could not create a private output directory" >&2
  exit 1
}
trap 'rm -rf "$OUT_DIR"' EXIT

n=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  n=$((n + 1))
  recover_one "$meta" "$id" > "$OUT_DIR/$n" 2>/dev/null &
done
wait
i=1
while [ "$i" -le "$n" ]; do
  [ ! -s "$OUT_DIR/$i" ] || cat "$OUT_DIR/$i"
  i=$((i + 1))
done
exit 0
