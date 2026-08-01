#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--provider <claude|codex|grok>] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--provider <claude|codex|grok>] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --provider records the subscription provider selected for a dispatch profile.
#   --backend <name> is the explicit runtime session-provider backend for this
#   exact task only (docs/configuration.md "Runtime backend" owns when that flag
#   is authorized). Without it, the script resolves FM_BACKEND, then
#   config/backend, then runtime auto-detection from the runtime firstmate's
#   environment: $TMUX, HERDR_ENV=1, or cmux runtime signals (via
#   bin/fm-backend.sh's fm_backend_detect, with cmux fallback details in
#   docs/cmux-backend.md),
#   then tmux.
#   For every backend except orca, firstmate leases the task worktree itself with
#   `treehouse get --lease`, run under a HOME that puts the pool on the repo's own
#   filesystem (bin/fm-treehouse-lib.sh owns why that HOME is the only lever), and
#   then sends the pane a plain cd. The lease is durable, so fm-teardown.sh returning
#   the worktree is what frees the pool slot; a spawn that fails before publishing
#   state/<id>.meta returns its own lease.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns acquire no treehouse lease and firstmate
#   cannot place their worktree - a split from the object store is reported, not
#   refused; cmux is a session provider only, exactly like herdr/zellij, so it
#   leases like the rest. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   A herdr crewmate or scout is placed in the exact workspace of the firstmate
#   or secondmate process launching it, resolved from that process's own herdr
#   pane rather than from a workspace label (herdr enforces no label uniqueness,
#   so a label cannot tell two "firstmate" workspaces apart). A claimed parent
#   identity that is unreadable, contradictory, stale, or from another herdr
#   session stops the spawn before any worker endpoint exists. A launcher
#   outside herdr has no workspace to inherit and uses this home's own labeled
#   workspace, which must then match exactly one. --secondmate is the deliberate
#   exception: it stands up that secondmate home's own workspace.
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
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|cline|cursor-agent|copilot|agy)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters. pi-signed launches that exact executable name from PATH and
#   refuses before endpoint creation when it is unavailable; it never falls back to pi.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--provider/--model/--effort/--backend applies to every pair.
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
#     __OPINPUT__   absolute path to the canonical operational-input encoder
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
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
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$SCRIPT_DIR/fm-treehouse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
PROVIDER=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
PROVIDER_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      provider) PROVIDER=$a; PROVIDER_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
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
    --provider) want_value=provider ;;
    --provider=*) PROVIDER=${a#--provider=}; PROVIDER_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$PROVIDER_SET" -eq 0 ] || [ -n "$PROVIDER" ] || { echo "error: --provider requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac
case "$PROVIDER" in
  ''|claude|codex|grok) ;;
  *) echo "error: --provider must be one of claude, codex, grok" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
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
TREEHOUSE_LEASE_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0

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

