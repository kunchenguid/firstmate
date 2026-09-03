#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>]
#        fm-spawn.sh <task-id> <project-dir> --scout [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --mode and --yolo are this task's delivery contract, REQUIRED for every ship
#   spawn and refused on --scout and --secondmate spawns. Firstmate resolves both
#   per task at intake (AGENTS.md section 7); data/projects.md holds the captain's
#   standing posture as context, not as this task's answer, so a spawn never looks
#   the mode up. A ship spawn additionally reads the brief's recorded
#   "Delivery contract: mode=<mode>" line and REFUSES a mismatch, so the worker's
#   instructions and the recorded task delivery cannot drift apart; a brief
#   scaffolded before that line existed warns once and launches on the flag. When
#   the explicit mode carries less rigor than the project's standing posture, a
#   loud one-line deviation notice is printed and the spawn continues.
#   no-mistakes-prod-only is a registry policy rather than a task mode and is
#   refused as a flag value.
#        fm-spawn.sh <task-id> --relaunch [--harness <name>] [--model <name>] [--effort <level>]
#   --relaunch launches a replacement agent for an EXISTING task into that
#   task's own recorded endpoint and worktree instead of creating either. It is
#   the launch half of the control plane (bin/fm-control.sh relaunch), which
#   owns the checkpoint, the progress note, stopping the previous agent, and the
#   transaction; call fm-control rather than this flag directly unless you are
#   deliberately re-launching an already-stopped task. Every identity axis -
#   backend, kind, project or home, worktree, endpoint - comes from the task's
#   validated state/<id>.meta, so --backend, --scout, --secondmate, a project
#   positional, and batch pairs are all refused alongside it; only harness,
#   model, and effort may change, which is what makes a harness switch one
#   ordinary relaunch. It refuses unless the recorded endpoint is positively
#   agent-free on a backend with a recovery-grade agent-state classifier (tmux
#   or herdr), refuses unless the endpoint's shell is sitting in the recorded
#   worktree, and clears the previous harness's per-task wiring before arming
#   the new incarnation.
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   exact task only (docs/configuration.md "Runtime backend" owns when that flag
#   is authorized). Without it, the script resolves FM_BACKEND, then
#   config/backend, then runtime auto-detection from the runtime firstmate's
#   environment: $TMUX, HERDR_ENV=1, or cmux runtime signals (via
#   bin/fm-backend.sh's fm_backend_detect, with cmux fallback details in
#   docs/cmux-backend.md),
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
#   A herdr crewmate or scout is placed in the exact workspace of the firstmate
#   or secondmate process launching it, resolved from that process's own herdr
#   pane rather than from a workspace label (herdr enforces no label uniqueness,
#   so a label cannot tell two "firstmate" workspaces apart). A claimed parent
#   identity that is unreadable, contradictory, stale, or from another herdr
#   session stops the spawn before any worker endpoint exists. A launcher
#   outside herdr has no workspace to inherit and uses this home's own labeled
#   workspace, which must then match exactly one. --secondmate is the deliberate
#   exception: it stands up that secondmate home's own workspace.
#   Herdr additionally uses a presentation-only layout by default when the
#   selected client and running server meet the Herdr 0.8.0 floor. The local
#   config/herdr-presentation-spaces file can say off to disable it or on to
#   opt in below that floor; an empty file remains the historical opt-in form.
#   A clean fresh task first writes state/<id>.herdr-presentation atomically,
#   then creates a disposable
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
#   even when they select different backends. A fresh spawn first takes the
#   per-home task-set lock and refuses rather than waits when forced teardown owns
#   it; relaunch is exempt because the existing task's control lock covers it.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the crewmate/scout escape hatch
#   for verifying new adapters. Persistent secondmates require a verified adapter
#   whose launch boundary can be reconciled before identity commitment. For pi and
#   pi-signed, fm-spawn resolves the selected executable
#   name from PATH once, probes that concrete path with --help, and launches the
#   same path. It adds --tui-mode regular only when that help advertises the flag;
#   a failed or inconclusive probe omits it so older Pi versions remain launchable.
#   A missing selected executable refuses before endpoint creation, and pi-signed
#   never falls back to pi.
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
#   Ship and scout spawns validate the optional exact work identity through
#   bin/fm-work-identity.sh before creating an endpoint. A linked intake record
#   must match the generated instructions byte-for-byte and is bound into meta by
#   schema/status/SHA-256 fields; an absent record is recorded explicitly as
#   unlinked. Relaunch validates and preserves the same binding.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
#   Before a fresh ship or scout worker starts, its clean task worktree fetches
#   origin, resolves the current remote default branch, and resets to its tip.
#   An unreachable origin, unresolved default branch, or non-clean worktree
#   refuses the spawn rather than risking a PR based on stale history.
#   A slot whose only deviation is a stale submodule gitlink is refused by that
#   same clean check, but is reported as a stale checkout naming each submodule
#   and both pins; nothing is converged or removed, and no remedy is suggested.
#   That report is only reached when each submodule's checked-out commit is
#   already contained in one of its remotes, so a submodule carrying an unpushed
#   commit keeps the conservative uncommitted-work refusal instead. That
#   containment test reads local refs only and never fetches, so this gate stays
#   usable offline; a stale remote-tracking ref can therefore make an unpushed
#   commit look contained, which is exactly why no remedy command is printed.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend/--mode/--yolo
#   applies to every pair. A ship batch therefore carries one delivery contract, and each
#   pair still checks it against its own brief; a batch spanning modes is two invocations.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEFINPUT__ shell-quoted immutable operational input captured from the validated launch brief
#     __PIBIN__    quoted concrete Pi-family executable path resolved from PATH
#     __PITUIMODE__ optional --tui-mode regular when that executable advertises it
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __WORKTREE__  absolute path to the task worktree
#     __CURSORBIN__ resolved, cursor-verified executable for a cursor launch
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# muse installs no hook at all - its plugin engine is off in the default build - so
# it writes state/<id>.muse-session to bind the pane to muse's own session event
# log; muse is crewmate/scout only and is refused for --secondmate.
# cursor installs no per-task hook either: it writes state/<id>.cursor-session to
# bind the pane to cursor's own conversation transcript (projects root, the exact
# workspace path cursor records in .workspace-trusted, and the conversations that
# already existed for that workspace). It is launched through the verified binary
# resolver because `cursor` is not the CLI name. A cursor SECONDMATE instead runs
# the tracked project-scope .cursor/hooks.json in its own home, whose stop-hook
# park owns that home's supervision (docs/supervision-protocols/cursor.md).
# Publishing the record and moving this home's backlog item to In flight are one
# step, not two: bin/fm-backlog-transition-lib.sh owns that invariant, and this
# script performs the transition under the task's own meta lock before it reports
# success. A ship or scout dispatch therefore REFUSES up front, before any
# endpoint, worktree, or record exists, unless the home's backlog has an
# unheld, unblocked Queued or In flight item for the id; a transition that fails
# after publication removes the record it just wrote rather than leaving a
# worker the backlog does not own. A relaunch re-reads the row instead of
# re-running the transition, so an eligible In-flight item is left untouched.
# The transition is
# skipped entirely for --secondmate spawns (persistent agents are not work
# items), on a config/backlog-backend=manual home, and in a home that keeps no
# data/backlog.md. An automatic-backend home with a backlog but no compatible
# tasks-axi refuses before creating any lifecycle state.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> [mode=<mode> yolo=<on|off>] window=<backend-target> worktree=<path>
# A ship task records the explicit mode/yolo it was passed; a secondmate spawn records
# mode=secondmate, yolo=off, home=, and projects=; a scout records neither, and both the
# success line and state/<id>.meta omit them.
# Every fresh spawn or relaunch records a new spawn_gen= incarnation token so durable
# consumers can distinguish a replacement worker that reuses the same task id.
# When the home session's frozen trace-context decision is enabled (see
# docs/configuration.md and bin/fm-trace-context-lib.sh), the meta also records
# one W3C traceparent= carrier, the same value injected into the pane as
# TRACEPARENT; the default-off path writes neither, leaving the generated meta
# and launch environment unchanged.
#   --traceparent <carrier> delivers a carrier that a REMOTE parent already
#   resolved and will record, instead of resolving one from this home's frozen
#   decision. It is accepted only for --secondmate spawns, only as a strictly
#   validated W3C traceparent, and exists because a remote secondmate's task
#   identity is owned by the parent home that holds its task metadata, while the
#   pane export happens on the remote host (bin/fm-remote-secondmate-control.sh).
#   Local spawns never pass it and resolve their own carrier exactly as before.
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

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
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
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
fi
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
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
TRACEPARENT_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
TRACEPARENT_SET=0
RELAUNCH=0
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
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      traceparent) TRACEPARENT_ARG=$a; TRACEPARENT_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout; KIND_SET=1 ;;
    --secondmate) KIND=secondmate; KIND_SET=1 ;;
    --relaunch) RELAUNCH=1 ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --traceparent) want_value=traceparent ;;
    --traceparent=*) TRACEPARENT_ARG=${a#--traceparent=}; TRACEPARENT_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$MODE_SET" -eq 0 ] || [ -n "$MODE" ] || { echo "error: --mode requires a non-empty value" >&2; exit 1; }
[ "$YOLO_SET" -eq 0 ] || [ -n "$YOLO" ] || { echo "error: --yolo requires a non-empty value" >&2; exit 1; }
[ "$TRACEPARENT_SET" -eq 0 ] || [ -n "$TRACEPARENT_ARG" ] || { echo "error: --traceparent requires a non-empty value" >&2; exit 1; }
# A parent-delivered carrier replaces this home's own resolution, so it is
# refused unless it is a secondmate spawn carrying a strictly valid W3C value.
# Nothing else may reach the pane's TRACEPARENT export.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  [ "$KIND" = secondmate ] || {
    echo "error: --traceparent applies only to --secondmate spawns; every other spawn resolves its own carrier from this home's frozen trace-context decision" >&2
    exit 1
  }
  fm_trace_context_valid "$TRACEPARENT_ARG" || {
    echo "error: --traceparent is not a valid W3C traceparent" >&2
    exit 1
  }
