#!/usr/bin/env bash
# Relaunch a live ship/scout task in place on a different (or same) harness
# without leasing a new worktree or discarding work.
#
# Usage:
#   fm-runtime-handoff.sh <task-id> --harness <name> \
#     [--model <name>] [--effort <level>] \
#     [--progress-note <text>] [--progress-note-file <path>] \
#     [--skip-exit] [--backend <name>]
#
# What this does (mechanism only; firstmate decides WHEN to call it):
#   1. Reconcile the recorded worktree and endpoint ownership; refuse rather
#      than guess when either cannot be proven safe.
#   2. Cleanly exit the current agent using the recorded harness's verified
#      exit command (harness-adapters owns those facts).
#   3. Keep the same agent-free endpoint, worktree, and lease intact.
#   4. Relaunch the chosen verified harness in the EXISTING worktree with the
#      existing brief plus a concise progress note (brief file is not rewritten).
#   5. Rewrite harness=/model=/effort= (and the new endpoint fields)
#      in state/<id>.meta while preserving every other meta line (pr=, x_*, ...).
#
# Hard refusals:
#   - missing meta, missing endpoint, missing/unreadable worktree, missing original brief
#   - kind=secondmate (secondmate recovery is a different owner)
#   - live or ambiguous endpoint ownership after exit attempt
#   - unverified target harness (no launch template)
#   - --backend naming a different provider than the one recorded in meta, whose
#     endpoint string only the recorded backend can read
#   - primary-checkout or non-isolated worktree path
#   - backend=orca, refused by the relaunch half, because Orca owns its own
#     worktree lifecycle and there is no lease to preserve in place
#
# Tunables:
#   FM_HANDOFF_EXIT_POLLS (default 30) and FM_HANDOFF_EXIT_SLEEP (default 0.5)
#   bound the wait for the old agent to stop being alive after the exit command;
#   exhausting that budget refuses the handoff rather than splitting ownership.
#
# Writes one launch-only prompt file, state/<id>.handoff-prompt, holding the
# progress note plus the unchanged brief; fm-teardown.sh removes it.
#
# Does NOT: abort or restart a live no-mistakes run; start automatic quota
# monitoring; change delivery mode or yolo; return a treehouse lease.
#
# The handoff prompt tells the replacement agent to re-attach any active
# no-mistakes run via `no-mistakes axi status` and continue gates rather than
# starting a second run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-runtime-handoff refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-runtime-handoff.sh <task-id> --harness <name> [options]
  --harness <name>              required verified target harness
  --model <name>                optional model axis for the new launch
  --effort <low|medium|high|xhigh|max>
  --progress-note <text>        concise progress for the replacement agent
  --progress-note-file <path>   same, read from a file
  --skip-exit                   skip the old harness exit command (endpoint
                                must already be dead/missing)
  --backend <name>              must match the recorded backend; omit to keep it
EOF
  exit 2
}

ID=
HARNESS=
MODEL=
EFFORT=
BACKEND_ARG=
PROGRESS_NOTE=
PROGRESS_NOTE_FILE=
SKIP_EXIT=0
want_value=

for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS=$a ;;
      model) MODEL=$a ;;
      effort) EFFORT=$a ;;
      backend) BACKEND_ARG=$a ;;
      progress-note) PROGRESS_NOTE=$a ;;
      progress-note-file) PROGRESS_NOTE_FILE=$a ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --harness) want_value=harness ;;
    --harness=*) HARNESS=${a#--harness=} ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=} ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=} ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=} ;;
    --progress-note) want_value=progress-note ;;
    --progress-note=*) PROGRESS_NOTE=${a#--progress-note=} ;;
    --progress-note-file) want_value=progress-note-file ;;
    --progress-note-file=*) PROGRESS_NOTE_FILE=${a#--progress-note-file=} ;;
    --skip-exit) SKIP_EXIT=1 ;;
    -h|--help) usage ;;
    --*) echo "error: unknown option $a" >&2; usage ;;
    *)
      if [ -n "$ID" ]; then
        echo "error: unexpected argument '$a'" >&2
        usage
      fi
      ID=$a
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$ID" ] || usage
[ -n "$HARNESS" ] || { echo "error: --harness is required" >&2; exit 1; }

fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }

case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
[ ! -L "$META" ] || { echo "error: meta for task $ID is a symlink; refusing handoff" >&2; exit 1; }

KIND=$(fm_meta_get "$META" kind)
case "$KIND" in
  ship|scout) ;;
  secondmate)
    echo "error: task $ID is a secondmate; use secondmate recovery, not runtime handoff" >&2
    exit 1
    ;;
  *)
    echo "error: task $ID has unsupported kind='${KIND:-}' for runtime handoff" >&2
    exit 1
    ;;
esac

WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
OLD_HARNESS=$(fm_meta_get "$META" harness)
[ -n "$WT" ] || { echo "error: meta for $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: recorded worktree for $ID does not exist: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: recorded project for $ID does not exist: $PROJ" >&2; exit 1; }

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: original brief missing at $BRIEF; refusing handoff rather than regenerating it" >&2; exit 1; }

# Isolation: worktree must be a real git root distinct from the project primary.
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
WT_REAL=$(cd "$WT" 2>/dev/null && pwd -P) || WT_REAL=
PROJ_REAL=$(cd "$PROJ" 2>/dev/null && pwd -P) || PROJ_REAL=
WT_TOP_REAL=
[ -n "$WT_TOP" ] && WT_TOP_REAL=$(cd "$WT_TOP" 2>/dev/null && pwd -P) || true
if [ -z "$WT_REAL" ] || [ -z "$WT_TOP_REAL" ] || [ "$WT_REAL" != "$WT_TOP_REAL" ]; then
  echo "error: recorded worktree for $ID is not a usable git worktree root ($WT); refusing handoff" >&2
  exit 1
fi
if [ -n "$PROJ_REAL" ] && [ "$WT_REAL" = "$PROJ_REAL" ]; then
  echo "error: recorded worktree for $ID is the project primary checkout; refusing handoff to avoid tangling it" >&2
  exit 1
fi

if ! fm_control_harness_supports_kind "$HARNESS" "$KIND"; then
  echo "error: target harness '$HARNESS' is not a verified adapter for $KIND handoff; refuse rather than launching it" >&2
  exit 1
fi

if [ -n "$PROGRESS_NOTE_FILE" ]; then
  [ -f "$PROGRESS_NOTE_FILE" ] || { echo "error: --progress-note-file not found: $PROGRESS_NOTE_FILE" >&2; exit 1; }
  PROGRESS_NOTE=$(cat "$PROGRESS_NOTE_FILE")
fi
if [ -z "$PROGRESS_NOTE" ]; then
  PROGRESS_NOTE="No progress note was supplied. Inspect git status, git log, and the task status log, then continue from the original brief. Preserve all existing commits and uncommitted changes."
fi

# Exit command facts from harness-adapters (do not invent adapters here).
handoff_exit_spec() {  # <harness> -> prints "text:<cmd>" or "key:<key>"
  fm_control_exit_spec "$1" || return 1
  printf '\n'
}

# The recorded backend owns the recorded endpoint string: every ownership check
# below (state, exit, kill) must run through it. A --backend naming a different
# provider would read the old provider's target through the new provider, report
# missing, and leave the old agent alive beside the relaunched one, so refuse.
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
if [ -n "$BACKEND_ARG" ] && [ "$BACKEND_ARG" != "$BACKEND" ]; then
  echo "error: --backend '$BACKEND_ARG' differs from the backend recorded for $ID ('$BACKEND'); refusing handoff rather than checking the old endpoint through a different session provider" >&2
  exit 1
fi

agent_state_of() {
  if [ -z "$TARGET" ]; then
    printf 'missing\n'
    return 0
  fi
  fm_backend_agent_state "$BACKEND" "$TARGET"
}

wait_for_non_alive() {
  local i=0 max=${FM_HANDOFF_EXIT_POLLS:-30} interval=${FM_HANDOFF_EXIT_SLEEP:-0.5} st
  while [ "$i" -lt "$max" ]; do
    st=$(agent_state_of)
    case "$st" in
      dead|missing) printf '%s\n' "$st"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  agent_state_of
}

