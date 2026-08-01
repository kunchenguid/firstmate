#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--launch <variant>] [--backend <name>] [--scout]
#        fm-spawn.sh --host <name> <task-id> <project-name-on-host> [--harness <name>] [--model <name>] [--effort <level>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--launch <variant>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --launch <variant> selects a NAMED LAUNCH VARIANT declared under
#   config/harness-overrides.json .[<harness>].variants.[<variant>]. A variant changes
#   only how the resolved harness starts (its binary, launch args, and launch env); it
#   never changes WHICH harness runs, so the recorded harness= and every supervision
#   fact keep applying. Variant choice is always explicit - an explicit --launch, then
#   the dispatch profile's launch field, then .[<harness>].default_variant - and is
#   never inferred from quota or any other runtime signal. Naming a variant the
#   resolved harness does not declare is a hard spawn refusal, never a silent fallback.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   Herdr additionally supports a default-off presentation-only layout when the
#   local config/herdr-presentation-spaces flag exists. A clean fresh task first
#   writes state/<id>.herdr-presentation atomically, then creates a disposable
#   workspace containing only the ordinary task pane. The journal and visible
#   random token are never endpoint or ownership authority. Existing, ambiguous,
#   or recovered state is never adopted, reused, closed, or deleted through that
#   presentation path; a flat launch is allowed only after duplicate-agent risk
#   is independently absent. Treehouse allocation and task metadata are unchanged.
#   A clean projected create makes one bounded attempt to hold the one
#   session-scoped presentation-order lock (keyed by named session plus
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
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok|traex)
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
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so its OWN crewmates, dispatch profiles, backlog backend, and
#   per-harness launch overrides inherit primary config, while the secondmate
#   receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --host <name> dispatches the task to a REMOTE task host registered in
#   config/relay-hosts.json instead of running it here. The second positional
#   argument is then the PROJECT NAME under that host's own projects directory,
#   not a local path. The host runs its own bin/fm-spawn.sh over the Bifrost
#   relay, so the worktree assertion, harness launch, and trust dialog are all
#   handled on that machine; this side records the returned metadata plus host=
#   and returns. Arm the wake path afterwards with bin/fm-relay-check-make.sh,
#   because a remote crewmate's status file and turn-end marker live on ITS
#   machine and this home's signal scan cannot see them. --host is mutually
#   exclusive with --secondmate, --backend, and --launch, and WITHOUT --host not
#   one byte of the local path changes (bin/fm-relay-host.sh, docs/relay-host.md).
#   Exit 3 means a GUI-capable host declined for a reason that passes - locked
#   screen, no desktop host session, or asleep and unable to answer. The task is
#   NOT live and NOT lost: it is queued and its wake check is armed here, so it
#   dispatches on its own once that machine can take it (docs/relay-gui-host.md).
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
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __ENV__      built-in launch env prefix, MERGED with config/harness-overrides.json .[<harness>].env
#     __CMD__      built-in binary, replaced by config/harness-overrides.json .[<harness>].command
#     __ARGS__     built-in launch args, replaced by config/harness-overrides.json .[<harness>].args
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex and traex
#                  -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#   config/harness-overrides.json (LOCAL, gitignored) customizes only __ENV__/__CMD__/__ARGS__
#   per harness; firstmate always owns the model/effort flags, the brief injection, and the
#   turn-end hook (resolve_launch_overrides; full contract in docs/configuration.md). With no
#   such file the assembled launch string is byte-identical to the built-in template.
#   A named variant under .[<harness>].variants layers over that harness's own three axes,
#   per axis: command and args replace, env merges with the variant winning. With no variant
#   selected the assembled launch string is byte-identical to the pre-variant one.
#     __PIBRIEFENV__ shell assignment identifying the unchanged Pi positional brief
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> [launch=<variant>] kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# launch= appears only when a named launch variant was selected.
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
# After metadata is durable, ship and scout spawns also ask tasks-axi to move the
# matching backlog row to In flight. A missing row or failed write is loud but
# never rolls back a live launch - state/<id>.meta remains the runtime record.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,102p' "$0" | sed 's/^# \{0,1\}//'
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
# Optional LOCAL (gitignored) per-harness launch override file; see
# docs/configuration.md and resolve_launch_overrides.
HARNESS_OVERRIDES="$CONFIG/harness-overrides.json"
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-remote-preflight-lib.sh
. "$SCRIPT_DIR/fm-remote-preflight-lib.sh"
# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# A machine that is not the control plane of its fleet may not start work
# anywhere - here or on a peer. Silent and free on a home that declared no
# fleet, which is every single-machine home (bin/fm-helm-lib.sh).
fm_helm_assert "$FM_HOME" "starting a task" || exit 1
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HOST_ARG=
LAUNCH_VARIANT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
HOST_SET=0
LAUNCH_SET=0
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
      host) HOST_ARG=$a; HOST_SET=1 ;;
      launch) LAUNCH_VARIANT=$a; LAUNCH_SET=1 ;;
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
    --host) want_value=host ;;
    --host=*) HOST_ARG=${a#--host=}; HOST_SET=1 ;;
    --launch) want_value=launch ;;
    --launch=*) LAUNCH_VARIANT=${a#--launch=}; LAUNCH_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$HOST_SET" -eq 0 ] || [ -n "$HOST_ARG" ] || { echo "error: --host requires a non-empty value" >&2; exit 1; }
[ "$LAUNCH_SET" -eq 0 ] || [ -n "$LAUNCH_VARIANT" ] || { echo "error: --launch requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# --host dispatches the whole spawn to a REMOTE task host over the Bifrost relay
# and returns before any local machinery runs. That ordering is the compatibility
# contract: with no --host, not one byte of the path below changes, exactly like
# the backend= rule further down. The remote host executes its OWN
# bin/fm-spawn.sh, so the worktree-isolation assertion, the harness launch, and
# the trust-dialog handling all happen locally over there rather than being
# reimplemented across the link (bin/fm-relay-host.sh, docs/relay-host.md).
if [ "$HOST_SET" -eq 1 ]; then
  [ "$KIND" != secondmate ] || { echo "error: --host does not support --secondmate spawns" >&2; exit 1; }
  [ "$BACKEND_SET" -eq 0 ] || { echo "error: --backend selects a LOCAL session provider and cannot combine with --host" >&2; exit 1; }
  [ "$LAUNCH_SET" -eq 0 ] || { echo "error: --launch names a local launch variant and cannot combine with --host" >&2; exit 1; }
  [ "${#POS[@]}" -ge 2 ] || { echo "error: --host needs <task-id> <project-name-on-host>" >&2; exit 1; }
  HOST_ID=${POS[0]}
  # Same task-id gate as the local path below, deliberately identical in check,
  # message, and exit code. A remote task still gets a state/<id>.meta here, so a
  # dot-leading name would write a HIDDEN record that every "$STATE"/*.meta glob
  # skips, leaving a live remote task nothing on this side can find or steer.
  fm_task_id_creation_valid "$HOST_ID" || { echo "error: invalid task id" >&2; exit 2; }
  HOST_PROJECT=${POS[1]}
  host_spawn_args=("$HOST_ARG" "$HOST_ID" "$HOST_PROJECT")
  [ "$KIND" = scout ] && host_spawn_args+=(--scout)
  [ -z "$HARNESS_ARG" ] || host_spawn_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || host_spawn_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || host_spawn_args+=(--effort "$EFFORT")
  host_rc=0
  host_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-relay-host.sh" spawn "${host_spawn_args[@]}") || host_rc=$?
  # Exit 3 means the host declined for a reason that passes - a GUI host whose
  # screen is locked, whose desktop host session is down, or that is asleep and
  # could not answer at all. The dispatch is held rather than lost, and the wake
  # check is armed HERE rather than left to a later step: a queued dispatch with
  # no check would sit forever, since retrying it is the check's whole job. When
  # it takes, the same check reverts to reporting the task's events.
  if [ "$host_rc" -eq 3 ]; then
    printf '%s\n' "$host_out"
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-relay-check-make.sh" "$HOST_ID" >/dev/null 2>&1; then
      printf 'queued on %s: %s will dispatch by itself once that machine can take it\n' \
        "$HOST_ARG" "$HOST_ID"
    else
      echo "error: $HOST_ID is queued for $HOST_ARG but arming its retry failed; it will NOT dispatch on its own" >&2
      exit 1
    fi
    exit 3
  fi
  if [ "$host_rc" -ne 0 ]; then
    # A failure waiting will not fix, reported synchronously to whoever ran this
    # and with no retry armed. Clearing the queued record here is what stops it
    # becoming a leak: nothing would ever pick it up, and `queued` would list a
    # dispatch that is going nowhere. A refusal that DOES pass is exit 3 above,
    # and that one is kept and retried.
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-relay-host.sh" cancel "$HOST_ID" >/dev/null 2>&1 || true
    exit 1
  fi
  printf '%s\n' "$host_out"
  # Same durable backlog transition the local path makes below; a failure here is
  # reported, never fatal, because the task is already live on the host.
  if [ -f "$DATA/backlog.md" ] && command -v tasks-axi >/dev/null 2>&1; then
    (cd "$FM_HOME" && tasks-axi start "$HOST_ID" --file "$DATA/backlog.md" >/dev/null 2>&1) \
      || echo "warning: $HOST_ID is live on $HOST_ARG but data/backlog.md was not moved to In progress" >&2
  fi
  printf 'spawned on %s: %s (arm its wake path with bin/fm-relay-check-make.sh %s)\n' \
    "$HOST_ARG" "$HOST_ID" "$HOST_ID"
  exit 0
fi

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
  local status=$?
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
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
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  [ -z "$LAUNCH_VARIANT" ] || shared_args+=(--launch "$LAUNCH_VARIANT")
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
    ''|claude|codex|opencode|pi|grok|traex)
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

# The verified launch command per adapter, expressed as a template with three
# OVERRIDABLE axes and a firstmate-OWNED tail. The overridable axes are the launch
# env prefix (__ENV__), the binary (__CMD__), and the default launch/autonomy args
# (__ARGS__); config/harness-overrides.json can replace command and args and merge
# env per harness (resolve_launch_overrides below; full contract in
# docs/configuration.md). The tail - the model/effort flags and the brief
# injection ("$(cat __BRIEF__)", plus the harness-specific turn-end wiring like
# codex's -c notify=/__TURNEND__ and pi's -e __PIEXT__) - is fixed here and is
# never reachable by an override, which is what preserves supervision. __ENV__ and
# __ARGS__ each expand to their content plus one trailing space, or to empty; the
# one literal space after __CMD__ separates the binary from what follows. The
# knowledge half of each adapter (busy signature, exit command, dialogs, quirks)
# lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    claude) printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__"$(cat __BRIEF__)"'
      else
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    traex)
      # traex (TRAE CLI 2.0) is a codex fork and takes codex's exact shape.
      # CREWMATE: the brief is the positional PROMPT and -c notify=[...] is the
      # turn-end signal. notify= is used instead of a [[hooks.Stop]] entry because
      # traex's claude-style hooks are gated behind a per-hook-command persisted
      # trust hash, and an untrusted hook is silently ignored - a per-task turn-end
      # command would hash differently every task and fail open. notify= is not
      # trust-gated and fires unprompted (verified 2026-07-17, traex 0.200.13).
      # SECONDMATE: no notify, exactly like codex. A secondmate runs a firstmate
      # home whose checkout carries tracked .trae/hooks.json, so its own primary
      # turn-end guard rides that Stop hook (verified full block loop, scout
      # traex-parity-study-n7 §4.3), and its watcher uses the traex foreground
      # checkpoint (docs/supervision-protocols/traex.md). First launch in a new
      # secondmate home shows TWO dialogs - directory trust, then a hooks-review
      # "Trust all" (default, single Enter) - after which the fixed hook hashes stay
      # trusted; see the harness-adapters and secondmate-provisioning skills.
      if [ "$kind" = secondmate ]; then
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__"$(cat __BRIEF__)"'
      else
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' '__ENV____CMD__ __MODELFLAG____ARGS__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__PIBRIEFENV__ __ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' '__PIBRIEFENV__ __ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    grok) printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

