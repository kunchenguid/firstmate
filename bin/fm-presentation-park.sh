#!/usr/bin/env bash
# fm-presentation-park.sh - collapse the visible presentation of a task whose
# agent has exited while the task itself stays recorded (parked).
#
# Usage: fm-presentation-park.sh <task-id> --trigger exit|sweep|teardown-refused
#
# Why this exists. A crewmate's agent runs inside an interactive shell in its
# terminal endpoint, under the `treehouse get` subshell that holds its pool slot.
# When the agent exits - by itself, or through bin/fm-control.sh exit - that
# shell is left behind, and nothing but a successful bin/fm-teardown.sh ever
# removed it. On Herdr every such task kept a bare-shell workspace in the
# sidebar. This script is the single owner of collapsing that presentation. The
# three callers only say why they are asking:
#
#   exit              bin/fm-control.sh exit stopped the agent; the task is
#                     parked with its record kept.
#   sweep             bin/fm-watch.sh found a stale endpoint whose task's current
#                     status is done or paused. Any other or unreadable status is
#                     ineligible.
#   teardown-refused  bin/fm-teardown.sh refused because the worktree holds work
#                     that has not landed.
#
# The verdict:
#   closed  The work is landed: the worktree is clean, has no commit off every
#           remote, and its HEAD is contained in origin's default branch
#           (work_is_landed below), so the endpoint is closed; on Herdr the
#           projected workspace goes with its last pane. Never on
#           teardown-refused. The task record, claim, and worktree stay for
#           bin/fm-teardown.sh; a released Treehouse slot may be handed on, and
#           bin/fm-spawn.sh --relaunch then refuses a slot another task claimed.
#   parked  Every still-resumable task: the endpoint, its shell, its Treehouse
#           slot, the worktree, every id, the projection token, and the journal
#           are kept; the task tab reads "parked: <task-id>" and a projected
#           workspace reads "└ parked: <task-id> · p:<token>". A relaunch
#           restores both. The live shell keeps an interactive Treehouse slot
#           reserved, so unmerged work stays resumable in place even after its
#           branch later lands.
#   gone    The endpoint was already gone.
#   unchanged  The backend, kind, status, or agent state is not eligible.
#
# The worktree test here is presentation-only and deliberately stricter than
# bin/fm-teardown.sh's landed-work test: an uninspectable, dirty, or unpushed
# worktree always reads as unlanded and gets the stub. It never authorizes
# removing anything but the exited agent's own terminal.
#
# Exactness. Only this home's state/<id>.meta record names the endpoint, and it
# must pass bin/fm-backend.sh's fm_backend_validate_task_endpoint. The backend
# adapter re-proves the agent gone at the exact recorded pane and tab under the
# session presentation lock (bin/backends/herdr.sh fm_backend_herdr_park_endpoint);
# a live, unknown, or moved endpoint is left untouched. Nothing is matched by
# label or name. The task's lifecycle lock (state/.control-<id>.lock) is held
# for the decision, or inherited from a parent that holds it.
#
# Backends: only herdr implements a presentation park today. Every other
# backend, and a secondmate, is reported unchanged.
#
# Output: one line, `presentation=<verdict> task=<id> [reason=<why>]`.
# Exit status: 0 for every verdict above; 1 for a usage error or a failed
# mutation. Callers treat a failure as presentation-only and continue.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

ID=${1:-}
case "$ID" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 1 ;;
esac
shift
TRIGGER=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER=${2:-}; shift 2 || { usage >&2; exit 1; } ;;
    --trigger=*) TRIGGER=${1#--trigger=}; shift ;;
    *) echo "error: unexpected argument '$1'" >&2; exit 1 ;;
  esac
done
case "$TRIGGER" in
  exit|sweep|teardown-refused) ;;
  *) echo "error: --trigger must be exit, sweep, or teardown-refused" >&2; exit 1 ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME is not set to a firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

report() {  # <verdict> [reason]
  if [ -n "${2:-}" ]; then
    printf 'presentation=%s task=%s reason=%s\n' "$1" "$ID" "$2"
  else
    printf 'presentation=%s task=%s\n' "$1" "$ID"
  fi
}

fm_task_id_creation_valid "$ID" || { echo "error: '$ID' is not a valid task id" >&2; exit 1; }
META="$STATE/$ID.meta"
[ -f "$META" ] || { report unchanged no-task-record; exit 0; }
fm_backend_validate_task_endpoint "$META" "$ID" 2>/dev/null || { report unchanged endpoint-identity-invalid; exit 0; }
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
case "${KIND:-ship}" in
  ship|scout) ;;
  *) report unchanged "kind-${KIND}"; exit 0 ;;
esac
[ "$BACKEND" = herdr ] || { report unchanged "backend-$BACKEND"; exit 0; }

if [ "$TRIGGER" = sweep ]; then
  case "$(status_line_verb "$(status_current_line "$STATE/$ID.status" "${KIND:-ship}")")" in
    done|paused) ;;
    *) report unchanged status-not-done-or-paused; exit 0 ;;
  esac
fi

# The lifecycle lock is inherited only when its recorded holder is a live
# ancestor of this process (fm-control and fm-teardown call this script while
# holding it, possibly through a command-substitution subshell).
control_lock_held_by_ancestor() {
  local owner pid=$PPID depth=0
  owner=$(cat "$CONTROL_LOCK/pid" 2>/dev/null || true)
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$owner" || return 1
  while [ "$depth" -lt 4 ]; do
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$pid" = "$owner" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    depth=$((depth + 1))
  done
  return 1
}
CONTROL_LOCK="$STATE/.control-$ID.lock"
if control_lock_held_by_ancestor; then
  :
elif fm_lock_try_acquire "$CONTROL_LOCK"; then
  trap 'fm_lock_release "$CONTROL_LOCK" || true' EXIT
else
  report unchanged lifecycle-action-in-progress
  exit 0
fi

# 0 only when the work is landed: the worktree is readable and clean, has no
# commit that is not on some remote-tracking branch, and its HEAD is contained
# in origin's default branch. An unresolvable default ref or a failed read is
# not landed. Everything else stays resumable and keeps the stub, because
# closing the shell releases an interactive Treehouse slot and Treehouse 2.3.0
# has no supported way to reserve it again.
work_is_landed() {
  local dirty unpushed ref
  [ -n "$WT" ] && [ -d "$WT" ] || return 1
  dirty=$(git -C "$WT" status --porcelain 2>/dev/null) || return 1
  [ -z "$dirty" ] || return 1
  unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -z "$unpushed" ] || return 1
  ref=$(git -C "$WT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || return 1
  [ -n "$ref" ] || return 1
  git -C "$WT" merge-base --is-ancestor HEAD "$ref" 2>/dev/null
}

MODE=stub
if [ "$TRIGGER" != teardown-refused ] && work_is_landed; then
  MODE=close
fi

fm_backend_source herdr || { echo "error: herdr adapter unavailable" >&2; exit 1; }
fm_backend_herdr_parse_target "$T" || { report unchanged endpoint-unparseable; exit 0; }
TAB=$(fm_meta_get "$META" herdr_tab_id)
rc=0
verdict=$(fm_backend_herdr_park_endpoint "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
  "$TAB" "$MODE" "$ID" "$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")") || rc=$?
case "$verdict" in
  closed|parked|gone) report "$verdict" ;;
  ineligible:*) report unchanged "${verdict#ineligible:}" ;;
  *) report unchanged "${verdict#failed:}"; exit 1 ;;
esac
[ "$rc" -eq 1 ] && exit 1
exit 0
