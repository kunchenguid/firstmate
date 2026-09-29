#!/usr/bin/env bash
# fm-spawn.sh - launch an isolated ship or scout task.
#
# Usage:
#   fm-spawn.sh <task-id> [<project-directory>] [--scout]
#     [--harness <pi|codex|traex|launch-command>] [--model <name>]
#     [--effort <level>] [--backend <name>]
#     [--mode <no-mistakes|direct-PR|local-only>] [--yolo <on|off>]
#   fm-spawn.sh --relaunch <task-id> [--harness <name>] [--model <name>]
#     [--effort <level>]
#
# Fresh ship spawns require an explicit delivery mode and yolo posture. Scouts
# accept neither. Relaunch reuses the recorded task identity, backend, project,
# worktree, kind, delivery posture, and endpoint. Historical persistent-home
# records are preserved and refused before any lifecycle action.
#
# Every local-agent spawn validates that its task worktree is distinct from the
# primary checkout. Dispatch profiles, backend selection, trace propagation,
# backlog transitions, launch environment allowlisting, and provider-specific
# harness flags are resolved and recorded by the owners sourced below.
#
# On success prints:
#   spawned <id> harness=<name> kind=<ship|scout> [mode=<mode> yolo=<on|off>]
#     window=<backend-target> worktree=<path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
  /*)
    printf '%s\n' "$path"
    return 0
    ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_HOME=$(resolve_directory_input FM_HOME "$FM_HOME") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  FM_STATE_OVERRIDE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_DATA_OVERRIDE=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
fm_config_source_present() {
  perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect configuration source at $ARGV[0]: $!\n" }
  ' -- "$1"
}
if ! LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-allowlist"); then
  exit 1
fi
LAUNCH_ENV_NAMES=
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  if [ ! -f "$CONFIG/launch-env-allowlist" ] || [ ! -r "$CONFIG/launch-env-allowlist" ]; then
    echo "error: config/launch-env-allowlist must be a readable regular file" >&2
    exit 1
  fi
  if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
    split("\n") | map(select(. != "" and (startswith("#") | not))) |
    if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
    else error("expected environment names only") end
  ' "$CONFIG/launch-env-allowlist" 2>/dev/null); then
    echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
    exit 1
  fi
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
KIND_SET=0
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
MODE=
YOLO=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
RELAUNCH=0
LIFECYCLE_ACTION_ID=${FM_CONTROL_ACTION_ID:-}
LIFECYCLE_EXPECTED_GEN=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
    --*)
      echo "error: --$want_value requires a value" >&2
      exit 1
      ;;
    esac
    case "$want_value" in
    action-id) LIFECYCLE_ACTION_ID=$a ;;
    expected-generation) LIFECYCLE_EXPECTED_GEN=$a ;;
    harness)
      HARNESS_ARG=$a
      HARNESS_SET=1
      ;;
    model)
      MODEL=$a
      MODEL_SET=1
      ;;
    effort)
      EFFORT=$a
      EFFORT_SET=1
      ;;
    backend)
      BACKEND_ARG=$a
      BACKEND_SET=1
      ;;
    mode)
      MODE=$a
      MODE_SET=1
      ;;
    yolo)
      YOLO=$a
      YOLO_SET=1
      ;;
    *)
      echo "error: internal parser state for --$want_value" >&2
      exit 1
      ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
  --action-id) want_value=action-id ;;
  --expected-generation) want_value='expected-generation' ;;
  --scout)
    KIND=scout
    KIND_SET=1
    ;;
  --relaunch) RELAUNCH=1 ;;
  --harness) want_value=harness ;;
  --harness=*)
    HARNESS_ARG=${a#--harness=}
    HARNESS_SET=1
    ;;
  --model) want_value=model ;;
  --model=*)
    MODEL=${a#--model=}
    MODEL_SET=1
    ;;
  --effort) want_value=effort ;;
  --effort=*)
    EFFORT=${a#--effort=}
    EFFORT_SET=1
    ;;
  --backend) want_value=backend ;;
  --backend=*)
    BACKEND_ARG=${a#--backend=}
    BACKEND_SET=1
    ;;
  --mode) want_value=mode ;;
  --mode=*)
    MODE=${a#--mode=}
    MODE_SET=1
    ;;
  --yolo) want_value=yolo ;;
  --yolo=*)
    YOLO=${a#--yolo=}
    YOLO_SET=1
    ;;
  *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || {
  echo "error: --$want_value requires a value" >&2
  exit 1
}
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || {
  echo "error: --harness requires a non-empty value" >&2
  exit 1
}
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || {
  echo "error: --model requires a non-empty value" >&2
  exit 1
}
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || {
  echo "error: --effort requires a non-empty value" >&2
  exit 1
}
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || {
  echo "error: --backend requires a non-empty value" >&2
  exit 1
}
[ "$MODE_SET" -eq 0 ] || [ -n "$MODE" ] || {
  echo "error: --mode requires a non-empty value" >&2
  exit 1
}
[ "$YOLO_SET" -eq 0 ] || [ -n "$YOLO" ] || {
  echo "error: --yolo requires a non-empty value" >&2
  exit 1
}
case "$EFFORT" in
'' | low | medium | high | xhigh | max | ultra) ;;
*)
  echo "error: --effort must be one of low, medium, high, xhigh, max, ultra" >&2
  exit 1
  ;;
esac

# --relaunch reuses an existing task's endpoint, worktree, project, and kind,
# so every axis this block resolves for a fresh spawn instead comes from that
# task's own durable record below. Contradicting it on the command line is a
# refusal rather than a silently-ignored flag.
if [ "$RELAUNCH" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded backend; --backend cannot override it" >&2
    exit 1
  }
  [ "$KIND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded kind; --scout cannot override it" >&2
    exit 1
  }
  [ "$MODE_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it" >&2
    exit 1
  }
  [ "$YOLO_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it" >&2
    exit 1
  }
else
  # Delivery contract (AGENTS.md section 7). A ship task's mode and yolo are
  # firstmate's per-task decision, so they are required and closed-set validated
  # here rather than resolved from the project registry. Scouts deliver a report
  # and record no delivery posture.
  if [ "$KIND" = ship ]; then
    [ "$MODE_SET" -eq 1 ] || {
      echo "error: ship spawns require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 1 ] || {
      echo "error: ship spawns require --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
      exit 1
    }
    case "$MODE" in
    no-mistakes | direct-PR | local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1
      ;;
    *)
      echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2
      exit 1
      ;;
    esac
    case "$YOLO" in
    on | off) ;;
    *)
      echo "error: --yolo must be on or off (got '$YOLO')" >&2
      exit 1
      ;;
    esac
  else
    [ "$MODE_SET" -eq 0 ] || {
      echo "error: --mode applies only to ship spawns; a scout delivers a report" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 0 ] || {
      echo "error: --yolo applies only to ship spawns; a scout delivers a report" >&2
      exit 1
    }
  fi
fi

BACKEND=
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_CONTROL_LOCK=
SPAWN_CONTROL_LOCK_HELD=0
SPAWN_CONTROL_PARENT=0
SPAWN_META_TMP=
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_FRESH_COMMIT_PENDING=0
SPAWN_LAUNCH_ATTEMPTED=0
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
SPAWN_TREEHOUSE_PROJECT_LOCK=
SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
SPAWN_SLOT_CLAIMED=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=

spawn_fresh_commit_rollback() {
  if [ "$SPAWN_LAUNCH_ATTEMPTED" = 1 ]; then
    echo "error: launch submission was attempted; retaining $ID's original task and busy bindings for reconciliation" >&2
    return 1
  fi
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
    "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}



spawn_abort_cleanup() {
  local status=$?
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] &&
    [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] &&
    [ -n "$SPAWN_META_TMP" ] &&
    [ ! -e "$SPAWN_META_TMP" ] &&
    [ ! -L "$SPAWN_META_TMP" ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
      "$RELAUNCH_REPLACEMENT_HARNESS" \
      "$RELAUNCH_REPLACEMENT_WT" \
      "$RELAUNCH_REPLACEMENT_STATE" \
      "$ID"; then
      echo "warning: could not remove replacement wiring after aborted relaunch of $ID" >&2
    fi
    if [ -n "$RELAUNCH_REPLACEMENT_BUSY_GEN" ]; then
      if ! "$FM_ROOT/bin/fm-busy-event.sh" retire \
        "$RELAUNCH_REPLACEMENT_STATE" "$ID" \
        --gen "$RELAUNCH_REPLACEMENT_BUSY_GEN"; then
        echo "warning: could not retire replacement busy generation after aborted relaunch of $ID" >&2
      fi
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] &&
    [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    if [ "$SPAWN_LAUNCH_ATTEMPTED" = 1 ]; then
      # Enter transport, trust and readiness failures cannot prove the worker
      # never started. Keep the publication and original generations even if
      # backlog reconciliation fails; deleting evidence cannot undo a launch.
      SPAWN_FRESH_COMMIT_PENDING=0
      FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
      if ! spawn_commit_backlog_transition; then
        echo "error: preserved task $ID needs backlog reconciliation: $FM_BACKLOG_TRANSITION_ERROR" >&2
      fi
      echo "error: preserved unconfirmed launch $ID at $T; inspect trust and reconcile the existing worker, do not fresh-spawn" >&2
    elif ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
  fi
  # A spawn that aborts after claiming its slot but before its record survives
  # must not leave a claim naming a task no record describes. The release is a
  # read-then-remove, so it runs only while the project lock that wrote the
  # claim is still held (aborts before metadata publication); a later abort has
  # already released that lock and leaves the claim for the next spawn's
  # atomic replacement rather than racing it. The release itself never removes
  # another task's claim.
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] &&
    fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    SPAWN_SLOT_CLAIMED=0
    if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
    else
      echo "warning: leaving task $ID's slot claim on $WT in place; the Treehouse project lock is no longer held, so the next spawn's claim replaces it" >&2
    fi
  fi
  if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
    fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
  fi
  if [ "$SPAWN_CONTROL_LOCK_HELD" = 1 ]; then
    SPAWN_CONTROL_LOCK_HELD=0
    fm_lock_release "$SPAWN_CONTROL_LOCK" || true
  fi
  [ -z "$SPAWN_META_TMP" ] || rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One bounded lock per live Herdr session/socket.
spawn_herdr_presentation_order_lock_acquire() {
  local session=${1:-} attempt lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$HERDR_PRESENTATION_ORDER_LOCK"; then
      HERDR_PRESENTATION_ORDER_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

clear_relaunch_harness_wiring() {
  local harness=$1 wt=$2 state=$3 id=$4 path
  fm_control_require_recoverable_harness "$harness" || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_paths "$harness" "$wt" "$state" "$id")
EOF
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "$RELAUNCH" -eq 1 ] && [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ]; then
  echo "error: --relaunch is single-task only; relaunch each task explicitly" >&2
  exit 1
fi
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac then
  if [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  # One delivery contract applies to every pair in a batch, exactly like the shared
  # harness. Each pair still re-validates it against its own brief, so a batch
  # spanning several modes is two invocations rather than a silent mixed dispatch.
  [ "$MODE_SET" -eq 0 ] || shared_args+=(--mode "$MODE")
  [ "$YOLO_SET" -eq 0 ] || shared_args+=(--yolo "$YOLO")
  for pair in "${POS[@]}"; do
    case "$pair" in
    *=*) : ;;
    *)
      echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2
      rc=2
      continue
      ;;
    esac
    if [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else
        echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2
        rc=1
      fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else
        echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2
        rc=1
      fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || {
  echo "error: invalid task id" >&2
  exit 2
}
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
elif [ "$RELAUNCH" -eq 1 ]; then
  echo "error: spawn refused: state directory does not exist at $STATE" >&2
  exit 1
fi
# Role partition: spawning NEW work is MAIN-owned. A relaunch of an existing
# task is legitimate branch recovery (fm-control drives it through this same
# entrypoint), so only a fresh spawn refuses the branch actor (contract:
# bin/fm-lease-lib.sh; no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$RELAUNCH" -ne 1 ]; then
  fm_lease_forbid_branch "new-task spawn (fm-spawn)"
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_CONTROL_LOCK="$STATE/.control-$ID.lock"
  control_owner=$(cat "$SPAWN_CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
    SPAWN_CONTROL_PARENT=1
  elif [ "$(fm_lease_actor)" = branch ]; then
    # Role partition refinement: branch recovery relaunches only through the
    # fm-control transaction that owns the control lock, never by invoking
    # this entrypoint directly (contract: bin/fm-lease-lib.sh).
    echo "error: relaunch (fm-spawn) refused - the supervision branch must relaunch through fm-control" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  elif fm_lock_try_acquire "$SPAWN_CONTROL_LOCK"; then
    SPAWN_CONTROL_LOCK_HELD=1
  else
    echo "error: another lifecycle action is already running for task $ID" >&2
    exit 1
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  mkdir -p "$STATE" || {
    echo "error: could not create parent state directory" >&2
    exit 1
  }
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  # A FRESH spawn changes which tasks this home has, so it must not interleave
  # with a forced teardown that has already enumerated that set: a record
  # published inside the enumerate-then-remove window is invisible to the
  # teardown's per-task preflight but visible to its cleanup, and gets mutated
  # while never lifecycle-locked (bin/fm-wake-lib.sh's fm_task_set_lock_path
  # owns the evidence; bin/fm-teardown.sh holds the same lock from enumeration
  # through cleanup). Taken before this task's own locks, matching the
  # acquisition order documented there, and held through publication.
  #
  # A relaunch is exempt: it republishes a task that already exists, so it is
  # already covered by that task's control lock, which the teardown preflight
  # tests.
  #
  # Refusing rather than waiting is the fail-closed direction: the home may be
  # moments from removal, so there is nothing worth waiting for.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
    echo "error: could not resolve the task-set lock for $STATE" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK"; then
    echo "error: this home's task set is locked by another operation (a forced teardown is enumerating or removing its tasks); refusing to create task $ID rather than racing it" >&2
    exit 1
  fi
  SPAWN_TASK_SET_LOCK_HELD=1
fi
# New intake uses the Herdr-only selector. Historical relaunch validates its
# recorded identity below and never coerces a retired backend.
if [ "$RELAUNCH" -eq 0 ]; then
  if [ "$BACKEND_SET" -eq 1 ]; then
    BACKEND=$BACKEND_ARG
  else
    BACKEND=$(fm_backend_name)
  fi
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
# A fresh intake may recover an agent-free recorded Herdr endpoint, but never
# overwrite an old backend identity or create a second agent under the same id.
# Check before worktree allocation.
if [ "$RELAUNCH" -eq 0 ] && { [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; }; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  fm_backend_validate_task_endpoint "$STATE/$ID.meta" "$ID" || exit 1
  existing_pane=${FM_BACKEND_VALIDATED_TARGET#*:}
  existing_session=${FM_BACKEND_VALIDATED_TARGET%%:*}
  existing_state=$(fm_backend_herdr_pane_agent_state "$existing_session" "$existing_pane")
  case "$existing_state" in
    dead|no-agent) ;;
    *)
      echo "error: existing Herdr endpoint for $ID is $existing_state; refusing duplicate launch" >&2
      exit 1
      ;;
  esac
fi
PROJ=
ARG3=
RAW_LAUNCH=0

# --relaunch adoption: every identity axis comes from the task's own validated
# durable record, never from the command line, so a relaunch can only ever
# re-launch the task it names. The endpoint identity check is the same shared
# validation teardown uses, so a malformed, ambiguous, or foreign record
# refuses here exactly as it refuses there.
RELAUNCH_PRIOR_HARNESS=
if [ "$RELAUNCH" -eq 1 ]; then
  [ "${#POS[@]}" -eq 1 ] || {
    echo "error: --relaunch takes the task id only; its project or home comes from the task's own record" >&2
    exit 1
  }
  RELAUNCH_META="$STATE/$ID.meta"
  if [ ! -e "$RELAUNCH_META" ] && [ ! -L "$RELAUNCH_META" ]; then
    echo "error: --relaunch needs an existing task record; no $RELAUNCH_META" >&2
    exit 1
  fi
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  SPAWN_META_LOCK=$(fm_meta_lock_path "$RELAUNCH_META") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  fm_control_require_recoverable_harness "$(fm_meta_get "$RELAUNCH_META" harness)" || exit 1
  fm_backend_validate_task_endpoint "$RELAUNCH_META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  RELAUNCH_TARGET=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  # A relaunch must PROVE the previous agent is gone before it launches another
  # one into the same endpoint, and Herdr has a recovery-grade
  # classifier that can (bin/fm-control-lib.sh owns that capability table).
  fm_control_backend_state_verified "$BACKEND" || {
    echo "error: backend '$BACKEND' has no recovery-grade agent-state classifier, so a relaunch cannot prove the previous agent exited; refusing rather than risking two agents in one endpoint" >&2
    exit 1
  }
  RELAUNCH_STATE=$(fm_backend_agent_state "$BACKEND" "$RELAUNCH_TARGET")
  [ "$RELAUNCH_STATE" = dead ] || {
    echo "error: task $ID's endpoint reads '$RELAUNCH_STATE'; a relaunch requires a positively agent-free endpoint (stop the agent first with bin/fm-control.sh $ID exit)" >&2
    exit 1
  }
  RELAUNCH_PRIOR_HARNESS=$(fm_meta_get "$RELAUNCH_META" harness)
  KIND=$(fm_meta_get "$RELAUNCH_META" kind)
  [ -n "$KIND" ] || KIND=ship
  [ "$KIND" != secondmate ] || {
    echo "error: task $ID is a historical secondmate record; relaunch is no longer supported" >&2
    exit 1
  }
  MODE=$(fm_meta_get "$RELAUNCH_META" mode)
  YOLO=$(fm_meta_get "$RELAUNCH_META" yolo)
  RELAUNCH_WT=$(fm_meta_get "$RELAUNCH_META" worktree)
  [ -n "$RELAUNCH_WT" ] && [ -d "$RELAUNCH_WT" ] || {
    echo "error: task $ID's recorded worktree '${RELAUNCH_WT:-none}' is missing; refusing to relaunch without the local copy its work lives in" >&2
    exit 1
  }
  PROJ=$(fm_meta_get "$RELAUNCH_META" project)
  [ -n "$PROJ" ] || {
    echo "error: task $ID has no recorded project; refusing to relaunch" >&2
    exit 1
  }
  if [ "$BACKEND" = herdr ]; then
    HERDR_SES=$(fm_meta_get "$RELAUNCH_META" herdr_session)
    HERDR_WORKSPACE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_workspace_id)
    HERDR_TAB_ID=$(fm_meta_get "$RELAUNCH_META" herdr_tab_id)
    HERDR_PANE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_pane_id)
  fi
  # With no explicit harness, a relaunch reuses the harness already recorded
  # for this task. It must NOT fall through to the fresh-spawn config
  # resolution, which would silently move an existing task onto the current
  # crew default. Choosing a different harness is the caller's explicit decision,
  # made with --harness (bin/fm-control.sh resolves that decision).
  ARG3=${HARNESS_ARG:-$RELAUNCH_PRIOR_HARNESS}
  [ -n "$ARG3" ] || {
    echo "error: task $ID has no recorded harness; pass --harness to relaunch it" >&2
    exit 1
  }
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolve_pi_executable() {
  local candidate dir
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
  /*) printf '%s\n' "$candidate" ;;
  *)
    dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$dir" "$(basename "$candidate")"
    ;;
  esac
}

# Pi's CLI surface is version-dependent, so probe the resolved executable's help
# before composing the optional regular-TUI flag. An absent or inconclusive probe
# omits the flag so older Pi versions can still spawn.
pi_supports_tui_mode() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--tui-mode([[:space:]=]|$)'
}

# The verified launch command per adapter. The knowledge half of each adapter
# (busy-state source, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1
  # shellcheck disable=SC2016
  case "$harness" in
    codex)
      printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)__BUSYMARKER__"'
      ;;
    pi)
      printf '%s' '__PIBIN____PITUIMODE__'
      printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      ;;
    traex) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS FM_TRAEX_HARNESS=traex traex -y __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)__BUSYMARKER__"' ;;
    *) return 1 ;;
  esac
}

RAW_LAUNCH=0
RAW_TRAEX=0
case "$ARG3" in
*' '*) # raw launch command (unverified-adapter escape hatch)
  RAW_LAUNCH=1
  LAUNCH=$ARG3
  HARNESS=""
  # This bounded lexical check covers direct and ordinary shell-wrapped TraeX
  # commands. Deliberately constructed interpreter code is outside the
  # supported detection guarantee; preserving general raw execution is the
  # captain-approved boundary.
  canonical=${LAUNCH//\'/}
  canonical=${canonical//\"/}
  canonical=${canonical//\\/}
  [[ "$canonical" =~ (^|[^[:alnum:]_.-])traex([^[:alnum:]_.-]|$) ]] && RAW_TRAEX=1
  if [[ "$canonical" =~ (^|[^[:alnum:]_.-])(claude|opencode|grok|kimi|cursor|cursor-agent|gemini|muse|muse-bin-[[:alnum:]_.-]+|rovo|rovodev|omp|agy|pi-signed)([^[:alnum:]_.-]|$) ]]; then
    echo "error: removed harness command '${BASH_REMATCH[2]}'; select pi, codex, or traex explicitly" >&2
    exit 1
  fi
  for word in $LAUNCH; do
    case "$word" in [A-Za-z_]*=*) continue ;; *)
      HARNESS=$(basename "$word")
      break
      ;;
    esac
  done
  ;;
'')
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew) || exit 1
  harness_src='config/crew-harness'
  LAUNCH=$(launch_template "$HARNESS" "$KIND") || {
    echo "error: unsupported harness '$HARNESS' (from $harness_src or detection); select pi, codex, or traex explicitly; historical work is preserved" >&2
    exit 1
  }
  ;;
*)
  HARNESS=$ARG3
  LAUNCH=$(launch_template "$HARNESS" "$KIND") || {
    echo "error: unsupported harness '$HARNESS'; select pi, codex, or traex explicitly; historical work is preserved" >&2
    exit 1
  }
  ;;
esac

case "$HARNESS" in
pi)
  PI_BIN=$(resolve_pi_executable "$HARNESS") || {
    echo "error: $HARNESS executable not found on PATH; install it or select a different verified harness" >&2
    exit 1
  }
  PI_TUI_MODE=
  if pi_supports_tui_mode "$PI_BIN"; then
    PI_TUI_MODE=' --tui-mode regular'
  fi
  LAUNCH=${LAUNCH//__PITUIMODE__/$PI_TUI_MODE}
  LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH"
  ;;
esac
# TraeX intentionally follows the ordinary harness contract rather than owning
# a backend lifecycle subsystem. Refuse its narrow unsupported surfaces before
# any endpoint is created; Herdr then supplies the same generic pane, process,
# input, liveness, busy-state, and cleanup operations used by Codex.
if [ "$RAW_TRAEX" -eq 1 ]; then
  echo "error: TraeX must use Firstmate's verified launch template; raw TraeX launch commands remain unverified" >&2
  exit 1
fi
if [ "$HARNESS" = traex ]; then
  if [ "$RAW_LAUNCH" -eq 1 ]; then
    echo "error: TraeX must use Firstmate's verified launch template; raw TraeX launch commands remain unverified" >&2
    exit 1
  fi
  if [ "$BACKEND" != herdr ]; then
    echo "error: traex workers are verified only on backend=herdr; backend=$BACKEND is unsupported" >&2
    exit 1
  fi
  if [ "$EFFORT" = max ]; then
    echo "error: traex supports --effort low, medium, high, or xhigh; max is not verified and is refused" >&2
    exit 1
  fi
  if ! command -v traex >/dev/null 2>&1; then
    echo "error: traex executable not found on PATH; install TraeX or select a different verified harness" >&2
    exit 1
  fi
fi

# Ultra is an explicit native capability, never a Pi thinking-level alias.
# Validate the fully resolved profile before worktree or endpoint provisioning.
if [ "$EFFORT" = ultra ]; then
  "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$HARNESS" "$MODEL" "$EFFORT" || exit 1
  [ "$RAW_LAUNCH" = 0 ] || {
    echo "error: --effort ultra requires the canonical --harness pi launch so its native flag cannot be omitted" >&2
    exit 1
  }
fi
model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
  codex | pi | traex)
    printf -- '--model %s ' "$(shell_quote "$model")"
    ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2 model=${3:-}
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
  codex)
    # The installed codex config schema uses model_reasoning_effort. The
    # installed model catalog supports max for gpt-5.6-luna; keep that level
    # scoped to the model whose catalog entry advertises it.
    case "$effort" in
    low | medium | high | xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
    max)
      [ "$model" = gpt-5.6-luna ] || return 0
      printf -- '-c %s ' "$(shell_quote 'model_reasoning_effort="max"')"
      ;;
    esac
    ;;
  traex)
    # TraeX exposes model_reasoning_effort through -c for the verified
    # low|medium|high|xhigh values. Its unsupported max value is refused by
    # profile validation before an endpoint is created.
    case "$effort" in
    low | medium | high | xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
    esac
    ;;
  pi)
    # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
    # its --thinking flag.
    case "$effort" in
    ultra)
      "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
      printf -- '--codex-effort %s ' "$(shell_quote ultra)"
      ;;
    low | medium | high | xhigh | max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  esac
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
  projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
  *) printf '%s\n' "$path" ;;
  esac
}

PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
WT=""
BRIEF="$DATA/$ID/brief.md"
if [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve the shared Treehouse project lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
    echo "error: another Treehouse slot allocation or return is in progress for $PROJ_ABS; refusing to race it" >&2
    exit 1
  fi
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
fi
[ -f "$BRIEF" ] || {
  echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2
  exit 1
}
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  if fm_brief_task_placeholders_present "$BRIEF"; then
    echo "error: $BRIEF still contains {TASK} or {FIRSTMATE_SPEC}; fill ## Captain's intent and ## Firstmate spec before spawn" >&2
    exit 1
  fi
  if ! fm_brief_task_content_valid "$BRIEF"; then
    echo "error: $BRIEF must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before spawn" >&2
    exit 1
  fi
  if ADDRESS_LINE=$(fm_brief_intent_address_line "$BRIEF"); then
    echo "error: $BRIEF ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before spawn, since the heading already records provenance" >&2
    exit 1
  fi
  if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
    if fm_brief_task_heading_present "$BRIEF" "## Captain's intent"; then
      CAPTAIN_INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
    else
      LEGACY_TASK_BODY=$(fm_brief_heading_body "$BRIEF" "# Task")
      CAPTAIN_INTENT=$(fm_brief_marked_captain_words "$LEGACY_TASK_BODY")
      if [ -z "$(printf '%s' "$CAPTAIN_INTENT" | tr -d '[:space:]')" ]; then
        echo "error: legacy mixed # Task brief has no provenance-marked captain words for no-mistakes --intent; add [captain] lines or migrate to ## Captain's intent and ## Firstmate spec" >&2
        exit 1
      fi
    fi
  fi
  # Use the existing launch-brief overlay for every worker kind, including
  # pre-scope briefs and relaunches. Charters never enter this worker path.
  SOURCE_BRIEF=$BRIEF
  BRIEF="$DATA/$ID/launch-brief.md"
  BRIEF_TMP="$DATA/$ID/.launch-brief.md.${BASHPID:-$$}"
  {
    fm_brief_worker_role "$STATE" "$ID" &&
      printf '\n' &&
      cat "$SOURCE_BRIEF" &&
      if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
        fm_brief_intent_overlay "$CAPTAIN_INTENT"
      fi
  } >"$BRIEF_TMP" || {
    rm -f -- "$BRIEF_TMP"
    echo "error: could not render current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  }
  if ! mv "$BRIEF_TMP" "$BRIEF"; then
    rm -f -- "$BRIEF_TMP"
    echo "error: could not publish current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  fi
fi

delivery_rigor_rank() { # <mode> -> 3 (most rigor) .. 1 (least); 0 = not a task mode
  case "$1" in
  no-mistakes) echo 3 ;;
  direct-PR) echo 2 ;;
  local-only) echo 1 ;;
  *) echo 0 ;;
  esac
}

# Brief/spawn delivery agreement, checked before any endpoint exists.
# fm-brief.sh records a ship brief's mode as a fixed "Delivery contract: mode=<mode>"
# line. A spawn that disagrees would launch a worker whose instructions and whose
# recorded task delivery differ, which is the exact drift this contract prevents.
if [ "$KIND" = ship ]; then
  PROJ_NAME=$(basename "$PROJ_ABS")
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  if [ -z "$BRIEF_MODE" ]; then
    echo "warning: $BRIEF records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode $MODE - confirm its definition of done matches" >&2
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    echo "error: delivery mismatch for $ID: the brief says mode=$BRIEF_MODE but this spawn passed --mode $MODE; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree" >&2
    exit 1
  fi
  # The registry holds the captain's standing posture, so dropping below it is
  # allowed (a current explicit captain instruction wins) but never silent. An
  # unregistered project resolves to the same no-mistakes standing default, which
  # is why the notice names the standing posture rather than the registry line. A
  # conditional policy is excluded: both of its legs are legitimate classifications.
  STANDING_MODE=$("$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJ_NAME" 2>/dev/null | cut -d' ' -f1) || STANDING_MODE=
  if [ -n "$STANDING_MODE" ] && [ "$STANDING_MODE" != no-mistakes-prod-only ] &&
    [ "$(delivery_rigor_rank "$MODE")" -lt "$(delivery_rigor_rank "$STANDING_MODE")" ]; then
    echo "notice: $ID ships mode=$MODE while the standing posture for $PROJ_NAME is $STANDING_MODE - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
fi

BRIEF_DIR_REAL=$(cd "$(dirname "$BRIEF")" && pwd -P)
BRIEF_REAL="$BRIEF_DIR_REAL/$(basename "$BRIEF")"

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Herdr's foreground_cwd read can report the OS-level, physically-resolved cwd,
# so comparing it against a still-symlinked PROJ_ABS can misfire both ways:
# false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Session-provider container-ensure + task creation. A Herdr spawn goes through
# the version-gated single-home workspace and tab-per-task sequence in
# bin/backends/herdr.sh. Downstream operations treat the resulting $T ("target")
# string as opaque routing resolved by fm_backend_resolve_selector.

# True when <path> is an isolated worktree of the spawning project: a real
# directory that is its own worktree root, is not the spawning project itself,
# and does not share the project repository's common git dir. SPAWN_WT_TOP is
# left holding the worktree root the check read, and SPAWN_WT_REASON a short
# phrase naming why a rejected path failed, both for the refusal messages.
#
# The worktree-discovery poll below reads this same predicate, so it can never
# adopt a path the guard would then refuse. That matters because a pane's cwd
# read is a snapshot of whatever process is in the foreground: while `treehouse
# get` is still fetching and checking a slot out, it reports the REPOSITORY's
# primary checkout as its own cwd. That path differs from a linked spawning
# project, so a poll comparing only against the project accepted it, and the
# guard then refused a launch whose slot treehouse went on to create normally.
# A read like that is a transient, not a destination: the poll keeps waiting.
SPAWN_WT_TOP=
SPAWN_WT_REASON=
spawn_worktree_isolated() { # <path>
  local path=$1 wt_real wt_top_real wt_git_dir proj_common
  SPAWN_WT_TOP=
  SPAWN_WT_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    SPAWN_WT_REASON="it is not a readable directory"
    return 1
  fi
  SPAWN_WT_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to fm-spawn's OWN cwd and report the path as a subdirectory
  # of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$SPAWN_WT_TOP" ] && ! wt_top_real=$(cd "$SPAWN_WT_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  if [ "$wt_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_REASON="it is the spawning project itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked spawning home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$PROJ_ABS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    SPAWN_WT_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    SPAWN_WT_REASON="it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
    return 1
  fi
  return 0
}

validate_spawn_worktree() { # <source> <inspect-target>
  local source=$1 inspect_target=$2
  if ! spawn_worktree_isolated "$WT"; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${SPAWN_WT_TOP:-none}'; spawning project '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# A pooled slot whose only deviation is a submodule gitlink is stale, not dirty:
# an earlier refresh moved the superproject and left the submodule checkout on
# the pin the previous base recorded. The refusal still stands and this gate
# never touches the slot; it only names the cause, because "is not clean" while
# the operator's own `git status` reads clean gives neither a cause nor a remedy.
# A pin is only reported as stale when the commit the slot holds is already
# contained in one of the submodule's remotes. Anything that cannot be proven
# contained - an unpushed commit, a submodule with no remote, a git error - falls
# through to the conservative uncommitted-work refusal, as does any entry that is
# not exactly a clean submodule sitting on a different pin. The diagnosis is
# buffered and only emitted once every entry qualifies, so it can never
# contradict the verdict.
#
# No remedy command is printed, deliberately. That containment check reads local
# refs only and never fetches, because this gate has to stay usable offline. A
# remote-tracking ref that has gone stale - its upstream branch deleted or
# force-pushed, and never pruned - therefore still reads as containment, so a
# commit that is really unpushed can look contained. Naming the submodule and both
# pins is what the operator actually needs; printing a checkout command on a
# judgement that can be fooled could cost them that commit, so the remedy is left
# to the operator, who can see the whole picture.
describe_stale_submodule_pins() { # <worktree> <status>
  local worktree=$1 status=$2 line path want have unpushed lines=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in ' M '*) path=${line#' M '} ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" ls-files --stage -- "$path" 2>/dev/null | cut -c1-6)" = 160000 ] || return 1
    [ -z "$(git -C "$worktree/$path" status --porcelain 2>/dev/null)" ] || return 1
    want=$(git -C "$worktree" rev-parse --verify --quiet "HEAD:$path" 2>/dev/null) || return 1
    have=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ "$want" != "$have" ] || return 1
    unpushed=$(git -C "$worktree/$path" log --format=%H --max-count=1 "$have" --not --remotes -- 2>/dev/null) || return 1
    [ -z "$unpushed" ] || return 1
    lines+="error: submodule '$path' is checked out at $have, but this base records $want"$'\n'
  done <<EOF
$status
EOF
  [ -n "$lines" ] || return 1
  printf '%s' "$lines" >&2
}

spawn_worktree_has_origin_config() { # <worktree>
  # Resolved remote.origin.* variables cover Git's effective include/includeIf chain; raw headers are also detected in the worktree config and any included file Git names through another variable. Git cannot enumerate a variable-less included file, so an empty origin section that is its only content remains indistinguishable from absence and intentionally proceeds rather than reimplementing Git's config parser.
  local worktree=$1 config origin key seen=$'\n'
  git -C "$worktree" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r origin key; do
    case $origin in file:*) config=${origin#file:} ;; *) continue ;; esac
    [ -f "$config" ] || continue
    case $seen in *$'\n'"$config"$'\n'*) continue ;; esac
    seen+="$config"$'\n'
    awk '/^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"[[:space:]]*\][[:space:]]*([#;].*)?$/ || /^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee]\.origin[[:space:]]*\][[:space:]]*([#;].*)?$/ { found=1 } END { exit !found }' "$config" && return 0
  done < <(git -C "$worktree" config --list --show-origin 2>/dev/null || true)
  return 1
}

freshen_spawn_worktree_base() { # <worktree>
  local worktree=$1 default target expected actual status
  status=$(git -C "$worktree" -c core.quotePath=false status --porcelain) || {
    echo "error: could not inspect pooled worktree '$worktree' before refreshing its base" >&2
    return 1
  }
  if [ -n "$status" ]; then
    if describe_stale_submodule_pins "$worktree" "$status"; then
      echo "error: pooled worktree '$worktree' has a stale submodule checkout, not uncommitted work; refusing to launch and leaving it untouched" >&2
    else
      echo "error: pooled worktree '$worktree' is not clean; refusing to discard uncommitted work while refreshing its base" >&2
    fi
    return 1
  fi
  if ! spawn_worktree_has_origin_config "$worktree"; then
    return 0
  fi
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
    echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  default=$(fm_default_branch "$worktree") || {
    echo "error: could not determine origin's default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  target="origin/$default"
  if ! git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    echo "error: could not fetch '$target' for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  expected=$(git -C "$worktree" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    echo "error: '$target' is not a commit for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  if ! git -C "$worktree" reset --hard "$target" >/dev/null; then
    echo "error: could not reset pooled worktree '$worktree' to '$target'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree '$worktree' is at '${actual:-unknown}', not current '$target' ('$expected'); refusing to launch" >&2
    return 1
  fi
}

herdr_projection_meta_field_exact() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower structurally bound reclaim path.
herdr_projection_existing_meta_allows_flat() { # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  HERDR_RECOVERY_BACKEND=$old_backend
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    target_session=$FM_BACKEND_HERDR_SESSION
    target_pane=$FM_BACKEND_HERDR_PANE
    old_session=$(herdr_projection_meta_field_exact "$meta" herdr_session) || {
      echo "error: existing herdr metadata for $ID has an ambiguous session; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_WORKSPACE_ID=$(herdr_projection_meta_field_exact "$meta" herdr_workspace_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous workspace; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_TAB_ID=$(herdr_projection_meta_field_exact "$meta" herdr_tab_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous tab; refusing duplicate launch" >&2
      return 1
    }
    old_pane=$(herdr_projection_meta_field_exact "$meta" herdr_pane_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous pane; refusing duplicate launch" >&2
      return 1
    }
    [ "$target_session" = "$old_session" ] && [ "$target_pane" = "$old_pane" ] || {
      echo "error: existing herdr metadata for $ID has inconsistent endpoint identities; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_PANE_ID=$old_pane
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
    # A stale registration over a shell-only pane is agent-free for RECOVERY
    # (--relaunch reuses the pane, issue #4115), but the duplicate-launch
    # corridor keeps refusing it like every other non-husk state, so a fresh
    # spawn is refused here consistently with the reclaim and presentation
    # gates downstream.
    dead | no-agent) return 0 ;;
    live | stale-agent | unknown)
      echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
  dead) return 0 ;;
  alive | unknown)
    echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
    return 1
    ;;
  esac
}

# Backlog preflight (bin/fm-backlog-transition-lib.sh). This spawn is about to
# become the sole owner of the row's In-flight transition, so prove the row is
# transitionable BEFORE any endpoint, worktree, or record exists: a refusal here
# costs nothing to unwind, while the same refusal after publication would strand
# a live pane. The authoritative mutation still runs under the meta lock below.
BACKLOG_TRANSITION=0
BACKLOG_ROW_STATE=
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if fm_backlog_row_probe "$DATA" "$ID"; then
    BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND) and re-run" >&2
    exit 1
  else
    echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
    exit 1
  fi
  if ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
    echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
    exit 1
  fi
else
  BACKLOG_GATE_STATUS=$?
  if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
    echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi

if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
fm_task_lifecycle_execution_allowed "$ID" || exit 1
LIFECYCLE_OLD_GENERATION=
if [ -f "$DATA/$ID/lifecycle.json" ]; then
  LIFECYCLE_BEFORE=$(fm_task_lifecycle read "$ID") || exit 1
  LIFECYCLE_OLD_GENERATION=$(printf '%s' "$LIFECYCLE_BEFORE" | jq -r '.execution_generation')
fi
if [ "$RELAUNCH" = 0 ] && [ -n "$LIFECYCLE_ACTION_ID$LIFECYCLE_EXPECTED_GEN" ]; then
  [ -n "$LIFECYCLE_ACTION_ID" ] && [ -n "$LIFECYCLE_EXPECTED_GEN" ] && [ "$RELAUNCH" = 0 ] || exit 2
  if [ "$(fm_meta_get "$STATE/$ID.meta" launch_action_id)" = "$LIFECYCLE_ACTION_ID" ]; then
    fm_task_lifecycle authorize "$ID" --action-id "$LIFECYCLE_ACTION_ID" --kind spawn \
      --expected-generation "$LIFECYCLE_EXPECTED_GEN" < "$DATA/$ID/brief.md" >/dev/null || exit 1
    echo "spawn already published for action $LIFECYCLE_ACTION_ID; reconcile the existing execution"
    exit 0
  fi
  [ "$(printf '%s' "$LIFECYCLE_BEFORE" | jq -r '.next_action.phase')" = prepared ] || {
    echo 'REFUSED: launch submission is uncertain; recover its recorded endpoint, never allocate a second one' >&2
    exit 1
  }
  fm_task_lifecycle authorize "$ID" --action-id "$LIFECYCLE_ACTION_ID" --kind spawn \
    --expected-generation "$LIFECYCLE_EXPECTED_GEN" < "$DATA/$ID/brief.md" >/dev/null || exit 1
fi
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  exit 1
fi

W="fm-$ID"
if [ "$RELAUNCH" -eq 1 ]; then
  # Adopt the recorded endpoint instead of creating one. This is what keeps a
  # relaunch a REPLACEMENT rather than a second copy of the task: no new
  # terminal, no second worktree, and every uncommitted change left exactly
  # where the previous agent left it.
  T=$RELAUNCH_TARGET
  WT=$RELAUNCH_WT
  WT_TARGET=$T
  SES=${T%%:*}
else
  case "$BACKEND" in
  herdr)
    # Placement, separately from labeling: a crewmate/scout belongs in the
    # EXACT herdr workspace this launching process is itself running in, which
    # only its own herdr pane identity can name (a same-labeled sibling
    # workspace must never be adopted).
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE"; then
      HERDR_SES=$(fm_backend_herdr_session)
      HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        fm_backend_herdr_server_ensure "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not ensure its exact named session" >&2
          exit 1
        }
        spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" >&2
          exit 1
        }
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
        if [ "${HERDR_RECOVERY_BACKEND:-}" = herdr ]; then
          set +e
          FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_reclaim_task \
            "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_LABEL_HOME" \
            "$HERDR_RECOVERY_WORKSPACE_ID" "$HERDR_RECOVERY_TAB_ID" "$HERDR_RECOVERY_PANE_ID" \
            "$HERDR_PARENT_LABEL" "$W" "$PROJ_ABS"
          HERDR_RECLAIM_STATUS=$?
          set -e
          case "$HERDR_RECLAIM_STATUS" in
          0)
            HERDR_PROJECTED=1
            HERDR_WORKSPACE_ID=$HERDR_RECOVERY_WORKSPACE_ID
            HERDR_SEEDED_DEFAULT_TAB_ID=""
            HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
            HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
            HERDR_PROJECTION_ABORT_CLEANUP=1
            HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
            HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
            HERDR_PROJECTION_ABORT_SEEDED_PANE=""
            ;;
          2)
            spawn_herdr_presentation_order_lock_release
            ;;
          *) exit 1 ;;
          esac
        else
          spawn_herdr_presentation_order_lock_release
        fi
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        # Session lock path resolution and exact parent binding both need a
        # live named-session socket before journal publication.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif [ "${FM_BACKEND_HERDR_PRESENTATION_PREFERENCE:-default}" = default ] &&
          ! fm_backend_herdr_presentation_default_supported "$STATE" "$HERDR_SES"; then
          :
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          # The projected child is placed and bound UNDER this launcher's exact
          # parent workspace. Its own herdr pane identity names that workspace
          # directly; the label lookup is only the fallback for a launcher with
          # no herdr ancestry at all. A claimed-but-broken identity refuses here
          # rather than projecting under a guessed parent.
          set +e
          fm_backend_herdr_launcher_identity "$HERDR_SES"
          HERDR_LAUNCHER_STATUS=$?
          set -e
          case "$HERDR_LAUNCHER_STATUS" in
          0) HERDR_PARENT_WORKSPACE_ID=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID ;;
          2) HERDR_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_parent_workspace_exact \
            "$HERDR_SES" "$HERDR_PARENT_LABEL" 2>/dev/null || true) ;;
          *)
            spawn_herdr_presentation_order_lock_release
            exit 1
            ;;
          esac
          if [ -z "$HERDR_PARENT_WORKSPACE_ID" ]; then
            echo "warning: herdr presentation parent is absent or ambiguous; using the ordinary flat layout without projection" >&2
            spawn_herdr_presentation_order_lock_release
          else
            HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
            HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
            if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
              "$PROJ_ABS" "$HERDR_PROJECTION_LABEL" "$W"; then
              if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
                HERDR_PROJECTION_ABORT_CLEANUP=1
                HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
                HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
                HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
              fi
              exit 1
            fi
            HERDR_PROJECTED=1
            HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
            HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
            HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
            HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
            HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
            HERDR_PROJECTION_ABORT_CLEANUP=1
            HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
            HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
            HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
            fm_backend_herdr_projection_order_best_effort \
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PARENT_WORKSPACE_ID"
            HERDR_HOME_ID=$(fm_backend_herdr_projection_home_identity "$HERDR_LABEL_HOME" 2>/dev/null || true)
            if [ -n "$HERDR_HOME_ID" ] &&
              fm_backend_herdr_projection_live_binding_matches \
                "$HERDR_SES" "$HERDR_PROJECTION_ID" "$HERDR_WORKSPACE_ID" \
                "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$HERDR_PARENT_WORKSPACE_ID" \
                "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W" &&
              fm_backend_herdr_projection_journal_bind \
                "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_HOME_ID" "$HERDR_SES" \
                "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
                "$HERDR_PARENT_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W"; then
              :
            else
              echo "warning: herdr presentation could not publish an exact restart binding; this task will use flat fallback after a restart" >&2
            fi
          fi
        else
          echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
        fi
      fi
    fi
    if [ "$HERDR_PROJECTED" -ne 1 ]; then
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
      # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
      # (the second field empty when this call ADOPTED a pre-existing workspace
      # rather than creating a fresh one). Split on the guaranteed single tab
      # character; the seeded tab id is threaded through to create_task
      # untouched, which is the only function permitted to prune it (never
      # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
      CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
      HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
      HERDR_SES=${CONTAINER%%:*}
      HERDR_WORKSPACE_ID=${CONTAINER#*:}
      HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    fi
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  esac
fi
# The exact Herdr pane is also the worktree-discovery target.
: "${WT_TARGET:=$T}"
spawn_send_text_line() { # <target> <text>
  case "$BACKEND" in
  herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
  esac
}
spawn_current_path() { # <target>
  case "$BACKEND" in
  herdr) fm_backend_herdr_current_path "$1" ;;
  esac
}
spawn_send_literal() { # <target> <text>
  case "$BACKEND" in
  herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
  esac
}
spawn_send_key() { # <target> <key>
  case "$BACKEND" in
  herdr) fm_backend_herdr_send_key "$1" "$2" ;;
  esac
}

if [ "$RELAUNCH" -eq 1 ]; then
  # No worktree is acquired: the recorded one is reused as-is. What must be
  # proven instead is that the adopted endpoint's shell is actually sitting in
  # that worktree, so the replacement agent starts where the work is rather
  # than wherever the pane happened to drift.
  relaunch_wt_real=$(real_path_or_raw "$WT")
  relaunch_seen=
  for _ in $(seq 1 10); do
    relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
    sleep 0.5
  done
  if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
    if [ "$BACKEND" != herdr ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}', not its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
    relaunch_cd_path=${WT//\'/\'\\\'\'}
    spawn_send_text_line "$WT_TARGET" "cd -- '$relaunch_cd_path'" || {
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and could not be told to return to its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    }
    for _ in $(seq 1 10); do
      relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
      [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
      sleep 0.5
    done
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and did not return to its recorded worktree '$WT' when told to; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
  fi
  validate_spawn_worktree "relaunch" "$T"
else
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # The project comparison is physical: spawn_worktree_isolated screens each
  # read against PROJ_ABS_REAL, not PROJ_ABS, because a symlinked project prefix
  # would otherwise make the pane's OS-level cwd read differ from PROJ_ABS on
  # the very first poll, before the pane has actually moved.
  #
  # A single read that already looks isolated is not proof the pane settled
  # there: terminal cwd reporting can transiently show an unrelated stale path
  # (seen live as another real git checkout entirely) before the shell catches
  # up with treehouse get's cd. That
  # stale path passes spawn_worktree_isolated too (it resolves to a real,
  # distinct worktree top-level), so accepting it on one read alone silently
  # records the wrong worktree= in state/<id>.meta. Require two consecutive
  # reads to agree on the same isolated path before accepting it; a mismatch
  # just becomes the new candidate rather than resetting the wait, so a pane
  # that is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  #
  # Every candidate is screened with the isolation guard's own predicate, so a
  # read of the project itself or of the repository primary checkout is treated
  # as the transient it is and the wait continues, instead of being adopted and
  # then refused by the guard.
  # A candidate the screen rejects is never adopted, so a host where the pane
  # never reaches an isolated worktree spends the whole window before refusing.
  # That wait is deliberate - telling a transient apart from a terminal
  # misconfiguration would need machinery this path does not want - so the
  # refusal has to be self-explaining instead: carry the last path seen and the
  # reason it was rejected, and report both at the deadline.
  candidate=""
  last_seen=""
  last_reason="the pane reported no path"
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$p" ] || last_seen="$p"
    if [ -n "$p" ] && spawn_worktree_isolated "$p"; then
      p_real=$(real_path_or_raw "$p")
      last_reason="it is an isolated worktree, but no second read agreed with it"
      if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
        WT="$p"
        break
      fi
      candidate="$p_real"
    else
      candidate=""
      [ -z "$p" ] || last_reason=$SPAWN_WT_REASON
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter an isolated worktree within 60s (last seen '${last_seen:-none}': $last_reason; spawning project '$PROJ_ABS'); inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"

  # Claim the pool slot for this task. The interactive `treehouse get` sent to
  # the pane above records only a process lease (Treehouse's durable
  # `get --lease --lease-holder` is not this path), so Treehouse cannot say which task a slot belongs
  # to once that task's worker exits - and that is exactly when the slot is
  # handed on and this task's worktree= line goes stale. The claim is what lets
  # bin/fm-teardown.sh leave a slot that has since been reassigned untouched, so
  # a slot that cannot be claimed is refused here, at the cheapest point, rather
  # than launching a worker whose slot teardown could later release out from
  # under its successor.
  # Written under the Treehouse project lock held from before slot allocation
  # through metadata publication, so no other spawn or return sees a half-claim.
  SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
  if fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    if ! fm_treehouse_slot_owner_claim "$WT" "$ID" "$FM_HOME" "$SPAWN_GEN"; then
      echo "error: could not claim Treehouse pool slot $WT for task $ID; refusing to launch a worker whose slot cannot later be proved to be its own; inspect window $T" >&2
      exit 1
    fi
    SPAWN_SLOT_CLAIMED=1
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  freshen_spawn_worktree_base "$WT" || exit 1
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook where enabled: a file that touches
# state/<id>.turn-ended when the agent finishes a turn. Worktree-resident hooks
# and token pointers stay out of git's view so they never block teardown's dirty
# check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >>"$EXCL"
}
if [ "$RELAUNCH" -eq 1 ]; then
  # Retire the previous incarnation's per-task harness wiring before arming the
  # new one. Without this, a harness switch would leave the old adapter's hook
  # files and turn-end token registry entries behind, and even a same-harness
  # relaunch would orphan the retired busy generation's token
  # (bin/fm-control-lib.sh owns where those artifacts live).
  clear_relaunch_harness_wiring "$RELAUNCH_PRIOR_HARNESS" "$WT" "$STATE_REAL" "$ID" || {
    echo "error: could not retire $RELAUNCH_PRIOR_HARNESS wiring for task $ID; refusing to arm the replacement" >&2
    exit 1
  }
  RELAUNCH_REPLACEMENT_PENDING=1
  RELAUNCH_REPLACEMENT_HARNESS=$HARNESS
  RELAUNCH_REPLACEMENT_STATE=$STATE_REAL
  RELAUNCH_REPLACEMENT_WT=$WT
fi
BUSY_GEN=
case "$HARNESS" in
  codex | traex)
    if [ "$RAW_LAUNCH" -eq 0 ] && [ "$BACKEND" = herdr ]; then
      BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID" --state unknown) || exit 1
      [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
      if [ "$HARNESS" = codex ]; then
        BUSY_SESSIONS_ROOT="${CODEX_HOME:-$HOME/.codex}/sessions"
      else
        BUSY_SESSIONS_ROOT="${TRAE_HOME:-$HOME/.trae}/cli/sessions"
      fi
      BUSY_SESSIONS_ROOT=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$BUSY_SESSIONS_ROOT") || exit 1
      python3 "$FM_ROOT/bin/fm-busy-transcript.py" init "$STATE_REAL" "$ID" "$HARNESS" \
        "$WT" "$BUSY_SESSIONS_ROOT" "$BACKEND" "$T" || exit 1
    fi
    ;;
esac
if [ "$HARNESS" = pi ]; then
  BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
    echo "error: failed to arm the busy-state contract for $ID" >&2
    exit 1
  }
  [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
    # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
    # loaded from inside the project (verified live), but an explicit -e path
    # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
    cat >"$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "progress", "$STATE_REAL", "$ID", "--gen", "$BUSY_GEN",
    ]);
  });
}
EOF
fi

# Delivery posture recorded in meta so fm-teardown's safety check and the
# validate/merge stages can branch on it. A ship task carries the explicit
# per-task decision validated above; a scout records none at all, because its
# deliverable is a report rather than a merge
# (fm-teardown.sh defaults an absent mode to no-mistakes, and fm-promote.sh
# requires an explicit mode when a scout is promoted to a ship task).
if [ "$KIND" = scout ]; then
  MODE=
  YOLO=
fi

# Resolve the optional default-off W3C trace context (bin/fm-trace-context-lib.sh,
# docs/configuration.md): the one carrier both recorded in meta and injected into
# the pane, so an observer reads exactly what the child receives. Empty only when
# disabled or on entropy/validation failure. Reuses this task's already-recorded
# value on relaunch; any other spawn roots a fresh trace, never adopting this
# process's own ambient TRACEPARENT, so each routed task is its own trace
# boundary even under a persistent supervisor. Never aborts the spawn and adds
# only the cost of reading a few bytes of entropy.
#
# The session-start path owns input resolution. Spawn consumes only the frozen
# home-session state.
SPAWN_TRACE_EFFECTIVE=$(fm_trace_context_session_effective "$STATE/.trace-context-effective")
if [ "$SPAWN_TRACE_EFFECTIVE" = on ]; then
  SPAWN_TRACEPARENT=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$STATE/$ID.meta" || true)
else
  SPAWN_TRACEPARENT=
fi

META_WINDOW=$T
SPAWN_GEN=${SPAWN_GEN:-"s$(date +%s).${BASHPID:-$$}.$RANDOM"}
SPAWN_REBIND_SLOT=0
if [ "$RELAUNCH" = 1 ] && fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
  fm_treehouse_slot_owner_state "$WT" "$ID" "$(fm_meta_get "$STATE/$ID.meta" spawn_gen)"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine)
      [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" = "$FM_HOME" ] || { echo 'error: relaunch slot belongs to another home' >&2; exit 1; }
      SPAWN_REBIND_SLOT=1 ;;
    absent) : ;; # Legacy absence grants no new claim.
    *) echo 'error: relaunch slot claim is ambiguous or reassigned' >&2; exit 1 ;;
  esac
fi
SPAWN_META_PATH="$STATE/$ID.meta"
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_TMP="$STATE/.$ID.meta.relaunch.${BASHPID:-$$}"
else
  SPAWN_META_TMP="$STATE/.$ID.meta.spawn.${BASHPID:-$$}"
  SPAWN_FRESH_COMMIT_PENDING=1
fi
SPAWN_META_PATH=$SPAWN_META_TMP
preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree project harness kind mode yolo tasktmp model effort busy_gen spawn_gen launch_state launch_action_id traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx", keys, " ")
      for (i in keys) owned[keys[i]] = 1
    }
    !($1 in owned)
  ' "$RELAUNCH_META"
}
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  echo "launch_state=prepared"
  [ -z "$LIFECYCLE_ACTION_ID" ] || echo "launch_action_id=$LIFECYCLE_ACTION_ID"
  # Default-off writes no traceparent= line.
  # Always publish the explicit terminal identity for new records.
  echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
} >"$SPAWN_META_PATH" || {
  echo "error: task record for $ID could not be prepared at $SPAWN_META_PATH" >&2
  exit 1
}
if [ "$RELAUNCH" -eq 0 ]; then
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  SPAWN_META_TMP=
fi

# The lifecycle binding is committed only after launch delivery succeeds below.
# Metadata published before a failed launch remains an unknown execution that
# recovery must inspect; it is never promoted to a confirmed action receipt.
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
if [ "$RELAUNCH" = 0 ] && [ "$BACKEND" = herdr ] && [ -f "$STATE/$ID.herdr-presentation" ]; then
  fm_backend_herdr_projection_bind_execution "$STATE/$ID.herdr-presentation" "$ID" "$SPAWN_GEN" || \
    echo "warning: launch identity could not be bound; independent endpoint cleanup will retain this endpoint" >&2
fi

# Fuse the backlog In-flight transition into the publication that just created
# the record (bin/fm-backlog-transition-lib.sh owns the invariant). It runs under
# this task's own meta lock, so a steer or teardown racing the same id stays
# serialized exactly as before. The call itself is deferred to the final commit
# point below. Only failures before launch submission remain unwindable;
# attempted launches retain their identity even when that transition fails.
spawn_commit_backlog_transition() {
  [ "$BACKLOG_TRANSITION" = 1 ] || return 0
  fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"
}

# The deferred-signal exit path's preservation report. A claim about preserved
# state is only trustworthy if that state is read back after the commit: the
# commit's own exit status has been observed to agree with a row that did not
# actually move (fm-yi4j evidence, 2026-09-05). This re-reads the paired record
# and the backlog row under the same per-task lock as the commit, repairs a row
# the commit believed it moved, and sets SPAWN_PRESERVED_CLAIM to exactly what
# was verified or attempted - never intent phrased as outcome.
spawn_report_preserved_state() {
  local repair_error=
  if ! fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE"; then
    SPAWN_PRESERVED_CLAIM="preservation could not be verified: its paired task record is missing; close out its backlog item by hand"
    return 1
  fi
  if ! fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item was not found; close out its paired task record by hand"
    else
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item state is unreadable (${FM_BACKLOG_ROW_ERROR:-no error recorded}); close out its paired task record and backlog item by hand"
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="verified preserved: its paired task record is present and its backlog item is In flight"
    return 0
  fi
  # The commit reported success, but the row does not read back In flight:
  # move it now under the same lock and verify the result before naming it.
  fm_backlog_start "$DATA" "$ID" || repair_error=$FM_BACKLOG_TRANSITION_ERROR
  if [ -z "$repair_error" ] &&
    fm_backlog_row_probe "$DATA" "$ID" &&
    [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="its backlog item did not read back In flight after the commit; it was moved to In flight now and verified, together with its paired task record"
    return 0
  fi
  SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item reads ${FM_BACKLOG_ROW_STATE:-unreadable}${repair_error:+, and moving it to In flight failed ($repair_error)}; close out its paired task record and backlog item by hand"
  return 1
}

if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_PUBLISH_STARTED=1
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: replacement task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  RELAUNCH_REPLACEMENT_PENDING=0
  SPAWN_META_PUBLISH_STARTED=0
  SPAWN_META_TMP=
fi
# A dispatch or relaunch keeps the per-task meta lock through launch delivery.
# The backlog mutation is deliberately the final fallible commit below, so
# teardown cannot remove a relaunched record while its replacement worker is
# still being delivered, cannot observe or complete a fresh provisional record
# between its state check and `tasks-axi start`, and a delivery failure cannot
# follow a committed In-flight transition.
if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
  fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK"
fi
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
fi

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
sq_worktree=$(shell_quote "$WT")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT" "$MODEL") || exit 1
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
BUSY_MARKER=
if [ -n "${BUSY_GEN:-}" ]; then
  case "$HARNESS" in
    codex|traex) BUSY_MARKER="\$(printf '\\nFIRSTMATE_BUSY_GENERATION=%s' '$BUSY_GEN')" ;;
  esac
fi
LAUNCH=${LAUNCH//__BUSYMARKER__/$BUSY_MARKER}
if [ -n "$BUSY_MARKER" ]; then
  # The pane shell may have a different ambient vendor home from the spawning
  # process. Pin the launched TUI to the same session root that we bound.
  case "$HARNESS" in
    codex) LAUNCH="CODEX_HOME=$(shell_quote "${BUSY_SESSIONS_ROOT%/sessions}") $LAUNCH" ;;
    traex) LAUNCH="TRAE_HOME=$(shell_quote "${BUSY_SESSIONS_ROOT%/cli/sessions}") $LAUNCH" ;;
  esac
fi
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
case "$HARNESS" in
pi) LAUNCH=${LAUNCH//__PIBIN__/"$(shell_quote "$PI_BIN")"} ;;
esac
LAUNCH=${LAUNCH//__WORKTREE__/$sq_worktree}
case "$HARNESS" in
codex | pi)
  LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI $LAUNCH"
  ;;
esac
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  # Fresh publication still owns the lock. Relaunch deliberately uses a short
  # independent critical section so other metadata interfaces can serialize.
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK"
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] ||
    ! awk -F= '$1 != "traceparent"' "$meta" >"$SPAWN_META_TMP" ||
    ! printf 'traceparent=%s\n' "$SPAWN_TRACEPARENT" >>"$SPAWN_META_TMP" ||
    ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$meta" "task record" "$STATE"; then
    status=1
    rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  fi
  SPAWN_META_TMP=
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$SPAWN_META_LOCK" || status=1
    SPAWN_META_LOCK_HELD=0
  fi
  return "$status"
}

spawn_record_launch_state() { # <prepared|unconfirmed|confirmed>
  SPAWN_META_TMP="$STATE/.$ID.meta.launch.${BASHPID:-$$}"
  awk -F= '$1 != "launch_state"' "$STATE/$ID.meta" >"$SPAWN_META_TMP" &&
    printf 'launch_state=%s\n' "$1" >>"$SPAWN_META_TMP" &&
    fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE" || return 1
  SPAWN_META_TMP=
}

# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
# Mark the pane as a task worker so bin/fm-test-run.sh can refuse to run the
# suite in the repository's primary checkout. Ship and scout workers are the
# ones assigned an isolated worktree. The id reached a validated bare-slug
# charset above, so it carries no shell
# syntax of its own.
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  spawn_send_text_line "$T" "export FM_TASK_ID=$ID"
fi
# Send through the exact channel that already ships GOTMPDIR, so every backend
# and harness gets it before launch. Skipped
# entirely when trace context is off.
if [ -n "$SPAWN_TRACEPARENT" ]; then
  if spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then
    if ! spawn_record_traceparent; then
      LAUNCH="unset TRACEPARENT; $LAUNCH"
    fi
  else
    TRACE_SEND_STATUS=$?
    if [ "$TRACE_SEND_STATUS" -eq 2 ]; then
      echo "error: trace-context input could not be cleared for $W; refusing to append the launch command" >&2
      exit 1
    fi
    LAUNCH="unset TRACEPARENT; $LAUNCH"
  fi
fi
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  LAUNCH_ENV_PREFIX='/usr/bin/env -i'
  for env_name in HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE \
    TMPDIR TMP TEMP GOTMPDIR HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID \
    FM_TASK_ID \
    $LAUNCH_ENV_NAMES; do
    # Only validated names enter shell syntax. Values expand once, quoted, in
    # the pane shell and never become source text or spawn-process snapshots.
    # shellcheck disable=SC2016
    printf -v env_arg '${%s+"%s=$%s"}' "$env_name" "$env_name" "$env_name"
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX $env_arg"
  done
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    # shellcheck disable=SC2016
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX "'${TRACEPARENT+"TRACEPARENT=$TRACEPARENT"}'
  fi
  LAUNCH="$LAUNCH_ENV_PREFIX /bin/sh -c $(shell_quote "$LAUNCH")"
fi
sleep 0.3
# Publish the uncertainty before any launch text can arrive. A signal or lost
# transport response after this point cannot roll back the worker's identity.
spawn_record_launch_state unconfirmed
SPAWN_LAUNCH_ATTEMPTED=1
# Projection rollback is endpoint destruction, so it has the same boundary.
HERDR_PROJECTION_ABORT_CLEANUP=0
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
spawn_send_key "$T" Enter
if [ -n "${BUSY_GEN:-}" ]; then
  case "$HARNESS" in
    codex|traex) python3 "$FM_ROOT/bin/fm-busy-transcript.py" activate "$STATE_REAL" "$ID" || exit 1 ;;
  esac
fi
if [ "$HARNESS" = traex ]; then
  # Sending Enter proves transport only. A fresh isolated copy may show TraeX's
  # native trust chooser; the harness adapter verifies that exact dialog and
  # accepts it once, while Herdr remains the sole lifecycle/backend owner.
  if ! fm_backend_herdr_traex_wait_started "$T" "$WT" "$PROJ_ABS"; then
    echo "error: TraeX task instructions did not begin through the verified Herdr launch path; inspect window $T" >&2
    exit 1
  fi
fi
# This is the commit point: all endpoint and harness delivery that can reject
# the spawn has succeeded. Re-read and transition while holding the same
# per-task lock as metadata publication, then and only then report success.
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
SPAWN_DEFERRED_SIGNAL=
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  trap 'SPAWN_DEFERRED_SIGNAL=HUP' HUP
  trap 'SPAWN_DEFERRED_SIGNAL=INT' INT
  trap 'SPAWN_DEFERRED_SIGNAL=TERM' TERM
fi
SPAWN_BACKLOG_COMMIT_STATUS=0
# Both the commit and its preservation read-back run under this task's meta
# lock, so an unresponsive tasks-axi there would hold the lock - and every
# lifecycle operation waiting on it - open ended, with even the deferred
# signals parked in a trap. Bound each invocation
# (bin/fm-backlog-transition-lib.sh's fm_tasks_axi): a timed-out call
# fails through the ordinary error plumbing, and the interrupted exit path
# reports it as the reason the preservation could not be verified.
FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
if spawn_commit_backlog_transition; then
  SPAWN_FRESH_COMMIT_PENDING=0
else
  SPAWN_BACKLOG_COMMIT_STATUS=$?
  if spawn_commit_backlog_transition; then
    SPAWN_BACKLOG_COMMIT_STATUS=0
    SPAWN_FRESH_COMMIT_PENDING=0
  fi
fi
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  if [ "$RELAUNCH" -eq 0 ]; then
    if spawn_fresh_commit_rollback; then
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); its record was removed so no worker is left that the backlog does not own - close out endpoint $T and local copy $WT by hand, then re-run the spawn" >&2
    else
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); launch was attempted, so its record and bindings remain at $STATE/$ID.meta for reconciliation; do not remove them or spawn a duplicate worker" >&2
    fi
  else
    echo "error: task $ID was republished but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); fix the backlog and re-run the relaunch" >&2
  fi
fi
trap - HUP INT TERM
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  exit "$SPAWN_BACKLOG_COMMIT_STATUS"
fi
spawn_record_launch_state confirmed
if [ "$KIND" != secondmate ] && [ "$RELAUNCH" = 0 ]; then
  FM_HOME="$FM_HOME" fm_task_lifecycle bind-execution "$ID" \
    --expected-generation "$LIFECYCLE_OLD_GENERATION" --action-id "$LIFECYCLE_ACTION_ID" >/dev/null || exit 1
fi
if [ -n "$SPAWN_DEFERRED_SIGNAL" ]; then
  case "$SPAWN_DEFERRED_SIGNAL" in
  HUP) SPAWN_DEFERRED_SIGNAL_STATUS=129 ;;
  INT) SPAWN_DEFERRED_SIGNAL_STATUS=130 ;;
  TERM) SPAWN_DEFERRED_SIGNAL_STATUS=143 ;;
  esac
  # Keep deferring further signals so the read-back below cannot itself be
  # killed halfway through verifying or correcting the preserved state.
  trap 'SPAWN_DEFERRED_SIGNAL=$SPAWN_DEFERRED_SIGNAL' HUP INT TERM
  # Deliberately unguarded against errexit: a failed verification still set
  # the honest attempted-preservation claim the exit below reports.
  spawn_report_preserved_state || true
  trap - HUP INT TERM
  echo "error: spawn of $ID was interrupted after launch delivery began; $SPAWN_PRESERVED_CLAIM" >&2
  exit "$SPAWN_DEFERRED_SIGNAL_STATUS"
fi
if [ "$KIND" != secondmate ] && [ "$RELAUNCH" = 1 ]; then
  if [ "$SPAWN_REBIND_SLOT" = 1 ]; then
    fm_treehouse_slot_owner_claim "$WT" "$ID" "$FM_HOME" "$SPAWN_GEN" || {
      echo 'error: replacement published but slot generation update failed; preserve records for reconciliation' >&2
      exit 1
    }
  fi
  FM_HOME="$FM_HOME" fm_task_lifecycle bind-execution "$ID" \
    --expected-generation "$LIFECYCLE_OLD_GENERATION" --action-id "$LIFECYCLE_ACTION_ID" >/dev/null || exit 1
fi
if [ "$RELAUNCH" = 1 ] && [ "$BACKEND" = herdr ] && [ -f "$STATE/$ID.herdr-presentation" ]; then
  fm_backend_herdr_projection_bind_execution "$STATE/$ID.herdr-presentation" "$ID" "$SPAWN_GEN" || \
    echo "warning: replacement launch identity unavailable; endpoint cleanup retained" >&2
fi
fm_lock_release "$SPAWN_META_LOCK"
SPAWN_META_LOCK_HELD=0

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT"