# Built-in defaults for the three overridable launch axes, keyed by harness. They
# are kind-independent (only the fixed tail differs by kind). These are kept
# byte-for-byte equal to the historical inline templates, so with no
# config/harness-overrides.json the assembled launch string is unchanged.
harness_default_command() {
  case "$1" in
    claude) printf '%s' 'claude' ;;
    codex) printf '%s' 'codex' ;;
    opencode) printf '%s' 'opencode' ;;
    pi) printf '%s' 'pi' ;;
    grok) printf '%s' 'grok' ;;
    # MUST be traex. `traecli`, `trae-cli`, `trae-agent`, `coco`, and `ta` are the
    # OLD coco 1.0 agent on a box that kept the 1.0 install - a different agent
    # whose supervision facts firstmate has never verified. Launching one of those
    # names would silently supervise the wrong agent.
    traex) printf '%s' 'traex' ;;
  esac
}

# grok's --always-approve auto-approves every tool execution (verified: the
# crewmate runs fully autonomously), the targeted equivalent of claude's
# --dangerously-skip-permissions. opencode and pi carry no default launch args:
# opencode's autonomy rides its env (OPENCODE_CONFIG_CONTENT) and pi needs none.
harness_default_args() {
  case "$1" in
    claude) printf '%s' '--dangerously-skip-permissions' ;;
    codex) printf '%s' '--dangerously-bypass-approvals-and-sandbox' ;;
    grok) printf '%s' '--always-approve' ;;
    # traex's -y is the same flag name codex uses, spelled short. Verified against
    # a control on 2026-07-17: under an identical restrictive config, a write was
    # SandboxDenied without -y and succeeded with it.
    traex) printf '%s' '-y' ;;
    *) : ;;
  esac
}

