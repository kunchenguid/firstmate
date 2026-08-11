#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree, or a secondmate in
# its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--display-title <title>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--display-title <title>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --display-title supplies the deterministic Herdr-only presentation phrase.
#   Without it, spawn reads data/<task-id>/display-title, then the structured
#   backlog title, then a semantic task-id fallback. Tmux naming is unchanged.
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX or HERDR_ENV=1; bin/fm-backend.sh's fm_backend_detect), then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   Herdr adapter. Auto-detected Herdr prints a loud stderr notice;
#   auto-detected tmux stays silent. Default tmux spawns do not write backend=
#   to meta; absent backend= means tmux.
#   A backend spawn refusal (missing dependency or version gate) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   Herdr additionally supports a default-off presentation-only layout when the
#   local config/herdr-presentation-spaces flag exists. A clean fresh task first
#   writes state/<id>.herdr-presentation atomically, then creates a disposable
#   workspace containing only the ordinary task pane. A successful clean create
#   upgrades its attempt journal with exact home, session, workspace, tab, pane,
#   parent, and label bindings. On a same-identity restart, that complete binding
#   plus authoritative metadata may replace one exact agent-free husk in place.
#   The journal, visible token, and labels alone are never endpoint or ownership
#   authority, and every ambiguous recovery stays on the flat fallback after
#   duplicate-agent risk is independently absent. Treehouse allocation and task
#   metadata are unchanged.
#   A clean projected create or exact resume makes one bounded attempt to hold
#   the one session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through launch handoff. Lock
#   contention warns and falls back to the ordinary flat layout before any
#   projection mutation. The exact response-derived new workspace is inserted
#   immediately after its owning parent (firstmate or 2ndmate-<id>) contiguous
#   child block. Ordering never authorizes lifecycle cleanup, and any
#   unavailable, ambiguous, or failed move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. It also reads fm-route.sh and fills any
#   omitted --model/--effort axes from the route when the active crew harness still
#   matches the routed harness. When config/crew-dispatch.json exists,
#   crewmate/scout spawns require an explicit harness so firstmate cannot silently
#   skip dispatch profile consultation. A --secondmate spawn is exempt and resolves
#   the SECONDMATE harness (config/secondmate-harness -> config/crew-harness -> own),
#   then fills any omitted --model/--effort axes from primary-local
#   config/secondmate-profile.json.
#   That keeps the secondmate-vs-crewmate launch profile DURABLE across every
#   respawn (recovery, /updatefirstmate, restart). A bare adapter name
#   (claude|codex|opencode|pi|grok) overrides the harness for this spawn (either
#   kind). A non-flag string containing whitespace is treated as a RAW launch
#   command - the escape hatch for verifying new adapters.
#   A --secondmate spawn also propagates the primary's declared inheritable config
#   into the secondmate home's config/, so the secondmate's OWN crewmates,
#   dispatch profiles, and backlog backend inherit the primary's settings
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Matching JT Control Room ship spawns for .openclaw or jt-control-room append a
#   JT PR Intake Governor block to direct-PR/no-mistakes briefs before launch.
#   Eligible projects may also receive an optional codebase-memory-mcp (CBM)
#   orientation block and CBM env exports at launch (soft dependency; see
#   bin/fm-cbm-lib.sh). Missing CBM never blocks spawn.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root of the TARGET project (same git common dir and HEAD
#   present), distinct from the project checkout, active home, and Firstmate
#   root. Every launch carries an explicit worker-home declaration. The settle
#   poll prefers the live agent process cwd over provider pane-path hints, and
#   the acquired slot is stamped with its current owner.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
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
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "spawn" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$SCRIPT_DIR/fm-tool-path-lib.sh"
fm_normalize_tool_path
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-label-lib.sh
. "$SCRIPT_DIR/fm-task-label-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-agent-cwd-lib.sh
. "$SCRIPT_DIR/fm-agent-cwd-lib.sh"
# shellcheck source=bin/fm-slot-owner-lib.sh
. "$SCRIPT_DIR/fm-slot-owner-lib.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
DISPLAY_TITLE=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
DISPLAY_TITLE_SET=0
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
      display-title) DISPLAY_TITLE=$a; DISPLAY_TITLE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --display-title) want_value=display-title ;;
    --display-title=*) DISPLAY_TITLE=${a#--display-title=}; DISPLAY_TITLE_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$DISPLAY_TITLE_SET" -eq 0 ] || [ -n "$DISPLAY_TITLE" ] || { echo "error: --display-title requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection: explicit --backend > FM_BACKEND > config/backend > tmux.
# Validate before project resolution so an unsupported runtime is refused
# loudly and deterministically.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_FLAT_ABORT_CLEANUP=0
HERDR_FLAT_ABORT_TARGET=
HERDR_FLAT_ABORT_UNCERTAIN=0
HERDR_FLAT_ABORT_SCOPE=
HERDR_FLAT_ABORT_LABEL=
HERDR_FLAT_ABORT_UNCERTAINTY_FILE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_ENDPOINT_CREATED=0
SPAWN_WORKTREE_LEASED=0
SPAWN_WORKTREE_PROVEN=0
SPAWN_WORKTREE_PATH_SOURCE=
SPAWN_META_PUBLISHED=0
SPAWN_RECOVERY_META_PUBLISHED=0
SPAWN_RECOVERY_META_REPLACE_ALLOWED=0
SPAWN_SLOT_STAMPED=0
SPAWN_SLOT_LOCK_HELD=0
SPAWN_SLOT_LOCK_PATH=
SPAWN_HOME_LOCK=
SPAWN_HOME_LOCK_HELD=0
SPAWN_PARENT_HOME_LOCK=
SPAWN_PARENT_HOME_LOCK_HELD=0
SPAWN_WORKTREE_PATH=
SPAWN_WORKTREE_LEASE_PROOF=
SPAWN_ARTIFACTS_CLEAN=0
SPAWN_CLAUDE_HOOK_CREATED=0
SPAWN_OPENCODE_HOOK_CREATED=0
SPAWN_PI_EXT_CREATED=0
SPAWN_TURNEND_CREATED=0
SPAWN_GROK_POINTER_CREATED=0
SPAWN_GROK_TOKEN_CREATED=0
SPAWN_GROK_AUTH_CREATED=0
SPAWN_GROK_AUTH_PROVISIONAL=0
SPAWN_GROK_HOOK_CREATED=0
SPAWN_GROK_CONFIG_CREATED=0
SPAWN_CREATED_DIRECTORIES=()
SPAWN_GROK_AUTH_FILE=
SPAWN_GROK_AUTH_TMP=
SPAWN_GROK_HOOK_FILE=
SPAWN_GROK_CONFIG_FILE=
SPAWN_CLAUDE_HOOK_INODE=
SPAWN_CLAUDE_HOOK_DIGEST=
SPAWN_OPENCODE_HOOK_INODE=
SPAWN_OPENCODE_HOOK_DIGEST=
SPAWN_PI_EXT_INODE=
SPAWN_PI_EXT_DIGEST=
SPAWN_TURNEND_INODE=
SPAWN_TURNEND_DIGEST=
SPAWN_GROK_POINTER_INODE=
SPAWN_GROK_POINTER_DIGEST=
SPAWN_GROK_TOKEN_INODE=
SPAWN_GROK_TOKEN_DIGEST=
SPAWN_GROK_AUTH_INODE=
SPAWN_GROK_AUTH_DIGEST=

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

spawn_herdr_flat_uncertainty_record() {
  local reason=$1 target=${2:-} scope=${3:-} label=${4:-} file tmp
  file=${HERDR_FLAT_ABORT_UNCERTAINTY_FILE:-"$STATE/$ID.herdr-cleanup-uncertain"}
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(mktemp "$STATE/.$ID.herdr-cleanup-uncertain.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$ID"
    printf 'reason=%s\n' "$reason"
    printf 'target=%s\n' "$target"
    printf 'scope=%s\n' "$scope"
    printf 'label=%s\n' "$label"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

spawn_abort_recovery_meta() {
  local tmp meta="$STATE/$ID.meta"
  [ -n "${T:-}" ] && [ -n "${PROJ_ABS:-}" ] || return 1
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if [ "${SPAWN_RECOVERY_META_PUBLISHED:-0}" != 1 ] \
      && [ "${SPAWN_RECOVERY_META_REPLACE_ALLOWED:-0}" != 1 ]; then
      return 0
    fi
    [ ! -L "$meta" ] || return 1
  fi
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(mktemp "$STATE/.$ID.spawn-abort.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    echo "window=$T"
    if [ "${SPAWN_WORKTREE_PROVEN:-0}" = 1 ] && [ -n "${WT:-}" ]; then
      echo "worktree=$WT"
    else
      echo "worktree="
      echo "slot_lease_state=unresolved"
      echo "slot_lease_holder=$ID"
      [ -z "${WT_CANDIDATE:-}" ] || echo "slot_worktree_candidate=$WT_CANDIDATE"
    fi
    echo "project=$PROJ_ABS"
    echo "harness=${HARNESS:-unknown}"
    echo "kind=${KIND:-ship}"
    echo "mode=${MODE:-no-mistakes}"
    echo "yolo=${YOLO:-off}"
    echo "tasktmp=${TASK_TMP:-}"
    echo "model=${MODEL:-default}"
    echo "effort=${EFFORT:-default}"
    [ "${BACKEND:-tmux}" = tmux ] || echo "backend=${BACKEND:-tmux}"
    if [ "${BACKEND:-tmux}" = herdr ]; then
      echo "display_label=${DISPLAY_LABEL:-}"
      echo "herdr_session=${HERDR_SES:-}"
      echo "herdr_workspace_id=${HERDR_WORKSPACE_ID:-}"
      echo "herdr_tab_id=${HERDR_TAB_ID:-}"
      echo "herdr_pane_id=${HERDR_PANE_ID:-}"
    fi
    [ -z "${GROK_AUTH_DIR:-}" ] || echo "grok_registry_dir=$GROK_AUTH_DIR"
    [ -z "${SPAWN_GROK_AUTH_FILE:-}" ] || echo "grok_registry_token=${SPAWN_GROK_AUTH_FILE##*/}"
    if [ "${SPAWN_CLAUDE_HOOK_CREATED:-0}" = 1 ]; then
      echo "claude_hook_inode=$SPAWN_CLAUDE_HOOK_INODE"
      echo "claude_hook_digest=$SPAWN_CLAUDE_HOOK_DIGEST"
    fi
    if [ "${SPAWN_OPENCODE_HOOK_CREATED:-0}" = 1 ]; then
      echo "opencode_hook_inode=$SPAWN_OPENCODE_HOOK_INODE"
      echo "opencode_hook_digest=$SPAWN_OPENCODE_HOOK_DIGEST"
    fi
    echo "spawn_state=aborted"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  SPAWN_RECOVERY_META_PUBLISHED=1
}

spawn_slot_stamp_owned() {
  [ -n "${WT:-}" ] && [ -n "${ID:-}" ] || return 1
  fm_slot_stamp_record "$WT" || return 1
  [ "$FM_SLOT_STAMP_TASK" = "$ID" ] || return 1
  fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$(real_path_or_raw "$FM_HOME")"
}

spawn_release_label_lock() {
  [ "${HERDR_LABEL_LOCK_HELD:-0}" = 1 ] || return 0
  if fm_lock_release "$HERDR_LABEL_LOCK"; then
    HERDR_LABEL_LOCK_HELD=0
    return 0
  fi
  return 1
}

spawn_release_home_lock() {
  [ "${SPAWN_HOME_LOCK_HELD:-0}" = 1 ] || return 0
  if fm_lock_release "$SPAWN_HOME_LOCK"; then
    SPAWN_HOME_LOCK_HELD=0
    return 0
  fi
  return 1
}

spawn_release_parent_home_lock() {
  [ "${SPAWN_PARENT_HOME_LOCK_HELD:-0}" = 1 ] || return 0
  if fm_lock_release "$SPAWN_PARENT_HOME_LOCK"; then
    SPAWN_PARENT_HOME_LOCK_HELD=0
    return 0
  fi
  return 1
}

spawn_release_task_lock() {
  [ "${SPAWN_TASK_LOCK_HELD:-0}" = 1 ] || return 0
  if fm_lock_release "$SPAWN_TASK_LOCK"; then
    SPAWN_TASK_LOCK_HELD=0
    return 0
  fi
  return 1
}

spawn_require_new_artifact() {
  local path=$1
  [ ! -e "$path" ] && [ ! -L "$path" ] || {
    echo "error: spawn artifact already exists and is not owned by this spawn: $path" >&2
    return 1
  }
}

spawn_artifact_inode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%i' "$1" 2>/dev/null
  else
    stat -c '%i' "$1" 2>/dev/null
  fi
}

spawn_artifact_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

spawn_artifact_proof_available() {
  local dir=$1
  spawn_artifact_inode "$dir" >/dev/null || return 1
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1
}

spawn_create_new_artifact() {
  local path=$1 inode_var=$2 digest_var=$3 created_var=${4:-} dir tmp inode digest
  spawn_require_new_artifact "$path" || return 1
  dir=$(dirname -- "$path") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  spawn_artifact_proof_available "$dir" || return 1
  tmp=$(mktemp "$dir/.fm-artifact.XXXXXXXXXXXX") || return 1
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  inode=$(spawn_artifact_inode "$tmp") || {
    rm -f -- "$tmp"
    return 1
  }
  if ! digest=$(spawn_artifact_digest "$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$path" 2>/dev/null; then
    rm -f -- "$tmp"
    echo "error: spawn artifact path was occupied during exclusive creation: $path" >&2
    return 1
  fi
  printf -v "$inode_var" '%s' "$inode"
  printf -v "$digest_var" '%s' "$digest"
  if [ -n "$created_var" ]; then
    printf -v "$created_var" '%s' 1
  fi
  if ! [ -f "$path" ] || [ -L "$path" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

spawn_create_or_reuse_artifact() {
  local path=$1 created_var=${2:-} inode_var=${3:-} digest_var=${4:-}
  local dir tmp status inode digest
  dir=$(dirname -- "$path") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  spawn_artifact_proof_available "$dir" || return 1
  tmp=$(mktemp "$dir/.fm-artifact.XXXXXXXXXXXX") || return 1
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$tmp" "$path"; then
      status=0
    else
      status=1
    fi
    rm -f -- "$tmp"
    if [ "$status" -eq 0 ] && [ -n "$created_var" ]; then
      printf -v "$created_var" '%s' 0
    fi
    return "$status"
  fi
  inode=$(spawn_artifact_inode "$tmp") || {
    rm -f -- "$tmp"
    return 1
  }
  if ! digest=$(spawn_artifact_digest "$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$path" 2>/dev/null; then
    if [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$tmp" "$path"; then
      rm -f -- "$tmp"
      if [ -n "$created_var" ]; then
        printf -v "$created_var" '%s' 0
      fi
      return 0
    fi
    rm -f -- "$tmp"
    return 1
  fi
  if [ -n "$created_var" ]; then
    printf -v "$created_var" '%s' 1
  fi
  if [ -n "$inode_var" ]; then
    printf -v "$inode_var" '%s' "$inode"
  fi
  if [ -n "$digest_var" ]; then
    printf -v "$digest_var" '%s' "$digest"
  fi
  if ! [ -f "$path" ] || [ -L "$path" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

spawn_preflight_real_directory_path() {
  local path=$1 parent
  [ -n "$path" ] || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    [ "$path" = / ] && return 0
    parent=$(dirname -- "$path") || return 1
    [ "$parent" != "$path" ] || return 1
    spawn_preflight_real_directory_path "$parent"
    return
  fi
  parent=$(dirname -- "$path") || return 1
  [ "$parent" != "$path" ] || return 1
  spawn_preflight_real_directory_path "$parent"
}

spawn_ensure_real_directory_path() {
  local path=$1 parent
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    [ "$path" = / ] && return 0
    parent=$(dirname -- "$path") || return 1
    [ "$parent" != "$path" ] || return 1
    spawn_ensure_real_directory_path "$parent"
    return
  fi
  parent=$(dirname -- "$path") || return 1
  [ "$parent" != "$path" ] || return 1
  spawn_ensure_real_directory_path "$parent" || return 1
  if mkdir "$path" 2>/dev/null; then
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    SPAWN_CREATED_DIRECTORIES+=("$path")
    return 0
  fi
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
}

spawn_artifact_matches_or_absent() {
  local path=$1 expected=$2
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$expected" "$path"
    return
  fi
  return 0
}

spawn_remove_owned_artifact() {
  spawn_remove_artifact_bound "$1" "$2" "$3"
}

spawn_remove_unproven_artifact() {
  spawn_remove_artifact_bound "$1" "$2" ""
}

spawn_remove_artifact_bound() {
  local path=$1 expected_inode=$2 expected_digest=${3:-}
  local identity quarantine dir identity_inode identity_digest
  [ -n "$path" ] || return 1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ -n "$expected_inode" ] || return 1
  dir=${path%/*}
  [ "$dir" = "$path" ] && dir=.
  identity="$dir/.fm-owned.$$.${RANDOM}.identity"
  quarantine="$dir/.fm-owned.$$.${RANDOM}.quarantine"
  [ ! -e "$identity" ] && [ ! -L "$identity" ] || return 1
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
  ln "$path" "$identity" 2>/dev/null || return 1
  if ! [ -f "$identity" ] || [ -L "$identity" ] || ! [ "$path" -ef "$identity" ]; then
    rm -f -- "$identity"
    return 1
  fi
  identity_inode=$(spawn_artifact_inode "$identity") || {
    rm -f -- "$identity"
    return 1
  }
  if [ "$identity_inode" != "$expected_inode" ]; then
    rm -f -- "$identity"
    return 1
  fi
  if [ -n "$expected_digest" ]; then
    identity_digest=$(spawn_artifact_digest "$identity") || {
      rm -f -- "$identity"
      return 1
    }
    if [ "$identity_digest" != "$expected_digest" ]; then
      rm -f -- "$identity"
      return 1
    fi
  fi
  if ! mv "$path" "$quarantine" 2>/dev/null; then
    rm -f -- "$identity"
    return 1
  fi
  if [ "$quarantine" -ef "$identity" ]; then
    rm -f -- "$quarantine" "$identity"
    return $?
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ] \
     && [ -f "$quarantine" ] && [ ! -L "$quarantine" ] \
     && ln "$quarantine" "$path" 2>/dev/null; then
    rm -f -- "$quarantine" || true
  fi
  rm -f -- "$identity" || true
  return 1
}

spawn_discard_grok_auth_provisional() {
  local path=${SPAWN_GROK_AUTH_TMP:-}
  if [ -n "$path" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    rm -f -- "$path" || return 1
  fi
  SPAWN_GROK_AUTH_TMP=
  SPAWN_GROK_AUTH_FILE=
  SPAWN_GROK_AUTH_INODE=
  SPAWN_GROK_AUTH_DIGEST=
  SPAWN_GROK_AUTH_PROVISIONAL=0
}

spawn_acquire_home_lock() {
  local lock_home=$1 lock_path
  [ -d "$lock_home" ] || return 1
  lock_path=$(fm_config_inherit_lock_path "$lock_home") || return 1
  fm_lock_acquire_wait "$lock_path" || return 1
  SPAWN_HOME_LOCK=$lock_path
  SPAWN_HOME_LOCK_HELD=1
}

spawn_acquire_parent_home_lock() {
  local lock_home=$1 lock_path
  [ -d "$lock_home" ] || return 1
  lock_path=$(fm_config_inherit_lock_path "$lock_home") || return 1
  fm_lock_acquire_wait "$lock_path" || return 1
  SPAWN_PARENT_HOME_LOCK=$lock_path
  SPAWN_PARENT_HOME_LOCK_HELD=1
}

spawn_abort_artifacts_cleanup() {
  local rc=0 token owner_file created_dir created_index
  [ -n "${ID:-}" ] || return 0
  if [ "${SPAWN_CLAUDE_HOOK_CREATED:-0}" = 1 ] && [ -n "${WT:-}" ] && [ -d "$WT" ]; then
    spawn_remove_owned_artifact "$WT/.claude/settings.local.json" "$SPAWN_CLAUDE_HOOK_INODE" "$SPAWN_CLAUDE_HOOK_DIGEST" \
      || rc=1
  fi
  if [ "${SPAWN_OPENCODE_HOOK_CREATED:-0}" = 1 ] && [ -n "${WT:-}" ] && [ -d "$WT" ]; then
    spawn_remove_owned_artifact "$WT/.opencode/plugins/fm-turn-end.js" "$SPAWN_OPENCODE_HOOK_INODE" "$SPAWN_OPENCODE_HOOK_DIGEST" || rc=1
  fi
  if [ "${SPAWN_GROK_POINTER_CREATED:-0}" = 1 ] && [ -n "${WT:-}" ] && [ -d "$WT" ]; then
    spawn_remove_owned_artifact "$WT/.fm-grok-turnend" "$SPAWN_GROK_POINTER_INODE" "$SPAWN_GROK_POINTER_DIGEST" || rc=1
  fi
  if [ "${SPAWN_TURNEND_CREATED:-0}" = 1 ]; then
    spawn_remove_owned_artifact "$STATE/$ID.turn-ended" "$SPAWN_TURNEND_INODE" "$SPAWN_TURNEND_DIGEST" || rc=1
  fi
  if [ "${SPAWN_PI_EXT_CREATED:-0}" = 1 ]; then
    spawn_remove_owned_artifact "$STATE/$ID.pi-ext.ts" "$SPAWN_PI_EXT_INODE" "$SPAWN_PI_EXT_DIGEST" || rc=1
  fi
  if [ "${SPAWN_GROK_AUTH_CREATED:-0}" = 1 ] && [ -n "${SPAWN_GROK_AUTH_FILE:-}" ]; then
    spawn_remove_owned_artifact "$SPAWN_GROK_AUTH_FILE" "$SPAWN_GROK_AUTH_INODE" "$SPAWN_GROK_AUTH_DIGEST" || rc=1
  fi
  if [ "${SPAWN_GROK_AUTH_PROVISIONAL:-0}" = 1 ] && [ -n "${SPAWN_GROK_AUTH_FILE:-}" ]; then
    spawn_remove_unproven_artifact "$SPAWN_GROK_AUTH_FILE" "${SPAWN_GROK_AUTH_INODE:-}" || rc=1
  fi
  if [ -n "${SPAWN_GROK_AUTH_TMP:-}" ]; then
    if [ ! -e "$SPAWN_GROK_AUTH_TMP" ] && [ ! -L "$SPAWN_GROK_AUTH_TMP" ]; then
      :
    elif [ -n "${SPAWN_GROK_AUTH_INODE:-}" ] && [ -n "${SPAWN_GROK_AUTH_DIGEST:-}" ]; then
      spawn_remove_owned_artifact "$SPAWN_GROK_AUTH_TMP" \
        "$SPAWN_GROK_AUTH_INODE" "$SPAWN_GROK_AUTH_DIGEST" || rc=1
    else
      rc=1
    fi
  fi
  if [ "${SPAWN_GROK_HOOK_CREATED:-0}" = 1 ]; then
    spawn_remove_owned_artifact "$SPAWN_GROK_HOOK_FILE" \
      "$SPAWN_GROK_HOOK_INODE" "$SPAWN_GROK_HOOK_DIGEST" || rc=1
  fi
  if [ "${SPAWN_GROK_CONFIG_CREATED:-0}" = 1 ]; then
    spawn_remove_owned_artifact "$SPAWN_GROK_CONFIG_FILE" \
      "$SPAWN_GROK_CONFIG_INODE" "$SPAWN_GROK_CONFIG_DIGEST" || rc=1
  fi
  if [ "${SPAWN_GROK_TOKEN_CREATED:-0}" = 1 ] && [ -n "${STATE:-}" ] \
    && { [ -e "$STATE/$ID.grok-turnend-token" ] || [ -L "$STATE/$ID.grok-turnend-token" ]; }; then
    if [ "${SPAWN_GROK_AUTH_CREATED:-0}" != 1 ]; then
      rc=1
    else
      token=$(sed -n 's/^token=//p' "$STATE/$ID.grok-turnend-token" 2>/dev/null | head -1 || true)
      case "$token" in
        fm.????????????)
          case "$token" in
            *[!A-Za-z0-9._-]*) rc=1 ;;
            *) spawn_remove_owned_artifact "$STATE/$ID.grok-turnend-token" \
                 "$SPAWN_GROK_TOKEN_INODE" "$SPAWN_GROK_TOKEN_DIGEST" || rc=1 ;;
          esac
          ;;
        *) rc=1 ;;
      esac
    fi
  fi
  for ((created_index=${#SPAWN_CREATED_DIRECTORIES[@]} - 1; created_index >= 0; created_index--)); do
    created_dir=${SPAWN_CREATED_DIRECTORIES[$created_index]}
    if [ -e "$created_dir" ] || [ -L "$created_dir" ]; then
      if [ -d "$created_dir" ] && [ ! -L "$created_dir" ]; then
        rmdir "$created_dir" || rc=1
      else
        rc=1
      fi
    fi
  done
  [ -z "${HERDR_LABEL_JOURNAL:-}" ] || rm -f "$HERDR_LABEL_JOURNAL" || rc=1
  [ -z "${HERDR_PRESENTATION_JOURNAL:-}" ] || rm -f "$HERDR_PRESENTATION_JOURNAL" || rc=1
  if [ -n "${TASK_TMP:-}" ] && [ -d "$TASK_TMP" ]; then
    owner_file="$TASK_TMP/.fm-tasktmp-owner"
    if [ -f "$owner_file" ] && [ ! -L "$owner_file" ] \
       && printf 'task=%s\npath=%s\n' "$ID" "$TASK_TMP" | cmp -s - "$owner_file"; then
      rm -rf -- "$TASK_TMP" || rc=1
    else
      rc=1
    fi
  fi
  return "$rc"
}

spawn_abort_cleanup() {
  local status=$? cleanup_session endpoint_cleanup_status=1 slot_returned=0
  [ "${SPAWN_ENDPOINT_CREATED:-0}" = 1 ] || endpoint_cleanup_status=0
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    if fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE"; then
      endpoint_cleanup_status=0
    fi
  fi
  if [ "$HERDR_FLAT_ABORT_CLEANUP" = 1 ]; then
    cleanup_session=${HERDR_FLAT_ABORT_TARGET%%:*}
    if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ] \
       && ! spawn_herdr_presentation_order_lock_acquire "$cleanup_session"; then
      spawn_herdr_flat_uncertainty_record \
        "presentation lock unavailable during abort cleanup" "$HERDR_FLAT_ABORT_TARGET" "" "" \
        || echo "error: could not persist Herdr abort-cleanup uncertainty for $ID" >&2
    elif fm_backend_herdr_parse_target "$HERDR_FLAT_ABORT_TARGET" \
         && fm_backend_herdr_projection_teardown_close \
           "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE"; then
      endpoint_cleanup_status=0
      rm -f "${HERDR_FLAT_ABORT_UNCERTAINTY_FILE:-"$STATE/$ID.herdr-cleanup-uncertain"}"
    else
      spawn_herdr_flat_uncertainty_record \
        "exact focus-safe abort cleanup unconfirmed" "$HERDR_FLAT_ABORT_TARGET" "" "" \
        || echo "error: could not persist Herdr abort-cleanup uncertainty for $ID" >&2
    fi
    HERDR_FLAT_ABORT_CLEANUP=0
  fi
  if [ "$HERDR_FLAT_ABORT_UNCERTAIN" = 1 ]; then
    spawn_herdr_flat_uncertainty_record \
      "tab create mutation identity unavailable" "" "$HERDR_FLAT_ABORT_SCOPE" "$HERDR_FLAT_ABORT_LABEL" \
      || echo "error: could not persist Herdr create uncertainty for $ID" >&2
    HERDR_FLAT_ABORT_UNCERTAIN=0
  fi
  if [ "${HERDR_LABEL_LOCK_HELD:-0}" = 1 ]; then
    spawn_release_label_lock || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          {
            echo "window=$W"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            echo "mode=${MODE:-no-mistakes}"
            echo "yolo=${YOLO:-off}"
            echo "tasktmp=${TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
          } > "$STATE/$ID.meta" 2>/dev/null || true
        fi
      fi
    fi
  fi
  if [ "$status" -ne 0 ] \
     && [ "${SPAWN_ENDPOINT_CREATED:-0}" = 1 ] \
     && [ "$endpoint_cleanup_status" -ne 0 ] \
     && [ "${BACKEND:-}" != herdr ] \
     && [ "${BACKEND:-}" != orca ] \
     && [ -n "${WID:-}" ]; then
    if cleanup_spawn_window "$WID"; then
      endpoint_cleanup_status=0
    fi
  fi
  if [ "$status" -ne 0 ] && [ "$endpoint_cleanup_status" -eq 0 ]; then
    if spawn_abort_artifacts_cleanup; then
      SPAWN_ARTIFACTS_CLEAN=1
    else
      echo "warning: spawn abort could not remove every task artifact; preserving recovery metadata" >&2
    fi
  fi
  if [ "$status" -ne 0 ] \
     && [ "${SPAWN_WORKTREE_LEASED:-0}" = 1 ] \
     && [ "${SPAWN_WORKTREE_PROVEN:-0}" = 1 ] \
     && [ "${SPAWN_SLOT_STAMPED:-0}" != 1 ] \
     && [ -n "${WT:-}" ]; then
    if [ "${SPAWN_SLOT_LOCK_HELD:-0}" != 1 ] \
       && fm_slot_lock_acquire "$WT"; then
      SPAWN_SLOT_LOCK_PATH=$FM_SLOT_LOCK_PATH
      SPAWN_SLOT_LOCK_HELD=1
    fi
    if [ "${SPAWN_SLOT_LOCK_HELD:-0}" = 1 ] \
       && fm_slot_stamp_write "$WT" "$ID" "$(real_path_or_raw "$FM_HOME")" 2>/dev/null; then
      SPAWN_SLOT_STAMPED=1
    fi
  fi
  if [ "$status" -ne 0 ] \
     && [ "${SPAWN_WORKTREE_LEASED:-0}" = 1 ] \
     && [ "${SPAWN_WORKTREE_PROVEN:-0}" = 1 ] \
     && [ "$endpoint_cleanup_status" -eq 0 ] \
     && [ "$SPAWN_ARTIFACTS_CLEAN" = 1 ] \
     && [ -n "${WT:-}" ] \
     && [ -n "${PROJ_ABS:-}" ] \
     && spawn_slot_stamp_owned; then
    if ( cd "$PROJ_ABS" && treehouse return --force "$WT" ) >/dev/null 2>&1; then
      if fm_slot_stamp_clear_after_return "$WT" "$ID" "$(real_path_or_raw "$FM_HOME")"; then
        slot_returned=1
        if [ "${SPAWN_META_PUBLISHED:-0}" = 1 ] \
          || [ "${SPAWN_RECOVERY_META_PUBLISHED:-0}" = 1 ]; then
          rm -f "$STATE/$ID.meta" || slot_returned=0
        fi
      else
        echo "warning: spawn abort returned $WT but could not clear its ownership stamp; preserving recovery metadata" >&2
      fi
    else
      echo "warning: spawn abort could not return leased worktree $WT; preserving its metadata and ownership stamp for teardown" >&2
    fi
  fi
  if [ "$status" -ne 0 ] \
     && [ "$slot_returned" -ne 1 ] \
     && [ "${SPAWN_WORKTREE_LEASED:-0}" = 1 ] \
     && [ "${SPAWN_META_PUBLISHED:-0}" != 1 ]; then
    if spawn_abort_recovery_meta; then
      echo "warning: spawn abort left a recoverable task record for the lease held by $ID${WT:+ on worktree $WT}" >&2
    else
      echo "error: spawn abort could not publish a recoverable task record for the lease held by $ID${WT:+ on worktree $WT}" >&2
    fi
    if [ -z "${WT:-}" ]; then
      local candidate_note=''
      [ -z "${WT_CANDIDATE:-}" ] || candidate_note=" (settle poll saw candidate ${WT_CANDIDATE})"
      echo "warning: no pooled slot path was resolved for $ID; run 'treehouse list' to find the slot leased to $ID$candidate_note and reclaim it per docs/worker-isolation.md" >&2
    fi
  fi
  if [ -n "${META_TMP:-}" ] && [ -e "$META_TMP" ]; then
    rm -f "$META_TMP"
  fi
  [ -z "${SPAWN_WORKTREE_LEASE_PROOF:-}" ] || rm -f "$SPAWN_WORKTREE_LEASE_PROOF" 2>/dev/null || true
  if [ "$SPAWN_SLOT_LOCK_HELD" = 1 ]; then
    SPAWN_SLOT_LOCK_HELD=0
    fm_slot_lock_release "$SPAWN_SLOT_LOCK_PATH" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "${SPAWN_HOME_LOCK_HELD:-0}" = 1 ]; then
    spawn_release_home_lock || true
  fi
  if [ "${SPAWN_PARENT_HOME_LOCK_HELD:-0}" = 1 ]; then
    spawn_release_parent_home_lock || true
  fi
  if [ "${SPAWN_TASK_LOCK_HELD:-0}" = 1 ]; then
    spawn_release_task_lock || true
  fi
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One bounded lock per live Herdr session/socket, shared across all homes.
# <session> is required so secondmate and primary spawns serialize against the
# same session without writing any other home's state directory.
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
  if [ "$DISPLAY_TITLE_SET" -eq 1 ]; then
    echo "error: batch dispatch does not support one shared --display-title; spawn each task explicitly" >&2
    exit 2
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
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
if [ "$DISPLAY_TITLE_SET" -eq 0 ] && [ -e "$DATA/$ID/display-title" ]; then
  [ -f "$DATA/$ID/display-title" ] || {
    echo "error: display title record for $ID is not a regular file" >&2
    exit 1
  }
  DISPLAY_TITLE=$(cat "$DATA/$ID/display-title")
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
HERDR_FLAT_ABORT_UNCERTAINTY_FILE="$STATE/$ID.herdr-cleanup-uncertain"
if [ -e "$HERDR_FLAT_ABORT_UNCERTAINTY_FILE" ] || [ -L "$HERDR_FLAT_ABORT_UNCERTAINTY_FILE" ]; then
  echo "error: unresolved Herdr cleanup uncertainty for $ID at $HERDR_FLAT_ABORT_UNCERTAINTY_FILE; refusing another spawn" >&2
  exit 1
fi
PROJ=
ARG3=
FIRSTMATE_HOME=

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
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"'
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

HARNESS=
LAUNCH=
ROUTE_PROFILE=manual
ROUTE_HARNESS=
ROUTE_MODEL=default
ROUTE_EFFORT=default
ROUTE_REASON=
ROUTE_OVERRIDE=none
ROUTE_RISK_FLAGS=none
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ROUTE_HARNESS=${HARNESS:-raw}
    ROUTE_REASON="raw launch command selected for adapter verification"
    ROUTE_OVERRIDE='raw-launch'
    ;;
  '')
    # Deferred until BRIEF/PROJ_ABS are known, so the route can read task text.
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ROUTE_HARNESS=$HARNESS
    ROUTE_REASON="manual harness override selected $HARNESS"
    ROUTE_OVERRIDE=manual-harness
    ;;
esac

parse_route_output() {
  local line key value
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    case "$key" in
      profile) ROUTE_PROFILE=$value ;;
      harness) ROUTE_HARNESS=$value ;;
      model) ROUTE_MODEL=$value ;;
      effort) ROUTE_EFFORT=$value ;;
      reason) ROUTE_REASON=$value ;;
      override) ROUTE_OVERRIDE=$value ;;
      risk_flags) ROUTE_RISK_FLAGS=$value ;;
    esac
  done
}

apply_secondmate_profile_config() {
  local file err model effort
  [ "$KIND" = secondmate ] || return 0
  file="$CONFIG/secondmate-profile.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: config/secondmate-profile.json requires jq to read model/effort defaults" >&2
    exit 1
  fi
  if ! jq . "$file" >/dev/null 2>&1; then
    echo "error: invalid config/secondmate-profile.json - malformed JSON" >&2
    exit 1
  fi
  err=$(jq -r '
    if type != "object" then "top-level value must be an object"
    elif has("model") and ((.model | type) != "string" or (.model | length) == 0) then "model must be a non-empty string"
    elif has("effort") and ((.effort | type) != "string") then "effort must be a string"
    elif has("effort") and (.effort as $e | (["default","low","medium","high","xhigh","max"] | index($e) | not)) then "invalid effort: " + (.effort | tostring)
    else empty
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "error: invalid config/secondmate-profile.json - $err" >&2
    exit 1
  fi
  if [ "$MODEL_SET" -eq 0 ]; then
    model=$(jq -r '.model // "default"' "$file")
    MODEL=$model
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    effort=$(jq -r '.effort // "default"' "$file")
    EFFORT=$effort
  fi
}

append_route_block() {
  [ "$KIND" != secondmate ] || return 0
  grep -qxF '<!-- firstmate-route -->' "$BRIEF" 2>/dev/null && return 0
  cat >> "$BRIEF" <<EOF

<!-- firstmate-route -->
# Route

route: $ROUTE_PROFILE because $ROUTE_REASON
Harness: $ROUTE_HARNESS
Model: $ROUTE_MODEL
Reasoning effort: $ROUTE_EFFORT
Override: $ROUTE_OVERRIDE
Risk flags: $ROUTE_RISK_FLAGS
Do not downgrade this route without an explicit firstmate override.
EOF
}

is_jt_pr_intake_context() {
  local lower_id lower_project
  lower_project=$(basename "$PROJ_ABS" | tr '[:upper:]' '[:lower:]')
  case "$lower_project" in
    .openclaw|jt-control-room) ;;
    *) return 1 ;;
  esac

  lower_id=$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')
  case "$lower_id" in
    jt-*|*jt-control-room*|*replenishment*|*donnees*|*automation*) return 0 ;;
  esac

  if grep -Eiq 'jt control room|jt-control-room|control room|operator|routes?|replenishment|donnees|trust cockpit|automation cockpit|ppc|sellersnap|runtime|served data|refresh:doctor|replenishment-workflow-board|4187' "$BRIEF" 2>/dev/null; then
    return 0
  fi
  return 1
}

append_jt_pr_intake_governor() {
  [ "$KIND" = ship ] || return 0
  case "$MODE" in
    direct-PR|no-mistakes) ;;
    *) return 0 ;;
  esac
  grep -qxF '<!-- firstmate:jt-pr-intake-governor:start -->' "$BRIEF" 2>/dev/null && return 0
  is_jt_pr_intake_context || return 0
  cat >> "$BRIEF" <<'EOF'

<!-- firstmate:jt-pr-intake-governor:start -->
# JT PR Intake Governor

Before implementation, write a short intake note in your working notes or report, and carry the same answers into the PR body. Answer every field:

- Problem category: Replenishment/supplier proof, Automation/PPC proof, runtime/served data, operator UX/routes, Donnees/trust cockpit, tests/contracts, docs/knowledge, OpenClaw/Firstmate tooling, or other.
- Priority (P0-P4): classify operator impact, data-risk, money-risk, and whether the problem blocks a daily decision.
- Affected surface: page, endpoint, script, source file, generated artifact, or runtime service.
- Authoritative source: exact repo file, live endpoint, report, merged PR, source CSV/export, or runtime command that proves the truth.
- Expected proof: what the operator should see after the fix, including safe_to_buy/external_action_authorized when relevant.
- Verification gate: focused test, npm script, Python test, browser/live JSON proof, or CI check required before PR.
- Duplicate/superseded check: name any earlier PR/report/problem this replaces, confirms, or intentionally leaves alone.
- Runtime data policy: source-only PR, generated-data PR, runtime-local adoption, or no runtime mutation.

If any field cannot be answered from the brief and live/repo evidence, append `needs-decision:` or `blocked:` and stop. Do not open a PR until this intake is answered.
<!-- firstmate:jt-pr-intake-governor:end -->
EOF
}

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(awk -v wanted="$id" '$1 == "-" && $2 == wanted { line = $0 } END { if (line != "") print line }' "$reg")
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
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
      # Grok 0.2.101 accepts only low|medium|high for --reasoning-effort;
      # xhigh and max are recorded in meta but omitted from the launch command.
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
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  if ! spawn_acquire_parent_home_lock "$FM_HOME"; then
    echo "error: could not acquire the parent-home spawn lock for $ID" >&2
    exit 1
  fi
  if ! spawn_acquire_home_lock "$PROJ_ABS"; then
    echo "error: could not acquire the per-home spawn lock for $ID" >&2
    exit 1
  fi
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritance propagation is separate from the tracked local-HEAD fast-forward:
  # declared local config converges into config/, while captain-shared.md converges
  # read-only into data/. Primary launch knobs remain local to the primary home.
  propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
    || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  if [ -f "$FM_HOME/$SUB_HOME_MARKER" ] && ! spawn_acquire_home_lock "$FM_HOME"; then
    echo "error: could not acquire the per-home spawn lock for $ID" >&2
    exit 1
  fi
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
SCOPE_MARKER="$DATA/$ID/scope-contract-enabled"
SCOPE_MARKER_PRESENT=0
if [ -e "$SCOPE_MARKER" ] || [ -L "$SCOPE_MARKER" ]; then
  SCOPE_MARKER_PRESENT=1
  if ! "$FM_ROOT/bin/fm-scope-contract.sh" validate-marker "$SCOPE_MARKER" >/dev/null 2>&1; then
    echo "error: invalid scope-contract marker at $SCOPE_MARKER" >&2
    exit 1
  fi
fi
if [ "$SCOPE_MARKER_PRESENT" -eq 1 ]; then
  "$FM_ROOT/bin/fm-scope-contract.sh" validate-brief "$BRIEF" || {
    echo "error: invalid scope contract in $BRIEF" >&2
    exit 1
  }
fi

if [ -z "$ARG3" ]; then
  if [ "$KIND" = secondmate ]; then
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
    ROUTE_HARNESS=$HARNESS
    ROUTE_REASON="secondmate launch uses config/secondmate-harness with config/crew-harness fallback"
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/secondmate-harness/config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
  else
    if [ -f "$CONFIG/crew-dispatch.json" ]; then
      echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules, with optional --model/--effort axes (the consultation backstop, so the rules are never silently skipped)." >&2
      exit 1
    fi
    route_out=
    if ! route_out=$("$FM_ROOT/bin/fm-route.sh" "$ID" "$PROJ_ABS" --kind "$KIND" --task-file "$BRIEF" 2>&1); then
      printf '%s\n' "$route_out" >&2
      exit 1
    fi
    parse_route_output <<EOF
$route_out
EOF
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    if [ "$HARNESS" != "$ROUTE_HARNESS" ]; then
      ROUTE_OVERRIDE=config-harness
      ROUTE_REASON="$ROUTE_REASON; launch harness overridden by config/crew-harness: $HARNESS"
    else
      [ "$MODEL_SET" -eq 1 ] || MODEL=$ROUTE_MODEL
      [ "$EFFORT_SET" -eq 1 ] || EFFORT=$ROUTE_EFFORT
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from route profile '$ROUTE_PROFILE'); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
  fi
fi

if [ "$KIND" = secondmate ]; then
  apply_secondmate_profile_config
  ROUTE_MODEL=${MODEL:-default}
  ROUTE_EFFORT=${EFFORT:-default}
fi

herdr_projection_meta_field_exact() {  # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower version 2 reclaim path.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state old_slot_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_slot_state=$(awk -F= '$1 == "slot_lease_state" { print $2; exit }' "$meta" 2>/dev/null || true)
  if [ "$old_slot_state" = unresolved ]; then
    echo "error: existing task $ID has an unresolved pooled-slot lease; reconcile its recovery record before retrying" >&2
    return 1
  fi
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
      dead|no-agent) return 0 ;;
      live|unknown)
        echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
        return 1
        ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
    dead) return 0 ;;
    alive|unknown)
      echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
}

W="fm-$ID"
if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
  if [ "$(awk -F= '$1 == "slot_returning" { print $2; exit }' "$STATE/$ID.meta" 2>/dev/null || true)" = 1 ]; then
    echo "error: existing task $ID is in the middle of a pooled-slot return; refusing duplicate launch" >&2
    exit 1
  fi
  herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
  SPAWN_RECOVERY_META_REPLACE_ALLOWED=1
fi
DISPLAY_LABEL=
TASK_KEY=
HERDR_LABEL_JOURNAL=
HERDR_LABEL_LOCK=
HERDR_LABEL_LOCK_HELD=0
HERDR_SES=
HERDR_WORKSPACE_ID=
HERDR_TAB_ID=
HERDR_PANE_ID=

cleanup_spawn_window() {
  if [ "$BACKEND" = herdr ] && [ "${HERDR_PROJECTION_ABORT_CLEANUP:-0}" = 1 ]; then
    return 0
  fi
  fm_backend_kill "$BACKEND" "$1" >/dev/null 2>&1
}

cleanup_unidentified_spawn_window() {
  local window_ids_after window_id candidate='' candidate_count=0
  window_ids_after=$(fm_backend_list_task_ids "$BACKEND" "$SES" 2>/dev/null || true)
  while IFS= read -r window_id; do
    [ -n "$window_id" ] || continue
    if ! grep -qxF "$window_id" <<<"$WINDOW_IDS_BEFORE"; then
      candidate=$window_id
      candidate_count=$((candidate_count + 1))
    fi
  done <<<"$window_ids_after"
  [ "$candidate_count" -eq 1 ] && fm_backend_kill "$BACKEND" "$candidate" >/dev/null 2>&1 || true
}

# Spawn-time isolation guard: the resolved pane path must be the root of a real
# worktree OF THE TARGET project. A different git root is not enough: a raced
# treehouse shell can briefly land in an unrelated repository, which would put
# an autonomous agent in the wrong project. Compare physical git common dirs,
# then confirm the candidate HEAD exists in the target repo.
real_path_or_raw() {  # <path>
  if [ -n "$1" ] && [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

git_common_dir_real() {  # <dir> -> physical absolute common dir, or fail
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P)
}

PROJ_ABS_REAL=$(real_path_or_raw "$PROJ_ABS")
PROJ_GIT_COMMON_REAL=
PROJ_GIT_COMMON_RESOLVED=0
proj_git_common_real() {
  if [ "$PROJ_GIT_COMMON_RESOLVED" -eq 0 ]; then
    PROJ_GIT_COMMON_REAL=$(git_common_dir_real "$PROJ_ABS" || true)
    PROJ_GIT_COMMON_RESOLVED=1
  fi
  printf '%s\n' "$PROJ_GIT_COMMON_REAL"
}

SPAWN_WT_FAIL=
spawn_worktree_check() {  # <candidate>; sets SPAWN_WT_FAIL (empty = valid)
  local candidate=$1 candidate_real worktree_root worktree_root_real
  local project_common worktree_common worktree_head guarded guarded_real
  SPAWN_WT_FAIL=
  candidate_real=$(real_path_or_raw "$candidate")
  worktree_root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)
  worktree_root_real=$(real_path_or_raw "$worktree_root")
  if [ -z "$candidate_real" ] || [ -z "$worktree_root_real" ] \
    || [ "$candidate_real" != "$worktree_root_real" ]; then
    SPAWN_WT_FAIL="resolved path is not the root of a git worktree (worktree root '${worktree_root:-none}')"
    return 0
  fi
  if [ "$candidate_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_FAIL="resolved path is the primary project checkout itself"
    return 0
  fi
  for guarded in "$FM_HOME" "$FM_ROOT"; do
    guarded_real=$(real_path_or_raw "$guarded")
    if [ "$candidate_real" = "$guarded_real" ]; then
      SPAWN_WT_FAIL="resolved path is the active operational home or Firstmate root ('$guarded_real')"
      return 0
    fi
  done
  project_common=$(proj_git_common_real)
  if [ -z "$project_common" ]; then
    SPAWN_WT_FAIL="cannot resolve the target project's git common dir from '$PROJ_ABS'"
    return 0
  fi
  worktree_common=$(git_common_dir_real "$candidate_real" || true)
  if [ "$worktree_common" != "$project_common" ]; then
    SPAWN_WT_FAIL="resolved worktree belongs to a DIFFERENT repo (its git common dir is '${worktree_common:-unresolvable}', expected '$project_common')"
    return 0
  fi
  worktree_head=$(git -C "$candidate_real" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$worktree_head" ] \
    || ! git -C "$PROJ_ABS" cat-file -e "$worktree_head^{commit}" 2>/dev/null; then
    SPAWN_WT_FAIL="worktree HEAD '${worktree_head:-unresolvable}' does not exist in the target repo"
  fi
}

worktree_of_target_repo() {  # <candidate> -> 0 iff fully valid
  spawn_worktree_check "$1"
  [ -z "$SPAWN_WT_FAIL" ]
}

validate_spawn_worktree() {  # <source> <inspect-target>
  spawn_worktree_check "$WT"
  [ -z "$SPAWN_WT_FAIL" ] || {
    {
      echo "error: $1 did not yield an isolated worktree of the target project; refusing to launch. $SPAWN_WT_FAIL"
      echo "  resolved: '$WT'"
      echo "  expected: a linked worktree of '$PROJ_ABS' (git common dir '$(proj_git_common_real)')"
      echo "  hint: a raced or stale treehouse lease, or an rc-driven cd in the pane's shell, can leave the pane cwd in an unrelated repo; inspect the pool state ('treehouse status' in the project; ~/.treehouse/*/treehouse-state.json) and target $2 before respawning. The just-created window is killed and any uncertain lease is retained in recovery metadata."
    } >&2
    cleanup_spawn_window "$WID"
    exit 1
  }
}

case "$BACKEND" in
  tmux)
    SES=$(fm_backend_container_ensure "$BACKEND" "$PROJ_ABS")
    T="$SES:$W"
    WINDOW_IDS_BEFORE=$(fm_backend_list_task_ids "$BACKEND" "$SES" 2>/dev/null || true)
    WID=$(fm_backend_create_task "$BACKEND" "$SES" "$W" "$PROJ_ABS") || exit 1
    if [[ ! "$WID" =~ ^@[0-9]+$ ]]; then
      cleanup_unidentified_spawn_window
      echo "error: tmux did not return a window id for $T" >&2
      exit 1
    fi
    if ! fm_backend_set_task_option "$BACKEND" "$WID" automatic-rename off; then
      cleanup_spawn_window "$WID" || true
      echo "error: tmux failed to disable automatic window renaming for $T" >&2
      exit 1
    fi
    if ! fm_backend_set_task_option "$BACKEND" "$WID" allow-rename off; then
      cleanup_spawn_window "$WID" || true
      echo "error: tmux failed to disable window renaming for $T" >&2
      exit 1
    fi
    if ! fm_backend_rename_task "$BACKEND" "$WID" "$W"; then
      cleanup_spawn_window "$WID" || true
      echo "error: tmux failed to restore canonical window name $T" >&2
      exit 1
    fi
    if [ "$(fm_backend_task_name "$BACKEND" "$WID")" != "$W" ]; then
      cleanup_spawn_window "$WID" || true
      echo "error: tmux did not retain canonical window name $T" >&2
      exit 1
    fi
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
    HERDR_SES=$(fm_backend_herdr_session)
    HERDR_LABEL_LOCK="$STATE/.herdr-label.lock"
    if ! fm_lock_acquire_wait "$HERDR_LABEL_LOCK"; then
      echo "error: timed out waiting for another Herdr spawn to finish reserving its display label" >&2
      exit 1
    fi
    HERDR_LABEL_LOCK_HELD=1
    HERDR_LABEL_DATA=$(fm_task_label_prepare "$STATE" "$ID" "$KIND" "$DISPLAY_TITLE" "" \
      "$DATA/backlog.md" "$HERDR_LABEL_HOME" "$HERDR_SES" "") || exit 1
    IFS=$'\t' read -r DISPLAY_LABEL TASK_KEY <<EOF
$HERDR_LABEL_DATA
EOF
    HERDR_LABEL_JOURNAL="$STATE/$ID.herdr-label"
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && [ -f "$CONFIG/herdr-presentation-spaces" ]; then
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
            "$HERDR_PARENT_LABEL" "$DISPLAY_LABEL" "$PROJ_ABS"
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
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          HERDR_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_parent_workspace_exact \
            "$HERDR_SES" "$HERDR_PARENT_LABEL" 2>/dev/null || true)
          if [ -z "$HERDR_PARENT_WORKSPACE_ID" ]; then
            echo "warning: herdr presentation parent is absent or ambiguous; using the ordinary flat layout without projection" >&2
            spawn_herdr_presentation_order_lock_release
          else
            HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
            HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
            if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
              "$PROJ_ABS" "$HERDR_PROJECTION_LABEL" "$DISPLAY_LABEL"; then
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
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL"
            HERDR_HOME_ID=$(fm_backend_herdr_projection_home_identity "$HERDR_LABEL_HOME" 2>/dev/null || true)
            if [ -n "$HERDR_HOME_ID" ] \
               && fm_backend_herdr_projection_live_binding_matches \
                 "$HERDR_SES" "$HERDR_PROJECTION_ID" "$HERDR_WORKSPACE_ID" \
                 "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$HERDR_PARENT_WORKSPACE_ID" \
                 "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$DISPLAY_LABEL" \
               && fm_backend_herdr_projection_journal_bind \
                 "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_HOME_ID" "$HERDR_SES" \
                 "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
                 "$HERDR_PARENT_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$DISPLAY_LABEL"; then
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
      HERDR_FLAT_LABEL_DATA=$(fm_task_label_prepare "$STATE" "$ID" "$KIND" "$DISPLAY_TITLE" "" \
        "$DATA/backlog.md" "$HERDR_LABEL_HOME" "$HERDR_SES" "$HERDR_WORKSPACE_ID") || exit 1
      [ "$HERDR_FLAT_LABEL_DATA" = "$HERDR_LABEL_DATA" ] || {
        echo "error: Herdr display-label binding changed before tab creation" >&2
        exit 1
      }
      if ! HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$DISPLAY_LABEL" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID"); then
        case "$HERDR_TASK_IDS" in
          cleanup-required$'\t'*)
            HERDR_FLAT_ABORT_CLEANUP=1
            HERDR_FLAT_ABORT_TARGET=${HERDR_TASK_IDS#*$'\t'}
            ;;
          cleanup-uncertain$'\t'*)
            IFS=$'\t' read -r _ HERDR_FLAT_ABORT_SCOPE HERDR_FLAT_ABORT_LABEL <<EOF
$HERDR_TASK_IDS
EOF
            HERDR_FLAT_ABORT_UNCERTAIN=1
            ;;
        esac
        exit 1
      fi
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
      if [ -n "$HERDR_PANE_ID" ]; then
        HERDR_FLAT_ABORT_CLEANUP=1
        HERDR_FLAT_ABORT_TARGET="$HERDR_SES:$HERDR_PANE_ID"
      fi
    fi
    HERDR_BOUND_LABEL_DATA=$(fm_task_label_prepare "$STATE" "$ID" "$KIND" "$DISPLAY_TITLE" "" \
      "$DATA/backlog.md" "$HERDR_LABEL_HOME" "$HERDR_SES" "$HERDR_WORKSPACE_ID") || exit 1
    [ "$HERDR_BOUND_LABEL_DATA" = "$HERDR_LABEL_DATA" ] || {
      echo "error: Herdr display-label binding changed during spawn" >&2
      exit 1
    }
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: Herdr did not return a tab/pane id for $DISPLAY_LABEL" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    WID="$T"
    ;;
esac
SPAWN_ENDPOINT_CREATED=1
spawn_settle_path() {  # <target>
  local record lease_path
  SPAWN_WORKTREE_PATH=
  SPAWN_WORKTREE_PATH_SOURCE=
  record=$(fm_agent_cwd_verdict "" "$BACKEND" "$1")
  if [ "$(fm_agent_verdict_field "$record" source)" = proc ]; then
    SPAWN_WORKTREE_PATH_SOURCE=proc
    SPAWN_WORKTREE_PATH=$(fm_agent_verdict_field "$record" cwd)
    return 0
  fi
  lease_path=$(cat "${SPAWN_WORKTREE_LEASE_PROOF:-}" 2>/dev/null || true)
  if [ -n "$lease_path" ]; then
    SPAWN_WORKTREE_PATH_SOURCE=lease
    SPAWN_WORKTREE_PATH=$lease_path
    return 0
  fi
  SPAWN_WORKTREE_PATH_SOURCE=hint
  SPAWN_WORKTREE_PATH=$(fm_backend_current_path "$BACKEND" "$1" 2>/dev/null || true)
}

if [ "$KIND" != secondmate ]; then
  SPAWN_WORKTREE_LEASE_PROOF="$STATE/.$ID.spawn-worktree"
  rm -f "$SPAWN_WORKTREE_LEASE_PROOF"
  TREEHOUSE_LEASE_COMMAND=$(fm_worker_treehouse_lease_command "$ID" "$SPAWN_WORKTREE_LEASE_PROOF") || exit 1
  SPAWN_WORKTREE_LEASED=1
  fm_backend_send_text_line "$BACKEND" "$WID" "$TREEHOUSE_LEASE_COMMAND" || exit 1
  spawn_abort_recovery_meta || {
    echo "error: could not persist a recovery record for the pooled lease held by $ID; refusing to continue" >&2
    exit 1
  }

  # Prefer the live process cwd through /proc. Provider pane cwd remains a hint
  # where no process id is available.
  # Accept a pane cwd only once it passes the complete target-repo check. A
  # transient foreign cwd is retained only for the eventual diagnostic.
  WT_CANDIDATE=
  for _ in $(seq 1 "${FM_SPAWN_WT_WAIT_SECS:-60}"); do
    spawn_settle_path "$WID"
    p=$SPAWN_WORKTREE_PATH
    if [ "$SPAWN_WORKTREE_PATH_SOURCE" = hint ]; then
      [ -z "$p" ] || WT_CANDIDATE="$p"
      sleep 1
      continue
    fi
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" != "$PROJ_ABS_REAL" ]; then
      WT_CANDIDATE="$p"
      if worktree_of_target_repo "$p"; then
        WT="$p"
        case "$SPAWN_WORKTREE_PATH_SOURCE" in
          proc|lease) SPAWN_WORKTREE_PROVEN=1 ;;
        esac
        break
      fi
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within ${FM_SPAWN_WT_WAIT_SECS:-60}s; inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

# Per-task temp root with Go's build temp nested at gotmp/.
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-$ID.XXXXXX") || exit 1
chmod 700 "$TASK_TMP" || { rm -rf -- "$TASK_TMP"; exit 1; }
TASK_TMP_OWNER="$TASK_TMP/.fm-tasktmp-owner"
printf 'task=%s\npath=%s\n' "$ID" "$TASK_TMP" > "$TASK_TMP_OWNER" || {
  rm -rf -- "$TASK_TMP"
  exit 1
}
chmod 600 "$TASK_TMP_OWNER" || { rm -rf -- "$TASK_TMP"; exit 1; }
mkdir "$TASK_TMP/gotmp" || { rm -rf -- "$TASK_TMP"; exit 1; }
chmod 700 "$TASK_TMP/gotmp" || { rm -rf -- "$TASK_TMP"; exit 1; }

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  spawn_create_new_artifact "$TURNEND" SPAWN_TURNEND_INODE SPAWN_TURNEND_DIGEST SPAWN_TURNEND_CREATED </dev/null || exit 1
  case "$HARNESS" in
    claude*)
      spawn_preflight_real_directory_path "$WT/.claude" || exit 1
      spawn_ensure_real_directory_path "$WT/.claude" || exit 1
      spawn_create_new_artifact "$WT/.claude/settings.local.json" SPAWN_CLAUDE_HOOK_INODE SPAWN_CLAUDE_HOOK_DIGEST SPAWN_CLAUDE_HOOK_CREATED <<EOF || exit 1
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      spawn_preflight_real_directory_path "$WT/.opencode/plugins" || exit 1
      spawn_ensure_real_directory_path "$WT/.opencode/plugins" || exit 1
      spawn_create_new_artifact "$WT/.opencode/plugins/fm-turn-end.js" SPAWN_OPENCODE_HOOK_INODE SPAWN_OPENCODE_HOOK_DIGEST SPAWN_OPENCODE_HOOK_CREATED <<EOF || exit 1
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
      spawn_create_new_artifact "$STATE/$ID.pi-ext.ts" SPAWN_PI_EXT_INODE SPAWN_PI_EXT_DIGEST SPAWN_PI_EXT_CREATED <<EOF || exit 1
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
      # grok fires a Stop hook at every turn boundary (see the harness-adapters
      # skill for verification), the
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
      GROK_HOME_DIR="${GROK_HOME:-$HOME/.grok}"
      case "$GROK_HOME_DIR" in
        /*) ;;
        *) exit 1 ;;
      esac
      case "$GROK_HOME_DIR" in
        *$'\n'*|*$'\r'*) exit 1 ;;
      esac
      GROK_HOOKS_DIR="$GROK_HOME_DIR/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      GROK_HOOK_SCRIPT="$GROK_HOOKS_DIR/fm-turn-end.sh"
      GROK_HOOK_CONFIG="$GROK_HOOKS_DIR/fm-turn-end.json"
      SPAWN_GROK_HOOK_FILE=$GROK_HOOK_SCRIPT
      SPAWN_GROK_CONFIG_FILE=$GROK_HOOK_CONFIG
      spawn_preflight_real_directory_path "$GROK_HOME_DIR" || exit 1
      spawn_preflight_real_directory_path "$GROK_HOOKS_DIR" || exit 1
      spawn_preflight_real_directory_path "$GROK_AUTH_DIR" || exit 1
      spawn_ensure_real_directory_path "$GROK_HOME_DIR" || exit 1
      spawn_ensure_real_directory_path "$GROK_HOOKS_DIR" || exit 1
      spawn_ensure_real_directory_path "$GROK_AUTH_DIR" || exit 1
      GROK_HOME_DIR=$(cd "$GROK_HOME_DIR" && pwd -P) || exit 1
      GROK_HOOKS_DIR=$(cd "$GROK_HOOKS_DIR" && pwd -P) || exit 1
      GROK_AUTH_DIR=$(cd "$GROK_AUTH_DIR" && pwd -P) || exit 1
      GROK_HOOK_SCRIPT="$GROK_HOOKS_DIR/fm-turn-end.sh"
      GROK_HOOK_CONFIG="$GROK_HOOKS_DIR/fm-turn-end.json"
      SPAWN_GROK_HOOK_FILE=$GROK_HOOK_SCRIPT
      SPAWN_GROK_CONFIG_FILE=$GROK_HOOK_CONFIG
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      GROK_HOOK_BODY="$TASK_TMP/grok-turn-end.sh"
      GROK_CONFIG_BODY="$TASK_TMP/grok-turn-end.json"
      cat > "$GROK_HOOK_BODY" <<EOF
#!/usr/bin/env bash
set -u
FM_FIRSTMATE_GROK_HOOK=1
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
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOK_SCRIPT")")
      cat > "$GROK_CONFIG_BODY" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$hook_command"}]}]}}
EOF
      spawn_artifact_matches_or_absent "$GROK_HOOK_SCRIPT" "$GROK_HOOK_BODY" || exit 1
      spawn_artifact_matches_or_absent "$GROK_HOOK_CONFIG" "$GROK_CONFIG_BODY" || exit 1
      spawn_artifact_proof_available "$GROK_AUTH_DIR" || exit 1
      old_umask=$(umask)
      umask 077
      auth_tmp=$(mktemp "$GROK_AUTH_DIR/.fm-artifact.XXXXXXXXXXXX") || exit 1
      auth_suffix=${auth_tmp##*.}
      auth_file="$GROK_AUTH_DIR/fm.$auth_suffix"
      SPAWN_GROK_AUTH_TMP=$auth_tmp
      SPAWN_GROK_AUTH_FILE=$auth_file
      SPAWN_GROK_AUTH_PROVISIONAL=1
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_tmp" || { spawn_discard_grok_auth_provisional || true; exit 1; }
      SPAWN_GROK_AUTH_INODE=$(spawn_artifact_inode "$auth_tmp") || { spawn_discard_grok_auth_provisional || true; exit 1; }
      SPAWN_GROK_AUTH_DIGEST=$(spawn_artifact_digest "$auth_tmp") || { spawn_discard_grok_auth_provisional || true; exit 1; }
      if ! ln "$auth_tmp" "$auth_file" 2>/dev/null; then
        spawn_discard_grok_auth_provisional || true
        exit 1
      fi
      SPAWN_GROK_AUTH_CREATED=1
      [ -f "$auth_file" ] && [ ! -L "$auth_file" ] || { rm -f -- "$auth_tmp"; exit 1; }
      rm -f -- "$auth_tmp" || exit 1
      SPAWN_GROK_AUTH_TMP=
      SPAWN_GROK_AUTH_PROVISIONAL=0
      spawn_create_new_artifact "$STATE/$ID.grok-turnend-token" SPAWN_GROK_TOKEN_INODE SPAWN_GROK_TOKEN_DIGEST SPAWN_GROK_TOKEN_CREATED <<EOF || exit 1
token=${auth_file##*/}
dir=$GROK_AUTH_DIR
inode=$SPAWN_GROK_AUTH_INODE
digest=$SPAWN_GROK_AUTH_DIGEST
EOF
      spawn_create_or_reuse_artifact "$GROK_HOOK_SCRIPT" \
        SPAWN_GROK_HOOK_CREATED SPAWN_GROK_HOOK_INODE SPAWN_GROK_HOOK_DIGEST \
        < "$GROK_HOOK_BODY" || exit 1
      spawn_create_or_reuse_artifact "$GROK_HOOK_CONFIG" \
        SPAWN_GROK_CONFIG_CREATED SPAWN_GROK_CONFIG_INODE SPAWN_GROK_CONFIG_DIGEST \
        < "$GROK_CONFIG_BODY" || exit 1
      spawn_create_new_artifact "$WT/.fm-grok-turnend" SPAWN_GROK_POINTER_INODE SPAWN_GROK_POINTER_DIGEST SPAWN_GROK_POINTER_CREATED <<EOF || exit 1