spawn_abort_cleanup() {
  local status=$? herdr_pane_close_refused=0
  # The projection pane close must run BEFORE the lease return below: under the
  # leased flow the pane's top-level shell has cwd in the worktree, so
  # `treehouse return --force` kills that shell and Herdr's last-pane cleanup
  # destroys the workspace and steals focus before the exact-pane close could
  # restore it (same ordering fm-teardown.sh enforces on the normal path).
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
      herdr_pane_close_refused=1
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
  # A treehouse lease is durable: unlike the old interactive `treehouse get`, the
  # pool slot is NOT freed when the pane dies. If this spawn fails before the task
  # exists in state/, teardown will never run for it, so the lease has to come back
  # here or the slot is held with nothing to release it. The one exception is a
  # refused pane close above: returning then would kill the still-live pane and
  # steal focus, so the slot is left with the exact recovery command instead.
  if [ "$TREEHOUSE_LEASE_ABORT_CLEANUP" = 1 ]; then
    TREEHOUSE_LEASE_ABORT_CLEANUP=0
    if [ -n "${WT:-}" ] && [ -n "${PROJ_ABS:-}" ]; then
      if [ "$herdr_pane_close_refused" = 1 ]; then
        echo "warning: leased worktree $WT was not returned because its herdr pane is still open; close the pane, then run 'HOME=${POOL_HOME:-<pool-home>} treehouse return --force $WT' from $PROJ_ABS to free the pool slot" >&2
      else
        fm_treehouse_return "$PROJ_ABS" "$WT" >/dev/null 2>&1 \
          || echo "warning: could not return the leased worktree $WT; run 'HOME=${POOL_HOME:-<pool-home>} treehouse return --force $WT' from $PROJ_ABS to free the pool slot" >&2
      fi
    fi
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
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
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
  [ -z "$PROVIDER" ] || shared_args+=(--provider "$PROVIDER")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
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
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi|cline|cursor-agent|copilot|agy)
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
# (busy-state source, exit command, dialogs, quirks) lives in the harness-adapters skill.
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi|pi-signed)
      if [ "$kind" = secondmate ]; then
        printf '%s%s' "$harness" ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s%s' "$harness" ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # cline (Cline CLI 3.0.46): `-i --tui` opens the persistent interactive TUI and
    # a positional prompt seeds AND auto-runs the first turn (verified via tmux
    # capture; see docs/verification/cline-adapter.md). --auto-approve true keeps the
    # unattended crewmate autonomous (the targeted equivalent of claude's
    # --dangerously-skip-permissions; it is on by default but passed explicitly for
    # version robustness). Turn-end is observed by the pane classifier (the braille
    # "esc to cancel" spinner clears and the composer returns to its idle
    # placeholder), so no launch-side turn-end placeholder is needed. Effort maps to
    # --thinking (see the effort helper below), never --effort.
    cline) printf '%s' 'cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # cursor-agent (Cursor CLI 2026.07): the default `agent` is a persistent interactive
    # TUI; a positional prompt seeds AND auto-runs the first turn (verified via tmux
    # capture) once the workspace is trusted. --force ("Run Everything") makes the
    # crewmate autonomous (equivalent of claude's --dangerously-skip-permissions). Effort
    # is a MODEL bracket param (e.g. 'claude-opus-4-8[effort=high]'), not a flag, so no
    # __EFFORTFLAG__. WORKSPACE TRUST: interactive mode shows a blocking "Workspace Trust
    # Required" dialog that --trust does NOT bypass (headless-only). fm-spawn clears it
    # with both verified bypasses (harness-adapters skill +
    # docs/verification/cursor-agent-adapter.md): the per-harness setup below pre-seeds
    # ~/.cursor/projects/<slug>/.workspace-trusted before launch, and the post-launch
    # readiness gate answers a residual dialog with `a` (covering the undocumented
    # long-path slug variant), failing the spawn loudly instead of hanging on the dialog.
    cursor-agent) printf '%s' 'cursor-agent --force __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # copilot (GitHub Copilot CLI 1.0.75): `-i <prompt>` ("Start interactive mode
    # and automatically execute this prompt") seeds AND auto-runs the first turn
    # once the folder-trust dialog is cleared (verified via tmux capture; see
    # docs/verification/copilot-adapter.md) - the same argv-seed pattern as
    # claude/codex/cline/cursor-agent, not kimi's bare-launch+inject. `--allow-all`
    # (== --yolo; the non-jargon spelling is used for diff legibility) is the
    # targeted equivalent of claude's --dangerously-skip-permissions. `--no-ask-user`
    # additionally disables the ask_user tool: a live test with a deliberately
    # underspecified brief did NOT stall without it, but it is included anyway as a
    # zero-downside defensive flag - there is no attended human to answer ask_user
    # in a supervised crewmate pane. Turn-end is observed by the pane classifier (the
    # `Working.*esc interrupt` busy footer clears and the composer returns to its
    # bare `❯` idle glyph), so no launch-side turn-end placeholder is needed. Effort
    # maps to --reasoning-effort (see the effort helper below), accepting the full
    # shared low|medium|high|xhigh|max vocabulary with no tier omitted.
    # FOLDER TRUST: a genuinely fresh worktree is never on copilot's persistent
    # allow-list, so the blocking "Confirm folder trust" dialog above appears on
    # every launch into it, and no CLI flag bypasses it (--allow-all/--allow-all-*
    # and the untested --add-dir were all probed and disproved - see
    # docs/verification/copilot-adapter.md "Trust / permission gate"). fm-spawn
    # clears it with a post-launch readiness gate ONLY: while the dialog is present,
    # send a single default-focus Enter (session-scoped trust, "Yes"); once the pane
    # reaches the busy footer or idle status bar, proceed; on budget exhaustion, fail
    # the spawn loudly (copilot_spawn_fail). Deliberately NO pre-seed of that
    # allow-list, unlike cursor-agent's per-project marker: copilot's only pre-seed
    # target is a single shared, global, credential-bearing JSONC config file, with
    # no delegated writer and no config-dir override to isolate it - the
    # keystroke-only mechanism gets the same guarantee with zero writes to the
    # operator's home (see copilot_wait_for_trust_clear below for the full
    # reasoning).
    copilot) printf '%s' 'copilot --allow-all --no-ask-user __MODELFLAG____EFFORTFLAG__-i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # agy (Antigravity CLI 1.1.9): `-i` / `--prompt-interactive` seeds AND
    # auto-runs the first turn once the project-trust dialog is cleared
    # (verified via tmux capture; docs/verification/agy-adapter.md) - the same
    # argv-seed pattern as claude/codex/cline/cursor-agent/copilot, not kimi's
    # bare-launch+inject. `--dangerously-skip-permissions` is the autonomy flag
    # (auto-approves tool permission prompts); it does NOT bypass the project
    # trust dialog. MODEL/EFFORT: agy lists effort-baked model ids
    # (`gemini-3.6-flash-low|medium|high`) AND a separate `--effort
    # low|medium|high` flag. A bare base model (e.g. `gemini-3.6-flash`)
    # REQUIRES `--effort`; a baked suffix alone works; matching baked+effort
    # works; conflicting baked+effort fails closed with a clear error. firstmate
    # therefore passes both axes when set: preferred form is base model +
    # `--effort`, and full effort-baked model ids also work when no effort axis
    # is supplied (or when it matches). Ceiling is `high`; omit xhigh/max rather
    # than passing a known-bad value. Turn-end is observed from the pane (the
    # `esc to cancel` busy footer clears and the composer returns to `? for
    # shortcuts`), so no launch-side turn-end placeholder is needed.
    # PROJECT TRUST: a genuinely fresh worktree shows a blocking "Do you trust
    # the contents of this project?" dialog (`Yes, I trust this folder` /
    # `No, exit`). `--dangerously-skip-permissions` does not bypass it.
    # Accepting "Yes" persists the path into
    # `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` (verified).
    # fm-spawn clears it with a post-launch readiness gate ONLY: while the
    # dialog is present, send one default-focus Enter; once the pane reaches
    # the busy footer or idle shortcuts bar, proceed; on budget exhaustion,
    # fail the spawn loudly (agy_spawn_fail). Deliberately NO pre-seed of
    # trustedWorkspaces: that file also holds permission allow-lists and is
    # operator-global, with no delegated writer - the keystroke-only mechanism
    # gets the same guarantee with zero writes to the operator's home.
    agy) printf '%s' 'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__-i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # only an absolute brief pointer after the TUI readiness gate below.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task worktree token, so no launch placeholder belongs here.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
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