fi
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# --relaunch reuses an existing task's endpoint, worktree, project, and kind,
# so every axis this block resolves for a fresh spawn instead comes from that
# task's own durable record below. Contradicting it on the command line is a
# refusal rather than a silently-ignored flag.
if [ "$RELAUNCH" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded backend; --backend cannot override it" >&2; exit 1; }
  [ "$KIND_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded kind; --scout/--secondmate cannot override it" >&2; exit 1; }
  [ "$MODE_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it" >&2; exit 1; }
  [ "$YOLO_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it" >&2; exit 1; }
else
  # Delivery contract (AGENTS.md section 7). A ship task's mode and yolo are
  # firstmate's per-task decision, so they are required and closed-set validated
  # here rather than resolved from the project registry. Scouts deliver a report
  # and record no delivery posture; secondmate spawns hardcode theirs.
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
      no-mistakes|direct-PR|local-only) ;;
      no-mistakes-prod-only)
        echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
        exit 1 ;;
      *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
    esac
    case "$YOLO" in
      on|off) ;;
      *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
    esac
  else
    [ "$MODE_SET" -eq 0 ] || {
      echo "error: --mode applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 0 ] || {
      echo "error: --yolo applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
  fi
fi

spawn_remote_secondmate() {
  local id=$1 remote host root home harness positional model effort backend out rc meta tmp
  local remote_backend remote_target remote_harness remote_herdr_session registry_lock remote_lock remote_generation
  local remote_traceparent remote_recorded_traceparent
  local -a launch_args
  id=${POS[0]:-}
  fm_task_id_creation_valid "$id" || { echo "error: invalid task id" >&2; return 2; }
  mkdir -p "$STATE" || { echo "error: could not create parent state directory" >&2; return 1; }
  SPAWN_TASK_LOCK="$STATE/.spawn-$id.lock"
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
  elif ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    echo "error: another spawn is already creating task $id" >&2
    return 1
  fi
  registry_lock=$(secondmate_registry_lock_path "$STATE")
  if ! fm_lock_acquire_wait "$registry_lock"; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: secondmate registry could not be locked for remote spawn" >&2
    return 1
  fi
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  if [ "$remote" != 1 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 3
  fi
  host=$(secondmate_registry_field "$DATA/secondmates.md" "$id" host)
  root=$(secondmate_registry_field "$DATA/secondmates.md" "$id" root)
  home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home)
  fm_lock_release "$registry_lock" || {
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  }
  if ! fm_lock_acquire_wait "$registry_lock"; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  fi
  [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)" = 1 ] \
    && [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" host 2>/dev/null || true)" = "$host" ] \
    && [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" root 2>/dev/null || true)" = "$root" ] \
    && [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" home 2>/dev/null || true)" = "$home" ] || {
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: remote secondmate $id route changed during identity reservation" >&2
      return 1
    }
  positional=${POS[1]:-}
  if [ "${#POS[@]}" -gt 2 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate spawn accepts no local home positional argument" >&2
    return 2
  fi
  if [ -n "$HARNESS_ARG" ]; then
    harness=$HARNESS_ARG
  elif [ -n "$positional" ]; then
    harness=$positional
  else
    harness=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
  fi
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *)
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: remote secondmate spawn requires a verified harness adapter, not a raw launch command: $harness" >&2
      return 1
      ;;
  esac
  model=${MODEL:--}
  effort=${EFFORT:--}
  if [ -z "$HARNESS_ARG" ] && [ -z "$positional" ]; then
    if [ "$MODEL_SET" -eq 0 ]; then
      model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
      [ -n "$model" ] || model=-
    fi
    if [ "$EFFORT_SET" -eq 0 ]; then
      effort=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
      [ -n "$effort" ] || effort=-
    fi
  fi
  # A remote second mate always runs on Herdr: its server belongs to the host's
  # own GUI login session, so the endpoint outlives every SSH connection that
  # supervises it. bin/fm-remote-doctor.sh gates that host on the same
  # requirement, and the remote home's config/backend never overrides it.
  case "${BACKEND_ARG:--}" in
    -|herdr) backend=herdr ;;
    *)
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: a remote secondmate runs only on the herdr backend, not '$BACKEND_ARG'" >&2
      return 1
      ;;
  esac
  case "$effort" in
    -|low|medium|high|xhigh|max) ;;
    *)
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: invalid configured remote secondmate effort: $effort" >&2
      return 1
      ;;
  esac
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! fm_backlog_record_present "$meta" "task record" "$STATE" \
      || [ "$(fm_pr_file_link_count "$meta" 2>/dev/null || true)" != 1 ] \
      || [ "$(fm_meta_get "$meta" kind)" != secondmate ] \
      || [ "$(fm_meta_get "$meta" remote_host)" != "$host" ] \
      || [ "$(fm_meta_get "$meta" remote_root)" != "$root" ] \
      || [ "$(fm_meta_get "$meta" home)" != "$home" ]; then
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: existing metadata for $id does not identify this remote secondmate route" >&2
      return 1
    fi
  fi
  if ! prepare_secondmate_work_identity; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  fi
  # Gate the host before anything is published or transferred, so a host that
  # cannot hold a durable Herdr endpoint refuses here rather than half-way
  # through a launch. This is also the readiness gate every liveness relaunch
  # passes through, because recovery respawns through this same route.
  rc=0
  fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    # Summary first, then the doctor's own text: a caller that reports only the
    # first line, such as the startup liveness sweep, must still say something
    # actionable.
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id readiness could not be confirmed; preserved route $host:$home" >&2
    else
      echo "error: remote secondmate $id host $host is not ready for a remote second mate; launch refused" >&2
    fi
    [ -z "$FM_REMOTE_READINESS_OUT" ] || printf '%s\n' "$FM_REMOTE_READINESS_OUT" >&2
    [ "$rc" -ne 255 ] || return 255
    return 1
  fi
  remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id")
  if ! fm_lock_acquire_wait "$remote_lock"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance transaction could not be locked" >&2
    return 1
  fi
  remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
  if [ -z "$remote_generation" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance generation could not be published" >&2
    return 1
  fi
  if "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" >/dev/null; then
    :
  else
    rc=$?
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id inheritance completion is unknown; launch refused and route preserved for reconciliation" >&2
    else
      echo "error: remote secondmate $id inheritance failed; launch refused" >&2
    fi
    return "$rc"
  fi
  # This parent home owns the remote secondmate's task identity because it holds
  # the task metadata an observer reads, exactly as for a local spawn: the
  # carrier is resolved against THIS task's own meta (reused verbatim on
  # relaunch, freshly rooted otherwise, never adopting this process's ambient
  # TRACEPARENT) under this home's frozen decision, then handed to the remote
  # host to export into the agent's pane. Disabled resolves to empty and the
  # remote launch call stays byte-identical to the untraced one.
  remote_traceparent=
  if [ "$(fm_trace_context_session_effective "$STATE/.trace-context-effective")" = on ]; then
    remote_traceparent=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$meta" || true)
  fi
  launch_args=("$id" "$harness" "$model" "$effort" "$backend")
  [ -z "$remote_traceparent" ] || launch_args+=("$remote_traceparent")
  if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh launch \
    "${launch_args[@]}" < /dev/null 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      SECONDMATE_RESERVATION_PRESERVE=1
      echo "error: remote secondmate $id is unavailable or launch completion is unknown; preserved route $host:$home" >&2
    fi
    return "$rc"
  fi
  SECONDMATE_RESERVATION_PRESERVE=1
  remote_backend=$(printf '%s\n' "$out" | sed -n 's/^backend=//p' | tail -1)
  remote_target=$(printf '%s\n' "$out" | sed -n 's/^target=//p' | tail -1)
  remote_harness=$(printf '%s\n' "$out" | sed -n 's/^harness=//p' | tail -1)
  remote_herdr_session=$(printf '%s\n' "$out" | sed -n 's/^herdr_session=//p' | tail -1)
  if [ "$remote_backend" != herdr ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned backend '${remote_backend:-missing}', expected herdr; preserving the remote route for reconciliation" >&2
    return 1
  fi
  [ -n "$remote_target" ] && [ "$remote_harness" = "$harness" ] || {
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned malformed route metadata; preserving the remote route for reconciliation" >&2
    return 1
  }
  if [ "$remote_herdr_session" != fm-remote ] || [ "${remote_target%%:*}" != "$remote_herdr_session" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned Herdr session '${remote_herdr_session:-missing}', expected 'fm-remote'; preserving the remote route for reconciliation" >&2
    return 1
  fi
  if ! commit_secondmate_work_identity; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id launched, but its unlinked identity could not be committed; preserving the remote route for reconciliation" >&2
    return 1
  fi
  # Record what the remote endpoint ACTUALLY carries, read back from its own
  # launch, rather than what this side hoped to deliver. That keeps the #995
  # guarantee that the recorded carrier is the identity the child received even
  # when the remote host already had a live agent and reused its endpoint. An
  # off decision delivers no carrier, but an endpoint already holding one still
  # reports it here so the parent does not deny the agent's actual identity.
  remote_recorded_traceparent=$(printf '%s\n' "$out" | sed -n 's/^traceparent=//p' | tail -1)
  fm_trace_context_valid "$remote_recorded_traceparent" || remote_recorded_traceparent=
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-remote-secondmate-meta.XXXXXX") || {
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id launched, but its metadata candidate could not be created; preserving the remote route for reconciliation" >&2
    return 1
  }
  if ! {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$home"
    echo "project=$root"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "tasktmp="
    echo "model=${model#-}"
    echo "effort=${effort#-}"
    echo "home=$home"
    echo "projects=$(secondmate_registry_field "$DATA/secondmates.md" "$id" projects)"
    echo "remote_host=$host"
    echo "remote_root=$root"
    echo "remote_backend=$remote_backend"
    echo "remote_herdr_session=$remote_herdr_session"
    echo "remote_target=$remote_target"
    echo "work_identity_schema=$SECONDMATE_WORK_IDENTITY_SCHEMA"
    echo "work_identity_status=$SECONDMATE_WORK_IDENTITY_STATUS"
    [ -z "$remote_recorded_traceparent" ] || echo "traceparent=$remote_recorded_traceparent"
  } > "$tmp" || ! "$SCRIPT_DIR/fm-work-identity.sh" metadata-publish-unlinked \
    "$id" --file "$tmp"; then
    rm -f -- "$tmp"
    if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
      SPAWN_TASK_SET_LOCK_HELD=0
      fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
    fi
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id launched, but its metadata could not be published safely; preserving the remote route for reconciliation" >&2
    return 1
  fi
  rm -f -- "$tmp"
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK"
  fi
  fm_lock_release "$remote_lock" || true
  fm_lock_release "$registry_lock" || true
  fm_lock_release "$SPAWN_TASK_LOCK" || true
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null; then
    echo "error: remote secondmate $id launched, but its reply source could not be armed; endpoint metadata is preserved" >&2
    return 1
  fi
  echo "spawned $id harness=$harness kind=secondmate mode=secondmate yolo=off window=remote:$id worktree=$home remote=$host backend=$remote_backend"
  return 0
}

BACKEND=
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
SPAWN_CONTROL_LOCK=
SPAWN_CONTROL_LOCK_HELD=0
SPAWN_CONTROL_PARENT=0
SPAWN_META_TMP=
SPAWN_BRIEF_TMP=
SPAWN_DISPATCH_PENDING=0
SPAWN_DISPATCH_TRANSACTION=
SPAWN_ENDPOINT_RECEIPT=
SPAWN_ENDPOINT_RECOVERED=0
SPAWN_ENDPOINT_CREATING_RECOVERY=0
SPAWN_ENDPOINT_MISSING=0
SPAWN_ENDPOINT_PHASE=
SPAWN_ENDPOINT_ENTRY_STATE=
SPAWN_ENDPOINT_ENTRY_DIGEST=
SPAWN_ENDPOINT_RETIREMENT_RECOVERED=0
SPAWN_LAUNCH_SUBMITTED_RECOVERY=0
SPAWN_KIMI_DELIVERY_RECOVERY=0
SPAWN_METADATA_RECOVERY=0
SPAWN_LAUNCH_REQUEST=
SPAWN_LAUNCH_EXECUTED=
SPAWN_LAUNCH_REQUEST_TOKEN=
SPAWN_IDENTITY_HOME=
SPAWN_IDENTITY_HOME_ID=
SPAWN_ORCA_OPERATION=
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_FRESH_COMMIT_PENDING=0
SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT=
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
SECONDMATE_RESERVATION_TRANSACTION=
SECONDMATE_RESERVATION_PENDING=0
SECONDMATE_RESERVATION_PRESERVE=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=
RELAUNCH_REPLACEMENT_AUTH_PATH=
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0

spawn_fresh_commit_rollback() {
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
      "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}

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

spawn_file_link_count() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

spawn_file_inode_identity() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

spawn_launch_request_paths() {
  local digest
  digest=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION" | spawn_sha256_stream) || return 1
  SPAWN_LAUNCH_REQUEST="$STATE/.$ID.launch-request.$digest"
  SPAWN_LAUNCH_EXECUTED="$SPAWN_LAUNCH_REQUEST/executed"
  SPAWN_LAUNCH_OUTCOME="$SPAWN_LAUNCH_REQUEST/outcome"
  SPAWN_LAUNCH_GUARD="$STATE/.$ID.launch-execution.$digest"
  SPAWN_LAUNCH_REQUEST_TOKEN="$SPAWN_DISPATCH_TRANSACTION:$LAUNCH_BRIEF_HASH"
}

spawn_launch_guard_state_at() {
  local guard=$1 owner child value pid token
  if [ ! -e "$guard" ] && [ ! -L "$guard" ]; then
    printf 'absent'
    return 0
  fi
  [ -d "$guard" ] && [ ! -L "$guard" ] || return 1
  owner="$guard/owner"
  child="$guard/child"
  if [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    printf 'abandoned'
    return 0
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] \
    && [ "$(spawn_file_link_count "$owner")" = 1 ] || return 1
  value=$(tr -d '\n' < "$owner") || return 1
  pid=${value%%:*}
  token=${value#*:}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
  if [ -e "$child" ] || [ -L "$child" ]; then
    [ -f "$child" ] && [ ! -L "$child" ] \
      && [ "$(spawn_file_link_count "$child")" = 1 ] || return 1
    value=$(tr -d '\n' < "$child") || return 1
    pid=${value%%:*}
    token=${value#*:}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    if kill -0 "$pid" 2>/dev/null; then
      printf 'running'
    else
      printf 'exited'
    fi
  elif kill -0 "$pid" 2>/dev/null; then
    printf 'starting'
  else
    printf 'abandoned'
  fi
}

spawn_launch_guard_state() {
  spawn_launch_guard_state_at "$SPAWN_LAUNCH_GUARD"
}

spawn_launch_child_exec_state() {
  local child="$SPAWN_LAUNCH_GUARD/child" value pid token command
  [ -f "$child" ] && [ ! -L "$child" ] \
    && [ "$(spawn_file_link_count "$child")" = 1 ] || { printf 'starting'; return 0; }
  value=$(tr -d '\n' < "$child") || return 1
  pid=${value%%:*}
  token=${value#*:}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
  kill -0 "$pid" 2>/dev/null || { printf 'exited'; return 0; }
  command=$(ps -o comm= -p "$pid" 2>/dev/null | awk 'NF { print $1; exit }') || return 1
  command=${command##*/}
  case "$command" in
    ''|sh|bash|dash|zsh|ksh) printf 'starting' ;;
    *) printf 'executed' ;;
  esac
}

spawn_launch_guard_cleanup_retryable() {
  local state entry retired restore=0
  state=$(spawn_launch_guard_state) || return 1
  case "$state" in absent) return 0 ;; abandoned) ;; *) return 1 ;; esac
  [ ! -e "$SPAWN_LAUNCH_EXECUTED" ] && [ ! -L "$SPAWN_LAUNCH_EXECUTED" ] || return 1
  retired=$(umask 077; mktemp -d "$STATE/.$ID.launch-execution-retired.XXXXXX") || return 1
  rmdir -- "$retired" || return 1
  mv -- "$SPAWN_LAUNCH_GUARD" "$retired" || return 1
  state=$(spawn_launch_guard_state_at "$retired") || restore=1
  if [ "$restore" -eq 0 ]; then
    case "$state" in abandoned|starting) ;; *) restore=1 ;; esac
  fi
  if [ -e "$retired/child" ] || [ -L "$retired/child" ]; then restore=1; fi
  if [ "$restore" -eq 1 ]; then
    mv -- "$retired" "$SPAWN_LAUNCH_GUARD" || return 1
    return 1
  fi
  for entry in "$retired"/* "$retired"/.[!.]* "$retired"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in owner|.owner.tmp|.child.tmp) ;; *) restore=1; break ;; esac
    [ -f "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(spawn_file_link_count "$entry")" = 1 ] || { restore=1; break; }
  done
  if [ "$restore" -eq 1 ]; then
    mv -- "$retired" "$SPAWN_LAUNCH_GUARD" || return 1
    return 1
  fi
  for entry in "$retired"/* "$retired"/.[!.]* "$retired"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    rm -f -- "$entry" || return 1
  done
  rmdir -- "$retired"
}

spawn_launch_guard_cleanup_terminal() {
  local state entry retired
  state=$(spawn_launch_guard_state) || return 1
  case "$state" in absent) return 0 ;; exited|abandoned) ;; *) return 1 ;; esac
  retired=$(umask 077; mktemp -d "$STATE/.$ID.launch-execution-retired.XXXXXX") || return 1
  rmdir -- "$retired" || return 1
  mv -- "$SPAWN_LAUNCH_GUARD" "$retired" || return 1
  state=$(spawn_launch_guard_state_at "$retired") || return 1
  case "$state" in exited|abandoned) ;; *) return 1 ;; esac
  for entry in "$retired"/* "$retired"/.[!.]* "$retired"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in owner|child|.owner.tmp|.child.tmp) ;; *) return 1 ;; esac
    [ -f "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(spawn_file_link_count "$entry")" = 1 ] || return 1
  done
  rm -rf -- "$retired"
}

spawn_launch_request_file_matches() {  # <path> <value>
  local path=$1 value=$2 links bytes
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(spawn_file_link_count "$path") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 512 ] || return 1
  printf '%s\n' "$value" | cmp -s "$path" -
}

spawn_launch_request_state() {
  local owner pid outcome guard_state
  spawn_launch_request_paths || return 1
  if [ ! -e "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ]; then
    printf 'absent'
    return 0
  fi
  [ -d "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ] || return 1
  guard_state=$(spawn_launch_guard_state) || return 1
  if [ -e "$SPAWN_LAUNCH_OUTCOME" ] || [ -L "$SPAWN_LAUNCH_OUTCOME" ]; then
    [ -f "$SPAWN_LAUNCH_OUTCOME" ] && [ ! -L "$SPAWN_LAUNCH_OUTCOME" ] || return 1
    [ "$(spawn_file_link_count "$SPAWN_LAUNCH_OUTCOME")" = 1 ] || return 1
    outcome=$(tr -d '\n' < "$SPAWN_LAUNCH_OUTCOME") || return 1
    case "$outcome" in
      "running:$SPAWN_LAUNCH_REQUEST_TOKEN")
        case "$guard_state" in running) printf 'executed' ;; exited|abandoned) printf 'launch-exited' ;; *) printf 'accepted' ;; esac
        ;;
      "exited:"*":$SPAWN_LAUNCH_REQUEST_TOKEN")
        outcome=${outcome#exited:}
        outcome=${outcome%:"$SPAWN_LAUNCH_REQUEST_TOKEN"}
        case "$outcome" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$outcome" -eq 0 ]; then
          printf 'launch-exited'
        else
          printf 'launch-failed'
        fi
        ;;
      *) return 1 ;;
    esac
    return 0
  fi
  if [ -e "$SPAWN_LAUNCH_EXECUTED" ] || [ -L "$SPAWN_LAUNCH_EXECUTED" ]; then
    spawn_launch_request_file_matches "$SPAWN_LAUNCH_EXECUTED" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
    case "$guard_state" in
      running) printf 'executed' ;;
      exited|abandoned) printf 'launch-exited' ;;
      *) printf 'accepted' ;;
    esac
    return 0
  fi
  case "$guard_state" in
    running|starting)
      printf 'accepted'
      return 0
      ;;
    exited)
      printf 'launch-exited'
      return 0
      ;;
    abandoned)
      printf 'launch-abandoned'
      return 0
      ;;
  esac
  if [ -e "$SPAWN_LAUNCH_REQUEST/accepted" ] || [ -L "$SPAWN_LAUNCH_REQUEST/accepted" ]; then
    spawn_launch_request_file_matches "$SPAWN_LAUNCH_REQUEST/accepted" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
    printf 'accepted'
    return 0
  fi
  owner="$SPAWN_LAUNCH_REQUEST/owner"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  [ "$(spawn_file_link_count "$owner")" = 1 ] || return 1
  pid=$(tr -d '[:space:]' < "$owner")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -e "$SPAWN_LAUNCH_REQUEST/attempted" ] || [ -L "$SPAWN_LAUNCH_REQUEST/attempted" ]; then
    spawn_launch_request_file_matches "$SPAWN_LAUNCH_REQUEST/attempted" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
    if [ -e "$SPAWN_LAUNCH_REQUEST/failed" ] || [ -L "$SPAWN_LAUNCH_REQUEST/failed" ]; then
      [ -f "$SPAWN_LAUNCH_REQUEST/failed" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST/failed" ] || return 1
      printf 'failed'
    elif kill -0 "$pid" 2>/dev/null; then
      printf 'attempted-live'
    else
      printf 'attempted-dead'
    fi
  elif kill -0 "$pid" 2>/dev/null; then
    printf 'unattempted-live'
  else
    printf 'unattempted-dead'
  fi
}

spawn_launch_request_cleanup() {
  local entry
  spawn_launch_request_paths || return 1
  if [ ! -e "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ]; then return 0; fi
  [ -d "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ] || return 1
  if [ -e "$SPAWN_LAUNCH_REQUEST/kimi-submission" ] \
    || [ -L "$SPAWN_LAUNCH_REQUEST/kimi-submission" ]; then
    kimi_submission_cleanup_preflight || return 1
  fi
  for entry in "$SPAWN_LAUNCH_REQUEST"/* "$SPAWN_LAUNCH_REQUEST"/.[!.]* "$SPAWN_LAUNCH_REQUEST"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in owner|attempted|accepted|failed|executed|outcome|kimi-submission|kimi-submit-owner|kimi-submit-go|kimi-submit-attempted|kimi-submit-attempted.entering|kimi-submit-attempted.entering.baseline|kimi-submit-attempted.operation-owner|kimi-submit-attempted.operation-started|kimi-submit-attempted.operation-result|kimi-submit-result|.owner.tmp|.attempted.tmp|.accepted.tmp|.failed.tmp|.executed.tmp|.outcome.tmp|.kimi-submission.tmp|.kimi-submit-owner.tmp|.kimi-submit-go.tmp|.kimi-submit-attempted.tmp|.kimi-submit-attempted.entering.tmp.*|.kimi-submit-attempted.entering.baseline.tmp.*|.kimi-submit-attempted.operation-owner.tmp.*|.kimi-submit-attempted.operation-started.tmp.*|.kimi-submit-attempted.operation-result.tmp.*|.kimi-submit-result.tmp) ;; *) return 1 ;; esac
    [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
    [ "$(spawn_file_link_count "$entry")" = 1 ] || return 1
    rm -f -- "$entry" || return 1
  done
  rmdir -- "$SPAWN_LAUNCH_REQUEST"
}

spawn_launch_request_helper() {  # <command>
  local command=$1 rc=0 tmp
  set +e
  umask 077
  mkdir -m 700 -- "$SPAWN_LAUNCH_REQUEST" 2>/dev/null || exit 0
  tmp="$SPAWN_LAUNCH_REQUEST/.owner.tmp"
  printf '%s\n' "${BASHPID:-$$}" > "$tmp" && chmod 600 "$tmp" \
    && mv -- "$tmp" "$SPAWN_LAUNCH_REQUEST/owner" || exit 1
  spawn_send_launch_line "$T" "$command" || rc=$?
  tmp="$SPAWN_LAUNCH_REQUEST/.attempted.tmp"
  printf '%s\n' "$SPAWN_LAUNCH_REQUEST_TOKEN" > "$tmp" && chmod 600 "$tmp" \
    && mv -- "$tmp" "$SPAWN_LAUNCH_REQUEST/attempted" || exit 1
  if [ "$rc" -eq 0 ]; then
    tmp="$SPAWN_LAUNCH_REQUEST/.accepted.tmp"
    printf '%s\n' "$SPAWN_LAUNCH_REQUEST_TOKEN" > "$tmp" && chmod 600 "$tmp" \
      && mv -- "$tmp" "$SPAWN_LAUNCH_REQUEST/accepted" || exit 1
    exit 0
  fi
  tmp="$SPAWN_LAUNCH_REQUEST/.failed.tmp"
  printf '%s\n' "$rc" > "$tmp" && chmod 600 "$tmp" \
    && mv -- "$tmp" "$SPAWN_LAUNCH_REQUEST/failed"
  exit "$rc"
}

spawn_launch_request_start() {  # <command>
  local command=$1 helper_pid i=0
  spawn_launch_request_paths || return 1
  [ ! -e "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ] || return 0
  (trap - EXIT; trap '' HUP INT TERM; spawn_launch_request_helper "$command") \
    </dev/null >/dev/null 2>&1 &
  helper_pid=$!
  while kill -0 "$helper_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    if [ -d "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ] \
       && { [ -e "$SPAWN_LAUNCH_REQUEST/attempted" ] \
         || [ -L "$SPAWN_LAUNCH_REQUEST/attempted" ]; }; then
      break
    fi
    sleep 0.01
    i=$((i + 1))
  done
  [ -d "$SPAWN_LAUNCH_REQUEST" ] && [ ! -L "$SPAWN_LAUNCH_REQUEST" ]
}

spawn_launch_request_wait() {
  local state agent_state guard_state i=0 max=${FM_SPAWN_LAUNCH_POLLS:-100} interval=${FM_SPAWN_LAUNCH_INTERVAL:-0.1}
  while [ "$i" -lt "$max" ]; do
    state=$(spawn_launch_request_state) || return 1
    case "$state" in
      accepted|executed|attempted-live)
        guard_state=$(spawn_launch_guard_state) || return 1
        if [ "$guard_state" = running ] \
          && [ "$(spawn_launch_child_exec_state)" = executed ]; then
          return 0
        fi
        agent_state=$(fm_backend_agent_state "$BACKEND" "$T")
        [ "$agent_state" != alive ] || return 0
        ;;
      launch-exited)
        [ "$KIND" != secondmate ] || return 2
        return 0
        ;;
      failed|attempted-dead|launch-abandoned|launch-failed) return 2 ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 3
}

spawn_launch_acceptance_wait() {
  local state i=0 max=${FM_SPAWN_LAUNCH_POLLS:-100} interval=${FM_SPAWN_LAUNCH_INTERVAL:-0.1}
  while [ "$i" -lt "$max" ]; do
    state=$(spawn_launch_request_state) || return 1
    case "$state" in
      accepted|executed) return 0 ;;
      launch-exited|failed|attempted-dead|launch-abandoned|launch-failed) return 2 ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 3
}

spawn_launch_delivery_wait() {
  if [ "$KIND" = secondmate ]; then
    spawn_launch_request_wait
  else
    spawn_launch_acceptance_wait
  fi
}

spawn_endpoint_receipt_commitment_load() {  # <state-inode> <base>
  local state_inode=$1 base=$2 state kind _dev inode mode links bytes _mtime _ctime extra commitment
  state=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe \
    "$STATE" "$state_inode" "$base") || return 1
  IFS=: read -r kind _dev inode mode links bytes _mtime _ctime extra <<EOF
$state
EOF
  [ -z "$extra" ] && [ "$kind" = regular ] || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 65536 ] || return 1
  commitment=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe-digest \
    "$STATE" "$state_inode" "$base" "$bytes") || return 1
  IFS=$'\t' read -r SPAWN_ENDPOINT_ENTRY_STATE SPAWN_ENDPOINT_ENTRY_DIGEST extra <<EOF
$commitment
EOF
  [ -z "$extra" ] && [ "$SPAWN_ENDPOINT_ENTRY_STATE" = "$state" ] || return 1
  case "$SPAWN_ENDPOINT_ENTRY_DIGEST" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#SPAWN_ENDPOINT_ENTRY_DIGEST}" -eq 64 ]
}

spawn_endpoint_receipt_retire() {
  local base state_inode
  [ -n "$SPAWN_ENDPOINT_RECEIPT" ] || return 1
  [ -n "$SPAWN_ENDPOINT_ENTRY_STATE" ] && [ -n "$SPAWN_ENDPOINT_ENTRY_DIGEST" ] || return 1
  base=$(basename -- "$SPAWN_ENDPOINT_RECEIPT") || return 1
  state_inode=$(spawn_file_inode_identity "$STATE") || return 1
  python3 "$SCRIPT_DIR/fm-work-identity-fs.py" remove \
    "$STATE" "$state_inode" "$base" \
    "$SPAWN_ENDPOINT_ENTRY_STATE" "$SPAWN_ENDPOINT_ENTRY_DIGEST" >/dev/null || return 1
  SPAWN_ENDPOINT_PHASE=
  SPAWN_ENDPOINT_ENTRY_STATE=
  SPAWN_ENDPOINT_ENTRY_DIGEST=
}

spawn_endpoint_receipt_publish() {  # <phase> [worktree]
  local phase=$1 worktree=${2:-} details payload payload_digest tmp base state_inode rc=0
  local source_details source_state source_digest
  case "$phase" in endpoint-creating|endpoint-created|worktree-unsent|worktree-requesting|worktree-requested|worktree-retryable|worktree-acquired|worktree-ready|launch-prepared|launch-submitted) ;; *) return 1 ;; esac
  case "$BACKEND" in
    tmux)
      details=$(jq -n -S -c --arg session "${SES:-}" --arg window_id "${WT_TARGET:-}" \
        '{session:$session,window_id:$window_id}') || return 1
      ;;
    herdr)
      details=$(jq -n -S -c --arg session "${HERDR_SES:-}" \
        --arg workspace_id "${HERDR_WORKSPACE_ID:-}" --arg tab_id "${HERDR_TAB_ID:-}" \
        --arg pane_id "${HERDR_PANE_ID:-}" \
        '{session:$session,workspace_id:$workspace_id,tab_id:$tab_id,pane_id:$pane_id}') || return 1
      ;;
    zellij)
      details=$(jq -n -S -c --arg session "${ZELLIJ_SES:-}" \
        --arg tab_id "${ZELLIJ_TAB_ID:-}" --arg pane_id "${ZELLIJ_PANE_ID:-}" \
        '{session:$session,tab_id:$tab_id,pane_id:$pane_id}') || return 1
      ;;
    cmux)
      details=$(jq -n -S -c --arg workspace_id "${CMUX_WORKSPACE_ID:-}" \
        --arg surface_id "${CMUX_SURFACE_ID:-}" \
        '{workspace_id:$workspace_id,surface_id:$surface_id}') || return 1
      ;;
    orca)
      details=$(jq -n -S -c --arg worktree_id "${ORCA_WORKTREE_ID:-}" \
        --arg terminal "${ORCA_TERMINAL:-}" \
        '{worktree_id:$worktree_id,terminal:$terminal}') || return 1
      ;;
    *) return 1 ;;
  esac
  payload=$(jq -n -S -c \
    --arg schema fm-spawn-endpoint.v1 --arg phase "$phase" \
    --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
    --arg transaction "$SPAWN_DISPATCH_TRANSACTION" \
    --arg instructions_sha256 "$LAUNCH_BRIEF_HASH" --arg backend "$BACKEND" \
    --arg kind "$KIND" --arg project "$PROJ_ABS" --arg label "$W" --arg target "${T:-}" \
    --arg worktree "$worktree" --argjson details "$details" \
    '{schema:$schema,phase:$phase,binding:{home:$home,home_id:$home_id,task_id:$task},
      transaction_id:$transaction,instructions_sha256:$instructions_sha256,
      backend:$backend,kind:$kind,project:$project,
      endpoint:{label:$label,target:(if $phase == "endpoint-creating" and $target == "" then null else $target end),details:$details},
      worktree:(if $worktree == "" then null else $worktree end)}') || return 1
  payload_digest=$(printf '%s\n' "$payload" | spawn_sha256_stream) || return 1
  tmp=$(umask 077; mktemp "$STATE/.$ID.spawn-endpoint.XXXXXX") || return 1
  if ! printf '%s\n' "$payload" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  base=$(basename -- "$SPAWN_ENDPOINT_RECEIPT") || { rm -f -- "$tmp"; return 1; }
  state_inode=$(spawn_file_inode_identity "$STATE") || { rm -f -- "$tmp"; return 1; }
  source_details=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe-source "$tmp" 65536) \
    || { rm -f -- "$tmp"; return 1; }
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  [ "$source_state" != "$source_details" ] && [ "$source_digest" = "$payload_digest" ] \
    || { rm -f -- "$tmp"; return 1; }
  if [ -z "$SPAWN_ENDPOINT_PHASE" ]; then
    python3 "$SCRIPT_DIR/fm-work-identity-fs.py" no-clobber \
      "$STATE" "$state_inode" "$base" "$tmp" "${base}.publishing" \
      "$source_state" "$source_digest" >/dev/null || rc=$?
  else
    [ -n "$SPAWN_ENDPOINT_ENTRY_STATE" ] && [ -n "$SPAWN_ENDPOINT_ENTRY_DIGEST" ] \
      || { rm -f -- "$tmp"; return 1; }
    python3 "$SCRIPT_DIR/fm-work-identity-fs.py" replace \
      "$STATE" "$state_inode" "$base" "$tmp" \
      "$SPAWN_ENDPOINT_ENTRY_STATE" "$SPAWN_ENDPOINT_ENTRY_DIGEST" \
      "$source_state" "$source_digest" >/dev/null || rc=$?
  fi
  rm -f -- "$tmp" || return 1
  [ "$rc" -eq 0 ] || return "$rc"
  spawn_endpoint_receipt_commitment_load "$state_inode" "$base" || return 1
  [ "$SPAWN_ENDPOINT_ENTRY_DIGEST" = "$payload_digest" ] || return 1
  SPAWN_ENDPOINT_PHASE=$phase
  if [ "$KIND" = secondmate ] && [ "$SECONDMATE_RESERVATION_PENDING" -eq 1 ]; then
    SECONDMATE_RESERVATION_PRESERVE=1
  fi
}

spawn_endpoint_receipt_load() {
  local receipt=$SPAWN_ENDPOINT_RECEIPT canonical receipt_snapshot target worktree details
  local base state_inode
  base=$(basename -- "$receipt") || return 1
  state_inode=$(spawn_file_inode_identity "$STATE") || return 1
  spawn_endpoint_receipt_commitment_load "$state_inode" "$base" || {
    echo "error: spawn endpoint receipt is unsafe: $receipt" >&2
    return 1
  }
  receipt_snapshot=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" snapshot \
    "$STATE" "$state_inode" "$base" \
    "$SPAWN_ENDPOINT_ENTRY_STATE" "$SPAWN_ENDPOINT_ENTRY_DIGEST") || return 1
  [ "${#receipt_snapshot}" -le 65535 ] \
    || { echo "error: spawn endpoint receipt is oversized: $receipt" >&2; return 1; }
  canonical=$(printf '%s\n' "$receipt_snapshot" | jq -e -S -c -s \
    --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
    --arg transaction "$SPAWN_DISPATCH_TRANSACTION" \
    --arg instructions_sha256 "$LAUNCH_BRIEF_HASH" --arg backend "$BACKEND" \
    --arg kind "$KIND" --arg project "$PROJ_ABS" --arg label "$W" '
      def exact($keys): (keys | sort) == ($keys | sort);
      select(length == 1) | .[0] | . as $r | select(
        type == "object"
        and exact(["schema","phase","binding","transaction_id","instructions_sha256","backend","kind","project","endpoint","worktree"])
        and .schema == "fm-spawn-endpoint.v1"
        and (.phase == "endpoint-creating" or .phase == "endpoint-created"
          or .phase == "worktree-unsent" or .phase == "worktree-requesting"
          or .phase == "worktree-requested" or .phase == "worktree-retryable"
          or .phase == "worktree-acquired" or .phase == "worktree-ready"
          or .phase == "launch-prepared" or .phase == "launch-submitted")
        and .binding == {home:$home,home_id:$home_id,task_id:$task}
        and .transaction_id == $transaction and .instructions_sha256 == $instructions_sha256
        and .backend == $backend and .kind == $kind and .project == $project
        and (.endpoint | type == "object" and exact(["label","target","details"])
          and .label == $label
          and (if $r.phase == "endpoint-creating" then (.target == null or (.target | type) == "string")
               else (.target | type) == "string" and (.target | length) > 0 end)
          and (.details | type) == "object"
          and (if $backend == "tmux" then (.details | exact(["session","window_id"]))
               elif $backend == "herdr" then (.details | exact(["session","workspace_id","tab_id","pane_id"]))
               elif $backend == "zellij" then (.details | exact(["session","tab_id","pane_id"]))
               elif $backend == "cmux" then (.details | exact(["workspace_id","surface_id"]))
               elif $backend == "orca" then (.details | exact(["worktree_id","terminal"]))
               else false end))
        and (.worktree == null or (.worktree | type) == "string")
        and (if .phase == "worktree-ready" or .phase == "worktree-acquired"
               or .phase == "launch-prepared" or .phase == "launch-submitted"
             then (.worktree | type) == "string" and (.worktree | length) > 0
             elif .phase == "endpoint-creating" or .phase == "worktree-retryable" then .worktree == null
             else true end)
        and (if .phase == "worktree-retryable" or .phase == "worktree-acquired" then
               ($backend == "zellij" or $backend == "cmux")
             else true end)
      ) | $r
    ' 2>/dev/null) || {
      echo "error: spawn endpoint receipt is malformed or mismatched: $receipt" >&2
      return 1
    }
  [ "$canonical" = "$receipt_snapshot" ] || {
    echo "error: spawn endpoint receipt is not canonical: $receipt" >&2
    return 1
  }
  SPAWN_ENDPOINT_PHASE=$(printf '%s' "$canonical" | jq -r '.phase') || return 1
  if [ "$KIND" = secondmate ] && [ "$SECONDMATE_RESERVATION_PENDING" -eq 1 ]; then
    SECONDMATE_RESERVATION_PRESERVE=1
  fi
  if [ "$SPAWN_ENDPOINT_PHASE" = endpoint-creating ]; then
    SPAWN_ENDPOINT_CREATING_RECOVERY=1
    return 0
  fi
  target=$(printf '%s' "$canonical" | jq -r '.endpoint.target') || return 1
  worktree=$(printf '%s' "$canonical" | jq -r '.worktree // ""') || return 1
  details=$(printf '%s' "$canonical" | jq -c '.endpoint.details') || return 1
  T=$target
  WT=$worktree
  case "$BACKEND" in
    tmux)
      printf '%s' "$details" | jq -e '(keys | sort) == (["session","window_id"] | sort)' >/dev/null \
        || return 1
      SES=$(printf '%s' "$details" | jq -er '.session | select(length > 0)') || return 1
      WT_TARGET=$(printf '%s' "$details" | jq -r '.window_id // ""') || return 1
      [ -n "$WT_TARGET" ] || WT_TARGET=$T
      [ "$T" = "$SES:$W" ] || return 1
      ;;
    herdr)
      printf '%s' "$details" | jq -e '(keys | sort) == (["session","workspace_id","tab_id","pane_id"] | sort)' >/dev/null \
        || return 1
      HERDR_SES=$(printf '%s' "$details" | jq -er '.session | select(length > 0)') || return 1
      HERDR_WORKSPACE_ID=$(printf '%s' "$details" | jq -er '.workspace_id | select(length > 0)') || return 1
      HERDR_TAB_ID=$(printf '%s' "$details" | jq -er '.tab_id | select(length > 0)') || return 1
      HERDR_PANE_ID=$(printf '%s' "$details" | jq -er '.pane_id | select(length > 0)') || return 1
      [ "$T" = "$HERDR_SES:$HERDR_PANE_ID" ] || return 1
      WT_TARGET=$T
      ;;
    zellij)
      printf '%s' "$details" | jq -e '(keys | sort) == (["session","tab_id","pane_id"] | sort)' >/dev/null \
        || return 1
      ZELLIJ_SES=$(printf '%s' "$details" | jq -er '.session | select(length > 0)') || return 1
      ZELLIJ_TAB_ID=$(printf '%s' "$details" | jq -er '.tab_id | select(length > 0)') || return 1
      ZELLIJ_PANE_ID=$(printf '%s' "$details" | jq -er '.pane_id | select(length > 0)') || return 1
      [ "$T" = "$ZELLIJ_SES:$ZELLIJ_PANE_ID" ] || return 1
      WT_TARGET=$T
      ;;
    cmux)
      printf '%s' "$details" | jq -e '(keys | sort) == (["workspace_id","surface_id"] | sort)' >/dev/null \
        || return 1
      CMUX_WORKSPACE_ID=$(printf '%s' "$details" | jq -er '.workspace_id | select(length > 0)') || return 1
      CMUX_SURFACE_ID=$(printf '%s' "$details" | jq -er '.surface_id | select(length > 0)') || return 1
      [ "$T" = "$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID" ] || return 1
      WT_TARGET=$T
      ;;
    orca)
      printf '%s' "$details" | jq -e '(keys | sort) == (["worktree_id","terminal"] | sort)' >/dev/null \
        || return 1
      ORCA_WORKTREE_ID=$(printf '%s' "$details" | jq -er '.worktree_id | select(length > 0)') || return 1
      ORCA_TERMINAL=$(printf '%s' "$details" | jq -er '.terminal | select(length > 0)') || return 1
      [ "$T" = "$ORCA_TERMINAL" ] || return 1
      WT_TARGET=$T
      ;;
    *) return 1 ;;
  esac
  if [ -n "$WT" ]; then
    spawn_endpoint_worktree_binding_valid || {
      echo "error: recorded spawn worktree is invalid or cross-project for $ID: $WT" >&2
      return 1
    }
  fi
  if [ "$KIND" != secondmate ]; then
    spawn_provisional_harness_wiring_recover || return 1
  fi
  if ! fm_backend_target_exists "$BACKEND" "$target" "$W"; then
    endpoint_state=$(fm_backend_agent_state "$BACKEND" "$target")
    if [ "$endpoint_state" = missing ]; then
      case "$SPAWN_ENDPOINT_PHASE" in
        launch-prepared|launch-submitted) SPAWN_ENDPOINT_MISSING=1 ;;
        *)
          echo "error: recorded spawn endpoint is gone for $ID: $target" >&2
          return 2
          ;;
      esac
    else
      echo "error: recorded spawn endpoint is unavailable for $ID: $target" >&2
      return 1
    fi
  fi
  if [ "$BACKEND" = tmux ] || [ "$BACKEND" = herdr ]; then
    endpoint_state=$(fm_backend_agent_state "$BACKEND" "$target")
    case "$SPAWN_ENDPOINT_PHASE:$endpoint_state" in
      launch-prepared:*) ;;
      launch-submitted:*) SPAWN_LAUNCH_SUBMITTED_RECOVERY=1 ;;
      worktree-requesting:dead|worktree-requesting:ambiguous|worktree-requested:dead|worktree-requested:ambiguous) ;;
      *:dead) ;;
      *)
        echo "error: recorded spawn endpoint is not safely recoverable for $ID: $target ($endpoint_state)" >&2
        return 1
        ;;
    esac
  elif [ "$SPAWN_ENDPOINT_PHASE" = launch-submitted ]; then
    SPAWN_LAUNCH_SUBMITTED_RECOVERY=1
  fi
  SPAWN_ENDPOINT_RECOVERED=1
}

spawn_endpoint_worktree_binding_valid() {
  local wt_real project_real wt_top wt_top_real wt_common project_common
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || return 1
  project_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || return 1
  if [ "$KIND" = secondmate ]; then
    [ "$wt_real" = "$project_real" ]
    return
  fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || return 1
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || return 1
  [ "$wt_real" = "$wt_top_real" ] && [ "$wt_real" != "$project_real" ] || return 1
  wt_common=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(git -C "$PROJ_ABS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$wt_common" = "$project_common" ]
}

spawn_orca_operation_prepare() {
  if [ -e "$SPAWN_ORCA_OPERATION" ] || [ -L "$SPAWN_ORCA_OPERATION" ]; then
    [ -d "$SPAWN_ORCA_OPERATION" ] && [ ! -L "$SPAWN_ORCA_OPERATION" ] || {
      echo "error: Orca endpoint operation path is unsafe: $SPAWN_ORCA_OPERATION" >&2
      return 1
    }
  else
    (umask 077; mkdir "$SPAWN_ORCA_OPERATION") || return 1
  fi
}

spawn_orca_operation_publish() {  # <result|failure> <payload>
  local kind=$1 payload=$2 tmp target rc=0
  case "$kind" in
    result) target="$SPAWN_ORCA_OPERATION/result.json" ;;
    failure) target="$SPAWN_ORCA_OPERATION/failure.json" ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$SPAWN_ORCA_OPERATION/.${kind}.XXXXXX") || return 1
  if ! printf '%s\n' "$payload" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_backend_orca_no_clobber_publish "$tmp" "$target" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2)
      cmp -s "$tmp" "$target"
      rc=$?
      rm -f -- "$tmp"
      return "$rc"
      ;;
    *) rm -f -- "$tmp"; return 1 ;;
  esac
}

spawn_orca_operation_helper() {
  local claim_tmp claim_rc create_response terminal_response raw rc wt_id='' wt_path='' terminal='' payload rest wt_real wt_top wt_top_real proj_real failure_reason=creation orca_name orca_name_digest
  set +e
  claim_tmp=$(umask 077; mktemp "$SPAWN_ORCA_OPERATION/.claim.XXXXXX") || exit 1
  printf '%s\n' "${BASHPID:-$$}" > "$claim_tmp" || { rm -f -- "$claim_tmp"; exit 1; }
  claim_rc=0
  fm_backend_orca_no_clobber_publish "$claim_tmp" "$SPAWN_ORCA_OPERATION/claim" || claim_rc=$?
  case "$claim_rc" in
    0) ;;
    2) rm -f -- "$claim_tmp"; exit 0 ;;
    *) rm -f -- "$claim_tmp"; exit 1 ;;
  esac

  create_response="$SPAWN_ORCA_OPERATION/create-response.json"
  orca_name_digest=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION" | spawn_sha256_stream) || exit 1
  orca_name="$W-${orca_name_digest:0:16}"
  raw=$(fm_backend_orca_worktree_create_durable "$PROJ_ABS" "$orca_name" "$create_response")
  rc=$?
  if [ "$rc" -eq "$FM_BACKEND_ORCA_WORKTREE_CREATE_IN_PROGRESS" ]; then
    exit "$FM_BACKEND_ORCA_WORKTREE_CREATE_IN_PROGRESS"
  fi
  if [ -n "$raw" ]; then
    wt_id=${raw%%$'\t'*}
    if [ "$raw" != "$wt_id" ]; then
      rest=${raw#*$'\t'}
      wt_path=${rest%%$'\t'*}
      if [ "$rest" != "$wt_path" ]; then terminal=${rest#*$'\t'}; fi
    fi
  fi
  if [ "$rc" -eq 3 ] && [ -z "$raw" ]; then
    failure_reason=compensated
  elif [ "$rc" -ne 0 ] && [ -n "$wt_id" ] && [ -z "$wt_path" ]; then
    failure_reason=path
  fi
  if [ "$rc" -eq 0 ] && [ -n "$wt_id" ] && [ -n "$wt_path" ]; then
    wt_real=$(cd "$wt_path" 2>/dev/null && pwd -P)
    wt_top=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null)
    wt_top_real=
    [ -z "$wt_top" ] || wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P)
    proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P)
    if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] \
       || [ "$wt_real" = "$proj_real" ]; then
      rc=3
      failure_reason=isolation
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -z "$terminal" ]; then
    terminal_response="$SPAWN_ORCA_OPERATION/terminal-response.json"
    terminal=$(fm_backend_orca_terminal_create_durable "$wt_id" "$W" \
      "$terminal_response" "$SPAWN_ORCA_OPERATION/terminal-create")
    rc=$?
    [ "$rc" -ne "$FM_BACKEND_ORCA_TERMINAL_CREATE_IN_PROGRESS" ] \
      || exit "$FM_BACKEND_ORCA_TERMINAL_CREATE_IN_PROGRESS"
    [ "$rc" -eq 0 ] || failure_reason=terminal
  fi
  if [ "$rc" -eq 0 ] && [ -n "$wt_id" ] && [ -n "$wt_path" ] && [ -n "$terminal" ]; then
    payload=$(jq -n -S -c \
      --arg schema fm-spawn-orca-endpoint.v1 \
      --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
      --arg transaction "$SPAWN_DISPATCH_TRANSACTION" --arg project "$PROJ_ABS" --arg label "$W" \
      --arg worktree_id "$wt_id" --arg worktree "$wt_path" --arg terminal "$terminal" \
      '{schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},
        transaction_id:$transaction,project:$project,label:$label,
        worktree_id:$worktree_id,worktree:$worktree,terminal:$terminal}') || rc=1
    if [ "$rc" -eq 0 ] && spawn_orca_operation_publish result "$payload"; then
      exit 0
    fi
    exit 1
  fi

  payload=$(jq -n -S -c \
    --arg schema fm-spawn-orca-operation-failure.v1 \
    --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
    --arg transaction "$SPAWN_DISPATCH_TRANSACTION" --arg project "$PROJ_ABS" --arg label "$W" \
    --arg reason "$failure_reason" --arg worktree_id "$wt_id" --arg worktree "$wt_path" --arg terminal "$terminal" \
    '{schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},
      transaction_id:$transaction,project:$project,label:$label,reason:$reason,
      worktree_id:(if $worktree_id == "" then null else $worktree_id end),
      worktree:(if $worktree == "" then null else $worktree end),
      terminal:(if $terminal == "" then null else $terminal end)}') || exit 1
  spawn_orca_operation_publish failure "$payload" || exit 1
  exit 1
}

spawn_orca_operation_start() {
  local error_file="$SPAWN_ORCA_OPERATION/helper.err" links
  if [ -e "$error_file" ] || [ -L "$error_file" ]; then
    [ -f "$error_file" ] && [ ! -L "$error_file" ] || return 1
    links=$(spawn_file_link_count "$error_file") || return 1
    [ "$links" = 1 ] || return 1
    : > "$error_file" || return 1
  else
    (umask 077; : > "$error_file") || return 1
  fi
  (trap - EXIT; trap '' HUP INT TERM; spawn_orca_operation_helper) \
    </dev/null >/dev/null 2>"$error_file" &
}

spawn_orca_operation_load() {  # 0=result, 2=in progress, 3=unclaimed, 4=creator exited, 6=recoverable response
  local file canonical links pid failure_reason create_response_recoverable=0
  for file in \
    "$SPAWN_ORCA_OPERATION/result.json" \
    "$SPAWN_ORCA_OPERATION/failure.json" \
    "$SPAWN_ORCA_OPERATION/claim" \
    "$SPAWN_ORCA_OPERATION/terminal-response.json" \
    "$SPAWN_ORCA_OPERATION/terminal-create.pid" \
    "$SPAWN_ORCA_OPERATION/terminal-create.start" \
    "$SPAWN_ORCA_OPERATION/terminal-create.status"
  do
    fm_backend_orca_no_clobber_recover "$file" || return 1
  done
  file="$SPAWN_ORCA_OPERATION/result.json"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    links=$(spawn_file_link_count "$file") || return 1
    [ "$links" = 1 ] || return 1
    canonical=$(jq -e -S -c -s \
      --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
      --arg transaction "$SPAWN_DISPATCH_TRANSACTION" --arg project "$PROJ_ABS" --arg label "$W" '
        def exact($keys): (keys | sort) == ($keys | sort);
        select(length == 1) | .[0] | . as $r | select(
          type == "object"
          and exact(["schema","binding","transaction_id","project","label","worktree_id","worktree","terminal"])
          and .schema == "fm-spawn-orca-endpoint.v1"
          and .binding == {home:$home,home_id:$home_id,task_id:$task}
          and .transaction_id == $transaction and .project == $project and .label == $label
          and ([.worktree_id,.worktree,.terminal] | all(type == "string" and length > 0))
        ) | $r
      ' "$file" 2>/dev/null) || return 1
    printf '%s\n' "$canonical" | cmp -s "$file" - || return 1
    ORCA_WORKTREE_ID=$(printf '%s' "$canonical" | jq -r '.worktree_id') || return 1
    WT=$(printf '%s' "$canonical" | jq -r '.worktree') || return 1
    ORCA_TERMINAL=$(printf '%s' "$canonical" | jq -r '.terminal') || return 1
    return 0
  fi

  file="$SPAWN_ORCA_OPERATION/failure.json"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    links=$(spawn_file_link_count "$file") || return 1
    [ "$links" = 1 ] || return 1
    canonical=$(jq -e -S -c -s \
      --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" --arg task "$ID" \
      --arg transaction "$SPAWN_DISPATCH_TRANSACTION" --arg project "$PROJ_ABS" --arg label "$W" '
        def exact($keys): (keys | sort) == ($keys | sort);
        select(length == 1) | .[0] | . as $r | select(
          type == "object"
          and exact(["schema","binding","transaction_id","project","label","reason","worktree_id","worktree","terminal"])
          and .schema == "fm-spawn-orca-operation-failure.v1"
          and .binding == {home:$home,home_id:$home_id,task_id:$task}
          and .transaction_id == $transaction and .project == $project and .label == $label
          and (.reason == "creation" or .reason == "isolation" or .reason == "path"
            or .reason == "terminal" or .reason == "compensated")
          and ([.worktree_id,.worktree,.terminal] | all(. == null or (type == "string" and length > 0)))
          and (if .reason == "compensated" then
            .worktree_id == null and .worktree == null and .terminal == null
          else true end)
        ) | $r
      ' "$file" 2>/dev/null) || return 1
    printf '%s\n' "$canonical" | cmp -s "$file" - || return 1
    ORCA_WORKTREE_ID=$(printf '%s' "$canonical" | jq -r '.worktree_id // ""') || return 1
    WT=$(printf '%s' "$canonical" | jq -r '.worktree // ""') || return 1
    ORCA_TERMINAL=$(printf '%s' "$canonical" | jq -r '.terminal // ""') || return 1
    failure_reason=$(printf '%s' "$canonical" | jq -r '.reason') || return 1
    [ -z "$ORCA_WORKTREE_ID" ] || ORCA_ABORT_CLEANUP=1
    case "$failure_reason" in
      compensated) return 5 ;;
      isolation)
        echo "error: orca worktree create did not yield an isolated worktree (resolved '$WT'; primary '$PROJ_ABS')" >&2
        ;;
      path)
        echo "error: orca worktree create did not return a path for $W" >&2
        ;;
      *)
        echo "error: Orca endpoint creation failed for $ID; exact partial resources are preserved for cleanup" >&2
        ;;
    esac
    return 1
  fi

  file="$SPAWN_ORCA_OPERATION/create-response.json"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    links=$(spawn_file_link_count "$file") || return 1
    [ "$links" = 1 ] || return 1
    [ "$(LC_ALL=C wc -c < "$file" | tr -d ' ')" -le 65536 ] || return 1
    create_response_recoverable=1
  fi

  file="$SPAWN_ORCA_OPERATION/claim"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 3; fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  links=$(spawn_file_link_count "$file") || return 1
  [ "$links" = 1 ] || return 1
  pid=$(tr -d '[:space:]' < "$file")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then return 2; fi
  [ "$create_response_recoverable" -eq 0 ] || return 6
  return 4
}

spawn_orca_operation_wait() {
  local status dispatch_abort_rc=0 started=0 creator_exited=0 i=0 max=${FM_SPAWN_ORCA_CREATE_POLLS:-600} interval=${FM_SPAWN_ORCA_CREATE_INTERVAL:-0.1}
  while [ "$i" -lt "$max" ]; do
    set +e
    spawn_orca_operation_load
    status=$?
    set -e
    case "$status" in
      0) return 0 ;;
      3)
        if [ "$started" -eq 0 ]; then
          spawn_orca_operation_start || return 1
          started=1
        fi
        ;;
      2) creator_exited=0 ;;
      4)
        creator_exited=$((creator_exited + 1))
        if [ "$creator_exited" -ge 10 ]; then
          [ ! -s "$SPAWN_ORCA_OPERATION/helper.err" ] || cat "$SPAWN_ORCA_OPERATION/helper.err" >&2
          echo "error: Orca endpoint creator stopped without a recoverable result for $ID" >&2
          return 1
        fi
        ;;
      6)
        creator_exited=$((creator_exited + 1))
        if [ "$creator_exited" -ge 10 ]; then
          rm -f -- "$SPAWN_ORCA_OPERATION/claim" || return 1
          spawn_orca_operation_start || return 1
          started=1
          creator_exited=0
        fi
        ;;
      5)
        [ ! -s "$SPAWN_ORCA_OPERATION/helper.err" ] || cat "$SPAWN_ORCA_OPERATION/helper.err" >&2
        spawn_orca_operation_retire || {
          echo "error: compensated Orca endpoint journal could not be retired for $ID" >&2
          return 1
        }
        spawn_endpoint_receipt_retire || {
          echo "error: compensated Orca endpoint receipt could not be retired for $ID" >&2
          return 1
        }
        FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
          FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-work-identity.sh" \
          dispatch-abort "$ID" --transaction "$SPAWN_DISPATCH_TRANSACTION" >/dev/null 2>&1 \
          || dispatch_abort_rc=$?
        case "$dispatch_abort_rc" in
          0) SPAWN_DISPATCH_PENDING=0 ;;
          *)
            echo "error: compensated Orca work identity dispatch requires reconciliation for $ID" >&2
            return 1
            ;;
        esac
        echo "error: Orca endpoint creation failed without leaving resources; rerun spawn to retry" >&2
        return 1
        ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  echo "error: Orca endpoint creation is still in progress for $ID; rerun spawn to resume it" >&2
  return 1
}

spawn_orca_operation_retire() {
  local retired
  [ -n "$SPAWN_ORCA_OPERATION" ] || return 0
  if [ ! -e "$SPAWN_ORCA_OPERATION" ] && [ ! -L "$SPAWN_ORCA_OPERATION" ]; then return 0; fi
  [ -d "$SPAWN_ORCA_OPERATION" ] && [ ! -L "$SPAWN_ORCA_OPERATION" ] || return 1
  retired=$(umask 077; mktemp -d "$STATE/.$ID.spawn-orca-retired.XXXXXX") || return 1
  rmdir -- "$retired" || return 1
  mv -- "$SPAWN_ORCA_OPERATION" "$retired" || return 1
  rm -rf -- "$retired" 2>/dev/null || true
}

spawn_metadata_transaction_published() {
  local meta="$STATE/$ID.meta" links count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  links=$(spawn_file_link_count "$meta") || return 1
  [ "$links" = 1 ] || return 1
  count=$(grep -Fxc "work_identity_dispatch_transaction=$SPAWN_DISPATCH_TRANSACTION" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ]
}

spawn_abort_cleanup() {
  local status=$? orca_cleanup_compensated=0 orca_resource_cleanup_ok=1
  local preserve_published_launch=0 launch_abort_state
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] \
     && [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] \
     && spawn_metadata_transaction_published; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
        "$RELAUNCH_REPLACEMENT_HARNESS" \
        "$RELAUNCH_REPLACEMENT_WT" \
        "$RELAUNCH_REPLACEMENT_STATE" \
        "$ID" \
        "$RELAUNCH_REPLACEMENT_AUTH_PATH"; then
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
    if [ -n "${ORCA_TERMINAL:-}" ] \
      && ! fm_backend_orca_terminal_close_exact "$ORCA_TERMINAL" --absent-ok >/dev/null 2>&1; then
      orca_resource_cleanup_ok=0
      echo "warning: Orca terminal cleanup could not be confirmed; preserving the exact endpoint receipt and operation journal for recovery" >&2
    fi
    if [ "$orca_resource_cleanup_ok" = 1 ] && [ -n "${ORCA_WORKTREE_ID:-}" ] \
      && ! fm_backend_orca_remove_worktree "$ORCA_WORKTREE_ID" --absent-ok >/dev/null 2>&1; then
      orca_resource_cleanup_ok=0
      echo "warning: Orca worktree cleanup could not be confirmed; preserving the exact endpoint receipt and operation journal for recovery" >&2
    fi
    [ "$orca_resource_cleanup_ok" -ne 1 ] || orca_cleanup_compensated=1
  fi
  if [ "$orca_cleanup_compensated" = 1 ]; then
    if ! spawn_orca_operation_retire 2>/dev/null; then
      echo "warning: compensated Orca operation journal could not be retired; preserving its endpoint receipt for recovery" >&2
    elif [ -n "$SPAWN_ENDPOINT_RECEIPT" ] \
      && ! spawn_endpoint_receipt_retire 2>/dev/null; then
      echo "warning: compensated Orca endpoint receipt could not be retired; work identity dispatch requires reconciliation" >&2
    fi
  fi
  if [ "$SPAWN_DISPATCH_PENDING" = 1 ]; then
    local dispatch_abort_rc=0
    SPAWN_DISPATCH_PENDING=0
    if [ -n "$SPAWN_ENDPOINT_RECEIPT" ] \
       && { [ -e "$SPAWN_ENDPOINT_RECEIPT" ] || [ -L "$SPAWN_ENDPOINT_RECEIPT" ]; }; then
      echo "warning: work identity dispatch for $ID is preserved with its endpoint receipt for recovery" >&2
    else
      FM_HOME="$FM_HOME" \
        FM_DATA_OVERRIDE="$DATA" \
        FM_STATE_OVERRIDE="$STATE" \
        FM_ROOT_OVERRIDE="$FM_ROOT" \
        "$SCRIPT_DIR/fm-work-identity.sh" dispatch-abort "$ID" \
          --transaction "$SPAWN_DISPATCH_TRANSACTION" >/dev/null 2>&1 \
        || dispatch_abort_rc=$?
      case "$dispatch_abort_rc" in
        0|4) ;;
        *) echo "warning: work identity dispatch for $ID requires reconciliation" >&2 ;;
      esac
    fi
  fi
  if [ "$SECONDMATE_RESERVATION_PENDING" -eq 1 ] \
     && [ "$SECONDMATE_RESERVATION_PRESERVE" -eq 0 ]; then
    local reservation_abort_rc=0
    SECONDMATE_RESERVATION_PENDING=0
    FM_HOME="$FM_HOME" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-work-identity.sh" unlinked-abort "$ID" \
        --transaction "$SECONDMATE_RESERVATION_TRANSACTION" >/dev/null 2>&1 \
      || reservation_abort_rc=$?
    case "$reservation_abort_rc" in
      0|4) ;;
      *) echo "warning: persistent secondmate identity reservation for $ID requires reconciliation" >&2 ;;
    esac
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    case "$SPAWN_ENDPOINT_PHASE" in
      launch-submitted) preserve_published_launch=1 ;;
      launch-prepared)
        launch_abort_state=$(spawn_launch_request_state 2>/dev/null || printf ambiguous)
        case "$launch_abort_state" in
          accepted|executed|launch-exited|launch-failed|attempted-live|unattempted-live) preserve_published_launch=1 ;;
        esac
        ;;
    esac
  fi
  if [ "$preserve_published_launch" = 1 ]; then
    SPAWN_FRESH_COMMIT_PENDING=0
    SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
    echo "warning: published task metadata and exact launch evidence for $ID were preserved for retry" >&2
  else
    if [ "$SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING" = 1 ]; then
      if spawn_provisional_harness_wiring_retire; then
        SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
      else
        status=1
      fi
    fi
    if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ] \
       && [ "$SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING" = 0 ] \
       && ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
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
  [ -z "$SPAWN_BRIEF_TMP" ] || rm -f "$SPAWN_BRIEF_TMP" 2>/dev/null || true
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

clear_relaunch_harness_wiring() {
  local harness=$1 wt=$2 state=$3 id=$4 recorded_auth_path=${5:-}
  local token_path token auth_path path
  # The wiring arms above match on harness PREFIXES, because a task launched
  # from a raw command records that command's basename rather than the exact
  # adapter name. The retirement tables are keyed by the exact adapter, so the
  # recorded value is resolved to its adapter first; otherwise a task recorded
  # as, say, `grok-2` would have wiring armed and never retired. An
  # unrecognized value resolves to no adapter, which is also the case in which
  # no wiring was armed to begin with.
  harness=$(fm_control_harness_family "$harness") || harness=
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state" "$id") || return 1
  token=
  if [ -n "$token_path" ] && { [ -e "$token_path" ] || [ -L "$token_path" ]; }; then
    [ -f "$token_path" ] && [ ! -L "$token_path" ] \
      && [ "$(spawn_file_link_count "$token_path")" = 1 ] || return 1
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  if [ -n "$recorded_auth_path" ]; then
    fm_control_harness_turnend_auth_record_valid \
      "$harness" "$token" "$recorded_auth_path" || return 1
    auth_path=$recorded_auth_path
  else
    auth_path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  fi
  if [ -n "$auth_path" ]; then
    fm_control_harness_turnend_auth_remove_exact \
      "$harness" "$token" "$auth_path" "$state/$id.turn-ended" || return 1
  fi
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
  # One delivery contract applies to every pair in a batch, exactly like the shared
  # harness. Each pair still re-validates it against its own brief, so a batch
  # spanning several modes is two invocations rather than a silent mixed dispatch.
  [ "$MODE_SET" -eq 0 ] || shared_args+=(--mode "$MODE")
  [ "$YOLO_SET" -eq 0 ] || shared_args+=(--yolo "$YOLO")
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
SECONDMATE_WORK_IDENTITY_SCHEMA=
SECONDMATE_WORK_IDENTITY_STATUS=
SECONDMATE_RESERVATION_TRANSACTION="secondmate-spawn:$ID"
prepare_secondmate_work_identity() {
  SECONDMATE_RESERVATION_PENDING=1
  SECONDMATE_WORK_IDENTITY_JSON=$(
    FM_HOME="$FM_HOME" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-work-identity.sh" unlinked-prepare "$ID" \
        --reason persistent-secondmate \
        --transaction "$SECONDMATE_RESERVATION_TRANSACTION"
  ) || return 1
  SECONDMATE_WORK_IDENTITY_SCHEMA=$(printf '%s' "$SECONDMATE_WORK_IDENTITY_JSON" | jq -er '.schema') \
    || { echo "error: persistent secondmate work identity projection is malformed for $ID" >&2; return 1; }
  SECONDMATE_WORK_IDENTITY_STATUS=$(printf '%s' "$SECONDMATE_WORK_IDENTITY_JSON" | jq -er '.status') \
    || { echo "error: persistent secondmate work identity projection is malformed for $ID" >&2; return 1; }
  [ "$SECONDMATE_WORK_IDENTITY_STATUS" = unlinked ] || {
    echo "error: persistent secondmate control task $ID cannot carry a linked work identity; route exact work units to tasks in the secondmate home" >&2
    return 1
  }
}

commit_secondmate_work_identity() {
  SECONDMATE_WORK_IDENTITY_JSON=$(
    FM_HOME="$FM_HOME" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-work-identity.sh" unlinked-commit "$ID" \
        --transaction "$SECONDMATE_RESERVATION_TRANSACTION"
  ) || return 1
  SECONDMATE_WORK_IDENTITY_SCHEMA=$(printf '%s' "$SECONDMATE_WORK_IDENTITY_JSON" | jq -er '.schema') \
    || return 1
  SECONDMATE_WORK_IDENTITY_STATUS=$(printf '%s' "$SECONDMATE_WORK_IDENTITY_JSON" | jq -er '.status') \
    || return 1
  [ "$SECONDMATE_WORK_IDENTITY_STATUS" = unlinked ] || return 1
  SECONDMATE_RESERVATION_PENDING=0
  SECONDMATE_RESERVATION_PRESERVE=0
}
if [ "$KIND" = secondmate ]; then
  if spawn_remote_secondmate "$ID"; then
    exit 0
  else
    remote_spawn_rc=$?
  fi
  [ "$remote_spawn_rc" -eq 3 ] || exit "$remote_spawn_rc"
fi
# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$RELAUNCH" -eq 0 ]; then
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
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
PROJ=
ARG3=
FIRSTMATE_HOME=

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
  fm_backend_validate_task_endpoint "$RELAUNCH_META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  RELAUNCH_TARGET=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  # A relaunch must PROVE the previous agent is gone before it launches another
  # one into the same endpoint, and only tmux and herdr have a recovery-grade
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
  MODE=$(fm_meta_get "$RELAUNCH_META" mode)
  YOLO=$(fm_meta_get "$RELAUNCH_META" yolo)
  RELAUNCH_WT=$(fm_meta_get "$RELAUNCH_META" worktree)
  [ -n "$RELAUNCH_WT" ] && [ -d "$RELAUNCH_WT" ] || {
    echo "error: task $ID's recorded worktree '${RELAUNCH_WT:-none}' is missing; refusing to relaunch without the local copy its work lives in" >&2
    exit 1
  }
  if [ "$KIND" = secondmate ]; then
    FIRSTMATE_HOME=$(fm_meta_get "$RELAUNCH_META" home)
    [ -n "$FIRSTMATE_HOME" ] || FIRSTMATE_HOME=$RELAUNCH_WT
  else
    PROJ=$(fm_meta_get "$RELAUNCH_META" project)
    [ -n "$PROJ" ] || {
      echo "error: task $ID has no recorded project; refusing to relaunch" >&2
      exit 1
    }
  fi
  if [ "$BACKEND" = herdr ]; then
    HERDR_SES=$(fm_meta_get "$RELAUNCH_META" herdr_session)
    HERDR_WORKSPACE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_workspace_id)
    HERDR_TAB_ID=$(fm_meta_get "$RELAUNCH_META" herdr_tab_id)
    HERDR_PANE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_pane_id)
  fi
  # With no explicit harness, a relaunch reuses the harness already recorded
  # for this task. It must NOT fall through to the fresh-spawn config
  # resolution, which would silently move an existing task onto whatever the
  # crew or secondmate default currently says. Choosing a different harness is
  # the caller's explicit decision, made with --harness (bin/fm-control.sh
  # resolves that decision, including a secondmate's durable pin).
  ARG3=${HARNESS_ARG:-$RELAUNCH_PRIOR_HARNESS}
  [ -n "$ARG3" ] || {
    echo "error: task $ID has no recorded harness; pass --harness to relaunch it" >&2
    exit 1
  }
elif [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse)
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
if [ "$KIND" = secondmate ]; then
  if [ "$RELAUNCH" -eq 1 ] && [ -n "$(fm_meta_get "$RELAUNCH_META" remote_host)" ]; then
    if spawn_remote_secondmate "$ID"; then
      exit 0
    else
      remote_spawn_rc=$?
    fi
    [ "$remote_spawn_rc" -eq 3 ] || exit "$remote_spawn_rc"
    echo "error: task $ID records a remote secondmate endpoint but has no remote registry route" >&2
    exit 1
  fi
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

render_launch() {
  local template=$1 output='' prefix rest token marker replacement
  while [[ "$template" == *"__"* ]]; do
    prefix=${template%%__*}
    rest=${template#*__}
    if [[ "$rest" != *"__"* ]]; then
      output="${output}${prefix}__${rest}"
      template=
      break
    fi
    token=${rest%%__*}
    template=${rest#*__}
    marker="__${token}__"
    replacement=$marker
    case "$marker" in
      __MODELFLAG__) replacement=$MODELFLAG ;;
      __EFFORTFLAG__) replacement=$EFFORTFLAG ;;
      __TURNEND__) replacement=$sq_turnend ;;
      __PIEXT__) replacement=$sq_piext ;;
      __PITURNEND__) replacement=$sq_piturnend ;;
      __PIWATCH__) replacement=$sq_piwatch ;;
      __WORKTREE__) replacement=$sq_worktree ;;
      __BRIEF__) replacement=$sq_brief ;;
      __BRIEFINPUT__) replacement=$sq_brief_input ;;
      __PITUIMODE__) [ "${PI_TUI_MODE+x}" = x ] && replacement=$PI_TUI_MODE ;;
      __PIBIN__) [ -z "${PI_BIN:-}" ] || replacement=$(shell_quote "$PI_BIN") ;;
      __CURSORBIN__) [ -z "${CURSOR_BIN:-}" ] || replacement=$(shell_quote "$CURSOR_BIN") ;;
      __KIMIBIN__) [ -z "${KIMI_BIN:-}" ] || replacement=$(shell_quote "$KIMI_BIN") ;;
      __MUSEBIN__) [ -z "${MUSE_BIN:-}" ] || replacement=$(shell_quote "$MUSE_BIN") ;;
      __MUSECONFIG__) [ -z "${MUSE_CONFIG_HOME:-}" ] || replacement=$(shell_quote "$MUSE_CONFIG_HOME") ;;
      __MUSEDATA__) [ -z "${MUSE_DATA_HOME:-}" ] || replacement=$(shell_quote "$MUSE_DATA_HOME") ;;
    esac
    output="${output}${prefix}${replacement}"
  done
  printf '%s' "${output}${template}"
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG____BRIEFINPUT__' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox __BRIEFINPUT__'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" __BRIEFINPUT__'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt __BRIEFINPUT__' ;;
    pi|pi-signed)
      printf '%s' '__PIBIN____PITUIMODE__'
      if [ "$kind" = secondmate ]; then
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ __BRIEFINPUT__'
      else
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ __BRIEFINPUT__'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG____BRIEFINPUT__' ;;
    # Cursor Agent CLI. --trust suppresses the workspace-trust prompt, which
    # --yolo does NOT cover and which would otherwise block every spawn, since
    # each task gets a fresh worktree path cursor has never seen. --yolo is the
    # --force alias whose TUI label is "Run Everything". --workspace pins the
    # exact worktree. -w/--worktree is deliberately never passed: it allocates a
    # SECOND worktree under ~/.cursor/worktrees and would break firstmate's
    # isolation contract. The binary is resolved rather than named because
    # `cursor` is not the CLI (the installed names are cursor-agent and the
    # legacy alias agent), and the foreign primary markers are cleared so an
    # inherited CLAUDECODE cannot outrank cursor's own marker in a process that
    # only reads the environment. Cursor exposes no effort flag, so the shared
    # effort axis is deliberately omitted and stays in task metadata only.
    cursor) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS __CURSORBIN__ --trust --yolo __MODELFLAG__--workspace __WORKTREE__ __BRIEFINPUT__' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # the captured immutable operational input after the TUI readiness gate below.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task worktree token, so no launch placeholder belongs here.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    # muse (Muse Code): a positional prompt starts the supervised interactive
    # session. --yolo is the single flag that makes a crewmate pane viable: muse
    # ships approval prompts AND a filesystem/network sandbox ON by default
    # (--sandbox-network defaults to proxy-only, which refuses outright without a
    # managed proxy), and it gates a fresh workspace behind a trust dialog. One
    # --yolo disables approval, disables the sandbox so git and network work, and
    # trusts the workspace for the run, so no dialog appears on the fresh
    # per-task worktree (verified, muse 0.1.0-R708.1).
    # MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on is the privacy control:
    # muse otherwise loads the OPERATOR's foreign personal rules from ~/.claude
    # into every run and ships them to Meta-hosted inference, even under an
    # isolated XDG_CONFIG_HOME. exec mode's --no-foreign-personal-context flag is
    # NOT accepted by the interactive TUI (it exits with "unexpected argument"),
    # so this env var is the only control that reaches a pane worker. Verified to
    # drop the foreign rules_file context block while KEEPING the project's own
    # AGENTS.md rules, which the crewmate contract depends on.
    # muse's turn-end signal rides neither the launch command nor a hook: its
    # plugin engine is off in the default build, so firstmate folds muse's own
    # session event log instead (bin/fm-busy-lib.sh), bound by the sidecar
    # written below. Nothing to place in the template for it.
    # codex, opencode, and kimi are also markerless and share this inherited-marker hazard; changing their verified launch boundaries belongs in follow-up work.
    muse) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=__MUSECONFIG__ XDG_DATA_HOME=__MUSEDATA__ MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on __MUSEBIN__ --yolo __MODELFLAG____EFFORTFLAG____BRIEFINPUT__' ;;
    *) return 1 ;;
  esac
}

RAW_LAUNCH=0
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    RAW_LAUNCH=1
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

if [ "$KIND" = secondmate ] && [ "$RAW_LAUNCH" -eq 1 ]; then
  if [[ "$LAUNCH" == *[';&|<>`']* || "$LAUNCH" == *"\$("* \
    || "$LAUNCH" == *$'\n'* || "$LAUNCH" == *$'\r'* ]]; then
    echo "error: a local secondmate raw launch must be one simple executable command; shell pipelines, compounds, substitutions, and redirections cannot prove the persistent process boundary" >&2
    exit 1
  fi
fi

# muse is verified as a CREWMATE/SCOUT adapter only. A secondmate is a firstmate
# instance, so it needs a primary supervision protocol; muse has none, and its
# Claude-compatible hook dialect explicitly rejects the model-reawakening and
# asyncRewake handlers that firstmate's primary turn-end supervision is built on
# (muse 0.1.0-R708.1). Refusing here keeps that gap loud instead of standing up a
# secondmate whose supervision cycle could never be armed.
if [ "$KIND" = secondmate ] && [ "$HARNESS" = muse ]; then
  echo "error: muse is a verified crewmate/scout adapter only and cannot run a secondmate; it has no primary supervision protocol. Select a harness verified for secondmates." >&2
  exit 1
fi

case "$HARNESS" in
  pi|pi-signed)
    PI_BIN=$(resolve_pi_executable "$HARNESS") || {
      echo "error: $HARNESS executable not found on PATH; install it or select a different verified harness" >&2
      exit 1
    }
    PI_TUI_MODE=
    if pi_supports_tui_mode "$PI_BIN"; then
      PI_TUI_MODE=' --tui-mode regular'
    fi
    LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH"
    ;;
  cursor)
    # `cursor` is not the CLI name, and the legacy alias `agent` is far too
    # generic to launch on its name alone, so resolution runs through the
    # verified owner rather than a bare command lookup. Refusing here keeps a
    # missing install a loud spawn refusal instead of a pane that dies with a
    # command-not-found the supervisor would read as a wedged worker.
    CURSOR_BIN=$(fm_cursor_resolve_binary) || exit 1
    if [ -n "$MODEL" ] && [ "$MODEL" != default ]; then
      if CURSOR_MODELS=$(fm_cursor_list_models "$CURSOR_BIN"); then
        if ! printf '%s\n' "$CURSOR_MODELS" | fm_cursor_catalog_has_model "$MODEL"; then
          echo "error: Cursor model '$MODEL' is not available from '$CURSOR_BIN --list-models'; choose an id listed by that command or omit --model" >&2
          exit 1
        fi
      fi
    fi
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
  secondmate_registry_field "$DATA/secondmates.md" "$1" "$2"
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

resolve_muse_binary() {
  local candidate dir
  candidate=$(command -v muse 2>/dev/null || true)
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
  echo "error: muse executable not found on PATH; install Muse Code or select a different verified harness" >&2
  return 1
}

# muse_credential_present: 0 when a launched muse pane can reach its provider
# without an interactive login. muse offers exactly two credential paths
# (verified, muse 0.1.0-R708.1): the META_API_KEY environment variable, which
# always takes priority, and a stored credential written by `muse auth set` or
# `muse login` into <config>/muse/auth.json. This is a PREFLIGHT rather than a
# rendered-screen check because an unauthenticated pane does not exit - it sits
# on an OAuth device-code prompt ("Sign in at this page ... Waiting for
# approval...") waiting for a human who is not there, which would look to
# supervision like a wedged worker rather than a missing credential.
muse_worker_meta_api_key_present() {
  local session worker_env
  [ "$BACKEND" = tmux ] || return 1
  if [ -n "${TMUX:-}" ]; then
    session=$(tmux display-message -p '#S' 2>/dev/null) || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || return 1
    session=firstmate
  fi
  worker_env=$(tmux show-environment -t "$session" META_API_KEY 2>/dev/null) || return 1
  case "$worker_env" in
    META_API_KEY=?*) return 0 ;;
  esac
  return 1
}

muse_credential_present() {
  local auth=$1
  [ -s "$auth" ] || muse_worker_meta_api_key_present
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse)
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
    muse)
      # muse 0.1.0-R708.1 --reasoning-effort accepts none|minimal|low|medium|
      # high|xhigh|ultra and defaults to high, so low..xhigh map straight across.
      # ultra is muse's max-CLASS level, so firstmate's max maps onto it - but
      # only ever as an EXPLICIT captain choice, never as a fallback, because
      # AGENTS.md section 4 forbids selecting max without captain preference and
      # the omitted effort here leaves muse on its own high default. muse's extra
      # none/minimal levels sit below firstmate's shared vocabulary and are
      # deliberately unreachable rather than remapped onto low.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
        max) printf -- '--reasoning-effort %s ' "$(shell_quote ultra)" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command. Cursor encodes effort
    # in model ids such as cursor-grok-4.5-high, so it also receives no separate
    # effort flag.
  esac
}

case "$LAUNCH" in
  *__MUSEBIN__*)
    MUSE_BIN=$(resolve_muse_binary) || exit 1
    MUSE_CONFIG_HOME=$(resolve_directory_input XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-${HOME:-}/.config}") || exit 1
    MUSE_DATA_HOME=$(resolve_directory_input XDG_DATA_HOME "${XDG_DATA_HOME:-${HOME:-}/.local/share}") || exit 1
    MUSE_AUTH_FILE="$MUSE_CONFIG_HOME/muse/auth.json"
    if ! muse_credential_present "$MUSE_AUTH_FILE"; then
      if [ -n "${META_API_KEY:-}" ]; then
        echo "error: muse has no worker-reachable credential; META_API_KEY is set for fm-spawn but cannot be proven present in the $BACKEND worker environment. Store the fleet credential at '$MUSE_AUTH_FILE' with 'muse login' or 'muse auth set --api-key-stdin'. The secret will not be copied into the launch command." >&2
      else
        echo "error: muse has no worker-reachable credential; META_API_KEY cannot be proven present in the $BACKEND worker environment and '$MUSE_AUTH_FILE' is absent or empty. Store the fleet credential with 'muse login' or 'muse auth set --api-key-stdin'." >&2
      fi
      exit 1
    fi
    ;;
esac

case "$LAUNCH" in
  *__KIMIBIN__*)
    KIMI_BIN=$(resolve_kimi_binary) || exit 1
    if [ "$KIND" = secondmate ] && [ "$BACKEND" != tmux ]; then
      echo "error: persistent Kimi secondmates require backend=tmux; Herdr does not expose a transaction-scoped prompt receipt" >&2
      exit 1
    fi
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
  if [ -z "$FIRSTMATE_HOME" ] && { [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; }; then
    fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE" || {
      echo "error: secondmate task record is unsafe: $FM_BACKLOG_TRANSITION_ERROR" >&2
      exit 1
    }
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  SECONDMATE_PREPARATION_RECOVERY=0
  if [ -e "$STATE/$ID.spawn-endpoint.json" ] || [ -L "$STATE/$ID.spawn-endpoint.json" ]; then
    SECONDMATE_PREPARATION_RECOVERY=1
  fi
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  if [ -e "$DATA/secondmates.md" ] || [ -L "$DATA/secondmates.md" ]; then
    if ! secondmate_registry_validate_bindings "$DATA/secondmates.md" resolve_path "$ID" "$FIRSTMATE_HOME"; then
      echo "error: $SECONDMATE_REGISTRY_ERROR" >&2
      exit 1
    fi
    SECONDMATE_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
  fi
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
  [ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
  prepare_secondmate_work_identity || exit 1
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ] \
     && [ "$SECONDMATE_PREPARATION_RECOVERY" -eq 0 ]; then
    CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
      echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    }
    if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
      echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    fi
    CONFIG_INHERIT_LOCK_HELD=1
  fi
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if [ "$SECONDMATE_PREPARATION_RECOVERY" -eq 0 ]; then
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
  fi
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ] \
     && [ "$SECONDMATE_PREPARATION_RECOVERY" -eq 0 ]; then
    # Inheritance propagation: push the primary-authoritative live-safe local inheritance
    # surface into this secondmate home (fm-config-inherit-lib.sh).
    FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
      || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2; exit 1; }
BRIEF_SOURCE=$BRIEF
mkdir -p "$STATE" || { echo "error: could not create state directory for launch brief" >&2; exit 1; }
STATE=$(cd -P "$STATE" && pwd -P) \
  || { echo "error: could not anchor state directory for launch brief" >&2; exit 1; }
BRIEF_SNAPSHOT="$STATE/$ID.launch-brief.md"
SPAWN_ENDPOINT_RECEIPT="$STATE/$ID.spawn-endpoint.json"
SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT="$STATE/$ID.harness-wiring-provisional.json"
[ "$BACKEND" != orca ] || SPAWN_ORCA_OPERATION="$STATE/$ID.spawn-orca-operation"
SPAWN_ENDPOINT_BASE=$(basename -- "$SPAWN_ENDPOINT_RECEIPT") || exit 1
SPAWN_STATE_INODE=$(spawn_file_inode_identity "$STATE") || exit 1
SPAWN_ENDPOINT_REMOVAL_JOURNAL="$STATE/.$SPAWN_ENDPOINT_BASE.remove-journal"
SPAWN_ENDPOINT_REMOVAL_PENDING=0
if [ -e "$SPAWN_ENDPOINT_REMOVAL_JOURNAL" ] || [ -L "$SPAWN_ENDPOINT_REMOVAL_JOURNAL" ]; then
  SPAWN_ENDPOINT_REMOVAL_PENDING=1
fi
SPAWN_ENDPOINT_RAW_STATE=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe-raw \
  "$STATE" "$SPAWN_STATE_INODE" "$SPAWN_ENDPOINT_BASE") || {
  echo "error: spawn endpoint receipt recovery is unsafe for $ID" >&2
  exit 1
}
if [ "$SPAWN_ENDPOINT_REMOVAL_PENDING" -eq 1 ] && [ "$SPAWN_ENDPOINT_RAW_STATE" = absent ]; then
  SPAWN_ENDPOINT_RETIREMENT_RECOVERED=1
fi
if [ -e "$BRIEF_SNAPSHOT" ] || [ -L "$BRIEF_SNAPSHOT" ]; then
  [ -f "$BRIEF_SNAPSHOT" ] && [ ! -L "$BRIEF_SNAPSHOT" ] \
    || { echo "error: launch brief snapshot path is unsafe: $BRIEF_SNAPSHOT" >&2; exit 1; }
fi
SPAWN_BRIEF_TMP=$(umask 077; mktemp "$STATE/.$ID.launch-brief.XXXXXX") \
  || { echo "error: could not create launch brief snapshot" >&2; exit 1; }
cp "$BRIEF_SOURCE" "$SPAWN_BRIEF_TMP" \
  || { echo "error: could not snapshot launch brief at $BRIEF_SOURCE" >&2; exit 1; }
chmod 400 "$SPAWN_BRIEF_TMP" \
  || { echo "error: could not protect launch brief snapshot" >&2; exit 1; }

spawn_sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

WORK_IDENTITY_STATUS=
WORK_IDENTITY_SCHEMA=
WORK_IDENTITY_HASH=
LAUNCH_BRIEF_HASH=
SPAWN_DISPATCH_TRANSACTION="spawn:${BASHPID:-$$}:$(date +%s):$RANDOM"
WORK_IDENTITY_ARGS=(dispatch-prepare "$ID" --brief "$SPAWN_BRIEF_TMP" \
  --instructions-path "$BRIEF_SNAPSHOT" --transaction "$SPAWN_DISPATCH_TRANSACTION")
if [ "$RELAUNCH" -eq 0 ]; then
  WORK_IDENTITY_ARGS+=(--resume)
fi
if [ "$RELAUNCH" -eq 1 ]; then
  PRIOR_LAUNCH_BRIEF=$(fm_meta_get "$RELAUNCH_META" launch_brief)
  if [ -z "$PRIOR_LAUNCH_BRIEF" ] || { [ ! -e "$PRIOR_LAUNCH_BRIEF" ] && [ ! -L "$PRIOR_LAUNCH_BRIEF" ]; }; then
    if [ -e "$STATE/$ID.control-relaunch.brief-prior" ] || [ -L "$STATE/$ID.control-relaunch.brief-prior" ]; then
      PRIOR_LAUNCH_BRIEF="$STATE/$ID.control-relaunch.brief-prior"
    else
      PRIOR_LAUNCH_BRIEF=$BRIEF_SOURCE
    fi
  fi
  WORK_IDENTITY_ARGS+=(--meta "$RELAUNCH_META" --prior-brief "$PRIOR_LAUNCH_BRIEF")
fi
WORK_DISPATCH_JSON=$(
  FM_HOME="$FM_HOME" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-work-identity.sh" "${WORK_IDENTITY_ARGS[@]}"
) || exit 1
SPAWN_DISPATCH_PENDING=1
SPAWN_DISPATCH_TRANSACTION=$(printf '%s' "$WORK_DISPATCH_JSON" | jq -er '.transaction_id') \
  || { echo "error: work identity dispatch binding has no transaction receipt for $ID" >&2; exit 1; }
WORK_IDENTITY_JSON=$(printf '%s' "$WORK_DISPATCH_JSON" | jq -ec '.work_identity') \
  || { echo "error: work identity dispatch binding is malformed for $ID" >&2; exit 1; }
LAUNCH_BRIEF_HASH=$(printf '%s' "$WORK_DISPATCH_JSON" | jq -er '.instructions_sha256') \
  || { echo "error: work identity dispatch binding has no instructions digest for $ID" >&2; exit 1; }
WORK_IDENTITY_STATUS=$(printf '%s' "$WORK_IDENTITY_JSON" | jq -er '.status') \
  || { echo "error: work identity projection has no status for $ID" >&2; exit 1; }
WORK_IDENTITY_SCHEMA=$(printf '%s' "$WORK_IDENTITY_JSON" | jq -er '.schema') \
  || { echo "error: work identity projection has no schema for $ID" >&2; exit 1; }
WORK_IDENTITY_HASH=$(printf '%s' "$WORK_IDENTITY_JSON" | jq -r '.sha256 // ""')
SPAWN_IDENTITY_HOME=$(printf '%s' "$WORK_IDENTITY_JSON" | jq -er '.binding.home') \
  || { echo "error: work identity projection has no physical home binding for $ID" >&2; exit 1; }
SPAWN_IDENTITY_HOME_ID=$(printf '%s' "$WORK_IDENTITY_JSON" | jq -er '.binding.home_id') \
  || { echo "error: work identity projection has no home binding for $ID" >&2; exit 1; }
rm -f -- "$SPAWN_BRIEF_TMP" \
  || { echo "error: could not retire validated launch brief candidate" >&2; exit 1; }
SPAWN_BRIEF_TMP=
BRIEF=$BRIEF_SNAPSHOT
SPAWN_BRIEF_BODY=$(cat "$BRIEF" || exit $?; printf '\034') \
  || { echo "error: could not capture validated launch brief" >&2; exit 1; }
SPAWN_BRIEF_BODY=${SPAWN_BRIEF_BODY%$'\034'}
CAPTURED_BRIEF_HASH=$(printf '%s' "$SPAWN_BRIEF_BODY" | spawn_sha256_stream) \
  || { echo "error: could not hash captured launch brief" >&2; exit 1; }
if [ -n "$LAUNCH_BRIEF_HASH" ] && [ "$CAPTURED_BRIEF_HASH" != "$LAUNCH_BRIEF_HASH" ]; then
  echo "error: launch brief changed after identity validation: $BRIEF" >&2
  exit 1
fi
LAUNCH_BRIEF_HASH=$CAPTURED_BRIEF_HASH
# shellcheck source=bin/fm-operational-input.sh
# shellcheck disable=SC1091
. "$FM_ROOT/bin/fm-operational-input.sh"
fm_operational_input_construct launch-brief "$SPAWN_BRIEF_BODY" SPAWN_BRIEF_INPUT \
  || { echo "error: could not encode captured launch brief" >&2; exit 1; }
unset SPAWN_BRIEF_BODY
W="fm-$ID"
spawn_provisional_harness_wiring_receipt_publication_recover() {
  local receipt=$SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT base state_inode
  base=$(basename -- "$receipt") || return 1
  state_inode=$(spawn_file_inode_identity "$STATE") || return 1
  python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe-raw \
    "$STATE" "$state_inode" "$base" >/dev/null
}

spawn_provisional_harness_wiring_receipt_load() {
  local receipt=$SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT canonical links bytes
  spawn_provisional_harness_wiring_receipt_publication_recover || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  links=$(spawn_file_link_count "$receipt") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$receipt" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 4096 ] || return 1
  canonical=$(jq -e -S -c -s \
    --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" \
    --arg task "$ID" --arg kind "$KIND" --arg worktree "$WT" '
      def exact($keys): (keys | sort) == ($keys | sort);
      select(length == 1) | .[0] | . as $r | select(
        type == "object"
        and exact(["schema","binding","transaction_id","harness","kind","worktree","auth_path"])
        and .schema == "fm-spawn-harness-wiring.v1"
        and .binding == {home:$home,home_id:$home_id,task_id:$task}
        and (.transaction_id | type) == "string" and (.transaction_id | length) > 0
        and (.harness == "grok" or .harness == "kimi")
        and .kind == $kind and .worktree == $worktree
        and (.auth_path | type) == "string" and (.auth_path | length) > 0
      ) | $r
    ' "$receipt" 2>/dev/null) || return 1
  printf '%s\n' "$canonical" | cmp -s "$receipt" - || return 1
  SPAWN_PROVISIONAL_RECEIPT_TRANSACTION=$(printf '%s' "$canonical" | jq -r '.transaction_id') || return 1
  SPAWN_PROVISIONAL_RECEIPT_HARNESS=$(printf '%s' "$canonical" | jq -r '.harness') || return 1
  SPAWN_PROVISIONAL_RECEIPT_AUTH_PATH=$(printf '%s' "$canonical" | jq -r '.auth_path') || return 1
  fm_control_harness_turnend_auth_record_valid \
    "$SPAWN_PROVISIONAL_RECEIPT_HARNESS" "" \
    "$SPAWN_PROVISIONAL_RECEIPT_AUTH_PATH"
}

spawn_provisional_harness_wiring_receipt_publish() {  # <harness> <auth-path>
  local harness=$1 auth_path=$2 payload tmp receipt=$SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT
  local base state_inode rc=0 source_details source_state source_digest
  fm_control_harness_turnend_auth_record_valid "$harness" "" "$auth_path" || return 1
  payload=$(jq -n -S -c \
    --arg schema fm-spawn-harness-wiring.v1 \
    --arg home "$SPAWN_IDENTITY_HOME" --arg home_id "$SPAWN_IDENTITY_HOME_ID" \
    --arg task "$ID" --arg transaction "$SPAWN_DISPATCH_TRANSACTION" \
    --arg harness "$harness" --arg kind "$KIND" --arg worktree "$WT" \
    --arg auth_path "$auth_path" \
    '{schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},
      transaction_id:$transaction,harness:$harness,kind:$kind,
      worktree:$worktree,auth_path:$auth_path}') || return 1
  tmp=$(umask 077; mktemp "$STATE/.$ID.harness-wiring-provisional.XXXXXX") || return 1
  if ! printf '%s\n' "$payload" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  base=$(basename -- "$receipt") || { rm -f -- "$tmp"; return 1; }
  state_inode=$(spawn_file_inode_identity "$STATE") || { rm -f -- "$tmp"; return 1; }
  source_details=$(python3 "$SCRIPT_DIR/fm-work-identity-fs.py" describe-source "$tmp" 4096) \
    || { rm -f -- "$tmp"; return 1; }
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  [ "$source_state" != "$source_details" ] \
    || { rm -f -- "$tmp"; return 1; }
  python3 "$SCRIPT_DIR/fm-work-identity-fs.py" no-clobber \
    "$STATE" "$state_inode" "$base" "$tmp" "${base}.publishing" \
    "$source_state" "$source_digest" || rc=$?
  rm -f -- "$tmp" || return 1
  [ "$rc" -eq 0 ]
}

spawn_provisional_harness_wiring_receipt_retire() {
  local receipt=$SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] && return 0
  spawn_provisional_harness_wiring_receipt_load || return 1
  rm -f -- "$receipt"
}

spawn_provisional_harness_wiring_metadata_matches_receipt() {
  local meta="$STATE/$ID.meta" family
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    return 2
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] \
    && [ "$(spawn_file_link_count "$meta")" = 1 ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$ID" >/dev/null 2>&1 || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = "$BACKEND" ] \
    && [ "$FM_BACKEND_VALIDATED_TARGET" = "$T" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" work_identity_dispatch_transaction)" = "$SPAWN_PROVISIONAL_RECEIPT_TRANSACTION" ] \
    || return 1
  family=$(fm_control_harness_family "$(fm_backend_meta_exact_value "$meta" harness)") || return 1
  [ "$family" = "$SPAWN_PROVISIONAL_RECEIPT_HARNESS" ] \
    && [ "$(fm_backend_meta_exact_value "$meta" kind)" = "$KIND" ] \
    && [ "$(fm_backend_meta_exact_value "$meta" project)" = "$PROJ_ABS" ] \
    && [ "$(fm_backend_meta_exact_value "$meta" worktree)" = "$WT" ] \
    && [ "$(fm_backend_meta_exact_value "$meta" harness_turnend_auth_path)" = "$SPAWN_PROVISIONAL_RECEIPT_AUTH_PATH" ]
}

spawn_provisional_harness_wiring_recover() {
  local receipt=$SPAWN_PROVISIONAL_HARNESS_WIRING_RECEIPT metadata_rc=0
  spawn_provisional_harness_wiring_receipt_publication_recover || {
    echo "error: provisional harness wiring publication is unsafe: $receipt" >&2
    return 1
  }
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] && return 0
  spawn_provisional_harness_wiring_receipt_load || {
    echo "error: provisional harness wiring receipt is unsafe or mismatched: $receipt" >&2
    return 1
  }
  spawn_provisional_harness_wiring_metadata_matches_receipt || metadata_rc=$?
  case "$metadata_rc" in
    0)
      if [ "$SPAWN_PROVISIONAL_RECEIPT_TRANSACTION" != "$SPAWN_DISPATCH_TRANSACTION" ]; then
        [ "$RELAUNCH" -eq 1 ] || {
          echo "error: published harness wiring transaction is mismatched for $ID" >&2
          return 1
        }
      else
        SPAWN_METADATA_RECOVERY=1
      fi
      ;;
    2)
      clear_relaunch_harness_wiring \
        "$SPAWN_PROVISIONAL_RECEIPT_HARNESS" "$WT" "$STATE" "$ID" \
        "$SPAWN_PROVISIONAL_RECEIPT_AUTH_PATH" || {
        echo "error: provisional harness authorization is unsafe or mismatched: $SPAWN_PROVISIONAL_RECEIPT_AUTH_PATH" >&2
        return 1
      }
      ;;
    *)
      echo "error: published task metadata is unsafe or mismatched for provisional harness wiring: $STATE/$ID.meta" >&2
      return 1
      ;;
  esac
  rm -f -- "$receipt"
}

spawn_provisional_harness_auth_path() {  # <harness> <auth-root>
  local harness=$1 root=$2 digest candidate
  fm_control_harness_turnend_auth_root_valid "$harness" "$root" || return 1
  mkdir -p "$root" || return 1
  digest=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION:$harness:$root:$ID" | spawn_sha256_stream) \
    || return 1
  case "$digest" in *[!0-9a-fA-F]*|'') return 1 ;; esac
  candidate="$root/fm.${digest:0:12}"
  fm_control_harness_turnend_auth_record_valid "$harness" "" "$candidate" || return 1
  [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

spawn_provisional_harness_auth_create() {  # <auth-path>
  local auth_path=$1
  [ ! -e "$auth_path" ] && [ ! -L "$auth_path" ] || return 1
  (umask 077; set -o noclobber; printf '%s\n' "$TURNEND" > "$auth_path") 2>/dev/null \
    || return 1
  [ -f "$auth_path" ] && [ ! -L "$auth_path" ] \
    && [ "$(spawn_file_link_count "$auth_path")" = 1 ]
}

spawn_provisional_harness_wiring_retire() {
  local meta="$STATE/$ID.meta" recorded_harness recorded_kind recorded_worktree recorded_auth_path
  local published=0
  [ "$KIND" != secondmate ] || return 0
  if spawn_metadata_transaction_published; then
    published=1
    recorded_harness=$(fm_meta_get "$meta" harness)
    recorded_kind=$(fm_meta_get "$meta" kind)
    recorded_worktree=$(fm_meta_get "$meta" worktree)
    recorded_auth_path=$(fm_meta_get "$meta" harness_turnend_auth_path)
  else
    recorded_harness=$HARNESS
    recorded_kind=$KIND
    recorded_worktree=$WT
    recorded_auth_path=${HARNESS_TURNEND_AUTH_PATH:-}
  fi
  [ -n "$recorded_harness" ] && [ "$recorded_kind" = "$KIND" ] \
    && [ -n "$recorded_worktree" ] && [ "$recorded_worktree" = "$WT" ] || return 1
  clear_relaunch_harness_wiring \
    "$recorded_harness" "$recorded_worktree" "$STATE" "$ID" "$recorded_auth_path" || return 1
  spawn_provisional_harness_wiring_receipt_retire || return 1
  if [ "$published" -eq 0 ] && [ -n "${BUSY_GEN:-}" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$BUSY_GEN" >/dev/null 2>&1 \
      || return 1
    [ ! -e "$STATE/$ID.busy-state" ] && [ ! -L "$STATE/$ID.busy-state" ] \
      && [ ! -e "$STATE/$ID.busy-gen" ] && [ ! -L "$STATE/$ID.busy-gen" ] || return 1
  fi
}

spawn_terminal_launch_reset() {
  local busy_gen=
  if spawn_metadata_transaction_published; then
    busy_gen=$(fm_meta_get "$STATE/$ID.meta" busy_gen)
    BUSY_GEN=$busy_gen
    spawn_provisional_harness_wiring_retire || return 1
    spawn_fresh_commit_rollback || return 1
  fi
  spawn_launch_request_cleanup || return 1
  spawn_launch_guard_cleanup_terminal || return 1
  SPAWN_FRESH_COMMIT_PENDING=0
  spawn_endpoint_receipt_publish worktree-ready "$WT"
}

spawn_missing_endpoint_compensate() {
  local busy_gen='' guard_state
  guard_state=$(spawn_launch_guard_state) || return 1
  case "$guard_state" in absent|exited|abandoned) ;; *) return 1 ;; esac
  if spawn_metadata_transaction_published; then
    busy_gen=$(fm_meta_get "$STATE/$ID.meta" busy_gen)
    spawn_provisional_harness_wiring_retire || return 1
  fi
  if [ "$KIND" != secondmate ] && [ -d "$WT" ]; then
    if [ "$BACKEND" = orca ]; then
      fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID" --absent-ok >/dev/null 2>&1 \
        || return 1
    else
      (cd "$PROJ_ABS" && treehouse return --force "$WT") >/dev/null 2>&1 || return 1
    fi
  fi
  if [ -n "$busy_gen" ]; then
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-work-identity.sh" \
      dispatch-retire-run "$ID" -- "$FM_ROOT/bin/fm-busy-event.sh" \
        retire "$STATE" "$ID" --gen "$busy_gen" >/dev/null || return 1
  else
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-work-identity.sh" \
      dispatch-retire-run "$ID" -- true >/dev/null || return 1
  fi
  spawn_launch_request_cleanup || return 1
  spawn_launch_guard_cleanup_terminal || return 1
  spawn_endpoint_receipt_retire || return 1
  SPAWN_DISPATCH_PENDING=0
  SPAWN_FRESH_COMMIT_PENDING=0
}

spawn_exited_launch_compensate() {
  local endpoint_state
  if [ "$SPAWN_ENDPOINT_MISSING" -ne 1 ]; then
    fm_backend_kill "$BACKEND" "$T" "${ZELLIJ_TAB_ID:-}" "$W" || return 1
    case "$BACKEND" in
      tmux|herdr)
        endpoint_state=$(fm_backend_agent_state "$BACKEND" "$T")
        [ "$endpoint_state" = missing ] || return 1
        ;;
      *)
        ! fm_backend_target_exists "$BACKEND" "$T" "$W" || return 1
        ;;
    esac
    SPAWN_ENDPOINT_MISSING=1
  fi
  spawn_missing_endpoint_compensate
}

if [ "$RELAUNCH" -eq 0 ] \
   && { [ -e "$SPAWN_ENDPOINT_RECEIPT" ] || [ -L "$SPAWN_ENDPOINT_RECEIPT" ]; }; then
  endpoint_receipt_rc=0
  spawn_endpoint_receipt_load || endpoint_receipt_rc=$?
  if [ "$endpoint_receipt_rc" -eq 2 ]; then
    echo "error: recorded endpoint is gone for $ID; exact receipt is preserved for reconciliation" >&2
    exit 1
  fi
  [ "$endpoint_receipt_rc" -eq 0 ] || exit "$endpoint_receipt_rc"
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$SPAWN_ENDPOINT_PHASE" = launch-prepared ]; then
  launch_request_state=$(spawn_launch_request_state) || {
    echo "error: launch request evidence is unsafe for $ID" >&2
    exit 1
  }
  case "$launch_request_state" in
    accepted|executed)
      spawn_metadata_transaction_published || {
        echo "error: accepted launch has no exact published metadata for $ID" >&2
        exit 1
      }
      SPAWN_METADATA_RECOVERY=1
      spawn_endpoint_receipt_publish launch-submitted "$WT" || {
        echo "error: accepted launch could not be journaled for $ID" >&2
        exit 1
      }
      SPAWN_LAUNCH_SUBMITTED_RECOVERY=1
      ;;
    launch-exited)
      spawn_exited_launch_compensate || {
        echo "error: exited launch for $ID could not be compensated safely" >&2
        exit 1
      }
      echo "error: launch for $ID exited before commit; its provisional publication was compensated - rerun spawn to retry" >&2
      exit 1
      ;;
    launch-failed)
      if [ "$SPAWN_ENDPOINT_MISSING" -eq 1 ]; then
        spawn_missing_endpoint_compensate
      else
        spawn_terminal_launch_reset
      fi || {
        echo "error: failed launch for $ID could not be compensated safely" >&2
        exit 1
      }
      echo "error: launch command for $ID exited unsuccessfully; its provisional publication was compensated - rerun spawn to retry" >&2
      exit 1
      ;;
    absent|failed|unattempted-dead|attempted-dead|launch-abandoned)
      if [ "$SPAWN_ENDPOINT_MISSING" -eq 1 ]; then
        echo "error: recorded endpoint disappeared before launch acceptance for $ID; exact evidence is preserved" >&2
        exit 1
      fi
      spawn_launch_guard_cleanup_retryable || {
        echo "error: retryable execution guard could not be retired for $ID" >&2
        exit 1
      }
      spawn_launch_request_cleanup || {
        echo "error: retryable launch evidence could not be retired for $ID" >&2
        exit 1
      }
      spawn_endpoint_receipt_publish worktree-ready "$WT" || {
        echo "error: retryable endpoint receipt could not be restored for $ID" >&2
        exit 1
      }
      if spawn_metadata_transaction_published; then
        SPAWN_METADATA_RECOVERY=1
      fi
      ;;
    *)
      echo "error: launch acceptance is ambiguous; exact request evidence is preserved for $ID" >&2
      exit 1
      ;;
  esac
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$SPAWN_LAUNCH_SUBMITTED_RECOVERY" -eq 1 ]; then
  spawn_metadata_transaction_published || {
    echo "error: submitted launch has no exact published metadata for $ID" >&2
    exit 1
  }
  SPAWN_METADATA_RECOVERY=1
  launch_request_state=$(spawn_launch_request_state) || {
    echo "error: submitted launch evidence is unsafe for $ID" >&2
    exit 1
  }
  case "$launch_request_state" in
    accepted|executed) ;;
    launch-exited)
      spawn_exited_launch_compensate || {
        echo "error: exited submitted launch for $ID could not be compensated safely" >&2
        exit 1
      }
      echo "error: submitted launch for $ID exited before commit; its provisional publication was compensated - rerun spawn to retry" >&2
      exit 1
      ;;
    *)
      echo "error: submitted launch lacks exact backend acceptance for $ID" >&2
      exit 1
      ;;
  esac
  if [ "$SPAWN_ENDPOINT_MISSING" -eq 1 ]; then
    spawn_missing_endpoint_compensate || {
      echo "error: missing accepted endpoint for $ID could not be compensated safely; exact receipt is preserved" >&2
      exit 1
    }
    echo "error: accepted launch endpoint for $ID disappeared; its published transaction was compensated - rerun spawn to retry" >&2
    exit 1
  else
    spawn_launch_delivery_wait || {
      echo "error: submitted launch has not published exact backend acceptance for $ID" >&2
      exit 1
    }
  fi
fi

delivery_rigor_rank() {  # <mode> -> 3 (most rigor) .. 1 (least); 0 = not a task mode
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
  if [ -n "$STANDING_MODE" ] && [ "$STANDING_MODE" != no-mistakes-prod-only ] \
     && [ "$(delivery_rigor_rank "$MODE")" -lt "$(delivery_rigor_rank "$STANDING_MODE")" ]; then
    echo "notice: $ID ships mode=$MODE while the standing posture for $PROJ_NAME is $STANDING_MODE - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
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
describe_stale_submodule_pins() {  # <worktree> <status>
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

freshen_spawn_worktree_base() {  # <worktree>
  local worktree=$1 default target expected actual status
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
    echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  default=$(default_branch "$worktree") || {
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
    echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (tasks-axi add $ID '<title>' --kind $KIND) and re-run" >&2
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
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  exit 1
fi
if [ "$RELAUNCH" -eq 0 ] && [ -z "$SPAWN_ENDPOINT_PHASE" ] \
   && spawn_metadata_transaction_published \
   && { [ "$SPAWN_ENDPOINT_RETIREMENT_RECOVERED" -eq 1 ] \
     || { [ "$BACKLOG_TRANSITION" -eq 1 ] \
       && [ "$BACKLOG_ROW_STATE" = "in_flight no no" ]; }; }; then
  fm_backend_validate_task_endpoint "$STATE/$ID.meta" "$ID" || exit 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = "$BACKEND" ] \
    && [ "$(fm_meta_get "$STATE/$ID.meta" kind)" = "$KIND" ] \
    && [ "$(fm_meta_get "$STATE/$ID.meta" project)" = "$PROJ_ABS" ] \
    && [ "$(fm_meta_get "$STATE/$ID.meta" harness)" = "$HARNESS" ] || {
      echo "error: committed spawn metadata is mismatched for exact retry of $ID" >&2
      exit 1
    }
  T=$FM_BACKEND_VALIDATED_TARGET
  WT=$(fm_meta_get "$STATE/$ID.meta" worktree)
  spawn_endpoint_worktree_binding_valid || {
    echo "error: committed spawn worktree is invalid or cross-project for $ID: $WT" >&2
    exit 1
  }
  if [ "$KIND" != scout ]; then
    [ "$(fm_meta_get "$STATE/$ID.meta" mode)" = "$MODE" ] \
      && [ "$(fm_meta_get "$STATE/$ID.meta" yolo)" = "$YOLO" ] || {
        echo "error: committed spawn delivery contract is mismatched for exact retry of $ID" >&2
        exit 1
      }
  fi
  fm_backend_target_exists "$BACKEND" "$T" "$W" || {
    echo "error: committed spawn endpoint is unavailable for $ID; refusing duplicate launch" >&2
    exit 1
  }
  spawn_launch_request_paths || exit 1
  spawn_launch_request_cleanup \
    || echo "warning: committed launch request journal could not be retired for $ID" >&2
  SPAWN_DISPATCH_PENDING=0
  SECONDMATE_RESERVATION_PENDING=0
  SPAWN_DELIVERY=
  [ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
  echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$T worktree=$WT"
  exit 0
fi

W="fm-$ID"
if [ "$RELAUNCH" -eq 1 ]; then
  # Adopt the recorded endpoint instead of creating one. This is what keeps a
  # relaunch a REPLACEMENT rather than a second copy of the task: no new
  # terminal, no second worktree, and every uncommitted change left exactly
  # where the previous agent left it.
  T=$RELAUNCH_TARGET
  # A secondmate's home already resolved WT above through the same validation a
  # fresh secondmate spawn uses; every other kind takes the recorded worktree.
  [ "$KIND" = secondmate ] || WT=$RELAUNCH_WT
  WT_TARGET=$T
  SES=${T%%:*}
elif [ "$SPAWN_ENDPOINT_RECOVERED" = 1 ]; then
  :
else
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
    if [ "$SPAWN_ENDPOINT_CREATING_RECOVERY" = 1 ]; then
      set +e
      WID=$(fm_backend_tmux_recover_task "$SES" "$W")
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0)
          [ "$(fm_backend_agent_state tmux "$T")" = dead ] || {
            echo "error: endpoint creation intent resolved to a non-empty tmux endpoint for $ID" >&2
            exit 1
          }
          ;;
        2) WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1 ;;
        *) exit 1 ;;
      esac
    else
      set +e
      fm_backend_tmux_recover_task "$SES" "$W" >/dev/null
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0) echo "error: window $SES:$W already exists" >&2; exit 1 ;;
        2) ;;
        *) exit 1 ;;
      esac
      T="$SES:$W"
      spawn_endpoint_receipt_publish endpoint-creating || {
        echo "error: could not publish endpoint creation intent for $ID" >&2
        exit 1
      }
      WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    fi
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
    if [ "$KIND" != secondmate ] && fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE"; then
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
        elif [ "${FM_BACKEND_HERDR_PRESENTATION_PREFERENCE:-default}" = default ] \
          && ! fm_backend_herdr_presentation_default_supported "$STATE" "$HERDR_SES"; then
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
    if [ "$SPAWN_ENDPOINT_CREATING_RECOVERY" = 1 ]; then
      set +e
      ZELLIJ_TASK_IDS=$(fm_backend_zellij_recover_task "$ZELLIJ_SES" "$W")
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0) ;;
        2) ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1 ;;
        *) exit 1 ;;
      esac
    else
      set +e
      fm_backend_zellij_recover_task "$ZELLIJ_SES" "$W" >/dev/null
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0)
          echo "error: zellij endpoint for $W already exists in session '$ZELLIJ_SES'" >&2
          exit 1
          ;;
        2) ;;
        *) exit 1 ;;
      esac
      spawn_endpoint_receipt_publish endpoint-creating || {
        echo "error: could not publish endpoint creation intent for $ID" >&2
        exit 1
      }
      ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    fi
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
    if [ "$SPAWN_ENDPOINT_CREATING_RECOVERY" = 1 ]; then
      set +e
      CMUX_TASK_IDS=$(fm_backend_cmux_recover_task "$W")
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0) ;;
        2) CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1 ;;
        *) exit 1 ;;
      esac
    else
      set +e
      fm_backend_cmux_recover_task "$W" >/dev/null
      ENDPOINT_RECOVERY_STATUS=$?
      set -e
      case "$ENDPOINT_RECOVERY_STATUS" in
        0) echo "error: cmux endpoint for $W already exists" >&2; exit 1 ;;
        2) ;;
        *) exit 1 ;;
      esac
      spawn_endpoint_receipt_publish endpoint-creating || {
        echo "error: could not publish endpoint creation intent for $ID" >&2
        exit 1
      }
      CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    fi
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
    if [ "$SPAWN_ENDPOINT_CREATING_RECOVERY" != 1 ]; then
      if [ -e "$SPAWN_ORCA_OPERATION" ] || [ -L "$SPAWN_ORCA_OPERATION" ]; then
        echo "error: stale Orca endpoint operation exists without a matching creation receipt: $SPAWN_ORCA_OPERATION" >&2
        exit 1
      fi
      spawn_endpoint_receipt_publish endpoint-creating || {
        echo "error: could not publish Orca endpoint creation intent for $ID" >&2
        exit 1
      }
    fi
    spawn_orca_operation_prepare || exit 1
    spawn_orca_operation_wait || exit 1
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ] || [ -z "$ORCA_TERMINAL" ]; then
      echo "error: Orca endpoint result is incomplete for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ "$SPAWN_ENDPOINT_CREATING_RECOVERY" = 1 ]; then
      fm_backend_target_exists orca "$ORCA_TERMINAL" "$W" || {
        echo "error: recovered Orca terminal is unavailable for $W" >&2
        exit 1
      }
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$SPAWN_ENDPOINT_RECOVERED" = 0 ]; then
  endpoint_worktree=
  if [ "$KIND" = secondmate ] || [ "$BACKEND" = orca ]; then endpoint_worktree=$WT; fi
  spawn_endpoint_receipt_publish endpoint-created "$endpoint_worktree" || {
    echo "error: could not publish endpoint recovery receipt for $ID" >&2
    exit 1
  }
  HERDR_PROJECTION_ABORT_CLEANUP=0
  ORCA_ABORT_CLEANUP=0
  if [ "$BACKEND" = orca ]; then
    spawn_orca_operation_retire || {
      echo "error: exact Orca creation journal could not be retired; endpoint receipt remains authoritative" >&2
      exit 1
    }
  fi
fi
if [ "$RELAUNCH" -eq 0 ] && { [ "$KIND" = secondmate ] || [ "$BACKEND" = orca ]; } \
   && [ "$SPAWN_ENDPOINT_PHASE" != launch-prepared ] \
   && [ "$SPAWN_ENDPOINT_PHASE" != launch-submitted ]; then
  spawn_endpoint_receipt_publish worktree-ready "$WT" || {
    echo "error: could not bind the recovered endpoint worktree for $ID" >&2
    exit 1
  }
fi
if [ "$KIND" = secondmate ]; then
  FM_INHERITABLE_CONFIG=trace-context \
    propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" \
    || echo "warning: secondmate $ID trace-context inheritance failed for $PROJ_ABS" >&2
fi
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
spawn_passive_current_path() {  # <target>
  case "$BACKEND" in
    zellij) fm_backend_zellij_passive_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_passive_current_path "$1" "$W" ;;
    *) spawn_current_path "$1" ;;
  esac
}
spawn_worktree_request_send() {  # <target> <text>
  spawn_send_text_line "$1" "$2"
}
spawn_worktree_request_result_file_validate() {
  local result=$1 links bytes canonical
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  links=$(spawn_file_link_count "$result") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$result" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 16384 ] || return 1
  canonical=$(jq -e -S -c --arg holder "$lease_holder" '
    def exact($keys): (keys | sort) == ($keys | sort);
    select(type == "object"
      and exact(["schema","status","exit_status","path","lease_holder","leases"])
      and .schema == "fm-spawn-worktree-result.v1"
      and (.status == "ok" or .status == "retryable" or .status == "ambiguous")
      and (.exit_status | type == "number" and floor == . and . >= 0 and . <= 255)
      and .lease_holder == $holder
      and (.leases | type == "array" and length <= 8
        and all(.[]; type == "object" and exact(["path","lease_id"])
          and (.path | type == "string" and startswith("/") and length <= 4096)
          and (.lease_id == null or (.lease_id | type == "string" and length > 0 and length <= 256))))
      and (if .status == "ok" then
             (.path | type == "string" and startswith("/") and length <= 4096)
             and (.leases | length) == 1 and .leases[0].path == .path
           elif .status == "retryable" then .path == null and (.leases | length) == 0
           else .path == null end))
    | .
  ' "$result" 2>/dev/null) || return 1
  printf '%s\n' "$canonical" | cmp -s "$result" -
}
spawn_worktree_request_result_recover() {
  local result="$WORKTREE_REQUEST_MARKER/result" candidate="$WORKTREE_REQUEST_MARKER/.result.tmp" links bytes
  if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then return 0; fi
  if ! spawn_worktree_request_result_file_validate "$candidate"; then
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    links=$(spawn_file_link_count "$candidate") || return 1
    [ "$links" = 1 ] || return 1
    bytes=$(LC_ALL=C wc -c < "$candidate" | tr -d ' ')
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bytes" -le 16384 ] || return 1
    rm -f -- "$candidate" || return 1
    return 0
  fi
  if [ ! -e "$result" ] && [ ! -L "$result" ]; then
    mv -- "$candidate" "$result" || return 1
    return 0
  fi
  spawn_worktree_request_result_file_validate "$result" || return 1
  cmp -s "$candidate" "$result" || return 1
  rm -f -- "$candidate"
}
spawn_worktree_request_result_load() {
  local result="$WORKTREE_REQUEST_MARKER/result" canonical status value
  [ -d "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ] || {
    if [ ! -e "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ]; then return 1; fi
    return 3
  }
  spawn_worktree_request_result_recover || return 3
  if [ ! -e "$result" ] && [ ! -L "$result" ]; then return 1; fi
  spawn_worktree_request_result_file_validate "$result" || return 3
  canonical=$(cat "$result") || return 3
  status=$(printf '%s' "$canonical" | jq -r '.status') || return 3
  case "$status" in
    ok)
      value=$(printf '%s' "$canonical" | jq -r '.path') || return 3
      printf '%s' "$value"
      ;;
    retryable) return 2 ;;
    ambiguous) return 4 ;;
    *) return 3 ;;
  esac
}
spawn_worktree_request_owner_state() {
  local owner="$WORKTREE_REQUEST_MARKER/owner" links bytes pid
  if [ ! -e "$owner" ] && [ ! -L "$owner" ]; then printf 'absent'; return 0; fi
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  links=$(spawn_file_link_count "$owner") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$owner" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$bytes" -le 32 ] || return 1
  pid=$(tr -d '[:space:]' < "$owner")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then printf 'live'; else printf 'dead'; fi
}
spawn_worktree_request_result_publish() {
  local payload=$1 tmp="$WORKTREE_REQUEST_MARKER/.result.tmp"
  [ ! -e "$WORKTREE_REQUEST_MARKER/result" ] && [ ! -L "$WORKTREE_REQUEST_MARKER/result" ] || return 1
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  printf '%s\n' "$payload" > "$tmp" && chmod 600 "$tmp" \
    && mv -- "$tmp" "$WORKTREE_REQUEST_MARKER/result"
}
spawn_worktree_request_reconcile() {
  local raw leases count path payload
  raw=$(treehouse status --json 2>/dev/null) || return 3
  leases=$(printf '%s' "$raw" | jq -e -S -c --arg holder "$lease_holder" '
    if type != "array" then error("status is not an array") else
      [.[] | select(.leased == true and .lease_holder == $holder
        and (.path | type == "string" and startswith("/") and length <= 4096)
        and (.lease_id | type == "string" and length > 0 and length <= 256))
        | {path:.path,lease_id:.lease_id}]
      | unique_by([.path,.lease_id])
    end
  ' 2>/dev/null) || return 3
  count=$(printf '%s' "$leases" | jq -r 'length') || return 3
  case "$count" in
    0) return 2 ;;
    1)
      path=$(printf '%s' "$leases" | jq -er '.[0].path') || return 3
      payload=$(jq -n -S -c --arg schema fm-spawn-worktree-result.v1 \
        --arg path "$path" --arg lease_holder "$lease_holder" --argjson leases "$leases" \
        '{schema:$schema,status:"ok",exit_status:0,path:$path,lease_holder:$lease_holder,leases:$leases}') \
        || return 3
      spawn_worktree_request_result_publish "$payload" || return 3
      printf '%s' "$path"
      ;;
    *)
      payload=$(jq -n -S -c --arg schema fm-spawn-worktree-result.v1 \
        --arg lease_holder "$lease_holder" --argjson leases "$leases" \
        '{schema:$schema,status:"ambiguous",exit_status:1,path:null,lease_holder:$lease_holder,leases:$leases}') \
        || return 3
      spawn_worktree_request_result_publish "$payload" || return 3
      return 4
      ;;
  esac
}
spawn_worktree_request_cleanup() {
  local entry links
  if [ -d "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ]; then
    for entry in "$WORKTREE_REQUEST_MARKER"/* "$WORKTREE_REQUEST_MARKER"/.[!.]* "$WORKTREE_REQUEST_MARKER"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      case "${entry##*/}" in result|.result.tmp|owner|.owner.tmp) ;; *) return 1 ;; esac
      [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
      links=$(spawn_file_link_count "$entry") || return 1
      [ "$links" = 1 ] || return 1
      rm -f -- "$entry" || return 1
    done
    rmdir -- "$WORKTREE_REQUEST_MARKER" || return 1
  elif [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ]; then
    return 1
  fi
  if [ -d "$WORKTREE_REQUEST_ACK" ] && [ ! -L "$WORKTREE_REQUEST_ACK" ]; then
    for entry in "$WORKTREE_REQUEST_ACK"/* "$WORKTREE_REQUEST_ACK"/.[!.]* "$WORKTREE_REQUEST_ACK"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      case "${entry##*/}" in attempted|accepted|.attempted.[A-Za-z0-9]*|.accepted.[A-Za-z0-9]*) ;; *) return 1 ;; esac
      [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
      links=$(spawn_file_link_count "$entry") || return 1
      [ "$links" = 1 ] || return 1
      rm -f -- "$entry" || return 1
    done
    rmdir -- "$WORKTREE_REQUEST_ACK" || return 1
  elif [ -e "$WORKTREE_REQUEST_ACK" ] || [ -L "$WORKTREE_REQUEST_ACK" ]; then
    return 1
  fi
}
spawn_send_launch_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_launch_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_launch_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_launch_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_launch_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_launch_line "$1" "$2" "$W" ;;
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

