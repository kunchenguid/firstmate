#!/usr/bin/env bash
# FM_ACCOUNT_DIRECTORY_CUTOVER: direct-pool-rotation-v3
# Spawn a direct report: a new crewmate in a treehouse worktree, an eligible
# pre-cutover Orca direct recovery with empirically verified provider authority,
# or a secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--account-pool <pool>] [--account-profile <profile>] [--no-account-routing] [--no-provision] [--backlog-row-exemption <test-fixture|tracking-backend-repair>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--account-pool <pool>] [--account-profile <profile>] [--no-account-routing] --secondmate
#        fm-spawn.sh <task-id> --recover-direct-account
#        fm-spawn.sh <task-id> (--resume-account|--continue-account) [--harness <claude|codex>] [--account-pool <pool>] [--account-profile <profile>]
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   New-task spawn-capable backends are the reference tmux adapter and
#   experimental herdr, zellij, and cmux. Orca's legacy respawn design owns both
#   the task worktree and terminal, but currently fails closed before provider
#   mutation because its lifecycle authority is unverified. cmux is a session
#   provider only, exactly like herdr/zellij,
#   so it does. An auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. orca and cmux do not support --secondmate spawns.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   Cloud placement: FM_SPAWN_CLOUD=azure (or a config/spawn-cloud file whose
#   first line is azure) places a NEW ship/scout crewmate on an elastic Azure
#   worker through bin/fm-worker-lifecycle.sh instead of creating a local
#   backend endpoint; the recorded metadata carries placement=azure plus the
#   account_home and worktree_git_dir_identity bindings that lifecycle derives
#   its request from, and window= stays empty so local endpoint probes fail
#   closed. Cloud spawns run ENTIRELY on the pi-codex runtime: harness
#   dispatch and claude profile routing are bypassed. account_home comes from
#   config/azure-worker-account-home when that file exists, otherwise from the
#   pi coding-agent directory for backward compatibility; pi's extension owns
#   multi-profile selection on the worker. With the switch off (default),
#   spawns stay byte-identical to the local path. Secondmate and
#   account-recovery spawns always stay local, and --backend, raw launch
#   commands, or a non-pi harness cannot be combined with cloud placement.
#   FM_SPAWN_PARENT_TASK / FM_SPAWN_PARENT_TASK_GENERATION mark a cloud spawn as
#   a SECONDMATE COMPARTMENT CHILD: both are forwarded to the lifecycle request
#   as --parent-task/--parent-task-generation, where the controller's fan-out,
#   lifetime, parent-liveness and depth bounds apply to them. Only the
#   compartment monitor sets them; every other spawn, including a local
#   secondmate home requesting its own crewmates, leaves them unset and keeps
#   the byte-identical parent-less argv.
#   FM_SPAWN_TASK_HOME names the home the CHILD TASK lives in (state/, data/,
#   projects/) when it is not the home that owns the elastic-worker controller
#   document. Only the compartment monitor sets it, always together with the
#   parent pair. FM_HOME deliberately stays on the primary: it is what names
#   the ONE money document, and moving it would aim the request at a second
#   controller and refuse at the lifecycle's home fence. The path is forwarded
#   as --task-home, which the controller refuses outside a compartment child
#   request and then authorizes against the home's own .fm-secondmate-home
#   marker and the primary's data/secondmates.md registry.
#   With no harness arg, a crewmate/scout spawn resolves the crewmate harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   Claude ship/scout launches never inherit the CLI's ambient model.
#   They resolve config/claude-crew-model (inherited into secondmate homes), whose
#   absent-file default and only accepted value is claude-opus-5. An explicit
#   --model must equal that anchor. An empty/default/unresolvable/mismatched model
#   or a raw Claude launch fails closed before endpoint creation.
#   Account routing is independently default-off. Its precedence and off/observe/
#   enforce resolution is owned by fm-account-routing-lib.sh. Direct account-
#   directory launch currently covers ship/scout crewmates only; secondmate
#   integration is deferred and retains legacy Agent Fleet routing.
#   For a NEW routed Claude or Codex ship/scout, fm-account-directory.sh discovers
#   the current user's account homes, chooses one through its direct per-vendor
#   usage contract, installs that profile's Herdr hook, and prefixes the provider
#   command with CLAUDE_CONFIG_DIR or CODEX_HOME.
#   Existing --account-pool and --account-profile inputs remain compatibility
#   activation signals for new direct launches; their aliases do not constrain
#   the direct usage choice. --no-account-routing remains the emergency per-spawn
#   opt-out and cannot be combined with either account flag. Off launches retain
#   their existing default-identity behavior.
#   config/secondmate-account-pool remains the primary's durable, non-inherited
#   Agent Fleet selection input for secondmate agents when routing is enabled. A
#   secondmate's own crewmates use inherited crewmate dispatch/routing policy, not
#   this setting.
#   --resume-account and --continue-account are legacy recovery paths only for
#   existing account_profile metadata. They retain the sealed Agent Fleet
#   session/lease behavior needed to recover those already-managed generations;
#   ship/scout launches never create that metadata.
#   --recover-direct-account is the ship/scout account_home recovery path. It reloads kind,
#   project, worktree, harness, backend, model, effort, mode, yolo, and report
#   requirements from metadata, selects a fresh account directory, and creates
#   only a replacement endpoint in the recorded worktree.
#   A --secondmate spawn also propagates the primary's declared inheritable config
#   into the secondmate home's config/, so the secondmate's OWN crewmates,
#   dispatch profiles, and backlog backend inherit the primary's settings
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   A genuinely new ship/scout spawn must already have an In flight or Queued row
#   in this home's configured backlog. --backlog-row-exemption accepts only
#   test-fixture or tracking-backend-repair and records the category in metadata.
#   Before a secondmate launch, the home must fast-forward safely to the primary
#   default-branch commit and independently match the live default tip.
#   Any unproven freshness state refuses launch.
#   After a leased worktree passes its identity, cleanliness, and freshness proof
#   and before any endpoint is created, a ship/scout spawn provisions that
#   worktree's declared project dependencies (bin/fm-provision-lib.sh owns the
#   detection, cache, readiness, and bound contracts). A worktree that declares
#   no recognized manifest is a no-op. Otherwise there are exactly two
#   non-success outcomes, and that library's header enumerates both: a
#   CAPABILITY GAP - a component this provisioner was never able to provision -
#   is named on stderr, in the provisioning log, in the spawn's provision=
#   metadata, and in the git-excluded .fm-provisioning.md at the root of the
#   leased worktree - the only one of those the crewmate can read - and launches
#   the lane with that component
#   unprovisioned; a FAILURE - an attempt that was made and did not complete -
#   refuses the spawn, because a lane launched onto a half-built environment is
#   worse than no lane. The task's brief is passed in so an over-budget worktree
#   spends its component budget on what the task actually names.
#   --no-provision skips provisioning for one spawn, and
#   config/worktree-provision=off for the home. Both still clear any
#   .fm-provisioning.md the previous lease of that pool slot left behind, so an
#   opted-out lane cannot read another task's report as its own.
#   Ship/scout spawns refresh the primary checkout before Treehouse acquisition,
#   surface dirty pool entries, and durably lease one available worktree before
#   creating the endpoint. They refuse to create that endpoint unless the leased
#   path is a clean isolated worktree from the requested repository whose HEAD
#   matches its live upstream or local default-branch tip. Dirty acquisitions
#   remain under their durable lease for manual recovery. Other pre-commit
#   failures close the prepared endpoint, restore prior task state, and return
#   only a worktree whose repository identity, cleanliness, and expected detached
#   tip are re-proven before and after owned hook cleanup, with the return held
#   under the common checkout mutation lock.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend/account
#   flags and --backlog-row-exemption apply to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,92p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SUB_HOME_MARKER=".fm-secondmate-home"
# TASK_HOME is the home THIS SPAWN's task lives in: its state/, data/ and
# projects/. FM_HOME stays the home that owns the ONE elastic-worker money
# document. They are the same directory for every ordinary spawn, and differ
# only on the secondmate compartment-child lane, where the primary spawns a
# crewmate ON BEHALF OF a secondmate whose home holds the task authorities.
# Moving FM_HOME instead would aim the request at a SECOND controller document
# and refuse at the lifecycle's home fence, which must not be weakened.
TASK_HOME=$FM_HOME
if [ -n "${FM_SPAWN_TASK_HOME:-}" ]; then
  for spawn_task_home_conflict in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE; do
    [ -z "${!spawn_task_home_conflict:-}" ] || {
      echo "error: FM_SPAWN_TASK_HOME cannot be combined with $spawn_task_home_conflict" >&2
      exit 1
    }
  done
  unset spawn_task_home_conflict
  case "$FM_SPAWN_TASK_HOME" in
    /*) : ;;
    *) echo "error: FM_SPAWN_TASK_HOME must be an absolute path" >&2; exit 1 ;;
  esac
  TASK_HOME=$(cd -P "$FM_SPAWN_TASK_HOME" 2>/dev/null && pwd -P) || {
    echo "error: FM_SPAWN_TASK_HOME is not an existing directory: $FM_SPAWN_TASK_HOME" >&2
    exit 1
  }
  [ -f "$TASK_HOME/$SUB_HOME_MARKER" ] && [ ! -L "$TASK_HOME/$SUB_HOME_MARKER" ] || {
    echo "error: FM_SPAWN_TASK_HOME is not a seeded secondmate home: $TASK_HOME" >&2
    exit 1
  }
  # Content too, not only shape: without this a typo in the parent id refuses
  # LATE at the controller, after the lifecycle locks are taken and the
  # convergence artifacts (including the copied provider credential) are staged.
  if [ -n "${FM_SPAWN_PARENT_TASK:-}" ] \
    && [ "$(cat "$TASK_HOME/$SUB_HOME_MARKER" 2>/dev/null || true)" != "$FM_SPAWN_PARENT_TASK" ]; then
    echo "error: FM_SPAWN_TASK_HOME is not marked for secondmate $FM_SPAWN_PARENT_TASK" >&2
    exit 1
  fi
fi
STATE="${FM_STATE_OVERRIDE:-$TASK_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$TASK_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$TASK_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# The controller's own state directory. Derived from $FM_HOME, never from
# $TASK_HOME: the money document has exactly one home even when the task does
# not live there.
PRIMARY_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECKOUT_STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
CHECKOUT_LOCK_ROOT=$(fm_checkout_lock_root "$CHECKOUT_STATE_BASE")
# shellcheck source=bin/fm-cloud-state-lib.sh
. "$SCRIPT_DIR/fm-cloud-state-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-report-contract-lib.sh
. "$SCRIPT_DIR/fm-report-contract-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-provision-lib.sh
. "$SCRIPT_DIR/fm-provision-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

spawn_checkout_refresh() {  # <command> [args...]
  # A compartment child keeps FM_HOME on the primary because that home owns
  # the one elastic-worker controller and money document. Checkout refresh is
  # different: its FM_HOME keys the managed source clone and Treehouse pool.
  # Bind only this subprocess to the home that owns the child task, while the
  # exact project argument remains the compartment home's selected project.
  # Otherwise a same-named primary project can donate a foreign pool slot,
  # which the post-acquisition Git-common-dir fence correctly refuses.
  if [ "$TASK_HOME" != "$FM_HOME" ]; then
    FM_HOME="$TASK_HOME" "$SCRIPT_DIR/fm-checkout-refresh.sh" "$@"
  else
    "$SCRIPT_DIR/fm-checkout-refresh.sh" "$@"
  fi
}

spawn_managed_endpoint_kill() {  # <backend> <target> <tab-id> <label> <kind> <secondmate-home> [recorded-scoped-target]
  local backend=$1 target=$2 tab_id=$3 label=$4 kind=$5 secondmate_home=${6:-} recorded_scoped_target=${7:-} endpoint_home
  endpoint_home=$(fm_backend_endpoint_home "$backend" "$kind" "$TASK_HOME" "$secondmate_home")
  if [ "$endpoint_home" != "$FM_HOME" ]; then
    ( unset FM_ROOT_OVERRIDE; FM_HOME="$endpoint_home" FM_ROOT="$endpoint_home" fm_backend_kill "$backend" "$target" "$tab_id" "$label" "$recorded_scoped_target" )
  else
    fm_backend_kill "$backend" "$target" "$tab_id" "$label" "$recorded_scoped_target"
  fi
}

spawn_managed_endpoint_state() {  # <backend> <target> <label> <kind> <secondmate-home> [recorded-scoped-target]
  local backend=$1 target=$2 label=$3 kind=$4 secondmate_home=${5:-} recorded_scoped_target=${6:-} endpoint_home
  endpoint_home=$(fm_backend_endpoint_home "$backend" "$kind" "$TASK_HOME" "$secondmate_home")
  if [ "$endpoint_home" != "$FM_HOME" ]; then
    ( unset FM_ROOT_OVERRIDE; FM_HOME="$endpoint_home" FM_ROOT="$endpoint_home" fm_backend_target_state "$backend" "$target" "$label" "$recorded_scoped_target" )
  else
    fm_backend_target_state "$backend" "$target" "$label" "$recorded_scoped_target"
  fi
}

git_repository_probe() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_IMPLICIT_WORK_TREE GIT_PREFIX
  unset GIT_SUPER_PREFIX GIT_INTERNAL_SUPER_PREFIX GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL
  command git "$@"
)

git_common_dir_real() {
  local repo=$1 common
  (
    cd "$repo" 2>/dev/null || exit 1
    common=$(git_repository_probe rev-parse --git-common-dir 2>/dev/null) || exit 1
    cd "$common" 2>/dev/null || exit 1
    pwd -P
  )
}

git_worktree_dir_real() {
  local repo=$1 git_dir
  (
    cd "$repo" 2>/dev/null || exit 1
    git_dir=$(git_repository_probe rev-parse --git-dir 2>/dev/null) || exit 1
    cd "$git_dir" 2>/dev/null || exit 1
    pwd -P
  )
}

git_directory_identity() {
  # shellcheck disable=SC2016 # JavaScript source is intentionally single-quoted.
  node -e '
const fs = require("fs");
const stat = fs.lstatSync(process.argv[1], { bigint: true });
if (!stat.isDirectory() || stat.isSymbolicLink()) process.exit(1);
process.stdout.write(`${stat.dev}:${stat.ino}`);
' "$1"
}

git_worktree_ref() {
  git_repository_probe -C "$1" symbolic-ref -q HEAD 2>/dev/null
}

git_worktree_head() {
  git_repository_probe -C "$1" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
}

capture_worktree_git_physical_identity() {
  local worktree=$1
  WORKTREE_GIT_DIR=$(git_worktree_dir_real "$worktree" 2>/dev/null) || return 1
  WORKTREE_GIT_DIR_IDENTITY=$(git_directory_identity "$WORKTREE_GIT_DIR" 2>/dev/null) || return 1
  [ -n "$WORKTREE_GIT_DIR" ] && [ -n "$WORKTREE_GIT_DIR_IDENTITY" ]
}

capture_direct_launch_authoritative_state() {
  local current_ref current_head expected_ref
  current_ref=$(git_worktree_ref "$WT" 2>/dev/null || true)
  current_head=$(git_worktree_head "$WT" 2>/dev/null) || return 1
  expected_ref="refs/heads/fm/$ID"
  WORKTREE_GIT_REF=$expected_ref
  WORKTREE_GIT_HEAD=
  WORKTREE_GIT_SETUP_REF=
  WORKTREE_GIT_SETUP_HEAD=
  if [ "$current_ref" != "$expected_ref" ]; then
    WORKTREE_GIT_SETUP_REF=$current_ref
    WORKTREE_GIT_SETUP_HEAD=$current_head
  fi
}

validate_direct_recovery_physical_identity() {
  local worktree_real worktree_literal current_git_dir current_git_dir_identity
  worktree_real=$(cd "$WT" 2>/dev/null && pwd -P) || worktree_real=
  worktree_literal=${WT%/}
  if [ -z "$worktree_real" ] || [ "$worktree_literal" != "$worktree_real" ]; then
    echo "error: recorded direct account recovery worktree '$WT' is redirected or non-canonical; refusing endpoint creation" >&2
    return 1
  fi
  current_git_dir=$(git_worktree_dir_real "$WT" 2>/dev/null) || current_git_dir=
  current_git_dir_identity=$(git_directory_identity "$current_git_dir" 2>/dev/null) || current_git_dir_identity=
  if [ -z "$current_git_dir" ] || [ -z "$current_git_dir_identity" ] \
    || [ "$current_git_dir" != "$RECORDED_WORKTREE_GIT_DIR" ] \
    || [ "$current_git_dir_identity" != "$RECORDED_WORKTREE_GIT_DIR_IDENTITY" ]; then
    echo "error: recorded direct account recovery worktree '$WT' no longer has its exact Git-dir identity; refusing endpoint creation" >&2
    return 1
  fi
  WORKTREE_GIT_DIR=$current_git_dir
  WORKTREE_GIT_DIR_IDENTITY=$current_git_dir_identity
}

validate_direct_recovery_worktree_identity() {
  local current_git_ref current_git_head
  validate_direct_recovery_physical_identity || return 1
  current_git_ref=$(git_worktree_ref "$WT" 2>/dev/null || true)
  current_git_head=$(git_worktree_head "$WT" 2>/dev/null) || current_git_head=
  if [ -n "$RECORDED_WORKTREE_GIT_SETUP_HEAD" ]; then
    if [ "$current_git_ref" = "$RECORDED_WORKTREE_GIT_REF" ]; then
      WORKTREE_GIT_REF=$current_git_ref
      WORKTREE_GIT_HEAD=
      WORKTREE_GIT_SETUP_REF=
      WORKTREE_GIT_SETUP_HEAD=
      return 0
    fi
    if [ "$current_git_ref" != "$RECORDED_WORKTREE_GIT_SETUP_REF" ] \
      || [ -z "$current_git_head" ] \
      || [ "$current_git_head" != "$RECORDED_WORKTREE_GIT_SETUP_HEAD" ]; then
      echo "error: recorded direct account recovery worktree '$WT' changed branch identity; refusing endpoint creation" >&2
      return 1
    fi
    WORKTREE_GIT_REF=$RECORDED_WORKTREE_GIT_REF
    WORKTREE_GIT_HEAD=
    WORKTREE_GIT_SETUP_REF=$RECORDED_WORKTREE_GIT_SETUP_REF
    WORKTREE_GIT_SETUP_HEAD=$RECORDED_WORKTREE_GIT_SETUP_HEAD
    return 0
  fi
  if [ -n "$RECORDED_WORKTREE_GIT_REF" ]; then
    if [ "$current_git_ref" != "$RECORDED_WORKTREE_GIT_REF" ]; then
      echo "error: recorded direct account recovery worktree '$WT' changed branch identity; refusing endpoint creation" >&2
      return 1
    fi
    WORKTREE_GIT_REF=$current_git_ref
    WORKTREE_GIT_HEAD=
  else
    if [ -n "$current_git_ref" ] || [ -z "$current_git_head" ] \
      || [ "$current_git_head" != "$RECORDED_WORKTREE_GIT_HEAD" ]; then
      echo "error: recorded direct account recovery worktree '$WT' changed detached HEAD identity; refusing endpoint creation" >&2
      return 1
    fi
    WORKTREE_GIT_REF=
    WORKTREE_GIT_HEAD=$current_git_head
  fi
  WORKTREE_GIT_SETUP_REF=
  WORKTREE_GIT_SETUP_HEAD=
}

validate_direct_launch_worktree_identity() {
  local current_git_dir current_git_dir_identity
  current_git_dir=$(git_worktree_dir_real "$WT" 2>/dev/null) || current_git_dir=
  current_git_dir_identity=$(git_directory_identity "$current_git_dir" 2>/dev/null) || current_git_dir_identity=
  if [ -z "$current_git_dir" ] || [ -z "$current_git_dir_identity" ] \
    || [ "$current_git_dir" != "$WORKTREE_GIT_DIR" ] \
    || [ "$current_git_dir_identity" != "$WORKTREE_GIT_DIR_IDENTITY" ]; then
    echo "error: direct account worktree '$WT' changed exact Git-dir identity before metadata install" >&2
    return 1
  fi
}

# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
KIND_SET=0
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
ACCOUNT_POOL=
ACCOUNT_PROFILE=
NO_ACCOUNT_ROUTING=0
NO_PROVISION=0
BACKLOG_ROW_EXEMPTION=
BACKLOG_ROW_EXEMPTION_SET=0
RESUME_ACCOUNT=0
CONTINUE_ACCOUNT=0
DIRECT_ACCOUNT_RECOVERY=0
CONTINUATION_LAUNCH_DIR=
CONTINUATION_PROMPT_FILE=
CONTINUATION_PROMPT_DIR_ID=
CONTINUATION_PROMPT_FILE_ID=
CONTINUATION_PROMPT_CONTENT_ID=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
ACCOUNT_POOL_SET=0
ACCOUNT_PROFILE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      account-pool) ACCOUNT_POOL=$a; ACCOUNT_POOL_SET=1 ;;
      account-profile) ACCOUNT_PROFILE=$a; ACCOUNT_PROFILE_SET=1 ;;
      backlog-row-exemption) BACKLOG_ROW_EXEMPTION=$a; BACKLOG_ROW_EXEMPTION_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout; KIND_SET=1 ;;
    --secondmate) KIND=secondmate; KIND_SET=1 ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --account-pool) want_value=account-pool ;;
    --account-pool=*) ACCOUNT_POOL=${a#--account-pool=}; ACCOUNT_POOL_SET=1 ;;
    --account-profile) want_value=account-profile ;;
    --account-profile=*) ACCOUNT_PROFILE=${a#--account-profile=}; ACCOUNT_PROFILE_SET=1 ;;
    --no-account-routing) NO_ACCOUNT_ROUTING=1 ;;
    --no-provision) NO_PROVISION=1 ;;
    --backlog-row-exemption) want_value='backlog-row-exemption' ;;
    --backlog-row-exemption=*) BACKLOG_ROW_EXEMPTION=${a#--backlog-row-exemption=}; BACKLOG_ROW_EXEMPTION_SET=1 ;;
    --resume-account) RESUME_ACCOUNT=1 ;;
    --continue-account) CONTINUE_ACCOUNT=1 ;;
    --recover-direct-account) DIRECT_ACCOUNT_RECOVERY=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$ACCOUNT_POOL_SET" -eq 0 ] || [ -n "$ACCOUNT_POOL" ] || { echo "error: --account-pool requires a non-empty value" >&2; exit 1; }
[ "$ACCOUNT_PROFILE_SET" -eq 0 ] || [ -n "$ACCOUNT_PROFILE" ] || { echo "error: --account-profile requires a non-empty value" >&2; exit 1; }
[ "$BACKLOG_ROW_EXEMPTION_SET" -eq 0 ] || [ -n "$BACKLOG_ROW_EXEMPTION" ] \
  || { echo "error: --backlog-row-exemption requires a non-empty value" >&2; exit 1; }
case "$BACKLOG_ROW_EXEMPTION" in
  ''|test-fixture|tracking-backend-repair) ;;
  *)
    echo "error: --backlog-row-exemption must be one of test-fixture, tracking-backend-repair" >&2
    exit 1
    ;;
esac
if [ "$NO_ACCOUNT_ROUTING" = 1 ] && { [ "$ACCOUNT_POOL_SET" = 1 ] || [ "$ACCOUNT_PROFILE_SET" = 1 ]; }; then
  echo "error: --no-account-routing cannot be combined with --account-pool or --account-profile" >&2
  exit 1
fi
[ "$RESUME_ACCOUNT" = 0 ] || [ "$NO_ACCOUNT_ROUTING" = 0 ] || { echo "error: --resume-account cannot disable account routing" >&2; exit 1; }
[ "$CONTINUE_ACCOUNT" = 0 ] || [ "$NO_ACCOUNT_ROUTING" = 0 ] || { echo "error: --continue-account cannot disable account routing" >&2; exit 1; }
[ "$RESUME_ACCOUNT" = 0 ] || [ "$CONTINUE_ACCOUNT" = 0 ] || { echo "error: --resume-account and --continue-account are mutually exclusive" >&2; exit 1; }
if [ $((RESUME_ACCOUNT + CONTINUE_ACCOUNT + DIRECT_ACCOUNT_RECOVERY)) -gt 1 ]; then
  echo "error: --resume-account, --continue-account, and --recover-direct-account are mutually exclusive" >&2
  exit 1
fi
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  if [ "$KIND_SET" = 1 ] || [ "$HARNESS_SET" = 1 ] || [ "$MODEL_SET" = 1 ] \
    || [ "$EFFORT_SET" = 1 ] || [ "$BACKEND_SET" = 1 ] \
    || [ "$ACCOUNT_POOL_SET" = 1 ] || [ "$ACCOUNT_PROFILE_SET" = 1 ] \
    || [ "$NO_ACCOUNT_ROUTING" = 1 ] || [ "$BACKLOG_ROW_EXEMPTION_SET" = 1 ]; then
    echo "error: --recover-direct-account accepts only a task id; task context comes from metadata" >&2
    exit 1
  fi
fi
[ -z "$ACCOUNT_POOL" ] || fm_account_valid_id "$ACCOUNT_POOL" || { echo "error: invalid --account-pool '$ACCOUNT_POOL'" >&2; exit 1; }
[ -z "$ACCOUNT_PROFILE" ] || fm_account_valid_id "$ACCOUNT_PROFILE" || { echo "error: invalid --account-profile '$ACCOUNT_PROFILE'" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

RECOVERY_ACCOUNT=0
[ "$RESUME_ACCOUNT" = 0 ] && [ "$CONTINUE_ACCOUNT" = 0 ] && [ "$DIRECT_ACCOUNT_RECOVERY" = 0 ] || RECOVERY_ACCOUNT=1
[ "$RECOVERY_ACCOUNT" = 0 ] || [ "$BACKLOG_ROW_EXEMPTION_SET" = 0 ] || {
  echo "error: --backlog-row-exemption applies only to a genuinely new ship or scout task" >&2
  exit 1
}
# Cloud placement switch (Phase 6 activation). FM_SPAWN_CLOUD wins over the
# durable config/spawn-cloud file; both accept azure (place new ship/scout
# crewmates on elastic Azure workers through bin/fm-worker-lifecycle.sh) or
# off/local (default). Any other value fails closed. When the switch is off,
# spawn behavior and task metadata stay byte-identical to the local-only path.
# Account-recovery spawns always stay on the local backend by design
# (recovery re-binds a local endpoint). Secondmate spawns stay local too
# UNLESS FM_SPAWN_SECONDMATE_CLOUD=1 (R2/R3 design B.9, expand/contract): with
# the flag set, a --secondmate spawn with cloud placement becomes a
# compartment - an ordinary reviewed worker slot whose queue entry carries
# role=secondmate, whose durable home stays on this machine, and whose
# session legs are dispatched by bin/fm-secondmate-cloud-monitor.sh (this
# spawn queues the request and launches the monitor; it never dispatches an
# execute itself). With the flag unset or any other value the gate below is
# byte-identical to the pre-flag behavior.
SPAWN_CLOUD=off
SPAWN_CLOUD_VALUE=
SPAWN_CLOUD_SOURCE=default
if [ -n "${FM_SPAWN_CLOUD+x}" ]; then
  SPAWN_CLOUD_VALUE=$FM_SPAWN_CLOUD
  SPAWN_CLOUD_SOURCE=FM_SPAWN_CLOUD
elif [ -f "$CONFIG/spawn-cloud" ] && [ ! -L "$CONFIG/spawn-cloud" ]; then
  SPAWN_CLOUD_VALUE=$(head -n1 "$CONFIG/spawn-cloud" 2>/dev/null | tr -d '[:space:]')
  SPAWN_CLOUD_SOURCE=config/spawn-cloud
fi
case "$SPAWN_CLOUD_VALUE" in
  ''|off|local) SPAWN_CLOUD=off ;;
  azure) SPAWN_CLOUD=azure ;;
  *)
    echo "error: unknown cloud placement '$SPAWN_CLOUD_VALUE' from $SPAWN_CLOUD_SOURCE (accepted: azure, off, local)" >&2
    exit 1
    ;;
esac
if [ "$SPAWN_CLOUD" = azure ] \
  && { { [ "$KIND" = secondmate ] && [ "${FM_SPAWN_SECONDMATE_CLOUD:-}" != 1 ]; } || [ "$RECOVERY_ACCOUNT" = 1 ]; }; then
  echo "notice: cloud placement covers new ship/scout spawns only; this spawn stays on the local backend" >&2
  SPAWN_CLOUD=off
fi
if [ "$SPAWN_CLOUD" = azure ] && [ "$STATE" != "$TASK_HOME/state" ]; then
  # The task home's OWN state directory, never an override. TASK_HOME is
  # FM_HOME everywhere except the compartment-child lane, where FM_SPAWN_TASK_HOME
  # already refuses to be combined with any state/data/projects override.
  echo "error: cloud placement requires the task home's own state directory ($TASK_HOME/state), not an override" >&2
  exit 1
fi
CLOUD_ACCOUNT_HOME=
CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS=43200
CLOUD_PLACEMENT_STATE=
CLOUD_WORKER_LAUNCH=
RESUME_META=
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_OWNED=0
SECONDMATE_HOME_LIFECYCLE_LOCK=
SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK=
TASK_HOME_LIFECYCLE_LOCK=
LIFECYCLE_LOCK_INHERITED_PID=
LIFECYCLE_LOCK_INHERITED_START=
SPAWN_META_PRESENT=0
SPAWN_META_SNAPSHOT=
SPAWN_PREFLIGHT_ID=${POS[0]:-}
spawn_idpart=${SPAWN_PREFLIGHT_ID%%=*}
SPAWN_PREFLIGHT_BATCH=0

resolve_cloud_account_home() {
  local config_file="$CONFIG/azure-worker-account-home" configured canonical lines
  if [ -e "$config_file" ] || [ -L "$config_file" ]; then
    [ -f "$config_file" ] && [ ! -L "$config_file" ] || {
      echo "error: config/azure-worker-account-home must be a regular non-symlink file" >&2
      return 1
    }
    lines=$(awk 'END { print NR }' "$config_file" 2>/dev/null) || return 1
    [ "$lines" = 1 ] || {
      echo "error: config/azure-worker-account-home must contain exactly one line" >&2
      return 1
    }
    IFS= read -r configured < "$config_file" || {
      echo "error: cannot read config/azure-worker-account-home" >&2
      return 1
    }
    case "$configured" in
      /*) ;;
      *)
        echo "error: config/azure-worker-account-home must name an absolute path" >&2
        return 1
        ;;
    esac
    [ -d "$configured" ] && [ ! -L "$configured" ] || {
      echo "error: cloud placement account home '$configured' is not a real directory" >&2
      return 1
    }
    canonical=$(CDPATH='' cd -- "$configured" 2>/dev/null && pwd -P) || return 1
    [ "$canonical" = "$configured" ] || {
      echo "error: config/azure-worker-account-home must name its canonical physical directory ($canonical)" >&2
      return 1
    }
    printf '%s\n' "$configured"
    return 0
  fi
  printf '%s\n' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
}

validate_cloud_account_pool() {
  python3 - "$SCRIPT_DIR/fm-pi-account-home.py" "$CLOUD_ACCOUNT_HOME/auth.json" <<'PY'
import importlib.util
import sys

module_path, source = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_pi_account_home", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pool = module.read_pool(module.Path(source))
if not pool:
    module.fail("Azure Pi pool must contain at least one profile")
expected = ["openai-codex"] + [
    f"openai-codex-{index}" for index in range(2, len(pool) + 1)
]
if sorted(pool) != sorted(expected):
    module.fail("Azure Pi pool profiles must be gap-free: " + ", ".join(expected))
faults = {name: module.entry_faults(pool[name]) for name in expected}
broken = [f"{name}: {', '.join(items)}" for name, items in faults.items() if items]
if broken:
    module.fail("Azure Pi pool has unusable profile shapes: " + "; ".join(broken))
accounts = [pool[name]["accountId"].strip() for name in expected]
if len(set(accounts)) != len(accounts):
    module.fail("Azure Pi pool profiles must name distinct upstream accounts")
PY
}

if [ "$SPAWN_CLOUD" = azure ]; then
  CLOUD_ACCOUNT_HOME=$(resolve_cloud_account_home) || exit 1
  [ -d "$CLOUD_ACCOUNT_HOME" ] || {
    echo "error: cloud placement account home '$CLOUD_ACCOUNT_HOME' is not a directory" >&2
    exit 1
  }
  validate_cloud_account_pool || exit 1
fi

release_secondmate_home_lifecycle_locks() {
  [ -z "${TASK_HOME_LIFECYCLE_LOCK:-}" ] \
    || fm_account_lifecycle_lock_release "$TASK_HOME_LIFECYCLE_LOCK" >/dev/null 2>&1 || true
  [ -z "${SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK:-}" ] \
    || fm_account_lifecycle_lock_release "$SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK" >/dev/null 2>&1 || true
  [ -z "${SECONDMATE_HOME_LIFECYCLE_LOCK:-}" ] \
    || fm_account_lifecycle_lock_release "$SECONDMATE_HOME_LIFECYCLE_LOCK" >/dev/null 2>&1 || true
  TASK_HOME_LIFECYCLE_LOCK=
  SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK=
  SECONDMATE_HOME_LIFECYCLE_LOCK=
}
if [ -n "$SPAWN_PREFLIGHT_ID" ] && [ "$SPAWN_PREFLIGHT_ID" != "$spawn_idpart" ] \
  && case "$spawn_idpart" in */*) false ;; *) true ;; esac; then
  SPAWN_PREFLIGHT_BATCH=1
