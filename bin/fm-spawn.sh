#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> --reason-code <CODE> [--route <ROUTE>] [--capability-floor <FLOOR>] [--tooling-gap-item <backlog-id>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>]
#        fm-spawn.sh <task-id> <project-dir> --scout --reason-code <CODE> [--route <ROUTE>] [--capability-floor <FLOOR>] [--tooling-gap-item <backlog-id>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>]
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
#   --slot-base <commit-ish> and --contribution-target <commit-ish> are this
#   task's TWO base references (bin/fm-task-base-lib.sh owns the contract). Both
#   are DERIVED per spawn and these flags only override that derivation, so an
#   ordinary spawn passes neither. The slot base is the commit the task's
#   worktree is placed at, so the worker reads the code the fleet ACTUALLY RUNS
#   and the brief's file and line citations resolve; it is the project checkout's
#   local default-branch tip, and the slot is placed there rather than left at
#   whatever commit the pool last used. The contribution target is the commit the
#   task's branch is cut from, so the PR carries no commit the target never had;
#   on a fork layout that is the upstream trunk, which is NOT the slot base.
#   Derivation cannot see the task's target files, so a task editing code that
#   exists only on the fork declares its target with the flag instead. When the
#   two coincide nothing changes. When the upstream trunk exists but cannot be
#   read locally the target is recorded as "unresolved" rather than guessed onto
#   the slot base, because that guess is the pollution this separates. A ship or
#   scout spawn additionally reads the brief's recorded "Base contract:" line and
#   REFUSES a mismatch, exactly like the delivery contract above. A slot holding
#   uncommitted work, or sitting on a task branch, is left untouched and launched
#   as-is with a notice. Refused on --secondmate, which syncs its whole home.
#   --reason-code <CODE> answers "why was an agent turn necessary here" for this
#   dispatch, in the closed vocabulary owned by bin/fm-reasoning-lib.sh. REQUIRED
#   for every ship and scout spawn and refused on --secondmate, which provisions a
#   standing home rather than dispatching a task. An out-of-enum value is refused
#   rather than recorded, because a free-text reason cannot be counted. The record
#   is written, not enforced: no dispatch is blocked for reasoning too little.
#   TOOLING_GAP is the one code that is NOT a reasoning code. It names a turn taken
#   only because a deterministic reader is broken or absent, is never counted as
#   justified reasoning, and REQUIRES --tooling-gap-item <backlog-id> naming an item
#   that is currently open in this home's data/backlog.md - otherwise the code would
#   launder every unfixed tool into a permanent "necessary agent turn".
#   --capability-floor <FLOOR> records the routing floor this dispatch was resolved
#   against, verbatim from config/crew-dispatch.json; an undefined floor is refused
#   and an omitted one falls back to that file's default route floor. A home with no
#   dispatch profiles records "unconfigured" and refuses an explicit floor.
#   --route <ROUTE> names the configured route this dispatch CLAIMS, and the spawn
#   checks the claim: the model must be in that route's ordered pool and must meet
#   the route's capability floor on every axis the config declares. A violation is
#   REFUSED naming the route, the exact JSON config path, the configured value and
#   the observed one, and a MISSING input is a violation too: an unstated model, a
#   floor id _floors does not define, an axis the config records no evidence for,
#   and a model the availability record holds each refuse rather than passing
#   unchecked. Required for ship and scout spawns in a
#   home whose config/crew-dispatch.json carries routed pools, unless an explicit
#   --capability-floor already names exactly one route; refused on --secondmate.
#   A home with no routed pool - which is every home using the documented profile
#   schema, and every home with no dispatch config - is unaffected. The route and
#   a digest of the policy surface that checked it land in state/<id>.meta, and
#   the recorded capability floor becomes the route's own so the two can never
#   describe different rungs. bin/fm-route-lib.sh owns the rules; run
#   bin/fm-route.sh to read them, list a route's eligible candidates in pool
#   order, or resolve a failover substitute inside the same pool.
#   Ship and scout spawns also consult bin/fm-admission.sh before allocating
#   anything: a fleet that is not accepting another task stops the spawn and the
#   request is queued as a `load` hold rather than dropped. The two non-preferred
#   bands are distinct answers - a `queue` action is FM_SPAWN_ADMISSION_DEFERRED
#   and a `refuse` action is FM_SPAWN_ADMISSION_REFUSED - and a batch takes one
#   fleet census for every pair rather than one per pair.
#   The spawn additionally derives reasoning_required from the reason code and
#   escalation_policy from kind plus the delivery contract, so neither can be
#   declared into disagreement with the record it summarizes. All of it lands in
#   state/<id>.meta; absent fields on an older meta read as unknown, never as
#   justified reasoning.
#   Every ship or scout spawn resolves the task's durable attempt count, so
#   whether a task may be retried is arithmetic rather than a judgment: the
#   budget is checked before anything is created and the result is committed
#   when the task's metadata is published, which also carries the count as
#   attempt= and attempt_budget=. The count moves only when the prior attempt was
#   RECORDED as failed; a spawn recovering a dead runtime or husk continues the
#   attempt already open and is never refused. A spent budget refuses the spawn
#   and records the terminal state. --attempt-budget <n> sets that budget for this task id and is
#   recorded, which is the only way past an exhausted one; it is refused on
#   --secondmate, whose relaunch is liveness recovery rather than a retry.
#   bin/fm-attempt.sh owns the record, the migration rule, and the refusal.
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   A "provider/model" --model is checked against the local model registry before
#   anything is created: the spawn REFUSES when an API-key provider's model is not
#   on the verified-free allowlist, when the provider's cost posture is unclassified,
#   when the registry records the model as rejected or blocked, or when the model's
#   recorded concurrency cap is already met. This is the last
#   gate before a dispatch can spend money, and the only one that sees a --model
#   passed explicitly rather than resolved from config/crew-dispatch.json. With no
#   config/models.json present the check is inert and spawns behave as before;
#   bin/fm-model-registry-lib.sh owns the full enforcement scope.
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
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|muse)
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
#   --scout records deliverable=scout in the task's meta (report deliverable, scratch
#   worktree; see AGENTS.md task lifecycle); --secondmate records role=secondmate and
#   launches in a provisioned firstmate home; the default is a commissioned crew ship
#   task. The deprecated kind= alias is dual-written beside the axes for the
#   migration window (bin/fm-task-axis-lib.sh).
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
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
#   Launch templates live in launch_template() in bin/fm-launch-lib.sh, the single owner
#   of every firstmate launch command; that library's header owns the placeholder
#   contract this script substitutes before launch.
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# Claude task settings also wire bin/fm-context-statusline.sh to the host's
# statusLine payload and its /tmp/fm-<id>/context-pressure.json snapshot.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# muse installs no hook at all - its plugin engine is off in the default build - so
# it writes state/<id>.muse-session to bind the pane to muse's own session event
# log; muse is crewmate/scout only and is refused for --secondmate.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> [mode=<mode> yolo=<on|off>] window=<backend-target> worktree=<path>
# A ship task records the explicit mode/yolo it was passed; a secondmate spawn records
# mode=secondmate, yolo=off, home=, and projects=; a scout records neither, and both the
# success line and state/<id>.meta omit them.
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
# Every ship and scout spawn records slot_base=, contribution_target= (a commit, or the
# literal "unresolved", or "n/a" for a scout), and base_state=
# (coincident|distinct|unresolved|read-only), so which commit a task read and which it
# contributed to stays inspectable after the fact. A scout cuts no branch, so it records
# base_state=read-only and takes no --contribution-target.
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
# shellcheck source=bin/fm-launch-lib.sh
. "$SCRIPT_DIR/fm-launch-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-task-base-lib.sh
. "$SCRIPT_DIR/fm-task-base-lib.sh"
# shellcheck source=bin/fm-task-axis-lib.sh
. "$SCRIPT_DIR/fm-task-axis-lib.sh"
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-reasoning-lib.sh
. "$SCRIPT_DIR/fm-reasoning-lib.sh"
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
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
SLOT_BASE_ARG=
CONTRIB_ARG=
REASON_CODE=
CAPABILITY_FLOOR=
TOOLING_GAP_ITEM=
ROUTE=
REASON_CODE_SET=0
CAPABILITY_FLOOR_SET=0
TOOLING_GAP_ITEM_SET=0
ROUTE_SET=0
ATTEMPT_BUDGET_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
TRACEPARENT_SET=0
RELAUNCH=0
SLOT_BASE_SET=0
CONTRIB_SET=0
ATTEMPT_BUDGET_SET=0
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
      slot-base) SLOT_BASE_ARG=$a; SLOT_BASE_SET=1 ;;
      contribution-target) CONTRIB_ARG=$a; CONTRIB_SET=1 ;;
      reason-code) REASON_CODE=$a; REASON_CODE_SET=1 ;;
      capability-floor) CAPABILITY_FLOOR=$a; CAPABILITY_FLOOR_SET=1 ;;
      route) ROUTE=$a; ROUTE_SET=1 ;;
      tooling-gap-item) TOOLING_GAP_ITEM=$a; TOOLING_GAP_ITEM_SET=1 ;;
      attempt-budget) ATTEMPT_BUDGET_ARG=$a; ATTEMPT_BUDGET_SET=1 ;;
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
    --slot-base) want_value=slot-base ;;
    --slot-base=*) SLOT_BASE_ARG=${a#--slot-base=}; SLOT_BASE_SET=1 ;;
    --contribution-target) want_value=contribution-target ;;
    --contribution-target=*) CONTRIB_ARG=${a#--contribution-target=}; CONTRIB_SET=1 ;;
    --reason-code) want_value='reason-code' ;;
    --reason-code=*) REASON_CODE=${a#--reason-code=}; REASON_CODE_SET=1 ;;
    --capability-floor) want_value='capability-floor' ;;
    --capability-floor=*) CAPABILITY_FLOOR=${a#--capability-floor=}; CAPABILITY_FLOOR_SET=1 ;;
    --route) want_value='route' ;;
    --route=*) ROUTE=${a#--route=}; ROUTE_SET=1 ;;
    --tooling-gap-item) want_value='tooling-gap-item' ;;
    --tooling-gap-item=*) TOOLING_GAP_ITEM=${a#--tooling-gap-item=}; TOOLING_GAP_ITEM_SET=1 ;;
    --attempt-budget) want_value='attempt-budget' ;;
    --attempt-budget=*) ATTEMPT_BUDGET_ARG=${a#--attempt-budget=}; ATTEMPT_BUDGET_SET=1 ;;
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
[ "$REASON_CODE_SET" -eq 0 ] || [ -n "$REASON_CODE" ] || { echo "error: --reason-code requires a non-empty value" >&2; exit 1; }
[ "$CAPABILITY_FLOOR_SET" -eq 0 ] || [ -n "$CAPABILITY_FLOOR" ] || { echo "error: --capability-floor requires a non-empty value" >&2; exit 1; }
[ "$ROUTE_SET" -eq 0 ] || [ -n "$ROUTE" ] || { echo "error: --route requires a non-empty value" >&2; exit 1; }
[ "$TOOLING_GAP_ITEM_SET" -eq 0 ] || [ -n "$TOOLING_GAP_ITEM" ] || { echo "error: --tooling-gap-item requires a non-empty value" >&2; exit 1; }
# Each justification value becomes one line of state/<id>.meta, so a value that
# is not one line is refused here, before anything downstream can read a forged
# key line as authority (bin/fm-reasoning-lib.sh).
for justification_flag in "reason-code=$REASON_CODE" "capability-floor=$CAPABILITY_FLOOR" "route=$ROUTE" "tooling-gap-item=$TOOLING_GAP_ITEM"; do
  fm_justification_value_recordable "${justification_flag#*=}" || {
    echo "error: $FM_REASON_TOKEN_VALUE_MALFORMED: --${justification_flag%%=*} must be a single line without control characters; each justification field is one line of state/<id>.meta and a newline would forge further key lines in it" >&2
    exit 1
  }
done
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
[ "$SLOT_BASE_SET" -eq 0 ] || [ -n "$SLOT_BASE_ARG" ] || { echo "error: --slot-base requires a non-empty value" >&2; exit 1; }
[ "$CONTRIB_SET" -eq 0 ] || [ -n "$CONTRIB_ARG" ] || { echo "error: --contribution-target requires a non-empty value" >&2; exit 1; }
# The retry budget is a deliberate number, so a raise is stated rather than
# inferred, and bin/fm-attempt.sh records the value it was raised to.
if [ "$ATTEMPT_BUDGET_SET" -eq 1 ]; then
  case "$ATTEMPT_BUDGET_ARG" in
    ''|*[!0-9]*|0) echo "error: --attempt-budget must be a positive integer" >&2; exit 1 ;;
  esac
  [ "$KIND" != secondmate ] || {
    echo "error: --attempt-budget applies only to ship and scout spawns; a secondmate relaunch is routine liveness recovery, not a retry, and is never counted against a budget" >&2
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
      echo "error: ship spawns require --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
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

# Agent-justification record (bin/fm-reasoning-lib.sh). This spawn is the last
# gate before an agent turn exists, so it is where the record has to be made:
# why was an agent necessary here, in a vocabulary closed enough to count.
#
# Scoped to TASK dispatches. A --secondmate spawn provisions a standing home
# rather than dispatching a task - AGENTS.md section 10 keeps a secondmate out
# of the backlog for the same reason - and the enum was derived from task
# invocations, so demanding one of its codes for a provisioning action would
# manufacture exactly the rubber-stamp answer the enum exists to prevent. Its
# meta carries none of these fields, and an absent field reads as unknown.
if [ "$KIND" = secondmate ]; then
  [ "$REASON_CODE_SET" -eq 0 ] || {
    echo "error: $FM_REASON_TOKEN_REFUSED: --reason-code applies to ship and scout dispatches; a --secondmate spawn provisions a standing home rather than dispatching a task" >&2
    exit 1
  }
  [ "$CAPABILITY_FLOOR_SET" -eq 0 ] || {
    echo "error: $FM_REASON_TOKEN_REFUSED: --capability-floor applies to ship and scout dispatches; a --secondmate spawn matches no dispatch rule" >&2
    exit 1
  }
  [ "$ROUTE_SET" -eq 0 ] || {
    echo "error: $FM_REASON_TOKEN_REFUSED: --route applies to ship and scout dispatches; a --secondmate spawn provisions a standing home and claims no route" >&2
    exit 1
  }
  [ "$TOOLING_GAP_ITEM_SET" -eq 0 ] || {
    echo "error: $FM_REASON_TOKEN_GAP_ITEM_REFUSED: --tooling-gap-item applies only to a --reason-code $FM_REASON_CODE_TOOLING_GAP dispatch" >&2
    exit 1
  }
else
  [ "$REASON_CODE_SET" -eq 1 ] || {
    echo "error: $FM_REASON_TOKEN_REQUIRED: every dispatch records why an agent turn was necessary; pass --reason-code <$(fm_reason_codes_oneline)>. Use $FM_REASON_CODE_TOOLING_GAP when the turn is only needed because a deterministic reader is broken or absent - it is not a reasoning code and files repair work instead." >&2
    exit 1
  }
  fm_reason_code_known "$REASON_CODE" || {
    echo "error: $FM_REASON_TOKEN_UNKNOWN: '$REASON_CODE' is not a reason code; the vocabulary is closed because free-text reasons cannot be counted. One of: $(fm_reason_codes_oneline)" >&2
    exit 1
  }

  # TOOLING_GAP's certification. A broken reader is not legitimate reasoning
  # demand, so the turn it forced is only recordable alongside OPEN repair work
  # for the reader itself. Without this the code launders every unfixed tool
  # into a permanent, uncounted category of "necessary" agent turns.
  if [ "$REASON_CODE" = "$FM_REASON_CODE_TOOLING_GAP" ]; then
    [ "$TOOLING_GAP_ITEM_SET" -eq 1 ] || {
      echo "error: $FM_REASON_TOKEN_GAP_ITEM_REQUIRED: --reason-code $FM_REASON_CODE_TOOLING_GAP requires --tooling-gap-item <backlog-id> naming the OPEN work item that repairs the broken reader; file the repair first, then dispatch" >&2
      exit 1
    }
    fm_backlog_item_open "$DATA" "$TOOLING_GAP_ITEM" || {
      echo "error: $FM_REASON_TOKEN_GAP_ITEM_UNFILED: no open work item '$TOOLING_GAP_ITEM' in $DATA/backlog.md; a $FM_REASON_CODE_TOOLING_GAP dispatch is only recordable once the reader's repair is actually filed and still open" >&2
      exit 1
    }
  else
    [ "$TOOLING_GAP_ITEM_SET" -eq 0 ] || {
      echo "error: $FM_REASON_TOKEN_GAP_ITEM_REFUSED: --tooling-gap-item applies only to a --reason-code $FM_REASON_CODE_TOOLING_GAP dispatch (got --reason-code $REASON_CODE)" >&2
      exit 1
    }
  fi

  # The floor is recorded verbatim from this home's own dispatch profiles, so
  # the record cannot claim a capability band the routing config never defines.
  if FLOOR_VOCAB=$(fm_capability_floor_vocabulary "$CONFIG"); then
    if [ "$CAPABILITY_FLOOR_SET" -eq 0 ]; then
      CAPABILITY_FLOOR=$(fm_capability_floor_default "$CONFIG" || true)
      [ -n "$CAPABILITY_FLOOR" ] || CAPABILITY_FLOOR=$FM_CAPABILITY_FLOOR_UNCONFIGURED
    fi
    if [ "$CAPABILITY_FLOOR" != "$FM_CAPABILITY_FLOOR_UNCONFIGURED" ] \
      && ! printf '%s\n' "$FLOOR_VOCAB" | grep -qxF -- "$CAPABILITY_FLOOR"; then
      echo "error: $FM_REASON_TOKEN_FLOOR_UNKNOWN: '$CAPABILITY_FLOOR' is not a floor defined by $CONFIG/crew-dispatch.json. Defined: $(printf '%s\n' "$FLOOR_VOCAB" | tr '\n' ' ' | sed 's/ $//')" >&2
      exit 1
    fi
  else
    case $? in
      2)
        echo "error: $FM_REASON_TOKEN_FLOOR_UNVERIFIABLE: $CONFIG/crew-dispatch.json exists but its floors cannot be read (missing jq or malformed JSON), so a recorded floor cannot be checked against its source" >&2
        exit 1
        ;;
      *)
        # No dispatch config in this home: there is no floor vocabulary to
        # match, so an explicit floor is refused rather than recorded unchecked.
        [ "$CAPABILITY_FLOOR_SET" -eq 0 ] || {
          echo "error: $FM_REASON_TOKEN_FLOOR_UNKNOWN: --capability-floor needs $CONFIG/crew-dispatch.json to define the floor vocabulary; this home configures no dispatch profiles" >&2
          exit 1
        }
        CAPABILITY_FLOOR=$FM_CAPABILITY_FLOOR_UNCONFIGURED
        ;;
    esac
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
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
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
      || [ "$(fm_task_role "$meta")" != secondmate ] \
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
    fm_task_axes_emit secondmate
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
# A secondmate is a firstmate home, not a task worktree: it already runs the
# primary's local-HEAD sync below and cuts no contribution branch at all.
if [ "$KIND" = secondmate ]; then
  [ "$SLOT_BASE_SET" -eq 0 ] && [ "$CONTRIB_SET" -eq 0 ] || {
    echo "error: --slot-base and --contribution-target apply only to ship and scout spawns; a secondmate home syncs to the primary default branch and cuts no contribution branch" >&2
    exit 1
  }