spawn_session_backend_worktree_acquire() {
  local old_request=0 owner_state result_rc reconcile_rc round=0 helper_pid start_wait
  local poll_max=${FM_SPAWN_WORKTREE_POLLS:-60} poll_interval=${FM_SPAWN_WORKTREE_INTERVAL:-1}
  local seen='' cd_command
  WORKTREE_REQUEST_DIGEST=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION" | spawn_sha256_stream) || return 1
  WORKTREE_REQUEST_MARKER="$STATE/.$ID.worktree-request.$WORKTREE_REQUEST_DIGEST"
  WORKTREE_REQUEST_ACK="$WORKTREE_REQUEST_MARKER.send"
  lease_holder="firstmate-$WORKTREE_REQUEST_DIGEST"
  case "$SPAWN_ENDPOINT_PHASE" in
    endpoint-created)
      if [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ] \
         || [ -e "$WORKTREE_REQUEST_ACK" ] || [ -L "$WORKTREE_REQUEST_ACK" ]; then
        echo "error: stale worktree request evidence exists before acquisition for $ID" >&2
        return 1
      fi
      spawn_endpoint_receipt_publish worktree-requesting || return 1
      ;;
    worktree-unsent|worktree-retryable)
      spawn_worktree_request_cleanup || return 1
      spawn_endpoint_receipt_publish worktree-requesting || return 1
      ;;
    worktree-requesting) ;;
    worktree-requested) old_request=1 ;;
    worktree-acquired)
      [ -n "$WT" ] || return 1
      ;;
    *)
      echo "error: endpoint receipt has no valid local worktree acquisition phase for $ID" >&2
      return 1
      ;;
  esac
  while [ -z "$WT" ] && [ "$round" -lt 2 ]; do
    if [ ! -e "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ]; then
      [ "$old_request" -eq 0 ] || break
      (trap '' HUP INT TERM; cd "$PROJ_ABS" && exec bash "$SCRIPT_DIR/fm-treehouse-worktree-request.sh" \
        "$WORKTREE_REQUEST_MARKER" "$lease_holder") </dev/null >/dev/null 2>&1 &
      helper_pid=$!
      start_wait=0
      while [ ! -e "$WORKTREE_REQUEST_MARKER/owner" ] && [ ! -L "$WORKTREE_REQUEST_MARKER/owner" ] \
        && kill -0 "$helper_pid" 2>/dev/null && [ "$start_wait" -lt 100 ]; do
        sleep 0.01
        start_wait=$((start_wait + 1))
      done
      if [ ! -e "$WORKTREE_REQUEST_MARKER/owner" ] && [ ! -L "$WORKTREE_REQUEST_MARKER/owner" ]; then
        echo "error: durable worktree request helper did not publish its owner journal for $ID" >&2
        return 1
      fi
    fi
    for _ in $(seq 1 "$poll_max"); do
      result_rc=0
      WT=$(spawn_worktree_request_result_load) || result_rc=$?
      case "$result_rc" in
        0) break ;;
        1)
          owner_state=$(spawn_worktree_request_owner_state) || {
            echo "error: worktree request owner evidence is unsafe for $ID" >&2
            return 1
          }
          if [ "$owner_state" = live ]; then
            WT=
          else
            reconcile_rc=0
            WT=$(spawn_worktree_request_reconcile) || reconcile_rc=$?
            case "$reconcile_rc" in
              0) break ;;
              2)
                WT=
                if [ "$old_request" -eq 1 ]; then
                  sleep "$poll_interval"
                  continue
                fi
                spawn_worktree_request_cleanup || return 1
                round=$((round + 1))
                break
                ;;
              4)
                echo "error: treehouse acquisition has several exact leases for $ID at $WORKTREE_REQUEST_MARKER/result" >&2
                return 1
                ;;
              *)
                echo "error: treehouse lease reconciliation is unsafe for $ID" >&2
                return 1
                ;;
            esac
          fi
          ;;
        2)
          WT=
          spawn_endpoint_receipt_publish worktree-retryable || return 1
          spawn_worktree_request_cleanup || return 1
          spawn_endpoint_receipt_publish worktree-requesting || return 1
          round=$((round + 1))
          break
          ;;
        4)
          echo "error: treehouse acquisition has ambiguous exact lease evidence for $ID at $WORKTREE_REQUEST_MARKER/result" >&2
          return 1
          ;;
        *)
          echo "error: worktree request result is unsafe for $ID" >&2
          return 1
          ;;
      esac
      [ -z "$WT" ] || break
      sleep "$poll_interval"
    done
    [ -z "$WT" ] || break
    if [ "$result_rc" -eq 1 ] && [ "${owner_state:-}" = live ]; then break; fi
    [ "$old_request" -eq 0 ] || break
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse acquisition remains in progress; exact lease evidence is preserved for $ID" >&2
    return 1
  fi
  if [ "$SPAWN_ENDPOINT_PHASE" != worktree-acquired ]; then
    spawn_endpoint_receipt_publish worktree-acquired "$WT" || {
      echo "error: could not preserve the acquired worktree for $ID" >&2
      return 1
    }
  fi
  for _ in $(seq 1 10); do
    seen=$(spawn_passive_current_path "$WT_TARGET" || true)
    [ -z "$seen" ] || [ "$(real_path_or_raw "$seen")" != "$(real_path_or_raw "$WT")" ] || break
    sleep 0.1
  done
  if [ -z "$seen" ] || [ "$(real_path_or_raw "$seen")" != "$(real_path_or_raw "$WT")" ]; then
    spawn_send_key "$WT_TARGET" C-u || {
      echo "error: could not clear the pending worktree transition for $ID" >&2
      return 1
    }
    cd_command="cd -- $(shell_quote "$WT")"
    spawn_send_text_line "$WT_TARGET" "$cd_command" || {
      echo "error: could not submit the exact worktree transition for $ID" >&2
      return 1
    }
    seen=
    for _ in $(seq 1 "$poll_max"); do
      seen=$(spawn_passive_current_path "$WT_TARGET" || true)
      [ -z "$seen" ] || [ "$(real_path_or_raw "$seen")" != "$(real_path_or_raw "$WT")" ] || break
      sleep "$poll_interval"
    done
  fi
  if [ -z "$seen" ] || [ "$(real_path_or_raw "$seen")" != "$(real_path_or_raw "$WT")" ]; then
    echo "error: endpoint did not enter its exact acquired worktree for $ID" >&2
    return 1
  fi
  validate_spawn_worktree "treehouse get" "$T"
  spawn_endpoint_receipt_publish worktree-ready "$WT" || return 1
  spawn_worktree_request_cleanup || {
    echo "error: could not retire exact worktree acquisition evidence for $ID" >&2
    return 1
  }
}

