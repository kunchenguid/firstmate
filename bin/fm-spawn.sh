#!/usr/bin/env bash
# FM_ACCOUNT_DIRECTORY_CUTOVER: direct-observe-passwd-home-v2
# Spawn a direct report: a new crewmate in a treehouse worktree, an eligible
# pre-cutover Orca direct recovery with empirically verified provider authority,
# or a secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--account-pool <pool>] [--account-profile <profile>] [--no-account-routing] [--scout]
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
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
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
#   secondmate's own crewmates use inherited crew dispatch/routing policy, not
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
#   Before a secondmate launch, the home must fast-forward safely to the primary
#   default-branch commit and independently match the live default tip.
#   Any unproven freshness state refuses launch.
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
#   source of truth; shared --scout/--harness/--model/--effort/--backend/account flags apply to every pair.
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
  sed -n '2,78p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CHECKOUT_STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
CHECKOUT_LOCK_ROOT=$(fm_checkout_lock_root "$CHECKOUT_STATE_BASE")
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-report-contract-lib.sh
. "$SCRIPT_DIR/fm-report-contract-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

spawn_managed_endpoint_kill() {  # <backend> <target> <tab-id> <label> <kind> <secondmate-home> [recorded-scoped-target]
  local backend=$1 target=$2 tab_id=$3 label=$4 kind=$5 secondmate_home=${6:-} recorded_scoped_target=${7:-} endpoint_home
  endpoint_home=$(fm_backend_endpoint_home "$backend" "$kind" "$FM_HOME" "$secondmate_home")
  if [ "$endpoint_home" != "$FM_HOME" ]; then
    ( unset FM_ROOT_OVERRIDE; FM_HOME="$endpoint_home" FM_ROOT="$endpoint_home" fm_backend_kill "$backend" "$target" "$tab_id" "$label" "$recorded_scoped_target" )
  else
    fm_backend_kill "$backend" "$target" "$tab_id" "$label" "$recorded_scoped_target"
  fi
}

