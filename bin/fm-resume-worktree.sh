#!/usr/bin/env bash
# bin/fm-resume-worktree.sh - resume a crewmate/scout task in its EXISTING,
# already-provisioned worktree instead of provisioning a fresh one via
# `treehouse get` (bin/fm-spawn.sh). Formalizes the ad hoc recovery firstmate
# did by hand after the last full-machine-restart recovery (AGENTS.md
# section 5): a restart can kill the runtime session-provider endpoint (the
# tmux window a crewmate lived in) while state/<id>.meta and the git worktree
# it points at survive untouched on disk. This script recreates the endpoint,
# starts it directly IN the recorded worktree (no treehouse involved, no new
# git worktree), and relaunches the SAME harness/model/effort profile that
# was recorded at the original spawn - it never touches git and never writes
# a fresh state/<id>.meta.
#
# Usage: fm-resume-worktree.sh <task-id>
#
# Scope: kind=ship|scout tasks on the tmux backend (today's verified
# reference backend) only.
#   - kind=secondmate is refused: recover a secondmate through
#     `bin/fm-spawn.sh <id> --secondmate` instead (AGENTS.md section 5 point
#     6) - a secondmate's home is a persistent firstmate home with its own
#     fast-forward + relaunch path, not a treehouse worktree in this sense.
#   - backend=herdr is refused for now: herdr's container/task lifecycle
#     (workspace-per-home labeling, seeded default tabs) is materially more
#     involved than tmux's; extend the herdr branch below if a herdr-backend
#     resume is ever needed instead of guessing at it here.
#   - Per-worktree turn-end hooks (.claude/settings.local.json,
#     .opencode/plugins/fm-turn-end.js, state/<id>.pi-ext.ts, grok's
#     firstmate-owned global hook + state/<id>.grok-turnend-token) are NOT
#     re-installed: they are ordinary files that survive a tmux or machine
#     restart untouched, unlike the runtime session endpoint this script
#     exists to recreate. If a worktree's hook file was independently lost,
#     respawn fresh with fm-spawn.sh instead of resuming.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-launch-lib.sh
. "$SCRIPT_DIR/fm-launch-lib.sh"

"$FM_ROOT/bin/fm-guard.sh" || true

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-resume-worktree.sh <task-id>" >&2; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta at $META; nothing to resume - use fm-spawn.sh to spawn a fresh task" >&2; exit 1; }

KIND=$(fm_meta_get "$META" kind); KIND=${KIND:-ship}
WT=$(fm_meta_get "$META" worktree)
PROJ_ABS=$(fm_meta_get "$META" project)
HARNESS=$(fm_meta_get "$META" harness)
MODEL=$(fm_meta_get "$META" model)
EFFORT=$(fm_meta_get "$META" effort)
BACKEND=$(fm_backend_of_meta "$META")
OLD_T=$(fm_meta_get "$META" window)
RECORDED_TASK_TMP=$(fm_meta_get "$META" tasktmp)

[ "$KIND" != secondmate ] || { echo "error: $ID is kind=secondmate; recover it with '$FM_ROOT/bin/fm-spawn.sh $ID --secondmate' instead (AGENTS.md section 5)" >&2; exit 1; }
[ -n "$WT" ] || { echo "error: meta for $ID has no worktree= recorded" >&2; exit 1; }
[ -n "$HARNESS" ] || { echo "error: meta for $ID has no harness= recorded" >&2; exit 1; }
fm_backend_validate "$BACKEND" || exit 1
[ "$BACKEND" = tmux ] || { echo "error: fm-resume-worktree.sh only supports the tmux backend today (meta backend=$BACKEND); resume it by hand or extend this script" >&2; exit 1; }
fm_backend_source "$BACKEND" || exit 1