fi

spawn_preflight_read_meta() {  # <meta>
  node "$SCRIPT_DIR/fm-contained-read.cjs" "$STATE" "$1" 1048576
}

spawn_preflight_load_meta() {  # <required:0|1>
  local required=$1 cleanup_count cleanup_value
  RESUME_META="$STATE/$SPAWN_PREFLIGHT_ID.meta"
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
      echo "error: state directory must be a real directory before spawning: $STATE" >&2
      return 1
    }
  else
    [ "$required" = 0 ] || {
      echo "error: no metadata for managed recovery at $RESUME_META" >&2
      return 1
    }
    return 0
  fi
  if [ -e "$RESUME_META" ] || [ -L "$RESUME_META" ]; then
    SPAWN_META_SNAPSHOT=$(spawn_preflight_read_meta "$RESUME_META") || {
      echo "error: unsafe metadata for spawn preflight at $RESUME_META" >&2
      return 1
    }
    SPAWN_META_PRESENT=1
    cleanup_count=$(printf '%s\n' "$SPAWN_META_SNAPSHOT" | grep -c '^orca_cleanup_pending=' || true)
    if [ "$cleanup_count" -ne 0 ]; then
      cleanup_value=$(spawn_preflight_meta_value orca_cleanup_pending)
      if [ "$cleanup_count" -eq 1 ] && [ "$cleanup_value" = 1 ]; then
        echo "error: Orca cleanup is pending for $SPAWN_PREFLIGHT_ID; run fm-teardown.sh $SPAWN_PREFLIGHT_ID before retrying spawn" >&2
      else
        echo "error: invalid Orca cleanup metadata for $SPAWN_PREFLIGHT_ID; refusing spawn" >&2
      fi
      return 1
    fi
  elif [ "$required" = 1 ]; then
    echo "error: no metadata for managed recovery at $RESUME_META" >&2
    return 1
  fi
}

spawn_preflight_meta_value() {  # <key>
  printf '%s\n' "$SPAWN_META_SNAPSHOT" | sed -n "s/^$1=//p" | tail -1
}

spawn_preflight_kind_value() {
  local parsed count value
  parsed=$(printf '%s\n' "$SPAWN_META_SNAPSHOT" | awk '
    index($0, "kind=") == 1 {
      count++
      value = substr($0, 6)
    }
    END {
      printf "%d\t%s\n", count + 0, value
    }
  ') || return 1
  count=${parsed%%$'\t'*}
  value=${parsed#*$'\t'}
  case "$count:$value" in
    0:) printf '%s\n' ship ;;
    1:ship|1:scout|1:secondmate) printf '%s\n' "$value" ;;
    1:*)
      echo "error: managed recovery metadata has invalid kind '$value' for $SPAWN_PREFLIGHT_ID" >&2
      return 1
      ;;
    *)
      echo "error: managed recovery metadata has duplicate kind records for $SPAWN_PREFLIGHT_ID" >&2
      return 1
      ;;
  esac
}

spawn_manual_backlog_has_row() {  # <task-id> <backlog-file>
  local task_id=$1 backlog=$2
  [ -f "$backlog" ] || return 1
  awk -v wanted="$task_id" '
    /^## (In flight|Queued)[[:space:]]*$/ { active = 1; next }
    /^## / { active = 0 }
    !active { next }
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/^\[[ xX]\][[:space:]]*/, "", line)
      if (substr(line, 1, 2) == "**") {
        line = substr(line, 3)
        closing_pos = index(line, "**")
        if (closing_pos == 0) next
        key = substr(line, 1, closing_pos - 1)
      } else {
        key = line
        sub(/[[:space:]].*$/, "", key)
      }
      if (key == wanted) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$backlog"
}

spawn_backlog_has_row() {  # <task-id>
  local task_id=$1 backlog task
  backlog="$DATA/backlog.md"
  if fm_tasks_axi_backend_available "$CONFIG"; then
    task=$(tasks-axi show "$task_id" --backend markdown --file "$backlog" 2>/dev/null) || return 1
    printf '%s\n' "$task" | grep -Eq '^[[:space:]]*state: (in_flight|queued)[[:space:]]*$'
    return $?
  fi
  spawn_manual_backlog_has_row "$task_id" "$backlog"
}

spawn_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

spawn_refuse_missing_backlog_row() {  # <task-id> <kind> <project-dir>
  local task_id=$1 kind=$2 project=$3 repo backlog
  repo=${project%/}
  repo=${repo##*/}
  [ -n "$repo" ] || repo=unknown
  backlog="$DATA/backlog.md"
  echo "error: new $kind task $task_id has no In flight or Queued row in $backlog; file it before dispatch." >&2
  printf 'fix: %s --data %s -- tasks-axi add %s %s --kind %s --repo %s --start --backend markdown --file %s\n' \
    "$(spawn_shell_quote "$SCRIPT_DIR/fm-data-write.py")" \
    "$(spawn_shell_quote "$DATA")" \
    "$(spawn_shell_quote "$task_id")" "$(spawn_shell_quote '<one line>')" \
    "$(spawn_shell_quote "$kind")" "$(spawn_shell_quote "$repo")" \
    "$(spawn_shell_quote "$backlog")" >&2
}

spawn_refuse_report_required_orca() {
  local report_count
  if [ "$SPAWN_META_PRESENT" != 1 ]; then
    echo "error: backend=orca cannot host new report-required tasks: Orca has no reliable endpoint-absence proof, so report-gated teardown could never complete; spawn report-required work on tmux, herdr, zellij, or cmux" >&2
    return 1
  fi
  report_count=$(printf '%s\n' "$SPAWN_META_SNAPSHOT" | grep -c '^report_required=' || true)
  [ "$report_count" -eq 0 ] || {
    if [ "$report_count" -eq 1 ] && [ "$(spawn_preflight_meta_value report_required)" = 1 ]; then
      echo "error: backend=orca cannot host new report-required tasks: Orca has no reliable endpoint-absence proof, so report-gated teardown could never complete; spawn report-required work on tmux, herdr, zellij, or cmux" >&2
    else
      echo "error: invalid report_required metadata for $SPAWN_PREFLIGHT_ID; legacy Orca recovery requires the marker to be absent" >&2
    fi
    return 1
  }
}

reconcile_failed_direct_recovery() {
  local task=$1 meta="$STATE/$1.meta" lock marker generation backend target tmux_session_target tab kind home tasktmp
  local backup_name backup_token backup backup_snapshot artifacts_name artifacts_token artifacts endpoint_state tmp current_backup_snapshot
  lock=$(fm_account_meta_lock_acquire "$STATE" "$task") || return 1
  marker=$(fm_account_meta_value "$meta" direct_recovery_cleanup)
  if [ "$marker" != pending ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: invalid retained direct recovery state for $task" >&2
    return 1
  fi
  generation=$(fm_account_meta_value "$meta" generation_id)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  tmux_session_target=$(fm_account_meta_value "$meta" tmux_session_target)
  tab=$(fm_account_meta_value "$meta" zellij_tab_id)
  kind=$(fm_account_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  home=$(fm_account_meta_value "$meta" home)
  tasktmp=$(fm_account_meta_value "$meta" tasktmp)
  backup_name=$(fm_account_meta_value "$meta" direct_recovery_backup)
  artifacts_name=$(fm_account_meta_value "$meta" direct_recovery_artifacts)
  case "$backup_name" in
    ".$task.meta.rollback."*) ;;
    *)
      fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
      echo "error: unsafe retained direct recovery backup for $task" >&2
      return 1
      ;;
  esac
  backup_token=${backup_name#".$task.meta.rollback."}
  if ! fm_account_valid_id "$backup_token"; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: unsafe retained direct recovery backup for $task" >&2
    return 1
  fi
  case "$artifacts_name" in
    ".$task.artifacts.rollback."*) ;;
    *)
      fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
      echo "error: unsafe retained direct recovery artifacts for $task" >&2
      return 1
      ;;
  esac
  artifacts_token=${artifacts_name#".$task.artifacts.rollback."}
  if ! fm_account_valid_id "$artifacts_token"; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: unsafe retained direct recovery artifacts for $task" >&2
    return 1
  fi
  backup="$STATE/$backup_name"
  artifacts="$STATE/$artifacts_name"
  backup_snapshot=$(spawn_preflight_read_meta "$backup") || {
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery backup is missing or unsafe for $task" >&2
    return 1
  }
  if [ ! -d "$artifacts" ] || [ -L "$artifacts" ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery artifacts are missing or unsafe for $task" >&2
    return 1
  fi
  if ! fm_account_task_tmp_is_expected "$task" "$tasktmp" "$generation" \
    || [ -z "$generation" ] || [ -z "$target" ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery metadata is incomplete for $task" >&2
    return 1
  fi
  fm_account_meta_lock_release "$lock" || return 1
  lock=

  spawn_managed_endpoint_kill "$backend" "$target" "$tab" "fm-$task" "$kind" "$home" "$tmux_session_target" 2>/dev/null || true
  endpoint_state=$(spawn_managed_endpoint_state "$backend" "$target" "fm-$task" "$kind" "$home" "$tmux_session_target" 2>/dev/null)
  case "$endpoint_state" in
    absent) ;;
    present)
      echo "error: retained direct recovery endpoint is still alive for $task" >&2
      return 1
      ;;
    *)
      echo "error: retained direct recovery endpoint state is unknown for $task" >&2
      return 1
      ;;
  esac

  lock=$(fm_account_meta_lock_acquire "$STATE" "$task") || return 1
  current_backup_snapshot=$(spawn_preflight_read_meta "$backup" 2>/dev/null) || current_backup_snapshot=
  if [ ! -f "$meta" ] \
    || [ "$(fm_account_meta_value "$meta" direct_recovery_cleanup)" != pending ] \
    || [ "$(fm_account_meta_value "$meta" generation_id)" != "$generation" ] \
    || [ "$(fm_backend_of_meta "$meta")" != "$backend" ] \
    || [ "$(fm_backend_target_of_meta "$meta")" != "$target" ] \
    || [ "$(fm_account_meta_value "$meta" direct_recovery_backup)" != "$backup_name" ] \
    || [ "$(fm_account_meta_value "$meta" direct_recovery_artifacts)" != "$artifacts_name" ] \
    || [ "$current_backup_snapshot" != "$backup_snapshot" ] \
    || [ ! -d "$artifacts" ] || [ -L "$artifacts" ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery generation changed before cleanup for $task" >&2
    return 1
  fi
  if ! fm_account_restore_artifacts "$STATE" "$task" "$artifacts_name" "$tasktmp" 1 "$generation"; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery artifacts could not be restored for $task" >&2
    return 1
  fi
  tmp=$(mktemp "$STATE/.$task.meta.direct-recovery-restore.XXXXXX") || {
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  if ! printf '%s\n' "$backup_snapshot" > "$tmp" \
    || ! fm_account_meta_merge_extensions "$meta" "$tmp" \
    || ! fm_account_safe_file_destination "$meta" \
    || ! mv "$tmp" "$meta"; then
    rm -f "$tmp"
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: retained direct recovery metadata could not be restored for $task" >&2
    return 1
  fi
  rm -f "$backup" || echo "warning: retained direct recovery backup remains for $task" >&2
  rm -rf "$artifacts" || echo "warning: retained direct recovery artifacts remain for $task" >&2
  fm_account_meta_lock_release "$lock" || return 1
  SPAWN_META_SNAPSHOT=$(spawn_preflight_read_meta "$meta") || return 1
  SPAWN_META_PRESENT=1
  echo "fm-spawn: cleaned retained direct recovery endpoint for $task" >&2
}

spawn_refuse_existing_orca_provider_identity() {
  [ "$SPAWN_META_PRESENT" != 1 ] || [ "$(spawn_preflight_meta_value backend)" != orca ] || {
    echo "error: existing Orca provider identity for $SPAWN_PREFLIGHT_ID must be cleared by teardown before respawn" >&2
    return 1
  }
}

spawn_refuse_unsupported_secondmate_backend() {
  [ "$KIND" != secondmate ] || [ "$BACKEND" != orca ] || {
    echo "error: backend=orca does not support --secondmate spawns yet" >&2
    return 1
  }
  [ "$KIND" != secondmate ] || [ "$BACKEND" != cmux ] || {
    echo "error: backend=cmux does not support --secondmate spawns yet" >&2
    return 1
  }
}

if [ "$RECOVERY_ACCOUNT" = 1 ]; then
  [ "${#POS[@]}" -ge 1 ] || { echo "error: account recovery requires a task id" >&2; exit 1; }
  case "$SPAWN_PREFLIGHT_ID" in *=*) echo "error: account recovery does not support batch syntax" >&2; exit 1 ;; esac
  if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] && [ "${#POS[@]}" -ne 1 ]; then
    echo "error: --recover-direct-account accepts exactly one task id" >&2
    exit 1
  fi
  spawn_preflight_load_meta 1 || exit 1
  recorded_kind=$(spawn_preflight_kind_value) || exit 1
  if [ "$KIND" != ship ] && [ "$KIND" != "$recorded_kind" ]; then
    echo "error: account recovery kind '$KIND' does not match recorded kind '$recorded_kind'" >&2
    exit 1
  fi
  KIND=$recorded_kind
  if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
    case "$KIND" in
      ship|scout) ;;
      *) echo "error: --recover-direct-account supports only recorded ship or scout tasks" >&2; exit 1 ;;
    esac
  fi
  recorded_backend=$(spawn_preflight_meta_value backend)
  [ -n "$recorded_backend" ] || recorded_backend=tmux
  if [ "$BACKEND_SET" = 1 ] && [ "$BACKEND_ARG" != "$recorded_backend" ]; then
    echo "error: account recovery backend override '$BACKEND_ARG' does not match recorded backend '$recorded_backend'" >&2
    exit 1
  fi
  BACKEND_ARG=$recorded_backend
  BACKEND_SET=1
fi

if [ "$SPAWN_CLOUD" = azure ]; then
  # Cloud placement replaces the local session backend for the crewmate itself
  # (it runs on an elastic worker), but every cloud crewmate still registers a
  # Herdr tracking endpoint so none is ever lost: the fleet supervises through
  # Herdr only, and an endpoint-less spawn would be invisible to status/reap.
  # Runtime auto-detection is skipped and an explicit --backend is a
  # contradiction: the tracking endpoint is Herdr unconditionally.
  if [ "$BACKEND_SET" -eq 1 ]; then
    echo "error: --backend cannot be combined with cloud placement ($SPAWN_CLOUD_SOURCE=azure)" >&2
    exit 1
  fi
  BACKEND=herdr
elif [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
spawn_refuse_unsupported_secondmate_backend || exit 1
if [ "$BACKEND" = orca ] && [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$SPAWN_PREFLIGHT_BATCH" = 0 ] \
  && { [ -e "$STATE/$SPAWN_PREFLIGHT_ID.meta" ] || [ -L "$STATE/$SPAWN_PREFLIGHT_ID.meta" ]; }; then
  spawn_preflight_load_meta 0 || exit 1
fi
if [ "$BACKEND" = orca ] && [ "$SPAWN_PREFLIGHT_BATCH" = 0 ] && [ "$SPAWN_META_PRESENT" = 1 ]; then
  spawn_refuse_report_required_orca || exit 1
  [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] || spawn_refuse_existing_orca_provider_identity || exit 1
fi
if [ "$BACKEND" = orca ] && { [ "$RECOVERY_ACCOUNT" = 0 ] || [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; }; then
  fm_backend_orca_runtime_check || exit 1
fi
if [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$SPAWN_PREFLIGHT_BATCH" = 0 ] && [ "$SPAWN_META_PRESENT" = 0 ]; then
  spawn_preflight_load_meta 0 || exit 1
fi
if [ "$BACKEND" = orca ] && [ "$SPAWN_PREFLIGHT_BATCH" = 0 ]; then
  spawn_refuse_report_required_orca || exit 1
  [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] || spawn_refuse_existing_orca_provider_identity || exit 1
fi

if [ "$SPAWN_PREFLIGHT_BATCH" = 0 ]; then
  SECONDMATE_HOME_LIFECYCLE_LOCK=$(fm_secondmate_home_lifecycle_lock_acquire "$CHECKOUT_LOCK_ROOT" "$FM_HOME") || exit 1
  trap 'release_secondmate_home_lifecycle_locks' EXIT
  fm_checkout_trusted_dir "$FM_HOME" >/dev/null || {
    echo "error: active firstmate home was removed or redirected while spawn waited for lifecycle ownership" >&2
    exit 1
  }
  if [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; then
    [ -f "$FM_HOME/$SUB_HOME_MARKER" ] && [ ! -L "$FM_HOME/$SUB_HOME_MARKER" ] || {
      echo "error: unsafe secondmate home marker at $FM_HOME/$SUB_HOME_MARKER" >&2
      exit 1
    }
  elif [ -f "$FM_HOME/data/charter.md" ]; then
    echo "error: secondmate home changed while spawn waited for lifecycle ownership" >&2
    exit 1
  fi
  if [ "$TASK_HOME" != "$FM_HOME" ]; then
    # The compartment-child lane writes this spawn's task state into the
    # SECONDMATE's home, so that home's lifecycle is owned for the same window
    # as the primary's. A separate lock variable, because the --secondmate
    # spawn path owns SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK.
    TASK_HOME_LIFECYCLE_LOCK=$(fm_secondmate_home_lifecycle_lock_acquire "$CHECKOUT_LOCK_ROOT" "$TASK_HOME") || exit 1
    fm_checkout_trusted_dir "$TASK_HOME" >/dev/null || {
      echo "error: task home was removed or redirected while spawn waited for lifecycle ownership" >&2
      exit 1
    }
    [ -f "$TASK_HOME/$SUB_HOME_MARKER" ] && [ ! -L "$TASK_HOME/$SUB_HOME_MARKER" ] || {
      echo "error: unsafe or absent secondmate home marker at $TASK_HOME/$SUB_HOME_MARKER" >&2
      exit 1
    }
  fi
fi

if [ -n "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:-}" ]; then
  [ "${#POS[@]}" -ge 1 ] || { echo "error: inherited account lifecycle lock requires a task id" >&2; exit 1; }
  inherited_lock_id=${POS[0]}
  case "$inherited_lock_id" in *=*) echo "error: inherited account lifecycle lock does not support batch syntax" >&2; exit 1 ;; esac
  expected_lifecycle_lock="$STATE/.account-lifecycle-$inherited_lock_id.lock"
  inherited_lock_identity=
  if [ "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" = "$expected_lifecycle_lock" ]; then
    inherited_lock_identity=$(fm_account_lifecycle_lock_identity "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" 2>/dev/null) || inherited_lock_identity=
  fi
  case "$inherited_lock_identity" in
    *$'\n'*)
      LIFECYCLE_LOCK_INHERITED_PID=${inherited_lock_identity%%$'\n'*}
      LIFECYCLE_LOCK_INHERITED_START=${inherited_lock_identity#*$'\n'}
      ;;
    *)
      echo "error: invalid inherited account lifecycle lock for $inherited_lock_id" >&2
      exit 1
      ;;
  esac
  if [ -z "$LIFECYCLE_LOCK_INHERITED_PID" ] || [ -z "$LIFECYCLE_LOCK_INHERITED_START" ]; then
    echo "error: invalid inherited account lifecycle lock for $inherited_lock_id" >&2
    exit 1
  fi
  LIFECYCLE_LOCK=$FM_ACCOUNT_LIFECYCLE_LOCK_HELD
  if [ ! -f "$LIFECYCLE_LOCK" ] || [ -L "$LIFECYCLE_LOCK" ]; then
    echo "error: inherited account lifecycle lock for $inherited_lock_id cannot transfer ownership" >&2
    exit 1
  fi
  lifecycle_handoff_start=$(fm_account_process_start_time "$$") || {
    echo "error: cannot record inherited account lifecycle lock handoff for $inherited_lock_id" >&2
    exit 1
  }
  lifecycle_handoff_tmp=$(mktemp "$STATE/.account-lifecycle-$inherited_lock_id.handoff.XXXXXX") || exit 1
  if ! printf '%s\n%s\n' "$$" "$lifecycle_handoff_start" > "$lifecycle_handoff_tmp"; then
    rm -f "$lifecycle_handoff_tmp"
    exit 1
  fi
  current_lock_identity=$(fm_account_lifecycle_lock_identity "$LIFECYCLE_LOCK" 2>/dev/null || true)
  if [ "$current_lock_identity" != "$inherited_lock_identity" ] \
    || [ ! -f "$LIFECYCLE_LOCK" ] || [ -L "$LIFECYCLE_LOCK" ] \
    || ! mv "$lifecycle_handoff_tmp" "$LIFECYCLE_LOCK"; then
    rm -f "$lifecycle_handoff_tmp"
    echo "error: inherited account lifecycle lock was lost before ownership handoff for $inherited_lock_id" >&2
    exit 1
  fi
  LIFECYCLE_LOCK_OWNED=1
  trap '[ "${LIFECYCLE_LOCK_OWNED:-0}" != 1 ] || [ -z "${LIFECYCLE_LOCK:-}" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true; release_secondmate_home_lifecycle_locks' EXIT
  # The handoff replaces the lock inode while live ownership prevents reclaim until this child releases the replacement.
  if ! fm_account_lifecycle_lock_owned "$LIFECYCLE_LOCK"; then
    echo "error: inherited account lifecycle lock ownership handoff failed for $inherited_lock_id" >&2
    exit 1
  fi
fi
if [ "$RECOVERY_ACCOUNT" = 1 ]; then
  [ -f "$RESUME_META" ] || { echo "error: no metadata for managed recovery at $RESUME_META" >&2; exit 1; }
  fm_account_safe_file_destination "$RESUME_META" || { echo "error: unsafe metadata for managed recovery at $RESUME_META" >&2; exit 1; }
  if [ -z "$LIFECYCLE_LOCK" ]; then
    LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "${POS[0]}") || exit 1
    LIFECYCLE_LOCK_OWNED=1
  fi
  trap '[ "${LIFECYCLE_LOCK_OWNED:-0}" != 1 ] || [ -z "${LIFECYCLE_LOCK:-}" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true; release_secondmate_home_lifecycle_locks' EXIT
  current_spawn_meta=$(spawn_preflight_read_meta "$RESUME_META") || {
    echo "error: unsafe metadata for managed recovery at $RESUME_META" >&2
    exit 1
  }
  # The early snapshot owns preflight refusals only. Once lifecycle ownership
  # serializes recovery, refresh it so a waiter validates the committed
  # replacement generation instead of rejecting that generation as stale.
  SPAWN_META_SNAPSHOT=$current_spawn_meta
  current_recorded_kind=$(spawn_preflight_kind_value) || exit 1
  [ "$current_recorded_kind" = "$KIND" ] || {
    echo "error: managed recovery kind changed before launch for ${POS[0]}" >&2
    exit 1
  }
  rm -rf "$STATE/.${POS[0]}.account-native-launch" "$STATE/.${POS[0]}.account-native-ready" "$STATE/.${POS[0]}.account-native-go" || exit 1
  direct_recovery_cleanup=$(fm_account_meta_value "$RESUME_META" direct_recovery_cleanup)
  if [ -n "$direct_recovery_cleanup" ]; then
    [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] || {
      echo "error: retained direct recovery state exists for ${POS[0]}; use --recover-direct-account" >&2
      exit 1
    }
    [ "$direct_recovery_cleanup" = pending ] || {
      echo "error: invalid retained direct recovery state for ${POS[0]}" >&2
      exit 1
    }
    reconcile_failed_direct_recovery "${POS[0]}" || exit 1
  fi
  if [ "$(fm_account_meta_value "$RESUME_META" account_rollback_cleanup)" = pending ]; then
    rollback_id=${POS[0]}
    rollback_account_task=$(fm_account_meta_value "$RESUME_META" account_task)
    rollback_meta_lock=$(fm_account_meta_lock_acquire "$STATE" "$rollback_id") || exit 1
    if [ ! -f "$RESUME_META" ] || [ "$(fm_account_meta_value "$RESUME_META" account_rollback_cleanup)" != pending ] \
      || [ "$(fm_account_meta_value "$RESUME_META" account_task)" != "$rollback_account_task" ]; then
      fm_account_meta_lock_release "$rollback_meta_lock" >/dev/null 2>&1 || true
      echo "error: managed task generation changed before rollback cleanup for $rollback_id" >&2
      exit 1
    fi
    rollback_kind=$(fm_account_meta_value "$RESUME_META" kind)
    [ -n "$rollback_kind" ] || rollback_kind=ship
    rollback_backend=$(fm_backend_of_meta "$RESUME_META")
    rollback_target=$(fm_backend_target_of_meta "$RESUME_META")
    rollback_tmux_session_target=$(fm_account_meta_value "$RESUME_META" tmux_session_target)
    [ -n "$rollback_tmux_session_target" ] || rollback_tmux_session_target=$(fm_account_meta_value "$RESUME_META" window)
    rollback_tab=$(fm_account_meta_value "$RESUME_META" zellij_tab_id)
    rollback_home=$(fm_account_meta_value "$RESUME_META" home)
    rollback_tasktmp=$(fm_account_meta_value "$RESUME_META" tasktmp)
    rollback_generation=$(fm_account_meta_value "$RESUME_META" generation_id)
    rollback_backup=$(fm_account_meta_value "$RESUME_META" account_rollback_backup)
    fm_account_meta_lock_release "$rollback_meta_lock" || exit 1
    rollback_meta_lock=
    if [ -n "$rollback_tasktmp" ] && ! fm_account_task_tmp_is_expected "$rollback_id" "$rollback_tasktmp" "$rollback_generation"; then
      echo "error: unsafe task temp path in rollback metadata for $rollback_id: $rollback_tasktmp" >&2
      exit 1
    fi
    if [ -n "$rollback_target" ]; then
      spawn_managed_endpoint_kill "$rollback_backend" "$rollback_target" "$rollback_tab" "fm-$rollback_id" "$rollback_kind" "$rollback_home" "$rollback_tmux_session_target" 2>/dev/null || true
    fi
    rollback_endpoint_state=$(spawn_managed_endpoint_state "$rollback_backend" "$rollback_target" "fm-$rollback_id" "$rollback_kind" "$rollback_home" "$rollback_tmux_session_target" 2>/dev/null)
    case "$rollback_endpoint_state" in
      absent) ;;
      present)
        echo "error: failed Agent Fleet attempt endpoint is still alive for $rollback_id; retaining its lease and metadata" >&2
        exit 1
        ;;
      *)
        echo "error: failed Agent Fleet attempt endpoint state is unknown for $rollback_id; retaining its lease and metadata" >&2
        exit 1
        ;;
    esac
    if ! fm_account_cleanup_rollback "$RESUME_META" "$DATA" "$rollback_id"; then
      echo "error: failed Agent Fleet attempt cleanup remains pending for $rollback_id" >&2
      exit 1
    fi
    rollback_profile=$(fm_account_meta_value "$RESUME_META" account_profile)
    if [ -z "$rollback_profile" ] && [ "$rollback_kind" = secondmate ] && [ -z "$rollback_backup" ]; then
      rm -f "$RESUME_META" "$STATE/$rollback_id.status" "$STATE/$rollback_id.turn-ended" "$STATE/$rollback_id.check.sh" "$STATE/$rollback_id.pi-ext.ts" "$STATE/$rollback_id.grok-turnend-token"
      if [ -n "$rollback_tasktmp" ] \
        && { fm_account_task_tmp_is_current "$rollback_id" "$rollback_tasktmp" "$rollback_generation" \
          || fm_account_task_tmp_is_previous "$rollback_id" "$rollback_tasktmp"; }; then
        fm_account_safe_remove_task_tmp "$rollback_id" "$rollback_tasktmp" "$rollback_generation" || exit 1
      fi
    fi
    if [ -z "$rollback_profile" ]; then
      if [ -n "$rollback_backup" ]; then
        echo "error: failed Agent Fleet attempt was cleaned for $rollback_id and the previous task state was restored; rerun against the restored task generation" >&2
      elif [ "$rollback_kind" = secondmate ]; then
        echo "error: failed Agent Fleet attempt was cleaned for $rollback_id; retry the secondmate spawn without tearing down its home" >&2
      else
        echo "error: failed Agent Fleet attempt was cleaned for $rollback_id; tear down its retained worktree before spawning again" >&2
      fi
      exit 1
    fi
  fi
  if [ "$(fm_account_meta_value "$RESUME_META" account_predecessor_cleanup)" = pending ]; then
    cleanup_id=${POS[0]}
    cleanup_account_task=$(fm_account_meta_value "$RESUME_META" account_task)
    FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$LIFECYCLE_LOCK" "$SCRIPT_DIR/fm-account-session-sync.sh" "$cleanup_id" --require >/dev/null || exit 1
    cleanup_lock=$(fm_account_meta_lock_acquire "$STATE" "$cleanup_id") || exit 1
    if [ ! -f "$RESUME_META" ] || [ "$(fm_account_meta_value "$RESUME_META" account_task)" != "$cleanup_account_task" ]; then
      fm_account_meta_lock_release "$cleanup_lock" >/dev/null 2>&1 || true
      echo "error: managed task generation changed before predecessor cleanup for $cleanup_id" >&2
      exit 1
    fi
    fm_account_meta_lock_release "$cleanup_lock" || exit 1
    cleanup_lock=
    if ! fm_account_cleanup_predecessor "$RESUME_META" "$DATA" "$cleanup_id"; then
      echo "error: predecessor Agent Fleet cleanup remains pending for $cleanup_id" >&2
      exit 1
    fi
    if [ "$CONTINUE_ACCOUNT" = 1 ]; then
      echo "completed predecessor Agent Fleet cleanup for $cleanup_id"
      exit 0
    fi
  fi
  recorded_backend=$(fm_backend_of_meta "$RESUME_META")
  if [ "$BACKEND_SET" = 1 ] && [ "$BACKEND_ARG" != "$recorded_backend" ]; then
    echo "error: account recovery backend override '$BACKEND_ARG' does not match recorded backend '$recorded_backend'" >&2
    exit 1
  fi
  BACKEND_ARG=$recorded_backend
  BACKEND_SET=1
fi

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND" = orca ] && [ "$RECOVERY_ACCOUNT" = 1 ] && [ "$DIRECT_ACCOUNT_RECOVERY" = 0 ]; then
  echo "error: managed account recovery is not implemented for backend=orca" >&2
  exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