kimi_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

# Kimi launch-readiness and delivery route their composer-emptiness half
# through the shared classifier (bin/fm-composer-lib.sh via
# fm_backend_composer_state), the same owner every steer and injection guard
# reads. This retired a fourth, spawn-local copy of composer shape knowledge -
# a hardcoded bordered `│ > │` regex that would have silently broken kimi
# spawn readiness fleet-wide the day kimi's TUI goes borderless the way
# claude's did. The banner and brief-echo greps below are launch-progress
# signals, not composer shapes, so they stay here.
kimi_composer_is_empty() {
  [ "$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null)" = empty ]
}

kimi_wait_for_ready() {
  local pane i=0 max=${FM_KIMI_READY_POLLS:-60} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    if printf '%s\n' "$pane" | grep -Fq 'Welcome to Kimi Code!' \
       || kimi_composer_is_empty; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_delivery_is_confirmed() {  # <plain-pane-capture>
  local pane=$1
  kimi_composer_is_empty || return 1
  if { printf '%s\n' "$pane" | grep -Fq '✨' \
       && printf '%s\n' "$pane" | grep -Fq 'FIRSTMATE_OP:'; } \
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

kimi_submission_cleanup_preflight() {
  local path value pid token verdict
  path="$SPAWN_LAUNCH_REQUEST/kimi-submission"
  [ -f "$path" ] && [ ! -L "$path" ] \
    && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
  value=$(tr -d '\n' < "$path") || return 1
  case "$value" in accepted|pending) ;; *) return 1 ;; esac
  for path in \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-owner"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] \
      && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
    value=$(tr -d '\n' < "$path") || return 1
    pid=${value%%:*}
    token=${value#*:}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
  done
  for path in \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-go" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.entering" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-started"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    spawn_launch_request_file_matches "$path" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
  done
  path="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.entering.baseline"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
    IFS=$'\t' read -r token value verdict < "$path" || return 1
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] && [ -z "$verdict" ] || return 1
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
  fi
  path="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-result"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
    IFS=$'\t' read -r token verdict < "$path" || return 1
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    case "$verdict" in empty|accepted|pending|pending-unproven|unsent|send-failed|ambiguous|unknown) ;; *) return 1 ;; esac
  fi
  path="$SPAWN_LAUNCH_REQUEST/kimi-submit-result"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
    IFS=$'\t' read -r token verdict < "$path" || return 1
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    case "$verdict" in accepted|pending) ;; *) return 1 ;; esac
  fi
}