fi
if [ "$KIND" = scout ] && [ "$CONTRIB_SET" -eq 1 ]; then
  echo "error: --contribution-target applies only to ship spawns; a scout delivers a report and cuts no branch, so it has only a slot base to read and cite" >&2
  exit 1
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
SLOT_HOLDER_PID=
WT_POOL_LOCK=
WT_POOL_LOCK_HELD=0

# Stop occupying the chosen pool slot. Called as soon as the pane's own shell is
# inside it, and again from the abort path so an aborted spawn never leaves the
# slot looking in-use to the rest of the fleet.
release_slot_holder() {
  [ -n "$SLOT_HOLDER_PID" ] || return 0
  kill "$SLOT_HOLDER_PID" 2>/dev/null || true
  wait "$SLOT_HOLDER_PID" 2>/dev/null || true
  SLOT_HOLDER_PID=
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
  release_slot_holder
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
            fm_task_axes_emit "$KIND"
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
  if [ "$WT_POOL_LOCK_HELD" = 1 ]; then
    WT_POOL_LOCK_HELD=0
    fm_lock_release "$WT_POOL_LOCK" || true
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
  if [ -n "${BATCH_ADMISSION_SNAPSHOT:-}" ]; then
    rm -f "$BATCH_ADMISSION_SNAPSHOT"
    BATCH_ADMISSION_SNAPSHOT=
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

# One machine-private exclusive lock per physical pool, keyed by the resolved
# project path. Unlike `treehouse get`, the select-then-enter allocation claims
# nothing until the holder process occupies the chosen slot, so two spawns
# selecting concurrently would both pick the same first-clean slot. The
# contenders are every home spawning into the pool, so the lock can never live
# under $STATE, which is per-home; it uses the same machine-private /tmp
# namespace shape as the herdr presentation lock (bin/backends/herdr.sh), with
# the same ownership and mode validation before use.
spawn_pool_select_lock_namespace_mode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

spawn_pool_select_lock_namespace_uid() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

spawn_pool_select_lock_namespace_valid() {
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(spawn_pool_select_lock_namespace_uid "$dir") || return 1
  mode=$(spawn_pool_select_lock_namespace_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

spawn_pool_select_lock_path() {  # <pool-real>
  local pool=$1 hash key dir
  [ -n "$pool" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$pool" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$pool" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$hash" ] || return 1
  key=${hash:0:32}
  dir=/tmp/firstmate-worktree-pool
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null; then
      spawn_pool_select_lock_namespace_valid "$dir" || return 1
    fi
  fi
  spawn_pool_select_lock_namespace_valid "$dir" || return 1
  printf '%s/select-%s.lock' "$dir" "$key"
}

# A lock that cannot be acquired refuses the spawn: proceeding unlocked would
# reopen the very race the lock closes. The wait is bounded well above the
# window one holder spans (selection through the pane settling into the slot).
spawn_pool_select_lock_acquire() {  # <pool-real>
  local pool=$1 attempt max
  if ! WT_POOL_LOCK=$(spawn_pool_select_lock_path "$pool"); then
    echo "error: cannot resolve the pool selection lock for $pool: /tmp/firstmate-worktree-pool is not this user's mode-700 directory and could not be created; refusing to choose a slot unserialized" >&2
    return 1
  fi
  attempt=0
  max=${FM_SPAWN_POOL_LOCK_POLLS:-1200}
  while [ "$attempt" -lt "$max" ]; do
    if fm_lock_try_acquire "$WT_POOL_LOCK"; then
      WT_POOL_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: another spawn is choosing a slot in this pool (lock $WT_POOL_LOCK held by pid ${FM_LOCK_HELD_PID:-unknown}); refusing to choose a slot unserialized" >&2
  return 1
}

spawn_pool_select_lock_release() {
  [ "$WT_POOL_LOCK_HELD" = 1 ] || return 0
  WT_POOL_LOCK_HELD=0
  fm_lock_release "$WT_POOL_LOCK" || true
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
  [ "$SLOT_BASE_SET" -eq 0 ] || shared_args+=(--slot-base "$SLOT_BASE_ARG")
  if [ "$KIND" = ship ] && [ "$CONTRIB_SET" -eq 1 ]; then
    shared_args+=(--contribution-target "$CONTRIB_ARG")
  fi
  [ "$REASON_CODE_SET" -eq 0 ] || shared_args+=(--reason-code "$REASON_CODE")
  [ "$CAPABILITY_FLOOR_SET" -eq 0 ] || shared_args+=(--capability-floor "$CAPABILITY_FLOOR")
  # A batch carries one concrete profile, so it claims one route: the same
  # model and effort cannot be inside two different routes' floors at once.
  [ "$ROUTE_SET" -eq 0 ] || shared_args+=(--route "$ROUTE")
  [ "$TOOLING_GAP_ITEM_SET" -eq 0 ] || shared_args+=(--tooling-gap-item "$TOOLING_GAP_ITEM")
  [ "$ATTEMPT_BUDGET_SET" -eq 0 ] || shared_args+=(--attempt-budget "$ATTEMPT_BUDGET_ARG")
  # ADMIT is a property of the FLEET, never of the pair, so one census answers it
  # for the whole batch. Without this each pair re-runs a full fm-fleet-snapshot
  # census serially, which is N censuses to answer one fleet-wide question. The
  # snapshot carries its own generation time and fm-admission.sh still ages it
  # against the configured freshness limit, so the census-integrity signal is
  # bounded exactly as before: a batch slow enough to stale the census is refused
  # exactly as a stale one always was.
  #
  # What a shared census CANNOT bound is saturation. `active_workers.count` and
  # `admission_queue_pressure.load_hold_depth` are measured once, before the
  # loop, so pair N is weighed against a fleet that does not yet contain pairs
  # 1..N-1. Today that cannot move the band: both ship `enforce: false` and
  # `enforcement_mode: "safety-only"` makes numeric enforcement unreachable. When
  # an evidence-gated mode makes either enforce, this sharing has to be revisited
  # - a per-pair census, or an in-loop headcount, is what that mode would need.
  BATCH_ADMISSION_SNAPSHOT=
  # shellcheck source=bin/fm-admission-lib.sh
  . "$SCRIPT_DIR/fm-admission-lib.sh"
  if [ "$(fm_admission_state "$(fm_admission_config_file "$CONFIG")")" = active ] \
    && [ -x "$FM_ROOT/bin/fm-fleet-snapshot.sh" ]; then
    BATCH_ADMISSION_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-spawn-admission-snapshot.XXXXXX") \
      || BATCH_ADMISSION_SNAPSHOT=
    if [ -n "$BATCH_ADMISSION_SNAPSHOT" ]; then
      chmod 600 "$BATCH_ADMISSION_SNAPSHOT" 2>/dev/null || true
      if ! "$FM_ROOT/bin/fm-fleet-snapshot.sh" --json > "$BATCH_ADMISSION_SNAPSHOT" 2>/dev/null; then
        # A census that could not be taken is not a shared census. Drop it and
        # let each pair ask for its own, so a batch never admits on a snapshot
        # the fleet snapshot owner refused to produce.
        rm -f "$BATCH_ADMISSION_SNAPSHOT"
        BATCH_ADMISSION_SNAPSHOT=
      fi
    fi
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
      if FM_SPAWN_NO_GUARD=1 FM_SPAWN_ADMISSION_SNAPSHOT="$BATCH_ADMISSION_SNAPSHOT" "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 FM_SPAWN_ADMISSION_SNAPSHOT="$BATCH_ADMISSION_SNAPSHOT" "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  if [ -n "$BATCH_ADMISSION_SNAPSHOT" ]; then
    rm -f "$BATCH_ADMISSION_SNAPSHOT"
    BATCH_ADMISSION_SNAPSHOT=
  fi
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_CONTROL_LOCK="$STATE/.control-$ID.lock"
  control_owner=$(cat "$SPAWN_CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
    SPAWN_CONTROL_PARENT=1
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

# The retry budget, before anything is created. Whether this task id may be
# attempted again is arithmetic over its durable count, which bin/fm-attempt.sh
# owns; a spent budget refuses here so a refused retry allocates no worktree and
# no endpoint, and records the named terminal state rather than stopping
# quietly. Only a spawn following a RECORDED FAILURE can be refused - one
# recovering a dead runtime continues the attempt already open. The result is
# committed later, at metadata publication, so a spawn that never reached a
# launch does not spend an attempt.
# Secondmates are exempt: their relaunch is routine liveness recovery, not a
# retry (fm-attempt.sh's header owns that reasoning).
ATTEMPT_FLAGS=()
[ "$ATTEMPT_BUDGET_SET" -eq 0 ] || ATTEMPT_FLAGS=(--budget "$ATTEMPT_BUDGET_ARG")
if [ "$KIND" != secondmate ]; then
  "$FM_ROOT/bin/fm-attempt.sh" check "$ID" "${ATTEMPT_FLAGS[@]+"${ATTEMPT_FLAGS[@]}"}" >/dev/null || exit 1
fi

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
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi|muse)
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

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    # The verified pi/pi-signed templates carry the FM_PI_HARNESS identity
    # marker inside launch_template (bin/fm-launch-lib.sh). A raw command
    # bypasses the library, so re-apply the marker here: even a raw Pi-family
    # launch must declare its identity, or a signed primary's environment
    # could relabel a plain Pi worker (docs/configuration.md).
    case "$HARNESS" in
      pi|pi-signed) LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH" ;;
    esac
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

# ADMIT. bin/fm-admission.sh is read-only by contract and returns the fleet band
# as its exit status; this is the caller that applies the outcome. A home with no
# admission policy exits 0 and nothing here changes.
#
# The two non-preferred bands are NOT the same answer and must not read as one.
# The decision record's own `action` splits them: `queue` is a DEFERRAL - the
# work is held and reconsidered - and `refuse` is a refusal. Each carries its own
# stable token and its own prose, because a caller matching tokens cannot act on
# a deferral it cannot tell from a refusal. Both place the hold the record's own
# `hold_kind` names, which is the whole queue substrate -
# .agents/skills/fleet-admission/SKILL.md owns that procedure and admission never
# opens a second queue - and both name the controlling condition, because a band
# without the condition that must clear is something nobody can act on. What the
# hold PROMISES comes from the band's own `auto_reconsider`: a band that records
# no automatic reconsideration gets a hold that waits for an explicit release,
# because promising a retake that will not happen is how a queued request is
# quietly lost. A hold that cannot be placed softens neither answer: the spawn
# stops either way and the failure is said out loud, so a request can never be
# silently dropped instead of queued.
#
# A batch parent may take one fleet census for the whole batch and hand it down
# through FM_SPAWN_ADMISSION_SNAPSHOT; admission still ages that snapshot against
# its own configured freshness limit, so sharing it cannot smuggle a stale census
# past the census-integrity signal.
spawn_admission_gate() {
  local record band action hold_kind auto_reconsider rc reason controlling token headline
  [ -x "$FM_ROOT/bin/fm-admission.sh" ] || return 0
  if [ -n "${FM_SPAWN_ADMISSION_SNAPSHOT:-}" ] && [ -f "${FM_SPAWN_ADMISSION_SNAPSHOT:-}" ]; then
    record=$("$FM_ROOT/bin/fm-admission.sh" --json --snapshot "$FM_SPAWN_ADMISSION_SNAPSHOT" 2>/dev/null)
  else
    record=$("$FM_ROOT/bin/fm-admission.sh" --json 2>/dev/null)
  fi
  rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ -z "$record" ] || ! band=$(printf '%s' "$record" | jq -r '.decision_band // empty' 2>/dev/null) \
    || [ -z "$band" ]; then
    echo "error: FM_SPAWN_ADMISSION_UNREADABLE: fleet admission returned no readable decision, so whether the fleet can accept this task could not be observed; that is not an admission" >&2
    return 1
  fi
  # controlling_rules names the deciding rule ids; the full observation, its
  # exact config path and the configured value it was measured against live in
  # the rules array. Both halves are quoted, because a band without the
  # condition that produced it is not something a reader can act on.
  controlling=$(printf '%s' "$record" | jq -r '
    (.controlling_rules // []) as $c
    | [ (.rules // [])[] | select(.rule_id as $r | $c | index($r))
        | .rule_id + " observed " + (.observed | tostring)
          + " against " + (.config_path // "an unrecorded config path")
          + " configured " + (.configured_value | tostring) ]
    | if length > 0 then join("; ") else ($c | join("; ")) end' 2>/dev/null)
  reason="Fleet admission $band: ${controlling:-no controlling rule recorded}; config $(printf '%s' "$record" | jq -r '.config_digest // "unknown"')"
  reason=$(printf '%s' "$reason" | tr -d '()' | tr '\n' ' ')
  action=$(printf '%s' "$record" | jq -r '.action // empty' 2>/dev/null)
  hold_kind=$(printf '%s' "$record" | jq -r '.hold_kind // empty' 2>/dev/null)
  [ -n "$hold_kind" ] || hold_kind=load
  auto_reconsider=$(printf '%s' "$record" | jq -r '.auto_reconsider // empty' 2>/dev/null)
  case "$action" in
    queue)
      token=FM_SPAWN_ADMISSION_DEFERRED
      headline="the fleet is not accepting another task right now, so this dispatch is deferred and queued for reconsideration rather than started"
      ;;
    *)
      token=FM_SPAWN_ADMISSION_REFUSED
      headline="the fleet is not accepting another task right now, so this dispatch is refused"
      ;;
  esac
  echo "error: $token: $headline - $reason" >&2
  if fm_tasks_axi_backend_available "$CONFIG" \
    && tasks-axi hold "$ID" --file "$DATA/backlog.md" --kind "$hold_kind" --reason "$reason" >/dev/null 2>&1; then
    if [ "$auto_reconsider" = true ]; then
      echo "queued $ID for reconsideration at the next successful cleanup or session start" >&2
    else
      echo "queued $ID as a $hold_kind hold; this band records no automatic reconsideration, so the hold waits for an explicit release" >&2
    fi
  else
    echo "warning: could not queue $ID; record the hold by hand so this request is not lost" >&2
  fi
  return 1
}

# The registry verdict for every candidate in a route decision, as the
# "<model><TAB><refusal>" lines bin/fm-route-lib.sh merges. Cost, reachability
# and concurrency stay with bin/fm-model-registry-lib.sh and are asked here,
# where they are already sourced; the routing library records the answer and
# never asks for itself.
spawn_route_registry_verdicts() {  # <decision-json>
  local model out
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    out=
    if out=$(fm_model_zero_budget_decision "$model") \
      && out=$(fm_model_routable_decision "$model") \
      && out=$(fm_model_concurrency_decision "$model"); then
      out=
    fi
    printf '%s\t%s\n' "$model" "$(printf '%s' "$out" | tr '\n\t' '  ')"
  done <<EOF
$(printf '%s' "$1" | jq -r '.candidates[]?.model' 2>/dev/null)
EOF
}

# ROUTE, ADMIT, ELIGIBLE - the routing policy's own intake order
# (`_interfaces.order_at_intake`), enforced at the one point where HARNESS,
# MODEL and EFFORT are all final and nothing has been created yet. A refusal
# anywhere below leaves no worktree, no endpoint and no metadata behind.
#
# ROUTE. A ship or scout dispatch names the route it claims, and this checks the
# claim against the configured route: the model is in that route's ordered pool,
# and it meets the route's capability floor. bin/fm-route-lib.sh owns the rules
# and every refusal names the route, the exact config path, the configured value
# and the observed one. Enforcement turns on only for a home whose
# config/crew-dispatch.json actually carries routed pools; the documented
# profile schema has none, so every other home is unaffected and a home with no
# dispatch config at all keeps the judgment-guided behavior it has today.
#
# The claim is the DISPATCH's, not this script's: nothing here matches a rule to
# a task, because natural-language rule matching is firstmate's judgment and a
# routed model has been measured mis-tiering the work it was asked to classify.
# A dispatch that supplies an explicit --capability-floor naming exactly one
# route needs no second flag; anything else states --route outright.
if [ "$KIND" != secondmate ]; then
  ROUTE_ENFORCING=0
  fm_route_pools_configured "$CONFIG" && ROUTE_CFG_RC=0 || ROUTE_CFG_RC=$?
  case "$ROUTE_CFG_RC" in
    0) ROUTE_ENFORCING=1 ;;
    2)
      echo "error: $FM_ROUTE_TOKEN_UNREADABLE: $CONFIG/crew-dispatch.json exists but cannot be read (missing jq or malformed JSON), so a dispatch cannot be checked against the routes it configures" >&2
      exit 1
      ;;
    *)
      # No routed pool to check against, so a route claim would be recorded
      # unverified. A record nothing checked is worse than no record.
      [ "$ROUTE_SET" -eq 0 ] || {
        echo "error: $FM_ROUTE_TOKEN_UNKNOWN: --route needs $CONFIG/crew-dispatch.json to configure a route with an ordered pool; this home configures none, so the claim could only be recorded unchecked" >&2
        exit 1
      }
      ;;
  esac
  if [ "$ROUTE_ENFORCING" -eq 1 ]; then
    if [ "$ROUTE_SET" -eq 0 ] && [ "$CAPABILITY_FLOOR_SET" -eq 1 ]; then
      ROUTE=$(fm_route_for_floor "$CONFIG" "$CAPABILITY_FLOOR" || true)
      [ -z "$ROUTE" ] || ROUTE_SET=1
    fi
    if [ "$ROUTE_SET" -eq 0 ]; then
      echo "error: $FM_ROUTE_TOKEN_REQUIRED: $CONFIG/crew-dispatch.json configures routed pools, so this dispatch must name the route it claims: pass --route <$(fm_route_ids "$CONFIG" | tr '\n' '|' | sed 's/|$//')>, or a --capability-floor that names exactly one of them." >&2
      exit 1
    fi
    # ONE evaluation answers both questions below. Evaluating twice would open a
    # window where the check and the recorded floor observe different config or
    # different availability state, and a record that disagrees with the check
    # that produced it is exactly what this enforcement exists to prevent.
    if ! ROUTE_DECISION=$(fm_route_decision "$CONFIG" "$ROUTE" "$MODEL" "$EFFORT" "$STATE"); then
      echo "error: $(fm_route_unreadable_refusal "$CONFIG")" >&2
      exit 1
    fi
    # Only the held-model refusal names substitutes, so the registry verdicts a
    # substitute list has to carry are computed only when one is about to be
    # printed. The happy path stays a single route evaluation with no registry
    # probe per candidate.
    if [ -n "$(printf '%s' "$ROUTE_DECISION" | jq -r '.subject.held // empty' 2>/dev/null)" ]; then
      ROUTE_DECISION=$(fm_route_decision_with_registry "$ROUTE_DECISION" \
        "$(spawn_route_registry_verdicts "$ROUTE_DECISION")")
    fi
    if ! ROUTE_REFUSAL=$(fm_route_refusal_from_decision "$CONFIG" "$ROUTE" "$MODEL" "$ROUTE_DECISION" "$STATE"); then
      echo "error: $ROUTE_REFUSAL" >&2
      exit 1
    fi
    # The floor is the route's own, so the recorded capability band and the
    # enforced route can never describe two different rungs of the ladder. The
    # check above already refused a floor id `_floors` does not define, so a
    # floor recorded here is always one that was measured against a definition.
    ROUTE_FLOOR=$(printf '%s' "$ROUTE_DECISION" | jq -r '.floor // empty' 2>/dev/null || true)
    if [ -n "$ROUTE_FLOOR" ]; then
      if [ "$CAPABILITY_FLOOR_SET" -eq 1 ] && [ "$CAPABILITY_FLOOR" != "$ROUTE_FLOOR" ]; then
        echo "error: $FM_ROUTE_TOKEN_FLOOR_MISMATCH: route $ROUTE resolves against floor $ROUTE_FLOOR, but this dispatch recorded --capability-floor $CAPABILITY_FLOOR; a record that disagrees with the route it was checked against is worse than no record" >&2
        exit 1
      fi
      CAPABILITY_FLOOR=$ROUTE_FLOOR
    fi
    ROUTE_POLICY_DIGEST=$(fm_route_policy_digest "$CONFIG")
  fi

  # ADMIT. Asked after the route and before anything is allocated, because it is
  # a property of the FLEET and not of this task. bin/fm-admission.sh is
  # read-only by contract and returns the band as its exit status; applying the
  # outcome is this caller's job. A home with no admission policy exits 0 and
  # nothing changes.
  spawn_admission_gate || exit 1
fi

# The shared census a batch parent hands down is THIS process's input and nothing
# else's. Dropped from the environment the moment the gate above has consumed it,
# so no child - the backend that opens the pane, a hook, the worker itself - can
# inherit a census taken before it existed and admit against it. Dropping it here
# rather than clearing it on the launch line covers every one of those channels
# at once and leaves the literal launch command tests pin unchanged.
unset FM_SPAWN_ADMISSION_SNAPSHOT

# ZERO-BUDGET AND QUOTA GATE. This is the first point where HARNESS and MODEL are
# both final (the harness resolves above; config/secondmate-harness can still
# overwrite MODEL just above this line) and the last point before any mutation -
# the worktree, the backend endpoint and the task metadata are all created below.
# A refusal here therefore leaves nothing behind to clean up.
#
# It is also the ONLY gate that sees a dispatch where firstmate passed --model
# explicitly, bypassing config/crew-dispatch.json entirely; bootstrap validation
# structurally cannot see that path. See bin/fm-model-registry-lib.sh for the
# enforcement scope, and note that an absent config/models.json leaves this inert.
if ! ZB_REFUSAL=$(fm_model_zero_budget_decision "$MODEL"); then
  echo "error: $ZB_REFUSAL" >&2
  exit 1
fi
# Separate axis from cost: a model can be free of any charge and still be one the
# account cannot use. Only the registry's recorded status catches that here.
if ! ROUTE_REFUSAL=$(fm_model_routable_decision "$MODEL"); then
  echo "error: $ROUTE_REFUSAL" >&2
  exit 1
fi
if ! CONC_REFUSAL=$(fm_model_concurrency_decision "$MODEL"); then
  echo "error: $CONC_REFUSAL" >&2
  exit 1
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

# The task's TWO base references (bin/fm-task-base-lib.sh owns the contract).
# Resolved from the PROJECT checkout, before any endpoint exists, so a spawn that
# cannot tell them apart stops here rather than handing a worker a brief whose
# file and line citations do not resolve against the code the fleet runs.
SLOT_BASE=
CONTRIB_TARGET=
BASE_STATE=
if [ "$KIND" != secondmate ]; then
  if task_base_resolve "$PROJ_ABS"; then
    SLOT_BASE=$TASK_BASE_SLOT
    CONTRIB_TARGET=$TASK_BASE_CONTRIB
    BASE_STATE=$TASK_BASE_STATE
  else
    echo "warning: $ID base references unresolved for $PROJ_ABS ($TASK_BASE_ERROR); the worktree is left at whatever commit the pool last used" >&2
    BASE_STATE=unresolved
  fi
  if [ "$KIND" = ship ] && [ "$MODE" = local-only ] && [ "$CONTRIB_SET" -eq 0 ] && [ -n "$SLOT_BASE" ]; then
    CONTRIB_TARGET=$SLOT_BASE
    BASE_STATE=coincident
  fi
  # An explicit override is firstmate's per-task answer and wins over derivation.
  # The derivation cannot see the task's target files; firstmate can, so a task
  # editing code that exists only on the fork is declared here rather than guessed.
  if [ "$SLOT_BASE_SET" -eq 1 ]; then
    SLOT_BASE=$(git -C "$PROJ_ABS" rev-parse --verify --quiet "$SLOT_BASE_ARG^{commit}" 2>/dev/null) || {
      echo "error: --slot-base '$SLOT_BASE_ARG' is not a commit in $PROJ_ABS" >&2
      exit 1
    }
  fi
  if [ "$CONTRIB_SET" -eq 1 ]; then
    CONTRIB_TARGET=$(git -C "$PROJ_ABS" rev-parse --verify --quiet "$CONTRIB_ARG^{commit}" 2>/dev/null) || {
      echo "error: --contribution-target '$CONTRIB_ARG' is not a commit in $PROJ_ABS" >&2
      exit 1
    }
  fi
  if [ "$SLOT_BASE_SET" -eq 1 ] || [ "$CONTRIB_SET" -eq 1 ]; then
    if [ -z "$CONTRIB_TARGET" ]; then
      BASE_STATE=unresolved
    elif [ "$SLOT_BASE" = "$CONTRIB_TARGET" ]; then
      BASE_STATE=coincident
    else
      BASE_STATE=distinct
    fi
  fi
  # A scout delivers a report and cuts no branch, so it has no contribution
  # target to be right or wrong about - only the commit its findings cite. Its
  # slot is still placed at the fleet trunk, which is the whole fix for a report
  # whose file and line citations must resolve against the running code.
  if [ "$KIND" = scout ] && [ -n "$SLOT_BASE" ]; then
    CONTRIB_TARGET=n/a
    BASE_STATE=read-only
  fi
fi

# Brief/spawn base agreement, the same drift guard the delivery contract uses
# above. fm-brief.sh records the pair it told the worker about; a spawn that
# resolved a different pair would hand that worker citations against one commit
# and a branch cut from another.
if [ "$KIND" != secondmate ]; then
  BRIEF_BASE=$(sed -n 's/^Base contract: slot=\([0-9a-f]*\) contribution=\([^ ]*\).*$/\1 \2/p' "$BRIEF" | head -n 1)
  if [ -z "$BRIEF_BASE" ]; then
    if [ "$KIND" = ship ] && [ "$BASE_STATE" != coincident ]; then
      echo "error: $ID brief records no base contract line but this task's read and contribution bases differ (${SLOT_BASE:0:12} vs ${CONTRIB_TARGET:-unresolved}); re-scaffold the brief with --slot-base/--contribution-target before spawning" >&2
      exit 1
    elif [ "$KIND" = scout ]; then
      echo "warning: $BRIEF records no base contract line; the scout will read and cite the resolved slot base ${SLOT_BASE:-unresolved}" >&2
    fi
  else
    BRIEF_SLOT=${BRIEF_BASE%% *}
    BRIEF_CONTRIB=${BRIEF_BASE##* }
    if [ "$BRIEF_SLOT" != "$SLOT_BASE" ] || [ "$BRIEF_CONTRIB" != "${CONTRIB_TARGET:-unresolved}" ]; then
      echo "error: base mismatch for $ID: the brief says slot=$BRIEF_SLOT contribution=$BRIEF_CONTRIB but this spawn resolved slot=$SLOT_BASE contribution=${CONTRIB_TARGET:-unresolved}; re-scaffold the brief or pass matching --slot-base/--contribution-target so the worker's instructions and the task record agree" >&2
      exit 1
    fi
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

# Pool allocation, BEFORE any endpoint exists. `treehouse get` resets a slot as
# part of acquiring it, so the only place this can be decided is ahead of the
# allocation - by the time the pane's cwd reveals the worktree, an unlanded
# branch has already been detached. Running it here (rather than beside the
# acquire below) also means a refusal never leaves an orphan window behind.
# Secondmate spawns own their home, and Orca owns its own worktree, so neither
# goes through the treehouse pool.
#
# The guard both refuses and CHOOSES: `treehouse get` takes no slot argument and
# hands out the first available slot, so one parked slot would otherwise
# blockade a pool whose later slots are empty. A named slot is entered by name
# below; empty output means the pool offered nothing to steer to and the
# allocation falls back to `treehouse get`.
#
# The whole select-to-enter window runs under the cross-home pool lock:
# `select` claims nothing by itself, so a second spawn selecting concurrently
# would deterministically choose the same slot. The lock is released once the
# pane has settled into the slot, alongside the holder, or by the abort path;
# when nothing was selected it is released right here, because the `treehouse
# get` fallback claims its slot atomically.
WT_SLOT_NAME=
WT_SLOT_REAL=
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_pool_select_lock_acquire "$PROJ_ABS_REAL" || exit 1
  wt_selection=$("$FM_ROOT/bin/fm-worktree-guard.sh" select "$PROJ_ABS_REAL") || exit 1
  if [ -n "$wt_selection" ]; then
    WT_SLOT_NAME=${wt_selection%%$'\t'*}
    WT_SLOT_REAL=$(real_path_or_raw "${wt_selection#*$'\t'}")
    # Hold the chosen slot from the moment it is chosen until the pane's own
    # shell is inside it. treehouse reports a slot in-use, and `get` skips it,
    # while ANY process's cwd is inside it (docs/verification/worktree-allocation.md),
    # so this occupies the slot across the window in which another home's
    # `treehouse get` could otherwise still take it. The abort path releases it
    # too, so a spawn that never got started leaves nothing occupied.
    ( cd "$WT_SLOT_REAL" 2>/dev/null && exec sleep 300 ) >/dev/null 2>&1 &
    SLOT_HOLDER_PID=$!
  else
    spawn_pool_select_lock_release
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
  if [ -n "$WT_SLOT_NAME" ]; then
    # `enter` is deliberate: unlike `get` it acquires the slot chosen above
    # without resetting it, so the slot base placement further below stays the
    # only thing that moves this worktree's HEAD.
    spawn_send_text_line "$WT_TARGET" "treehouse enter $(shell_quote "$WT_SLOT_NAME")"
  else
    spawn_send_text_line "$WT_TARGET" 'treehouse get'
  fi

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # Compare against PROJ_ABS_REAL (physical), not PROJ_ABS: a symlinked project
  # prefix would otherwise make the pane's OS-level cwd read differ from
  # PROJ_ABS on the very first poll, before the pane has actually moved.
  #
  # A single read that already differs from PROJ_ABS_REAL is not proof the pane
  # settled there: on some tmux/WSL setups a brand-new window's pane_current_path
  # transiently reports an unrelated stale path (seen live as another real git
  # checkout entirely) before the shell catches up with treehouse get's cd. That
  # stale path still passes the PROJ_ABS_REAL comparison and validate_spawn_worktree
  # below (it resolves to a real, distinct worktree top-level too), so accepting it
  # on one read alone silently records the wrong worktree= in state/<id>.meta. Require
  # two consecutive reads to agree on the same non-project path before accepting it;
  # a mismatch just becomes the new candidate rather than resetting the wait, so a
  # pane that is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  #
  # When a slot was chosen by name, the pane must arrive at THAT slot: any other
  # path means the pane went somewhere this spawn never inspected, which is
  # exactly what must never be recorded as the worktree.
  candidate=""
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ]; then
      p_real=$(real_path_or_raw "$p")
      if [ "$p_real" != "$PROJ_ABS_REAL" ] \
         && { [ -z "$WT_SLOT_REAL" ] || [ "$p_real" = "$WT_SLOT_REAL" ]; }; then
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
    sleep 1
  done
  release_slot_holder
  spawn_pool_select_lock_release
  if [ -z "$WT" ]; then
    if [ -n "$WT_SLOT_NAME" ]; then
      echo "error: 'treehouse enter $WT_SLOT_NAME' did not enter $WT_SLOT_REAL within 60s; inspect window $T" >&2
    else
      echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    fi
    exit 1
  fi

  if [ -n "$WT_SLOT_NAME" ]; then
    validate_spawn_worktree "treehouse enter $WT_SLOT_NAME" "$T"
  else
    validate_spawn_worktree "treehouse get" "$T"
  fi
fi

# Place the slot at the resolved slot base, so the worker reads the code the
# fleet ACTUALLY RUNS instead of whatever commit the pool last left there. A
# pooled slot is disposable, so this is a reset rather than the secondmate path's
# fast-forward - a fast-forward would silently skip a diverged slot and leave the
# stale base in place, which is the defect. Purely local, no fetch.
#
# It is still guarded, because "disposable" is a claim about the pool, not proof
# about THIS directory: a slot carrying uncommitted work, or sitting on a task
# branch, may hold work that was never landed. Either one is left untouched and
# launched as-is with a loud notice rather than reset over.
if [ "$KIND" != secondmate ] && [ -n "$WT" ] && [ -n "$SLOT_BASE" ]; then
  slot_head=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$slot_head" = "$SLOT_BASE" ]; then
    :
  elif [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    echo "warning: $ID slot at $WT has uncommitted changes; left at ${slot_head:0:12} instead of the slot base ${SLOT_BASE:0:12} - the brief's file and line citations may not match it" >&2
  else
    slot_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    slot_default=$(default_branch "$WT" 2>/dev/null || true)
    if [ -n "$slot_branch" ] && [ "$slot_branch" != "$slot_default" ]; then
      echo "warning: $ID slot at $WT is on branch '$slot_branch', which may hold unlanded work; left at ${slot_head:0:12} instead of the slot base ${SLOT_BASE:0:12}" >&2
    elif ! git -C "$WT" checkout --quiet --detach "$SLOT_BASE" 2>/dev/null; then
      echo "warning: $ID slot at $WT could not be placed at the slot base ${SLOT_BASE:0:12}; left at ${slot_head:0:12} - the brief's file and line citations may not match it" >&2
    fi
  fi
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
      context_statusline_command=$(json_escape "$(shell_quote "$FM_ROOT/bin/fm-context-statusline.sh") --record $(shell_quote "$TASK_TMP/context-pressure.json")")
      cat > "$WT/.claude/settings.local.json" <<EOF
{"statusLine":{"type":"command","command":"$context_statusline_command"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$j_submit"}]}],"Stop":[{"hooks":[{"type":"command","command":"$j_stop"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$j_stopfail"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$j_sessionend"}]}]}}
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
# (fm-teardown.sh defaults an absent mode to no-mistakes, and fm-reflag.sh
# requires an explicit mode when a scout is reflagged as a ship task).
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  : "${SECONDMATE_PROJECTS:=}"
elif [ "$KIND" = scout ]; then
  MODE=
  YOLO=
fi

# Both remaining justification fields are DERIVED from state this spawn already
# validated, never declared by the caller, so the record cannot disagree with
# the contract it summarizes (bin/fm-reasoning-lib.sh).
REASONING_REQUIRED=
ESCALATION_POLICY=
if [ "$KIND" != secondmate ]; then
  REASONING_REQUIRED=$(fm_reasoning_required_for "$REASON_CODE")
  ESCALATION_POLICY=$(fm_escalation_policy_for "$KIND" "$MODE" "$YOLO")
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
      split("window endpoint_task_id worktree project harness kind mode yolo tasktmp model effort busy_gen traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx", keys, " ")
      for (i in keys) owned[keys[i]] = 1
    }
    !($1 in owned)
  ' "$RELAUNCH_META"
}
# Commit the attempt now that a launch is actually happening, and publish the
# resulting count onto the metadata every other reader already joins on. A
# continuation republishes the same count rather than a new one. The
# durable record is the authority; these two fields are its readable copy, and
# an absent attempt= on an older task's metadata reads as attempt 1.
ATTEMPT_N=
ATTEMPT_BUDGET=
if [ "$KIND" != secondmate ]; then
  if ATTEMPT_OPENED=$("$FM_ROOT/bin/fm-attempt.sh" open "$ID" "${ATTEMPT_FLAGS[@]+"${ATTEMPT_FLAGS[@]}"}"); then
    ATTEMPT_N=${ATTEMPT_OPENED#attempt=}
    ATTEMPT_N=${ATTEMPT_N%% *}
    ATTEMPT_BUDGET=${ATTEMPT_OPENED##*attempt_budget=}
  else
    # The count could not be made durable. Refuse rather than launch an attempt
    # nobody counted: an uncounted attempt is exactly the state this replaces,
    # and the budget silently stops bounding anything.
    echo "error: could not record the attempt count for $ID; refusing to launch an uncounted attempt" >&2
    exit 1
  fi
fi
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  # Durable ownership for bin/fm-worktree-guard.sh: a process IDENTITY, not a
  # bare pid, because a reboot reissues pid numbers and a recorded pre-reboot
  # pid then resolves to an unrelated live process. Empty fields read as
  # UNRESOLVED at check time, never as a released slot. Only the treehouse pool
  # path records this: a secondmate owns its home and Orca owns its own
  # worktree, so neither is allocated from a shared pool.
  if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
    "$FM_ROOT/bin/fm-worktree-guard.sh" owner-fields "$WT" 2>/dev/null || true
  fi
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  # The three identity axes, plus the deprecated kind= alias they replace. Every
  # writer dual-writes through bin/fm-task-axis-lib.sh so no writer spells the
  # derivation itself; docs/vocabulary-collisions.md owns the alias's retirement.
  echo "kind=$KIND"
  fm_task_axes_emit "$KIND"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  # Both base references, so which commit a task read and which it contributed
  # to is inspectable after the fact rather than inferred from the branch.
  # base_state names the relationship in one word; an unresolved contribution
  # target is recorded as the literal "unresolved" and never as a commit.
  [ -z "$SLOT_BASE" ] || echo "slot_base=$SLOT_BASE"
  [ -z "$BASE_STATE" ] || echo "contribution_target=${CONTRIB_TARGET:-unresolved}"
  [ -z "$BASE_STATE" ] || echo "base_state=$BASE_STATE"
  # Agent-justification record. Written for every task dispatch; a --secondmate
  # spawn provisions a home rather than dispatching a task and carries none.
  [ -z "$REASONING_REQUIRED" ] || echo "reasoning_required=$REASONING_REQUIRED"
  [ -z "$REASON_CODE" ] || echo "reason_code=$REASON_CODE"
  [ -z "$CAPABILITY_FLOOR" ] || echo "capability_floor=$CAPABILITY_FLOOR"
  # The route this dispatch was checked against, and a digest of the exact
  # policy surface that checked it. Assigned once and never rewritten: no later
  # layer may write a scheduling, admission, or failover outcome back onto the
  # tier the work IS. An absent pair means this home enforces no routed pool.
  [ -z "$ROUTE" ] || echo "route=$ROUTE"
  [ -z "${ROUTE_POLICY_DIGEST:-}" ] || echo "route_policy_digest=$ROUTE_POLICY_DIGEST"
  [ -z "$ESCALATION_POLICY" ] || echo "escalation_policy=$ESCALATION_POLICY"
  [ -z "$TOOLING_GAP_ITEM" ] || echo "tooling_gap_item=$TOOLING_GAP_ITEM"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "$ATTEMPT_N" ] || echo "attempt=$ATTEMPT_N"
  [ -z "$ATTEMPT_BUDGET" ] || echo "attempt_budget=$ATTEMPT_BUDGET"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
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
} > "$SPAWN_META_PATH"
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
  case "$HARNESS" in
    claude) supervision_model=autoarm ;;
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
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT"