ORCA_TERMINAL_PROOF=
ORCA_REPO_ID=
ORCA_EXPECTED_TASK=
ID=
ACCOUNT_LEASE_CREATED=0
FM_ACCOUNT_MUTATION_ACQUIRED=0
ACCOUNT_SPAWN_COMMITTED=0
ACCOUNT_EFFECTIVE_MODE=off
ACCOUNT_PRIMARY_MODE=off
ACCOUNT_TASK=
ACCOUNT_ATTEMPT=
SPAWN_GENERATION_ID=
ACCOUNT_PREDECESSOR_TASK=
ACCOUNT_PREDECESSOR_ATTEMPT=
ACCOUNT_PREDECESSOR_PROVIDER=
ACCOUNT_PREDECESSOR_PROFILE=
ACCOUNT_PREDECESSOR_POOL=
ACCOUNT_PREDECESSOR_SESSION=
CONTINUATION_PACKET=
ENDPOINT_CREATED=0
T=
WORKTREE_CREATED=0
WORKTREE_RETAIN_ON_ABORT=0
WORKTREE_EXPECTED_TIP=
WORKTREE_ACQUIRE_RECORD=
WORKTREE_ACQUIRE_OWNER_START=
WORKTREE_ACQUIRE_ENDPOINT_PHASE=not-created
WORKTREE_ACQUIRE_TASKTMP_PHASE=not-created
META_INSTALLED=0
META_BACKUP=
EXISTING_ARTIFACT_BACKUP=
META_WRITE_LOCK=
RAW_LAUNCH=0
ACCOUNT_NATIVE_LAUNCH_SCRIPT=
ACCOUNT_NATIVE_LAUNCH_READY=
ACCOUNT_NATIVE_LAUNCH_GO=
ACCOUNT_NATIVE_LAUNCH_DIR=
DIRECT_ACCOUNT_ROUTING=0
# Secondmate account selection. A secondmate is a long-lived supervisor whose
# workspace is a firstmate home, not a task worktree, so it must NOT take on
# DIRECT_ACCOUNT_ROUTING's worktree-identity, authoritative-final-state, and
# fresh-selection-per-respawn contract. This flag is the narrow half it does
# need: pick a rotated account directory and bind the provider identity onto the
# launch, so secondmates stop inheriting whatever ambient identity the primary
# happened to be running under and stop piling onto one account.
DIRECT_ACCOUNT_SECONDMATE=0
# Set when an observe-mode secondmate wanted a routed account but none could be
# selected, so it launched on the provider's default identity. Recorded in task
# metadata so a degraded launch is visible rather than looking like a routed one.
DIRECT_ACCOUNT_DEGRADED=0
DIRECT_ACCOUNT_HOME=
# Environment delivered natively by `herdr agent start --env KEY=VALUE` (one
# repeated flag per entry). Empty for every other backend, which has no native
# env channel and keeps using command-scoped shell prefixes instead.
HERDR_AGENT_ENV=()
DIRECT_ACCOUNT_RESPAWN=0
DIRECT_ACCOUNT_PREPARE_DEFERRED=0
WORKTREE_GIT_DIR=
WORKTREE_GIT_DIR_IDENTITY=
WORKTREE_GIT_REF=
WORKTREE_GIT_HEAD=
WORKTREE_GIT_SETUP_REF=
WORKTREE_GIT_SETUP_HEAD=
CONFIG_INHERIT_REPORT_TMP=
ORIGINAL_STATUS_PRESENT=-1
ORIGINAL_TURN_ENDED_PRESENT=-1
ORIGINAL_CHECK_PRESENT=-1
ORIGINAL_PI_EXT_PRESENT=-1
ORIGINAL_GROK_TOKEN_PRESENT=-1
ORIGINAL_PROVISION_LOG_PRESENT=-1
ORIGINAL_TASK_TMP_PRESENT=-1
PROVISION_LOG=

spawn_test_lab_enabled() {
  fm_account_test_lab_enabled \
    || [ "${FM_ACCOUNT_DIRECTORY_TEST_LAB:-}" = firstmate-account-directory-test-lab-v1 ]
}

snapshot_existing_artifacts() {
  local backup name source tasktmp=$SPAWN_TASK_TMP
  backup=$(mktemp -d "$STATE/.$ID.artifacts.rollback.XXXXXX") || return 1
  for name in "$ID.status" "$ID.turn-ended" "$ID.check.sh" "$ID.pi-ext.ts" "$ID.grok-turnend-token"; do
    source="$STATE/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      if ! cp -Pp "$source" "$backup/$name"; then
        rm -rf "$backup"
        return 1
      fi
    fi
  done
  [ ! -e "$tasktmp" ] || : > "$backup/tasktmp-existed"
  [ ! -e "$tasktmp/gotmp" ] || : > "$backup/gotmp-existed"
  EXISTING_ARTIFACT_BACKUP=$backup
}

discard_existing_artifact_backup() {
  [ -z "$EXISTING_ARTIFACT_BACKUP" ] || rm -rf "$EXISTING_ARTIFACT_BACKUP"
  EXISTING_ARTIFACT_BACKUP=
}

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  [ "$raw" != "$ORCA_WORKTREE_ID" ] || return 1
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  [ "$rest" != "$WT" ] || return 1
  rest=${rest#*$'\t'}
  ORCA_TERMINAL=${rest%%$'\t'*}
  [ "$rest" != "$ORCA_TERMINAL" ] || return 1
  rest=${rest#*$'\t'}
  ORCA_TERMINAL_PROOF=${rest%%$'\t'*}
  [ "$rest" != "$ORCA_TERMINAL_PROOF" ] || return 1
  rest=${rest#*$'\t'}
  ORCA_REPO_ID=$rest
  case "$ORCA_REPO_ID" in *$'\t'*) return 1 ;; esac
}

persist_orca_cleanup_quarantine() {
  local phase=$1
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  python3 - "$STATE" "$STATE/$ID.meta" "$phase" \
    "${W:-fm-$ID}" "${WT:-}" "${PROJ_ABS:-}" "${HARNESS:-}" "${KIND:-ship}" \
    "${MODE:-no-mistakes}" "${YOLO:-off}" "${TASK_TMP:-}" "${MODEL:-default}" \
    "${EFFORT:-default}" "${ORCA_WORKTREE_ID:-}" "${ORCA_TERMINAL:-}" \
    "${ORCA_TERMINAL_PROOF:-unproven}" "${ORCA_REPO_ID:-}" "fm-$ID" \
    "repo-path:${PROJ_ABS:-}" <<'PY'
import os
import stat
import sys
import tempfile

(state, metadata, phase, window, worktree, project, harness, kind, mode, yolo,
 tasktmp, model, effort, worktree_id, terminal, proof, repo_id, expected_task,
 provider_scope) = sys.argv[1:]
values = [
    ("window", window),
    ("worktree", worktree),
    ("project", project),
    ("harness", harness),
    ("kind", kind),
    ("mode", mode),
    ("yolo", yolo),
    ("tasktmp", tasktmp),
    ("model", model),
    ("effort", effort),
    ("backend", "orca"),
]
if worktree_id:
    values.append(("orca_worktree_id", worktree_id))
if terminal:
    values.append(("terminal", terminal))
values.extend([
    ("orca_cleanup_pending", "1"),
    ("orca_cleanup_phase", phase),
    ("orca_terminal_proof", proof),
    ("orca_repo_id", repo_id),
    ("orca_expected_task", expected_task),
    ("orca_discovery_label", expected_task),
    ("orca_provider_scope", provider_scope),
])
owned = {
    "window", "worktree", "project", "harness", "kind", "mode", "yolo",
    "tasktmp", "model", "effort", "backend", "orca_worktree_id", "terminal",
    "orca_cleanup_pending", "orca_cleanup_phase", "orca_terminal_proof",
    "orca_repo_id", "orca_expected_task", "orca_discovery_label",
    "orca_provider_scope",
}
for key, value in values:
    if any(character in value for character in "\0\r\n"):
        raise SystemExit(1)
state_metadata = os.lstat(state)
if not stat.S_ISDIR(state_metadata.st_mode) or stat.S_ISLNK(state_metadata.st_mode):
    raise SystemExit(1)
preserved = []
retained = {}
try:
    metadata_state = os.lstat(metadata)
except FileNotFoundError:
    metadata_state = None
if metadata_state is not None:
    if not stat.S_ISREG(metadata_state.st_mode) or stat.S_ISLNK(metadata_state.st_mode):
        raise SystemExit(1)
    with open(metadata, encoding="utf-8") as stream:
        for line in stream:
            key = line.split("=", 1)[0]
            if key not in owned:
                preserved.append(line)
            elif "=" in line:
                retained[key] = line.rstrip("\n").split("=", 1)[1]
values = [
    (key, retained.get(key, value) if value == "" else value)
    for key, value in values
]
for key, value in values:
    if any(character in value for character in "\0\r\n"):
        raise SystemExit(1)
descriptor, temporary = tempfile.mkstemp(prefix=".orca-quarantine.", dir=state)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.writelines(preserved)
        for key, value in values:
            output.write(f"{key}={value}\n")
        output.flush()
        os.fsync(output.fileno())
    try:
        destination = os.lstat(metadata)
    except FileNotFoundError:
        destination = None
    if destination is not None and (
        not stat.S_ISREG(destination.st_mode) or stat.S_ISLNK(destination.st_mode)
    ):
        raise OSError("unsafe quarantine destination")
    os.replace(temporary, metadata)
    directory = os.open(state, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

persist_failed_account_rollback() {
  local meta tmp current_task backup_name artifact_backup_name rollback_window preserve_extensions=0
  mkdir -p "$STATE" || return 1
  fm_account_real_directory "$STATE" || return 1
  meta="$STATE/$ID.meta"
  tmp=$(mktemp "$STATE/.$ID.meta.rollback-pending.XXXXXX") || return 1
  current_task=$(fm_account_meta_value "$meta" account_task)
  if [ -f "$meta" ] && [ "$current_task" = "$ACCOUNT_TASK" ]; then
    awk '!/^account_rollback_/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    [ ! -f "$meta" ] || preserve_extensions=1
    rollback_window=${META_WINDOW:-${T:-${W:-fm-$ID}}}
    {
      echo "window=$rollback_window"
      echo "worktree=${WT:-}"
      echo "project=${PROJ_ABS:-}"
      echo "harness=${HARNESS:-}"
      echo "kind=${KIND:-ship}"
      echo "mode=${MODE:-no-mistakes}"
      echo "yolo=${YOLO:-off}"
      echo "tasktmp=${TASK_TMP:-}"
      echo "tasktmp_phase=${WORKTREE_ACQUIRE_TASKTMP_PHASE:-not-created}"
      echo "model=${MODEL:-default}"
      echo "effort=${EFFORT:-default}"
      echo "generation_id=${SPAWN_GENERATION_ID:-account:$ACCOUNT_TASK:${ACCOUNT_ATTEMPT:-legacy}}"
      [ -z "${ACCOUNT_POOL:-}" ] || echo "account_pool=$ACCOUNT_POOL"
      [ -z "${ACCOUNT_PROFILE:-}" ] || echo "account_profile=$ACCOUNT_PROFILE"
      echo "account_task=$ACCOUNT_TASK"
      echo "account_attempt=${ACCOUNT_ATTEMPT:-legacy}"
      [ -z "${ACCOUNT_PREDECESSOR_TASK:-}" ] || echo "account_predecessor_task=$ACCOUNT_PREDECESSOR_TASK"
      [ -z "${ACCOUNT_PREDECESSOR_ATTEMPT:-}" ] || echo "account_predecessor_attempt=$ACCOUNT_PREDECESSOR_ATTEMPT"
      [ -z "${ACCOUNT_PREDECESSOR_PROVIDER:-}" ] || echo "account_predecessor_provider=$ACCOUNT_PREDECESSOR_PROVIDER"
      [ -z "${ACCOUNT_PREDECESSOR_PROFILE:-}" ] || echo "account_predecessor_profile=$ACCOUNT_PREDECESSOR_PROFILE"
      [ -z "${ACCOUNT_PREDECESSOR_POOL:-}" ] || echo "account_predecessor_pool=$ACCOUNT_PREDECESSOR_POOL"
      [ -z "${ACCOUNT_PREDECESSOR_SESSION:-}" ] || echo "account_predecessor_session=$ACCOUNT_PREDECESSOR_SESSION"
      [ "${BACKEND:-tmux}" = tmux ] || echo "backend=$BACKEND"
      [ "${BACKEND:-tmux}" != tmux ] || [ -z "${WID:-}" ] || echo "tmux_window_id=$WID"
      [ "${BACKEND:-tmux}" != tmux ] || [ -z "${META_WINDOW:-${T:-}}" ] || echo "tmux_session_target=${META_WINDOW:-$T}"
      [ "${BACKEND:-tmux}" != herdr ] || {
        echo "herdr_session=${HERDR_SES:-}"
        echo "herdr_workspace_id=${HERDR_WORKSPACE_ID:-}"
        echo "herdr_tab_id=${HERDR_TAB_ID:-}"
        echo "herdr_pane_id=${HERDR_PANE_ID:-}"
      }
      [ "${BACKEND:-tmux}" != zellij ] || {
        echo "zellij_session=${ZELLIJ_SES:-}"
        echo "zellij_tab_id=${ZELLIJ_TAB_ID:-}"
        echo "zellij_pane_id=${ZELLIJ_PANE_ID:-}"
      }
      [ "${BACKEND:-tmux}" != cmux ] || {
        echo "cmux_workspace_id=${CMUX_WORKSPACE_ID:-}"
        echo "cmux_surface_id=${CMUX_SURFACE_ID:-}"
      }
      [ "${KIND:-ship}" != secondmate ] || {
        echo "home=${PROJ_ABS:-}"
        echo "projects=${SECONDMATE_PROJECTS:-}"
      }
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if [ "$preserve_extensions" = 1 ]; then
    fm_account_meta_merge_extensions "$meta" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf 'account_rollback_cleanup=pending\n' >> "$tmp"
  if [ -n "$META_BACKUP" ]; then
    backup_name=${META_BACKUP##*/}
    printf 'account_rollback_backup=%s\n' "$backup_name" >> "$tmp"
  fi
  if [ -n "$EXISTING_ARTIFACT_BACKUP" ]; then
    artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
    printf 'account_rollback_artifacts=%s\n' "$artifact_backup_name" >> "$tmp"
  fi
  [ "$RESUME_ACCOUNT" != 1 ] || printf 'account_rollback_preserve_session=1\n' >> "$tmp"
  fm_account_safe_file_destination "$meta" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  META_INSTALLED=1
}

persist_failed_direct_recovery() {
  local meta="$STATE/$ID.meta" tmp backup_name artifacts_name retained_window retained_tmux_session account_home
  [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ] || return 1
  [ -n "$EXISTING_ARTIFACT_BACKUP" ] && [ -d "$EXISTING_ARTIFACT_BACKUP" ] || return 1
  backup_name=${META_BACKUP##*/}
  artifacts_name=${EXISTING_ARTIFACT_BACKUP##*/}
  retained_window=${META_WINDOW:-${T:-${W:-fm-$ID}}}
  retained_tmux_session=
  if [ "${BACKEND:-tmux}" = tmux ]; then
    retained_tmux_session=${META_WINDOW:-${SES:-firstmate}:${W:-fm-$ID}}
    retained_window=$retained_tmux_session
  fi
  account_home=${DIRECT_ACCOUNT_HOME:-${RECORDED_ACCOUNT_HOME:-}}
  tmp=$(mktemp "$STATE/.$ID.meta.direct-recovery-pending.XXXXXX") || return 1
  {
    echo "window=$retained_window"
    echo "worktree=${WT:-${RECORDED_WORKTREE:-}}"
    echo "worktree_git_dir=${WORKTREE_GIT_DIR:-${RECORDED_WORKTREE_GIT_DIR:-}}"
    echo "worktree_git_dir_identity=${WORKTREE_GIT_DIR_IDENTITY:-${RECORDED_WORKTREE_GIT_DIR_IDENTITY:-}}"
    [ -z "${WORKTREE_GIT_REF:-${RECORDED_WORKTREE_GIT_REF:-}}" ] || echo "worktree_git_ref=${WORKTREE_GIT_REF:-${RECORDED_WORKTREE_GIT_REF:-}}"
    [ -z "${WORKTREE_GIT_HEAD:-${RECORDED_WORKTREE_GIT_HEAD:-}}" ] || echo "worktree_git_head=${WORKTREE_GIT_HEAD:-${RECORDED_WORKTREE_GIT_HEAD:-}}"
    [ -z "${WORKTREE_GIT_SETUP_REF:-}" ] || echo "worktree_git_setup_ref=$WORKTREE_GIT_SETUP_REF"
    [ -z "${WORKTREE_GIT_SETUP_HEAD:-}" ] || echo "worktree_git_setup_head=$WORKTREE_GIT_SETUP_HEAD"
    echo "project=${PROJ_ABS:-${RECORDED_PROJECT:-}}"
    echo "harness=${HARNESS:-${RECORDED_HARNESS:-}}"
    echo "kind=${KIND:-${RECORDED_KIND:-ship}}"
    echo "mode=${MODE:-${RECORDED_MODE:-no-mistakes}}"
    echo "yolo=${YOLO:-${RECORDED_YOLO:-off}}"
    echo "tasktmp=${TASK_TMP:-$SPAWN_TASK_TMP}"
    echo "tasktmp_phase=${WORKTREE_ACQUIRE_TASKTMP_PHASE:-not-created}"
    echo "model=${RECORDED_MODEL:-${MODEL:-default}}"
    echo "effort=${RECORDED_EFFORT:-${EFFORT:-default}}"
    echo "generation_id=${RECORDED_GENERATION:-${SPAWN_GENERATION_ID:-}}"
    [ "${RECORDED_REPORT_REQUIRED_SET:-0}" != 1 ] || echo "report_required=${RECORDED_REPORT_REQUIRED:-}"
    [ -z "$account_home" ] || echo "account_home=$account_home"
    [ "${BACKEND:-tmux}" = tmux ] || echo "backend=$BACKEND"
    [ "${BACKEND:-tmux}" != tmux ] || [ -z "${WID:-}" ] || echo "tmux_window_id=$WID"
    [ "${BACKEND:-tmux}" != tmux ] || echo "tmux_session_target=$retained_tmux_session"
    [ "${BACKEND:-tmux}" != herdr ] || {
      echo "herdr_session=${HERDR_SES:-}"
      echo "herdr_workspace_id=${HERDR_WORKSPACE_ID:-}"
      echo "herdr_tab_id=${HERDR_TAB_ID:-}"
      echo "herdr_pane_id=${HERDR_PANE_ID:-}"
    }
    [ "${BACKEND:-tmux}" != zellij ] || {
      echo "zellij_session=${ZELLIJ_SES:-}"
      echo "zellij_tab_id=${ZELLIJ_TAB_ID:-}"
      echo "zellij_pane_id=${ZELLIJ_PANE_ID:-}"
    }
    [ "${BACKEND:-tmux}" != orca ] || {
      echo "orca_worktree_id=${ORCA_WORKTREE_ID:-}"
      echo "terminal=${ORCA_TERMINAL:-${T:-}}"
    }
    [ "${BACKEND:-tmux}" != cmux ] || {
      echo "cmux_workspace_id=${CMUX_WORKSPACE_ID:-}"
      echo "cmux_surface_id=${CMUX_SURFACE_ID:-}"
    }
    echo "direct_recovery_cleanup=pending"
    echo "direct_recovery_backup=$backup_name"
    echo "direct_recovery_artifacts=$artifacts_name"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_account_meta_merge_extensions "$meta" "$tmp" || { rm -f "$tmp"; return 1; }
  fm_account_safe_file_destination "$meta" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  META_INSTALLED=1
}

persist_failed_direct_spawn() {  # <endpoint-created:0|1>
  local endpoint_created=$1 meta="$STATE/$ID.meta" tmp retained_window retained_tmux_session retained_mode retained_yolo backup_name artifacts_name preserve_extensions=0
  case "$endpoint_created" in 0|1) ;; *) return 1 ;; esac
  retained_window=
  retained_tmux_session=
  retained_mode=${MODE:-}
  retained_yolo=${YOLO:-off}
  [ -n "$retained_mode" ] || retained_mode=no-mistakes
  if [ "$endpoint_created" = 1 ]; then
    retained_window=${META_WINDOW:-${T:-${W:-fm-$ID}}}
    if [ "${BACKEND:-tmux}" = tmux ]; then
      retained_tmux_session=${META_WINDOW:-${SES:-firstmate}:${W:-fm-$ID}}
      retained_window=$retained_tmux_session
    fi
  fi
  if [ -n "${WT:-}" ] && [ -d "$WT" ]; then
    if [ -z "${WORKTREE_GIT_DIR:-}" ] || [ -z "${WORKTREE_GIT_DIR_IDENTITY:-}" ]; then
      capture_worktree_git_physical_identity "$WT" >/dev/null 2>&1 || true
    fi
    if [ -z "${WORKTREE_GIT_REF:-}" ] && [ -z "${WORKTREE_GIT_HEAD:-}" ]; then
      capture_direct_launch_authoritative_state >/dev/null 2>&1 || true
    fi
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.direct-spawn-pending.XXXXXX") || return 1
  if [ "$META_INSTALLED" = 1 ] && [ -f "$meta" ] \
    && [ "$(fm_account_meta_value "$meta" generation_id)" = "$SPAWN_GENERATION_ID" ]; then
    if [ "$endpoint_created" = 1 ]; then
      awk '!/^direct_spawn_cleanup=/ && !/^direct_spawn_endpoint=/ && !/^direct_spawn_backup=/ && !/^direct_spawn_artifacts=/ && !/^rollback_pending=/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
      awk '
        !/^(window|tmux_window_id|tmux_session_target|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|zellij_session|zellij_tab_id|zellij_pane_id|cmux_workspace_id|cmux_surface_id)=/ &&
        !/^direct_spawn_cleanup=/ && !/^direct_spawn_endpoint=/ && !/^direct_spawn_backup=/ && !/^direct_spawn_artifacts=/ && !/^rollback_pending=/
      ' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
      printf 'window=\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
  else
    [ ! -f "$meta" ] || preserve_extensions=1
    {
      echo "window=$retained_window"
      echo "worktree=${WT:-}"
      [ -z "${WORKTREE_GIT_DIR:-}" ] || echo "worktree_git_dir=$WORKTREE_GIT_DIR"
      [ -z "${WORKTREE_GIT_DIR_IDENTITY:-}" ] || echo "worktree_git_dir_identity=$WORKTREE_GIT_DIR_IDENTITY"
      [ -z "${WORKTREE_GIT_REF:-}" ] || echo "worktree_git_ref=$WORKTREE_GIT_REF"
      [ -z "${WORKTREE_GIT_HEAD:-}" ] || echo "worktree_git_head=$WORKTREE_GIT_HEAD"
      [ -z "${WORKTREE_GIT_SETUP_REF:-}" ] || echo "worktree_git_setup_ref=$WORKTREE_GIT_SETUP_REF"
      [ -z "${WORKTREE_GIT_SETUP_HEAD:-}" ] || echo "worktree_git_setup_head=$WORKTREE_GIT_SETUP_HEAD"
      echo "project=${PROJ_ABS:-}"
      echo "harness=${HARNESS:-}"
      echo "kind=${KIND:-ship}"
      echo "mode=$retained_mode"
      echo "yolo=$retained_yolo"
      echo "tasktmp=${TASK_TMP:-$SPAWN_TASK_TMP}"
      echo "tasktmp_phase=${WORKTREE_ACQUIRE_TASKTMP_PHASE:-not-created}"
      echo "model=${MODEL:-default}"
      echo "effort=${EFFORT:-default}"
      echo "generation_id=${SPAWN_GENERATION_ID:-}"
      echo "report_required=1"
      [ -z "${DIRECT_ACCOUNT_HOME:-}" ] || echo "account_home=$DIRECT_ACCOUNT_HOME"
      [ "${BACKEND:-tmux}" = tmux ] || echo "backend=$BACKEND"
      [ "$endpoint_created" != 1 ] || [ "${BACKEND:-tmux}" != tmux ] || [ -z "${WID:-}" ] || echo "tmux_window_id=$WID"
      [ "$endpoint_created" != 1 ] || [ "${BACKEND:-tmux}" != tmux ] || echo "tmux_session_target=$retained_tmux_session"
      [ "$endpoint_created" != 1 ] || [ "${BACKEND:-tmux}" != herdr ] || {
        echo "herdr_session=${HERDR_SES:-}"
        echo "herdr_workspace_id=${HERDR_WORKSPACE_ID:-}"
        echo "herdr_tab_id=${HERDR_TAB_ID:-}"
        echo "herdr_pane_id=${HERDR_PANE_ID:-}"
      }
      [ "$endpoint_created" != 1 ] || [ "${BACKEND:-tmux}" != zellij ] || {
        echo "zellij_session=${ZELLIJ_SES:-}"
        echo "zellij_tab_id=${ZELLIJ_TAB_ID:-}"
        echo "zellij_pane_id=${ZELLIJ_PANE_ID:-}"
      }
      [ "$endpoint_created" != 1 ] || [ "${BACKEND:-tmux}" != cmux ] || {
        echo "cmux_workspace_id=${CMUX_WORKSPACE_ID:-}"
        echo "cmux_surface_id=${CMUX_SURFACE_ID:-}"
      }
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if [ "$endpoint_created" = 1 ]; then
    case "${BACKEND:-tmux}" in
      tmux)
        grep -q '^tmux_window_id=' "$tmp" || printf 'tmux_window_id=%s\n' "${WID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^tmux_session_target=' "$tmp" || printf 'tmux_session_target=%s\n' "$retained_tmux_session" >> "$tmp" || { rm -f "$tmp"; return 1; }
        ;;
      herdr)
        grep -q '^herdr_session=' "$tmp" || printf 'herdr_session=%s\n' "${HERDR_SES:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^herdr_workspace_id=' "$tmp" || printf 'herdr_workspace_id=%s\n' "${HERDR_WORKSPACE_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^herdr_tab_id=' "$tmp" || printf 'herdr_tab_id=%s\n' "${HERDR_TAB_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^herdr_pane_id=' "$tmp" || printf 'herdr_pane_id=%s\n' "${HERDR_PANE_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        ;;
      zellij)
        grep -q '^zellij_session=' "$tmp" || printf 'zellij_session=%s\n' "${ZELLIJ_SES:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^zellij_tab_id=' "$tmp" || printf 'zellij_tab_id=%s\n' "${ZELLIJ_TAB_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^zellij_pane_id=' "$tmp" || printf 'zellij_pane_id=%s\n' "${ZELLIJ_PANE_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        ;;
      cmux)
        grep -q '^cmux_workspace_id=' "$tmp" || printf 'cmux_workspace_id=%s\n' "${CMUX_WORKSPACE_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        grep -q '^cmux_surface_id=' "$tmp" || printf 'cmux_surface_id=%s\n' "${CMUX_SURFACE_ID:-}" >> "$tmp" || { rm -f "$tmp"; return 1; }
        ;;
    esac
  fi
  if [ "$preserve_extensions" = 1 ]; then
    fm_account_meta_merge_extensions "$meta" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  [ "$endpoint_created" != 0 ] || printf 'direct_spawn_endpoint=not-created\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'direct_spawn_cleanup=pending\nrollback_pending=1\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
    backup_name=${META_BACKUP##*/}
    printf 'direct_spawn_backup=%s\n' "$backup_name" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if [ -n "$EXISTING_ARTIFACT_BACKUP" ] && [ -d "$EXISTING_ARTIFACT_BACKUP" ]; then
    artifacts_name=${EXISTING_ARTIFACT_BACKUP##*/}
    printf 'direct_spawn_artifacts=%s\n' "$artifacts_name" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  fm_account_safe_file_destination "$meta" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  META_INSTALLED=1
}

clear_account_rollback_markers() {
  local meta="$STATE/$ID.meta" tmp
  tmp=$(mktemp "$STATE/.$ID.meta.rollback-commit.XXXXXX") || return 1
  awk '!/^account_rollback_/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_account_safe_file_destination "$meta" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

persist_failed_account_rollback_short() {
  local lock status
  lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || return 1
  if persist_failed_account_rollback; then status=0; else status=$?; fi
  fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || status=1
  return "$status"
}

cleanup_continuation_launch_transport() {
  [ -n "${CONTINUATION_LAUNCH_DIR:-}" ] || return 0
  if [ -n "${CONTINUATION_PROMPT_FILE:-}" ] && [ -n "${CONTINUATION_PROMPT_DIR_ID:-}" ] \
    && [ -n "${CONTINUATION_PROMPT_FILE_ID:-}" ]; then
    python3 "$SCRIPT_DIR/fm-prompt-exec.py" --cleanup "$CONTINUATION_PROMPT_FILE" \
      "$CONTINUATION_PROMPT_DIR_ID" "$CONTINUATION_PROMPT_FILE_ID" >/dev/null 2>&1 || true
  fi
  CONTINUATION_LAUNCH_DIR=
  CONTINUATION_PROMPT_FILE=
  CONTINUATION_PROMPT_DIR_ID=
  CONTINUATION_PROMPT_FILE_ID=
  CONTINUATION_PROMPT_CONTENT_ID=
}

create_worktree_acquisition_record() {
  local record tmp start home_real
  start=$(fm_account_process_start_time "$$") || {
    echo "error: cannot record Treehouse acquisition owner for $ID" >&2
    return 1
  }
  record="$STATE/.worktree-acquire-$ID.pending"
  [ ! -e "$record" ] && [ ! -L "$record" ] || {
    echo "error: stale or concurrent Treehouse acquisition record exists for $ID; let auto-reap reconcile it before retrying" >&2
    return 1
  }
  tmp=$(mktemp "$STATE/.worktree-acquire-$ID.XXXXXX") || return 1
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || { rm -f "$tmp"; return 1; }
  {
    printf '%s\n%s\n' "$$" "$start"
    printf 'id=%s\n' "$ID"
    printf 'project=%s\n' "$PROJ_ABS"
    printf 'holder=firstmate-%s\n' "$ID"
    printf 'home=%s\n' "$home_real"
    printf 'kind=%s\nmode=%s\nyolo=%s\n' "$KIND" "$MODE" "$YOLO"
    printf 'generation_id=%s\ntasktmp=%s\ntasktmp_phase=not-created\n' "$SPAWN_GENERATION_ID" "$TASK_TMP"
    printf 'backend=%s\nendpoint_phase=not-created\nworktree=\n' "$BACKEND"
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! ln "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: could not claim Treehouse acquisition record for $ID" >&2
    return 1
  fi
  rm -f "$tmp"
  WORKTREE_ACQUIRE_RECORD=$record
  WORKTREE_ACQUIRE_OWNER_START=$start
}

record_acquired_worktree() {
  local tmp
  [ -n "$WORKTREE_ACQUIRE_RECORD" ] || return 1
  [ "$(sed -n '1p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$$" ] \
    && [ "$(sed -n '2p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$WORKTREE_ACQUIRE_OWNER_START" ] || {
    echo "error: Treehouse acquisition ownership changed for $ID" >&2
    return 1
  }
  tmp=$(mktemp "$STATE/.worktree-acquire-$ID.update.XXXXXX") || return 1
  if ! sed '/^worktree=/d' "$WORKTREE_ACQUIRE_RECORD" > "$tmp" \
    || ! printf 'worktree=%s\n' "$WT" >> "$tmp" \
    || ! mv "$tmp" "$WORKTREE_ACQUIRE_RECORD"; then
      rm -f "$tmp"
      return 1
  fi
}

persist_worktree_acquisition_phases() {
  local tmp
  [ -n "$WORKTREE_ACQUIRE_RECORD" ] || return 0
  [ "$(sed -n '1p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$$" ] \
    && [ "$(sed -n '2p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$WORKTREE_ACQUIRE_OWNER_START" ] || {
    echo "error: Treehouse acquisition ownership changed for $ID" >&2
    return 1
  }
  case "$WORKTREE_ACQUIRE_ENDPOINT_PHASE" in not-created|creating|created) ;; *) return 1 ;; esac
  case "$WORKTREE_ACQUIRE_TASKTMP_PHASE" in not-created|created) ;; *) return 1 ;; esac
  if [ "$WORKTREE_ACQUIRE_ENDPOINT_PHASE" = created ]; then
    case "$BACKEND" in tmux|herdr|zellij|cmux) ;; *) return 1 ;; esac
  fi
  tmp=$(mktemp "$STATE/.worktree-acquire-$ID.phase.XXXXXX") || return 1
  if ! awk '
    !/^(backend|endpoint_phase|tasktmp_phase|window|tmux_window_id|tmux_session_target|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|zellij_session|zellij_tab_id|zellij_pane_id|cmux_workspace_id|cmux_surface_id)=/
  ' "$WORKTREE_ACQUIRE_RECORD" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  {
    printf 'backend=%s\n' "$BACKEND"
    printf 'endpoint_phase=%s\n' "$WORKTREE_ACQUIRE_ENDPOINT_PHASE"
    printf 'tasktmp_phase=%s\n' "$WORKTREE_ACQUIRE_TASKTMP_PHASE"
    if [ "$WORKTREE_ACQUIRE_ENDPOINT_PHASE" = created ]; then
      printf 'window=%s\n' "$T"
      case "$BACKEND" in
        tmux)
          printf 'tmux_window_id=%s\n' "$WID"
          printf 'tmux_session_target=%s\n' "$T"
          ;;
        herdr)
          printf 'herdr_session=%s\n' "$HERDR_SES"
          printf 'herdr_workspace_id=%s\n' "$HERDR_WORKSPACE_ID"
          printf 'herdr_tab_id=%s\n' "$HERDR_TAB_ID"
          printf 'herdr_pane_id=%s\n' "$HERDR_PANE_ID"
          ;;
        zellij)
          printf 'zellij_session=%s\n' "$ZELLIJ_SES"
          printf 'zellij_tab_id=%s\n' "$ZELLIJ_TAB_ID"
          printf 'zellij_pane_id=%s\n' "$ZELLIJ_PANE_ID"
          ;;
        cmux)
          printf 'cmux_workspace_id=%s\n' "$CMUX_WORKSPACE_ID"
          printf 'cmux_surface_id=%s\n' "$CMUX_SURFACE_ID"
          ;;
      esac
    fi
  } >> "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$WORKTREE_ACQUIRE_RECORD" || { rm -f "$tmp"; return 1; }
}

