#!/usr/bin/env bash
# Safely rehome one quota-wedged task to a different explicit harness.
# Usage:
#   fm-rehome-quota-wall.sh <task-id> --harness <verified-harness> [--model <name>] [--effort <level>] [--dispatch-approved] [--force-dirty]
#
# Contract:
#   - Manual substrate only; no dispatch or spawn path calls this automatically.
#   - Requires an explicit verified harness and never chooses a harness itself.
#   - When config/crew-dispatch.json exists, refuses unless the operator passes
#     --dispatch-approved after consulting the dispatch rules.
#   - Supports the evidence-backed tmux same-worktree relaunch path only.
#   - Refuses dirty uncommitted work unless --force-dirty is explicit.
#   - Preserves task identity by reusing state/<id>.meta, data/<id>/, the same
#     worktree, current branch, and recorded PR metadata.
#   - Refuses if opposite_harness_must_differ_from=<harness> in task meta would
#     be violated by the requested target harness.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-harness-launch-lib.sh
. "$SCRIPT_DIR/fm-harness-launch-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

usage() {
  sed -n '2,18p' "$0" >&2
}

need_value() {
  [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { usage; exit 0; }
ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }
shift || true

HARNESS=
MODEL=default
EFFORT=default
BACKEND=tmux
DISPATCH_APPROVED=0
FORCE_DIRTY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) need_value "$@"; HARNESS=$2; shift 2 ;;
    --harness=*) HARNESS=${1#--harness=}; shift ;;
    --model) need_value "$@"; MODEL=$2; shift 2 ;;
    --model=*) MODEL=${1#--model=}; shift ;;
    --effort) need_value "$@"; EFFORT=$2; shift 2 ;;
    --effort=*) EFFORT=${1#--effort=}; shift ;;
    --backend) need_value "$@"; BACKEND=$2; shift 2 ;;
    --backend=*) BACKEND=${1#--backend=}; shift ;;
    --dispatch-approved) DISPATCH_APPROVED=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$HARNESS" ] || { echo "error: --harness is required; rehome never picks a harness itself" >&2; exit 2; }
case "$EFFORT" in
  default|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 2 ;;
esac
fm_launch_template "$HARNESS" ship >/dev/null \
  || { echo "error: unknown or unverified harness '$HARNESS'" >&2; exit 2; }
[ "$BACKEND" = tmux ] || { echo "error: fm-rehome-quota-wall currently supports --backend tmux only" >&2; exit 2; }

if [ -f "$CONFIG/crew-dispatch.json" ] && [ "$DISPATCH_APPROVED" -ne 1 ]; then
  echo "error: config/crew-dispatch.json is active; consult it first, then rerun with --dispatch-approved" >&2
  exit 1
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
fm_capacity_opposite_harness_ok "$META" "$HARNESS" || exit 1

OLD_BACKEND=$(fm_backend_of_meta "$META")
[ "$OLD_BACKEND" = tmux ] || { echo "error: current task backend '$OLD_BACKEND' is not supported by this tmux-only rehome helper" >&2; exit 1; }
OLD_TARGET=$(fm_backend_target_of_meta "$META")
OLD_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
[ "$KIND" != secondmate ] || { echo "error: secondmate rehome is not supported; use the secondmate recovery path" >&2; exit 1; }
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
TASK_TMP=$(fm_meta_get "$META" tasktmp)
[ -n "$TASK_TMP" ] || TASK_TMP="/tmp/fm-$ID"
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: recorded worktree is missing: ${WT:-<empty>}" >&2; exit 1; }
[ -n "$PROJ" ] || PROJ="$WT"
ORIG_BRIEF="$DATA/$ID/brief.md"
[ -f "$ORIG_BRIEF" ] || { echo "error: original brief missing at $ORIG_BRIEF" >&2; exit 1; }

WT_REAL=$(cd "$WT" && pwd -P)
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$WT_TOP" ] || { echo "error: $WT is not a git worktree" >&2; exit 1; }
WT_TOP_REAL=$(cd "$WT_TOP" && pwd -P)
[ "$WT_REAL" = "$WT_TOP_REAL" ] || { echo "error: recorded worktree is not its git top-level: $WT" >&2; exit 1; }

DIRTY_RAW=$(git -C "$WT" status --porcelain)
DIRTY=$(printf '%s\n' "$DIRTY_RAW" | grep -vE '^[?][?] (\.claude/|\.opencode/|\.fm-grok-turnend$)' | head -1 || true)
if [ -n "$DIRTY" ] && [ "$FORCE_DIRTY" -ne 1 ]; then
  echo "REFUSED: worktree $WT has uncommitted changes; commit/stash them or rerun with --force-dirty." >&2
  printf '%s\n' "$DIRTY_RAW" >&2
  exit 1
fi
if [ -n "$DIRTY" ]; then
  echo "warning: --force-dirty set; rehoming with uncommitted work present" >&2
fi

HEAD=$(git -C "$WT" rev-parse HEAD)
BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')
PR_URL=$(fm_meta_get "$META" pr)

