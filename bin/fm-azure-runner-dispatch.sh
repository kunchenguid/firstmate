#!/usr/bin/env bash
# Opt-in per-command bridge from repository/no-mistakes shell commands to the
# disposable Azure runner.
#
# FM_AZURE_RUNNER_REMOTE_CLASSES is a comma-separated selection whose entries
# are <command-class>=<resource-class>, for example:
#   test=behavior-heavy,lint=validation-standard
# A missing command class executes locally, preserving today's default.
# Once selected remote, any transport/identity/staging/quota/result failure is
# returned as failure; this bridge never retries the command on the Mac.
# FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES is an explicit comma-separated local
# recovery selection and wins only for the named classes.
#
# Remote execution requires three per-run bindings. An operator may export all
# of them (the docs/azure-runner.md recipe), and explicit values are passed
# through unchanged. Inside an ambient no-mistakes run nothing exports them,
# so this wrapper is the caller that derives them from the run's own identity:
#
#   FM_AZURE_RUNNER_TASK / FM_AZURE_RUNNER_GENERATION
#     1. Task-worktree metadata: when the command's Git top-level is the
#        recorded `worktree=` of exactly one `$FM_HOME/state/<task>.meta`,
#        the task id is that metadata's name and the generation is its
#        `generation_id`. This is the same worktree-to-task authority the
#        rest of the fleet uses (bin/fm-no-mistakes-reattach.sh,
#        bin/fm-worker-lifecycle.py authoritative_request_bindings).
#     2. no-mistakes gate worktree: gate steps execute inside the daemon's
#        own snapshot at <nm-home>/worktrees/<repo-id>/<run-id> (see
#        bin/fm-nm-step-liveness.sh), which records no firstmate task. The
#        run's own identity is used instead: the task is nm-<run-id> and the
#        generation is the exact snapshot HEAD under validation.
#   FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION
#     Passed through from the operator environment's FM_AZURE_SUBSCRIPTION_ID,
#     explicitly and never invented; absent means refusal.
#
# Every underivable binding fails CLOSED with an exact error naming what is
# missing. There is no silent local fallback on a derivation failure:
# FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES stays the only explicit opt-out.
#
# Usage:
#   fm-azure-runner-dispatch.sh <command-class> -- <argv...>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
COMMAND_CLASS=${1:-}
[ -n "$COMMAND_CLASS" ] || { echo "usage: fm-azure-runner-dispatch.sh <command-class> -- <argv...>" >&2; exit 2; }
shift
[ "${1:-}" = -- ] || { echo "dispatch requires -- before exact command argv" >&2; exit 2; }
shift
[ "$#" -gt 0 ] || { echo "dispatch requires command argv" >&2; exit 2; }
[[ "$COMMAND_CLASS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || { echo "invalid command class" >&2; exit 2; }

contains_class() {
  local raw=$1 wanted=$2 entry name
  IFS=, read -r -a entries <<<"$raw"
  for entry in "${entries[@]:-}"; do
    name=${entry%%=*}
    [ "$name" = "$wanted" ] && return 0
  done
  return 1
}

resource_for_class() {
  local raw=$1 wanted=$2 entry name resource
  IFS=, read -r -a entries <<<"$raw"
  for entry in "${entries[@]:-}"; do
    name=${entry%%=*}
    resource=${entry#*=}
    if [ "$name" = "$wanted" ]; then
      [ "$resource" != "$entry" ] && [ -n "$resource" ] || return 2
      printf '%s\n' "$resource"
      return 0
    fi
  done
  return 1
}

# A remote-selected command whose bindings cannot be derived runs NOWHERE:
# loud exact refusal, never a silent local execution of the command.
refuse() {
  printf 'azure-runner dispatch: %s\n' "$1" >&2
  exit 1
}

meta_last_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Derive task/generation from the ambient run. Sets DERIVED_TASK and
# DERIVED_GENERATION or refuses with the exact reason.
derive_task_bindings() {
  local toplevel state_dir fm_root ambient_home meta recorded resolved
  local match_meta='' match_count=0 match_names='' run_dir run_id head
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) \
    || refuse "cannot derive FM_AZURE_RUNNER_TASK: the working directory is not inside a Git worktree, so no ambient run identity exists; export FM_AZURE_RUNNER_TASK and FM_AZURE_RUNNER_GENERATION explicitly"
  toplevel=$(cd "$toplevel" && pwd -P)

  # 1. Task-worktree metadata authority.
  fm_root="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
  ambient_home="${FM_HOME:-$fm_root}"
  state_dir="${FM_STATE_OVERRIDE:-$ambient_home/state}"
  if [ -d "$state_dir" ]; then
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] || continue
      recorded=$(meta_last_value "$meta" worktree)
      [ -n "$recorded" ] || continue
      resolved=$(cd "$recorded" 2>/dev/null && pwd -P) || continue
      if [ "$resolved" = "$toplevel" ]; then
        match_meta=$meta
        match_count=$((match_count + 1))
        match_names="$match_names $(basename "$meta" .meta)"
      fi
    done
  fi
  if [ "$match_count" -gt 1 ]; then
    refuse "cannot derive FM_AZURE_RUNNER_TASK: worktree $toplevel is recorded by more than one task metadata in $state_dir:$match_names; export FM_AZURE_RUNNER_TASK and FM_AZURE_RUNNER_GENERATION explicitly"
  fi
  if [ "$match_count" -eq 1 ]; then
    DERIVED_TASK=$(basename "$match_meta" .meta)
    DERIVED_GENERATION=$(meta_last_value "$match_meta" generation_id)
    [ -n "$DERIVED_GENERATION" ] \
      || refuse "cannot derive FM_AZURE_RUNNER_GENERATION: task metadata $match_meta records no generation_id"
    return 0
  fi

  # 2. no-mistakes gate-worktree run identity: .../worktrees/<repo-id>/<run-id>
  # with a 26-character ULID run id (Crockford alphabet, no I/L/O/U).
  run_dir=$(dirname "$toplevel")
  run_id=$(basename "$toplevel")
  if [ "$(basename "$(dirname "$run_dir")")" = worktrees ] \
    && [[ "$run_id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]; then
    head=$(git -C "$toplevel" rev-parse HEAD 2>/dev/null) \
      || refuse "cannot derive FM_AZURE_RUNNER_GENERATION: gate worktree $toplevel has no readable HEAD"
    DERIVED_TASK="nm-$run_id"
    DERIVED_GENERATION=$head
    return 0
  fi

  refuse "cannot derive FM_AZURE_RUNNER_TASK: no task metadata in $state_dir records worktree $toplevel and it is not a no-mistakes gate worktree (worktrees/<repo-id>/<run-id>); export FM_AZURE_RUNNER_TASK and FM_AZURE_RUNNER_GENERATION explicitly"
}

if contains_class "${FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES:-}" "$COMMAND_CLASS"; then
  printf 'azure-runner dispatch: explicit local recovery selected for %s\n' "$COMMAND_CLASS" >&2
  exec "$@"
fi

if ! contains_class "${FM_AZURE_RUNNER_REMOTE_CLASSES:-}" "$COMMAND_CLASS"; then
  exec "$@"
fi

RESOURCE_CLASS=$(resource_for_class "$FM_AZURE_RUNNER_REMOTE_CLASSES" "$COMMAND_CLASS") || {
  echo "remote command selection must be <command-class>=<resource-class>" >&2
  exit 2
}

TASK=${FM_AZURE_RUNNER_TASK:-}
GENERATION=${FM_AZURE_RUNNER_GENERATION:-}
CONFIRM=${FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION:-}

# Explicit values are honored as a pair only: half a hand-set identity would
# silently mix an operator task with a derived generation (or the reverse).
if [ -n "$TASK" ] && [ -z "$GENERATION" ]; then
  refuse "FM_AZURE_RUNNER_TASK is set without FM_AZURE_RUNNER_GENERATION; export both or neither"
fi
if [ -z "$TASK" ] && [ -n "$GENERATION" ]; then
  refuse "FM_AZURE_RUNNER_GENERATION is set without FM_AZURE_RUNNER_TASK; export both or neither"
fi
if [ -z "$TASK" ]; then
  DERIVED_TASK='' DERIVED_GENERATION=''
  derive_task_bindings
  TASK=$DERIVED_TASK
  GENERATION=$DERIVED_GENERATION
fi
if [ -z "$CONFIRM" ]; then
  # Pass-through only: the subscription confirmation always originates from
  # the operator environment and is never synthesized here.
  [ -n "${FM_AZURE_SUBSCRIPTION_ID:-}" ] \
    || refuse "cannot derive FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION: FM_AZURE_SUBSCRIPTION_ID is not set in the operator environment"
  CONFIRM=$FM_AZURE_SUBSCRIPTION_ID
fi

exec "$SCRIPT_DIR/fm-azure-runner.sh" run \
  --confirm-run \
  --confirm-subscription "$CONFIRM" \
  --task "$TASK" \
  --generation "$GENERATION" \
  --resource-class "$RESOURCE_CLASS" \
  -- "$@"