token=${auth_file##*/}
EOF
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

append_jt_pr_intake_governor
append_route_block
# Soft CBM orientation for allowlisted ship/scout projects only (no-op if CBM
# off/missing). Secondmate charters stay free of CBM policy text.
if [ "$KIND" != secondmate ]; then
  fm_cbm_append_brief_policy "$BRIEF" "$PROJ_ABS" "$KIND" || true
fi

mkdir -p "$STATE"
# Record current ownership in the linked worktree's private git directory.
# Metadata is historical; teardown uses this stamp as independent evidence.
# A seeded secondmate home may be a plain directory rather than a pooled git
# worktree. Ordinary task workers must always have a stamp; linked secondmate
# homes get the same proof when a pooled slot is actually involved.
if [ -n "${WT:-}" ] && fm_slot_stamp_path "$WT" >/dev/null 2>&1; then
  if ! fm_slot_lock_acquire "$WT"; then
    echo "error: could not serialize pooled-slot ownership for $ID; refusing to publish task state or launch" >&2
    exit 1
  fi
  SPAWN_SLOT_LOCK_PATH=$FM_SLOT_LOCK_PATH
  SPAWN_SLOT_LOCK_HELD=1
  if ! fm_slot_stamp_write "$WT" "$ID" "$(real_path_or_raw "$FM_HOME")" 2>/dev/null; then
    if fm_slot_stamp_record "$WT" >/dev/null 2>&1; then
      echo "error: could not prove pooled-slot ownership for $ID: slot $WT is already stamped for task '$FM_SLOT_STAMP_TASK' in home '$FM_SLOT_STAMP_HOME', not $ID in $(real_path_or_raw "$FM_HOME"); refusing to publish task state or launch" >&2
    else
      echo "error: could not prove pooled-slot ownership for $ID: the ownership stamp for slot $WT could not be written or read back; refusing to publish task state or launch" >&2
    fi
    echo "error: a slot whose stamp outlived its task poisons every spawn that draws it - reclaim it per docs/worker-isolation.md (confirm the stamped task is gone, then clear the stamp) before respawning $ID" >&2
    exit 1
  fi
  SPAWN_SLOT_STAMPED=1
elif [ "$KIND" != secondmate ]; then
  echo "error: could not prove pooled-slot ownership for $ID: ${WT:-<no worktree>} is not a linked worktree with a private git dir, so no ownership stamp can be recorded; refusing to publish task state or launch" >&2
  echo "error: docs/worker-isolation.md owns the reclaim procedure for a pooled slot that cannot be stamped" >&2
  exit 1
fi
META_TMP=$(mktemp "$STATE/.$ID.meta.XXXXXX") || exit 1
chmod 600 "$META_TMP" || { rm -f "$META_TMP"; exit 1; }
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "route_profile=$ROUTE_PROFILE"
  echo "route_harness=$ROUTE_HARNESS"
  echo "route_model=$ROUTE_MODEL"
  echo "route_effort=$ROUTE_EFFORT"
  echo "route_reason=$ROUTE_REASON"
  echo "route_override=$ROUTE_OVERRIDE"
  echo "route_risk_flags=$ROUTE_RISK_FLAGS"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # Missing backend= is the compatibility spelling for tmux. Record only
  # non-default backends so existing and new tmux metadata stay unchanged.
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  [ -z "${GROK_AUTH_DIR:-}" ] || echo "grok_registry_dir=$GROK_AUTH_DIR"
  [ -z "${SPAWN_GROK_AUTH_FILE:-}" ] || echo "grok_registry_token=${SPAWN_GROK_AUTH_FILE##*/}"
  if [ "${SPAWN_CLAUDE_HOOK_CREATED:-0}" = 1 ]; then
    echo "claude_hook_inode=$SPAWN_CLAUDE_HOOK_INODE"
    echo "claude_hook_digest=$SPAWN_CLAUDE_HOOK_DIGEST"
  fi
  if [ "${SPAWN_OPENCODE_HOOK_CREATED:-0}" = 1 ]; then
    echo "opencode_hook_inode=$SPAWN_OPENCODE_HOOK_INODE"
    echo "opencode_hook_digest=$SPAWN_OPENCODE_HOOK_DIGEST"
  fi
  if [ "$BACKEND" = herdr ]; then
    echo "display_label=$DISPLAY_LABEL"
    echo "task_key=$TASK_KEY"
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$META_TMP" || { rm -f "$META_TMP"; exit 1; }
mv "$META_TMP" "$STATE/$ID.meta" || { rm -f "$META_TMP"; exit 1; }
SPAWN_META_PUBLISHED=1
if [ "$BACKEND" = herdr ]; then
  rm -f "$HERDR_LABEL_JOURNAL"
  if [ "$HERDR_LABEL_LOCK_HELD" = 1 ]; then
    spawn_release_label_lock || echo "warning: $ID launched but its Herdr label lock $HERDR_LABEL_LOCK could not be released; the exit cleanup will retry" >&2
  fi
fi

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
if [ "$KIND" = secondmate ]; then
  WORKER_HOME=$PROJ_ABS
  WORKER_ROLE=secondmate
else
  WORKER_HOME=$(real_path_or_raw "$FM_HOME")
  WORKER_ROLE=crewmate
fi
WORKER_ENV_PREFIX=$(fm_worker_launch_env_prefix "$WORKER_ROLE" "$ID" "$WORKER_HOME") || {
  echo "error: could not build the home declaration for $ID; refusing to launch a task child that would inherit this home" >&2
  exit 1
}
LAUNCH="$WORKER_ENV_PREFIX$LAUNCH"
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
sq_gotmpdir=$(shell_quote "$TASK_TMP/gotmp")
fm_backend_send_text_line "$BACKEND" "$WID" "export GOTMPDIR=$sq_gotmpdir"
sleep 0.3
# Soft CBM env for orientation tools/CLI (cache + resource caps + PATH).
# Also prefix the launch command so the agent process itself inherits CBM even
# if a later pane export is missed. Missing CBM is a no-op.
if [ "$KIND" != secondmate ] && fm_cbm_project_eligible "$PROJ_ABS" \
  && fm_cbm_prepare_environment 2>/dev/null \
  && cbm_prefix=$(fm_cbm_launch_env_prefix_prepared 2>/dev/null); then
  # Pane-level exports for shell tools the agent may run later.
  cbm_cache=$FM_CBM_RESOLVED_CACHE
  cbm_mem=$FM_CBM_RESOLVED_MEM
  cbm_workers=$FM_CBM_RESOLVED_WORKERS
  cbm_path_prefix=$FM_CBM_RESOLVED_PATH_PREFIX
  # FM_CBM_TASK_ID tags usage.jsonl lines from fm-cbm-cli.sh for this task.
  # FM_CBM_CLI points agents at the logged CLI wrapper when they shell out.
  cbm_cli_wrap=$(shell_quote "$FM_ROOT/bin/fm-cbm-cli.sh")
  fm_backend_send_text_line "$BACKEND" "$WID" "export CBM_CACHE_DIR=$(shell_quote "$cbm_cache") CBM_MEM_BUDGET_MB=$(shell_quote "$cbm_mem") CBM_WORKERS=$(shell_quote "$cbm_workers") FM_CBM_TASK_ID=$(shell_quote "$ID") FM_CBM_CLI=$cbm_cli_wrap FM_HOME=$(shell_quote "$FM_HOME") PATH=$(shell_quote "$cbm_path_prefix"):\"\$PATH\""
  sleep 0.2
  LAUNCH="${cbm_prefix}${LAUNCH}"
fi
fm_backend_send_literal "$BACKEND" "$WID" "$LAUNCH"
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
fi
HERDR_FLAT_ABORT_CLEANUP=0
fm_backend_send_key "$BACKEND" "$WID" Enter

  # The launch has already been sent, so this is past the point of no return.
  # A failed release of an advisory lock changes no ownership evidence and must
  # never trigger the abort cleanup, which would kill the window, force-return
  # the slot, and delete the published meta of a task that launched fine.
  if [ "$SPAWN_SLOT_LOCK_HELD" = 1 ]; then
    SPAWN_SLOT_LOCK_HELD=0
    fm_slot_lock_release "$SPAWN_SLOT_LOCK_PATH" \
      || echo "warning: $ID launched but its pooled-slot ownership lock $SPAWN_SLOT_LOCK_PATH could not be released; clear the stale lock file manually" >&2
  fi
if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
  spawn_herdr_presentation_order_lock_release
fi
if [ "$SPAWN_HOME_LOCK_HELD" = 1 ]; then
  spawn_release_home_lock \
    || echo "warning: $ID launched but its per-home spawn lock $SPAWN_HOME_LOCK could not be released; the exit cleanup will retry" >&2
fi
if [ "$SPAWN_PARENT_HOME_LOCK_HELD" = 1 ]; then
  spawn_release_parent_home_lock \
    || echo "warning: $ID launched but its parent-home spawn lock $SPAWN_PARENT_HOME_LOCK could not be released; the exit cleanup will retry" >&2
fi
if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
  spawn_release_task_lock \
    || echo "warning: $ID launched but its task lock $SPAWN_TASK_LOCK could not be released; the exit cleanup will retry" >&2
fi
if [ "$HERDR_LABEL_LOCK_HELD" = 0 ] \
   && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 0 ] \
   && [ "$SPAWN_HOME_LOCK_HELD" = 0 ] \
   && [ "$SPAWN_PARENT_HOME_LOCK_HELD" = 0 ] \
   && [ "$SPAWN_TASK_LOCK_HELD" = 0 ]; then
  trap - EXIT
fi

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