case "$HARNESS" in
  pi|pi-signed) LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH" ;;
esac

case "$HARNESS" in
  kimi)
    [ -z "$PROVIDER" ] || { echo "error: Kimi cannot carry a subscription routing provider" >&2; exit 1; }
    ;;
  claude|codex|grok)
    [ -z "$PROVIDER" ] || [ "$PROVIDER" = "$HARNESS" ] || { echo "error: native harness $HARNESS requires provider $HARNESS" >&2; exit 1; }
    ;;
esac

# pi-signed is an explicitly selected executable identity, not an alias that may
# silently fall back to pi. Resolve it from PATH before creating an endpoint and
# retain the literal name in the launch command and task metadata.
if [ "$HARNESS" = pi-signed ] && ! command -v pi-signed >/dev/null 2>&1; then
  echo "error: pi-signed executable not found on PATH; install the signed Pi wrapper or select a different verified harness" >&2
  exit 1
fi

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

secondmate_registry_value() {
  secondmate_registry_field "$DATA/secondmates.md" "$1" "$2"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolve_kimi_binary() {
  local candidate dir fallback
  candidate=$(command -v kimi 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s\n' "$candidate"; return 0 ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        if [ -n "$dir" ]; then
          printf '%s/%s\n' "$dir" "$(basename "$candidate")"
          return 0
        fi
        ;;
    esac
  fi
  fallback="${HOME:-}/.kimi-code/bin/kimi"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'" >&2
  return 1
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cline|cursor-agent|copilot|agy)
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
    pi|pi-signed)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    cline)
      # cline 3.0.46 maps the reasoning-effort axis to --thinking, which accepts
      # none|low|medium|high|xhigh (verified in `cline --help`; a live launch with
      # `--thinking high` showed "(high)" in the model status bar). It has no `max`
      # tier, so omit max rather than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    copilot)
      # copilot 1.0.75 accepts --effort, --reasoning-effort <level> with the
      # FULLEST vocabulary of any adapter: none|minimal|low|medium|high|xhigh|max
      # (verified via --help AND a zero-quota pre-flight validation probe:
      # `--reasoning-effort bogus-tier` was rejected with exit 1 before any API
      # call, listing exactly those seven choices). firstmate's shared axis
      # (low|medium|high|xhigh|max) is a full subset, so all five tiers pass
      # through - no tier needs omitting, unlike cline (no max) or codex/grok
      # (lower ceilings). --reasoning-effort (long form) is used over the
      # --effort alias for greppability, matching codex's spelling convention.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    agy)
      # agy 1.1.9 accepts --effort low|medium|high (verified via --help and live
      # conflict probes; docs/verification/agy-adapter.md "Model and effort").
      # xhigh and max are not accepted, so omit them rather than passing a
      # known-bad value. When the model id already ends in -low/-medium/-high,
      # a matching --effort is accepted and a conflicting --effort fails closed
      # at launch with a clear agy error - firstmate does not rewrite model ids.
      case "$effort" in
        low|medium|high) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command.
  esac
}