clear_worktree_acquisition_record() {
  [ -n "${WORKTREE_ACQUIRE_RECORD:-}" ] || return 0
  if [ "$(sed -n '1p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$$" ] \
    && [ "$(sed -n '2p' "$WORKTREE_ACQUIRE_RECORD" 2>/dev/null)" = "$WORKTREE_ACQUIRE_OWNER_START" ]; then
    rm -f "$WORKTREE_ACQUIRE_RECORD"
  fi
  WORKTREE_ACQUIRE_RECORD=
  WORKTREE_ACQUIRE_OWNER_START=
}

spawn_return_created_worktree() {
  local return_output return_status
  [ "$WORKTREE_CREATED" = 1 ] || return 0
  [ "${BACKEND:-tmux}" != orca ] || return 0
  [ -n "${WT:-}" ] && [ -d "$WT" ] || return 0
  if [ "$WORKTREE_RETAIN_ON_ABORT" = 1 ]; then
    if return_output=$(fm_checkout_treehouse_return_safe \
        "$WT" "$CHECKOUT_LOCK_ROOT" "$PROJ_ABS" "firstmate-$ID" 2>&1); then
      [ -z "$return_output" ] || printf '%s\n' "$return_output" >&2
      return 0
    else
      return_status=$?
    fi
    [ -z "$return_output" ] || printf '%s\n' "$return_output" >&2
    echo "warning: retained unsafe acquired worktree $WT because a non-forcing rollback refused it" >&2
    return "$return_status"
  fi
  if [ -z "$WORKTREE_EXPECTED_TIP" ] \
    || ! spawn_checkout_refresh verify-returnable "$WT" "${PROJ_ABS_REAL:-$PROJ_ABS}" "$WORKTREE_EXPECTED_TIP"; then
    echo "warning: retained acquired worktree $WT because repository identity and its expected detached tip could not be re-proven" >&2
    return 1
  fi
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
  if ! spawn_checkout_refresh verify-returnable "$WT" "${PROJ_ABS_REAL:-$PROJ_ABS}" "$WORKTREE_EXPECTED_TIP"; then
    echo "warning: retained acquired worktree $WT because post-cleanup repository safety could not be re-proven" >&2
    return 1
  fi
  if return_output=$(fm_checkout_treehouse_return_safe \
      "$WT" "$CHECKOUT_LOCK_ROOT" "${PROJ_ABS_REAL:-$PROJ_ABS}" "firstmate-$ID" 2>&1); then
    [ -z "$return_output" ] || printf '%s\n' "$return_output" >&2
    return 0
  else
    return_status=$?
  fi
  [ -z "$return_output" ] || printf '%s\n' "$return_output" >&2
  case "$return_status:$return_output" in
    "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS:"*"Treehouse return process cleanup could not be verified"*)
      echo "warning: retained rollback worktree $WT because Treehouse return process cleanup is unverified; inspect the reported anchored process group, terminate only its remaining processes, and retry cleanup" >&2
      ;;
  esac
  return "$return_status"
}

spawn_restore_unmanaged_state_locked() {
  local meta="$STATE/$ID.meta" current_generation artifact_backup_name
  [ "${ACCOUNT_EFFECTIVE_MODE:-off}" != enforce ] || return 0
  if [ -n "$EXISTING_ARTIFACT_BACKUP" ]; then
    artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
    fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "$SPAWN_TASK_TMP" 1 "$SPAWN_GENERATION_ID" || return 1
  fi
  if [ -n "$META_BACKUP" ]; then
    [ -f "$META_BACKUP" ] && [ -f "$meta" ] || return 1
    current_generation=$(fm_meta_get "$meta" generation_id)
    if [ "$META_INSTALLED" = 1 ]; then
      [ "$current_generation" = "$SPAWN_GENERATION_ID" ] || return 1
    elif [ "${BACKEND:-tmux}" = orca ] \
      && [ "$(fm_meta_get "$meta" orca_cleanup_pending)" = 1 ] \
      && [ "$(fm_meta_get "$meta" orca_expected_task)" = "fm-$ID" ] \
      && { [ -z "$(fm_meta_get "$meta" orca_worktree_id)" ] \
        || [ "$(fm_meta_get "$meta" orca_worktree_id)" = "${ORCA_WORKTREE_ID:-}" ]; } \
      && { [ -z "$(fm_meta_get "$meta" terminal)" ] \
        || [ "$(fm_meta_get "$meta" terminal)" = "${ORCA_TERMINAL:-}" ]; }; then
      :
    else
      cmp -s "$meta" "$META_BACKUP" || return 1
    fi
    fm_account_meta_merge_extensions "$meta" "$META_BACKUP" || return 1
    fm_account_safe_file_destination "$meta" || return 1
    mv "$META_BACKUP" "$meta" || return 1
    META_BACKUP=
  elif [ "$META_INSTALLED" = 1 ] && [ -e "$meta" ]; then
    current_generation=$(fm_meta_get "$meta" generation_id)
    [ "$current_generation" = "$SPAWN_GENERATION_ID" ] || return 1
    rm -f "$meta" || return 1
  fi
  discard_existing_artifact_backup
}

spawn_restore_unmanaged_state() {
  local lock=${1:-} lock_owned=0 status
  [ -n "${ID:-}" ] || return 0
  if [ -z "$lock" ]; then
    lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || return 1
    lock_owned=1
  fi
  if spawn_restore_unmanaged_state_locked; then
    status=0
  else
    status=$?
  fi
  if [ "$lock_owned" = 1 ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || status=1
  fi
  return "$status"
}

spawn_abort_cleanup() {
  local status=$? endpoint_state endpoint_gone=1 account_clean=1 state_clean=1 worktree_clean=1 rollback_lock='' rollback_tmp restored_existing_meta=0 artifact_backup_name release_status orca_cleanup_failed=0 orca_boundary_token=
  trap - EXIT
  # This is an EXIT trap whose job is to attempt every independent cleanup
  # action and then return the original spawn status. The parent script runs
  # with `set -e`; without disabling errexit here, a benign nonzero probe can
  # stop the trap after endpoint removal but before lease/session/worktree
  # rollback, leaking prepared resources.
  set +e
  [ -z "${META_TMP:-}" ] || rm -f "$META_TMP"
  # The provisioning log belongs to this attempt. An abort that leaves it behind
  # accumulates one orphaned file per task in the home's state directory, which
  # is exactly the leak the ORIGINAL_*_PRESENT bookkeeping exists to prevent;
  # spawn_provision_worktree has already printed what it contained.
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "$ORIGINAL_PROVISION_LOG_PRESENT" = 0 ] \
    && [ -n "${PROVISION_LOG:-}" ]; then
    rm -f "$PROVISION_LOG"
  fi
  if [ -n "${META_WRITE_LOCK:-}" ]; then
    rollback_lock=$META_WRITE_LOCK
    META_WRITE_LOCK=
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
        case "$(fm_backend_orca_terminal_state "$ORCA_TERMINAL" "$ORCA_WORKTREE_ID" "fm-${ID:-unknown}")" in
          present|absent) ;;
          *) orca_cleanup_failed=1 ;;
        esac
      else
        orca_cleanup_failed=1
      fi
    elif [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      case "$(fm_backend_orca_worktree_terminal_state "$ORCA_WORKTREE_ID" "fm-${ID:-unknown}")" in
        present|absent) ;;
        *) orca_cleanup_failed=1 ;;
      esac
    else
      orca_cleanup_failed=1
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ] && [ "$orca_cleanup_failed" = 0 ]; then
      validate_orca_abort_worktree_identity || orca_cleanup_failed=1
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ] && [ "$orca_cleanup_failed" = 0 ]; then
      fm_backend_orca_quiesce_worktree_terminals "$ORCA_WORKTREE_ID" "fm-${ID:-unknown}" "${ORCA_TERMINAL:-}" || orca_cleanup_failed=1
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ] && [ "$orca_cleanup_failed" = 0 ]; then
      validate_orca_abort_worktree_identity || orca_cleanup_failed=1
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ] && [ "$orca_cleanup_failed" = 0 ]; then
      orca_boundary_token=$(fm_checkout_tree_boundary_token "$WT") || orca_cleanup_failed=1
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ] && [ "$orca_cleanup_failed" = 0 ]; then
      fm_backend_remove_worktree_bound \
        orca "$ORCA_WORKTREE_ID" "$WT" "$orca_boundary_token" || orca_cleanup_failed=1
    fi
    if [ "$orca_cleanup_failed" = 0 ]; then
      spawn_restore_unmanaged_state "$rollback_lock" || {
        state_clean=0
        echo "warning: failed to restore prior task state after Orca abort cleanup for ${ID:-unknown}" >&2
      }
    fi
    if [ "$orca_cleanup_failed" = 1 ]; then
      endpoint_gone=0
      worktree_clean=0
      echo "warning: retaining Orca cleanup metadata for ${ID:-unknown} because endpoint absence or worktree removal is unproven" >&2
      persist_orca_cleanup_quarantine spawn-abort || \
        echo "warning: failed to update the pre-armed Orca cleanup quarantine for ${ID:-unknown}" >&2
    fi
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] \
    && [ "${BACKEND:-tmux}" != orca ] \
    && [ "$ENDPOINT_CREATED" = 1 ] && [ -n "${T:-}" ]; then
    spawn_managed_endpoint_kill "${BACKEND:-tmux}" "$T" "${ZELLIJ_TAB_ID:-}" "fm-${ID:-unknown}" "${KIND:-ship}" "${PROJ_ABS:-}" "${META_WINDOW:-}" 2>/dev/null || true
    endpoint_state=$(spawn_managed_endpoint_state "${BACKEND:-tmux}" "$T" "fm-${ID:-unknown}" "${KIND:-ship}" "${PROJ_ABS:-}" "${META_WINDOW:-}" 2>/dev/null)
    case "$endpoint_state" in
      absent) ;;
      present)
        endpoint_gone=0
        echo "warning: retaining failed spawn resources for ${ID:-unknown} because the endpoint is still alive" >&2
        ;;
      *)
        endpoint_gone=0
        echo "warning: retaining failed spawn resources for ${ID:-unknown} because the endpoint state is unknown" >&2
        ;;
    esac
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "$endpoint_gone" = 1 ] \
    && [ "${ACCOUNT_EFFECTIVE_MODE:-off}" != enforce ] \
    && [ "${DIRECT_ACCOUNT_ROUTING:-0}" != 1 ]; then
    spawn_restore_unmanaged_state "$rollback_lock" || state_clean=0
    if [ "$state_clean" = 1 ]; then
      spawn_return_created_worktree || worktree_clean=0
    else
      worktree_clean=0
      WORKTREE_RETAIN_ON_ABORT=1
      spawn_return_created_worktree || true
      echo "warning: retained failed spawn resources for ${ID:-unknown} because prior task state could not be restored" >&2
    fi
    [ "$worktree_clean" = 1 ] || echo "warning: failed to return rollback worktree for ${ID:-unknown}" >&2
  fi
  [ -z "${ACCOUNT_NATIVE_LAUNCH_DIR:-}" ] || rm -rf "$ACCOUNT_NATIVE_LAUNCH_DIR"
  cleanup_continuation_launch_transport
  [ -z "${CONFIG_INHERIT_REPORT_TMP:-}" ] || rm -f "$CONFIG_INHERIT_REPORT_TMP"
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${DIRECT_ACCOUNT_RECOVERY:-0}" = 1 ] && [ "$endpoint_gone" = 0 ]; then
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ]; then
      persist_failed_direct_recovery || echo "warning: failed to persist retained direct recovery state for ${ID:-unknown}" >&2
    else
      echo "warning: failed to acquire metadata lock while preserving retained direct recovery for ${ID:-unknown}" >&2
    fi
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${DIRECT_ACCOUNT_ROUTING:-0}" = 1 ] \
    && [ "${DIRECT_ACCOUNT_RECOVERY:-0}" != 1 ] && [ "$endpoint_gone" = 0 ]; then
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ]; then
      persist_failed_direct_spawn 1 || echo "warning: failed to persist retained direct spawn state for ${ID:-unknown}" >&2
    else
      echo "warning: failed to acquire metadata lock while preserving retained direct spawn for ${ID:-unknown}" >&2
    fi
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${DIRECT_ACCOUNT_RECOVERY:-0}" = 1 ] && [ "$endpoint_gone" = 1 ]; then
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ]; then
      artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
      if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-$SPAWN_TASK_TMP}" 1 "$SPAWN_GENERATION_ID"; then
        if [ "$META_INSTALLED" = 1 ] && [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
          if fm_account_meta_merge_extensions "$STATE/$ID.meta" "$META_BACKUP" \
            && fm_account_safe_file_destination "$STATE/$ID.meta" \
            && mv "$META_BACKUP" "$STATE/$ID.meta"; then
            META_BACKUP=
          else
            echo "warning: failed to restore direct recovery metadata for ${ID:-unknown}" >&2
          fi
        elif [ -n "$META_BACKUP" ]; then
          rm -f "$META_BACKUP"
          META_BACKUP=
        fi
        [ -z "$EXISTING_ARTIFACT_BACKUP" ] || rm -rf "$EXISTING_ARTIFACT_BACKUP"
        EXISTING_ARTIFACT_BACKUP=
      else
        echo "warning: failed to restore direct recovery artifacts for ${ID:-unknown}" >&2
      fi
    else
      echo "warning: failed to acquire metadata lock while restoring direct recovery for ${ID:-unknown}" >&2
    fi
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${DIRECT_ACCOUNT_ROUTING:-0}" = 1 ] \
    && [ "${DIRECT_ACCOUNT_RECOVERY:-0}" != 1 ] && [ "$endpoint_gone" = 1 ]; then
    if [ "$WORKTREE_CREATED" = 1 ] && [ -n "${WT:-}" ] && [ -d "$WT" ]; then
      spawn_return_created_worktree || worktree_clean=0
      [ "$worktree_clean" = 1 ] || echo "warning: failed to return direct spawn worktree for ${ID:-unknown}; retaining cleanup metadata" >&2
    fi
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ] && [ "$worktree_clean" = 1 ]; then
      if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
        artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
        if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-$SPAWN_TASK_TMP}" 1 "$SPAWN_GENERATION_ID" \
          && fm_account_meta_merge_extensions "$STATE/$ID.meta" "$META_BACKUP" \
          && fm_account_safe_file_destination "$STATE/$ID.meta" \
          && mv "$META_BACKUP" "$STATE/$ID.meta"; then
          META_BACKUP=
          discard_existing_artifact_backup
          restored_existing_meta=1
        else
          worktree_clean=0
          echo "warning: failed to restore prior task state after direct spawn rollback for ${ID:-unknown}" >&2
        fi
      else
        if [ "$META_INSTALLED" = 1 ] \
          && [ "$(fm_meta_get "$STATE/$ID.meta" generation_id)" = "${SPAWN_GENERATION_ID:-}" ]; then
          rm -f "$STATE/$ID.meta" || worktree_clean=0
        fi
        [ "$ORIGINAL_STATUS_PRESENT" != 0 ] || rm -f "$STATE/$ID.status"
        [ "$ORIGINAL_TURN_ENDED_PRESENT" != 0 ] || rm -f "$STATE/$ID.turn-ended"
        [ "$ORIGINAL_CHECK_PRESENT" != 0 ] || rm -f "$STATE/$ID.check.sh"
        [ "$ORIGINAL_PI_EXT_PRESENT" != 0 ] || rm -f "$STATE/$ID.pi-ext.ts"
        [ "$ORIGINAL_GROK_TOKEN_PRESENT" != 0 ] || rm -f "$STATE/$ID.grok-turnend-token"
        if [ "$ORIGINAL_TASK_TMP_PRESENT" = 0 ] && [ -n "${TASK_TMP:-}" ] \
          && ! fm_account_safe_remove_task_tmp "$ID" "$TASK_TMP" "$SPAWN_GENERATION_ID"; then
          worktree_clean=0
          echo "warning: failed to remove direct spawn task temp for ${ID:-unknown}; retaining cleanup metadata" >&2
        fi
      fi
    fi
    if [ "$worktree_clean" != 1 ]; then
      if [ -n "$rollback_lock" ]; then
        persist_failed_direct_spawn "$ENDPOINT_CREATED" || echo "warning: failed to persist direct spawn cleanup state for ${ID:-unknown}" >&2
      else
        echo "warning: failed to acquire metadata lock while preserving direct spawn cleanup for ${ID:-unknown}" >&2
      fi
    fi
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${ACCOUNT_EFFECTIVE_MODE:-off}" = enforce ] && [ "$endpoint_gone" = 1 ]; then
    if [ "$ACCOUNT_LEASE_CREATED" = 1 ] || fm_account_mutation_owned; then
      release_status=0
      fm_account_release "$ACCOUNT_TASK" --force 2>/dev/null || release_status=$?
      if [ "$release_status" -ne 0 ]; then
        account_clean=0
        echo "warning: failed to roll back Agent Fleet lease for ${ID:-unknown} (exit $release_status)" >&2
      elif [ "$RESUME_ACCOUNT" != 1 ] && ! fm_account_session_remove "$ACCOUNT_TASK" 2>/dev/null; then
        account_clean=0
        echo "warning: failed to roll back Agent Fleet session for ${ID:-unknown}" >&2
      else
        fm_account_lineage_append "$DATA" "$ID" rolled-back "$ACCOUNT_ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$ACCOUNT_POOL" "$ACCOUNT_PROFILE" pending "$ACCOUNT_PREDECESSOR_TASK" >/dev/null 2>&1 || true
      fi
    fi
    if [ "$account_clean" = 1 ]; then
      spawn_return_created_worktree || worktree_clean=0
      [ "$worktree_clean" = 1 ] || echo "warning: failed to return rollback worktree for ${ID:-unknown}" >&2
    fi
    if [ -z "$rollback_lock" ]; then
      if rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}"); then
        :
      else
        account_clean=0
      fi
    fi
    if [ "$account_clean" = 1 ]; then
      if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
        if [ "$(fm_meta_get "$STATE/$ID.meta" account_task)" = "$ACCOUNT_TASK" ] \
          || cmp -s "$STATE/$ID.meta" "$META_BACKUP"; then
          artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
          if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-}" 1 "$SPAWN_GENERATION_ID" \
            && fm_account_meta_merge_extensions "$STATE/$ID.meta" "$META_BACKUP" \
            && fm_account_safe_file_destination "$STATE/$ID.meta" \
            && mv "$META_BACKUP" "$STATE/$ID.meta"; then
            [ -z "$EXISTING_ARTIFACT_BACKUP" ] || rm -rf "$EXISTING_ARTIFACT_BACKUP"
            EXISTING_ARTIFACT_BACKUP=
            restored_existing_meta=1
          else
            account_clean=0
            echo "warning: failed to restore prior task state for ${ID:-unknown}" >&2
          fi
        else
          rm -f "$META_BACKUP"
          discard_existing_artifact_backup
        fi
        [ -f "$META_BACKUP" ] || META_BACKUP=
      elif [ "$META_INSTALLED" = 1 ] && [ "$(fm_meta_get "$STATE/$ID.meta" account_task)" = "$ACCOUNT_TASK" ] && [ "$worktree_clean" = 1 ]; then
        rm -f "$STATE/$ID.meta"
      elif [ "$META_INSTALLED" = 1 ] && [ "$(fm_meta_get "$STATE/$ID.meta" account_task)" = "$ACCOUNT_TASK" ]; then
        rollback_tmp=$(mktemp "$STATE/.$ID.meta.rollback.XXXXXX" 2>/dev/null) || rollback_tmp=
        if [ -n "$rollback_tmp" ] \
          && awk '!/^account_/ && !/^provider_session_id=/ && !/^continuation_packet=/' "$STATE/$ID.meta" > "$rollback_tmp" \
          && printf 'rollback_pending=1\n' >> "$rollback_tmp" \
          && fm_account_safe_file_destination "$STATE/$ID.meta" \
          && mv "$rollback_tmp" "$STATE/$ID.meta"; then
          rollback_tmp=
        else
          [ -z "$rollback_tmp" ] || rm -f "$rollback_tmp"
          account_clean=0
          echo "warning: failed to preserve rollback metadata for ${ID:-unknown}" >&2
        fi
      fi
      if [ "$account_clean" = 1 ] && [ "$restored_existing_meta" != 1 ] && [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$worktree_clean" = 1 ]; then
        [ "$ORIGINAL_STATUS_PRESENT" != 0 ] || rm -f "$STATE/$ID.status"
        [ "$ORIGINAL_TURN_ENDED_PRESENT" != 0 ] || rm -f "$STATE/$ID.turn-ended"
        [ "$ORIGINAL_CHECK_PRESENT" != 0 ] || rm -f "$STATE/$ID.check.sh"
        [ "$ORIGINAL_PI_EXT_PRESENT" != 0 ] || rm -f "$STATE/$ID.pi-ext.ts"
        [ "$ORIGINAL_GROK_TOKEN_PRESENT" != 0 ] || rm -f "$STATE/$ID.grok-turnend-token"
        if [ "$ORIGINAL_TASK_TMP_PRESENT" = 0 ] && [ -n "${TASK_TMP:-}" ] \
          && ! fm_account_safe_remove_task_tmp "$ID" "$TASK_TMP" "$SPAWN_GENERATION_ID"; then
          account_clean=0
          echo "warning: failed to remove Agent Fleet task temp for ${ID:-unknown}; retaining cleanup metadata" >&2
        fi
      fi
      if [ "$account_clean" != 1 ] && [ -n "$rollback_lock" ]; then
        persist_failed_account_rollback || echo "warning: failed to persist Agent Fleet rollback state for ${ID:-unknown}" >&2
      fi
    elif [ -n "$rollback_lock" ]; then
      persist_failed_account_rollback || echo "warning: failed to persist Agent Fleet rollback state for ${ID:-unknown}" >&2
    fi
    [ -z "$rollback_lock" ] || fm_account_meta_lock_release "$rollback_lock" >/dev/null 2>&1 || true
    rollback_lock=
  fi
  if [ "$ACCOUNT_SPAWN_COMMITTED" != 1 ] && [ "${ACCOUNT_EFFECTIVE_MODE:-off}" = enforce ] && [ "$endpoint_gone" = 0 ]; then
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ]; then
      persist_failed_account_rollback || echo "warning: failed to persist Agent Fleet rollback state for ${ID:-unknown}" >&2
    fi
  fi
  [ -z "$rollback_lock" ] || fm_account_meta_lock_release "$rollback_lock" >/dev/null 2>&1 || true
  if [ -n "${WORKTREE_ACQUIRE_RECORD:-}" ]; then
    if [ -f "$STATE/${ID:-unknown}.meta" ] \
      || { [ "$WORKTREE_CREATED" = 1 ] && [ "$worktree_clean" = 1 ]; }; then
      clear_worktree_acquisition_record
    else
      echo "warning: retained Treehouse acquisition record for ${ID:-unknown}; auto-reap will reconcile any lease after owner death" >&2
    fi
  fi
  [ -z "$META_BACKUP" ] || [ -f "$META_BACKUP" ] || META_BACKUP=
  [ -z "$EXISTING_ARTIFACT_BACKUP" ] || [ -d "$EXISTING_ARTIFACT_BACKUP" ] || EXISTING_ARTIFACT_BACKUP=
  [ "${LIFECYCLE_LOCK_OWNED:-0}" != 1 ] || [ -z "${LIFECYCLE_LOCK:-}" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true
  release_secondmate_home_lifecycle_locks
  LIFECYCLE_LOCK=
  LIFECYCLE_LOCK_OWNED=0
  return "$status"
}
trap spawn_abort_cleanup EXIT

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  [ -z "$ACCOUNT_POOL" ] || shared_args+=(--account-pool "$ACCOUNT_POOL")
  [ -z "$ACCOUNT_PROFILE" ] || shared_args+=(--account-profile "$ACCOUNT_PROFILE")
  [ "$NO_ACCOUNT_ROUTING" = 0 ] || shared_args+=(--no-account-routing)
  [ "$NO_PROVISION" = 0 ] || shared_args+=(--no-provision)
  [ -z "$BACKLOG_ROW_EXEMPTION" ] || shared_args+=(--backlog-row-exemption "$BACKLOG_ROW_EXEMPTION")
  if [ "$RECOVERY_ACCOUNT" = 1 ]; then
    echo "error: batch dispatch does not support account recovery; recover tasks individually" >&2
    exit 1
  fi
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"} --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"}; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  trap - EXIT
  exit "$rc"
fi
ID=${POS[0]}
mkdir -p "$STATE" || {
  echo "error: cannot establish state directory at $STATE" >&2
  exit 1
}
if [ "$SPAWN_META_PRESENT" = 1 ]; then
  EXISTING_TASK_TMP=$(spawn_preflight_meta_value tasktmp)
  EXISTING_TASK_GENERATION=$(spawn_preflight_meta_value generation_id)
  if [ -n "$EXISTING_TASK_TMP" ]; then
    fm_account_task_tmp_is_expected "$ID" "$EXISTING_TASK_TMP" "$EXISTING_TASK_GENERATION" || {
      echo "error: existing task metadata has an unsafe tasktmp for $ID" >&2
      exit 1
    }
  fi
else
  EXISTING_TASK_TMP=
  EXISTING_TASK_GENERATION=
fi
PROJ=
ARG3=
FIRSTMATE_HOME=
SECONDMATE_PROJECTS=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
  if [ -z "$FIRSTMATE_HOME" ] && [ "$SPAWN_META_PRESENT" = 1 ]; then
    FIRSTMATE_HOME=$(spawn_preflight_meta_value home)
  fi
  REGISTERED_SECONDMATE_HOME=$(fm_secondmate_registry_query "$DATA/secondmates.md" query "$ID" home) || {
    echo "error: secondmate registry is malformed, missing, or does not uniquely register $ID" >&2
    exit 1
  }
  SECONDMATE_PROJECTS=$(fm_secondmate_registry_query "$DATA/secondmates.md" query "$ID" projects) || {
    echo "error: secondmate project registration is unprovable for $ID" >&2
    exit 1
  }
  REGISTERED_SECONDMATE_HOME=$(fm_checkout_trusted_dir "$REGISTERED_SECONDMATE_HOME") || {
    echo "error: registered secondmate home is unavailable or redirected for $ID" >&2
    exit 1
  }
  if [ -n "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(fm_checkout_trusted_dir "$FIRSTMATE_HOME") || {
      echo "error: requested secondmate home is unavailable or redirected for $ID" >&2
      exit 1
    }
    [ "$FIRSTMATE_HOME" = "$REGISTERED_SECONDMATE_HOME" ] || {
      echo "error: requested secondmate home does not match the exact registration for $ID" >&2
      exit 1
    }
  else
    FIRSTMATE_HOME=$REGISTERED_SECONDMATE_HOME
  fi
  ACTIVE_HOME_CANONICAL=$(fm_checkout_trusted_dir "$FM_HOME") || exit 1
  if [ "$FIRSTMATE_HOME" != "$ACTIVE_HOME_CANONICAL" ]; then
    SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK=$(fm_secondmate_home_lifecycle_lock_acquire "$CHECKOUT_LOCK_ROOT" "$FIRSTMATE_HOME") || exit 1
  fi
else
  PROJ=${POS[1]:-}
  ARG3=${POS[2]:-}
fi

if [ "$BACKLOG_ROW_EXEMPTION_SET" = 1 ] \
  && { [ "$KIND" = secondmate ] || [ "$SPAWN_META_PRESENT" = 1 ]; }; then
  echo "error: --backlog-row-exemption applies only to a genuinely new ship or scout task" >&2
  exit 1
