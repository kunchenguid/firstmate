#!/usr/bin/env bash
# Auto-redeploy a registered, machine-local deployed CLI clone after its PR merges.
#
# Why this exists: tools like missive-axi, review-axi, and ahrefs-axi run from
# npm-linked working clones under ~/dev/<name> (e.g. `which missive` resolves to
# ~/dev/missive-axi/dist/bin/missive.js). Merging a PR to such a tool's main does
# NOT update the installed command - the live CLI silently lags main until someone
# manually pulls and rebuilds. This script fast-forwards the deployed clone to its
# default branch and rebuilds it, so the live command always tracks main with no
# manual step.
#
# The registry that opts a project into this is config/deploy-clones.json (local,
# gitignored; schema in docs/configuration.md, starting point in
# docs/examples/deploy-clones.json). Absent or empty registry = complete no-op.
# A project not in the registry is never touched.
#
# Safety: the deployed clone lives outside projects/, so this is not a projects/
# write, but it keeps the same no-destruction discipline. A clone with
# uncommitted changes, a non-fast-forwardable pull, or a failing build is
# reported as a concrete failure and is NEVER reported as deployed; nothing is
# ever forced, stashed, or discarded.
#
# Subcommands (see --help):
#   on-merge <task-id>   Resolve the task's project from state/<id>.meta, and if
#                        that project is registered, redeploy its clone. Launched
#                        detached so it never blocks the caller (the watcher poll
#                        loop or fm-pr-merge.sh); on-merge failures are reported
#                        through the durable wake queue. This is the entry point
#                        fm-merge-outcome-lib.sh wires into the merge-landed path.
#   run [--wake] <name>  Redeploy one registered clone by project name,
#                        synchronously. --wake reports a failure to the durable
#                        wake queue in addition to stderr. Manual/operator use.
#   list                 Print the registered project names and their clone paths.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-deploy-clone.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REGISTRY="$CONFIG/deploy-clones.json"