case "$LAUNCH" in
  *__KIMIBIN__*)
    KIMI_BIN=$(resolve_kimi_binary) || exit 1
    LAUNCH=${LAUNCH//__KIMIBIN__/$(shell_quote "$KIMI_BIN")}
    if [ "$KIND" != secondmate ]; then
      "$FM_ROOT/bin/fm-kimi-turnend-hook.sh" install || {
        echo "error: refusing Kimi spawn because the global turn-end hook could not be installed safely" >&2
        exit 1
      }
    fi
    ;;
esac

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
  if [ -e "$DATA/secondmates.md" ] || [ -L "$DATA/secondmates.md" ]; then
    if ! secondmate_registry_validate_bindings "$DATA/secondmates.md" resolve_path "$ID" "$FIRSTMATE_HOME"; then
      echo "error: $SECONDMATE_REGISTRY_ERROR" >&2
      exit 1
    fi
    SECONDMATE_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
  fi
  WT="$PROJ_ABS"
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
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
    echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  fi
  CONFIG_INHERIT_LOCK_HELD=1
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into this secondmate home (fm-config-inherit-lib.sh).
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
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
BRIEF_DIR_REAL=$(cd "$(dirname "$BRIEF")" && pwd -P)
BRIEF_REAL="$BRIEF_DIR_REAL/$(basename "$BRIEF")"

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

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# A worktree split from its object store cannot run the validation pipeline at
# all: git blocks in read_gitfile_gently and `no-mistakes init`/`axi run` hang
# forever (bin/fm-treehouse-lib.sh owns the full explanation). Refuse the spawn
# instead of launching a crew that is guaranteed to wedge hours later, on the one
# path firstmate places itself. An undeterminable answer is not a violation.
assert_worktree_colocated() {  # <worktree> <pool-home>
  local wt=$1 pool_home=$2 status=0
  fm_treehouse_worktree_colocated "$wt" || status=$?
  if [ "$status" = 1 ]; then
    echo "error: worktree $wt (filesystem $FM_TREEHOUSE_WT_DEVICE) is on a different filesystem than its object store $FM_TREEHOUSE_STORE (filesystem $FM_TREEHOUSE_STORE_DEVICE); the validation pipeline would hang in that worktree, so refusing to launch. Firstmate selected pool root $pool_home/.treehouse; a treehouse.toml in the repo root overrides that." >&2
    exit 1
  fi
  return 0
}

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
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
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
    #
    # Placement, separately from labeling: a crewmate/scout belongs in the
    # EXACT herdr workspace this launching process is itself running in, which
    # only its own herdr pane identity can name (a same-labeled sibling
    # workspace must never be adopted). A --secondmate launch is the exception -
    # it stands up a DIFFERENT home's own workspace by design - so it asks for
    # the per-home container instead of inheriting this launcher's.
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_LAUNCHER_RELATIONSHIP=launcher-home
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
      HERDR_LAUNCHER_RELATIONSHIP=other-home
    fi
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && [ -f "$CONFIG/herdr-presentation-spaces" ]; then
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
            *) spawn_herdr_presentation_order_lock_release; exit 1 ;;
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
            if [ -n "$HERDR_HOME_ID" ] \
               && fm_backend_herdr_projection_live_binding_matches \
                 "$HERDR_SES" "$HERDR_PROJECTION_ID" "$HERDR_WORKSPACE_ID" \
                 "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$HERDR_PARENT_WORKSPACE_ID" \
                 "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W" \
               && fm_backend_herdr_projection_journal_bind \
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
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS" "$HERDR_LAUNCHER_RELATIONSHIP") || exit 1
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
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    # Orca owns its own worktree placement - `orca worktree create` takes no root
    # or path argument - so firstmate cannot put this one on the object store's
    # filesystem the way it does for a treehouse pool. Report a split rather than
    # refusing: the crew can still ship through direct-PR or local-only, and this
    # is pre-existing Orca behavior, not something this spawn introduced.
    ORCA_COLOCATED_STATUS=0
    fm_treehouse_worktree_colocated "$WT" || ORCA_COLOCATED_STATUS=$?
    if [ "$ORCA_COLOCATED_STATUS" = 1 ]; then
      echo "warning: orca placed worktree $WT (filesystem $FM_TREEHOUSE_WT_DEVICE) on a different filesystem than its object store $FM_TREEHOUSE_STORE (filesystem $FM_TREEHOUSE_STORE_DEVICE); the no-mistakes validation pipeline will hang in that worktree. Use a delivery mode that does not run it, or configure Orca to place worktrees on the repo's filesystem." >&2
    fi
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
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

kimi_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

kimi_capture_has_empty_composer() {  # <plain-pane-capture>
  printf '%s\n' "$1" \
    | grep -Eq '^[[:space:]]*(│|┃|\|)[[:space:]]*>[[:space:]]*(│|┃|\|)[[:space:]]*$'
}