kimi_submission_entering_recovery() {  # <entering-path>
  local entering=$1 verdict
  verdict=$(FM_BACKEND_SUBMIT_ENTERING_EVIDENCE_FILE=$entering \
    FM_BACKEND_SUBMIT_TYPED_EVIDENCE_FILE="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted" \
    FM_BACKEND_SUBMIT_TYPED_EVIDENCE_TOKEN=$SPAWN_LAUNCH_REQUEST_TOKEN \
    fm_backend_dead_entering_verdict "$BACKEND" "$T" "$W" \
      "$entering" "$SPAWN_LAUNCH_REQUEST_TOKEN") || return 1
  case "$verdict" in accepted|unsent|ambiguous) printf '%s' "$verdict" ;; *) return 1 ;; esac
}

kimi_submission_state() {
  local path="$SPAWN_LAUNCH_REQUEST/kimi-submission" owner go attempted entering result operation_owner operation_started operation_result
  local value links pid token verdict
  owner="$SPAWN_LAUNCH_REQUEST/kimi-submit-owner"
  go="$SPAWN_LAUNCH_REQUEST/kimi-submit-go"
  attempted="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted"
  entering="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.entering"
  result="$SPAWN_LAUNCH_REQUEST/kimi-submit-result"
  operation_owner="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-owner"
  operation_started="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-started"
  operation_result="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-result"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'absent'; return 0; fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(spawn_file_link_count "$path") || return 1
  [ "$links" = 1 ] || return 1
  value=$(tr -d '\n' < "$path") || return 1
  case "$value" in pending|accepted) printf '%s' "$value"; return 0 ;; prepared) ;; *) return 1 ;; esac
  if [ -e "$result" ] || [ -L "$result" ]; then
    [ -f "$result" ] && [ ! -L "$result" ] \
      && [ "$(spawn_file_link_count "$result")" = 1 ] || return 1
    IFS=$'\t' read -r token verdict < "$result" || return 1
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    case "$verdict" in
      accepted|pending|ambiguous|unsent) printf '%s' "$verdict" ;;
      send-failed) printf 'ambiguous' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  if [ -e "$operation_result" ] || [ -L "$operation_result" ]; then
    [ -f "$operation_result" ] && [ ! -L "$operation_result" ] \
      && [ "$(spawn_file_link_count "$operation_result")" = 1 ] || return 1
    IFS=$'\t' read -r token verdict < "$operation_result" || return 1
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    case "$verdict" in
      empty|accepted) printf 'accepted' ;;
      pending|pending-unproven) printf 'pending' ;;
      unsent) printf 'unsent' ;;
      *) printf 'ambiguous' ;;
    esac
    return 0
  fi
  if [ -e "$operation_owner" ] || [ -L "$operation_owner" ]; then
    [ -f "$operation_owner" ] && [ ! -L "$operation_owner" ] \
      && [ "$(spawn_file_link_count "$operation_owner")" = 1 ] || return 1
    value=$(tr -d '\n' < "$operation_owner") || return 1
    pid=${value%%:*}
    token=${value#*:}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
    if kill -0 "$pid" 2>/dev/null; then
      printf 'submitting'
    elif [ -e "$attempted" ] || [ -L "$attempted" ]; then
      spawn_launch_request_file_matches "$attempted" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
      printf 'ambiguous'
    elif [ -e "$entering" ] || [ -L "$entering" ]; then
      spawn_launch_request_file_matches "$entering" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
      kimi_submission_entering_recovery "$entering"
    else
      if [ -e "$operation_started" ] || [ -L "$operation_started" ]; then
        spawn_launch_request_file_matches "$operation_started" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
      fi
      printf 'unsent'
    fi
    return 0
  fi
  if [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    if [ -e "$attempted" ] || [ -L "$attempted" ]; then return 1; fi
    printf 'prepared'
    return 0
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] \
    && [ "$(spawn_file_link_count "$owner")" = 1 ] || return 1
  value=$(tr -d '\n' < "$owner") || return 1
  pid=${value%%:*}
  token=${value#*:}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$token" = "$SPAWN_LAUNCH_REQUEST_TOKEN" ] || return 1
  if [ ! -e "$go" ] && [ ! -L "$go" ]; then
    [ ! -e "$attempted" ] && [ ! -L "$attempted" ] || return 1
    printf 'prepared'
  else
    spawn_launch_request_file_matches "$go" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
    if kill -0 "$pid" 2>/dev/null; then
      printf 'submitting'
    else
      if [ -e "$attempted" ] || [ -L "$attempted" ]; then
        spawn_launch_request_file_matches "$attempted" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
        printf 'ambiguous'
      elif [ -e "$entering" ] || [ -L "$entering" ]; then
        spawn_launch_request_file_matches "$entering" "$SPAWN_LAUNCH_REQUEST_TOKEN" || return 1
        kimi_submission_entering_recovery "$entering"
      else
        printf 'prepared'
      fi
    fi
  fi
}

kimi_submission_reset_unsent() {
  local path
  for path in \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-go" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.entering" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.entering.baseline" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-owner" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-started" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted.operation-result" \
    "$SPAWN_LAUNCH_REQUEST/kimi-submit-result"
  do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] \
        && [ "$(spawn_file_link_count "$path")" = 1 ] || return 1
      rm -f -- "$path" || return 1
    fi
  done
}