usage() {
  cat >&2 <<'EOF'
usage: fm-deploy-clone.sh on-merge <task-id>
       fm-deploy-clone.sh run [--wake] <project-name>
       fm-deploy-clone.sh list

Redeploy a registered, machine-local deployed CLI clone after its PR merges.
Registry: config/deploy-clones.json (local, gitignored). Absent = no-op.
See docs/configuration.md "Deployed CLI clones" for the schema.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

die() { printf 'fm-deploy-clone: %s\n' "$1" >&2; exit 1; }

# Expand a leading ~ (or ~/) in a registry path to $HOME. Other paths pass
# through unchanged, so both ~/dev/<name> and absolute paths are accepted.
expand_path() {
  local p=$1
  # These ~ forms are literal case patterns and a literal prefix strip, not shell
  # tilde expansion, so SC2088's "tilde does not expand in quotes" does not apply.
  # shellcheck disable=SC2088
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#\~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# Read the registry once into a validated temp snapshot. Absent registry is a
# graceful no-op (exit 0 with no output); malformed JSON is a loud failure so a
# broken registry is never silently treated as empty.
require_registry() {
  [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ] || return 3
  [ -r "$REGISTRY" ] || die "registry not readable: $REGISTRY"
  command -v jq >/dev/null 2>&1 || die "jq is required to read $REGISTRY"
  jq -e . "$REGISTRY" >/dev/null 2>&1 || die "registry is not valid JSON: $REGISTRY"
  return 0
}

# Echo "<path>\t<build>" for a registered project name, or nothing when the name
# is not registered.
registry_lookup() {
  local name=$1
  jq -r --arg n "$name" \
    '.clones[]? | select(.name == $n) | [(.path // ""), (.build // "")] | @tsv' \
    "$REGISTRY"
}

# Append one durable failure wake so firstmate surfaces a redeploy problem at its
# next drain. The record path is state/, keyed per clone so repeated failures for
# the same clone collapse rather than spam.
wake_failure() {
  local name=$1 reason=$2 lib="$FM_ROOT/bin/fm-wake-lib.sh"
  if [ ! -r "$lib" ]; then
    printf 'fm-deploy-clone: redeploy failed but NOT announced (missing %s)\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  fm_wake_append check "deploy-clone-$name" \
    "check: CLI redeploy failed for $name - $reason"
}

# Guarded redeploy of one clone. Echoes the concrete failure reason on stdout of
# the caller-visible path via return; the caller decides whether to also wake.
# Never forces, stashes, or discards. Returns 0 on success, 1 on any failure with
# the reason left in DEPLOY_FAIL_REASON.
DEPLOY_FAIL_REASON=''
redeploy_one() {
  local name=$1 path build clone git_err build_err
  DEPLOY_FAIL_REASON=''
  local row
  row=$(registry_lookup "$name")
  if [ -z "$row" ]; then
    DEPLOY_FAIL_REASON="project $name is not in the registry"
    return 1
  fi
  path=${row%%$'\t'*}
  build=${row#*$'\t'}
  if [ -z "$path" ]; then
    DEPLOY_FAIL_REASON="registry entry for $name has no clone path"
    return 1
  fi
  if [ -z "$build" ]; then
    DEPLOY_FAIL_REASON="registry entry for $name has no build command"
    return 1
  fi
  clone=$(expand_path "$path")

  if [ ! -d "$clone" ]; then
    DEPLOY_FAIL_REASON="deployed clone not found: $clone"
    return 1
  fi
  if ! git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DEPLOY_FAIL_REASON="deployed clone is not a git repository: $clone"
    return 1
  fi
  if [ -n "$(git -C "$clone" status --porcelain 2>/dev/null)" ]; then
    DEPLOY_FAIL_REASON="clone has uncommitted changes, left untouched: $clone"
    return 1
  fi
  if ! git_err=$(git -C "$clone" pull --ff-only 2>&1); then
    DEPLOY_FAIL_REASON="not fast-forwardable ($clone): ${git_err//$'\n'/ }"
    return 1
  fi
  if ! build_err=$( (cd "$clone" && bash -c "$build") 2>&1); then
    DEPLOY_FAIL_REASON="build failed in $clone ($build): ${build_err//$'\n'/ }"
    return 1
  fi
  printf 'deployed: %s (%s)\n' "$name" "$clone"
  return 0
}

cmd_run() {
  local wake=0
  if [ "${1:-}" = "--wake" ]; then
    wake=1
    shift
  fi
  local name=${1:-}
  [ -n "$name" ] || { usage; exit 2; }
  if ! require_registry; then
    # Registry absent: nothing to deploy. Silent no-op.
    return 0
  fi
  if redeploy_one "$name"; then
    return 0
  fi
  printf 'fm-deploy-clone: %s\n' "$DEPLOY_FAIL_REASON" >&2
  [ "$wake" -eq 1 ] && wake_failure "$name" "$DEPLOY_FAIL_REASON"
  return 1
}

# Resolve the project name for a task from its metadata: the basename of the
# project= worktree root recorded in state/<id>.meta.
project_name_for_task() {
  local id=$1 line proj
  local meta="$STATE/$id.meta"
  [ -r "$meta" ] || return 1
  line=$(grep -m1 '^project=' "$meta" 2>/dev/null) || return 1
  proj=${line#project=}
  [ -n "$proj" ] || return 1
  basename "$proj"
}

# Launch the redeploy detached so it never blocks the caller. Its own process
# group and detached stdio follow the same three-way detach as
# fm-startup-network.sh: stdio to /dev/null, nohup to outlive the launcher, and
# an independent process group so a bounded caller terminating its group does not
# kill the worker.
launch_detached() {
  local name=$1 monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SELF" run --wake "$name" >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
}

cmd_on_merge() {
  local id=${1:-}
  [ -n "$id" ] || { usage; exit 2; }
  # No registry -> nothing opted in. No meta or no project -> nothing to resolve.
  require_registry || return 0
  local name
  name=$(project_name_for_task "$id") || return 0
  # Only act on a registered project; unregistered projects are untouched.
  [ -n "$(registry_lookup "$name")" ] || return 0
  if [ "${FM_DEPLOY_CLONE_FOREGROUND:-0}" = 1 ]; then
    cmd_run --wake "$name"
    return $?
  fi
  launch_detached "$name"
  return 0
}

cmd_list() {
  require_registry || { echo "no registry at $REGISTRY"; return 0; }
  jq -r '.clones[]? | "\(.name)\t\(.path)"' "$REGISTRY"
}

case "${1:-}" in
  on-merge) shift; cmd_on_merge "$@" ;;
  run) shift; cmd_run "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) usage; exit 2 ;;
esac