kimi_wait_for_ready() {
  local pane i=0 max=${FM_KIMI_READY_POLLS:-60} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    if printf '%s\n' "$pane" | grep -Fq 'Welcome to Kimi Code!' \
       || kimi_capture_has_empty_composer "$pane"; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_delivery_is_confirmed() {  # <plain-pane-capture>
  local pane=$1
  kimi_capture_has_empty_composer "$pane" || return 1
  if { printf '%s\n' "$pane" | grep -Fq '✨' \
       && printf '%s\n' "$pane" | grep -Fq 'Read the brief at'; } \
     || printf '%s\n' "$pane" \
       | grep -qiE 'context:[[:space:]]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[[:space:]]*%'; then
    return 0
  fi
  return 1
}

kimi_wait_for_delivery() {
  local pane i=0 max=${FM_KIMI_DELIVERY_POLLS:-40} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    kimi_delivery_is_confirmed "$pane" && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

cursor_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

cursor_trust_dialog_present() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Fq 'Workspace Trust Required'
}

# Past the trust gate: the idle composer placeholder (→-prefixed, verified) or
# the mid-turn busy anchor (the seeded positional brief auto-runs the moment
# trust clears, so the pane may go straight to Working / "ctrl+c to stop").
cursor_pane_is_past_trust() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Eq '→ (Plan, search, build anything|Add a follow-up)|ctrl\+c to stop'
}

# Clear cursor-agent's blocking workspace-trust dialog. The pre-seeded
# .workspace-trusted marker normally skips it entirely; when the dialog still
# appears (e.g. cursor's length-capped slug variant for very long worktree
# paths), answer it ONCE with the verified `a` keypress and keep polling.
# `a` is sent at most once: after trust clears, a repeat keypress would land
# in the composer as stray text. A pane that never reaches a ready/working
# signal within the poll budget is a failed spawn, not a silent hang.
cursor_wait_for_trust_clear() {
  local pane i=0 max=${FM_CURSOR_TRUST_POLLS:-60} interval=${FM_CURSOR_POLL_INTERVAL:-0.5} answered=0
  while [ "$i" -lt "$max" ]; do
    pane=$(cursor_capture)
    # Test the POSITIVE past-trust anchor FIRST: cursor's TUI never clears the
    # 'Workspace Trust Required' frame from the terminal scrollback, so the
    # dialog literal stays in every capture FOREVER with the live conversation
    # rendering below it. Checking dialog_present first would make this elif
    # success branch unreachable, exhaust the poll budget, and report a false
    # failure while a trusted, working agent runs unsupervised. Only when the
    # pane is NOT yet past the gate does the dialog-present branch fire and send
    # the one-shot `a` keypress.
    if cursor_pane_is_past_trust "$pane"; then
      return 0
    elif cursor_trust_dialog_present "$pane"; then
      if [ "$answered" -eq 0 ]; then
        spawn_send_literal "$T" a
        answered=1
      fi
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

cursor_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

copilot_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

copilot_trust_dialog_present() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Fq 'Confirm folder trust'
}

# Past the trust gate: EITHER the busy footer (the seeded `-i` prompt
# auto-runs the instant trust clears, per docs/verification/copilot-adapter.md
# "Launch", so the pane normally goes straight to busy) OR the idle status
# bar. Deliberately NOT the bare idle-composer glyph (U+276F): the trust
# dialog's own option cursor renders with that exact same codepoint
# (docs/verification/copilot-adapter.md "Trust / permission gate"), so a
# bare-glyph anchor would match the dialog itself and report "past trust"
# while it is still up (T3 has a dedicated regression fence for this). The
# busy literal is necessarily duplicated from FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT
# (bin/fm-tmux-lib.sh) because fm-spawn.sh does not source fm-tmux-lib.sh; a
# drift fence (T3.4) pins the two together. The `\?` in the idle alternate is
# mandatory - unescaped it is an ERE quantifier and silently stops matching a
# literal `?`.
copilot_pane_is_past_trust() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Eq 'Working.*esc interrupt|/ commands · \? help'
}

# Clear copilot's blocking folder-trust dialog. There is deliberately NO
# pre-seed of copilot's persistent trust allow-list here (unlike cursor's
# per-harness setup below): that allow-list lives in a single shared, global
# JSONC config file that also holds the operator's live OAuth credential, has
# no delegated writer (`copilot config` is a help topic, not a mutating
# subcommand) and no config-directory override to isolate a test copy - so
# any pre-seed write path would have to satisfy atomicity, byte-for-byte
# header preservation, and concurrency-safety forever, on every dispatch, for
# a benefit ("maybe skip a dialog this poll already handles") that does not
# justify the risk to a credential. See docs/verification/copilot-adapter.md
# "Trust / permission gate" (options analysis) for the full reasoning. This
# keystroke-only mechanism therefore never opens, reads, or writes that
# file at all: zero blast radius on the operator's home, by construction.
#
# Default focus on the dialog is option 1 ("Yes", session-scoped trust,
# verified) so a single Enter clears it; answered at most once (S7) - a
# repeat Enter after trust clears would land in the composer as stray text.
copilot_wait_for_trust_clear() {
  local pane i=0 max=${FM_COPILOT_TRUST_POLLS:-60} interval=${FM_COPILOT_POLL_INTERVAL:-0.5} answered=0
  while [ "$i" -lt "$max" ]; do
    pane=$(copilot_capture)
    if copilot_trust_dialog_present "$pane"; then
      if [ "$answered" -eq 0 ]; then
        spawn_send_key "$T" Enter
        answered=1
      fi
    elif copilot_pane_is_past_trust "$pane"; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

copilot_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

agy_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

agy_trust_dialog_present() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Fq 'Do you trust the contents of this project?'
}