kimi_submission_publish() {  # <prepared|pending|accepted>
  local value=$1 tmp="$SPAWN_LAUNCH_REQUEST/.kimi-submission.tmp"
  case "$value" in prepared|pending|accepted) ;; *) return 1 ;; esac
  printf '%s\n' "$value" > "$tmp" && chmod 600 "$tmp" \
    && mv -- "$tmp" "$SPAWN_LAUNCH_REQUEST/kimi-submission"
}

kimi_submission_helper() {
  local owner="$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" go="$SPAWN_LAUNCH_REQUEST/kimi-submit-go"
  local attempted="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted"
  local result="$SPAWN_LAUNCH_REQUEST/kimi-submit-result" tmp verdict i=0
  set +e
  umask 077
  tmp="$SPAWN_LAUNCH_REQUEST/.kimi-submit-owner.tmp"
  printf '%s:%s\n' "${BASHPID:-$$}" "$SPAWN_LAUNCH_REQUEST_TOKEN" > "$tmp" \
    && chmod 600 "$tmp" && mv -- "$tmp" "$owner" || exit 1
  while ! spawn_launch_request_file_matches "$go" "$SPAWN_LAUNCH_REQUEST_TOKEN" 2>/dev/null; do
    [ ! -e "$go" ] && [ ! -L "$go" ] || exit 1
    i=$((i + 1))
    [ "$i" -lt 1200 ] || exit 3
    sleep 0.05
  done
  verdict=$(fm_backend_send_text_submit_journaled \
    "$attempted" "$SPAWN_LAUNCH_REQUEST_TOKEN" \
    "$BACKEND" "$T" "$KIMI_INPUT" "$KIMI_SUBMIT_RETRIES" \
    "$KIMI_SUBMIT_SLEEP" "$KIMI_SUBMIT_SETTLE" "$W") || verdict=ambiguous
  case "$verdict" in
    empty|accepted) verdict=accepted ;;
    pending|pending-unproven) verdict=pending ;;
    unsent) verdict=unsent ;;
    send-failed)
      verdict=$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null) || verdict=unknown
      case "$verdict" in pending|pending-unproven) verdict=pending ;; *) verdict=ambiguous ;; esac
      ;;
    *) verdict=ambiguous ;;
  esac
  tmp="$SPAWN_LAUNCH_REQUEST/.kimi-submit-result.tmp"
  printf '%s\t%s\n' "$SPAWN_LAUNCH_REQUEST_TOKEN" "$verdict" > "$tmp" \
    && chmod 600 "$tmp" && mv -- "$tmp" "$result"
}