STATE_NOW=$(agent_state_of)
case "$STATE_NOW" in
  dead)
    :
    ;;
  missing)
    echo "error: recorded endpoint for $ID is missing; --reuse-worktree needs an existing agent-free endpoint" >&2
    exit 1
    ;;
  alive)
    if [ "$SKIP_EXIT" = 1 ]; then
      echo "error: endpoint for $ID is still alive and --skip-exit was set; refusing handoff" >&2
      exit 1
    fi
    if [ -z "$OLD_HARNESS" ]; then
      echo "error: meta for $ID has no harness= to select an exit command; refusing handoff while the endpoint is alive" >&2
      exit 1
    fi
    EXIT_HARNESS=$(fm_control_harness_family "$OLD_HARNESS") || {
      echo "error: no verified exit command for recorded harness '$OLD_HARNESS'; refuse rather than guess" >&2
      exit 1
    }
    EXIT_SPEC=$(handoff_exit_spec "$EXIT_HARNESS") || {
      echo "error: no verified exit command for recorded harness '$OLD_HARNESS'; refuse rather than guess" >&2
      exit 1
    }
    case "$EXIT_SPEC" in
      text:*)
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "${EXIT_SPEC#text:}" || {
          echo "error: could not deliver exit command to $ID; refusing handoff" >&2
          exit 1
        }
        ;;
      key:*)
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" --key "${EXIT_SPEC#key:}" || {
          echo "error: could not deliver exit key to $ID; refusing handoff" >&2
          exit 1
        }
        ;;
    esac
    STATE_NOW=$(wait_for_non_alive)
    case "$STATE_NOW" in
      dead) : ;;
      missing)
        echo "error: endpoint for $ID disappeared after exit attempt; refusing handoff because --reuse-worktree needs an existing endpoint" >&2
        exit 1
        ;;
      *)
        echo "error: endpoint for $ID is still '$STATE_NOW' after exit attempt; refusing handoff rather than splitting ownership" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    # ambiguous | unreadable | unverified | unknown
    echo "error: cannot reconcile endpoint ownership for $ID (agent state='$STATE_NOW'); refusing handoff rather than guessing" >&2
    exit 1
    ;;
esac

# Build a launch-only handoff prompt. Never rewrite the original brief file.
HANDOFF_PROMPT="$STATE/$ID.handoff-prompt"
{
  cat <<EOF
# Runtime handoff - continue this in-flight task

You are replacing a previous worker runtime on the SAME task identity, worktree, and branch.
Preserve every commit and every uncommitted change.
Do not create a new worktree. Do not start over from a clean tree.

## Progress so far

$PROGRESS_NOTE

## Active pipeline

If a no-mistakes validation run is active on this branch, re-attach with \`no-mistakes axi status\` and continue driving its gates.
Never start a second run as part of this handoff.
Never abort or restart a live pipeline as part of this handoff.

## Original brief

The original brief file is unchanged at:
$BRIEF

Follow it exactly. Its full content is included below for convenience.

---
EOF
  cat "$BRIEF"
} > "$HANDOFF_PROMPT"

# Relaunch in place through spawn's reuse path (preserves treehouse lease).
SPAWN_ARGS=(
  "$ID"
  --reuse-worktree
  --harness "$HARNESS"
  --handoff-brief "$HANDOFF_PROMPT"
)
[ -z "$MODEL" ] || SPAWN_ARGS+=(--model "$MODEL")
[ -z "$EFFORT" ] || SPAWN_ARGS+=(--effort "$EFFORT")
[ -z "$BACKEND_ARG" ] || SPAWN_ARGS+=(--backend "$BACKEND_ARG")
# When no explicit backend, spawn --reuse-worktree keeps the recorded backend,
# which is the only backend an explicit --backend is allowed to name here.

if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-spawn.sh" "${SPAWN_ARGS[@]}"; then
  echo "error: in-place relaunch failed for $ID; worktree and unlanded work were left intact" >&2
  exit 1
fi

printf 'handed-off %s from harness=%s to harness=%s worktree=%s\n' \
  "$ID" "${OLD_HARNESS:-unknown}" "$HARNESS" "$WT"
printf 'working: runtime handoff to %s; continue from original brief\n' "$HARNESS" >> "$STATE/$ID.status" || true