# Past the trust gate: EITHER the busy footer (`esc to cancel`, the seeded `-i`
# prompt auto-runs the instant trust clears) OR the idle shortcuts bar
# (`? for shortcuts`). Deliberately NOT "Antigravity CLI" - that literal also
# appears inside the trust dialog ("Antigravity CLI requires permission..."),
# so it would report past-trust while the dialog is still up. The `\?` in the
# idle alternate is mandatory - unescaped it is an ERE quantifier.
agy_pane_is_past_trust() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Eq 'esc to cancel|\? for shortcuts'
}

# Clear agy's blocking project-trust dialog. There is deliberately NO pre-seed
# of ~/.gemini/antigravity-cli/settings.json trustedWorkspaces: that file also
# holds permission allow-lists, has no delegated writer, and is operator-global.
# A single Enter accepts the default-focus "Yes, I trust this folder" (verified
# to persist the path and proceed); answered at most once so a repeat Enter
# after trust clears does not land as stray composer text. See
# docs/verification/agy-adapter.md "Trust / permission gate".
agy_wait_for_trust_clear() {
  local pane i=0 max=${FM_AGY_TRUST_POLLS:-60} interval=${FM_AGY_POLL_INTERVAL:-0.5} answered=0
  while [ "$i" -lt "$max" ]; do
    pane=$(agy_capture)
    if agy_trust_dialog_present "$pane"; then
      if [ "$answered" -eq 0 ]; then
        spawn_send_key "$T" Enter
        answered=1
      fi
    elif agy_pane_is_past_trust "$pane"; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

agy_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  # Firstmate acquires the worktree itself rather than sending `treehouse get` to
  # the pane, because the pool has to land on the repo's own filesystem and the
  # only way to select it is the HOME treehouse runs under (bin/fm-treehouse-lib.sh
  # owns why). An interactive `treehouse get` opens the crew's shell as a child of
  # treehouse, so that HOME would be inherited by the agent and by everything it
  # runs - wrong ~/.claude, wrong git config, wrong gh credentials. Leasing here
  # keeps the override inside this process: the pane only ever receives a plain cd.
  # The lease's own `git fetch` still needs the real git and gh config, which that
  # same substitution hides, so fm_treehouse_preserve_user_config pins them first.
  #
  # The lease is durable, so every exit path between here and metadata publication
  # must return it; TREEHOUSE_LEASE_ABORT_CLEANUP arms spawn_abort_cleanup for that.
  # fm-teardown.sh already returns the worktree by absolute path on the normal path.
  POOL_HOME=$(fm_treehouse_pool_home "$PROJ_ABS") || exit 1
  LEASE_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-spawn-lease-err.XXXXXXXX")
  WT=$( cd "$PROJ_ABS" && fm_treehouse_preserve_user_config && HOME="$POOL_HOME" treehouse get --lease --lease-holder "fm-$ID" 2>"$LEASE_ERR_FILE" ) || {
    echo "error: treehouse could not lease a worktree for $PROJ_ABS under pool root $POOL_HOME/.treehouse" >&2
    [ ! -s "$LEASE_ERR_FILE" ] || sed 's/^/  treehouse: /' "$LEASE_ERR_FILE" >&2
    rm -f "$LEASE_ERR_FILE"
    exit 1
  }
  rm -f "$LEASE_ERR_FILE"
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    echo "error: treehouse returned no usable worktree path for $PROJ_ABS (got '${WT:-}')" >&2
    exit 1
  fi
  TREEHOUSE_LEASE_ABORT_CLEANUP=1

  validate_spawn_worktree "treehouse get --lease" "$T"
  assert_worktree_colocated "$WT" "$POOL_HOME"

  # Move the pane into the leased worktree. `cd` is the one instruction every
  # supported pane shell understands identically, which matters because the shell
  # is the operator's, not ours.
  spawn_send_text_line "$WT_TARGET" "cd $(shell_quote "$WT")"

  # Confirm the pane really landed there before anything is launched into it.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # The expected path is known exactly now, so - unlike the old "any path that is
  # not the project" wait - a transient stale pane_current_path (seen live on some
  # tmux/WSL setups as another real git checkout entirely) can never be mistaken
  # for arrival. Compare physically: a symlinked prefix would otherwise never match.
  WT_REAL=$(real_path_or_raw "$WT")
  landed=0
  SETTLE_POLLS=${FM_SPAWN_SETTLE_POLLS:-60}
  for _ in $(seq 1 "$SETTLE_POLLS"); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" = "$WT_REAL" ]; then
      landed=1
      break
    fi
    sleep 1
  done
  if [ "$landed" -ne 1 ]; then
    echo "error: pane did not enter the leased worktree $WT within 60s; inspect window $T" >&2
    exit 1
  fi
fi

# Per-task temp root: /tmp/fm-<uid>-<id>/ with Go's build temp nested at gotmp/.
# Go won't create GOTMPDIR, so mkdir before it is used; fm-teardown removes the
# whole root (reading the path this spawn recorded as tasktmp=, so changing the
# shape here never orphans an already-running task's temp).
# Nested (not a bare .../gotmp) so other per-task temp can live alongside later,
# and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
#
# The uid is part of the path for the same reason the herdr presentation lock
# namespace carries one (fm_backend_herdr_presentation_lock_namespace): task ids
# are not unique across operators, so on a multi-operator box a uid-less
# /tmp/fm-<id> is created by whoever spawns that id first and is then owned by
# them outright. Every other operator's mkdir silently lands in a directory it
# cannot write, and teardown's rm -rf fails with EACCES.
TASK_TMP_UID=$(id -u 2>/dev/null || true)
case "$TASK_TMP_UID" in
  ''|*[!0-9]*) TASK_TMP_UID=nouid ;;