# The worktree must still be a genuine, isolated git worktree on disk - the
# same isolation guard fm-spawn.sh applies right after `treehouse get`,
# checked directly here since there is no pane-cwd poll to wait on.
[ -d "$WT" ] || { echo "error: recorded worktree $WT no longer exists on disk; this task cannot be resumed, only respawned fresh" >&2; exit 1; }
WT_REAL=$(cd "$WT" && pwd -P)
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || { echo "error: $WT is not a git worktree (git rev-parse --show-toplevel failed)" >&2; exit 1; }
WT_TOP_REAL=$(cd "$WT_TOP" && pwd -P)
[ "$WT_REAL" = "$WT_TOP_REAL" ] || { echo "error: $WT is not the root of its own git worktree (resolved root: $WT_TOP)" >&2; exit 1; }
if [ -n "$PROJ_ABS" ] && [ -d "$PROJ_ABS" ]; then
  PROJ_REAL=$(cd "$PROJ_ABS" && pwd -P)
  [ "$WT_REAL" != "$PROJ_REAL" ] || { echo "error: recorded worktree $WT IS the primary project checkout $PROJ_ABS; refusing to resume onto it" >&2; exit 1; }
fi

# Refuse if the recorded endpoint is already alive - resuming would either
# collide with a live crewmate or silently orphan it. A stuck-but-alive
# crewmate is stuck-crewmate-recovery's job, not this script's.
if [ -n "$OLD_T" ] && fm_backend_target_exists "$BACKEND" "$OLD_T"; then
  echo "error: $ID's recorded window $OLD_T is still alive; nothing to resume (if it looks stuck, use the stuck-crewmate-recovery playbook instead)" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (unverified adapter; resume it by hand)" >&2; exit 1; }

rewrite_resume_meta() {
  local tmp_meta
  tmp_meta=$(mktemp "$STATE/.$ID.meta.XXXXXX") || return 1
  awk -v new_window="window=$T" -v new_tasktmp="tasktmp=$TASK_TMP" '
    BEGIN { window_done=0; tasktmp_done=0 }
    /^window=/ { print new_window; window_done=1; next }
    /^tasktmp=/ { if ($0 == "tasktmp=") print new_tasktmp; else print; tasktmp_done=1; next }
    { print }
    END {
      if (!window_done) print new_window
      if (!tasktmp_done) print new_tasktmp
    }
  ' "$META" > "$tmp_meta" || { rm -f "$tmp_meta"; return 1; }
  mv "$tmp_meta" "$META"
}

# Session-provider container-ensure + task creation, mirroring fm-spawn.sh's
# own tmux branch, but with the window's starting cwd set directly to the
# EXISTING worktree ($WT) instead of the project dir - there is no
# `treehouse get` step here to move the pane into a fresh worktree.
W="fm-$ID"
SES=$(fm_backend_tmux_container_ensure)
T="$SES:$W"
TASK_TMP="${RECORDED_TASK_TMP:-/tmp/fm-$ID}"
fm_backend_tmux_create_task "$SES" "$W" "$WT" || exit 1

meta_tracked=0
if [ "$T" = "$OLD_T" ] && [ -n "$RECORDED_TASK_TMP" ]; then
  meta_tracked=1
fi
cleanup_untracked_endpoint() {
  [ "$meta_tracked" -eq 1 ] || fm_backend_tmux_kill "$T" 2>/dev/null || true
}
trap cleanup_untracked_endpoint EXIT INT TERM HUP
if [ "$meta_tracked" -eq 0 ]; then
  rewrite_resume_meta || exit 1
fi
meta_tracked=1
trap - EXIT INT TERM HUP

mkdir -p "$TASK_TMP/gotmp"
PROXY_SOURCE_CMD=$(proxy_env_source_command "$TASK_TMP") || exit 1

STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}

fm_backend_tmux_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
[ -z "$PROXY_SOURCE_CMD" ] || fm_backend_tmux_send_text_line "$T" "$PROXY_SOURCE_CMD"
sleep 0.3
fm_backend_tmux_send_literal "$T" "$LAUNCH"
sleep 0.3
fm_backend_tmux_send_key "$T" Enter

echo "resumed $ID harness=$HARNESS kind=$KIND window=$T worktree=$WT"