fi
if [ "$KIND" != secondmate ] && [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$SPAWN_META_PRESENT" = 0 ]; then
  [ -f "$DATA/$ID/brief.md" ] || { echo "error: no brief at $DATA/$ID/brief.md" >&2; exit 1; }
  if [ -n "$BACKLOG_ROW_EXEMPTION" ]; then
    echo "WARNING: backlog row exemption '$BACKLOG_ROW_EXEMPTION' is active for new $KIND task $ID; the category will be recorded in task metadata" >&2
  elif ! spawn_backlog_has_row "$ID"; then
    spawn_refuse_missing_backlog_row "$ID" "$KIND" "$PROJ"
    exit 1
  fi
fi

if [ -z "$LIFECYCLE_LOCK" ]; then
  LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || exit 1
  LIFECYCLE_LOCK_OWNED=1
fi
if [ "$RECOVERY_ACCOUNT" = 0 ]; then
  if [ "$SPAWN_META_PRESENT" = 1 ]; then
    current_spawn_meta=$(spawn_preflight_read_meta "$STATE/$ID.meta") || {
      echo "error: unsafe metadata for spawn at $STATE/$ID.meta" >&2
      exit 1
    }
    [ "$current_spawn_meta" = "$SPAWN_META_SNAPSHOT" ] || {
      echo "error: task metadata changed before spawn mutation for $ID" >&2
      exit 1
    }
  elif [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
    echo "error: task metadata appeared before spawn mutation for $ID" >&2
    exit 1
  fi
fi

if [ -e "$STATE/$ID.status" ] || [ -L "$STATE/$ID.status" ]; then ORIGINAL_STATUS_PRESENT=1; else ORIGINAL_STATUS_PRESENT=0; fi
if [ -e "$STATE/$ID.turn-ended" ] || [ -L "$STATE/$ID.turn-ended" ]; then ORIGINAL_TURN_ENDED_PRESENT=1; else ORIGINAL_TURN_ENDED_PRESENT=0; fi
if [ -e "$STATE/$ID.check.sh" ] || [ -L "$STATE/$ID.check.sh" ]; then ORIGINAL_CHECK_PRESENT=1; else ORIGINAL_CHECK_PRESENT=0; fi
if [ -e "$STATE/$ID.pi-ext.ts" ] || [ -L "$STATE/$ID.pi-ext.ts" ]; then ORIGINAL_PI_EXT_PRESENT=1; else ORIGINAL_PI_EXT_PRESENT=0; fi
if [ -e "$STATE/$ID.grok-turnend-token" ] || [ -L "$STATE/$ID.grok-turnend-token" ]; then ORIGINAL_GROK_TOKEN_PRESENT=1; else ORIGINAL_GROK_TOKEN_PRESENT=0; fi
if [ "$RECOVERY_ACCOUNT" = 1 ]; then
  RECORDED_KIND=$(fm_meta_get "$RESUME_META" kind)
  [ -n "$RECORDED_KIND" ] || RECORDED_KIND=ship
  if [ "$KIND" != ship ] && [ "$KIND" != "$RECORDED_KIND" ]; then
    echo "error: account recovery kind '$KIND' does not match recorded kind '$RECORDED_KIND'" >&2
    exit 1
  fi
  KIND=$RECORDED_KIND
  spawn_refuse_unsupported_secondmate_backend || exit 1
  RECORDED_HARNESS=$(fm_meta_get "$RESUME_META" harness)
  RECORDED_PROJECT=$(fm_meta_get "$RESUME_META" project)
  RECORDED_WORKTREE=$(fm_meta_get "$RESUME_META" worktree)
  [ -n "$RECORDED_HARNESS" ] || { echo "error: managed recovery metadata has no harness for $ID" >&2; exit 1; }
  if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
    RECORDED_ACCOUNT_HOME=$(fm_meta_get "$RESUME_META" account_home)
    RECORDED_MODEL=$(fm_meta_get "$RESUME_META" model)
    RECORDED_EFFORT=$(fm_meta_get "$RESUME_META" effort)
    RECORDED_MODE=$(fm_meta_get "$RESUME_META" mode)
    RECORDED_YOLO=$(fm_meta_get "$RESUME_META" yolo)
    RECORDED_WORKTREE_GIT_DIR=$(fm_meta_get "$RESUME_META" worktree_git_dir)
    RECORDED_WORKTREE_GIT_DIR_IDENTITY=$(fm_meta_get "$RESUME_META" worktree_git_dir_identity)
    RECORDED_WORKTREE_GIT_REF=$(fm_meta_get "$RESUME_META" worktree_git_ref)
    RECORDED_WORKTREE_GIT_HEAD=$(fm_meta_get "$RESUME_META" worktree_git_head)
    RECORDED_WORKTREE_GIT_SETUP_REF=$(fm_meta_get "$RESUME_META" worktree_git_setup_ref)
    RECORDED_WORKTREE_GIT_SETUP_HEAD=$(fm_meta_get "$RESUME_META" worktree_git_setup_head)
    RECORDED_GENERATION=$(fm_meta_get "$RESUME_META" generation_id)
    RECORDED_TASKTMP=$(fm_meta_get "$RESUME_META" tasktmp)
    RECORDED_REPORT_REQUIRED=
    RECORDED_REPORT_REQUIRED_SET=0
    if grep -q '^report_required=' "$RESUME_META"; then
      RECORDED_REPORT_REQUIRED_SET=1
      RECORDED_REPORT_REQUIRED=$(fm_meta_get "$RESUME_META" report_required)
    fi
    case "$RECORDED_KIND" in
      ship|scout) ;;
      *) echo "error: direct account recovery metadata has invalid kind '$RECORDED_KIND' for $ID" >&2; exit 1 ;;
    esac
    case "$RECORDED_HARNESS" in
      claude|codex) ;;
      *) echo "error: direct account recovery metadata has unsupported harness '$RECORDED_HARNESS' for $ID" >&2; exit 1 ;;
    esac
    [ -z "$(fm_meta_get "$RESUME_META" direct_spawn_cleanup)" ] || {
      echo "error: failed direct spawn cleanup is pending for $ID; tear down the retained endpoint and worktree before recovery" >&2
      exit 1
    }
    [ -z "$(fm_meta_get "$RESUME_META" rollback_pending)" ] || {
      echo "error: rollback cleanup is pending for $ID; tear down the retained task state before recovery" >&2
      exit 1
    }
    [ -n "$RECORDED_ACCOUNT_HOME" ] || { echo "error: direct account recovery metadata has no account_home for $ID" >&2; exit 1; }
    [ -z "$(fm_meta_get "$RESUME_META" account_profile)" ] || { echo "error: direct account recovery cannot replace legacy account_profile metadata for $ID" >&2; exit 1; }
    [ -z "$(fm_meta_get "$RESUME_META" account_rollback_cleanup)" ] || { echo "error: direct account recovery cannot bypass pending legacy rollback cleanup for $ID" >&2; exit 1; }
    [ -n "$RECORDED_PROJECT" ] || { echo "error: direct account recovery metadata has no project for $ID" >&2; exit 1; }
    [ -n "$RECORDED_WORKTREE" ] || { echo "error: direct account recovery metadata has no worktree for $ID" >&2; exit 1; }
    [ -n "$RECORDED_WORKTREE_GIT_DIR" ] || { echo "error: direct account recovery metadata has no exact worktree Git-dir for $ID" >&2; exit 1; }
    [ -n "$RECORDED_WORKTREE_GIT_DIR_IDENTITY" ] || { echo "error: direct account recovery metadata has no worktree Git-dir identity for $ID" >&2; exit 1; }
    if [ -n "$RECORDED_WORKTREE_GIT_REF" ] && [ -n "$RECORDED_WORKTREE_GIT_HEAD" ]; then
      echo "error: direct account recovery metadata has conflicting branch and detached HEAD identities for $ID" >&2
      exit 1
    fi
    if [ -z "$RECORDED_WORKTREE_GIT_REF" ] && [ -z "$RECORDED_WORKTREE_GIT_HEAD" ]; then
      echo "error: direct account recovery metadata has no authoritative worktree Git state for $ID" >&2
      exit 1
    fi
    if [ -n "$RECORDED_WORKTREE_GIT_SETUP_REF" ] && [ -z "$RECORDED_WORKTREE_GIT_SETUP_HEAD" ]; then
      echo "error: direct account recovery metadata has an incomplete branch-setup identity for $ID" >&2
      exit 1
    fi
    if [ -n "$RECORDED_WORKTREE_GIT_SETUP_HEAD" ] \
      && { [ -z "$RECORDED_WORKTREE_GIT_REF" ] || [ -n "$RECORDED_WORKTREE_GIT_HEAD" ]; }; then
      echo "error: direct account recovery metadata has an invalid branch-setup transition for $ID" >&2
      exit 1
    fi
    [ -n "$RECORDED_MODE" ] || { echo "error: direct account recovery metadata has no mode for $ID" >&2; exit 1; }
    [ -n "$RECORDED_YOLO" ] || { echo "error: direct account recovery metadata has no yolo setting for $ID" >&2; exit 1; }
    [ -n "$RECORDED_GENERATION" ] || { echo "error: direct account recovery metadata has no generation_id for $ID" >&2; exit 1; }
    fm_account_task_tmp_is_expected "$ID" "$RECORDED_TASKTMP" "$RECORDED_GENERATION" || { echo "error: direct account recovery metadata has an invalid tasktmp for $ID" >&2; exit 1; }
    RECORDED_META_WORKTREE_GIT_REF=$RECORDED_WORKTREE_GIT_REF
    RECORDED_META_WORKTREE_GIT_HEAD=$RECORDED_WORKTREE_GIT_HEAD
    RECORDED_META_WORKTREE_GIT_SETUP_REF=$RECORDED_WORKTREE_GIT_SETUP_REF
    RECORDED_META_WORKTREE_GIT_SETUP_HEAD=$RECORDED_WORKTREE_GIT_SETUP_HEAD
    HARNESS_ARG=$RECORDED_HARNESS
    HARNESS_SET=1
    MODEL=$RECORDED_MODEL
    EFFORT=$RECORDED_EFFORT
    [ "$MODEL" = default ] && MODEL=
    [ "$EFFORT" = default ] && EFFORT=
    ARG3=$HARNESS_ARG
    DIRECT_ACCOUNT_RESPAWN=1
    PROJ=$RECORDED_PROJECT
  else
    RECORDED_PROFILE=$(fm_meta_get "$RESUME_META" account_profile)
    RECORDED_POOL=$(fm_meta_get "$RESUME_META" account_pool)
    RECORDED_SESSION=$(fm_meta_get "$RESUME_META" provider_session_id)
    RECORDED_ACCOUNT_TASK=$(fm_meta_get "$RESUME_META" account_task)
    RECORDED_ATTEMPT=$(fm_meta_get "$RESUME_META" account_attempt)
    [ -n "$RECORDED_ACCOUNT_TASK" ] || RECORDED_ACCOUNT_TASK=$ID
    [ -n "$RECORDED_ATTEMPT" ] || RECORDED_ATTEMPT=legacy
    [ -n "$RECORDED_PROFILE" ] || { echo "error: managed recovery metadata has no account_profile for $ID" >&2; exit 1; }
    [ -n "$RECORDED_POOL" ] || { echo "error: managed recovery metadata has no account_pool for $ID" >&2; exit 1; }
    if [ "$RESUME_ACCOUNT" = 1 ]; then
      FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$LIFECYCLE_LOCK" "$SCRIPT_DIR/fm-account-session-sync.sh" "$ID" --require >/dev/null || exit 1
      RECORDED_SESSION=$(fm_meta_get "$RESUME_META" provider_session_id)
      [ -n "$RECORDED_SESSION" ] || { echo "error: managed recovery metadata has no provider_session_id for $ID" >&2; exit 1; }
      if [ "$HARNESS_SET" = 1 ] && [ "$HARNESS_ARG" != "$RECORDED_HARNESS" ]; then
        echo "error: --resume-account harness override '$HARNESS_ARG' does not match recorded harness '$RECORDED_HARNESS'" >&2
        exit 1
      fi
      if [ "$ACCOUNT_POOL_SET" = 1 ] && [ "$ACCOUNT_POOL" != "$RECORDED_POOL" ]; then
        echo "error: --resume-account pool override '$ACCOUNT_POOL' does not match recorded pool '$RECORDED_POOL'" >&2
        exit 1
      fi
      if [ "$ACCOUNT_PROFILE_SET" = 1 ] && [ "$ACCOUNT_PROFILE" != "$RECORDED_PROFILE" ]; then
        echo "error: --resume-account profile override '$ACCOUNT_PROFILE' does not match recorded profile '$RECORDED_PROFILE'" >&2
        exit 1
      fi
      HARNESS_ARG=$RECORDED_HARNESS
      ACCOUNT_POOL=$RECORDED_POOL
      ACCOUNT_PROFILE=$RECORDED_PROFILE
      ACCOUNT_POOL_SET=1
      ACCOUNT_PROFILE_SET=1
      ACCOUNT_TASK=$RECORDED_ACCOUNT_TASK
      ACCOUNT_ATTEMPT=$RECORDED_ATTEMPT
    else
      [ "$HARNESS_SET" = 1 ] || HARNESS_ARG=$RECORDED_HARNESS
      if [ "$ACCOUNT_POOL_SET" = 0 ] && [ "$ACCOUNT_PROFILE_SET" = 0 ]; then
        if [ "$HARNESS_ARG" = "$RECORDED_HARNESS" ]; then
          ACCOUNT_POOL=$RECORDED_POOL
        else
          ACCOUNT_POOL=$(fm_account_default_pool "$HARNESS_ARG") || {
            echo "error: no default account pool for continuation harness '$HARNESS_ARG'" >&2
            exit 1
          }
        fi
        ACCOUNT_POOL_SET=1
      fi
      ACCOUNT_PREDECESSOR_TASK=$RECORDED_ACCOUNT_TASK
      ACCOUNT_PREDECESSOR_ATTEMPT=$RECORDED_ATTEMPT
      ACCOUNT_PREDECESSOR_PROVIDER=$RECORDED_HARNESS
      ACCOUNT_PREDECESSOR_PROFILE=$RECORDED_PROFILE
      ACCOUNT_PREDECESSOR_POOL=$RECORDED_POOL
      ACCOUNT_PREDECESSOR_SESSION=$RECORDED_SESSION
    fi
    HARNESS_SET=1
    ARG3=$HARNESS_ARG
    if [ "$RESUME_ACCOUNT" = 1 ] || [ "$HARNESS_ARG" = "$RECORDED_HARNESS" ]; then
      [ "$MODEL_SET" = 1 ] || MODEL=$(fm_meta_get "$RESUME_META" model)
      [ "$EFFORT_SET" = 1 ] || EFFORT=$(fm_meta_get "$RESUME_META" effort)
    fi
    [ "$MODEL" = default ] && MODEL=
    [ "$EFFORT" = default ] && EFFORT=
    if [ "$KIND" = secondmate ]; then
      RECORDED_SECONDMATE_HOME=$(fm_meta_get "$RESUME_META" home)
      RECORDED_SECONDMATE_HOME=$(fm_checkout_trusted_dir "$RECORDED_SECONDMATE_HOME") || {
        echo "error: managed recovery secondmate home is unavailable or redirected for $ID" >&2
        exit 1
      }
      [ "$RECORDED_SECONDMATE_HOME" = "$FIRSTMATE_HOME" ] || {
        echo "error: managed recovery secondmate home does not match registration for $ID" >&2
        exit 1
      }
    else
      PROJ=$(fm_meta_get "$RESUME_META" project)
    fi
  fi
fi

direct_recovery_context_matches() {
  [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] || return 0
  [ -f "$RESUME_META" ] \
    && [ "$(fm_meta_get "$RESUME_META" kind)" = "$RECORDED_KIND" ] \
    && [ "$(fm_meta_get "$RESUME_META" harness)" = "$RECORDED_HARNESS" ] \
    && [ "$(fm_meta_get "$RESUME_META" project)" = "$RECORDED_PROJECT" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree)" = "$RECORDED_WORKTREE" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_dir)" = "$RECORDED_WORKTREE_GIT_DIR" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_dir_identity)" = "$RECORDED_WORKTREE_GIT_DIR_IDENTITY" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_ref)" = "$RECORDED_META_WORKTREE_GIT_REF" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_head)" = "$RECORDED_META_WORKTREE_GIT_HEAD" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_setup_ref)" = "$RECORDED_META_WORKTREE_GIT_SETUP_REF" ] \
    && [ "$(fm_meta_get "$RESUME_META" worktree_git_setup_head)" = "$RECORDED_META_WORKTREE_GIT_SETUP_HEAD" ] \
    && [ "$(fm_backend_of_meta "$RESUME_META")" = "$BACKEND" ] \
    && [ "$(fm_meta_get "$RESUME_META" model)" = "$RECORDED_MODEL" ] \
    && [ "$(fm_meta_get "$RESUME_META" effort)" = "$RECORDED_EFFORT" ] \
    && [ "$(fm_meta_get "$RESUME_META" mode)" = "$RECORDED_MODE" ] \
    && [ "$(fm_meta_get "$RESUME_META" yolo)" = "$RECORDED_YOLO" ] \
    && [ "$(fm_meta_get "$RESUME_META" account_home)" = "$RECORDED_ACCOUNT_HOME" ] \
    && [ "$(fm_meta_get "$RESUME_META" generation_id)" = "$RECORDED_GENERATION" ] \
    && [ "$(fm_meta_get "$RESUME_META" tasktmp)" = "$RECORDED_TASKTMP" ] \
    && [ -z "$(fm_meta_get "$RESUME_META" account_profile)" ] \
    && [ -z "$(fm_meta_get "$RESUME_META" direct_recovery_cleanup)" ] \
    && [ -z "$(fm_meta_get "$RESUME_META" direct_spawn_cleanup)" ] \
    && [ -z "$(fm_meta_get "$RESUME_META" account_rollback_cleanup)" ] \
    && [ -z "$(fm_meta_get "$RESUME_META" rollback_pending)" ] \
    || return 1
  if [ "$RECORDED_REPORT_REQUIRED_SET" = 1 ]; then
    grep -q '^report_required=' "$RESUME_META" \
      && [ "$(fm_meta_get "$RESUME_META" report_required)" = "$RECORDED_REPORT_REQUIRED" ]
  else
    if grep -q '^report_required=' "$RESUME_META"; then
      return 1
    fi
  fi
}

[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false __AGENT__ --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__AGENT__ __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' '__AGENT__ __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    # pi: --approve ("Trust project-local files for this run") is what keeps an
    # unattended pi agent off the project-trust dialog. Pi has no permission system,
    # but it DOES gate every not-yet-trusted directory behind that dialog on first
    # run - observed even on clean worktrees - and a task worktree or a freshly
    # seeded secondmate home is always a new path, so without --approve the agent
    # parks on a prompt nobody is watching. It is per-run and scoped to this
    # firstmate-launched agent; it never touches the captain's machine-wide
    # defaultProjectTrust posture in ~/.pi/agent/settings.json. Both flags go ahead
    # of __MODELFLAG__/__EFFORTFLAG__ so --exclude-tools stays adjacent to its value
    # and the line renders correctly whether or not those placeholders expand.
    pi)
      if [ "$kind" = secondmate ]; then
        # A secondmate gets --approve for the same trust-dialog reason (and it also
        # lets pi auto-discover the home's project-local extensions), but NOT
        # --exclude-tools ask_question: a secondmate is a firstmate-class supervisor
        # the captain may type into directly, so its interactive surface is
        # deliberately left intact. Excluding the tool is only a denylist entry, so
        # revisit this if pi ever ships a question tool that can park a secondmate -
        # fm-watch.sh skips stale-pane wakes for kind=secondmate, so a parked
        # secondmate would not trip stale detection.
        printf '%s' '__AGENT__ --approve --fast __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        # --exclude-tools is a plain denylist over built-in, extension, and custom
        # tool names (pi 0.84.0 filters it as a Set, ignoring names that are not
        # registered), and ask_question is pi's own documented example for it. A
        # crewmate's contract is to run autonomously and report through its status
        # file, so a tool that halts the run to ask a question nobody is watching is
        # never the right behavior here.
        printf '%s' '__AGENT__ --approve --exclude-tools ask_question --fast __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

if [ "$SPAWN_CLOUD" = azure ]; then
  # Cloud-placed crewmates run ENTIRELY on the pi-codex runtime: the cloud lane
  # bypasses local harness dispatch (config/crew-harness, crew-dispatch.json)
  # and every claude profile-routing mechanism, and pi's own extension owns
  # multi-profile selection on the worker. A conflicting explicit harness or a
  # raw launch command is a contradiction, not an override.
  case "$ARG3" in
    ''|pi) ;;
    *' '*)
      echo "error: cloud placement does not accept raw launch commands; the pi-codex runtime is selected unconditionally" >&2
      exit 1
      ;;
    *)
      echo "error: cloud placement runs only the pi-codex runtime; drop the '$ARG3' harness or spawn locally" >&2
      exit 1
      ;;
  esac
  ARG3=pi
fi
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    RAW_LAUNCH=1
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crewmate harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

if [ "$KIND" != secondmate ] && [ "$HARNESS" = claude ]; then
  CLAUDE_CREW_MODEL=$("$SCRIPT_DIR/fm-harness.sh" claude-crew-model) || exit 1
  [ "$RAW_LAUNCH" != 1 ] || {
    echo "error: Claude crew/scout launch does not accept raw launch commands because they cannot prove the resolved model; use --harness claude with an optional explicit --model" >&2
    exit 1
  }
  if [ -z "$MODEL" ] && [ "$MODEL_SET" -eq 0 ]; then
    MODEL=$CLAUDE_CREW_MODEL
  fi
  [ "$MODEL" = "$CLAUDE_CREW_MODEL" ] || {
    echo "error: Claude crew/scout model '$MODEL' does not match the installed Opus 5 anchor '$CLAUDE_CREW_MODEL'" >&2
    exit 1
  }
fi

ACCOUNT_EXPLICIT=0
if [ "$ACCOUNT_POOL_SET" = 1 ] || [ "$ACCOUNT_PROFILE_SET" = 1 ]; then
  ACCOUNT_EXPLICIT=1
fi
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  ACCOUNT_EXPLICIT=1
elif [ "$KIND" != secondmate ] && [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$NO_ACCOUNT_ROUTING" = 0 ] \
  && [ "$SPAWN_META_PRESENT" = 1 ] \
  && [ -n "$(spawn_preflight_meta_value account_home)" ]; then
  echo "error: direct account metadata already exists for ${POS[0]}; use --recover-direct-account to preserve its recorded task context" >&2
  exit 1
fi
if [ "$KIND" = secondmate ]; then
  ACCOUNT_PRIMARY_MODE=$(fm_account_resolve_mode "$CONFIG" 0 0) || exit 1
fi
ACCOUNT_EFFECTIVE_MODE=$(fm_account_resolve_mode "$CONFIG" "$ACCOUNT_EXPLICIT" "$NO_ACCOUNT_ROUTING") || exit 1
if [ "$NO_ACCOUNT_ROUTING" = 1 ]; then
  echo "WARNING: emergency --no-account-routing bypass is active for ${POS[0]:-unknown}; this spawn will use the provider's default identity and will be recorded in task metadata" >&2
fi
if [ "$DIRECT_ACCOUNT_RECOVERY" = 0 ] && [ "$ACCOUNT_EFFECTIVE_MODE" != off ] \
  && [ "$ACCOUNT_POOL_SET" = 0 ] && [ "$ACCOUNT_PROFILE_SET" = 0 ] && [ "$KIND" = secondmate ]; then
  if SM_ACCOUNT_POOL=$(fm_account_secondmate_pool "$CONFIG"); then
    ACCOUNT_POOL=$SM_ACCOUNT_POOL
  else
    sm_pool_status=$?
    [ "$sm_pool_status" -eq 1 ] || exit "$sm_pool_status"
  fi
fi
case "$HARNESS" in
  claude|codex) ;;
  *)
    if [ "$ACCOUNT_POOL_SET" = 1 ] || [ "$ACCOUNT_PROFILE_SET" = 1 ]; then
      echo "error: --account-pool/--account-profile requires a claude or codex harness, not '$HARNESS'" >&2
      exit 1
    fi
    if [ "$DIRECT_ACCOUNT_RESPAWN" = 1 ]; then
      echo "error: recorded direct account routing requires a claude or codex harness, not '$HARNESS'" >&2
      exit 1
    fi
    if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
      echo "error: enforced account routing requires a claude or codex harness, not '$HARNESS'" >&2
      exit 1
    fi
    ACCOUNT_EFFECTIVE_MODE=off
    ;;
esac
if { [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ] \
    || { [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$KIND" != secondmate ]; }; } \
  && [ "$ACCOUNT_EFFECTIVE_MODE" != off ]; then
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && fm_account_test_lab_enabled \
    && [ "$DIRECT_ACCOUNT_RECOVERY" = 0 ] \
    && [ "${FM_ACCOUNT_ROUTING_LEGACY_NEW_LAUNCH_TEST:-}" = firstmate-remove-fleet-routing-deadcode-fixture-v1 ]; then
    :
  else
    [ "$RAW_LAUNCH" != 1 ] || {
      echo "error: direct account-directory routing does not accept raw launch commands" >&2
      exit 1
    }
    DIRECT_ACCOUNT_ROUTING=1
    if [ "$ACCOUNT_POOL_SET" = 1 ] || [ "$ACCOUNT_PROFILE_SET" = 1 ]; then
      echo "fm-spawn: --account-pool/--account-profile now activate direct account-directory selection for new launches; the legacy alias does not pin the selected account" >&2
    elif [ "$DIRECT_ACCOUNT_RESPAWN" = 1 ]; then
      echo "fm-spawn: recorded direct account metadata activates fresh account-directory selection for this respawn" >&2
    fi
    if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
      DIRECT_ACCOUNT_PREPARE_DEFERRED=1
    else
      DIRECT_ACCOUNT_HOME=$("$SCRIPT_DIR/fm-account-directory.sh" prepare "$HARNESS") || exit 1
      echo "fm-spawn: selected direct $HARNESS account home $DIRECT_ACCOUNT_HOME" >&2
    fi
    # Every Agent Fleet branch below is guarded by enforce. New direct crewmate
    # launches deliberately rejoin the ordinary unmanaged spawn path after selection.
    ACCOUNT_EFFECTIVE_MODE=off
  fi
fi
# Secondmate launches under OBSERVE take the same rotated account directory as
# crewmates. Before this they fell through to the legacy Agent Fleet path, which
# in observe mode is shadow-only ("no lease; legacy launch unchanged") and binds
# no identity at all - so every secondmate inherited the ambient
# CLAUDE_CONFIG_DIR and the fleet's whole supervisor load landed on one account.
#
# ENFORCE is deliberately NOT diverted here. That mode already binds a real
# account through its Agent Fleet lease and native launch, so it was never the
# defect; routing it through direct selection would change the enforced lease,
# rollback, and recovery contract for no gain.
#
# Only the account binding is shared with the crewmate path. DIRECT_ACCOUNT_ROUTING
# stays 0, so a secondmate home is never treated as a task worktree and its
# metadata keeps the shape ordinary respawn expects. Selection is deferred to the
# shared prepare point further down: no account is chosen and no Herdr hook is
# installed until the home has proved its identity and its routing-policy
# inheritance, so a launch that is going to be refused never consumes a rotation.
if [ "$KIND" = secondmate ] && [ "$RECOVERY_ACCOUNT" = 0 ] && [ "$RAW_LAUNCH" != 1 ] \
  && [ "$ACCOUNT_EFFECTIVE_MODE" = observe ]; then
  case "$HARNESS" in
    claude|codex)
      DIRECT_ACCOUNT_SECONDMATE=1
      DIRECT_ACCOUNT_PREPARE_DEFERRED=1
      # The shadow Agent Fleet observe pass below would only re-derive a decision
      # that nothing applies; this launch binds a real account instead.
      ACCOUNT_EFFECTIVE_MODE=off
      ;;
  esac
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" != off ] && [ -z "$ACCOUNT_POOL" ]; then
  if [ -n "$ACCOUNT_PROFILE" ]; then
    ACCOUNT_POOL=explicit
  else
    ACCOUNT_POOL=$(fm_account_default_pool "$HARNESS") || {
      echo "error: no default account pool for harness '$HARNESS'" >&2
      exit 1
    }
  fi
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && [ "$RAW_LAUNCH" = 1 ]; then
  echo "error: enforced account routing does not accept raw launch commands" >&2
  exit 1
fi
if [ "$SPAWN_CLOUD" = azure ] && [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  echo "error: cloud placement does not support enforced Agent Fleet account routing" >&2
  exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && [ "$BACKEND" = orca ]; then
  echo "error: enforced Agent Fleet routing does not support backend=orca" >&2
  exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && ! fm_account_test_lab_enabled \
  && [ "$BACKEND" != herdr ]; then
  echo "error: enforced Agent Fleet routing requires backend=herdr so native agent startup can inject the selected account environment; backend=$BACKEND cannot provide that isolation, so retry with --backend herdr" >&2
  exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" != off ] && [ "$RESUME_ACCOUNT" != 1 ]; then
  ACCOUNT_ATTEMPT=$(fm_account_attempt_id "$FM_HOME" "$ID") || exit 1
  ACCOUNT_TASK=$(fm_account_task_key "$FM_HOME" "$ID" "$ACCOUNT_ATTEMPT") || exit 1
fi
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  SPAWN_GENERATION_ID=$RECORDED_GENERATION
elif [ "$ACCOUNT_EFFECTIVE_MODE" != off ]; then
  SPAWN_GENERATION_ID="account:$ACCOUNT_TASK:$ACCOUNT_ATTEMPT"
else
  SPAWN_GENERATION_ID="spawn:$(fm_account_attempt_id "$FM_HOME" "$ID")" || exit 1
fi
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  SPAWN_TASK_TMP=$RECORDED_TASKTMP
else
  SPAWN_TASK_TMP=$(fm_account_task_tmp_path "$ID" "$SPAWN_GENERATION_ID") || {
    echo "error: cannot establish a safe task temp path for $ID" >&2
    exit 1
  }
fi
if [ -e "$SPAWN_TASK_TMP" ] || [ -L "$SPAWN_TASK_TMP" ]; then ORIGINAL_TASK_TMP_PRESENT=1; else ORIGINAL_TASK_TMP_PRESENT=0; fi
TASK_TMP=$SPAWN_TASK_TMP
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  META_WRITE_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  if [ "$RECOVERY_ACCOUNT" = 1 ]; then
    current_recovery_task=$(fm_meta_get "$RESUME_META" account_task)
    current_recovery_attempt=$(fm_meta_get "$RESUME_META" account_attempt)
    [ -n "$current_recovery_task" ] || current_recovery_task=$ID
    [ -n "$current_recovery_attempt" ] || current_recovery_attempt=legacy
    if [ ! -f "$RESUME_META" ] \
      || [ "$current_recovery_task" != "$RECORDED_ACCOUNT_TASK" ] \
      || [ "$current_recovery_attempt" != "$RECORDED_ATTEMPT" ] \
      || [ "$(fm_meta_get "$RESUME_META" harness)" != "$RECORDED_HARNESS" ] \
      || [ "$(fm_meta_get "$RESUME_META" account_profile)" != "$RECORDED_PROFILE" ] \
      || [ "$(fm_meta_get "$RESUME_META" account_pool)" != "$RECORDED_POOL" ] \
      || [ "$(fm_meta_get "$RESUME_META" project)" != "$RECORDED_PROJECT" ] \
      || [ "$(fm_meta_get "$RESUME_META" worktree)" != "$RECORDED_WORKTREE" ] \
      || [ "$(fm_backend_of_meta "$RESUME_META")" != "$BACKEND" ] \
      || [ -n "$(fm_meta_get "$RESUME_META" account_rollback_cleanup)" ] \
      || [ -n "$(fm_meta_get "$RESUME_META" account_predecessor_cleanup)" ]; then
      echo "error: managed task generation changed before recovery mutation for $ID" >&2
      exit 1
    fi
    META_BACKUP=$(mktemp "$STATE/.$ID.meta.rollback.XXXXXX") || exit 1
    cp -p "$RESUME_META" "$META_BACKUP" || exit 1
  fi
  fm_account_meta_lock_release "$META_WRITE_LOCK" || exit 1
  META_WRITE_LOCK=
fi
EXISTING_META=0
EXISTING_REPORT_REQUIRED_SET=0
EXISTING_REPORT_REQUIRED=
if [ "$RECOVERY_ACCOUNT" = 0 ] && [ -f "$STATE/$ID.meta" ]; then
  EXISTING_META=1
  if grep -q '^report_required=' "$STATE/$ID.meta"; then
    EXISTING_REPORT_REQUIRED_SET=1
    EXISTING_REPORT_REQUIRED=$(fm_meta_get "$STATE/$ID.meta" report_required)
  fi
  if [ "$(fm_meta_get "$STATE/$ID.meta" rollback_pending)" = 1 ] || [ "$(fm_meta_get "$STATE/$ID.meta" account_rollback_cleanup)" = pending ]; then
    echo "error: rollback cleanup is pending for $ID; tear down the retained task state before spawning again" >&2
    exit 1
  fi
  existing_profile=$(fm_meta_get "$STATE/$ID.meta" account_profile)
  [ -z "$existing_profile" ] || {
    echo "error: managed metadata already exists for $ID; use --resume-account or --continue-account" >&2
    exit 1
  }
  existing_backend=$(fm_backend_of_meta "$STATE/$ID.meta")
  existing_target=$(fm_backend_target_of_meta "$STATE/$ID.meta")
  existing_kind=$(fm_meta_get "$STATE/$ID.meta" kind)
  [ -n "$existing_kind" ] || existing_kind=ship
  existing_home=$(fm_meta_get "$STATE/$ID.meta" home)
  existing_endpoint_state=$(spawn_managed_endpoint_state "$existing_backend" "$existing_target" "fm-$ID" \
    "$existing_kind" "$existing_home" "$(fm_meta_get "$STATE/$ID.meta" tmux_session_target)" 2>/dev/null)
  case "$existing_endpoint_state" in
    absent) ;;
    present) echo "error: endpoint is already alive for $ID; refusing duplicate spawn" >&2; exit 1 ;;
    *) echo "error: endpoint state is unknown for $ID; refusing duplicate spawn" >&2; exit 1 ;;
  esac
  META_BACKUP=$(mktemp "$STATE/.$ID.meta.rollback.XXXXXX") || exit 1
  cp -p "$STATE/$ID.meta" "$META_BACKUP" || exit 1
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
    snapshot_existing_artifacts || exit 1
  fi
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" != enforce ]; then
  snapshot_existing_artifacts || exit 1
