#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--launch <variant>] [--backend <name>]
#        fm-spawn.sh <task-id> <project-dir> --scout [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--launch <variant>] [--backend <name>]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--launch <variant>] [--backend <name>] --secondmate
#        fm-spawn.sh --host <name> <task-id> <project-name-on-host> --mode <mode> --yolo <on|off> [--harness <name>] [--model <name>] [--effort <level>]
#        fm-spawn.sh --host <name> <task-id> <project-name-on-host> --scout [--harness <name>] [--model <name>] [--effort <level>]
#        fm-spawn.sh --host <name> <secondmate-id> --secondmate [--harness <name>] [--model <name>] [--effort <level>]
#   --host dispatches the whole spawn to a REMOTE task host over the Bifrost relay
#   (bin/fm-relay-host.sh, docs/relay-host.md).
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
#   --launch <variant> selects a NAMED LAUNCH VARIANT declared under
#   config/harness-overrides.json .[<harness>].variants.[<variant>]. A variant changes
#   only how the resolved harness starts (its binary, launch args, and launch env); it
#   never changes WHICH harness runs, so the recorded harness= and every supervision
#   fact keep applying. Variant choice is always explicit - an explicit --launch, then
#   the dispatch profile's launch field, then .[<harness>].default_variant - and is
#   never inferred from quota or any other runtime signal. Naming a variant the
#   resolved harness does not declare is a hard spawn refusal, never a silent fallback.
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
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|traex)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters. For pi and pi-signed, fm-spawn resolves the selected executable
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
#   exclusive with --backend and --launch, and WITHOUT --host not
#   one byte of the local path changes (bin/fm-relay-host.sh, docs/relay-host.md).
#   --host --secondmate <id> launches a PERSISTENT secondmate in a home that
#   machine already holds, provisioned by bin/fm-home-seed.sh <id> - --machine
#   <host>. It takes no project positional (a secondmate's subject is its home)
#   and moves no backlog row (a secondmate is not a backlog item). Re-running it
#   for a live id is the documented recovery respawn, so it is not refused for
#   having metadata already; the host's own spawn owns duplicate-agent safety.
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
#   Before a fresh ship or scout worker starts, its clean task worktree fetches
#   origin, resolves the current remote default branch, and resets to its tip.
#   An unreachable origin, unresolved default branch, or non-clean worktree
#   refuses the spawn rather than risking a PR based on stale history.
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
#     __ENV__      built-in launch env prefix, MERGED with config/harness-overrides.json .[<harness>].env
#     __CMD__      built-in binary, replaced by config/harness-overrides.json .[<harness>].command
#     __ARGS__     built-in launch args, replaced by config/harness-overrides.json .[<harness>].args
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __PIBIN__    quoted concrete Pi-family executable path resolved from PATH
#     __PITUIMODE__ optional --tui-mode regular when that executable advertises it
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
#   kimi and muse carry no override axes: their templates resolve their own binary
#   and sandbox environment, so a launch variant does not apply to them.
#     __OPINPUT__   absolute path to the canonical operational-input encoder
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
# On success prints: spawned <id> harness=<name> [launch=<variant>] kind=<ship|scout|secondmate> [mode=<mode> yolo=<on|off>] window=<backend-target> worktree=<path>
# launch= appears only when a named launch variant was selected.
# A ship task records the explicit mode/yolo it was passed; a secondmate spawn records
# mode=secondmate, yolo=off, home=, and projects=; a scout records neither, and both the
# success line and state/<id>.meta omit them.
# After metadata is durable, ship and scout spawns also ask tasks-axi to move the
# matching backlog row to In flight. A missing row or failed write is loud but
# never rolls back a live launch - state/<id>.meta remains the runtime record.
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
# Optional LOCAL (gitignored) per-harness launch override file; see
# docs/configuration.md and resolve_launch_overrides.
HARNESS_OVERRIDES="$CONFIG/harness-overrides.json"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
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
# shellcheck source=bin/fm-remote-preflight-lib.sh
. "$SCRIPT_DIR/fm-remote-preflight-lib.sh"
# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
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
KIND_SET=0
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HOST_ARG=
LAUNCH_VARIANT=
MODE=
YOLO=
TRACEPARENT_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
HOST_SET=0
LAUNCH_SET=0
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
      host) HOST_ARG=$a; HOST_SET=1 ;;
      launch) LAUNCH_VARIANT=$a; LAUNCH_SET=1 ;;
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
    --host) want_value=host ;;
    --host=*) HOST_ARG=${a#--host=}; HOST_SET=1 ;;
    --launch) want_value=launch ;;
    --launch=*) LAUNCH_VARIANT=${a#--launch=}; LAUNCH_SET=1 ;;
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
[ "$HOST_SET" -eq 0 ] || [ -n "$HOST_ARG" ] || { echo "error: --host requires a non-empty value" >&2; exit 1; }
[ "$LAUNCH_SET" -eq 0 ] || [ -n "$LAUNCH_VARIANT" ] || { echo "error: --launch requires a non-empty value" >&2; exit 1; }
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

# --host dispatches the whole spawn to a REMOTE task host over the Bifrost relay
# and returns before any local machinery runs. That ordering is the compatibility
# contract: with no --host, not one byte of the path below changes, exactly like
# the backend= rule further down. The remote host executes its OWN
# bin/fm-spawn.sh, so the worktree-isolation assertion, the harness launch, and
# the trust-dialog handling all happen locally over there rather than being
# reimplemented across the link (bin/fm-relay-host.sh, docs/relay-host.md).
if [ "$HOST_SET" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || { echo "error: --backend selects a LOCAL session provider and cannot combine with --host" >&2; exit 1; }
  [ "$LAUNCH_SET" -eq 0 ] || { echo "error: --launch names a local launch variant and cannot combine with --host" >&2; exit 1; }
  # A secondmate takes no project positional: its subject is its home, which
  # bin/fm-home-seed.sh --machine already provisioned on that machine with the
  # charter in it. Everything else about the dispatch is the ordinary remote
  # path, because the host runs its own bin/fm-spawn.sh either way.
  if [ "$KIND" = secondmate ]; then
    [ "${#POS[@]}" -ge 1 ] || { echo "error: --host --secondmate needs <secondmate-id>" >&2; exit 1; }
  else
    [ "${#POS[@]}" -ge 2 ] || { echo "error: --host needs <task-id> <project-name-on-host>" >&2; exit 1; }
  fi
  HOST_ID=${POS[0]}
  # Same task-id gate as the local path below, deliberately identical in check,
  # message, and exit code. A remote task still gets a state/<id>.meta here, so a
  # dot-leading name would write a HIDDEN record that every "$STATE"/*.meta glob
  # skips, leaving a live remote task nothing on this side can find or steer.
  fm_task_id_creation_valid "$HOST_ID" || { echo "error: invalid task id" >&2; exit 2; }
  host_spawn_args=("$HOST_ARG" "$HOST_ID")
  if [ "$KIND" = secondmate ]; then
    host_spawn_args+=(--secondmate)
  else
    HOST_PROJECT=${POS[1]}
    host_spawn_args+=("$HOST_PROJECT")
  fi
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
  # A secondmate is not a backlog item in any home, so it is skipped here for
  # exactly the reason backlog_mark_started skips it locally.
  if [ "$KIND" != secondmate ] && [ -f "$DATA/backlog.md" ] && command -v tasks-axi >/dev/null 2>&1; then
    (cd "$FM_HOME" && tasks-axi start "$HOST_ID" --file "$DATA/backlog.md" >/dev/null 2>&1) \
      || echo "warning: $HOST_ID is live on $HOST_ARG but data/backlog.md was not moved to In progress" >&2
  fi
  printf 'spawned on %s: %s (arm its wake path with bin/fm-relay-check-make.sh %s)\n' \
    "$HOST_ARG" "$HOST_ID" "$HOST_ID"
  exit 0
fi

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
  if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
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
    claude|codex|opencode|pi|pi-signed|grok|kimi|traex|cursor) ;;
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
    if [ ! -f "$meta" ] || [ -L "$meta" ] \
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
      echo "error: remote secondmate $id is unavailable or launch completion is unknown; preserved route $host:$home" >&2
    fi
    return "$rc"
  fi
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
  # Record what the remote endpoint ACTUALLY carries, read back from its own
  # launch, rather than what this side hoped to deliver. That keeps the #995
  # guarantee that the recorded carrier is the identity the child received even
  # when the remote host already had a live agent and reused its endpoint. An
  # off decision delivers no carrier, but an endpoint already holding one still
  # reports it here so the parent does not deny the agent's actual identity.
  remote_recorded_traceparent=$(printf '%s\n' "$out" | sed -n 's/^traceparent=//p' | tail -1)
  fm_trace_context_valid "$remote_recorded_traceparent" || remote_recorded_traceparent=
  tmp="$meta.tmp.$$"
  {
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
    [ -z "$remote_recorded_traceparent" ] || echo "traceparent=$remote_recorded_traceparent"
  } > "$tmp"
  mv -f -- "$tmp" "$meta"
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK"
  fi
  fm_lock_release "$remote_lock" || true
  fm_lock_release "$registry_lock" || true
  fm_lock_release "$SPAWN_TASK_LOCK" || true
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
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=
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
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] \
     && [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] \
     && [ -n "$SPAWN_META_TMP" ] \
     && [ ! -e "$SPAWN_META_TMP" ] \
     && [ ! -L "$SPAWN_META_TMP" ]; then
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
            [ -z "${MODE:-}" ] || echo "mode=$MODE"
            [ -z "${YOLO:-}" ] || echo "yolo=$YOLO"
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
  local harness=$1 wt=$2 state=$3 id=$4 token_path token auth_path path
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
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  auth_path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  if [ -n "$auth_path" ]; then
    rm -f -- "$auth_path" || return 1
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
  [ -z "$LAUNCH_VARIANT" ] || shared_args+=(--launch "$LAUNCH_VARIANT")
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
  [ -f "$RELAUNCH_META" ] || {
    echo "error: --relaunch needs an existing task record; no $RELAUNCH_META" >&2
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
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|traex)
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

launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    claude) printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
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
      # traex-parity-study-n7 4.3), and its watcher uses the traex foreground
      # checkpoint (docs/supervision-protocols/traex.md). First launch in a new
      # secondmate home shows TWO dialogs - directory trust, then a hooks-review
      # "Trust all" (default, single Enter) - after which the fixed hook hashes stay
      # trusted; see the harness-adapters and secondmate-provisioning skills.
      if [ "$kind" = secondmate ]; then
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__ENV____CMD__ __MODELFLAG____EFFORTFLAG____ARGS__-c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' '__ENV____CMD__ __MODELFLAG____ARGS__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi|pi-signed)
      # Pi's launch args (--tui-mode regular) sit immediately after the binary,
      # ahead of the model/effort flags, which is the order the verified Pi
      # launch takes.
      if [ "$kind" = secondmate ]; then
        printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' '__ENV____CMD__ __ARGS____MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
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
    cursor) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS __CURSORBIN__ --trust --yolo __MODELFLAG__--workspace __WORKTREE__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # only an absolute brief pointer after the TUI readiness gate below.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task worktree token, so no launch placeholder belongs here.
    # kimi and muse resolve their own binary and sandbox environment below, so
    # neither carries the three overridable launch axes.
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
    muse) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=__MUSECONFIG__ XDG_DATA_HOME=__MUSEDATA__ MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on __MUSEBIN__ --yolo __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
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
    pi|pi-signed) printf '%s' '__PIBIN__' ;;
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
    # Pi's TUI mode is capability-gated after resolving the concrete executable.
    pi|pi-signed) [ -z "${PI_TUI_MODE:-}" ] || printf '%s' '--tui-mode regular' ;;
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
      harness_cfg='config/secondmate-harness'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
      harness_cfg='config/crew-harness'
    fi
    # Two different failures used to share one message that named neither remedy.
    # `unknown` is not an adapter this build lacks a template for: it is the
    # resolver reporting that nothing answered - no config file, and no harness
    # detectable from the process tree. That is exactly the shape a spawn started
    # by a relay verb has, because it inherits no environment and no terminal
    # (measured 2026-08-06 seeding a secondmate on box151), and the caller is on
    # another machine and cannot read this machine's config to find out. So say
    # which flag fixes it, in both branches.
    if ! LAUNCH=$(launch_template "$HARNESS" "$KIND"); then
      if [ "$HARNESS" = unknown ]; then
        echo "error: no harness resolved for this $KIND spawn: $harness_src names none, and no harness is detectable from this process (a non-interactive launcher, such as a relay verb, never has one)" >&2
        echo "       fix: pass --harness <claude|codex|opencode|pi|grok|traex> on this spawn, or put that adapter name in this machine's $harness_cfg" >&2
        echo "       from another machine that means: bin/fm-spawn.sh --host <this host> <id> ... --harness <name>" >&2
      else
        echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection)" >&2
        echo "       fix: pass --harness <claude|codex|opencode|pi|grok|traex> on this spawn, or a raw launch command to use an unverified adapter" >&2
      fi
      exit 1
    fi
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

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
    LAUNCH=${LAUNCH//__PITUIMODE__/$PI_TUI_MODE}
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
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|traex)
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
      # Same config key as codex, and the binary's own parser is authoritative.
      # On traex 0.200.13 `-c model_reasoning_effort='"max"'` was rejected, so max
      # was omitted. As of traex 0.200.19 the parser accepts max: a bogus value is
      # now rejected with "unknown variant `bogusvalue`, expected one of `none`,
      # `minimal`, `low`, `medium`, `high`, `xhigh`, `max`", and `max` loads
      # cleanly (verified 2026-08-13, traex 0.200.19). The ceiling is now max,
      # identical to claude and pi.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
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
    LAUNCH=${LAUNCH//__MUSEBIN__/$(shell_quote "$MUSE_BIN")}
    LAUNCH=${LAUNCH//__MUSECONFIG__/$(shell_quote "$MUSE_CONFIG_HOME")}
    LAUNCH=${LAUNCH//__MUSEDATA__/$(shell_quote "$MUSE_DATA_HOME")}
    ;;
esac

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
  # A home on another machine is refused here by name rather than by symptom.
  # Without this the remote path below is entered with a path that does not
  # exist on this filesystem, and the failure reads as a broken home instead of
  # a command sent to the wrong machine.
  SM_MACHINE=$(secondmate_registry_value "$ID" machine || true)
  if [ -z "$SM_MACHINE" ] && [ -f "$STATE/$ID.meta" ]; then
    SM_MACHINE=$(grep '^host=' "$STATE/$ID.meta" | tail -1 | cut -d= -f2- || true)
  fi
  if [ -n "$SM_MACHINE" ]; then
    echo "error: secondmate $ID lives on $SM_MACHINE; launch it there with bin/fm-spawn.sh --host $SM_MACHINE $ID --secondmate" >&2
    exit 1
  fi
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
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
    CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
      echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    }
    if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
      echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    fi
    CONFIG_INHERIT_LOCK_HELD=1
    # Inheritance propagation: push the primary-authoritative live-safe local inheritance
    # surface into this secondmate home (fm-config-inherit-lib.sh).
    FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
      || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  fi
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
  status=$(git -C "$worktree" status --porcelain) || {
    echo "error: could not inspect pooled worktree '$worktree' before refreshing its base" >&2
    return 1
  }
  if [ -n "$status" ]; then
    echo "error: pooled worktree '$worktree' is not clean; refusing to discard uncommitted work while refreshing its base" >&2
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
  # Probe the endpoint on the server its own metadata records, so "is the old one
  # still alive" is never answered by a same-named window on another server.
  fm_backend_bind_meta "$old_backend" "$meta" || true
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
  local url target host rc
  url=$(git -C "$PROJ_ABS" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  # Probe the [user@]host git itself would connect to, not a bare host: dropping
  # the `git@` connects as this process's own login, a different SSH identity.
  target=$(fm_remote_ssh_target "$url") || return 0
  host=${target##*@}
  rc=0
  fm_remote_preflight_ssh "$target" || rc=$?
  case "$rc" in
    10)
      echo "error: cannot spawn task $ID: the SSH host key for '$host' (project origin $url) is not trusted, so the first 'git fetch' would stop at an interactive host-authenticity prompt inside the crew terminal and wedge the spawn with no recoverable endpoint. Refusing to create a terminal or auto-accept the key. Verify the host fingerprint out of band and add it (run 'ssh $target' once to accept it, or append a verified key to known_hosts), then re-dispatch." >&2
      exit "$FM_SPAWN_REMOTE_BLOCKED"
      ;;
    11)
      echo "error: cannot spawn task $ID: SSH authentication as '$target' (project origin $url) was refused (Permission denied), so 'git fetch' would fail. Refusing to create a terminal. Provision the SSH credential/key for '$target', then re-dispatch." >&2
      exit "$FM_SPAWN_REMOTE_BLOCKED"
      ;;
  esac
  return 0
}

# Make sure this project clone draws worktrees from THIS home's own treehouse
# pool before the pane runs `treehouse get`. treehouse keys its pool by
# ($HOME, origin URL) with no home dimension, so without this two homes holding
# the same repo share one pool and one can be handed a worktree of the other's
# clone - the exact condition spawn_worktree_isolated refuses below.
# bin/fm-project-pool.sh owns the contract; it is idempotent, so every spawn
# converges a clone that predates pool isolation or arrived by hand.
#
# Best-effort on purpose. The failure cases are a project that commits its own
# treehouse.toml and an unwritable clone; refusing there would make the project
# undispatchable to buy nothing, because failing to write the config leaves
# exactly today's behavior, and spawn_worktree_isolated still refuses a worktree
# belonging to another home's clone. So warn loudly and let the guard do its job.
spawn_pool_isolate_project() {
  local out
  # --home is passed rather than derived: the home that must not collide is the
  # one dispatching this task, and PROJ_ABS is not always under its projects/.
  if out=$("$SCRIPT_DIR/fm-project-pool.sh" apply "$PROJ_ABS" --home "$FM_HOME" 2>&1); then
    return 0
  fi
  echo "warning: could not give $PROJ_ABS this home's own treehouse worktree pool, so it still shares one pool with any other firstmate home holding this repo: ${out:-unknown error}" >&2
  return 0
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_remote_preflight_or_block
  spawn_pool_isolate_project
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
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ]; then
  freshen_spawn_worktree_base "$WT" || exit 1
fi

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
# Publish the task metadata, checking the redirect result explicitly rather than
# relying on set -e to abort on a failed compound-command redirect.
# That errexit behavior is not reliable across bash versions (a failed meta-write
# redirect is swallowed identically on bash 3.2 and bash 5.0.3), so without this
# explicit check a meta-write failure would return success and leave a live task
# firstmate never recorded and cannot supervise or tear down.
# On failure exit non-zero with the Orca abort cleanup still armed, so the EXIT
# trap releases the terminal and worktree instead of leaking them.
meta_write_rc=0
SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
SPAWN_META_PATH="$STATE/$ID.meta"
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  SPAWN_META_TMP="$STATE/.$ID.meta.relaunch.${BASHPID:-$$}"
  SPAWN_META_PATH=$SPAWN_META_TMP
fi
preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree project harness kind mode yolo tasktmp model effort busy_gen spawn_gen traceparent launch backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx", keys, " ")
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
  # launch= records the NAME of the selected launch variant, and only when one was
  # selected, so a home with no variants keeps a byte-identical meta. The name alone
  # is recorded - never the variant's command or env - so a gateway launcher's
  # credentials stay in that launcher and out of firstmate's state files.
  [ -z "$RESOLVED_LAUNCH_VARIANT" ] || echo "launch=$RESOLVED_LAUNCH_VARIANT"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  # Default-off writes no traceparent= line.
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
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
} > "$SPAWN_META_PATH" || meta_write_rc=$?
if [ "$meta_write_rc" -ne 0 ]; then
  echo "error: failed to write task metadata to $SPAWN_META_PATH" >&2
  exit 1
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_PUBLISH_STARTED=1
  mv -f "$SPAWN_META_TMP" "$STATE/$ID.meta"
  RELAUNCH_REPLACEMENT_PENDING=0
  SPAWN_META_PUBLISH_STARTED=0
  SPAWN_META_TMP=
  fm_lock_release "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=0