spawn_managed_endpoint_state() {  # <backend> <target> <label> <kind> <secondmate-home> [recorded-scoped-target]
  local backend=$1 target=$2 label=$3 kind=$4 secondmate_home=${5:-} recorded_scoped_target=${6:-} endpoint_home
  endpoint_home=$(fm_backend_endpoint_home "$backend" "$kind" "$FM_HOME" "$secondmate_home")
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

direct_worktree_return_confirmed() {
  local project=$1 worktree=$2 listed
  [ ! -e "$worktree" ] && [ ! -L "$worktree" ] && return 0
  listed=$(git_repository_probe -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  ! printf '%s\n' "$listed" | grep -Fqx "worktree $worktree"
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
    || [ "$NO_ACCOUNT_ROUTING" = 1 ]; then
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
RESUME_META=
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_OWNED=0
SECONDMATE_HOME_LIFECYCLE_LOCK=
SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK=
LIFECYCLE_LOCK_INHERITED_PID=
LIFECYCLE_LOCK_INHERITED_START=
SPAWN_META_PRESENT=0
SPAWN_META_SNAPSHOT=
SPAWN_PREFLIGHT_ID=${POS[0]:-}
spawn_idpart=${SPAWN_PREFLIGHT_ID%%=*}
SPAWN_PREFLIGHT_BATCH=0

release_secondmate_home_lifecycle_locks() {
  [ -z "${SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK:-}" ] \
    || fm_account_lifecycle_lock_release "$SECONDMATE_TARGET_HOME_LIFECYCLE_LOCK" >/dev/null 2>&1 || true
  [ -z "${SECONDMATE_HOME_LIFECYCLE_LOCK:-}" ] \
    || fm_account_lifecycle_lock_release "$SECONDMATE_HOME_LIFECYCLE_LOCK" >/dev/null 2>&1 || true
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
  if [ "$tasktmp" != "/tmp/fm-$task" ] || [ -z "$generation" ] || [ -z "$target" ]; then
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
  if ! fm_account_restore_artifacts "$STATE" "$task" "$artifacts_name" "$tasktmp" 1; then
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

if [ "$BACKEND_SET" -eq 1 ]; then
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
    rollback_backup=$(fm_account_meta_value "$RESUME_META" account_rollback_backup)
    fm_account_meta_lock_release "$rollback_meta_lock" || exit 1
    rollback_meta_lock=
    if [ -n "$rollback_tasktmp" ] && [ "$rollback_tasktmp" != "/tmp/fm-$rollback_id" ]; then
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
      [ -z "$rollback_tasktmp" ] || rm -rf "$rollback_tasktmp"
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
ORCA_PROVIDER_TASK=
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
WORKTREE_CREATED=0
WORKTREE_RETAIN_ON_ABORT=0
WORKTREE_EXPECTED_TIP=
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
DIRECT_ACCOUNT_HOME=
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
ORIGINAL_TASK_TMP_PRESENT=-1

snapshot_existing_artifacts() {
  local backup name source tasktmp="/tmp/fm-$ID"
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
  ORCA_PROVIDER_TASK=
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
    echo "tasktmp=${TASK_TMP:-${RECORDED_TASKTMP:-/tmp/fm-$ID}}"
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

persist_failed_direct_spawn() {
  local meta="$STATE/$ID.meta" tmp retained_window retained_tmux_session retained_mode retained_yolo backup_name artifacts_name preserve_extensions=0
  retained_window=${META_WINDOW:-${T:-${W:-fm-$ID}}}
  retained_tmux_session=
  retained_mode=${MODE:-}
  retained_yolo=${YOLO:-off}
  [ -n "$retained_mode" ] || retained_mode=no-mistakes
  if [ "${BACKEND:-tmux}" = tmux ]; then
    retained_tmux_session=${META_WINDOW:-${SES:-firstmate}:${W:-fm-$ID}}
    retained_window=$retained_tmux_session
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
    awk '!/^direct_spawn_cleanup=/ && !/^direct_spawn_backup=/ && !/^direct_spawn_artifacts=/ && !/^rollback_pending=/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
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
      echo "tasktmp=${TASK_TMP:-/tmp/fm-$ID}"
      echo "model=${MODEL:-default}"
      echo "effort=${EFFORT:-default}"
      echo "generation_id=${SPAWN_GENERATION_ID:-}"
      echo "report_required=1"
      [ -z "${DIRECT_ACCOUNT_HOME:-}" ] || echo "account_home=$DIRECT_ACCOUNT_HOME"
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
      [ "${BACKEND:-tmux}" != cmux ] || {
        echo "cmux_workspace_id=${CMUX_WORKSPACE_ID:-}"
        echo "cmux_surface_id=${CMUX_SURFACE_ID:-}"
      }
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if [ "$preserve_extensions" = 1 ]; then
    fm_account_meta_merge_extensions "$meta" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
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

spawn_return_created_worktree() {
  local return_output return_status
  [ "$WORKTREE_CREATED" = 1 ] || return 0
  [ "${BACKEND:-tmux}" != orca ] || return 0
  [ -n "${WT:-}" ] && [ -d "$WT" ] || return 0
  if [ "$WORKTREE_RETAIN_ON_ABORT" = 1 ]; then
    echo "warning: retained unsafe acquired worktree $WT for manual recovery" >&2
    return 1
  fi
  if [ -z "$WORKTREE_EXPECTED_TIP" ] \
    || ! "$SCRIPT_DIR/fm-checkout-refresh.sh" verify-returnable "$WT" "$PROJ_ABS" "$WORKTREE_EXPECTED_TIP"; then
    echo "warning: retained acquired worktree $WT because repository identity and its expected detached tip could not be re-proven" >&2
    return 1
  fi
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
  if ! "$SCRIPT_DIR/fm-checkout-refresh.sh" verify-returnable "$WT" "$PROJ_ABS" "$WORKTREE_EXPECTED_TIP"; then
    echo "warning: retained acquired worktree $WT because post-cleanup repository safety could not be re-proven" >&2
    return 1
  fi
  if return_output=$(fm_checkout_treehouse_return "$WT" "$CHECKOUT_LOCK_ROOT" "$PROJ_ABS" 2>&1); then
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
    fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "/tmp/fm-$ID" 1 || return 1
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
  local status=$? endpoint_state endpoint_gone=1 account_clean=1 state_clean=1 worktree_clean=1 rollback_lock='' rollback_tmp restored_existing_meta=0 artifact_backup_name release_status orca_cleanup_failed=0
  trap - EXIT
  # This is an EXIT trap whose job is to attempt every independent cleanup
  # action and then return the original spawn status. The parent script runs
  # with `set -e`; without disabling errexit here, a benign nonzero probe can
  # stop the trap after endpoint removal but before lease/session/worktree
  # rollback, leaking prepared resources.
  set +e
  [ -z "${META_TMP:-}" ] || rm -f "$META_TMP"
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
      fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" || orca_cleanup_failed=1
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
    && { [ "${ACCOUNT_EFFECTIVE_MODE:-off}" = enforce ] || [ "${DIRECT_ACCOUNT_ROUTING:-0}" = 1 ]; } \
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
    && [ "${ACCOUNT_EFFECTIVE_MODE:-off}" != enforce ]; then
    spawn_restore_unmanaged_state "$rollback_lock" || state_clean=0
    if [ "$state_clean" = 1 ]; then
      spawn_return_created_worktree || worktree_clean=0
    else
      worktree_clean=0
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
      persist_failed_direct_spawn || echo "warning: failed to persist retained direct spawn state for ${ID:-unknown}" >&2
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
      if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-/tmp/fm-$ID}" 1; then
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
      rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
      if ( cd "$PROJ_ABS" && treehouse return --force "$WT" ) >/dev/null 2>&1; then
        direct_worktree_return_confirmed "$PROJ_ABS" "$WT" || worktree_clean=0
      else
        worktree_clean=0
      fi
      [ "$worktree_clean" = 1 ] || echo "warning: failed to return direct spawn worktree for ${ID:-unknown}; retaining cleanup metadata" >&2
    fi
    if [ -z "$rollback_lock" ]; then
      rollback_lock=$(fm_account_meta_lock_acquire "$STATE" "${ID:-unknown}" 2>/dev/null) || rollback_lock=
    fi
    if [ -n "$rollback_lock" ] && [ "$worktree_clean" = 1 ]; then
      if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
        artifact_backup_name=${EXISTING_ARTIFACT_BACKUP##*/}
        if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-/tmp/fm-$ID}" 1 \
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
        [ "$ORIGINAL_TASK_TMP_PRESENT" != 0 ] || { [ -z "${TASK_TMP:-}" ] || rm -rf "$TASK_TMP"; }
      fi
    fi
    if [ "$worktree_clean" != 1 ]; then
      if [ -n "$rollback_lock" ]; then
        persist_failed_direct_spawn || echo "warning: failed to persist direct spawn cleanup state for ${ID:-unknown}" >&2
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
          if fm_account_restore_artifacts "$STATE" "$ID" "$artifact_backup_name" "${TASK_TMP:-}" 1 \
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
        [ "$ORIGINAL_TASK_TMP_PRESENT" != 0 ] || { [ -z "${TASK_TMP:-}" ] || rm -rf "$TASK_TMP"; }
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
if [ -e "/tmp/fm-$ID" ] || [ -L "/tmp/fm-$ID" ]; then ORIGINAL_TASK_TMP_PRESENT=1; else ORIGINAL_TASK_TMP_PRESENT=0; fi

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
    [ "$RECORDED_TASKTMP" = "/tmp/fm-$ID" ] || { echo "error: direct account recovery metadata has an invalid tasktmp for $ID" >&2; exit 1; }
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
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
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
    # every other kind uses the crew harness only when no dispatch profile file is
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
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && [ "$BACKEND" = orca ]; then
  echo "error: enforced Agent Fleet routing does not support backend=orca" >&2
  exit 1
fi
if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ] && ! fm_account_test_lab_enabled \
  && [ "$BACKEND" != herdr ]; then
  echo "error: enforced Agent Fleet routing requires backend=herdr with a process-bound closed-shell certificate; backend=$BACKEND cannot prove that its pane shell was sanitized before startup" >&2
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
  existing_endpoint_state=$(fm_backend_target_state "$existing_backend" "$existing_target" "fm-$ID" "$(fm_meta_get "$STATE/$ID.meta" tmux_session_target)" 2>/dev/null)
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
  "$SCRIPT_DIR/fm-checkout-refresh.sh" verify-home "$PROJ_ABS" "$FM_ROOT" || {
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
  if [ "$ACCOUNT_EFFECTIVE_MODE" = enforce ]; then
    if ! secondmate_home_supports_account_routing "$PROJ_ABS"; then
      echo "error: refusing account-routed secondmate launch for $PROJ_ABS: the home lacks Agent Fleet routing support. Fast-forward or otherwise reconcile the home to this Firstmate revision, run bin/fm-config-push.sh, and retry." >&2
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
  if CHECKOUT_PREFLIGHT_OUT=$("$SCRIPT_DIR/fm-checkout-refresh.sh" preflight "$PROJ_ABS" 2>&1); then
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
  "$SCRIPT_DIR/fm-checkout-refresh.sh" pool-preflight "$PROJ_ABS" || {
    echo "error: refusing Treehouse acquisition because pool safety could not be inspected for $PROJ_ABS" >&2
    exit 1
  }
  acquire_status=0
  WT=$("$SCRIPT_DIR/fm-checkout-refresh.sh" acquire-worktree "$PROJ_ABS" "firstmate-$ID") || acquire_status=$?
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
  validate_spawn_worktree "treehouse get --lease" "$PROJ_ABS"
  freshness_status=0
  "$SCRIPT_DIR/fm-checkout-refresh.sh" verify-worktree "$WT" "$PROJ_ABS" || freshness_status=$?
  if [ "$freshness_status" -ne 0 ]; then
    echo "error: refusing to launch fm-$ID from a leased worktree whose repository identity, cleanliness, or default-tip freshness could not be proved" >&2
    exit 1
  fi
  WORKTREE_EXPECTED_TIP=$(git -C "$WT" rev-parse HEAD) || exit 1
  WORKTREE_RETAIN_ON_ABORT=0
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
  DIRECT_ACCOUNT_HOME=$("$SCRIPT_DIR/fm-account-directory.sh" prepare "$HARNESS") || exit 1
  echo "fm-spawn: selected direct $HARNESS account home $DIRECT_ACCOUNT_HOME" >&2
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

W="fm-$ID"
SPAWN_CWD=${WT:-$PROJ_ABS}
if [ "$DIRECT_ACCOUNT_RECOVERY" = 1 ]; then
  validate_direct_recovery_worktree_identity || exit 1
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
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$SPAWN_CWD") || exit 1
    ENDPOINT_CREATED=1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
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
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$SPAWN_CWD" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ENDPOINT_CREATED=1
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
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
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
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
      if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ] || [ "$ORCA_PROVIDER_TASK" != "$ORCA_EXPECTED_TASK" ]; then
        echo "error: orca did not return matching worktree id, path, and task authority for $W" >&2
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
    [ "$(fm_backend_orca_terminal_state "$ORCA_TERMINAL" "$ORCA_WORKTREE_ID" "$W")" = present ] \
      && fm_backend_orca_worktree_terminal_contains "$ORCA_WORKTREE_ID" "$W" "$ORCA_TERMINAL" || {
        echo "error: Orca terminal is not authoritatively bound to worktree $ORCA_WORKTREE_ID and task $W" >&2
        exit 1
      }
    T="$ORCA_TERMINAL"
    ENDPOINT_CREATED=1
    ;;
esac
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
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$RECOVERY_ACCOUNT" != 1 ]; then
  WT_REAL=$(real_path_or_raw "$WT")
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" = "$WT_REAL" ]; then
      break
    fi
    sleep 1
  done
  if [ -z "${p:-}" ] || [ "$(real_path_or_raw "$p")" != "$WT_REAL" ]; then
    echo "error: task endpoint did not start in leased worktree $WT within 60s; inspect window $T" >&2
    exit 1
  fi
fi
if [ -z "$WT" ] && [ "$BACKEND" = orca ]; then
  WT="$PROJ_ABS"
fi

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

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
fm_account_real_directory "$STATE" || { echo "error: unsafe state directory at $STATE" >&2; exit 1; }
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git_repository_probe -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      if [ "$ACCOUNT_EFFECTIVE_MODE" != enforce ]; then
        mkdir -p "$WT/.claude"
        cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
        exclude_path '.claude/settings.local.json'
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
      exclude_path '.opencode/plugins/fm-turn-end.js'
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
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
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

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
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
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  echo "generation_id=$SPAWN_GENERATION_ID"
  [ "$NO_ACCOUNT_ROUTING" != 1 ] || echo "account_routing_emergency_bypass=1"
  [ -z "$DIRECT_ACCOUNT_HOME" ] || echo "account_home=$DIRECT_ACCOUNT_HOME"
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
[ -z "$META_WRITE_LOCK" ] || fm_account_meta_lock_release "$META_WRITE_LOCK"
META_WRITE_LOCK=
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

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
if [ "$DIRECT_ACCOUNT_ROUTING" = 1 ]; then
  case "$HARNESS" in
    claude) AGENT_COMMAND="CLAUDE_CONFIG_DIR=$(shell_quote "$DIRECT_ACCOUNT_HOME") $HARNESS" ;;
    codex) AGENT_COMMAND="CODEX_HOME=$(shell_quote "$DIRECT_ACCOUNT_HOME") $HARNESS" ;;
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
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
if [ "$CONTINUE_ACCOUNT" = 1 ]; then
  continuation_launch_command=$LAUNCH
  LAUNCH="$(shell_quote python3) $(shell_quote "$SCRIPT_DIR/fm-prompt-exec.py") $(shell_quote "$CONTINUATION_PROMPT_FILE") $(shell_quote "$CONTINUATION_PROMPT_DIR_ID") $(shell_quote "$CONTINUATION_PROMPT_FILE_ID") $(shell_quote "$CONTINUATION_PROMPT_CONTENT_ID") $(shell_quote "$continuation_launch_command")"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
if [ "$BACKEND" = orca ]; then
  [ "$(fm_backend_orca_terminal_state "$T" "$ORCA_WORKTREE_ID" "$W")" = present ] \
    && fm_backend_orca_worktree_terminal_contains "$ORCA_WORKTREE_ID" "$W" "$T" || {
      echo "error: Orca terminal authority changed before launch for $ID" >&2
      exit 1
    }
  validate_orca_abort_worktree_identity || {
    echo "error: Orca worktree authority changed before launch for $ID" >&2
    exit 1
  }
fi
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
spawn_send_key "$T" Enter

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
CONTINUATION_LAUNCH_DIR=
CONTINUATION_PROMPT_FILE=
[ -z "$META_BACKUP" ] || rm -f "$META_BACKUP"
META_BACKUP=
discard_existing_artifact_backup
[ "$LIFECYCLE_LOCK_OWNED" != 1 ] || [ -z "$LIFECYCLE_LOCK" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" || exit 1
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
echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT$account_summary"
