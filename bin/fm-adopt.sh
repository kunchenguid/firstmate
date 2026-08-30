#!/usr/bin/env bash
# Adopt an ALREADY-RUNNING cmux workspace as a supervised firstmate task.
# Usage: fm-adopt.sh <id> --workspace <ws-uuid> [--surface <surf-uuid>] [--backend cmux]
#
# Registers a human-started cmux workspace/surface (NOT firstmate-spawned) as a
# task, so fm-peek.sh, fm-send.sh, fm-crew-state.sh, and the watcher operate on
# it. Unlike a spawn there is NO treehouse worktree and NO branch: worktree=
# records the workspace's OWN live cwd (a real existing directory, never a
# firstmate-managed worktree), and the task is supervise-only - it carries no
# delivery mode and never produces a PR. It records kind=adopted (and
# mode=adopted) so bin/fm-teardown.sh un-registers the task WITHOUT ever closing
# the human's cmux workspace, and bin/fm-watch.sh exempts it from stale-pane
# wakes (a human-driven or idle session being quiet is healthy, not stuck).
#
# The human's cmux workspace title is kept exactly as-is - never renamed.
# Peek/send target the surface by pure UUID because kind=adopted makes the
# expected-label empty (bin/fm-backend.sh's fm_backend_expected_label_of_selector),
# so no firstmate-scoped title check can reject the human's own title.
#
# cmux only, EXPERIMENTAL (docs/cmux-backend.md); any other backend refuses with
# an actionable error. Absent an app relaunch, cmux workspace ids are stable for
# the session; adopted workspaces are not fm-titled, so title-based recovery
# cannot re-find them after a relaunch - re-run fm-adopt then.
#
# As with fm-spawn, adding the data/backlog.md "In flight" line is the
# orchestrator's job, not this script's.
# On success prints: adopted <id> backend=cmux window=<ws>:<surface> worktree=<path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=
WS=
SURFACE=
BACKEND=cmux
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      workspace) WS=$a ;;
      surface) SURFACE=$a ;;
      backend) BACKEND=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --workspace) want_value=workspace ;;
    --workspace=*) WS=${a#--workspace=} ;;
    --surface) want_value=surface ;;
    --surface=*) SURFACE=${a#--surface=} ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND=${a#--backend=} ;;
    --*) echo "error: unknown flag $a" >&2; exit 1 ;;
    *)
      if [ -z "$ID" ]; then
        ID=$a
      else
        echo "error: unexpected extra argument '$a'" >&2; exit 1
      fi
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

[ -n "$ID" ] || { echo "usage: fm-adopt.sh <id> --workspace <ws-uuid> [--surface <surf-uuid>] [--backend cmux]" >&2; exit 1; }
[ -n "$WS" ] || { echo "error: --workspace <ws-uuid> is required" >&2; exit 1; }
[ ! -f "$STATE/$ID.meta" ] || { echo "error: task $ID already registered ($STATE/$ID.meta)" >&2; exit 1; }
if [ "$BACKEND" != cmux ]; then
  echo "error: fm-adopt currently supports only the cmux backend; got '$BACKEND'" >&2
  exit 1
fi

fm_backend_validate_spawn cmux || exit 1
fm_backend_source cmux || exit 1
# Client version gate plus socket reachability (launches cmux if simply down).
fm_backend_cmux_container_ensure || exit 1

if [ -z "$SURFACE" ]; then
  SURFACE=$(fm_backend_cmux_surface_id_for_workspace "$WS" || true)
  [ -n "$SURFACE" ] || { echo "error: could not resolve a surface for cmux workspace $WS; pass --surface <surf-uuid> or check 'cmux workspace list'" >&2; exit 1; }
fi

T="$WS:$SURFACE"
# Pure-UUID liveness check (no expected-label, so no title scoping): the surface
# must currently exist in the running app.
if ! fm_backend_target_exists cmux "$T"; then
  echo "error: no live cmux surface $T; is the workspace open? run 'cmux workspace list'" >&2
  exit 1
fi

# Refuse if this exact surface is already registered under a DIFFERENT task id.
# The self-id collision is caught above ($STATE/$ID.meta); this catches adopting
# the same live cmux surface a second time under a new id, which would have two
# tasks supervise - and send into - one surface. Compare the full window= line
# (workspace:surface) as a fixed string, since WS/SURFACE are opaque uuids.
if [ -d "$STATE" ]; then
  for other in "$STATE"/*.meta; do
    [ -e "$other" ] || continue
    [ "$other" = "$STATE/$ID.meta" ] && continue
    if grep -qxF "window=$T" "$other"; then
      echo "error: cmux surface $T is already registered as task '$(basename "$other" .meta)' ($other); tear that task down first, or adopt a different surface" >&2
      exit 1
    fi
  done
fi

# Derive worktree/project from the workspace's own live cwd. Adopt never creates
# a treehouse worktree; worktree= must be a real existing directory so
# fm-crew-state.sh can probe it, and it must never point at a firstmate-managed
# worktree. Fall back to $HOME with a loud notice when cmux reports no usable cwd.
WSCWD=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$WS" '.workspaces[]? | select(.id==$id) | .current_directory // empty' 2>/dev/null || true)
if [ -z "$WSCWD" ] || [ ! -d "$WSCWD" ]; then
  echo "NOTICE: cmux workspace $WS reported no usable current_directory; falling back to \$HOME for worktree=, so fm-crew-state.sh's worktree probe may be limited." >&2
  WSCWD=$HOME
fi
WORKTREE=$WSCWD
PROJECT=$WSCWD

mkdir -p "$STATE"
{
  echo "window=$WS:$SURFACE"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WORKTREE"
  echo "project=$PROJECT"
  echo "harness=adopted"
  echo "kind=adopted"
  echo "mode=adopted"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=cmux"
  echo "cmux_workspace_id=$WS"
  echo "cmux_surface_id=$SURFACE"
} > "$STATE/$ID.meta"

echo "adopted $ID backend=cmux window=$WS:$SURFACE worktree=$WORKTREE"