# Built-in launch env, one shell KEY=value assignment per line (the value already
# quoted as it must appear on the launch line). CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
# disables claude's interactive predicted-next-prompt ghost text, which renders as
# dim text in an otherwise-empty composer and would otherwise read like real typed
# input when firstmate captures the pane (see the harness-adapters skill; the CLI's
# --prompt-suggestions flag is print/SDK-mode only and does NOT suppress the
# interactive ghost text). It is a per-launch prefix scoped to this
# firstmate-launched agent and never touches the captain's global config; the
# dim-aware composer reader in fm-tmux-lib.sh is the defense-in-depth backstop.
# opencode's env grants blanket tool permission for the unattended run.
harness_default_env_pairs() {
  case "$1" in
    claude) printf '%s\n' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' ;;
    opencode) printf '%s\n' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\''' ;;
    *) : ;;
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
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
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
    claude|codex|opencode|pi|grok|traex)
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
    traex)
      # Same config key as codex, and the binary's own parser is authoritative:
      # `-c model_reasoning_effort='"max"'` is rejected with
      # "unknown variant `max`, expected one of `none`, `minimal`, `low`,
      # `medium`, `high`, `xhigh`" (verified 2026-07-17, traex 0.200.13). Omit max
      # rather than passing a known-bad value that would abort the launch.
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
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
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

# Shared jq prelude for the override file. Binds $h0 to the harness-level override
# object and $v0 to the selected variant object ({} when no variant is selected),
# so every axis lookup below reads the same two layers.
# shellcheck disable=SC2016  # jq program text: $h/$v/$h0/$v0 are jq bindings, not shell vars
OV_JQ_PRELUDE='
  def obj($x): if ($x | type) == "object" then $x else {} end;
  obj(.[$h]) as $h0
  | (if $v == "" then {} else obj(obj(.[$h]).variants[$v]) end) as $v0
  |'

# Run one jq query over the override file with the two-layer prelude bound.
ov_jq() {  # <harness> <variant> <jq-expr> [extra jq args...]
  local harness=$1 variant=$2 expr=$3
  shift 3
  jq -r --arg h "$harness" --arg v "$variant" "$@" "$OV_JQ_PRELUDE $expr" \
    "$HARNESS_OVERRIDES" 2>/dev/null || true
}

# True when the override file is present, jq is installed, and the JSON parses.
harness_overrides_usable() {
  [ -f "$HARNESS_OVERRIDES" ] \
    && command -v jq >/dev/null 2>&1 \
    && jq -e . "$HARNESS_OVERRIDES" >/dev/null 2>&1
}

# Resolve which NAMED LAUNCH VARIANT applies to this spawn and print it (empty
# means none). Precedence is explicit only, never inferred: an explicit --launch
# wins, then .[<harness>].default_variant from the override file. Quota, load, and
# every other runtime signal are deliberately not inputs here - the captain chose
# human selection over automatic routing, because the available quota readings are
# not accurate enough to route on (see docs/configuration.md). A named variant that
# the resolved harness does not declare is a hard refusal from both sources, so a
# typo or a stale name can never silently fall back to a different account.
# shellcheck disable=SC2016  # jq program text: $h0/$v are jq bindings, not shell vars
resolve_launch_variant() {  # <harness>
  local harness=$1 variant='' source=''
  if [ -n "$LAUNCH_VARIANT" ]; then
    variant=$LAUNCH_VARIANT
    source="--launch"
  fi
  if [ -z "$variant" ]; then
    if harness_overrides_usable; then
      variant=$(ov_jq "$harness" "" 'if ($h0.default_variant? | type) == "string" then $h0.default_variant else empty end')
      [ -z "$variant" ] || source="config/harness-overrides.json .$harness.default_variant"
    fi
  fi
  [ -n "$variant" ] || return 0
  if ! harness_overrides_usable; then
    echo "error: launch variant '$variant' requested via $source but config/harness-overrides.json is absent, unreadable, or jq is missing" >&2
    return 1
  fi
  # Declaration is key membership, not the resolved value's content: `{}` is a
  # valid no-op variant that inherits the harness-level command, args, and env.
  if [ "$(ov_jq "$harness" "$variant" 'if (($h0.variants? | type) == "object") and ($h0.variants | has($v)) then "yes" else "no" end')" != yes ]; then
    echo "error: launch variant '$variant' (from $source) is not declared under config/harness-overrides.json .$harness.variants" >&2
    echo "       declared variants for $harness: $(ov_jq "$harness" "" 'if ($h0.variants? | type) == "object" then ($h0.variants | keys_unsorted | join(", ")) else "" end' | sed 's/^$/(none)/')" >&2
    return 1
  fi
  printf '%s\n' "$variant"
}

# Resolve the three overridable launch axes for the resolved harness, applying
# config/harness-overrides.json when it is present, jq is available, and the file
# is valid JSON. Sets OV_ENV_VALUE, OV_CMD, OV_ARGS_VALUE:
#   - command: override .[$h].command replaces the built-in binary; absent keeps it.
#   - args: override .[$h].args (a JSON string array) replaces the built-in launch
#     args, each element shell-quoted as one literal argument (an empty array means
#     no args); absent keeps the built-in default.
#   - env: override .[$h].env is MERGED over the built-in launch env (override wins
#     on key conflict) and prepended as KEY=value assignments.
# A selected named variant layers over the harness-level values per axis: command
# and args replace when the variant declares them, and env merges with the variant
# winning on a key conflict. Layering rather than replacing is what keeps a variant
# a delta - the harness-level entry stays the shared base for every variant.
# OV_ENV_VALUE and OV_ARGS_VALUE carry a single trailing space when non-empty (or
# are empty), matching launch_template's placeholder spacing. The firstmate-owned
# tail (model/effort flags, brief injection, turn-end wiring) is NOT touched here.
# An absent file, absent jq, invalid JSON, absent harness key, or absent field each
# falls back to the built-in default for that axis, so the no-override launch string
# is byte-identical to the built-in template, and so is the launch string for a file
# that declares no variant. Override env is deliberately never recorded into meta,
# which is what keeps a variant's gateway credentials out of firstmate's state files.
# shellcheck disable=SC2016  # jq program text: $h0/$v0/$k are jq bindings, not shell vars
resolve_launch_overrides() {  # <harness> [<variant>]
  local harness=$1 variant=${2:-} cmd raw el first k v line merged
  local args_str env_pairs ov_env_keys
  OV_CMD=$(harness_default_command "$harness")
  args_str=$(harness_default_args "$harness")
  env_pairs=$(harness_default_env_pairs "$harness")
  ov_env_keys=
  if harness_overrides_usable; then
    cmd=$(ov_jq "$harness" "$variant" '
      (if ($v0.command? | type) == "string" and ($v0.command | length) > 0 then $v0.command
       elif ($h0.command? | type) == "string" and ($h0.command | length) > 0 then $h0.command
       else empty end)')
    [ -n "$cmd" ] && OV_CMD=$cmd
    if [ "$(ov_jq "$harness" "$variant" '
      if (($v0 | has("args")) and (($v0.args | type) == "array"))
        or (($h0 | has("args")) and (($h0.args | type) == "array"))
      then "yes" else "no" end')" = yes ]; then
      raw=$(ov_jq "$harness" "$variant" '
        (if ($v0 | has("args")) and (($v0.args | type) == "array") then $v0.args else $h0.args end)[]')
      args_str=
      if [ -n "$raw" ]; then
        first=1
        while IFS= read -r el; do
          if [ "$first" = 1 ]; then first=0; else args_str="$args_str "; fi
          args_str="$args_str$(shell_quote "$el")"
        done <<EOF
$raw
EOF
      fi
    fi
    ov_env_keys=$(ov_jq "$harness" "$variant" '(obj($h0.env) + obj($v0.env)) | keys_unsorted[]')
  fi
  # env prefix: built-in pairs whose key is not overridden, then the override pairs.
  merged=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=${line%%=*}
    if [ -n "$ov_env_keys" ] && printf '%s\n' "$ov_env_keys" | grep -qxF -- "$k"; then
      continue
    fi
    merged="$merged${merged:+ }$line"
  done <<EOF
$env_pairs
EOF
  if [ -n "$ov_env_keys" ]; then
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      v=$(ov_jq "$harness" "$variant" '(obj($h0.env) + obj($v0.env))[$k] | tostring' --arg k "$k")
      merged="$merged${merged:+ }$k=$(shell_quote "$v")"
    done <<EOF
$ov_env_keys
EOF
  fi
  if [ -n "$args_str" ]; then OV_ARGS_VALUE="$args_str "; else OV_ARGS_VALUE=; fi
  if [ -n "$merged" ]; then OV_ENV_VALUE="$merged "; else OV_ENV_VALUE=; fi
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

# Resolve the named launch variant here, before ANY fleet mutation, so an
# undeclared variant name refuses the spawn instead of leaving a half-built
# worktree behind. A raw launch command supplies its own binary and env, so a
# variant has nothing to layer over and the combination is refused outright
# rather than silently ignored.
if [ -n "$LAUNCH_VARIANT" ] && [ -z "$HARNESS" ]; then
  echo "error: --launch cannot be combined with a raw launch command; the raw command already sets its own binary, args, and env" >&2
  exit 1
fi
RESOLVED_LAUNCH_VARIANT=$(resolve_launch_variant "$HARNESS") || exit 1

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

# git_common_dir_real <dir>: the physical path of <dir>'s git common dir, or
# non-zero when <dir> is not inside a git repository. Every linked worktree of a
# repository shares the primary checkout's common dir, so equality of this value
# is the "same repository" test the isolation guard relies on.
git_common_dir_real() {  # <dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P)
}

# Empty when the project itself is not a git repository; the isolation guard
# below then fails closed rather than adopting any candidate worktree.
PROJ_COMMON_REAL=$(git_common_dir_real "$PROJ_ABS") || PROJ_COMMON_REAL=

# Session-provider container-ensure + task creation. tmux derives a readable,
# ownership-stamped session per FM_HOME (see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
# spawn_worktree_isolated <path>: 0 iff <path> is the root of a git working
# tree that belongs to the SAME repository as the primary project checkout
# (equal physical git common dirs) and is not the primary checkout itself.
# The same-repository requirement is load-bearing: the pane's cwd read can
# report a foreground process sitting in an UNRELATED repo (incident: an
# oh-my-zsh update prompt ate the leading char of `treehouse get`, the updater
# ran with cwd ~/.oh-my-zsh - itself a git clone - and the old
# any-git-root-except-primary check adopted it as the task worktree).
spawn_worktree_isolated() {  # <path>
  local cand=$1 cand_real cand_top cand_top_real cand_common
  [ -n "$PROJ_COMMON_REAL" ] || return 1
  cand_real=$(cd "$cand" 2>/dev/null && pwd -P) || return 1
  [ "$cand_real" != "$PROJ_ABS_REAL" ] || return 1
  cand_top=$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null) || return 1
  cand_top_real=$(cd "$cand_top" 2>/dev/null && pwd -P) || return 1
  [ "$cand_real" = "$cand_top_real" ] || return 1
  cand_common=$(git_common_dir_real "$cand") || return 1
  [ "$cand_common" = "$PROJ_COMMON_REAL" ]
}

validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_common
  if spawn_worktree_isolated "$WT"; then
    return 0
  fi
  wt_common=$(git_common_dir_real "$WT") || wt_common=none
  echo "error: $source did not yield an isolated worktree of the project repository (resolved '$WT'; its git common dir '$wt_common' vs project's '${PROJ_COMMON_REAL:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout or adopting an unrelated directory. Inspect target $inspect_target" >&2
  exit 1
}

# A stale presentation journal never grants launch authority.
# When authoritative metadata already exists, require its endpoint to be
# positively dead before the journal's read-only token inspection may allow a
# flat fallback.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  # Probe the endpoint on the server its own metadata records, so "is the old one
  # still alive" is never answered by a same-named window on another server.
  fm_backend_bind_meta "$old_backend" "$meta" || true
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    old_session=$FM_BACKEND_HERDR_SESSION
    old_pane=$FM_BACKEND_HERDR_PANE
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

# Distinct exit code for a spawn refused by the remote-access preflight (below):
# separable from a generic error (1) or a usage error (2) so a caller can tell an
# unstarted spawn (nothing created) from a mid-flight failure.
FM_SPAWN_REMOTE_BLOCKED=4

# Non-interactive SSH host-trust preflight, BEFORE any terminal/window is created.
# treehouse get's `git fetch origin` would otherwise stop at a first-time host
# authenticity prompt inside the crew pane, wedging the spawn with no recoverable
# endpoint (metadata is not written until after the fetch). Refuse up front with an
# actionable blocker instead of creating a doomed window, and never auto-accept an
# unknown key. Only treehouse-get spawns fetch; an orca spawn owns its worktree and
# a secondmate is not spawned here (mirrors the treehouse-get guard below).
spawn_remote_preflight_or_block() {
  local url host rc
  url=$(git -C "$PROJ_ABS" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  host=$(fm_remote_ssh_host "$url") || return 0
  rc=0
  fm_remote_preflight_ssh "$host" || rc=$?
  case "$rc" in
    10)
      echo "error: cannot spawn task $ID: the SSH host key for '$host' (project origin $url) is not trusted, so the first 'git fetch' would stop at an interactive host-authenticity prompt inside the crew terminal and wedge the spawn with no recoverable endpoint. Refusing to create a terminal or auto-accept the key. Verify the host fingerprint out of band and add it (run 'ssh $host' once to accept it, or append a verified key to known_hosts), then re-dispatch." >&2
      exit "$FM_SPAWN_REMOTE_BLOCKED"
      ;;
    11)
      echo "error: cannot spawn task $ID: SSH authentication to '$host' (project origin $url) was refused (Permission denied), so 'git fetch' would fail. Refusing to create a terminal. Provision the SSH credential/key for '$host', then re-dispatch." >&2
      exit "$FM_SPAWN_REMOTE_BLOCKED"
      ;;
  esac
  return 0
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_remote_preflight_or_block
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
# tmux/ is the pane's PRIVATE tmux namespace (TMUX_TMPDIR). Both exist before the
# terminal is created, because the tmux pane is given that namespace at creation
# time and tmux must find the directory already there.
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp" "$TASK_TMP/tmux"

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
    #
    # The pane is created with a PRIVATE tmux namespace already in place.
    #
    # This is the fleet-isolation fix (incident 2026-07-28 00:47): a crewmate
    # typing a bare `tmux` command in its own pane used to operate on the FLEET's
    # tmux server, because the pane inherited $TMUX. One `kill-server` from an
    # agent that was experimenting with tmux behavior took the whole fleet -
    # primary, secondmate, every crewmate - down in 2.5 seconds.
    #
    # Emptying $TMUX detaches the pane from the fleet server, and TMUX_TMPDIR
    # redirects tmux's socket directory, so a bare `tmux`, `tmux -L <anything>`,
    # and `tmux kill-server` all land on a throwaway per-task server instead.
    # Only an absolute `tmux -S <fleet socket>` can still reach the fleet, which
    # is a deliberate act rather than the accident this closes.
    #
    # $TMUX_PANE is deliberately left alone: it names a pane, not a server, so it
    # cannot reach the fleet on its own, and a secondmate - a firstmate primary
    # living in one of these panes - discovers its own supervisor pane through it
    # (bin/fm-supervisor-target-lib.sh's discover_supervisor_target).
    #
    # A secondmate also runs firstmate's own scripts and must still dispatch ITS
    # crew onto the shared fleet server, so it alone is handed the socket.
    # Ordinary crewmates are never told where the fleet server is.
    SANDBOX_ENV=("TMUX_TMPDIR=$TASK_TMP/tmux" "TMUX=")
    [ "$KIND" != secondmate ] || SANDBOX_ENV+=("FM_TMUX_SOCKET=$(fm_tmux_socket)")
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS" "${SANDBOX_ENV[@]}") || exit 1
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
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && [ -f "$CONFIG/herdr-presentation-spaces" ]; then
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        HERDR_RECOVERY_SESSION=$(fm_backend_herdr_session)
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_RECOVERY_SESSION" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        HERDR_SES=$(fm_backend_herdr_session)
        HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
        # Session lock path resolution needs a live named-session socket.
        # Ensure the server before journal publication so lock failure degrades
        # to flat without ever creating an unlocked projection.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
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
            "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL"
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
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # Compare against PROJ_ABS_REAL (physical), not PROJ_ABS: a symlinked project
  # prefix would otherwise make the pane's OS-level cwd read differ from
  # PROJ_ABS on the very first poll, before the pane has actually moved.
  # A candidate is latched only when spawn_worktree_isolated confirms it is a
  # worktree of the project's own repository: the pane's cwd can transit
  # through arbitrary directories (a shell-startup prompt intercepting the
  # command, a foreground updater), and "any path other than the primary" is
  # not evidence that treehouse ran. Rejected candidates keep the poll alive
  # (the real worktree may still appear) and the last one is reported on
  # timeout instead of ever being adopted. A valid candidate must also appear
  # in two consecutive reads so a transient stale pane path cannot be recorded.
  # FM_SPAWN_WT_TIMEOUT (seconds, default 60) exists so tests can exercise
  # the refusal path without waiting out the full production window.
  WT_TIMEOUT=${FM_SPAWN_WT_TIMEOUT:-60}
  case "$WT_TIMEOUT" in ''|*[!0-9]*) WT_TIMEOUT=60 ;; esac
  WT_LAST_REJECT=
  candidate=
  for _ in $(seq 1 "$WT_TIMEOUT"); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" != "$PROJ_ABS_REAL" ]; then
      if spawn_worktree_isolated "$p"; then
        p_real=$(real_path_or_raw "$p")
        if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
          WT="$p"
          break
        fi
        candidate="$p_real"
      else
        WT_LAST_REJECT="$p"
        candidate=
      fi
    else
      candidate=
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    if [ -n "$WT_LAST_REJECT" ]; then
      echo "error: treehouse get left the pane at '$WT_LAST_REJECT', which is not a worktree of the project repository (primary '$PROJ_ABS'); the command was likely intercepted in the pane (e.g. a shell-startup prompt consuming input). Refusing to adopt that path; inspect window $T" >&2
    else
      echo "error: treehouse get did not enter a worktree within ${WT_TIMEOUT}s; inspect window $T" >&2
    fi
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

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
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
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
    traex*)
      # traex: same as codex - turn-end rides -c notify=[...] and __TURNEND__.
      # Nothing is written into the worktree and no hook trust is needed, which is
      # exactly why notify= is used instead of traex's claude-style [[hooks.Stop]]:
      # hook trust is a sha256 of the hook COMMAND, so a per-task command (which
      # necessarily carries this task's own turn-end path) would hash differently
      # every task, never match a trusted hash, and be silently ignored.
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

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
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

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
# Publish the task metadata, checking the redirect result explicitly rather than
# relying on set -e to abort on a failed compound-command redirect.
# That errexit behavior is not reliable across bash versions (a failed meta-write
# redirect is swallowed identically on bash 3.2 and bash 5.0.3), so without this
# explicit check a meta-write failure would return success and leave a live task
# firstmate never recorded and cannot supervise or tear down.
# On failure exit non-zero with the Orca abort cleanup still armed, so the EXIT
# trap releases the terminal and worktree instead of leaking them.
meta_write_rc=0
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # launch= records the NAME of the selected launch variant, and only when one was
  # selected, so a home with no variants keeps a byte-identical meta. The name alone
  # is recorded - never the variant's command or env - so a gateway launcher's
  # credentials stay in that launcher and out of firstmate's state files.
  [ -z "$RESOLVED_LAUNCH_VARIANT" ] || echo "launch=$RESOLVED_LAUNCH_VARIANT"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  # tmux_socket= records WHICH tmux server this window lives on, so every later
  # reader addresses that server rather than whichever one it happens to be
  # running in. A meta without the field predates it and therefore predates any
  # socket move, so readers fall back to the ambient fleet socket - the exact
  # behavior every reader had before (bin/fm-tmux-lib.sh's
  # fm_tmux_socket_of_meta owns that compatibility rule).
  [ "$BACKEND" != tmux ] || echo "tmux_socket=$(fm_tmux_socket)"
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
} > "$STATE/$ID.meta" || meta_write_rc=$?
if [ "$meta_write_rc" -ne 0 ]; then
  echo "error: failed to write task metadata to $STATE/$ID.meta" >&2
  exit 1
fi
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

backlog_start_failure_banner() {  # <heading> <detail> <repair-command>
  local heading=$1 detail=$2 repair=$3 rule
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  %s\n' "$heading"
    printf '●  The launch succeeded and %s is live, but data/backlog.md was not updated.\n' "$ID"
    printf '●  %s\n' "$detail"
    printf '●  Repair now: %s\n' "$repair"
    printf '●%s\n' "$rule"
  } >&2
}

backlog_mark_started() {
  local backlog out repair retry
  [ "$KIND" = secondmate ] && return 0
  backlog="$DATA/backlog.md"
  repair="cd $(shell_quote "$FM_HOME") && tasks-axi add $(shell_quote "$ID") $(shell_quote '<task title>') --kind $(shell_quote "$KIND") --repo $(shell_quote "$PROJ_NAME") --start --file $(shell_quote "$backlog")"
  retry="cd $(shell_quote "$FM_HOME") && tasks-axi start $(shell_quote "$ID") --file $(shell_quote "$backlog")"

  if [ ! -f "$backlog" ]; then
    backlog_start_failure_banner \
      "BACKLOG ROW MISSING - $ID WAS DISPATCHED WITHOUT A BACKLOG ITEM" \
      "No backlog exists at $backlog, so this task has no durable task record." \
      "$repair"
    return 0
  fi

  # tasks-axi reads local configuration from the home, while --file keeps the
  # mutation pinned to that home's backlog even when fm-spawn was invoked elsewhere.
  if out=$(cd "$FM_HOME" && tasks-axi start "$ID" --file "$backlog" 2>&1); then
    return 0
  fi

  printf '%s\n' "$out" >&2
  case "$out" in
    *'not found in this backlog'*|*'code: NOT_FOUND'*)
      backlog_start_failure_banner \
        "BACKLOG ROW MISSING - $ID WAS DISPATCHED WITHOUT A BACKLOG ITEM" \
        "Create its durable task record with the command below (replace <task title> with the real title)." \
        "$repair"
      ;;
    *)
      backlog_start_failure_banner \
        "BACKLOG START FAILED - $ID IS STILL NOT MARKED IN FLIGHT" \
        "The backlog write failed, but the launch continues so the live task is not interrupted." \
        "$retry"
      ;;
  esac
}

backlog_mark_started

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
PIBRIEFENV=
[ "$HARNESS" != pi ] || PIBRIEFENV="FM_FIRSTMATE_PI_LAUNCH_BRIEF=$sq_brief"
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
# Overridable axes first (command, args, env prefix), then the firstmate-owned tail.
# For the raw-launch-command escape hatch, LAUNCH holds no __ENV__/__CMD__/__ARGS__
# placeholders, so these substitutions are a no-op there.
resolve_launch_overrides "$HARNESS" "$RESOLVED_LAUNCH_VARIANT"
LAUNCH=${LAUNCH//__ENV__/$OV_ENV_VALUE}
LAUNCH=${LAUNCH//__CMD__/$OV_CMD}
LAUNCH=${LAUNCH//__ARGS__/$OV_ARGS_VALUE}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__PIBRIEFENV__/$PIBRIEFENV}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Old-tmux fallback for the pane sandbox.
#
# The private tmux namespace is normally set when the window is CREATED
# (bin/backends/tmux.sh's fm_backend_tmux_create_task, `new-window -e`), which
# needs tmux 3.0+ and leaves nothing to lose in transit. On an older tmux that
# flag does not exist, so the same environment is typed into the pane instead -
# the pre-3.0 behavior, with the sent-line risk that comes with it.
if [ "$BACKEND" = tmux ] && ! fm_backend_tmux_pane_env_supported; then
  echo "warning: this tmux is too old for 'new-window -e'; sending the pane's private tmux namespace as a typed line instead" >&2
  spawn_send_text_line "$T" "unset TMUX; export TMUX_TMPDIR=$TASK_TMP/tmux"
  sleep 0.3
  if [ "$KIND" = secondmate ]; then
    spawn_send_text_line "$T" "export FM_TMUX_SOCKET=$(fm_tmux_socket)"
    sleep 0.3
  fi
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
if [ "$KIND" = secondmate ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

echo "spawned $ID harness=$HARNESS${RESOLVED_LAUNCH_VARIANT:+ launch=$RESOLVED_LAUNCH_VARIANT} kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"