fi

secondmate_registry_value() {
  fm_secondmate_registry_query "$DATA/secondmates.md" query "$1" "$2"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # pi accepts --thinking low|medium|high|xhigh. It warns and ignores max, so
      # omit max rather than passing a flag the installed CLI will reject as invalid.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

secondmate_home_supports_account_routing() {
  local home=$1
  [ -f "$home/bin/fm-account-routing-lib.sh" ] \
    && [ -f "$home/bin/fm-spawn.sh" ] \
    && grep -q '^fm_account_resolve_mode()' "$home/bin/fm-account-routing-lib.sh" \
    && grep -Fq "ACCOUNT_EFFECTIVE_MODE=\$(fm_account_resolve_mode" "$home/bin/fm-spawn.sh"
}

secondmate_routing_config_inherited() {
  local report=$1 status
  status=$(awk -F '\t' '$1 == "account-routing-mode" { value=$2 } END { print value }' "$report" 2>/dev/null)
  case "$status" in
    pushed|unchanged) return 0 ;;
  esac
  return 1
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  CURRENT_REGISTERED_SECONDMATE_HOME=$(secondmate_registry_value "$ID" home) || {
    echo "error: secondmate registration became unprovable for $ID" >&2
    exit 1
  }
  CURRENT_REGISTERED_SECONDMATE_HOME=$(fm_checkout_trusted_dir "$CURRENT_REGISTERED_SECONDMATE_HOME") || exit 1
  [ "$CURRENT_REGISTERED_SECONDMATE_HOME" = "$FIRSTMATE_HOME" ] || {
    echo "error: secondmate registration changed while spawn waited for lifecycle ownership" >&2
    exit 1
  }
  CURRENT_SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects) || {
    echo "error: secondmate project registration became unprovable for $ID" >&2
    exit 1
  }
  [ "$CURRENT_SECONDMATE_PROJECTS" = "$SECONDMATE_PROJECTS" ] || {
    echo "error: secondmate project registration changed while spawn waited for lifecycle ownership" >&2
    exit 1
  }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
else
  if [ "$RECOVERY_ACCOUNT" = 1 ]; then
    PROJ_ABS=$(fm_meta_get "$RESUME_META" project)
    WT=$(fm_meta_get "$RESUME_META" worktree)
    [ -n "$PROJ_ABS" ] && [ -d "$PROJ_ABS" ] || { echo "error: recorded project is unavailable for managed recovery: ${PROJ_ABS:-<missing>}" >&2; exit 1; }
    [ -n "$WT" ] && [ -d "$WT" ] || { echo "error: recorded worktree is unavailable for managed recovery: ${WT:-<missing>}" >&2; exit 1; }
  else
    PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
    WT=""
  fi
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md
# project management and task lifecycle). Resolve it before Treehouse
# acquisition so the crash-recovery record carries exact teardown authority
# even if spawn dies before endpoint creation or metadata installation.
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  MODE=$RECORDED_MODE
  YOLO=$RECORDED_YOLO
elif [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

if [ "$RECOVERY_ACCOUNT" = 1 ]; then
  RECORDED_TARGET=$(fm_backend_target_of_meta "$RESUME_META")
  RECOVERY_ENDPOINT_STATE=$(spawn_managed_endpoint_state "$BACKEND" "$RECORDED_TARGET" "fm-$ID" "$KIND" "$PROJ_ABS" "$(fm_meta_get "$RESUME_META" tmux_session_target)" 2>/dev/null)
  case "$RECOVERY_ENDPOINT_STATE" in
    absent) ;;
    present)
      echo "error: managed recovery endpoint is still alive for $ID; refusing to create a duplicate" >&2
      exit 1
      ;;
    *)
      echo "error: managed recovery endpoint state is unknown for $ID; refusing to create a duplicate" >&2
      exit 1
      ;;
  esac
fi

if [ "$KIND" = secondmate ]; then
  sm_primary_head=$(primary_head_commit "$FM_ROOT") || {
    echo "error: refusing secondmate launch because the primary default-branch commit cannot be resolved" >&2
    exit 1
  }
  if ! sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1); then
    echo "error: refusing secondmate launch because its home cannot fast-forward safely: $(first_line "$sm_ff_out")" >&2
    exit 1
  fi
  case "$sm_ff_out" in
    *': skipped:'*)
      echo "error: refusing secondmate launch because its home freshness is unresolved: $(first_line "$sm_ff_out")" >&2
      exit 1
      ;;
  esac
  spawn_checkout_refresh verify-home "$PROJ_ABS" "$FM_ROOT" || {
    echo "error: refusing secondmate launch because its live default-tip freshness cannot be proved" >&2
    exit 1
  }
  # Inheritable-config propagation: push the primary's declared LOCAL config into
  # this secondmate home's config/, so the secondmate's OWN crewmates and backlog
  # backend inherit the primary's settings. config/ is gitignored, so this is a
  # separate copy from the local-HEAD fast-forward above;
  # primary-authoritative and re-pushed on every convergence. config/secondmate-harness
  # is the primary's own knob and is deliberately NOT in the inheritable set
  # (fm-config-inherit-lib.sh). A primary with no inheritable config set is a no-op.
  CONFIG_INHERIT_REPORT_TMP=$(mktemp "$STATE/.fm-config-inherit.$ID.XXXXXX") || exit 1
  if ! FM_CONFIG_INHERIT_REPORT="$CONFIG_INHERIT_REPORT_TMP" \
    propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config"; then
    echo "warning: secondmate $ID config inheritance failed for $PROJ_ABS/config" >&2
  fi
  if ! secondmate_routing_config_inherited "$CONFIG_INHERIT_REPORT_TMP"; then
    echo "error: refusing secondmate launch for $PROJ_ABS: account-routing-mode inheritance did not succeed. Reconcile the home to this Firstmate revision, run bin/fm-config-push.sh, and retry." >&2
    exit 1
  fi
  if sm_inherited_routing_mode=$(fm_account_read_single_value "$PROJ_ABS/config/account-routing-mode" 2>/dev/null); then
    :
  else
    sm_routing_status=$?
    [ "$sm_routing_status" -eq 1 ] || {
      echo "error: refusing secondmate launch for $PROJ_ABS: the inherited account-routing-mode is unreadable. Run bin/fm-config-push.sh and retry." >&2
      exit 1
    }
    sm_inherited_routing_mode=off
  fi
  if [ "$sm_inherited_routing_mode" != "$ACCOUNT_PRIMARY_MODE" ]; then
    echo "error: refusing secondmate launch for $PROJ_ABS: the primary's $ACCOUNT_PRIMARY_MODE routing mode is not authoritative in the home. Run bin/fm-config-push.sh and retry." >&2
    exit 1
  fi
  if git -C "$PROJ_ABS" ls-files --error-unmatch bin/fm-account-routing-lib.sh >/dev/null 2>&1 \
    && [ ! -f "$PROJ_ABS/bin/fm-account-routing-lib.sh" ]; then
    echo "error: refusing secondmate $ID launch for home $PROJ_ABS: its dirty working tree is missing tracked Agent Fleet routing support. Restore or otherwise reconcile the home and retry." >&2
    exit 1
  fi
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
    if ! secondmate_home_supports_account_routing "$PROJ_ABS"; then
      echo "error: refusing account-routed secondmate $ID launch for home $PROJ_ABS: the home lacks Agent Fleet routing support, which indicates an unreconciled revision or dirty working tree. Fast-forward or otherwise reconcile the home to this Firstmate revision, run bin/fm-config-push.sh, and retry." >&2
      exit 1
    fi
  elif ! secondmate_home_supports_account_routing "$PROJ_ABS"; then
    echo "warning: secondmate $ID home $PROJ_ABS lacks Agent Fleet routing support; launching because account routing is $ACCOUNT_EFFECTIVE_MODE" >&2
  fi
  rm -f "$CONFIG_INHERIT_REPORT_TMP"
  CONFIG_INHERIT_REPORT_TMP=
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  BRIEF="$DATA/$ID/brief.md"
fi
if [ "$RESUME_ACCOUNT" != 1 ]; then
  [ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
fi
if [ "$KIND" = ship ] && [ "$RECOVERY_ACCOUNT" != 1 ]; then
  fm_completion_report_contract_ensure "$DATA" "$ID" "$BRIEF"
fi

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"
PROJ_ABS=$PROJ_ABS_REAL

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Refresh the checkout that will seed Treehouse before creating an endpoint.
# A dirty, off-default, or diverged checkout stays untouched and warns here, but
# does not make the acquisition unsafe: Treehouse fetches origin independently
# and resets the selected clean pool worktree from that remote-tracking ref.
# The post-acquisition verification below is the fail-closed freshness proof.
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$RECOVERY_ACCOUNT" != 1 ]; then
  if CHECKOUT_PREFLIGHT_OUT=$(spawn_checkout_refresh preflight "$PROJ_ABS_REAL" 2>&1); then
    CHECKOUT_PREFLIGHT_STATUS=0
  else
    CHECKOUT_PREFLIGHT_STATUS=$?
  fi
  if [ "$CHECKOUT_PREFLIGHT_STATUS" -ne 0 ]; then
    echo "warning: checkout refresh could not advance $PROJ_ABS before worktree acquisition: $(first_line "$CHECKOUT_PREFLIGHT_OUT")" >&2
  fi
fi

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real wt_common proj_common provider_path provider_real
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git_repository_probe -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
  fm_checkout_validate_git_metadata "$wt_real" >/dev/null || {
    echo "error: $source returned redirected or unprovable Git metadata at $wt_real" >&2
    exit 1
  }
  fm_checkout_validate_git_metadata "$proj_real" >/dev/null || {
    echo "error: project Git metadata is unprovable at $proj_real" >&2
    exit 1
  }
  wt_common=$(fm_checkout_git_common_dir "$wt_real") || exit 1
  proj_common=$(fm_checkout_git_common_dir "$proj_real") || exit 1
  [ "$wt_common" = "$proj_common" ] || {
    echo "error: $source returned a worktree from an unrelated repository" >&2
    exit 1
  }
  if [ "$BACKEND" = orca ]; then
    fm_backend_orca_authority_capabilities_check || exit 1
    provider_path=$(fm_backend_orca_worktree_path "$ORCA_WORKTREE_ID") || exit 1
    provider_real=$(fm_checkout_trusted_dir "$provider_path") || exit 1
    [ "$provider_real" = "$wt_real" ] || {
      echo "error: Orca worktree identity does not match its returned path" >&2
      exit 1
    }
  fi
}

# Keep a worktree-resident file out of git's view, so firstmate-owned launch
# machinery and provisioned dependency directories can never dirty the checkout
# that the freshness proof and teardown both require to be clean. Defined here
# because both the provisioning step below and the per-harness turn-end hooks
# further down use it.
#
# Returns 0 only once the exclusion is present in info/exclude and read back,
# and non-zero otherwise. Provisioning depends on that real status: it treats
# registration as a checked prerequisite and refuses to run an installer that
# would otherwise leave an unignored directory behind. The turn-end hook call
# sites below deliberately tolerate a failure instead, since losing a hook
# exclusion is a dirty-checkout nuisance, not a reason to refuse a spawn.
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git_repository_probe -C "$WT" rev-parse --git-path info/exclude 2>/dev/null) || return 1
  [ -n "$EXCL" ] || return 1
  mkdir -p "$(dirname "$EXCL")" || return 1
  grep -qxF "$rel" "$EXCL" 2>/dev/null && return 0
  printf '%s\n' "$rel" >> "$EXCL" || return 1
  grep -qxF "$rel" "$EXCL" 2>/dev/null
}

# Whether a path provisioning is about to create is ALREADY outside git's view,
# by the project's own ignore rules. It deliberately does NOT write an exclusion
# to make that true.
#
# It used to call exclude_path, and that was wrong in a way worth recording. For
# a linked worktree `git rev-parse --git-path info/exclude` resolves to the
# MAIN clone's .git/info/exclude, so provisioning a leased worktree wrote a
# durable, repo-wide rule into the captain's primary checkout and made that path
# invisible to `git status` there. Writing the linked worktree's own
# info/exclude instead does not work - git does not read it - and it would still
# pass this function's read-back check, so the exclusion would silently apply to
# nothing. Per-worktree core.excludesFile via extensions.worktreeConfig does
# work, but it displaces the operator's global excludes inside the worktree and
# is durable config complexity for a case that should be rare.
#
# So provisioning now refuses instead of hiding. A component whose install
# directory the project does not already ignore is one whose installed tree
# would show up as untracked, which fails the returnable check on abort and
# strands the pool lease - the failure that hard-blocks the fleet when every
# workspace is held. Refusing costs that project one line in its own .gitignore;
# guessing costs a lease and mutates a checkout firstmate must never write to.
fm_provision_register_exclude() {
  local rel=$1
  git_repository_probe -C "$WT" check-ignore -q "${rel#/}" 2>/dev/null
}

# Provision the freshly proven worktree's declared project dependencies, so the
# lane launched into it can run the project's own tests, formatters, and browser
# checks instead of shipping on another agent's evidence. Runs after the
# identity/cleanliness/freshness proof and before any endpoint exists, which is
# the only place it can: the directories involved are gitignored so they never
# travel with a worktree, and Treehouse v2.0.0 exposes no setup hook.
# bin/fm-provision-lib.sh owns detection, caching, readiness, bounds, and the
# capability-gap versus failure contract.
#
# The provisioning log is a per-task state artifact like $ID.status and
# $ID.meta: teardown removes it with the rest of the set, and an aborted spawn
# removes it here rather than leaking one file per attempt into the home's state
# directory. Because the abort path removes it, a refusal prints the tail of the
# log itself - the installer output IS the diagnosis, and pointing at a file the
# rollback is about to delete would be pointing at nothing.
PROVISION_SUMMARY=
PROVISION_PATH_PREFIX=
spawn_provision_worktree() {
  local mode
  # Before either opt-out, because an opted-out lease is the one that would
  # otherwise read the previous task's report as a description of its own
  # worktree - the more provisioning does here, the louder its absence must be.
  fm_provision_clear_report "$WT" || {
    echo "error: cannot remove a previous lease's provisioning report at $WT/$FM_PROVISION_REPORT_NAME" >&2
    echo "       fm-$ID would read it as a description of its own worktree, so the spawn is refused; remove that path by hand." >&2
    return 1
  }
  if [ "$NO_PROVISION" = 1 ]; then
    PROVISION_SUMMARY=off
    return 0
  fi
  mode=$(fm_provision_mode "$CONFIG") || {
    echo "error: config/worktree-provision must contain exactly 'on' or 'off'" >&2
    return 1
  }
  if [ "$mode" = off ]; then
    PROVISION_SUMMARY=off
    return 0
  fi
  PROVISION_LOG="$STATE/$ID.provision.log"
  if [ -e "$PROVISION_LOG" ] || [ -L "$PROVISION_LOG" ]; then
    ORIGINAL_PROVISION_LOG_PRESENT=1
  else
    ORIGINAL_PROVISION_LOG_PRESENT=0
  fi
  if ! fm_provision_worktree "$WT" "$STATE/provision-cache" "$PROVISION_LOG" "$DATA/$ID/brief.md"; then
    if [ -s "$PROVISION_LOG" ]; then
      echo "error: last 40 lines of the provisioning log for $ID (not retained past this refused spawn):" >&2
      tail -n 40 "$PROVISION_LOG" >&2
    fi
    return 1
  fi
  PROVISION_SUMMARY=$FM_PROVISION_SUMMARY
  PROVISION_PATH_PREFIX=$FM_PROVISION_PATH_PREFIX
  return 0
}

validate_orca_abort_worktree_identity() {
  local wt_root project_root wt_common project_common provider_path provider_root
  [ -n "${ORCA_WORKTREE_ID:-}" ] && [ -n "${WT:-}" ] && [ -n "${PROJ_ABS:-}" ] || return 1
  wt_root=$(fm_checkout_trusted_dir "$WT") || return 1
  project_root=$(fm_checkout_trusted_dir "$PROJ_ABS") || return 1
  [ "$wt_root" != "$project_root" ] || return 1
  fm_checkout_validate_git_metadata "$wt_root" >/dev/null || return 1
  fm_checkout_validate_git_metadata "$project_root" >/dev/null || return 1
  wt_common=$(fm_checkout_git_common_dir "$wt_root") || return 1
  project_common=$(fm_checkout_git_common_dir "$project_root") || return 1
  [ "$wt_common" = "$project_common" ] || return 1
  provider_path=$(fm_backend_orca_worktree_path "$ORCA_WORKTREE_ID") || return 1
  provider_root=$(fm_checkout_trusted_dir "$provider_path") || return 1
  [ "$provider_root" = "$wt_root" ]
}

if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  validate_spawn_worktree "recorded direct account recovery" "$RECORDED_TARGET"
  recorded_project_common=$(git_common_dir_real "$PROJ_ABS" 2>/dev/null || true)
  recorded_worktree_common=$(git_common_dir_real "$WT" 2>/dev/null || true)
  if [ -z "$recorded_project_common" ] || [ -z "$recorded_worktree_common" ] \
    || [ "$recorded_project_common" != "$recorded_worktree_common" ]; then
    echo "error: recorded direct account recovery worktree '$WT' does not belong to recorded project '$PROJ_ABS'; refusing endpoint creation" >&2
    exit 1
  fi
  validate_direct_recovery_worktree_identity || exit 1
fi

if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$RECOVERY_ACCOUNT" != 1 ]; then
  spawn_checkout_refresh pool-preflight "$PROJ_ABS_REAL" || {
    echo "error: refusing Treehouse acquisition because pool safety could not be inspected for $PROJ_ABS" >&2
    exit 1
  }
  create_worktree_acquisition_record || exit 1
  acquire_status=0
  WT=$(spawn_checkout_refresh acquire-worktree "$PROJ_ABS_REAL" "firstmate-$ID") || acquire_status=$?
  if [ "$acquire_status" -ne 0 ]; then
    if [ "$acquire_status" -eq 124 ]; then
      echo "error: refusing to spawn $ID after the bounded Treehouse acquisition timed out" >&2
    else
      echo "error: treehouse get --lease failed to acquire a task worktree for $ID" >&2
    fi
    exit 1
  fi
  [ -n "$WT" ] || {
    echo "error: treehouse get --lease did not report a task worktree for $ID" >&2
    exit 1
  }
  WORKTREE_CREATED=1
  WORKTREE_RETAIN_ON_ABORT=1
  record_acquired_worktree || exit 1
  validate_spawn_worktree "treehouse get --lease" "$PROJ_ABS"
  freshness_status=0
  spawn_checkout_refresh verify-worktree "$WT" "$PROJ_ABS_REAL" || freshness_status=$?
  if [ "$freshness_status" -ne 0 ]; then
    echo "error: refusing to launch fm-$ID from a leased worktree whose repository identity, cleanliness, or default-tip freshness could not be proved" >&2
    exit 1
  fi
  WORKTREE_EXPECTED_TIP=$(git -C "$WT" rev-parse HEAD) || exit 1
  WORKTREE_RETAIN_ON_ABORT=0
  spawn_provision_worktree || exit 1
fi

if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  META_WRITE_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  direct_recovery_context_matches || {
    echo "error: direct account task generation changed before recovery mutation for $ID" >&2
    exit 1
  }
  META_BACKUP=$(mktemp "$STATE/.$ID.meta.rollback.XXXXXX") || exit 1
  cp -p "$RESUME_META" "$META_BACKUP" || exit 1
  snapshot_existing_artifacts || exit 1
  fm_account_meta_lock_release "$META_WRITE_LOCK" || exit 1
  META_WRITE_LOCK=
fi

if [ "$DIRECT_ACCOUNT_PREPARE_DEFERRED" = 1 ]; then
  if [ "$DIRECT_ACCOUNT_SECONDMATE" = 1 ]; then
    # observe means "route when routing is possible", never "refuse to launch".
    # On a fresh install, or any home whose account directories have not been
    # provisioned, selection legitimately has nothing to choose from. Refusing
    # here would leave a domain supervisor down entirely, which is strictly worse
    # than running it on the provider's default identity - the outcome observe
    # mode produced before this path existed.
    # The degrade is deliberately LOUD and recorded in metadata rather than
    # silent: a silently un-routed secondmate is the exact bug this change fixes,
    # so it must be visible as a degraded launch instead of looking healthy.
    if DIRECT_ACCOUNT_HOME=$("$SCRIPT_DIR/fm-account-directory.sh" prepare "$HARNESS"); then
      echo "fm-spawn: selected direct $HARNESS account home $DIRECT_ACCOUNT_HOME" >&2
    else
      DIRECT_ACCOUNT_HOME=
      DIRECT_ACCOUNT_SECONDMATE=0
      DIRECT_ACCOUNT_DEGRADED=1
      echo "WARNING: secondmate $ID could not be routed to a $HARNESS account directory; launching on the provider's default identity instead of refusing. This secondmate shares whatever identity the environment supplies, so account load is NOT balanced for it. Provision this machine's $HARNESS account directories and respawn to restore routing." >&2
    fi
  else
    DIRECT_ACCOUNT_HOME=$("$SCRIPT_DIR/fm-account-directory.sh" prepare "$HARNESS") || exit 1
    echo "fm-spawn: selected direct $HARNESS account home $DIRECT_ACCOUNT_HOME" >&2
  fi
  DIRECT_ACCOUNT_PREPARE_DEFERRED=0
fi

if [ "$CONTINUE_ACCOUNT" = 1 ]; then
  CONTINUATION_RESULT=$(FM_ACCOUNT_CONTINUATION_EMIT_PROMPT_B64=1 \
    "$SCRIPT_DIR/fm-account-continuation.sh" "$ID" "$ACCOUNT_ATTEMPT") || exit 1
  case "$CONTINUATION_RESULT" in *$'\n'*) ;; *) echo "error: continuation prompt snapshot is incomplete for $ID" >&2; exit 1 ;; esac
  CONTINUATION_PACKET=${CONTINUATION_RESULT%%$'\n'*}
  CONTINUATION_PROMPT_B64=${CONTINUATION_RESULT#*$'\n'}
  CONTINUATION_LAUNCH_DIR=$(mktemp -d "$STATE/.$ID.continuation-launch.XXXXXX") \
    || { echo "error: cannot stage continuation native prompt for $ID" >&2; exit 1; }
  chmod 700 "$CONTINUATION_LAUNCH_DIR" || exit 1
  CONTINUATION_PROMPT_FILE="$CONTINUATION_LAUNCH_DIR/prompt"
  if ! CONTINUATION_PROMPT_IDENTITIES=$(printf '%s' "$CONTINUATION_PROMPT_B64" | python3 -c '
import base64, hashlib, os, sys
data = base64.b64decode(sys.stdin.buffer.read(), validate=True)
parent_path, name = os.path.split(os.path.abspath(sys.argv[1]))
parent_fd = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
try:
    written = 0
    while written < len(data):
        written += os.write(fd, data[written:])
    os.fsync(fd)
    parent = os.fstat(parent_fd)
    prompt = os.fstat(fd)
    sys.stdout.write(f"{parent.st_dev}:{parent.st_ino}\n{prompt.st_dev}:{prompt.st_ino}\n{hashlib.sha256(data).hexdigest()}\n")
finally:
    os.close(fd)
    os.close(parent_fd)
' "$CONTINUATION_PROMPT_FILE"); then
    echo "error: continuation prompt snapshot cannot be transported byte-verbatim for $ID" >&2
    exit 1
  fi
  CONTINUATION_PROMPT_DIR_ID=${CONTINUATION_PROMPT_IDENTITIES%%$'\n'*}
  CONTINUATION_PROMPT_REMAINDER=${CONTINUATION_PROMPT_IDENTITIES#*$'\n'}
  CONTINUATION_PROMPT_FILE_ID=${CONTINUATION_PROMPT_REMAINDER%%$'\n'*}
  CONTINUATION_PROMPT_CONTENT_ID=${CONTINUATION_PROMPT_REMAINDER#*$'\n'}
  [ -n "$CONTINUATION_PROMPT_DIR_ID" ] && [ -n "$CONTINUATION_PROMPT_FILE_ID" ] \
    && [ -n "$CONTINUATION_PROMPT_CONTENT_ID" ] \
    || { echo "error: continuation native prompt identity is unavailable for $ID" >&2; exit 1; }
  BRIEF=$CONTINUATION_PACKET
fi

PI_AUTHOR_ACCOUNT_HOME=

# prepare_launch_environment: every step the launch-command construction below
# The PATH a crewmate's tool commands run with. A harness executes tool commands
# through a NON-interactive shell, and on this class of host that shell reads only
# ~/.zshenv - never ~/.zprofile or ~/.zshrc, which is where Homebrew puts itself.
# zsh's compiled-in default is /bin:/usr/bin:/usr/ucb:/usr/local/bin, so a crewmate can
# end up unable to see gh, node, or the axi tooling even though every one of them is
# installed and its worktree is perfectly fine. Crewmates burned whole CI-repair rounds
# on "gh is absent" before this was traced to shell startup rather than the worktree.
#
# Firstmate's own PATH is the seed because it is proven by construction: firstmate
# runs gh-axi, treehouse, and tasks-axi itself. Seeding from it also preserves the
# exact resolution ORDER the host already has, so this cannot silently repoint a
# command (notably `claude`, which a host may front with a shim) - it only ever adds
# reach. The standard locations are appended for the case where firstmate itself was
# launched with a thin PATH; missing directories and duplicates are dropped.
#
# PROVISION_PATH_PREFIX leads when provisioning pinned a runtime the project
# declares (e.g. a .nvmrc Node): the crewmate must validate on the SAME runtime
# its dependencies were installed against, or native modules load against the
# wrong ABI and the lane cannot run its own checks even though node_modules is
# present (data/v3-env-repair-e3/report.md, 2026-08-05). That prefix holds
# EXACTLY node, npm, npx, and corepack (fm_provision_node_path_prefix), never a
# version-manager bin directory - such a directory also holds every globally
# npm-installed CLI for that Node, including the harnesses launched below, so
# leading with it would repoint `claude` or `codex` at whichever copy sits under
# the pinned runtime. The invariant above therefore still holds for every
# command except the Node toolchain the pin exists to fix.
crew_tool_path() {
  local seed dir out='' brew=/opt/homebrew
  [ -d "$brew" ] || brew=/usr/local
  seed="${PROVISION_PATH_PREFIX:+$PROVISION_PATH_PREFIX:}$PATH:$HOME/.local/bin:$brew/bin:$brew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local IFS=:
  for dir in $seed; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    # A single quote would break the quoting of the typed pane export below.
    case $dir in *"'"*) continue ;; esac
    case ":$out:" in *":$dir:"*) continue ;; esac
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}

# depends on - worktree canonicalization, the per-task temp root, the per-harness
# turn-end hook, delivery mode/yolo, and account selection. The body is unchanged
# and deliberately NOT re-indented (it contains heredocs whose bodies are written
# verbatim into hook files); it is wrapped in a function only so the herdr backend
# can run it BEFORE endpoint creation, because herdr `agent start` needs the final
# agent argv up front, while every other backend keeps calling it exactly where it
# ran before. orca is why this is not simply hoisted for all backends: orca only
# learns its worktree path during endpoint creation.
prepare_launch_environment() {
if [ "$DIRECT_ACCOUNT_ROUTING" = 1 ] && [ "$DIRECT_ACCOUNT_RECOVERY" = 0 ] && [ "$KIND" != secondmate ]; then
  WT=$(cd "$WT" 2>/dev/null && pwd -P) || {
    echo "error: cannot canonicalize direct account worktree for $ID" >&2
    exit 1
  }
  capture_worktree_git_physical_identity "$WT" || {
    echo "error: cannot record exact direct account worktree identity for $ID" >&2
    exit 1
  }
fi

# Per-task temp root with Go's build temp nested at gotmp/. The physical task
# state directory is its namespace, so separate homes and test runs cannot
# share a root even when their human-readable task ids match. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare task-root/gotmp) so other per-task temp can live alongside
# later, and teardown removes only this recorded generation. GOTMPDIR (not TMPDIR)
# is the targeted knob: TMPDIR is too broad (affects every program's temp, not
# just Go's).
TASK_TMP=$SPAWN_TASK_TMP
if spawn_test_lab_enabled && [ "${FM_TEST_TASKTMP_CREATE_FAIL:-0}" = 1 ]; then
  echo "error: test-only task temp creation failure for $ID" >&2
  exit 1
fi
mkdir -p "$TASK_TMP/gotmp"
WORKTREE_ACQUIRE_TASKTMP_PHASE=created
persist_worktree_acquisition_phases || {
  echo "error: cannot durably record task temp creation for $ID" >&2
  exit 1
}
# A cloud-placed pi crewmate never takes a LOCAL task-private account snapshot:
# the recorded account_home is the binding the worker lifecycle stages, and
# pi's own extension owns profile selection on the worker.
if [ "$HARNESS" = pi ] && [ "$RAW_LAUNCH" != 1 ] && [ "$SPAWN_CLOUD" != azure ]; then
  PI_AUTHOR_SOURCE_HOME=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
  PI_AUTHOR_ACCOUNT_HOME="$TASK_TMP/pi-author-agent"
  if "$SCRIPT_DIR/fm-pi-author-snapshot.py" \
    "$PI_AUTHOR_SOURCE_HOME" "$PI_AUTHOR_ACCOUNT_HOME"; then
    :
  else
    PI_AUTHOR_ACCOUNT_HOME=
    echo "WARNING: Pi task-private account capture failed; launching $ID without the captured account snapshot" >&2
  fi
fi
# herdr sets GOTMPDIR natively at agent start. Every other backend exports it into
# the pane shell just before the launch line, further down. CREW_PATH rides the same
# two channels for the same reason.
CREW_PATH=$(crew_tool_path)
if [ "$BACKEND" = herdr ]; then
  HERDR_AGENT_ENV+=("GOTMPDIR=$TASK_TMP/gotmp")
  HERDR_AGENT_ENV+=("PATH=$CREW_PATH")
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
fm_account_real_directory "$STATE" || { echo "error: unsafe state directory at $STATE" >&2; exit 1; }
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      if [ "$ACCOUNT_EFFECTIVE_MODE" != enforce ]; then
        mkdir -p "$WT/.claude"
        cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
        exclude_path '.claude/settings.local.json' \
          || echo "warning: could not exclude .claude/settings.local.json from git's view" >&2
      fi
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js' \
        || echo "warning: could not exclude .opencode/plugins/fm-turn-end.js from git's view" >&2
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend' \
        || echo "warning: could not exclude .fm-grok-turnend from git's view" >&2
      ;;
  esac
fi

if [ "$ACCOUNT_EFFECTIVE_MODE" = observe ]; then
  fm_account_select observe "$HARNESS" "$ACCOUNT_POOL" "$ACCOUNT_PROFILE" "$ACCOUNT_TASK" "$WT" || exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  if [ "$RESUME_ACCOUNT" = 1 ]; then
    if fm_account_recover "$ACCOUNT_TASK" "$ACCOUNT_PROFILE" "$ACCOUNT_POOL" "$HARNESS" "$WT"; then
      ACCOUNT_LEASE_CREATED=1
    else
      persist_failed_account_rollback_short || true
      exit 1
    fi
    persist_failed_account_rollback_short || exit 1
    fm_account_lineage_append "$DATA" "$ID" native-resume "$ACCOUNT_ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$ACCOUNT_POOL" "$ACCOUNT_PROFILE" "$RECORDED_SESSION" none || exit 1
  else
    persist_failed_account_rollback_short || exit 1
    if fm_account_select enforce "$HARNESS" "$ACCOUNT_POOL" "$ACCOUNT_PROFILE" "$ACCOUNT_TASK" "$WT"; then
      :
    else
      account_select_status=$?
      if [ "$account_select_status" -eq 2 ]; then
        ACCOUNT_LEASE_CREATED=1
        persist_failed_account_rollback_short || true
      fi
      exit 1
    fi
    ACCOUNT_PROFILE=$FM_ACCOUNT_SELECTED_PROFILE
    ACCOUNT_LEASE_CREATED=1
    FM_ACCOUNT_MUTATION_ACQUIRED=0
    persist_failed_account_rollback_short || exit 1
    fm_account_lineage_append "$DATA" "$ID" reserved "$ACCOUNT_ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$ACCOUNT_POOL" "$ACCOUNT_PROFILE" pending "$ACCOUNT_PREDECESSOR_TASK" || exit 1
  fi
fi

if [ "$DIRECT_ACCOUNT_ROUTING" = 1 ]; then
  if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
    validate_direct_recovery_worktree_identity || exit 1
  else
    validate_direct_launch_worktree_identity || exit 1
    capture_direct_launch_authoritative_state || {
      echo "error: cannot record authoritative direct account worktree Git state for $ID" >&2
      exit 1
    }
  fi
fi
}

# build_launch_command: resolve LAUNCH (the full harness launch command) and its
# placeholders. Body unchanged and not re-indented, for the same reasons as
# prepare_launch_environment above.
build_launch_command() {
sq_brief=$(shell_quote "$BRIEF")
if [ "$CONTINUE_ACCOUNT" = 1 ]; then
  continuation_prompt_command="\$(cat __BRIEF__)"
  continuation_prompt_marker="\"$continuation_prompt_command\""
  case "$HARNESS" in
    claude) continuation_prompt_reference= ;;
    codex) continuation_prompt_reference= ;;
    *) echo "error: continuation native prompt launch supports only claude and codex" >&2; exit 1 ;;
  esac
  LAUNCH=${LAUNCH//$continuation_prompt_marker/$continuation_prompt_reference}
  case "$LAUNCH" in *"$continuation_prompt_command"*) echo "error: continuation prompt was not bound to its verified generation" >&2; exit 1 ;; esac