esac
TASK_TMP="/tmp/fm-$TASK_TMP_UID-$ID"
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
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  # Arm the semantic busy-state contract (bin/fm-busy-lib.sh) for every
  # adapter with a verified semantic source. The launch brief sent below IS a
  # submitted turn, so the seed record is busy/fm-spawn. The minted gen is
  # embedded into each adapter's wiring so an event from a superseded
  # incarnation is rejected as stale. Grok stays on its isolated rendered-tail
  # fallback and standalone Kimi stays unknown until fm_busy_kimi_verified
  # opens, so neither is armed here.
  BUSY_GEN=
  case "$HARNESS" in
    codex*)
      if fm_busy_codex_semantic_source; then
        echo "error: codex semantic busy-state wiring is not implemented; extend the probe only together with verified wiring" >&2
        exit 1
      fi
      ;;
  esac
  case "$HARNESS" in
    claude*|opencode*|pi|pi-signed)
      BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
        echo "error: failed to arm the busy-state contract for $ID" >&2
        exit 1
      }
      ;;
    kimi*)
      # Standalone Kimi stays unknown until fm_busy_kimi_verified opens on a
      # live-verified installed version (bin/fm-busy-lib.sh owns the gate and
      # the required evidence). Arming without wiring would seed a busy record
      # nothing can ever clear, so the arm waits for the wiring.
      if fm_busy_kimi_verified; then
        echo "error: kimi semantic busy-state wiring is not implemented; open the gate only together with verified wiring" >&2
        exit 1
      fi
      ;;
  esac
  case "$HARNESS" in
    claude*)
      # Semantic busy-state hooks (bin/fm-busy-lib.sh): UserPromptSubmit opens
      # a turn; Stop (normal completion), StopFailure (API-error turn end),
      # and SessionEnd (process shutdown) all close it, so an abnormal end can
      # never leave a stale busy record. Claude fires no hook for a manual
      # interrupt, so the firstmate-controlled interruption procedure
      # (harness-adapters) records idle/fm-interrupt itself. Stop keeps the
      # turn-ended NOTIFICATION touch for the watcher. Every hook command
      # tolerates a refused event (|| true) so a stale-gen writer can never
      # break Claude's own lifecycle.
      mkdir -p "$WT/.claude"
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source claude-hook"
      j_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true")
      j_stop=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
      j_stopfail=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event stop-failure 2>/dev/null || true")
      j_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$j_submit"}]}],"Stop":[{"hooks":[{"type":"command","command":"$j_stop"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$j_stopfail"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$j_sessionend"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-busy-state.js" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID;
        const statusType = event.properties.status && event.properties.status.type;
        if (statusType === "busy" || statusType === "retry") {
          if (activeSession === null) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
          return;
        }
        if (statusType === "idle" && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-status-idle");
        }
        return;
      }
      if (event.type === "session.idle") {
        if (event.properties.sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-idle");
        }
        await new Promise((resolve) => {
          execFile("touch", ["$TURNEND"], () => resolve());
        });
      }
    },
  };
};
EOF
      exclude_path '.opencode/plugins/fm-busy-state.js'
      ;;
    pi|pi-signed)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
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
}
EOF
      ;;
    codex*)
      # Semantic busy-state source negotiation (bin/fm-busy-lib.sh owns the
      # probes and the evidence). Neither Codex path is usable on the
      # installed binary: a pane worker's turns are not observable through
      # the app-server protocol, and its lifecycle hooks did not fire for a
      # firstmate-launched worker. Codex therefore classifies unknown with
      # an explicit reason rather than falling back to idle, and no busy
      # wiring is installed. The turn-end NOTIFICATION marker still rides
      # the launch command via -c notify=[...] and __TURNEND__.
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
    kimi*)
      # Kimi's Stop hook is global, but it is inert unless cwd contains this
      # task's token pointer and the token resolves through Firstmate's private
      # registry. The installer above owns the format-preserving config edit and
      # the always-zero, silent hook script.
      KIMI_AUTH_DIR="$HOME/.kimi-code/fm-turn-end.d"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$KIMI_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.kimi-turnend-token"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-kimi-turnend"
      exclude_path '.fm-kimi-turnend'
      ;;
    cursor-agent)
      # Workspace-trust pre-seed (verified bypass, docs/verification/
      # cursor-agent-adapter.md): a pre-existing .workspace-trusted marker makes
      # cursor-agent skip the blocking interactive trust dialog entirely. The
      # slug is the worktree abspath with the leading / dropped and every /
      # replaced by -; the length-capped+hash variant cursor uses for very long
      # paths is not reproduced here, so the post-launch readiness gate below
      # still answers a residual dialog with `a`. An existing marker is kept
      # (its recorded trustedAt stays authoritative).
      CURSOR_PROJECT_DIR="${CURSOR_HOME:-$HOME/.cursor}/projects/$(printf '%s' "${WT#/}" | tr '/' '-')"
      if [ ! -f "$CURSOR_PROJECT_DIR/.workspace-trusted" ]; then
        mkdir -p "$CURSOR_PROJECT_DIR"
        printf '{"trustedAt":"%s","workspacePath":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$(json_escape "$WT")" \
          > "$CURSOR_PROJECT_DIR/.workspace-trusted"
      fi
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  : "${SECONDMATE_PROJECTS:=}"
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  [ -z "$PROVIDER" ] || echo "provider=$PROVIDER"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
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
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0
# The task now exists in state/, so fm-teardown.sh owns returning its worktree.
# Returning it from here after this point would pull the lease out from under a
# live task.
TREEHOUSE_LEASE_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
# Crewmate panes are created by a long-lived tmux/herdr daemon that does not
# inherit firstmate's current environment, so a bare `claude` in the pane falls
# back to the default ~/.claude store even when firstmate itself runs under a
# different CLAUDE_CONFIG_DIR (for example a work-vs-personal subscription split).
# Forward firstmate's own resolved store onto the claude launch so the crewmate
# uses the same credential/config firstmate is authenticated with. Only when set;
# an unset value is the single-store default and needs no prefix.
if [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fi
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  sq_primary_home=$(shell_quote "$FM_HOME")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$sq_primary_home FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
spawn_send_key "$T" Enter
if [ "$HARNESS" = cursor-agent ]; then
  if ! cursor_wait_for_trust_clear; then
    cursor_spawn_fail "cursor-agent did not clear the workspace-trust gate to a ready or working pane"
    exit 1
  fi
fi
if [ "$HARNESS" = copilot ]; then
  if ! copilot_wait_for_trust_clear; then
    copilot_spawn_fail "copilot did not clear the folder-trust gate to a ready or working pane"
    exit 1
  fi
fi
if [ "$HARNESS" = agy ]; then
  if ! agy_wait_for_trust_clear; then
    agy_spawn_fail "agy did not clear the project-trust gate to a ready or working pane"
    exit 1
  fi
fi
if [ "$HARNESS" = kimi ]; then
  if ! kimi_wait_for_ready; then
    kimi_spawn_fail "kimi did not show a verified ready signal before brief delivery"
    exit 1
  fi
  KIMI_POINTER="Read the brief at $BRIEF_REAL and follow it exactly."
  KIMI_SUBMIT_RETRIES=${FM_KIMI_SUBMIT_RETRIES:-3}
  KIMI_SUBMIT_SLEEP=${FM_KIMI_SUBMIT_SLEEP:-${FM_KIMI_POLL_INTERVAL:-0.5}}
  KIMI_SUBMIT_SETTLE=${FM_KIMI_SUBMIT_SETTLE:-0}
  KIMI_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
    "$BACKEND" "$T" "$KIMI_POINTER" "$KIMI_SUBMIT_RETRIES" \
    "$KIMI_SUBMIT_SLEEP" "$KIMI_SUBMIT_SETTLE" "$W") || {
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  }
  if [ "$KIMI_SUBMIT_VERDICT" = send-failed ]; then
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  fi
  if ! kimi_wait_for_delivery; then
    kimi_spawn_fail "kimi brief pointer delivery was not confirmed"
    exit 1
  fi
fi
if [ "$KIND" = secondmate ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"