if [ -n "$OLD_TARGET" ] && fm_backend_target_exists "$OLD_BACKEND" "$OLD_TARGET"; then
  ALIVE=$(fm_backend_agent_alive "$OLD_BACKEND" "$OLD_TARGET")
  case "$ALIVE" in
    alive)
      if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$ID" /exit >/dev/null 2>&1; then
        :
      else
        echo "warning: /exit send to old endpoint failed; waiting for liveness anyway" >&2
      fi
      for _ in $(seq 1 "${FM_REHOME_EXIT_POLLS:-20}"); do
        sleep "${FM_REHOME_EXIT_SLEEP:-0.5}"
        ALIVE=$(fm_backend_agent_alive "$OLD_BACKEND" "$OLD_TARGET")
        [ "$ALIVE" = dead ] && break
      done
      [ "$ALIVE" = dead ] || { echo "error: old endpoint still reports agent_alive=$ALIVE after /exit; refusing duplicate ownership" >&2; exit 1; }
      ;;
    dead)
      ;;
    *)
      echo "error: old endpoint liveness is '$ALIVE'; refusing duplicate ownership" >&2
      exit 1
      ;;
  esac
  fm_backend_kill "$OLD_BACKEND" "$OLD_TARGET" >/dev/null 2>&1 || true
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ISO=$(fm_capacity_iso_now)
mkdir -p "$DATA/$ID"
CONT_BRIEF="$DATA/$ID/rehome-$STAMP.md"
cat > "$CONT_BRIEF" <<EOF
# Rehome Continuation for $ID

This is the same firstmate task, not a helper lane.
Continue in the existing worktree and current branch.
Do not create a new branch, new task id, or child PR.

- Rehome reason: quota wall / capacity failover.
- Previous harness: ${OLD_HARNESS:-unknown}
- New harness: $HARNESS
- Worktree: $WT
- Branch: $BRANCH
- Head at rehome: $HEAD
- Recorded PR: ${PR_URL:-none}
- Rehomed at: $ISO

Before changing code, run \`git status --short\` and confirm you are still in this worktree.
Preserve the recorded PR/session identity; push ordinary commits to this branch if the task already has a PR.

## Original Brief

$(cat "$ORIG_BRIEF")
EOF

SES=$(fm_backend_tmux_container_ensure)
W="fm-$ID"
T="$SES:$W"
fm_backend_tmux_create_task "$SES" "$W" "$WT" >/dev/null

mkdir -p "$TASK_TMP/gotmp" "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
fm_launch_install_turn_end_hook "$HARNESS" "$KIND" "$WT" "$STATE" "$ID" "$TURNEND" "$PROJ"

META_TMP=$(mktemp "$STATE/$ID.meta.XXXXXXXX")
awk -F= '
  BEGIN {
    skip["window"]=1; skip["harness"]=1; skip["model"]=1; skip["effort"]=1; skip["backend"]=1;
    skip["terminal"]=1; skip["herdr_session"]=1; skip["herdr_workspace_id"]=1; skip["herdr_tab_id"]=1; skip["herdr_pane_id"]=1;
    skip["zellij_session"]=1; skip["zellij_tab_id"]=1; skip["zellij_pane_id"]=1;
    skip["orca_worktree_id"]=1; skip["cmux_workspace_id"]=1; skip["cmux_surface_id"]=1;
  }
  /^[A-Za-z_][A-Za-z0-9_]*=/ {
    if (skip[$1]) next;
  }
  { print }
' "$META" > "$META_TMP"
{
  printf 'window=%s\n' "$T"
  printf 'harness=%s\n' "$HARNESS"
  printf 'model=%s\n' "$MODEL"
  printf 'effort=%s\n' "$EFFORT"
  printf 'backend=tmux\n'
  printf 'rehome_at=%s\n' "$ISO"
  printf 'rehome_from_harness=%s\n' "${OLD_HARNESS:-unknown}"
  printf 'rehome_from_window=%s\n' "${OLD_TARGET:-none}"
  printf 'rehome_continuation=%s\n' "$CONT_BRIEF"
} >> "$META_TMP"
mv "$META_TMP" "$META"

SQ_BRIEF=$(fm_launch_shell_quote "$CONT_BRIEF")
SQ_TURNEND=$(fm_launch_shell_quote "$TURNEND")
SQ_PIEXT=$(fm_launch_shell_quote "$STATE/$ID.pi-ext.ts")
SQ_OMPEXT=$(fm_launch_shell_quote "$STATE/$ID.omp-ext.ts")
PROVIDERFLAG=$(fm_launch_provider_flag_for_harness "$HARNESS" "$MODEL")
MODELFLAG=$(fm_launch_model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(fm_launch_effort_flag_for_harness "$HARNESS" "$EFFORT")
CODEXMCPFLAG=$(fm_launch_codex_mcp_flag "$HARNESS" "$KIND" "$CONFIG")
LAUNCH=$(fm_launch_template "$HARNESS" "$KIND")
LAUNCH=${LAUNCH//__PROVIDERFLAG__/$PROVIDERFLAG}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__CODEXMCPFLAG__/$CODEXMCPFLAG}
LAUNCH=${LAUNCH//__CLAUDE_OAUTH_EXEC__/}
LAUNCH=${LAUNCH//__BRIEF__/$SQ_BRIEF}
LAUNCH=${LAUNCH//__TURNEND__/$SQ_TURNEND}
LAUNCH=${LAUNCH//__PIEXT__/$SQ_PIEXT}
LAUNCH=${LAUNCH//__OMPEXT__/$SQ_OMPEXT}
LAUNCH=${LAUNCH//__PITURNEND__/}
LAUNCH=${LAUNCH//__PIWATCH__/}

fm_backend_tmux_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
fm_backend_tmux_send_literal "$T" "$LAUNCH"
sleep 0.3
fm_backend_tmux_send_key "$T" Enter

printf 'rehomed %s from %s to %s window=%s worktree=%s continuation=%s\n' "$ID" "${OLD_HARNESS:-unknown}" "$HARNESS" "$T" "$WT" "$CONT_BRIEF"