kimi_submission_start() {
  local owner="$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" go="$SPAWN_LAUNCH_REQUEST/kimi-submit-go"
  local attempted="$SPAWN_LAUNCH_REQUEST/kimi-submit-attempted"
  local result="$SPAWN_LAUNCH_REQUEST/kimi-submit-result" helper_pid owner_value owner_pid i=0 state tmp
  state=$(kimi_submission_state) || return 1
  if [ "$state" = prepared ] && { [ -e "$owner" ] || [ -L "$owner" ]; }; then
    [ ! -e "$attempted" ] && [ ! -L "$attempted" ] || return 1
    owner_value=$(tr -d '\n' < "$owner") || return 1
    owner_pid=${owner_value%%:*}
    case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -f -- "$owner" || return 1
    fi
  fi
  if [ ! -e "$owner" ] && [ ! -L "$owner" ] \
    && [ ! -e "$result" ] && [ ! -L "$result" ]; then
    (trap - EXIT; trap '' HUP INT TERM; kimi_submission_helper) \
      </dev/null >/dev/null 2>&1 &
    helper_pid=$!
    while [ ! -e "$owner" ] && [ ! -L "$owner" ] \
      && [ ! -e "$result" ] && [ ! -L "$result" ] \
      && kill -0 "$helper_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.01
      i=$((i + 1))
    done
  fi
  [ -e "$owner" ] || [ -e "$result" ] || return 1
  if [ ! -e "$go" ] && [ ! -L "$go" ]; then
    tmp="$SPAWN_LAUNCH_REQUEST/.kimi-submit-go.tmp"
    printf '%s\n' "$SPAWN_LAUNCH_REQUEST_TOKEN" > "$tmp" \
      && chmod 600 "$tmp" && mv -- "$tmp" "$go" || return 1
  fi
  spawn_launch_request_file_matches "$go" "$SPAWN_LAUNCH_REQUEST_TOKEN"
}

kimi_submission_wait() {
  local state i=0 max=${FM_KIMI_SUBMISSION_POLLS:-100} interval=${FM_KIMI_SUBMISSION_INTERVAL:-0.1}
  while [ "$i" -lt "$max" ]; do
    state=$(kimi_submission_state) || return 1
    case "$state" in accepted|pending|unsent) printf '%s' "$state"; return 0 ;; ambiguous) return 2 ;; esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 3
}

kimi_deliver_launch_brief() {
  local recovery=${1:-fresh} submission_state composer_state journal=0
  if [ "$recovery" = recovery ] && kimi_wait_for_delivery; then return 0; fi
  if [ "$RELAUNCH" -eq 0 ]; then
    journal=1
    submission_state=$(kimi_submission_state) || {
      kimi_spawn_fail "kimi launch brief submission evidence is unsafe"
      return 1
    }
  else
    submission_state=absent
  fi
  if [ "$submission_state" = submitting ]; then
    submission_state=$(kimi_submission_wait) || {
      kimi_spawn_fail "kimi launch brief submission remains ambiguous"
      return 1
    }
  fi
  if [ "$submission_state" = unsent ]; then
    kimi_submission_reset_unsent || {
      kimi_spawn_fail "kimi unsent launch brief submission could not be retired"
      return 1
    }
    submission_state=prepared
  fi
  if [ "$submission_state" = prepared ] \
    && { [ -e "$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" ] \
      || [ -L "$SPAWN_LAUNCH_REQUEST/kimi-submit-owner" ]; }; then
    composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null) || composer_state=unknown
    case "$composer_state" in
      pending|pending-unproven)
        kimi_submission_publish pending || {
          kimi_spawn_fail "kimi pending launch brief submission could not be reconciled"
          return 1
        }
        submission_state=pending
        ;;
      empty) ;;
      *)
        kimi_spawn_fail "kimi launch brief submission remains ambiguous"
        return 1
        ;;
    esac
  elif [ "$submission_state" = ambiguous ]; then
    composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null) || composer_state=unknown
    case "$composer_state" in
      pending|pending-unproven) submission_state=pending ;;
      empty)
        kimi_spawn_fail "kimi launch brief submission remains ambiguous"
        return 1
        ;;
      *)
        kimi_spawn_fail "kimi launch brief submission remains ambiguous"
        return 1
        ;;
    esac
  fi
  if [ "$submission_state" = absent ] || [ "$submission_state" = prepared ]; then
    if ! kimi_wait_for_ready; then
      kimi_spawn_fail "kimi did not show a verified ready signal before brief delivery"
      return 1
    fi
    KIMI_INPUT=$SPAWN_BRIEF_INPUT
    KIMI_SUBMIT_RETRIES=${FM_KIMI_SUBMIT_RETRIES:-3}
    KIMI_SUBMIT_SLEEP=${FM_KIMI_SUBMIT_SLEEP:-${FM_KIMI_POLL_INTERVAL:-0.5}}
    KIMI_SUBMIT_SETTLE=${FM_KIMI_SUBMIT_SETTLE:-0}
    if [ "$journal" -eq 1 ]; then
      if [ "$submission_state" = absent ]; then
        kimi_submission_publish prepared || {
          kimi_spawn_fail "kimi launch brief submission could not be prepared"
          return 1
        }
      fi
      kimi_submission_start || {
        kimi_spawn_fail "kimi launch brief submission owner could not be started"
        return 1
      }
      KIMI_SUBMIT_VERDICT=$(kimi_submission_wait) || {
        kimi_spawn_fail "kimi launch brief submission remains ambiguous"
        return 1
      }
      if [ "$KIMI_SUBMIT_VERDICT" = unsent ]; then
        kimi_submission_reset_unsent || {
          kimi_spawn_fail "kimi unsent launch brief submission could not be retired"
          return 1
        }
        kimi_submission_start || {
          kimi_spawn_fail "kimi launch brief submission owner could not be restarted"
          return 1
        }
        KIMI_SUBMIT_VERDICT=$(kimi_submission_wait) || {
          kimi_spawn_fail "kimi launch brief submission remains ambiguous"
          return 1
        }
        if [ "$KIMI_SUBMIT_VERDICT" = unsent ]; then
          kimi_submission_reset_unsent || {
            kimi_spawn_fail "kimi unsent launch brief submission could not be retired"
            return 1
          }
          kimi_spawn_fail "kimi launch brief could not be submitted"
          return 1
        fi
      fi
    else
      KIMI_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
        "$BACKEND" "$T" "$KIMI_INPUT" "$KIMI_SUBMIT_RETRIES" \
        "$KIMI_SUBMIT_SLEEP" "$KIMI_SUBMIT_SETTLE" "$W") || {
        kimi_spawn_fail "kimi launch brief could not be submitted"
        return 1
      }
    fi
    case "$KIMI_SUBMIT_VERDICT" in
      pending) submission_state=pending ;;
      accepted|empty) submission_state=accepted ;;
      *)
        kimi_spawn_fail "kimi launch brief submission remains ambiguous"
        return 1
        ;;
    esac
    if [ "$journal" -eq 1 ]; then
      kimi_submission_publish "$submission_state" || {
        kimi_spawn_fail "kimi launch brief submission could not be journaled"
        return 1
      }
    fi
  elif [ "$submission_state" = pending ]; then
    spawn_send_key "$T" Enter || {
      kimi_spawn_fail "kimi pending launch brief could not be resubmitted"
      return 1
    }
  fi
  if ! kimi_wait_for_delivery; then
    kimi_spawn_fail "kimi launch brief delivery was not confirmed"
    return 1
  fi
}

if [ "$SPAWN_KIMI_DELIVERY_RECOVERY" -eq 1 ]; then
  kimi_deliver_launch_brief recovery || exit 1
  commit_secondmate_work_identity || {
    echo "error: delivered secondmate launch identity requires reconciliation for $ID" >&2
    exit 1
  }
  spawn_endpoint_receipt_retire || {
    echo "error: delivered secondmate launch receipt could not be retired for $ID" >&2
    exit 1
  }
  spawn_launch_request_cleanup \
    || echo "warning: delivered secondmate launch request could not be retired for $ID" >&2
  SPAWN_DISPATCH_PENDING=0
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
    fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME" || true
  fi
  echo "spawned $ID harness=$HARNESS kind=secondmate mode=secondmate yolo=off window=$T worktree=$WT"
  exit 0
fi

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
    echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}', not its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
    exit 1
  fi
  [ "$KIND" = secondmate ] || validate_spawn_worktree "relaunch" "$T"
elif [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  if [ "$SPAWN_ENDPOINT_PHASE" = worktree-ready ]; then
    recovered_worktree=$WT
    recovered_seen=
    for _ in $(seq 1 10); do
      case "$BACKEND" in
        zellij|cmux) recovered_seen=$(spawn_passive_current_path "$WT_TARGET" || true) ;;
        *) recovered_seen=$(spawn_current_path "$WT_TARGET" || true) ;;
      esac
      [ -z "$recovered_seen" ] \
        || [ "$(real_path_or_raw "$recovered_seen")" != "$(real_path_or_raw "$recovered_worktree")" ] \
        || break
      sleep 0.5
    done
    if [ -z "$recovered_seen" ] \
       || [ "$(real_path_or_raw "$recovered_seen")" != "$(real_path_or_raw "$recovered_worktree")" ]; then
      echo "error: recovered endpoint $T is not in its exact recorded worktree for $ID" >&2
      exit 1
    fi
    validate_spawn_worktree "recovered endpoint" "$T"
    WORKTREE_REQUEST_DIGEST=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION" | spawn_sha256_stream) || exit 1
    WORKTREE_REQUEST_MARKER="$STATE/.$ID.worktree-request.$WORKTREE_REQUEST_DIGEST"
    WORKTREE_REQUEST_ACK="$WORKTREE_REQUEST_MARKER.send"
    if [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ]; then
      [ -d "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ] || {
        echo "error: exact worktree request marker is unsafe for $ID" >&2
        exit 1
      }
    fi
    case "$BACKEND" in
      zellij|cmux)
        spawn_worktree_request_cleanup || {
          echo "error: exact worktree request acknowledgement is unsafe for $ID" >&2
          exit 1
        }
        ;;
    esac
  else
    case "$BACKEND" in
      zellij|cmux)
        spawn_session_backend_worktree_acquire || exit 1
        ;;
      *)
    WORKTREE_REQUEST_DIGEST=$(printf '%s' "$SPAWN_DISPATCH_TRANSACTION" | spawn_sha256_stream) || exit 1
    WORKTREE_REQUEST_MARKER="$STATE/.$ID.worktree-request.$WORKTREE_REQUEST_DIGEST"
    WORKTREE_REQUEST_ACK="$WORKTREE_REQUEST_MARKER.send"
    WORKTREE_REQUEST_COMMAND="mkdir -m 700 -- $(shell_quote "$WORKTREE_REQUEST_MARKER") && { treehouse get; rc=\$?; if [ \"\$rc\" -ne 0 ]; then rmdir $(shell_quote "$WORKTREE_REQUEST_MARKER") 2>/dev/null || true; fi; [ \"\$rc\" -eq 0 ]; }"
    worktree_request_recovery=0
    worktree_request_send_ready=0
    worktree_request_retryable=0
    case "$SPAWN_ENDPOINT_PHASE" in
      endpoint-created)
        if [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ]; then
          echo "error: stale worktree request acknowledgement exists before dispatch for $ID" >&2
          exit 1
        fi
        spawn_endpoint_receipt_publish worktree-requesting || {
          echo "error: could not publish worktree request intent for $ID" >&2
          exit 1
        }
        spawn_worktree_request_send "$WT_TARGET" "$WORKTREE_REQUEST_COMMAND" || {
          echo "error: could not send worktree acquisition for $ID; request intent preserved" >&2
          exit 1
        }
        spawn_endpoint_receipt_publish worktree-requested || {
          echo "error: could not confirm the sent worktree request for $ID" >&2
          exit 1
        }
        ;;
      worktree-unsent|worktree-requesting|worktree-requested)
        worktree_request_recovery=1
        ;;
      worktree-retryable)
        echo "error: retryable worktree request is unsupported for backend $BACKEND" >&2
        exit 1
        ;;
      *)
        echo "error: endpoint receipt has no valid worktree acquisition phase for $ID" >&2
        exit 1
        ;;
    esac

    worktree_poll_max=${FM_SPAWN_WORKTREE_POLLS:-60}
    worktree_poll_interval=${FM_SPAWN_WORKTREE_INTERVAL:-1}
    worktree_request_round=0
    while [ "$worktree_request_round" -lt 2 ] && [ -z "$WT" ]; do
      candidate=""
      if [ "$worktree_request_send_ready" -eq 0 ]; then
        for _ in $(seq 1 "$worktree_poll_max"); do
        p=$(spawn_current_path "$WT_TARGET" || true)
        if [ -n "$p" ]; then
          p_real=$(real_path_or_raw "$p")
          if [ "$p_real" != "$PROJ_ABS_REAL" ]; then
            if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
              WT="$p"
              break
            fi
            candidate="$p_real"
          else
            candidate=""
          fi
        else
          candidate=""
        fi
          sleep "$worktree_poll_interval"
        done
      fi
      [ -z "$WT" ] || break
      [ "$worktree_request_recovery" -eq 1 ] || break
      if [ "$worktree_request_retryable" -eq 1 ]; then
        spawn_worktree_request_cleanup || {
          echo "error: could not retire proven no-resource worktree evidence for $ID" >&2
          exit 1
        }
        worktree_request_retryable=0
      fi

      worktree_request_idle=0
      case "$BACKEND" in
        tmux)
          [ "$(fm_backend_agent_state "$BACKEND" "$T")" != dead ] || worktree_request_idle=1
          ;;
        herdr)
          if fm_backend_herdr_pane_idle_shell_pid "$HERDR_SES" "$HERDR_PANE_ID" >/dev/null; then
            worktree_request_idle=1
          fi
          ;;
      esac
      [ "$worktree_request_idle" -eq 1 ] || break
      if [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ]; then
        [ -d "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ] \
          || { echo "error: worktree request marker is unsafe: $WORKTREE_REQUEST_MARKER" >&2; exit 1; }
        break
      fi
      spawn_endpoint_receipt_publish worktree-requesting || {
        echo "error: could not republish worktree request intent for $ID" >&2
        exit 1
      }
      worktree_send_rc=0
      spawn_worktree_request_send "$WT_TARGET" "$WORKTREE_REQUEST_COMMAND" || worktree_send_rc=$?
      if [ "$worktree_send_rc" -ne 0 ]; then
        echo "error: could not resume failed worktree acquisition for $ID; request intent preserved" >&2
        exit 1
      fi
      spawn_endpoint_receipt_publish worktree-requested || {
        echo "error: could not confirm the resumed worktree request for $ID" >&2
        exit 1
      }
      worktree_request_recovery=0
      worktree_request_send_ready=0
      worktree_request_round=$((worktree_request_round + 1))
    done
    if [ -z "$WT" ]; then
      echo "error: treehouse get did not enter a worktree; in-flight request preserved for $ID at $T" >&2
      exit 1
    fi

    validate_spawn_worktree "treehouse get" "$T"
    spawn_endpoint_receipt_publish worktree-ready "$WT" || {
      echo "error: could not bind the recovered endpoint worktree for $ID" >&2
      exit 1
    }
    if [ -e "$WORKTREE_REQUEST_MARKER" ] || [ -L "$WORKTREE_REQUEST_MARKER" ]; then
      [ -d "$WORKTREE_REQUEST_MARKER" ] && [ ! -L "$WORKTREE_REQUEST_MARKER" ] || {
        echo "error: worktree request marker is unsafe: $WORKTREE_REQUEST_MARKER" >&2
        exit 1
      }
    fi
        ;;
    esac
  fi
fi
if [ "$KIND" != secondmate ]; then
  spawn_provisional_harness_wiring_recover || exit 1
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] \
   && [ "$SPAWN_METADATA_RECOVERY" -eq 0 ]; then
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
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$RELAUNCH" -eq 1 ] && [ "$SPAWN_METADATA_RECOVERY" -eq 0 ]; then
  # Retire the previous incarnation's per-task harness wiring before arming the
  # new one. Without this, a harness switch would leave the old adapter's hook
  # files and turn-end token registry entries behind, and even a same-harness
  # relaunch would orphan the retired busy generation's token
  # (bin/fm-control-lib.sh owns where those artifacts live).
  clear_relaunch_harness_wiring "$RELAUNCH_PRIOR_HARNESS" "$WT" "$STATE_REAL" "$ID" \
    "$(fm_meta_get "$RELAUNCH_META" harness_turnend_auth_path)" || {
    echo "error: could not retire $RELAUNCH_PRIOR_HARNESS wiring for task $ID; refusing to arm the replacement" >&2
    exit 1
  }
  RELAUNCH_REPLACEMENT_PENDING=1
  RELAUNCH_REPLACEMENT_HARNESS=$HARNESS
  RELAUNCH_REPLACEMENT_STATE=$STATE_REAL
  RELAUNCH_REPLACEMENT_WT=$WT