fi
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
if [ "$RESUME_ACCOUNT" = 1 ]; then
  case "$HARNESS:$KIND" in
    claude:*) LAUNCH='CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false __AGENT__ --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__' ;;
    codex:secondmate) LAUNCH='__AGENT__ __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox' ;;
    codex:*) LAUNCH='__AGENT__ __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]"' ;;
    *) echo "error: managed recovery supports only claude and codex" >&2; exit 1 ;;
  esac
fi
AGENT_COMMAND=$HARNESS
if [ "$HARNESS" = pi ] && [ -n "$PI_AUTHOR_ACCOUNT_HOME" ]; then
  AGENT_COMMAND="PI_CODING_AGENT_DIR=$(shell_quote "$PI_AUTHOR_ACCOUNT_HOME") pi"
fi
if [ "$DIRECT_ACCOUNT_ROUTING" = 1 ] || [ "$DIRECT_ACCOUNT_SECONDMATE" = 1 ]; then
  # herdr delivers the account directory NATIVELY, as `agent start --env KEY=VALUE`
  # (HERDR_AGENT_ENV below), instead of as a command-scoped shell prefix. Verified
  # before making the switch: no login profile on this machine sets CODEX_HOME or
  # CLAUDE_CONFIG_DIR, so the natively-injected value cannot be overwritten by the
  # login shell that evaluates the launch command. Every other backend keeps the
  # shell prefix, which is the only delivery mechanism a typed launch line has.
  case "$HARNESS:$BACKEND" in
    claude:herdr) HERDR_AGENT_ENV+=("CLAUDE_CONFIG_DIR=$DIRECT_ACCOUNT_HOME") ;;
    codex:herdr) HERDR_AGENT_ENV+=("CODEX_HOME=$DIRECT_ACCOUNT_HOME") ;;
    claude:*) AGENT_COMMAND="CLAUDE_CONFIG_DIR=$(shell_quote "$DIRECT_ACCOUNT_HOME") $HARNESS" ;;
    codex:*) AGENT_COMMAND="CODEX_HOME=$(shell_quote "$DIRECT_ACCOUNT_HOME") $HARNESS" ;;
  esac
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  if [ "$RESUME_ACCOUNT" = 1 ]; then
    rm -rf "$STATE/.$ID.account-native-launch" "$STATE/.$ID.account-native-ready" "$STATE/.$ID.account-native-go" || exit 1
    ACCOUNT_NATIVE_LAUNCH_DIR=$(mktemp -d "$STATE/.$ID.account-native-launch.XXXXXX") || exit 1
    chmod 700 "$ACCOUNT_NATIVE_LAUNCH_DIR" || exit 1
    ACCOUNT_NATIVE_LAUNCH_SCRIPT="$ACCOUNT_NATIVE_LAUNCH_DIR/account-native-launch"
    ACCOUNT_NATIVE_LAUNCH_READY="$ACCOUNT_NATIVE_LAUNCH_DIR/ready"
    ACCOUNT_NATIVE_LAUNCH_GO="$ACCOUNT_NATIVE_LAUNCH_DIR/go"
    resume_command=$(fm_account_resume_command "$ACCOUNT_TASK" "$WT" "$TURNEND") || exit 1
    if [ "$BACKEND" = herdr ]; then
      native_shell=$(fm_backend_herdr_managed_shell_bin) || {
        echo "error: managed Herdr worker shell is unavailable for native resume" >&2
        exit 1
      }
    else
      # Non-Herdr enforced recovery is reachable only in the explicit test lab.
      native_shell="$FM_ROOT/bin/fm-herdr-worker-shell"
      [ -f "$native_shell" ] && [ ! -L "$native_shell" ] && [ -x "$native_shell" ] || {
        echo "error: closed worker shell is unavailable for native resume" >&2
        exit 1
      }
    fi
    native_ready_q=$(fm_account_shell_quote "$ACCOUNT_NATIVE_LAUNCH_READY")
    native_go_q=$(fm_account_shell_quote "$ACCOUNT_NATIVE_LAUNCH_GO")
    if ! ( set -C; cat > "$ACCOUNT_NATIVE_LAUNCH_SCRIPT" <<EOF
#!$native_shell
set -euC
: > $native_ready_q
while [ ! -f $native_go_q ]; do /bin/sleep 0.05; done
/bin/rm -f $native_ready_q $native_go_q
exec $resume_command "\$@"
EOF
    ); then
      echo "error: could not create private native provider launch wrapper for $ID" >&2
      exit 1
    fi
    chmod +x "$ACCOUNT_NATIVE_LAUNCH_SCRIPT"
    AGENT_COMMAND=$(fm_account_shell_quote "$ACCOUNT_NATIVE_LAUNCH_SCRIPT")
  else
    AGENT_COMMAND=$(fm_account_exec_command "$ACCOUNT_PROFILE" "$ACCOUNT_POOL" "$ACCOUNT_TASK" "$WT" "$TURNEND") || exit 1
  fi
fi
LAUNCH=${LAUNCH//__AGENT__/$AGENT_COMMAND}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME=$sq_home $LAUNCH"
fi
if [ "$CONTINUE_ACCOUNT" = 1 ]; then
  continuation_launch_command=$LAUNCH
  LAUNCH="$(shell_quote python3) $(shell_quote "$SCRIPT_DIR/fm-prompt-exec.py") $(shell_quote "$CONTINUATION_PROMPT_FILE") $(shell_quote "$CONTINUATION_PROMPT_DIR_ID") $(shell_quote "$CONTINUATION_PROMPT_FILE_ID") $(shell_quote "$CONTINUATION_PROMPT_CONTENT_ID") $(shell_quote "$continuation_launch_command")"
fi
}

W="fm-$ID"
# herdr launches natively: `herdr agent start ... -- <argv>` creates the pane AND
# starts the agent in one call, so the whole launch command must exist BEFORE
# endpoint creation rather than being typed into a pane shell afterwards. Run the
# two launch-preparation blocks up front for herdr only; every other backend calls
# them at their original positions further down (see their definitions above).
if [ "$BACKEND" = herdr ]; then
  prepare_launch_environment
  build_launch_command
fi
SPAWN_CWD=${WT:-$PROJ_ABS}
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  validate_direct_recovery_worktree_identity || exit 1
fi
# Cloud placement still creates a local endpoint, but a Herdr TRACKING one:
# the crewmate entrypoint runs on an elastic worker through
# bin/fm-worker-lifecycle.sh after metadata install, while the Herdr tab runs
# the cloud monitor so the crewmate stays visible and reapable in the same
# workspace as local crewmates. The worker entrypoint is preserved verbatim
# in CLOUD_WORKER_LAUNCH before the endpoint's own launch string replaces
# LAUNCH for the tracking pane.
if [ "$SPAWN_CLOUD" = azure ]; then
  # The crewmate entrypoint runs on the worker against a FIXED staged layout
  # (docs/azure-worker-runtime.md D3): the supervisor clones the shipped
  # repository bundle to /mnt/task/repo (the execution cwd), places the brief
  # and the pi extension under /mnt/task/.fm-task/, and stages the provider
  # account at /mnt/account/pi-agent. The local LAUNCH string is therefore
  # NOT reused - its paths exist only on this machine. --print keeps the run
  # bounded and non-interactive under the supervisor's device-null stdin.
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands on the worker, not here
  CLOUD_WORKER_LAUNCH="env PI_CODING_AGENT_DIR=/mnt/account/pi-agent pi --print --approve --exclude-tools ask_question --fast ${MODELFLAG}${EFFORTFLAG}"'"$(cat /mnt/task/.fm-task/brief.md)"'
  # A secondmate compartment has no single worker entrypoint: its session
  # legs are built and dispatched by fm-secondmate-cloud-monitor.sh, so the
  # crewmate launch string above is never persisted or executed for it.
  [ "$KIND" != secondmate ] || CLOUD_WORKER_LAUNCH=
  # Cloud state files are keyed by task ID while the queue is keyed
  # ID@GENERATION: a re-spawn of the same task must not inherit the previous
  # generation's result (the monitor would exit on it at once), dispatch
  # marker (both owners would stand down and the new worker would never
  # execute), or logs. Swept HERE, before the tracking pane exists, so the
  # new monitor can never observe them.
  # Through the one owner (bin/fm-cloud-state-lib.sh), never a second spelling
  # of the file set: this sweep and the library used to enumerate the names
  # separately, so a name added to one was invisible to the other. The rebase
  # onto #280 is that exact case caught in the act: it added
  # <id>.worker-request.out to this sweep only, so nothing removed it at the
  # END of a task's life. It is in the library's enumeration now, which is why
  # the task-end remover covers it too.
  fm_cloud_state_remove_generation "$STATE" "$ID"
  if [ "$KIND" = secondmate ]; then
    # Compartment monitor state is generation-scoped the same way: a re-spawn
    # must not inherit leg dispatch markers (the new monitor would think legs
    # already ran), the collect cursor, the chain state, or a terminal status.
    rm -f "$STATE/$ID".cloud-secondmate-leg-*.dispatched \
      "$STATE/$ID".cloud-secondmate-leg-*.result.json \
      "$STATE/$ID".cloud-secondmate-leg-*.log \
      "$STATE/$ID.cloud-secondmate-state.json" "$STATE/$ID.cloud-secondmate-status" \
      "$STATE/$ID.cloud-secondmate-first-dispatch" "$STATE/$ID.cloud-collect-cursor"
    # The mailbox can hold unlanded commit bundles and the inbox unrelayed
    # captain text - the same "never destroy the last copy" doctrine as the
    # outcome directory below. Preserve non-empty ones under superseded names.
    for cloud_dir in cloud-mailbox cloud-inbox; do
      if [ -d "$STATE/$ID.$cloud_dir" ] && [ -n "$(ls -A "$STATE/$ID.$cloud_dir" 2>/dev/null)" ]; then
        superseded="$STATE/$ID.$cloud_dir.superseded-$(date -u +%Y%m%d%H%M%S)-$$"
        if mv "$STATE/$ID.$cloud_dir" "$superseded"; then
          echo "notice: $ID had a non-empty $cloud_dir; preserved at $superseded" >&2
        else
          echo "error: $ID has a non-empty $cloud_dir that could not be preserved; refusing to sweep it" >&2
          exit 1
        fi
      fi
      rm -rf "$STATE/$ID.$cloud_dir"
    done
  fi
  # The outcome directory is NOT transport. When the monitor cannot
  # fast-forward it tells the operator the bundle is "kept for manual
  # landing", and by then the guest copy is usually gone with the VM, so a
  # re-spawn deleting it would destroy the last copy of the crewmate's
  # commits. Preserve any bundle under a superseded name instead, and say so.
  if [ -s "$STATE/$ID.cloud-outcome/outcome.bundle" ]; then
    superseded="$STATE/$ID.cloud-outcome.superseded-$(date -u +%Y%m%d%H%M%S)-$$"
    if mv "$STATE/$ID.cloud-outcome" "$superseded"; then
      echo "notice: $ID had an unlanded outcome bundle; preserved at $superseded/outcome.bundle" >&2
    else
      # Failing here and sweeping anyway would destroy the last copy of the
      # crewmate's commits, which is the whole reason this block exists. Fail
      # closed instead: refuse the re-spawn rather than choose silently
      # between destroying the work and landing it for the wrong generation.
      echo "error: $ID has an unlanded outcome bundle that could not be preserved; refusing to sweep it" >&2
      exit 1
    fi
  fi
  rm -rf "$STATE/$ID.cloud-outcome"
  # The Herdr server starts endpoint panes in its closed environment, so the
  # monitor's own FM_HOME (and any state override the spawn ran with) must
  # travel inside the launch string; without FM_HOME the monitor's
  # required-environment guard exits at once and the tracking pane dies at
  # spawn time.
  CLOUD_MONITOR_SCRIPT=$SCRIPT_DIR/fm-spawn-cloud-monitor.sh
  # A secondmate compartment's pane runs the compartment monitor: the same
  # tracking-pane idiom, but it owns leg dispatch, inbox relay, collect and
  # chain verification instead of a single converged execute.
  [ "$KIND" != secondmate ] || CLOUD_MONITOR_SCRIPT=$SCRIPT_DIR/fm-secondmate-cloud-monitor.sh
  LAUNCH="FM_HOME=$(printf '%q' "$FM_HOME") FM_STATE_OVERRIDE=$(printf '%q' "$STATE") exec $(printf '%q' "$CLOUD_MONITOR_SCRIPT") $(printf '%q' "$ID") $(printf '%q' "$SPAWN_GENERATION_ID")"
fi
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id>.
    # WT_TARGET carries that stable id for spawn-time commands below; the
    # persisted window= handle stays $T (the name form), which is safe now that
    # rename is disabled.
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=creating
    persist_worktree_acquisition_phases || exit 1
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$SPAWN_CWD") || exit 1
    ENDPOINT_CREATED=1
    WT_TARGET="$WID"
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=created
    persist_worktree_acquisition_phases || exit 1
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. Ordinary task endpoints belong to TASK_HOME: normally that is
    # FM_HOME, while a compartment child deliberately keeps FM_HOME on the
    # primary money authority and routes its task files and endpoint to the
    # seeded secondmate home. A --secondmate spawn is different: it creates
    # the persistent home itself, so its endpoint belongs to PROJ_ABS. Shadow
    # FM_HOME for only these adapter calls; the cloud monitor launch below
    # still receives the primary FM_HOME so it can read the one controller.
    HERDR_LABEL_HOME=$TASK_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
    fi
    HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$SPAWN_CWD") || exit 1
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
    if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && ! fm_account_test_lab_enabled \
      && ! fm_backend_herdr_server_closed_shell_environment_ready "$HERDR_SES"; then
      echo "error: refusing enforced Agent Fleet routing because Herdr session '$HERDR_SES' was not launched by this adapter's closed environment; stop that idle server and let Firstmate restart it" >&2
      exit 1
    fi
    # Native launch: the pane and the agent are created by one `herdr agent start`
    # call, with the account/GOTMPDIR environment injected natively. The agent argv
    # is a login shell evaluating the very same LAUNCH string every other backend
    # types into its pane, so per-harness launch semantics (env prefixes, model and
    # effort flags, "$(cat <brief>)") stay byte-identical across backends and the
    # Agent Fleet enforced-mode command is preserved verbatim. What goes away is
    # typing that command into a composer and hoping it submits.
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=creating
    persist_worktree_acquisition_phases || exit 1
    FM_BACKEND_HERDR_AGENT_ENV=(${HERDR_AGENT_ENV[@]+"${HERDR_AGENT_ENV[@]}"})
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$SPAWN_CWD" "$HERDR_SEEDED_DEFAULT_TAB_ID" \
      /bin/bash -lc "$LAUNCH") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ENDPOINT_CREATED=1
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=created
    persist_worktree_acquisition_phases || exit 1
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=creating
    persist_worktree_acquisition_phases || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$SPAWN_CWD") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ENDPOINT_CREATED=1
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=created
    persist_worktree_acquisition_phases || exit 1
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=creating
    persist_worktree_acquisition_phases || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$SPAWN_CWD") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ENDPOINT_CREATED=1
    WORKTREE_ACQUIRE_ENDPOINT_PHASE=created
    persist_worktree_acquisition_phases || exit 1
    ;;
  orca)
    if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
      ORCA_WORKTREE_ID=$(fm_meta_get "$RESUME_META" orca_worktree_id)
      [ -n "$ORCA_WORKTREE_ID" ] || {
        echo "error: direct account recovery metadata has no Orca worktree id for $ID" >&2
        exit 1
      }
      ORCA_RECORDED_WORKTREE=$(fm_backend_orca_worktree_path "$ORCA_WORKTREE_ID") || exit 1
      [ "$(real_path_or_raw "$ORCA_RECORDED_WORKTREE")" = "$(real_path_or_raw "$WT")" ] || {
        echo "error: recorded Orca worktree identity no longer matches $WT for $ID" >&2
        exit 1
      }
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
      ORCA_TERMINAL_PROOF=recorded
    else
      ORCA_EXPECTED_TASK="fm-$ID"
      ORCA_TERMINAL_PROOF=unproven
      persist_orca_cleanup_quarantine spawn-preparing || {
        echo "error: cannot durably arm Orca cleanup quarantine for $ID" >&2
        exit 1
      }
      ORCA_ABORT_CLEANUP=1
      set +e
      ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
      ORCA_WT_STATUS=$?
      set -e
      if [ "$ORCA_WT_STATUS" -ne 0 ]; then
        if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
          parse_orca_worktree_result "$ORCA_WT_RAW" || true
          persist_orca_cleanup_quarantine spawn-abort || {
            echo "error: cannot durably record partial Orca create authority for $ID" >&2
          }
        fi
        exit 1
      fi
      parse_orca_worktree_result "$ORCA_WT_RAW" || true
      persist_orca_cleanup_quarantine spawn-abort || {
        echo "error: cannot durably record Orca create authority for $ID" >&2
        exit 1
      }
      if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
        echo "error: orca did not return worktree id and path authority for $W" >&2
        exit 1
      fi
      validate_spawn_worktree "orca worktree create" "$W"
      if [ -z "$ORCA_TERMINAL" ]; then
        ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
        ORCA_TERMINAL_PROOF=recorded
        persist_orca_cleanup_quarantine spawn-abort || {
          echo "error: cannot durably record the Orca terminal authority for $ID" >&2
          exit 1
        }
      fi
      WORKTREE_CREATED=1
    fi
    if [ "$(fm_backend_orca_terminal_state "$ORCA_TERMINAL" "$ORCA_WORKTREE_ID" "$W")" != present ] \
      || ! fm_backend_orca_worktree_terminal_contains "$ORCA_WORKTREE_ID" "$W" "$ORCA_TERMINAL"; then
      echo "error: Orca terminal is not authoritatively bound to worktree $ORCA_WORKTREE_ID and task $W" >&2
      exit 1
    fi
    T="$ORCA_TERMINAL"
    ENDPOINT_CREATED=1
    ;;
esac
if spawn_test_lab_enabled && [ "${FM_TEST_FAIL_AFTER_ENDPOINT:-0}" = 1 ]; then
  echo "error: test-only failure after endpoint creation for $ID" >&2
  exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  persist_failed_account_rollback_short || exit 1