fi
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
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
  local backlog out repair retry proj_name
  [ "$KIND" = secondmate ] && return 0
  backlog="$DATA/backlog.md"
  # Derived here rather than read from PROJ_NAME: that variable is set on the
  # ship path only, so a SCOUT reaching this banner would abort on an unbound
  # variable instead of printing the repair command it exists to print.
  proj_name=$(basename "$PROJ_ABS")
  repair="cd $(shell_quote "$FM_HOME") && tasks-axi add $(shell_quote "$ID") $(shell_quote '<task title>') --kind $(shell_quote "$KIND") --repo $(shell_quote "$proj_name") --start --file $(shell_quote "$backlog")"
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
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
sq_worktree=$(shell_quote "$WT")
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
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
case "$HARNESS" in
  pi|pi-signed) LAUNCH=${LAUNCH//__PIBIN__/"$(shell_quote "$PI_BIN")"} ;;
  cursor) LAUNCH=${LAUNCH//__CURSORBIN__/"$(shell_quote "$CURSOR_BIN")"} ;;
esac
LAUNCH=${LAUNCH//__WORKTREE__/$sq_worktree}
case "$HARNESS" in
  claude|codex|opencode|pi|pi-signed|grok|kimi|muse|traex)
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
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" tmp status=0
  SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] \
     || ! awk -F= '$1 != "traceparent"' "$meta" > "$SPAWN_META_TMP" \
     || ! printf 'traceparent=%s\n' "$SPAWN_TRACEPARENT" >> "$SPAWN_META_TMP" \
     || ! mv -f "$SPAWN_META_TMP" "$meta"; then
    status=1
    rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  fi
  SPAWN_META_TMP=
  fm_lock_release "$SPAWN_META_LOCK" || status=1
  SPAWN_META_LOCK_HELD=0
  return "$status"
}

# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
# Send through the exact channel that already ships GOTMPDIR, so every backend
# and harness - ship, scout, and secondmate - gets it before launch. Skipped
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
sleep 0.3
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
spawn_send_key "$T" Enter
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
if [ "$KIND" = secondmate ] && [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
echo "spawned $ID harness=$HARNESS${RESOLVED_LAUNCH_VARIANT:+ launch=$RESOLVED_LAUNCH_VARIANT} kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT"