fi
HARNESS_TURNEND_AUTH_PATH=
if [ "$KIND" != secondmate ] && [ "$SPAWN_METADATA_RECOVERY" -eq 0 ]; then
  [ "$RELAUNCH" -ne 0 ] || SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=1
  HARNESS_FAMILY=$(fm_control_harness_family "$HARNESS" 2>/dev/null || true)
  case "$HARNESS_FAMILY" in
    grok)
      HARNESS_AUTH_ROOT="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
      ;;
    kimi)
      HARNESS_AUTH_ROOT="$HOME/.kimi-code/fm-turn-end.d"
      ;;

    *) HARNESS_AUTH_ROOT= ;;
  esac
  if [ -n "$HARNESS_AUTH_ROOT" ]; then
    HARNESS_TURNEND_AUTH_PATH=$(spawn_provisional_harness_auth_path \
      "$HARNESS_FAMILY" "$HARNESS_AUTH_ROOT") || {
      echo "error: could not reserve exact $HARNESS_FAMILY turn-end authorization for $ID" >&2
      exit 1
    }
    RELAUNCH_REPLACEMENT_AUTH_PATH=$HARNESS_TURNEND_AUTH_PATH
    spawn_provisional_harness_wiring_receipt_publish \
      "$HARNESS_FAMILY" "$HARNESS_TURNEND_AUTH_PATH" || {
      echo "error: could not journal provisional $HARNESS_FAMILY wiring for $ID" >&2
      exit 1
    }
  fi
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
      [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
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
      # interrupt: fm-control preserves the adapter-owned state, while the
      # legacy fm-send --key Escape path records idle/fm-interrupt. Stop keeps
      # the turn-ended NOTIFICATION touch for the watcher. Every
      # hook command tolerates a refused event (|| true) so a stale-gen writer
      # can never break Claude's own lifecycle.
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
      auth_file=$HARNESS_TURNEND_AUTH_PATH
      fm_control_harness_turnend_auth_record_valid \
        grok "${auth_file##*/}" "$auth_file" || exit 1
      spawn_provisional_harness_auth_create "$auth_file" || {
        echo "error: could not create exact Grok turn-end authorization for $ID" >&2
        exit 1
      }
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
    muse*)
      # muse's turn lifecycle is neither a hook nor a launch flag: its plugin
      # engine (the only hook surface) is disabled in the default build, so
      # firstmate reads muse's own durable session event log instead
      # (bin/fm-busy-lib.sh owns the fold). That is a PULL
      # source with no writer, so nothing is armed and no record is seeded -
      # exactly the reason standalone Kimi is not armed either.
      # This sidecar is the whole binding: it pins the sessions root, the
      # workspace root that muse records in each log's metadata, this pane's
      # binding identity, and every matching main log that predates this pane.
      # The classifier then accepts only one new matching log, so it never
      # guesses between pane incarnations. Recording the resolved root here
      # also means a later change to XDG_DATA_HOME cannot silently re-point an
      # already-running task at a different log tree.
      MUSE_SESSIONS_ROOT="${MUSE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/muse/sessions"
      MUSE_BINDING_ID="$$.$RANDOM.$(date +%s)"
      rm -f "$STATE/$ID.muse-session-current"
      {
        printf 'sessions_root=%s\n' "$MUSE_SESSIONS_ROOT"
        printf 'workspace_root=%s\n' "$WT"
        printf 'binding_id=%s\n' "$MUSE_BINDING_ID"
        while IFS= read -r MUSE_PRIOR_LOG; do
          [ -n "$MUSE_PRIOR_LOG" ] && printf 'prior_log=%s\n' "$MUSE_PRIOR_LOG"
        done <<EOF
$(fm_busy_muse_matching_logs "$MUSE_SESSIONS_ROOT" "$WT" || true)
EOF
      } > "$STATE/$ID.muse-session"
      ;;
    cursor*)
      # Cursor's turn lifecycle is neither a hook nor a launch flag: it writes
      # its own durable per-conversation transcript and brackets every turn
      # there (bin/fm-busy-lib.sh owns the fold). Like muse that is a PULL
      # source with no writer, so nothing is armed and no record is seeded.
      # This sidecar is the whole binding. It pins the projects root and the
      # exact workspace path cursor records in each project's
      # .workspace-trusted, plus every conversation that already exists for
      # that workspace, so a relaunch into a reused worktree folds its OWN
      # conversation instead of its predecessor's. The classifier then accepts
      # only one remaining conversation and never guesses between incarnations.
      CURSOR_PROJECTS_ROOT="${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}"
      {
        printf 'projects_root=%s\n' "$CURSOR_PROJECTS_ROOT"
        printf 'workspace_root=%s\n' "$WT"
        if CURSOR_PRIOR_PROJECT=$(fm_busy_cursor_project_dir "$CURSOR_PROJECTS_ROOT" "$WT" 2>/dev/null); then
          for CURSOR_PRIOR_DIR in "$CURSOR_PRIOR_PROJECT"/agent-transcripts/*/; do
            [ -d "$CURSOR_PRIOR_DIR" ] || continue
            printf 'prior_conversation=%s\n' "$(basename -- "${CURSOR_PRIOR_DIR%/}")"
          done
        fi
      } > "$STATE/$ID.cursor-session"
      ;;
    kimi*)
      # Kimi's Stop hook is global, but it is inert unless cwd contains this
      # task's token pointer and the token resolves through Firstmate's private
      # registry. The installer above owns the format-preserving config edit and
      # the always-zero, silent hook script.
      auth_file=$HARNESS_TURNEND_AUTH_PATH
      fm_control_harness_turnend_auth_record_valid \
        kimi "${auth_file##*/}" "$auth_file" || exit 1
      spawn_provisional_harness_auth_create "$auth_file" || {
        echo "error: could not create exact Kimi turn-end authorization for $ID" >&2
        exit 1
      }
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.kimi-turnend-token"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-kimi-turnend"
      exclude_path '.fm-kimi-turnend'
      ;;
  esac
fi

# Delivery posture recorded in meta so fm-teardown's safety check and the
# validate/merge stages can branch on it. A ship task carries the explicit
# per-task decision validated above; a secondmate's posture is fixed; a scout
# records none at all, because its deliverable is a report rather than a merge
# (fm-teardown.sh defaults an absent mode to no-mistakes, and fm-promote.sh
# requires an explicit mode when a scout is promoted to a ship task).
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  : "${SECONDMATE_PROJECTS:=}"
elif [ "$KIND" = scout ]; then
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
# home-session state and reuses it for the carrier and Secondmate launch prefix.
#
# A remote secondmate launch is the one case where this process is not the home
# that owns the task's identity: the parent home resolved and will record the
# carrier, and this host only delivers it. The validated --traceparent value
# then IS the decision, so the enablement snapshot handed to the new Secondmate
# agrees with the carrier it receives exactly as on the local path.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  SPAWN_TRACE_EFFECTIVE=on
  SPAWN_TRACEPARENT=$TRACEPARENT_ARG
else
  SPAWN_TRACE_EFFECTIVE=$(fm_trace_context_session_effective "$STATE/.trace-context-effective")
  if [ "$SPAWN_TRACE_EFFECTIVE" = on ]; then
    SPAWN_TRACEPARENT=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$STATE/$ID.meta" || true)
  else
    SPAWN_TRACEPARENT=
  fi
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W

spawn_commit_backlog_transition() {
  [ "$BACKLOG_TRANSITION" = 1 ] || return 0
  fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"
}

if [ "$SPAWN_METADATA_RECOVERY" -eq 1 ]; then
  spawn_metadata_transaction_published || {
    echo "error: definitely unsent secondmate launch has no exact published metadata for $ID" >&2
    exit 1
  }
  SPAWN_GEN=$(fm_meta_get "$STATE/$ID.meta" spawn_gen)
  [ -n "$SPAWN_GEN" ] || {
    echo "error: definitely unsent secondmate launch metadata has no incarnation for $ID" >&2
    exit 1
  }
  SPAWN_DISPATCH_PENDING=0
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK"
  fi
else
SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
SPAWN_META_TMP=$(umask 077; mktemp "$STATE/.$ID.meta.XXXXXX") || exit 1
if [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_FRESH_COMMIT_PENDING=1
fi
SPAWN_META_PATH=$SPAWN_META_TMP
preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree project launch_brief launch_brief_sha256 work_identity_dispatch_transaction harness harness_turnend_auth_path kind mode yolo tasktmp model effort busy_gen spawn_gen traceparent work_identity_schema work_identity_status work_identity_sha256 backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx", keys, " ")
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
  echo "launch_brief=$BRIEF"
  echo "launch_brief_sha256=$LAUNCH_BRIEF_HASH"
  echo "work_identity_dispatch_transaction=$SPAWN_DISPATCH_TRANSACTION"
  echo "harness=$HARNESS"
  [ -z "$HARNESS_TURNEND_AUTH_PATH" ] || \
    echo "harness_turnend_auth_path=$HARNESS_TURNEND_AUTH_PATH"
  echo "kind=$KIND"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  if [ -n "$WORK_IDENTITY_STATUS" ]; then
    echo "work_identity_schema=$WORK_IDENTITY_SCHEMA"
    echo "work_identity_status=$WORK_IDENTITY_STATUS"
    [ "$WORK_IDENTITY_STATUS" != linked ] || echo "work_identity_sha256=$WORK_IDENTITY_HASH"
  fi
  # Default-off writes no traceparent= line.
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
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
} > "$SPAWN_META_PATH" || {
  echo "error: task record for $ID could not be prepared at $SPAWN_META_PATH" >&2
  exit 1
}
chmod 600 "$SPAWN_META_PATH" || exit 1
SPAWN_META_PUBLISH_STARTED=1
FM_HOME="$FM_HOME" \
  FM_DATA_OVERRIDE="$DATA" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_ROOT_OVERRIDE="$FM_ROOT" \
  "$SCRIPT_DIR/fm-work-identity.sh" dispatch-publish "$ID" \
    --brief "$BRIEF" --meta "$SPAWN_META_PATH" \
    --transaction "$SPAWN_DISPATCH_TRANSACTION" >/dev/null \
  || exit 1
spawn_provisional_harness_wiring_receipt_retire || {
  echo "error: published harness wiring receipt could not be retired for $ID" >&2
  exit 1
}

# Fuse the backlog In-flight transition into the identity owner's publication
# that just created the record. The call itself is deferred to the final commit
# point below so every earlier launch-delivery failure remains unwindable.
[ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_PENDING=0
SPAWN_META_PUBLISH_STARTED=0
published_meta_candidate=$SPAWN_META_TMP
SPAWN_META_TMP=
rm -f -- "$published_meta_candidate" \
  || echo "warning: could not retire published metadata candidate for $ID" >&2
SPAWN_DISPATCH_PENDING=0
if [ "$RELAUNCH" -eq 0 ]; then
  if [ "$BACKEND" = orca ]; then
    spawn_orca_operation_retire || {
      echo "error: could not retire Orca endpoint operation journal for $ID" >&2
      exit 1
    }
  fi
fi
# A dispatch or relaunch keeps the per-task meta lock through launch delivery.
# The backlog mutation is deliberately the final fallible commit below, so
# teardown cannot remove a relaunched record while its replacement worker is
# still being delivered, cannot observe or complete a fresh provisional record
# between its state check and `tasks-axi start`, and a delivery failure cannot
# follow a committed In-flight transition.
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
fi
"$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0
fi

sq_brief=$(shell_quote "$BRIEF")
sq_brief_input=$(shell_quote "$SPAWN_BRIEF_INPUT")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_worktree=$(shell_quote "$WT")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=$(render_launch "$LAUNCH") || exit 1
case "$HARNESS" in
  claude|codex|opencode|pi|pi-signed|grok|kimi|muse)
    LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS $LAUNCH"
    ;;
esac
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
  # Keep this in step with fm_supervision_model (bin/fm-wake-lib.sh): Claude's
  # Stop auto-arm and Cursor's stop-hook park both run the watcher only BETWEEN
  # turns, so a fresh beacon with no live watcher is their healthy mid-turn state.
  case "$HARNESS" in
    claude|cursor) supervision_model=autoarm ;;
    *) supervision_model=persistent ;;
  esac
  # Deliver the primary's EFFECTIVE trace-context decision as a normalized on/off
  # literal (never the raw FM_TRACE_CONTEXT string) so a FM_TRACE_CONTEXT override
  # on the primary reaches the secondmate's OWN workers, not just the copied
  # config/trace-context file: otherwise off would not disable them and on would
  # not enable them across the launch boundary (bin/fm-trace-context-lib.sh header).
  # Reuse the single frozen decision from the carrier resolution above so the
  # injected carrier and this on/off snapshot are guaranteed to agree.
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$sq_primary_home FM_HOME=$sq_home FM_TRACE_CONTEXT=$SPAWN_TRACE_EFFECTIVE FM_SUPERVISION_MODEL=$supervision_model $LAUNCH"
fi
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  # Fresh publication still owns the lock. Relaunch deliberately uses a short
  # independent critical section so other metadata interfaces can serialize.
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK" || return 1
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  if ! fm_meta_replace_expect "$meta"; then
    status=1
  else
    SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
    if [ ! -f "$meta" ] || [ ! -w "$meta" ] \
       || ! awk -F= '$1 != "traceparent"' "$meta" > "$SPAWN_META_TMP" \
       || ! printf 'traceparent=%s\n' "$SPAWN_TRACEPARENT" >> "$SPAWN_META_TMP" \
       || ! fm_meta_atomic_replace "$SPAWN_META_TMP" "$meta"; then
      status=1
      rm -f "$SPAWN_META_TMP" 2>/dev/null || true
    fi
  fi
  SPAWN_META_TMP=
  if [ "$acquired" = 1 ]; then
    if fm_lock_release "$SPAWN_META_LOCK"; then
      SPAWN_META_LOCK_HELD=0
    else
      status=1
    fi
  fi
  return "$status"
}

if [ "$RELAUNCH" -eq 0 ]; then
  spawn_launch_request_paths || exit 1
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    spawn_record_traceparent || {
      echo "error: trace metadata could not be validated and published safely for $ID" >&2
      exit 1
    }
  fi
  LAUNCH_COMMAND="export GOTMPDIR=$(shell_quote "$TASK_TMP/gotmp")"
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    LAUNCH_COMMAND="$LAUNCH_COMMAND && export TRACEPARENT=$(shell_quote "$SPAWN_TRACEPARENT")"
  fi
  LAUNCH_GUARD=$SPAWN_LAUNCH_GUARD
  sq_launch_outcome=$(shell_quote "$SPAWN_LAUNCH_OUTCOME")
  sq_launch_token=$(shell_quote "$SPAWN_LAUNCH_REQUEST_TOKEN")
  sq_launch_request=$(shell_quote "$SPAWN_LAUNCH_REQUEST")
  sq_launch_guard=$(shell_quote "$LAUNCH_GUARD")
  if [ "$RAW_LAUNCH" -eq 1 ]; then
    sq_launch_eval=$(shell_quote "exec env $LAUNCH")
  else
    sq_launch_eval=$(shell_quote "$LAUNCH")
  fi
  LAUNCH_CHILD_COMMAND="printf '%s:%s\\n' \"\$\$\" $sq_launch_token > $sq_launch_guard/.child.tmp && chmod 600 $sq_launch_guard/.child.tmp && mv $sq_launch_guard/.child.tmp $sq_launch_guard/child || exit 1; exec sh -c $sq_launch_eval"
  sq_launch_child=$(shell_quote "$LAUNCH_CHILD_COMMAND")
  LAUNCH_COMMAND="$LAUNCH_COMMAND && if mkdir $sq_launch_guard 2>/dev/null; then printf '%s:%s\\n' \"\$\$\" $sq_launch_token > $sq_launch_guard/.owner.tmp && chmod 600 $sq_launch_guard/.owner.tmp && mv $sq_launch_guard/.owner.tmp $sq_launch_guard/owner || exit 1; set +m 2>/dev/null || true; sh -c $sq_launch_child & launch_pid=\$!; wait \"\$launch_pid\"; launch_rc=\$?; printf 'exited:%s:%s\\n' \"\$launch_rc\" $sq_launch_token > $sq_launch_request/.outcome.tmp && chmod 600 $sq_launch_request/.outcome.tmp && mv $sq_launch_request/.outcome.tmp $sq_launch_outcome; exit \$launch_rc; fi"
  if [ "$SPAWN_LAUNCH_SUBMITTED_RECOVERY" -ne 1 ]; then
    spawn_endpoint_receipt_publish launch-prepared "$WT" || {
      echo "error: launch preparation could not be journaled for $ID" >&2
      exit 1
    }
    spawn_launch_request_start "$LAUNCH_COMMAND" || {
      echo "error: launch request owner could not be started for $ID" >&2
      exit 1
    }
    launch_delivery_status=0
    spawn_launch_delivery_wait || launch_delivery_status=$?
    if [ "$launch_delivery_status" -ne 0 ]; then
      launch_request_state=$(spawn_launch_request_state) || {
        echo "error: launch request evidence is unsafe for $ID" >&2
        exit 1
      }
      case "$launch_request_state" in
        launch-exited)
          spawn_exited_launch_compensate || {
            echo "error: terminal launch for $ID could not be compensated safely" >&2
            exit 1
          }
          echo "error: launch for $ID terminated before commit; its provisional publication was compensated - rerun spawn to retry" >&2
          ;;
        *)
          echo "error: launch submission is incomplete or ambiguous; exact request evidence is preserved for $ID" >&2
          ;;
      esac
      exit 1
    fi
    spawn_endpoint_receipt_publish launch-submitted "$WT" || {
      echo "error: launch was accepted, but its exact acceptance receipt could not be published for $ID" >&2
      exit 1
    }
  fi
  launch_request_state=$(spawn_launch_request_state) || {
    echo "error: accepted launch evidence is unsafe for $ID" >&2
    exit 1
  }
  if [ "$launch_request_state" = accepted ]; then
    # A transport receipt can race a short-lived child. Give its exact guard
    # one poll interval to publish a terminal outcome before committing it as
    # an active worker.
    sleep "${FM_SPAWN_LAUNCH_INTERVAL:-0.1}"
    launch_request_state=$(spawn_launch_request_state) || {
      echo "error: accepted launch evidence is unsafe for $ID" >&2
      exit 1
    }
  fi
  case "$launch_request_state" in
    accepted|executed) ;;
    launch-exited)
      spawn_exited_launch_compensate || {
        echo "error: terminal accepted launch for $ID could not be compensated safely" >&2
        exit 1
      }
      echo "error: launch for $ID terminated before commit; its provisional publication was compensated - rerun spawn to retry" >&2
      exit 1
      ;;
    *)
      echo "error: accepted launch lacks exact backend acceptance for $ID" >&2
      exit 1
      ;;
  esac
else
  spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp" || {
    echo "error: relaunch environment could not be delivered for $ID" >&2
    exit 1
  }
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    if spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then
      spawn_record_traceparent || {
        echo "error: trace metadata could not be validated and published safely for $ID" >&2
        exit 1
      }
    else
      TRACE_SEND_STATUS=$?
      if [ "$TRACE_SEND_STATUS" -eq 2 ]; then
        echo "error: trace-context input could not be cleared for $W; refusing to append the launch command" >&2
        exit 1
      fi
      LAUNCH="unset TRACEPARENT; $LAUNCH"
    fi
  fi
  sleep 0.3
  spawn_send_literal "$T" "$LAUNCH" || {
    echo "error: relaunch command could not be delivered for $ID" >&2
    exit 1
  }
  sleep 0.3
  if [ "$KIND" = secondmate ]; then
    SECONDMATE_RESERVATION_PRESERVE=1
  fi
  spawn_send_key "$T" Enter || {
    echo "error: relaunch command could not be submitted for $ID" >&2
    exit 1
  }
fi
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
if [ "$HARNESS" = kimi ]; then
  if [ "$SPAWN_LAUNCH_SUBMITTED_RECOVERY" = 1 ]; then
    kimi_deliver_launch_brief recovery || exit 1
  else
    kimi_deliver_launch_brief || exit 1
  fi
fi
if [ "$KIND" = secondmate ]; then
  commit_secondmate_work_identity || {
    echo "error: secondmate launch completed, but its unlinked identity could not be committed" >&2
    exit 1
  }
fi
if [ "$KIND" = secondmate ] && [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
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
if spawn_commit_backlog_transition; then
  SPAWN_FRESH_COMMIT_PENDING=0
  SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
else
  SPAWN_BACKLOG_COMMIT_STATUS=$?
  if spawn_commit_backlog_transition; then
    SPAWN_BACKLOG_COMMIT_STATUS=0
    SPAWN_FRESH_COMMIT_PENDING=0
    SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
  fi
fi
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  if [ "$RELAUNCH" -eq 0 ]; then
    SPAWN_FRESH_COMMIT_PENDING=0
    SPAWN_PROVISIONAL_HARNESS_WIRING_PENDING=0
    echo "error: task $ID's accepted launch could not move its backlog item to In flight ($FM_BACKLOG_TRANSITION_ERROR); exact metadata and launch acceptance were preserved - fix the backlog and re-run the spawn to finish the commit without relaunching" >&2
  else
    echo "error: task $ID was republished but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); fix the backlog and re-run the relaunch" >&2
  fi
fi
trap - HUP INT TERM
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  exit "$SPAWN_BACKLOG_COMMIT_STATUS"
fi
if [ "$RELAUNCH" -eq 0 ]; then
  spawn_endpoint_receipt_retire || {
    echo "error: accepted launch receipt could not be retired for $ID" >&2
    exit 1
  }
  spawn_launch_request_cleanup \
    || echo "warning: accepted launch request journal could not be retired for $ID" >&2
fi
fm_lock_release "$SPAWN_META_LOCK"
SPAWN_META_LOCK_HELD=0
if [ -n "$SPAWN_DEFERRED_SIGNAL" ]; then
  case "$SPAWN_DEFERRED_SIGNAL" in
    HUP) SPAWN_DEFERRED_SIGNAL_STATUS=129 ;;
    INT) SPAWN_DEFERRED_SIGNAL_STATUS=130 ;;
    TERM) SPAWN_DEFERRED_SIGNAL_STATUS=143 ;;
  esac
  echo "error: spawn of $ID was interrupted after launch delivery began; its paired task record and In-flight backlog state were preserved" >&2
  exit "$SPAWN_DEFERRED_SIGNAL_STATUS"
fi

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT"