fi
# #134 robustness: only tmux needs a command target distinct from $T - its
# rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend).
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
    zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_literal "$1" "$2" ;;
    cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  esac
}
# Cloud placement helpers. bin/fm-worker-lifecycle.sh reads its own authorities
# (task metadata, controller state, provider inventory) under $FM_HOME/state,
# so every call pins FM_HOME to this spawn's home explicitly.
spawn_cloud_lifecycle() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-worker-lifecycle.sh" "$@"
}
spawn_cloud_assignment_generation() {
  # The assignment is read from the CONTROLLER's document, which lives under
  # the primary's home. On the compartment-child lane $STATE is the
  # secondmate's, and reading it there would silently find no assignment and
  # report the child as durably queued forever.
  python3 - "$PRIMARY_STATE/azure-workers/controller.json" "$ID" "$SPAWN_GENERATION_ID" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
if item.get("status") == "assigned" and item.get("assignment_generation"):
    print(item["assignment_generation"])
PY
}
spawn_cloud_record_assignment() {  # <assignment-generation>
  local assignment=$1 lock
  lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || return 1
  if [ "$(fm_account_meta_value "$STATE/$ID.meta" generation_id)" = "$SPAWN_GENERATION_ID" ] \
    && [ -z "$(fm_account_meta_value "$STATE/$ID.meta" worker_assignment_generation)" ]; then
    printf 'worker_assignment_generation=%s\n' "$assignment" >> "$STATE/$ID.meta" || {
      fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
      return 1
    }
  fi
  fm_account_meta_lock_release "$lock" || return 1
}
# spawn_cloud_bind_leased_account: narrow the staged provider credential to the
# ONE Pi profile the controller leased for this placement (R5).
#
# The controller is the only selector: it picks a free profile under its own
# lock, in the same act that writes the queue entry that IS the lease, and
# prints the single-profile account home it projected (bin/fm-pi-account-home.py
# writes it; nothing here re-derives a home or re-implements a projection).
# This function reads that path back and makes it the credential the worker
# actually receives, so the lease is not a paper lease: without it the pooled
# auth.json would ride to the guest and every concurrent crewmate would resolve
# to the pool's first slot - one account, N workers, which is the collision R5
# exists to remove.
#
# It refuses rather than falling back. No leased path, no credential at the
# leased path, or a leased credential carrying more than one provider slot all
# stop the placement, because each of those is "we do not know which account
# this worker will use".
spawn_cloud_bind_leased_account() {  # <request-stdout-file>
  local out=$1 leased line tmp profile
  if spawn_test_lab_enabled && [ "${FM_TEST_CLOUD_ACCOUNT_BIND_FAIL:-0}" = 1 ]; then
    # Test-only: the lease-handback path below has no other injection point,
    # and an untested handback is how a pool quietly shrinks to zero.
    echo "error: test-only provider-account bind failure for $ID" >&2
    return 1
  fi
  leased=
  profile=
  while IFS= read -r line; do
    case "$line" in
      'account-home /'*) leased=${line#account-home } ;;
      'account-profile '*) profile=${line#account-profile } ;;
    esac
  done < "$out"
  # The controller reports the slot name separately BECAUSE the projected home
  # is keyed on the lease identity rather than the slot name; reading the name
  # off the path's last component would be reading the wrong thing.
  [ -n "$profile" ] || {
    echo "error: the controller named no leased provider-account profile for $ID" >&2
    return 1
  }
  [ -n "$leased" ] || {
    echo "error: the controller named no leased provider-account home for $ID; refusing to stage a pooled credential" >&2
    return 1
  }
  [ -d "$leased" ] && [ -f "$leased/auth.json" ] || {
    echo "error: leased provider-account home '$leased' holds no credential for $ID" >&2
    return 1
  }
  # Azure's hard VM shutdown is six hours after creation. Require twice that
  # much access-token headroom before staging so the guest cannot reach Pi's
  # automatic OAuth refresh path and rotate a refresh token independently of
  # the controller-owned pool. The host refresh scheduler is the sole refresh
  # authority; a stale pool slot is handed back rather than copied to Azure.
  "$SCRIPT_DIR/fm-credential-expiry.py" check --harness pi \
    --margin-seconds "$CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS" \
    --min-state usable "$leased" >/dev/null || {
    echo "error: leased provider-account credential lacks twelve hours of access-token headroom for $ID" >&2
    return 1
  }
  # Exactly one provider slot, checked by shape and never by content: a home
  # carrying more than one is the pool, and the guest would pick the first.
  python3 - "$leased/auth.json" <<'PY' || return 1
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        parsed = json.load(handle)
except (OSError, ValueError):
    print("error: leased provider-account credential is unreadable", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(parsed, dict) or len(parsed) != 1:
    print(
        "error: leased provider-account credential does not hold exactly one provider slot",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
  install -d -m 0700 "$STATE/$ID.cloud-account" || return 1
  tmp=$(mktemp "$STATE/$ID.cloud-account/.auth.XXXXXX") || return 1
  cp "$leased/auth.json" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  # Renamed, not written in place: a crash mid-copy must never leave the staged
  # credential truncated, which would fail the guest's digest check with no
  # clue why.
  mv "$tmp" "$STATE/$ID.cloud-account/auth.json" || { rm -f "$tmp"; return 1; }
  spawn_cloud_record_account_placement "$profile" "$leased" || return 1
  echo "fm-spawn: $ID placed on pi profile $profile ($leased)" >&2
}
spawn_cloud_record_account_placement() {  # <profile> <account-home>
  local profile=$1 leased=$2 lock
  lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || return 1
  if [ "$(fm_account_meta_value "$STATE/$ID.meta" generation_id)" = "$SPAWN_GENERATION_ID" ] \
    && [ -z "$(fm_account_meta_value "$STATE/$ID.meta" worker_account_profile)" ]; then
    {
      printf 'worker_account_profile=%s\n' "$profile"
      printf 'worker_account_home=%s\n' "$leased"
    } >> "$STATE/$ID.meta" || {
      fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
      return 1
    }
  fi
  fm_account_meta_lock_release "$lock" || return 1
}
# spawn_cloud_dispatch: after metadata install, drive the elastic worker
# lifecycle; the local Herdr endpoint holds only the tracking monitor. The
# request is durable; if admission leaves it queued (budget/quota/cost
# evidence), the spawn still succeeds with worker=queued and a later
# `bin/fm-worker-lifecycle.sh reconcile --apply` converges it. Once assigned,
# the crewmate entrypoint (CLOUD_WORKER_LAUNCH, the exact launch string every
# local backend uses) runs on the worker through a detached bounded
# `execute`, whose digest-bound result lands in state/<id>.worker-result.json.
# The exact cloud-lane environment names the far side of the closed pane reads.
# DERIVED, not hand-kept: bin/fm-cloud-env-contract.py is the one owner of that
# set, and tests/fm-spawn-cloud.test.sh asserts the PERSISTED file against it,
# so a name added to a reader without landing here goes red. Regenerate with:
#   bin/fm-cloud-env-contract.py --allowlist
# The readers are bin/fm-worker-lifecycle.py, bin/fm-azure-worker-provider.py,
# AND bin/fm-azure-pilot.sh - the pilot is a SUBPROCESS of the provider
# (run_pilot_create), so the grep of the provider alone that used to regenerate
# this line never saw the twelve names the pilot's own require_cloud_environment
# refuses without. That omission made a compartment child's worker impossible to
# create on any machine, in any configuration, which no hermetic test could see
# because they all drive a fixture provider that never shells out to the pilot.
# Still an explicit literal and not a prefix glob: a secret-bearing FM_AZURE_*
# must never land on disk silently, and the contract records that judgment in
# its SECRET_BEARING_EXCLUSIONS rather than leaving it to a pattern.
SPAWN_CLOUD_ENV_ALLOWLIST='FM_AZURE_ADMIN_EMAIL FM_AZURE_ADMIN_SSH_PUBLIC_KEY FM_AZURE_ADMIN_USERNAME FM_AZURE_BUDGET_START_DATE FM_AZURE_CLEANUP_TIMEOUT_SECONDS FM_AZURE_DEPLOYMENT_GENERATION FM_AZURE_KEY_VAULT_NAME FM_AZURE_MUTATION_STATE_DIR FM_AZURE_NAMING_PREFIX FM_AZURE_OPERATOR_DATA_PLANE_IP FM_AZURE_OWNER_TAG FM_AZURE_PROTECT_DURABLE_STATE FM_AZURE_RESOURCE_GROUP FM_AZURE_RUNNER_OPERATOR_OBJECT_ID FM_AZURE_RUNNER_VALIDATION_SKU FM_AZURE_SECONDMATE_MAX FM_AZURE_STEADY_STATE_BUDGET_TARGET_USD FM_AZURE_STORAGE_NAME FM_AZURE_SUBSCRIPTION_ID FM_AZURE_TENANT_ID FM_AZURE_VM_FAMILY FM_AZURE_WORKER_ADMISSION_HOURS FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST FM_AZURE_WORKER_COMMISSIONING_CEILING_USD FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE FM_AZURE_WORKER_DAILY_BOUND_USD FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS FM_AZURE_WORKER_IDLE_RELEASE_SECONDS FM_AZURE_WORKER_IMAGE_ID FM_AZURE_WORKER_MAX FM_AZURE_WORKER_POLICY_PHASE FM_AZURE_WORKER_SKUS FM_AZURE_WORKER_SLOTS FM_AZURE_WORKER_STATE_DIR FM_AZURE_WORKER_STEADY_TARGET_USD FM_AZURE_WORKER_WARM_IDLE'
spawn_cloud_persist_convergence_artifacts() {
  # A queued request outlives this process, but the entrypoint argv and the
  # FM_AZURE_* identity environment exist only here. Persist both so the
  # tracking monitor can dispatch the execute after a LATER reconcile
  # converges the assignment (the spawn-time reconcile may be refused on
  # transient evidence like a throttled pricing read). Ids and paths only -
  # never secret values (enforced by the allowlist above).
  local var wall
  wall=${FM_SPAWN_CLOUD_WALL_SECONDS:-3600}
  case "$wall" in ''|*[!0-9]*) wall=3600 ;; esac
  if [ "$wall" -lt 1 ] || [ "$wall" -gt 21600 ]; then
    wall=3600
  fi
  (
    umask 077
    # A secondmate compartment has no single persisted entrypoint: leg argvs
    # are built per dispatch by fm-secondmate-cloud-monitor.sh, and leaving a
    # crewmate-shaped entrypoint here could tempt a future converged dispatch
    # into running the wrong thing.
    [ "$KIND" = secondmate ] || printf '%s\n' "$CLOUD_WORKER_LAUNCH" > "$STATE/$ID.cloud-entrypoint" || exit 1
    # Crewmate payload: the repository as a credential-free bundle of the
    # leased worktree's exact HEAD, plus the two task files the entrypoint
    # reads; and the provider-account material the worker stages onto its
    # encrypted account disk. Both directories are digest-manifested into
    # the execute request by the lifecycle, so every staged byte is verified
    # on the guest before the entrypoint runs.
    install -d -m 0700 "$STATE/$ID.cloud-payload" "$STATE/$ID.cloud-account" \
      "$STATE/$ID.cloud-outcome" || exit 1
    # The landing side of the round trip: the leased local worktree this
    # bundle came from is where the crewmate's commits come back to, and the
    # tracking monitor (which outlives the spawn) needs it by path.
    printf '%s\n' "$WT" > "$STATE/$ID.cloud-worktree" || exit 1
    git -C "$WT" bundle create "$STATE/$ID.cloud-payload/repo.bundle" HEAD >/dev/null 2>&1 || {
      echo "error: cloud payload repository bundle failed for $ID" >&2
      exit 1
    }
    if [ -f "$DATA/$ID/brief.md" ]; then
      if [ "$KIND" = secondmate ]; then
        cp "$DATA/$ID/brief.md" "$STATE/$ID.cloud-payload/brief.md" || exit 1
      else
        # The generated brief names the task home's authorized report, visual,
        # and status paths. Those host paths do not exist on a worker. Rewrite
        # only the exact task-home prefix into the fixed return staging root;
        # the guest collector later accepts only the digest-bound task paths,
        # so this does not authorize arbitrary worker files to come home.
        python3 - "$DATA/$ID/brief.md" "$STATE/$ID.cloud-payload/brief.md" "$TASK_HOME" <<'PY' || exit 1
from pathlib import Path
import sys
source, destination, task_home = sys.argv[1:]
body = Path(source).read_bytes()
prefix = task_home.encode()
Path(destination).write_bytes(body.replace(prefix, b"/mnt/task/.fm-return"))
PY
      fi
    elif [ "$KIND" = secondmate ] && [ -f "$WT/data/charter.md" ]; then
      # A secondmate's standing brief is its persistent charter in the home;
      # the compartment payload carries a copy so the cloud agent's brief is
      # the same document the local launch would have read.
      cp "$WT/data/charter.md" "$STATE/$ID.cloud-payload/brief.md" || exit 1
    else
      echo "error: no brief for cloud payload of $ID (looked for $DATA/$ID/brief.md)" >&2
      exit 1
    fi
    if [ "$KIND" = secondmate ]; then
      # The compartment payload additionally ships the session runner and the
      # spawn-intent pi extension; the supervisor stages them (digest-bound)
      # at /mnt/task/.fm-task/ where the monitor's leg argv names them.
      cp "$SCRIPT_DIR/fm-secondmate-session.py" "$STATE/$ID.cloud-payload/fm-secondmate-session.py" || exit 1
      cp "$SCRIPT_DIR/fm-secondmate-spawn.pi-ext.ts" "$STATE/$ID.cloud-payload/fm-secondmate-spawn.pi-ext.ts" || exit 1
    fi
    CLOUD_ACCOUNT_SOURCE=$CLOUD_ACCOUNT_HOME
    if [ ! -f "$CLOUD_ACCOUNT_SOURCE/auth.json" ]; then
      echo "error: cloud account source lacks auth.json at $CLOUD_ACCOUNT_SOURCE" >&2
      exit 1
    fi
    # The POOLED auth.json is deliberately NOT copied here. This runs BEFORE the
    # request creates the lease, and the tracking monitor pane already exists and
    # is already polling: a crash, kill, or plain slow reconcile between here and
    # the narrowing would leave every signed-in account staged in a directory the
    # monitor is willing to dispatch as --account-dir. The account directory is
    # therefore written exactly once, by spawn_cloud_bind_leased_account, after
    # the controller has said which single account this placement leased. That
    # removes the window rather than guarding it.
    # settings.json is pi CONFIGURATION, not credential material, so it is staged
    # here with the rest of the payload.
    if [ -f "$CLOUD_ACCOUNT_SOURCE/settings.json" ]; then
      cp "$CLOUD_ACCOUNT_SOURCE/settings.json" "$STATE/$ID.cloud-account/settings.json" || exit 1
      chmod 0600 "$STATE/$ID.cloud-account/settings.json"
    fi
    {
      printf 'export FM_SPAWN_CLOUD_WALL_SECONDS=%q\n' "$wall"
      [ "$KIND" = secondmate ] \
        || printf 'export FM_SPAWN_CLOUD_RETURN_KIND=%q\n' "$KIND"
      [ -z "${FM_WORKER_PROVIDER_COMMAND:-}" ] \
        || printf 'export FM_WORKER_PROVIDER_COMMAND=%q\n' "$FM_WORKER_PROVIDER_COMMAND"
      if [ "$KIND" = secondmate ]; then
        # Compartment leg configuration is durable per compartment: the
        # monitor pane runs in the Herdr server's closed environment, so the
        # values the spawn ran with must ride the persisted file. Numeric
        # ids only, allowlisted by name - never secret values.
        for var in FM_SECONDMATE_LEG_SECONDS FM_SECONDMATE_POLL_SECONDS \
          FM_SECONDMATE_IDLE_SECONDS FM_SECONDMATE_TTL_HOURS; do
          [ -n "${!var+x}" ] || continue
          case "${!var}" in ''|*[!0-9]*) continue ;; esac
          printf 'export %s=%q\n' "$var" "${!var}"
        done
        # The compartment's child-relay policy knobs. The monitor pane runs in
        # the Herdr server's closed environment, so an operator knob that is
        # not persisted here is unreachable in production no matter what the
        # docs say. Bare names only (a project directory name), never a path
        # and never a secret.
        if [ -n "${FM_SECONDMATE_CHILD_PROJECT:-}" ]; then
          case "$FM_SECONDMATE_CHILD_PROJECT" in
            *[!A-Za-z0-9._-]*) : ;;
            *) printf 'export FM_SECONDMATE_CHILD_PROJECT=%q\n' "$FM_SECONDMATE_CHILD_PROJECT" ;;
          esac
        fi
      fi
      for var in $SPAWN_CLOUD_ENV_ALLOWLIST; do
        [ -n "${!var+x}" ] || continue
        printf 'export %s=%q\n' "$var" "${!var}"
      done
    } > "$STATE/$ID.cloud-env"
  ) || return 1
}
spawn_cloud_claim_execute_dispatch() {
  # Exactly-once execute dispatch, shared with the tracking monitor: whichever
  # owner creates the marker first (O_EXCL) dispatches; the other stands down.
  (set -C; : > "$STATE/$ID.cloud-execute-dispatched") 2>/dev/null
}
spawn_cloud_dispatch() {
  local owner_kind=primary assignment wall role_args parent_args task_home_args request_report
  CLOUD_PLACEMENT_STATE=queued
  # owner_kind is a property of the home the TASK belongs to, not of the home
  # that owns the money document. They are the same directory everywhere
  # except the compartment-child lane, where the request is minted by the
  # primary on behalf of a secondmate and must still say owner_kind=secondmate.
  [ ! -f "$TASK_HOME/$SUB_HOME_MARKER" ] || owner_kind=secondmate
  spawn_cloud_persist_convergence_artifacts || {
    echo "error: cloud worker convergence artifacts could not be persisted for $ID" >&2
    return 1
  }
  role_args=()
  # A --secondmate spawn on the cloud lane queues a COMPARTMENT: role=
  # secondmate on an ordinary author slot (R2/R3 B.1). The controller's
  # verify_request owns the depth-1 bound (role=secondmate requires
  # owner_kind=primary), so a secondmate home requesting a compartment is
  # refused there, loudly. Crewmate requests keep their exact pre-flag argv.
  [ "$KIND" != secondmate ] || role_args=(--role secondmate)
  # Compartment-child passthrough (R2/R3 B.5 step 3, AMENDMENT 1). The
  # secondmate compartment's monitor is the only caller that sets these, and
  # it always sets BOTH: the pair is what marks a request as a compartment
  # child, so a child cannot dodge the controller's fan-out, lifetime,
  # parent-liveness and depth bounds. Absent (every other spawn, including a
  # LOCAL secondmate home requesting its own crewmates) the argv is unchanged
  # and the documented parent-less lane stays byte-identical. A half-set pair
  # is forwarded as-is so verify_request refuses it loudly rather than being
  # quietly dropped here.
  parent_args=()
  if [ -n "${FM_SPAWN_PARENT_TASK:-}" ] || [ -n "${FM_SPAWN_PARENT_TASK_GENERATION:-}" ]; then
    parent_args=(--parent-task "${FM_SPAWN_PARENT_TASK:-}"
      --parent-task-generation "${FM_SPAWN_PARENT_TASK_GENERATION:-}")
  fi
  # The task home travels with the request ONLY when it differs from the
  # controller's home, so every ordinary spawn keeps its exact pre-flag argv.
  # The controller refuses --task-home outside a complete parent pair with
  # --role author and --owner-kind secondmate, and then authorizes the
  # directory against the marker plus the primary's own registry.
  task_home_args=()
  [ "$TASK_HOME" = "$FM_HOME" ] || task_home_args=(--task-home "$TASK_HOME")
  # The request's STDOUT carries the leased provider-account home (R5), so it is
  # captured rather than folded into stderr; stderr still flows through
  # untouched, and the captured lines are echoed on for the operator either way.
  request_report="$STATE/$ID.worker-request.out"
  rm -f "$request_report"
  spawn_cloud_lifecycle request \
    --task "$ID" --task-generation "$SPAWN_GENERATION_ID" \
    --owner-kind "$owner_kind" ${role_args[@]+"${role_args[@]}"} \
    ${parent_args[@]+"${parent_args[@]}"} \
    ${task_home_args[@]+"${task_home_args[@]}"} --eligible > "$request_report" || {
    cat "$request_report" >&2 2>/dev/null || true
    rm -f "$request_report"
    # No durable queue entry exists, so the convergence artifacts have no
    # owner; remove them (including the copied provider credential) with the
    # rolled-back spawn. $STATE is the directory this spawn just staged into,
    # which on the compartment-child lane is the secondmate's and not the
    # primary's, so the rollback needs no resolution of its own.
    fm_cloud_state_remove_generation "$STATE" "$ID"
  # The outcome directory is NOT transport. When the monitor cannot
  # fast-forward it tells the operator the bundle is "kept for manual
  # landing", and by then the guest copy is usually gone with the VM, so a
  # re-spawn deleting it would destroy the last copy of the crewmate's
  # commits. Preserve any bundle under a superseded name instead, and say so.
  if [ -s "$STATE/$ID.cloud-outcome/outcome.bundle" ]; then
    superseded="$STATE/$ID.cloud-outcome.superseded-$(date -u +%Y%m%d%H%M%S)"
    if mv "$STATE/$ID.cloud-outcome" "$superseded" 2>/dev/null; then
      echo "notice: $ID had an unlanded outcome bundle; preserved at $superseded/outcome.bundle" >&2
    fi
  fi
  rm -rf "$STATE/$ID.cloud-outcome"
    echo "error: cloud worker request was refused for $ID" >&2
    return 1
  }
  cat "$request_report" >&2
  if spawn_test_lab_enabled && [ "${FM_TEST_CLOUD_ABORT_AFTER_REQUEST:-0}" = 1 ]; then
    # Test-only: die exactly in the window between the durable lease and the
    # narrowing, with the tracking monitor already live. This is the window the
    # pool used to be staged in, and the only way to assert it is empty is to
    # stop the process inside it.
    kill -9 $$
  fi
  spawn_cloud_bind_leased_account "$request_report" || {
    # The queue entry exists and is the LEASE on a provider account. A spawn
    # that cannot bind that account must hand it back rather than leave it held
    # by work that will never run: an orphaned lease shrinks the pool by one
    # every time this happens. The entry is still `queued` here (reconcile has
    # not run), which is exactly what withdraw accepts, and withdraw also
    # removes the staged credential.
    if spawn_cloud_lifecycle withdraw --task "$ID" \
      --task-generation "$SPAWN_GENERATION_ID" --confirm-withdraw \
      --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" >&2; then
      echo "notice: released the provider-account lease for $ID with its withdrawn request" >&2
    else
      echo "error: the provider-account lease for $ID is still held by its queued request; withdraw it with bin/fm-worker-lifecycle.sh withdraw --task $ID --task-generation $SPAWN_GENERATION_ID" >&2
    fi
    echo "error: cloud placement for $ID could not be bound to its leased provider account" >&2
    return 1
  }
  if ! spawn_cloud_lifecycle reconcile --apply \
    --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" --json \
    > "$STATE/$ID.worker-reconcile.json" 2>&1; then
    echo "notice: cloud worker for $ID stays durably queued; reconcile refused (see $STATE/$ID.worker-reconcile.json)" >&2
    return 0
  fi
  assignment=$(spawn_cloud_assignment_generation) || assignment=
  if [ -z "$assignment" ]; then
    echo "notice: cloud worker for $ID stays durably queued awaiting admission; re-run bin/fm-worker-lifecycle.sh reconcile --apply" >&2
    return 0
  fi
  spawn_cloud_record_assignment "$assignment" || {
    echo "error: cloud worker assignment for $ID could not be recorded in task metadata" >&2
    return 1
  }
  CLOUD_PLACEMENT_STATE=assigned
  if [ "$KIND" = secondmate ]; then
    # The compartment monitor owns EVERY leg dispatch (O_EXCL per-leg
    # markers); the spawn never runs an execute for a compartment, so there
    # is no shared dispatch marker to claim here.
    echo "notice: secondmate compartment $ID is assigned; fm-secondmate-cloud-monitor dispatches its session legs" >&2
    return 0
  fi
  wall=${FM_SPAWN_CLOUD_WALL_SECONDS:-3600}
  case "$wall" in ''|*[!0-9]*) echo "error: invalid FM_SPAWN_CLOUD_WALL_SECONDS '$wall'" >&2; return 1 ;; esac
  spawn_cloud_claim_execute_dispatch || {
    echo "notice: cloud execute for $ID already claimed by the tracking monitor" >&2
    CLOUD_PLACEMENT_STATE=executing
    return 0
  }
  nohup env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-worker-lifecycle.sh" execute \
    --task "$ID" --task-generation "$SPAWN_GENERATION_ID" \
    --assignment-generation "$assignment" --wall-seconds "$wall" \
    --payload-dir "$STATE/$ID.cloud-payload" --account-dir "$STATE/$ID.cloud-account" \
    --outcome-dir "$STATE/$ID.cloud-outcome" --return-kind "$KIND" \
    --confirm-execute --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" \
    -- /bin/bash -lc "$CLOUD_WORKER_LAUNCH" \
    > "$STATE/$ID.worker-result.json" 2> "$STATE/$ID.worker-execute.log" < /dev/null &
  disown $! 2>/dev/null || true
  CLOUD_PLACEMENT_STATE=executing
}
if [ "$SPAWN_CLOUD" != azure ] && [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$RECOVERY_ACCOUNT" != 1 ]; then
  WT_REAL=$(real_path_or_raw "$WT")
  ENDPOINT_READY_STARTED=$(date +%s)
  ENDPOINT_READY_TIMEOUT=60
  while :; do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" = "$WT_REAL" ]; then
      break
    fi
    ENDPOINT_READY_NOW=$(date +%s)
    [ $((ENDPOINT_READY_NOW - ENDPOINT_READY_STARTED)) -lt "$ENDPOINT_READY_TIMEOUT" ] || break
    sleep 1
  done
  if [ -z "${p:-}" ] || [ "$(real_path_or_raw "$p")" != "$WT_REAL" ]; then
    echo "error: task endpoint did not start in leased worktree $WT within ${ENDPOINT_READY_TIMEOUT}s; inspect window $T" >&2
    exit 1
  fi
fi
if [ -z "$WT" ] && [ "$BACKEND" = orca ]; then
  WT="$PROJ_ABS"
fi


if [ "$BACKEND" != herdr ]; then
  prepare_launch_environment
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
# Cloud placement persists the exact identities the elastic worker lifecycle
# derives its bindings from (docs/azure-workers.md "Queue request"): the
# physical worktree Git-dir identity and the provider account home. The cloud
# lane is pi-codex only, so the account home is the dedicated Azure worker Pi
# pool when configured, otherwise the legacy pi coding-agent directory - never
# a claude/codex profile home, and never a local account-directory rotation
# (that machinery is bypassed entirely for cloud).
if [ "$SPAWN_CLOUD" = azure ]; then
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || {
    echo "error: cloud placement must not reach direct account-directory routing; refusing to mix profile machinery into the worker lane" >&2
    exit 1
  }
  if [ -z "${WORKTREE_GIT_DIR:-}" ] || [ -z "${WORKTREE_GIT_DIR_IDENTITY:-}" ]; then
    capture_worktree_git_physical_identity "$WT" || {
      echo "error: cannot record exact worktree Git-dir identity for cloud placement of $ID" >&2
      exit 1
    }
  fi
  [ -d "$CLOUD_ACCOUNT_HOME" ] || {
    echo "error: cloud placement account home '$CLOUD_ACCOUNT_HOME' is not a directory" >&2
    exit 1
  }
fi
lifecycle_lock_valid=0
if [ -n "$LIFECYCLE_LOCK" ]; then
  if [ "$LIFECYCLE_LOCK_OWNED" = 1 ]; then
    fm_account_lifecycle_lock_owned "$LIFECYCLE_LOCK" && lifecycle_lock_valid=1
  elif [ "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:-}" = "$LIFECYCLE_LOCK" ]; then
    current_lock_identity=$(fm_account_lifecycle_lock_identity "$LIFECYCLE_LOCK" 2>/dev/null || true)
    case "$current_lock_identity" in
      *$'\n'*)
        current_lock_pid=${current_lock_identity%%$'\n'*}
        current_lock_start=${current_lock_identity#*$'\n'}
        if [ "$current_lock_pid" = "$LIFECYCLE_LOCK_INHERITED_PID" ] \
          && [ "$current_lock_start" = "$LIFECYCLE_LOCK_INHERITED_START" ]; then
          lifecycle_lock_valid=1
        fi
        ;;
    esac
  fi
fi
if [ "$lifecycle_lock_valid" != 1 ]; then
  echo "error: managed lifecycle lock was lost before metadata install for $ID" >&2
  exit 1
fi
META_WRITE_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  direct_recovery_context_matches || {
    echo "error: direct account task generation changed before metadata install for $ID" >&2
    exit 1
  }
elif [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  if [ ! -f "$STATE/$ID.meta" ] || [ "$(fm_meta_get "$STATE/$ID.meta" account_task)" != "$ACCOUNT_TASK" ]; then
    echo "error: managed task generation changed before metadata install for $ID" >&2
    exit 1
  fi
fi
META_TMP=$(mktemp "$STATE/.$ID.meta.XXXXXX") || exit 1
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || echo "worktree_git_dir=$WORKTREE_GIT_DIR"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || echo "worktree_git_dir_identity=$WORKTREE_GIT_DIR_IDENTITY"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || [ -z "$WORKTREE_GIT_REF" ] || echo "worktree_git_ref=$WORKTREE_GIT_REF"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || [ -z "$WORKTREE_GIT_HEAD" ] || echo "worktree_git_head=$WORKTREE_GIT_HEAD"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || [ -z "$WORKTREE_GIT_SETUP_REF" ] || echo "worktree_git_setup_ref=$WORKTREE_GIT_SETUP_REF"
  [ "$DIRECT_ACCOUNT_ROUTING" != 1 ] || [ -z "$WORKTREE_GIT_SETUP_HEAD" ] || echo "worktree_git_setup_head=$WORKTREE_GIT_SETUP_HEAD"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "tasktmp_phase=$WORKTREE_ACQUIRE_TASKTMP_PHASE"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  echo "generation_id=$SPAWN_GENERATION_ID"
  [ -z "${PROVISION_SUMMARY:-}" ] || echo "provision=$PROVISION_SUMMARY"
  [ "$NO_ACCOUNT_ROUTING" != 1 ] || echo "account_routing_emergency_bypass=1"
  [ -z "$BACKLOG_ROW_EXEMPTION" ] || echo "backlog_row_exemption=$BACKLOG_ROW_EXEMPTION"
  [ -z "$DIRECT_ACCOUNT_HOME" ] || echo "account_home=$DIRECT_ACCOUNT_HOME"
  if [ "$SPAWN_CLOUD" = azure ]; then
    # Direct account routing was refused above for cloud spawns, so these keys
    # are written exactly once and account_home is always the pi-codex home.
    echo "placement=azure"
    echo "worktree_git_dir=$WORKTREE_GIT_DIR"
    echo "worktree_git_dir_identity=$WORKTREE_GIT_DIR_IDENTITY"
    echo "account_home=$CLOUD_ACCOUNT_HOME"
  fi
  [ "$DIRECT_ACCOUNT_DEGRADED" != 1 ] || echo "account_routing_degraded=1"
  if [ "$RECOVERY_ACCOUNT" = 1 ]; then
    if grep -q '^report_required=' "$RESUME_META"; then
      RECORDED_REPORT_REQUIRED=$(fm_account_meta_value "$RESUME_META" report_required)
      echo "report_required=$RECORDED_REPORT_REQUIRED"
    fi
  elif [ "$EXISTING_META" = 1 ]; then
    [ "$EXISTING_REPORT_REQUIRED_SET" = 0 ] || echo "report_required=$EXISTING_REPORT_REQUIRED"
  else
    # Every NEW task is report-required; new report-required Orca spawns were
    # already refused before any owned mutation (the backend=orca gate after
    # task-id resolution above).
    echo "report_required=1"
  fi
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
    echo "account_pool=$ACCOUNT_POOL"
    echo "account_profile=$ACCOUNT_PROFILE"
    echo "account_task=$ACCOUNT_TASK"
    echo "account_attempt=$ACCOUNT_ATTEMPT"
    [ -z "$ACCOUNT_PREDECESSOR_TASK" ] || echo "account_predecessor_task=$ACCOUNT_PREDECESSOR_TASK"
    [ -z "$ACCOUNT_PREDECESSOR_ATTEMPT" ] || echo "account_predecessor_attempt=$ACCOUNT_PREDECESSOR_ATTEMPT"
    [ -z "$ACCOUNT_PREDECESSOR_PROVIDER" ] || echo "account_predecessor_provider=$ACCOUNT_PREDECESSOR_PROVIDER"
    [ -z "$ACCOUNT_PREDECESSOR_PROFILE" ] || echo "account_predecessor_profile=$ACCOUNT_PREDECESSOR_PROFILE"
    [ -z "$ACCOUNT_PREDECESSOR_POOL" ] || echo "account_predecessor_pool=$ACCOUNT_PREDECESSOR_POOL"
    [ -z "$ACCOUNT_PREDECESSOR_SESSION" ] || echo "account_predecessor_session=$ACCOUNT_PREDECESSOR_SESSION"
    [ "$CONTINUE_ACCOUNT" != 1 ] || echo "account_predecessor_cleanup=pending"
    [ -z "$CONTINUATION_PACKET" ] || echo "continuation_packet=$CONTINUATION_PACKET"
    if [ "$RESUME_ACCOUNT" = 1 ]; then
      echo "provider_session_id=$RECORDED_SESSION"
    fi
    echo "account_rollback_cleanup=pending"
    rollback_backup_name=$(fm_account_meta_value "$STATE/$ID.meta" account_rollback_backup)
    rollback_artifacts_name=$(fm_account_meta_value "$STATE/$ID.meta" account_rollback_artifacts)
    rollback_preserve_session=$(fm_account_meta_value "$STATE/$ID.meta" account_rollback_preserve_session)
    [ -z "$rollback_backup_name" ] || echo "account_rollback_backup=$rollback_backup_name"
    [ -z "$rollback_artifacts_name" ] || echo "account_rollback_artifacts=$rollback_artifacts_name"
    [ -z "$rollback_preserve_session" ] || echo "account_rollback_preserve_session=$rollback_preserve_session"
  fi
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && [ "$BACKEND" = tmux ]; then
    echo "tmux_window_id=$WID"
    echo "tmux_session_target=$META_WINDOW"
  fi
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
    echo "orca_repo_id=$ORCA_REPO_ID"
    echo "orca_expected_task=$ORCA_EXPECTED_TASK"
    echo "orca_discovery_label=$ORCA_EXPECTED_TASK"
    echo "orca_provider_scope=repo-path:$PROJ_ABS"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$META_TMP"
if [ -f "$STATE/$ID.meta" ]; then
  # Preserve every extension field not owned by this spawn rewrite (PR/X-mode
  # pointers and future additive metadata) while replacing endpoint identity.
  PRESERVE_META_SOURCE="$STATE/$ID.meta"
  fm_account_meta_merge_extensions "$PRESERVE_META_SOURCE" "$META_TMP" || exit 1
fi
fm_account_safe_file_destination "$STATE/$ID.meta" || { echo "error: unsafe task metadata destination at $STATE/$ID.meta" >&2; exit 1; }
mv "$META_TMP" "$STATE/$ID.meta"
META_INSTALLED=1
clear_worktree_acquisition_record
[ -z "$META_WRITE_LOCK" ] || fm_account_meta_lock_release "$META_WRITE_LOCK"
META_WRITE_LOCK=
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

if [ "$BACKEND" != herdr ]; then
  build_launch_command
fi
# Export the crewmate PATH and GOTMPDIR into the crewmate's pane shell so the agent and
# every child process (go build, go test, ...) inherit them. Sent before the launch
# command so the env is set when the agent starts; the brief sleep lets it land.
if [ "$BACKEND" = orca ]; then
  if [ "$(fm_backend_orca_terminal_state "$T" "$ORCA_WORKTREE_ID" "$W")" != present ] \
    || ! fm_backend_orca_worktree_terminal_contains "$ORCA_WORKTREE_ID" "$W" "$T"; then
    echo "error: Orca terminal authority changed before launch for $ID" >&2
    exit 1
  fi
  validate_orca_abort_worktree_identity || {
    echo "error: Orca worktree authority changed before launch for $ID" >&2
    exit 1
  }
fi
# herdr already launched the agent natively during endpoint creation, with the
# same LAUNCH string as its argv and PATH/GOTMPDIR injected via --env, so there is
# nothing to type into a pane here.
if [ "$SPAWN_CLOUD" = azure ]; then
  spawn_cloud_dispatch || exit 1
elif [ "$BACKEND" != herdr ]; then
  spawn_send_text_line "$T" "export PATH='$CREW_PATH' GOTMPDIR=$TASK_TMP/gotmp"
  sleep 0.3
  spawn_send_literal "$T" "$LAUNCH"
  sleep 0.3
  spawn_send_key "$T" Enter
fi

if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
  session_sync_args=("$ID" --wait "${FM_ACCOUNT_SESSION_WAIT_SECONDS:-10}" --require)
  if [ "$RESUME_ACCOUNT" = 1 ]; then
    native_ready_wait=${FM_ACCOUNT_NATIVE_READY_WAIT_SECONDS:-5}
    case "$native_ready_wait" in ''|*[!0-9]*) echo "error: invalid native launch ready wait '$native_ready_wait'" >&2; exit 1 ;; esac
    native_ready_deadline=$(( $(date +%s) + native_ready_wait ))
    while [ ! -f "$ACCOUNT_NATIVE_LAUNCH_READY" ]; do
      [ "$(date +%s)" -lt "$native_ready_deadline" ] || {
        echo "error: native provider wrapper for $ID did not reach its launch gate" >&2
        exit 1
      }
      sleep 0.05
    done
    RECORDED_SESSION_EVENT_SEQ=$(FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$LIFECYCLE_LOCK" "$SCRIPT_DIR/fm-account-session-sync.sh" "$ID" --require --event-seq) || exit 1
    ( set -C; : > "$ACCOUNT_NATIVE_LAUNCH_GO" ) || exit 1
    session_sync_args+=(--after-event-seq "$RECORDED_SESSION_EVENT_SEQ")
  fi
  if ! FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$LIFECYCLE_LOCK" "$SCRIPT_DIR/fm-account-session-sync.sh" "${session_sync_args[@]}" >/dev/null; then
    echo "error: managed provider launch for $ID did not bind a fresh SessionStart mapping" >&2
    exit 1
  fi
  [ -z "$ACCOUNT_NATIVE_LAUNCH_DIR" ] || rm -rf "$ACCOUNT_NATIVE_LAUNCH_DIR" || exit 1
  ACCOUNT_NATIVE_LAUNCH_DIR=
  ACCOUNT_NATIVE_LAUNCH_GO=
  ACCOUNT_NATIVE_LAUNCH_READY=
  ACCOUNT_NATIVE_LAUNCH_SCRIPT=
  COMMIT_ENDPOINT_STATE=$(spawn_managed_endpoint_state "$BACKEND" "$T" "fm-$ID" "$KIND" "$PROJ_ABS" "$META_WINDOW" 2>/dev/null)
  case "$COMMIT_ENDPOINT_STATE" in
    present) ;;
    absent) echo "error: managed endpoint disappeared before launch commit for $ID" >&2; exit 1 ;;
    *) echo "error: managed endpoint state is unknown before launch commit for $ID" >&2; exit 1 ;;
  esac
  META_WRITE_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  if [ ! -f "$STATE/$ID.meta" ] || [ "$(fm_meta_get "$STATE/$ID.meta" account_task)" != "$ACCOUNT_TASK" ]; then
    echo "error: managed task generation changed before launch commit for $ID" >&2
    exit 1
  fi
  clear_account_rollback_markers || { echo "error: failed to commit managed rollback metadata for $ID" >&2; exit 1; }
  fm_account_meta_lock_release "$META_WRITE_LOCK" || exit 1
  META_WRITE_LOCK=
  ACCOUNT_SPAWN_COMMITTED=1
  [ -z "$META_BACKUP" ] || rm -f "$META_BACKUP"
  META_BACKUP=
  discard_existing_artifact_backup
  if [ "$CONTINUE_ACCOUNT" = 1 ]; then
    if ! fm_account_cleanup_predecessor_serialized "$STATE/$ID.meta" "$DATA" "$ID"; then
      echo "error: predecessor Agent Fleet cleanup remains pending for $ID" >&2
      exit 1
    fi
  fi
fi
[ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] || ACCOUNT_SPAWN_COMMITTED=1
if [ -n "$EXISTING_TASK_TMP" ] && [ "$EXISTING_TASK_TMP" != "$TASK_TMP" ]; then
  META_WRITE_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  if [ "$(fm_account_meta_value "$STATE/$ID.meta" generation_id)" != "$SPAWN_GENERATION_ID" ] \
    || [ "$(fm_account_meta_value "$STATE/$ID.meta" tasktmp)" != "$TASK_TMP" ]; then
    echo "error: task generation changed before prior temp cleanup for $ID" >&2
    exit 1
  fi
  fm_account_safe_remove_task_tmp "$ID" "$EXISTING_TASK_TMP" "$EXISTING_TASK_GENERATION" || exit 1
  fm_account_meta_lock_release "$META_WRITE_LOCK" || exit 1
  META_WRITE_LOCK=
fi
CONTINUATION_LAUNCH_DIR=
CONTINUATION_PROMPT_FILE=
[ -z "$META_BACKUP" ] || rm -f "$META_BACKUP"
META_BACKUP=
discard_existing_artifact_backup
[ "$LIFECYCLE_LOCK_OWNED" != 1 ] || [ -z "$LIFECYCLE_LOCK" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" || exit 1
if [ -n "$TASK_HOME_LIFECYCLE_LOCK" ]; then
  fm_account_lifecycle_lock_release "$TASK_HOME_LIFECYCLE_LOCK" || exit 1
  TASK_HOME_LIFECYCLE_LOCK=
fi
if [ -n "$SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK" ]; then
  fm_account_lifecycle_lock_release "$SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK" || exit 1
  SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK=
fi
[ -z "$SECONDMATE_HOME_LIFECYCLE_LOCK" ] || fm_account_lifecycle_lock_release "$SECONDMATE_HOME_LIFECYCLE_LOCK" || exit 1
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_OWNED=0
SECONDMATE_HOME_LIFECYCLE_LOCK=

account_summary=
[ -z "$DIRECT_ACCOUNT_HOME" ] || account_summary=" account_home=$DIRECT_ACCOUNT_HOME"
cloud_summary=
[ "$SPAWN_CLOUD" != azure ] || cloud_summary=" placement=azure worker=${CLOUD_PLACEMENT_STATE:-queued}"
echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT$account_summary$cloud_summary"
