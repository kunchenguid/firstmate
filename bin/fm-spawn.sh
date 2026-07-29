#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
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
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. orca, cmux, and zellij do not support
#   --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
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
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi)
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
#   A --secondmate spawn also resolves a session display name (label) so the
#   captain's phone app can tell persistent sessions apart. Resolution order:
#   the registry line's optional "label: <display name>" field in
#   data/secondmates.md, then a prior label= in state/<id>.meta, then the
#   derived fallback "SM <Title-cased id suffix>" (sm-portal -> "SM Portal").
#   The resolved label is recorded as label= in meta on every spawn and passed
#   only to harnesses with a verified session-name flag (claude: -n/--name);
#   other harnesses keep the label in meta and emit no flag, the same omission
#   contract as an unsupported --effort value. The name flag only sets the
#   display name; it never changes remote-control state. Ship/scout spawns
#   carry no label (crew windows keep their fm-<id> names).
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout. Two pre-flight
#   checks decide the provable cases up front, before any window is created, so
#   an operator mistake costs milliseconds instead of the settle window: the
#   project argument must name an existing directory, and (for ship/scout) that
#   directory must be inside a git repository, since nothing else can ever yield
#   an isolated worktree. Every remaining shape is decided by the post-launch
#   settle poll, which deliberately never fast-refuses an EXISTING pane path -
#   a live shell can still cd away from one - and whose timeout names the path
#   the window is parked on and the concrete reason it is not a worktree.
#   A pane parked on a NONEXISTENT path is refused early, but only once the pane
#   has been seen at the project directory: before that, an absent path can still
#   be a pre-shell-init transient, and refusing one would abort a healthy spawn.
#   FM_SPAWN_WORKTREE_POLLS and FM_SPAWN_WORKTREE_POLL_INTERVAL size that poll's
#   window, resolved and validated with those pre-flight refusals - each on its
#   own range, and their product against the settle window's wall-clock ceiling
#   (docs/configuration.md owns their schema).
#   A settle-poll refusal never leaves that window a SILENT orphan, since no task
#   metadata records it yet. The nonexistent-path abort and the worktree re-check
#   remove the tmux/zellij/cmux/flat-herdr window this launch created; the
#   TIMEOUT deliberately does not touch it, because treehouse get may still be
#   allocating in that pane and killing it could damage the project, so it names
#   the window, the path, and the by-hand commands instead. A present
#   state/<id>.meta stops the removal and is reported unless its recorded
#   endpoint resolves unambiguously to a DIFFERENT window; a removal that cannot
#   be confirmed names what was left behind, and no worktree is ever removed.
#   Task metadata written to state/<id>.meta: window=, worktree=, project=,
#   harness=, model=, effort=, kind=, mode=, yolo=, tasktmp=. A kind=secondmate
#   spawn also records home=, projects=, and label= (session display name); a
#   non-default runtime backend records
#   further backend-specific fields (docs/configuration.md "Runtime backend";
#   bin/fm-backend.sh). fm-pr-check later appends canonical pr=/pr_head=, and
#   fm-x-link appends the X-mode fields for an X-mode-originated task (AGENTS.md
#   section 14).
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
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __OPINPUT__   absolute path to the canonical operational-input encoder
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# That token is state/<id>.grok-turnend-token, and Kimi's equivalent per-task
# pointer is state/<id>.kimi-turnend-token: each holds the firstmate-owned hook
# registry entry name for this task, is written here at launch, and is removed
# by fm-teardown.sh when the task ends.
# Task metadata written to state/<id>.meta always records model= (the concrete
# model axis resolved for this spawn, or the literal default when the harness
# keeps its own)
# and tasktmp= (the per-task temp root /tmp/fm-<id>/ created here, read back by
# fm-teardown.sh so the scratch directory is removed with the task).
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, projects=, and label=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
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
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
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
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
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
if [ "$KIND" = secondmate ]; then
  case "$BACKEND" in
    orca | cmux | zellij)
      echo "error: backend=$BACKEND does not support --secondmate spawns yet" >&2
      exit 1
      ;;
  esac
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
SETTLE_ABORT_CLEANUP=0
SETTLE_ABORT_TARGET=
# report (never touch the window, say loudly what was left behind) or reclaim
# (remove the window this launch created). Defaults to report so an exit nobody
# anticipated inside the armed span leaks loudly rather than killing a pane whose
# state is unknown; the two exits that are provably safe opt in explicitly.
SETTLE_ABORT_MODE=report
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

# Deal with the window a refused settle poll created. Every refusal inside that
# poll exits after the backend window exists and `treehouse get` was sent into it,
# but before state/<id>.meta is written, so nothing records that window for
# fm-teardown.sh - it hard-refuses with "no meta for task <id>", which leaves the
# window unreclaimable by the fleet rather than merely untidy.
#
# The response is split by what the pane can be proved to be doing, because
# damaging a PROJECT is categorically worse than leaking a window:
#   - reclaim: the pane was seen at the project directory and then sat on a
#     nonexistent path across consecutive reads, or a confirmed worktree failed
#     its re-check. `treehouse get` cannot still be allocating in either case, so
#     removing the window costs nothing that was making progress.
#   - report: the settle window simply elapsed, or the launch exited somewhere
#     else inside the armed span. A slow-but-progressing `treehouse get` (large
#     repo, cold cache, WSL mount) would be SIGHUPed mid-flight by a kill, which
#     can leave a partial .git/worktrees/<name> or a stale lock IN the project,
#     and the timeout refusal itself sends the operator to read that pane. The
#     same holds for any exit nobody anticipated: the pane's state is unknown,
#     so nothing is touched and the orphan is named loudly instead. A reported
#     orphan is acceptable, a silent one is not.
#
# Two constraints keep the reclaim from being worse than the disease:
#   - Clean only what THIS spawn created, and only once no other task is shown to
#     own it. A meta is normally the proof that some task owns that window, so its
#     presence stops the cleanup dead unless the endpoint it records is readable,
#     unambiguous, and positively a DIFFERENT window - the stale-record class
#     where a completed task's pointer outlived its slot, leaving the window this
#     launch created owned by nothing. Ambiguity never authorizes a kill.
#   - Address the window by the stable id captured at creation, never the fm-<id>
#     name, for the same reason the settle poll targets that id: a lost or
#     renamed name can resolve to a DIFFERENT window, and killing the wrong
#     window is far worse than leaking one. The name is passed only as the
#     backends' own cross-check on the id, never as the handle.
#
# It never removes a worktree. `treehouse get` may already have allocated one in
# the pane, and fm-spawn can prove neither which one nor that it is disposable,
# so the possibility is reported for a human to settle and nothing is touched.
#
# Scoped to the backends whose task window this path leaves entirely unowned:
# tmux, zellij, cmux, and herdr's ordinary flat layout. Orca never reaches the
# settle poll at all, and a PROJECTED herdr task is left to its own exact
# projection cleanup, which owns the presentation lock this must not race for.

# The endpoint an existing record names for this task, or empty when the record
# is unreadable or carries no window field.
spawn_settle_abort_meta_window() {  # <meta-path>
  local line
  line=$(grep -m1 '^window=' "$1" 2>/dev/null) || return 0
  printf '%s' "${line#window=}"
}

# Compare that recorded endpoint against the window THIS launch created, echoing
# other (positively a different window), same, or unknown. Only "other" may
# authorize a reclaim, so every unreadable, malformed, or ambiguous answer has to
# land on unknown.
spawn_settle_abort_meta_verdict() {  # <recorded-endpoint>
  local recorded=$1 resolved out want
  if [ -z "$recorded" ]; then
    printf 'unknown'
    return 0
  fi
  case "$BACKEND" in
    tmux)
      # The record keeps the NAME form of the endpoint while this launch holds
      # the stable window id, so the two are comparable only after resolving the
      # name - and `display-message -t <gone-name>` answers about the ACTIVE
      # client's window instead of failing. Believe the resolution only when the
      # window it found still carries the recorded name; anything else is the
      # fallback answering about a window nobody asked about.
      out=$(tmux display-message -p -t "$recorded" '#{window_id} #{window_name}' 2>/dev/null) || out=
      resolved=${out%% *}
      want=${recorded##*:}
      if [ -z "$out" ] || [ -z "$resolved" ] || [ "$out" = "$resolved" ] \
         || [ -z "$want" ] || [ "${out#* }" != "$want" ]; then
        printf 'unknown'
        return 0
      fi
      ;;
    *)
      # Every other backend records the same id-form endpoint this launch holds,
      # so the strings are directly comparable with no lookup to be misled by.
      resolved=$recorded
      ;;
  esac
  if [ "$resolved" = "$SETTLE_ABORT_TARGET" ]; then
    printf 'same'
  else
    printf 'other'
  fi
}

# The title the backend actually gave this task's surface. zellij and cmux
# home-scope the caller-facing fm-<id> label to fm-<hometag>-<id> and create,
# list, and match only that scoped form, so naming the bare label in a by-hand
# hint would send an operator hunting for a tab that was never created.
spawn_settle_abort_display_name() {
  local scoped=''
  case "$BACKEND" in
    zellij)
      if fm_backend_source zellij >/dev/null 2>&1; then
        scoped=$(fm_backend_zellij_scoped_title "$W" 2>/dev/null) || scoped=''
      fi
      ;;
    cmux)
      if fm_backend_source cmux >/dev/null 2>&1; then
        scoped=$(fm_backend_cmux_scoped_title "$W" 2>/dev/null) || scoped=''
      fi
      ;;
  esac
  printf '%s' "${scoped:-$W}"
}

# The exact by-hand commands for the window this launch could not or must not
# remove, so a reported orphan is actionable rather than merely acknowledged.
spawn_settle_abort_manual_hint() {
  local name
  name=$(spawn_settle_abort_display_name)
  case "$BACKEND" in
    tmux)
      printf "read it with 'tmux capture-pane -p -t %s' and close it with 'tmux kill-window -t %s'" \
        "$SETTLE_ABORT_TARGET" "$SETTLE_ABORT_TARGET"
      ;;
    zellij)
      printf "read it by attaching with 'zellij attach %s' and close its '%s' tab there" \
        "${SETTLE_ABORT_TARGET%%:*}" "$name"
      ;;
    cmux)
      printf "read the '%s' workspace and close it with 'cmux close-workspace --workspace %s'" \
        "$name" "${SETTLE_ABORT_TARGET%%:*}"
      ;;
    herdr)
      printf "read it with 'herdr pane read %s --source recent --session %s' and close it with 'herdr pane close %s --session %s'" \
        "${SETTLE_ABORT_TARGET#*:}" "${SETTLE_ABORT_TARGET%%:*}" \
        "${SETTLE_ABORT_TARGET#*:}" "${SETTLE_ABORT_TARGET%%:*}"
      ;;
    *)
      printf "read and close the %s endpoint %s by hand" "$BACKEND" "$SETTLE_ABORT_TARGET"
      ;;
  esac
}

spawn_settle_abort_worktree_note() {
  echo "note: 'treehouse get' may already have allocated a worktree of '$PROJ_ABS' for this launch, and on the timeout path may still have been allocating one. fm-spawn never removes a worktree it cannot prove it created, so none was touched - run 'git -C $PROJ_ABS worktree list' and reclaim any unused or partial one by hand." >&2
}

# Whether the window this launch created is still open, as present, absent, or
# unknown. A CONFIRMED removal is the whole point of the reclaim, so the answer
# may not come from a probe that silently answers about a DIFFERENT window, nor
# from one that reads "closed" and "could not be read" identically.
#
# <kill-confirmed> is 1 only when the backend's own close call reported success.
spawn_settle_abort_target_state() {  # <kill-confirmed>
  local kill_confirmed=${1:-0} out
  case "$BACKEND" in
    tmux)
      # fm_backend_target_exists's tmux probe cannot answer this. Verified on
      # tmux 3.6: after `kill-window -t <window-id>`,
      # `display-message -p -t <window-id> '#{pane_id}'` exits 0 with EMPTY
      # output instead of failing, so an exit-status-only read calls every
      # removed window present and would warn about a leak that does not exist.
      # Match the exact id against the window inventory instead - the shape
      # fm_backend_tmux_agent_state already uses for this same tmux habit -
      # where absence is real absence. Only a failed inventory read is unknown,
      # apart from the responses that mean no server is left to hold a window.
      if out=$(LC_ALL=C tmux list-windows -a -F '#{window_id}' 2>&1); then
        if printf '%s\n' "$out" | grep -Fqx "$SETTLE_ABORT_TARGET"; then
          printf 'present'
        else
          printf 'absent'
        fi
        return 0
      fi
      case "$out" in
        *"no server running on "*|*"error connecting to "*) printf 'absent' ;;
        *) printf 'unknown' ;;
      esac
      ;;
    *)
      # Every other backend's probe queries its own inventory for the exact
      # recorded endpoint, with no active-window fallback to be misled by, so a
      # positive answer is presence. A negative one still conflates a closed
      # surface with an unreadable backend (server down, CLI gone), and this
      # path may not claim a removal it cannot see: absence counts only when the
      # close call itself succeeded, which is the evidence that the backend was
      # reachable enough for the negative to mean what it says.
      if fm_backend_target_exists "$BACKEND" "$SETTLE_ABORT_TARGET" "$W" >/dev/null 2>&1; then
        printf 'present'
      elif [ "$kill_confirmed" = 1 ]; then
        printf 'absent'
      else
        printf 'unknown'
      fi
      ;;
  esac
}

spawn_settle_abort_reclaim() {
  local meta="$STATE/$ID.meta" recorded='' verdict=none why unowned='' fate
  local name before after kill_confirmed=0
  name=$(spawn_settle_abort_display_name)
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    recorded=$(spawn_settle_abort_meta_window "$meta")
    verdict=$(spawn_settle_abort_meta_verdict "$recorded")
  fi
  if [ "$verdict" = none ]; then
    unowned="no task record was written for it"
  else
    unowned="the only task record for it, $meta, records endpoint '${recorded:-<none>}'"
  fi
  if [ "$SETTLE_ABORT_MODE" != reclaim ]; then
    # Only claim the orphan is beyond cleanup's reach where that was actually
    # established. A record naming this SAME window is a record teardown can
    # still follow, so saying otherwise would be false.
    case "$verdict" in
      same)
        fate="$meta records endpoint '$recorded', which resolves to this same window, so cleanup can still reach it through that record"
        ;;
      unknown)
        fate="$unowned, which could not be compared with this window, so cleanup may never find it"
        ;;
      *)
        fate="$unowned, so cleanup will never find it"
        ;;
    esac
    echo "warning: leaving the $BACKEND window this launch created open: $SETTLE_ABORT_TARGET (named $name) in '$PROJ_ABS', and $fate. It was NOT closed because 'treehouse get' may still be allocating in that pane and killing it could damage the project - $(spawn_settle_abort_manual_hint) once you have read it." >&2
    spawn_settle_abort_worktree_note
    return 0
  fi
  case "$verdict" in
    none) ;;
    other)
      echo "note: $meta records endpoint '$recorded', which is a different window than the $SETTLE_ABORT_TARGET this launch created, so that record is stale for this window and nothing owns it." >&2
      ;;
    *)
      if [ "$verdict" = same ]; then
        why="names this same window"
      else
        why="is unreadable, malformed, or could not be compared"
      fi
      echo "warning: leaving window $SETTLE_ABORT_TARGET open: $meta exists and this launch could not establish that the window it created is unowned - its recorded endpoint '${recorded:-<none>}' $why. Nothing was removed; inspect that record and the window by hand." >&2
      spawn_settle_abort_worktree_note
      return 0
      ;;
  esac
  before=$(spawn_settle_abort_target_state 0)
  if fm_backend_kill "$BACKEND" "$SETTLE_ABORT_TARGET" "${ZELLIJ_TAB_ID:-}" "$W" >/dev/null 2>&1; then
    kill_confirmed=1
  fi
  after=$(spawn_settle_abort_target_state "$kill_confirmed")
  case "$after" in
    present)
      echo "warning: could not remove the window this launch created: $BACKEND window $SETTLE_ABORT_TARGET (named $name) is still open, $unowned, so cleanup will never find it. $(spawn_settle_abort_manual_hint)." >&2
      ;;
    absent)
      if [ "$before" = absent ]; then
        echo "note: the $BACKEND window this launch created ($SETTLE_ABORT_TARGET) was already gone; nothing was left behind." >&2
      else
        echo "note: removed the $BACKEND window this launch created ($SETTLE_ABORT_TARGET), since $unowned." >&2
      fi
      ;;
    *)
      echo "warning: could not confirm that the window this launch created was removed: $BACKEND could not be read after the close, so $SETTLE_ABORT_TARGET (named $name) may still be open, and $unowned, so cleanup will never find it. $(spawn_settle_abort_manual_hint)." >&2
      ;;
  esac
  spawn_settle_abort_worktree_note
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
            echo "endpoint_task_id=$ID"
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
  if [ "$SETTLE_ABORT_CLEANUP" = 1 ]; then
    SETTLE_ABORT_CLEANUP=0
    spawn_settle_abort_reclaim || true
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
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi)
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
    # predicted-next-prompt ghost text, which renders as dim/faint (SGR 2) text inside
    # an otherwise-empty composer. It is a per-launch env prefix scoped to this
    # firstmate-launched agent; it never touches the captain's global config. The CLI's
    # --prompt-suggestions flag is print/SDK-mode only and does NOT suppress the
    # interactive ghost text (verified empirically), so the env var is the correct control.
    #
    # The prefix is applied per KIND, because the suggestion's value and its cost differ:
    #   ship/scout - DISABLED. An autonomous crewmate is a worker the captain never
    #     drives from its own composer, so the suggestion has no reader to help and is
    #     pure classifier risk.
    #   secondmate - ENABLED (no prefix). A secondmate is a captain-facing agent the
    #     captain does read and drive, so it shows the native suggestion exactly as the
    #     captain's own session does. Safety rests on the shared fm_composer_strip_ghost
    #     (bin/fm-composer-lib.sh), the one fleet-wide ANSI-aware extractor of real typed
    #     content, which every secondmate-reachable composer read routes through - the
    #     same backstop that already covers the captain's own firstmate pane, which this
    #     flag never reached either. The plain-screen readers that cannot strip ghost
    #     styling - orca, cmux, and zellij - all refuse --secondmate spawns above, so no
    #     secondmate can land on a reader without fm_composer_strip_ghost. See the
    #     harness-adapters skill for the contract that rule satisfies.
    claude)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG____NAMEFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
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
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    label) value=$(printf '%s\n' "$line" | sed -n 's/.*; label: \([^;)]*\).*/\1/p') ;;
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
    claude|codex|opencode|pi|pi-signed|grok|kimi)
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
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command.
  esac
}

# Derived session-label fallback for a secondmate with no explicit label:
# strip a leading "sm-", title-case each hyphen-separated word, prefix "SM ".
# sm-portal -> "SM Portal"; an acronym or house name (sm-cnc -> "SM CNC",
# sm-fw -> "SM Firmware") needs an explicit registry "label:" field instead.
secondmate_derived_label() {
  local id=$1 suffix word out first
  suffix=${id#sm-}
  out=
  for word in ${suffix//-/ }; do
    first=$(printf '%s' "${word:0:1}" | tr '[:lower:]' '[:upper:]')
    out="$out $first${word:1}"
  done
  printf 'SM%s\n' "$out"
}

name_flag_for_harness() {
  local harness=$1 name=$2
  [ -n "$name" ] || return 0
  case "$harness" in
    claude)
      # Verified on Claude Code 2.1.217 (2026-07-22): -n/--name sets the session
      # display name the Claude phone app shows; it does not change
      # remote-control state. No other harness has a verified session-name
      # flag, so like an unsupported --effort value the label stays in meta
      # and no flag is emitted for them.
      printf -- '--name %s ' "$(shell_quote "$name")"
      ;;
  esac
}

case "$LAUNCH" in
  *__KIMIBIN__*)
    KIMI_BIN=$(resolve_kimi_binary) || exit 1
    LAUNCH=${LAUNCH//__KIMIBIN__/"$(shell_quote "$KIMI_BIN")"}
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
  PROJ_ARG_PATH=$(resolve_project_dir_arg "$PROJ")
  # Pre-flight refusal 1 of 2: the project argument must name an existing
  # directory. Without this the bare `cd` below aborts under `set -e` with
  # bash's own "cd: ...: No such file or directory", which names the path but
  # not what fm-spawn expected of it or what to do next.
  if [ ! -d "$PROJ_ARG_PATH" ]; then
    echo "error: refusing to launch $ID: project path '$PROJ_ARG_PATH' is not an existing directory. Expected the project's local copy (an absolute path, or projects/<name> under $PROJECTS). Check the path, or clone the project first." >&2
    exit 1
  fi
  PROJ_ABS="$(cd "$PROJ_ARG_PATH" && pwd)"
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

# Pre-flight refusal 2 of 2: a ship/scout task's isolated worktree is always a
# git worktree derived from the project, whether treehouse get allocates it in
# the pane or Orca allocates it directly. A project path that is not inside a
# git repository at all therefore CANNOT yield one, no matter how long the poll
# below waits, so refuse here - before any window exists - instead of launching
# into a pane and burning the whole settle window on a certainty.
#
# This is deliberately a property of the project path fm-spawn was handed,
# evaluated in fm-spawn's own process, and never a property of the pane's
# reported cwd. That is what makes it safe to decide immediately: the slow-start
# case the poll below exists to tolerate is a pane that has not yet MOVED, which
# says nothing about whether the project can produce a worktree. A refusal here
# is wrong only if the project path is wrong, and a fast wrong-path refusal is
# exactly the outcome the operator wants.
if [ "$KIND" != secondmate ] && ! git -C "$PROJ_ABS" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: refusing to launch $ID: project path '$PROJ_ABS' is not inside a git repository, so no isolated worktree can ever be created for it. Expected a git repository (or a directory inside one); found a directory git does not track. Check the project path, or clone/initialize the project before dispatching." >&2
  exit 1
fi

# The settle poll's window is sized here, with the pre-flight refusals above and
# under the same conditions as the poll itself, because a malformed value is a
# property of the environment fm-spawn was handed and needs nothing the launch
# produces. Validating it inside the poll instead would abort only after a window
# had been created and a worktree allocated in it, and since state/<id>.meta is
# never written on a refusal, both would be left behind with nothing recording
# them for fm-teardown.sh to reclaim.
#
# A malformed value must also never silently shorten the wait into an accidental
# fast refusal, which is exactly the wrong-refusal failure that poll exists to
# avoid, so refuse the misconfiguration rather than guessing a window for it. The
# floor is 2 rather than 1 because accepting a worktree requires two consecutive
# reads that agree on the same physical path (see the poll below for why), so a
# one-poll window can only ever time out however correctly the pane settled. The
# ceilings exist because the window is a real wait: a fat-fingered extra digit
# would park the spawn for years rather than sizing it for a slow host. What an
# operator actually waits is count x interval, so the wall-clock ceiling is
# enforced on that PRODUCT as well; two independently in-range values still
# multiply into a window nobody asked for (86400 polls 60s apart is ~60 days).
#
# The shape check runs BEFORE any arithmetic comparison, and rejects a digit
# string too long to compare as well as a non-numeric one. `[ "$v" -lt 2 ]` on a
# value past the shell's integer range does not answer false, it errors, and the
# error status reads as "not less than 2" - so a value validated by comparison
# alone would be ACCEPTED while leaking the raw shell diagnostic that this whole
# refusal exists to replace. The product is therefore computed only once both
# values passed their own shape and range checks, and in whole milliseconds so a
# decimal interval stays exact integer arithmetic.
WT_POLLS_MIN=2
WT_POLLS_MAX=86400
# Consecutive identical nonexistent reads required before the gated fast refusal
# below may abort. Above the two reads that accepting a worktree needs, because a
# wrong abort here is the costly direction and the pre-init transient the gate
# already blocks was observed spanning more than one poll.
WT_MISSING_READS=3
# The interval floor is the millisecond the window is measured in: anything
# smaller rounds to no wait at all and busy-spins the backend path query, which
# is the failure the floor exists to prevent.
WT_POLL_INTERVAL_MIN=0.001
WT_POLL_INTERVAL_MAX=60
WT_WINDOW_MAX_SECONDS=86400
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  WT_POLLS=${FM_SPAWN_WORKTREE_POLLS:-60}
  wt_polls_bad=""
  case $WT_POLLS in
    ''|*[!0-9]*) wt_polls_bad=yes ;;
    ????????*) wt_polls_bad=yes ;;
  esac
  if [ -z "$wt_polls_bad" ] &&
    { [ "$WT_POLLS" -lt "$WT_POLLS_MIN" ] || [ "$WT_POLLS" -gt "$WT_POLLS_MAX" ]; }; then
    wt_polls_bad=yes
  fi
  if [ -n "$wt_polls_bad" ]; then
    echo "error: FM_SPAWN_WORKTREE_POLLS must be a whole number of polls between $WT_POLLS_MIN and $WT_POLLS_MAX, since accepting a worktree requires two consecutive reads that agree on the same path, got '${FM_SPAWN_WORKTREE_POLLS:-}'" >&2
    exit 1
  fi
  # Sleep length between polls, the other half of the count/interval poll pair
  # that sizes the settle window. Validated on the
  # same fail-closed shape-before-arithmetic rule as the count: a value reaching
  # `sleep` unchecked would abort mid-poll with the shell's own raw diagnostic,
  # and an effectively zero interval would busy-spin the backend path query with
  # no wait.
  #
  # The accepted shape is exactly what the refusal below and
  # docs/configuration.md advertise: whole seconds, a decimal, or the
  # leading-dot form `sleep` also takes. Nothing in range is rejected for how it
  # was WRITTEN - `60.000000` is a legal 60 - because only the whole part ever
  # reaches the arithmetic below, so only it needs a length bound, and that bound
  # is applied after cosmetic leading zeros are stripped.
  WT_POLL_INTERVAL=${FM_SPAWN_WORKTREE_POLL_INTERVAL:-1}
  wt_interval_bad=""
  wt_interval_int=$WT_POLL_INTERVAL
  wt_interval_frac=""
  case $WT_POLL_INTERVAL in
    *.*.*) wt_interval_bad=yes ;;
    *.*)
      wt_interval_int=${WT_POLL_INTERVAL%%.*}
      wt_interval_frac=${WT_POLL_INTERVAL#*.}
      # A dot with no digits after it ("1.", ".") is not a number sleep accepts.
      case $wt_interval_frac in
        ''|*[!0-9]*) wt_interval_bad=yes ;;
      esac
      ;;
  esac
  if [ -z "$wt_interval_bad" ]; then
    case $wt_interval_int in
      *[!0-9]*) wt_interval_bad=yes ;;
    esac
  fi
  # Only the leading-dot form may omit the whole part, so a bare "." is out.
  if [ -z "$wt_interval_bad" ] && [ -z "$wt_interval_int" ] && [ -z "$wt_interval_frac" ]; then
    wt_interval_bad=yes
  fi
  if [ -z "$wt_interval_bad" ]; then
    while [ "$wt_interval_int" != "${wt_interval_int#0}" ]; do
      wt_interval_int=${wt_interval_int#0}
    done
    # The one length bound that has to exist: bash's own arithmetic ERRORS on a
    # value past its integer range, which under set -e is the raw diagnostic
    # this whole refusal replaces.
    case $wt_interval_int in
      ??????*) wt_interval_bad=yes ;;
    esac
  fi
  if [ -z "$wt_interval_bad" ]; then
    # Whole milliseconds, the unit the wall-clock ceiling below is enforced in.
    # Truncating toward zero is what makes the floor exact: a value that rounds
    # away to no wait at all lands on 0 and is refused.
    wt_interval_frac_ms=${wt_interval_frac}000
    wt_interval_frac_ms=${wt_interval_frac_ms:0:3}
    WT_POLL_INTERVAL_MS=$((10#${wt_interval_int:-0} * 1000 + 10#$wt_interval_frac_ms))
    if [ "$WT_POLL_INTERVAL_MS" -lt 1 ] ||
      [ "$WT_POLL_INTERVAL_MS" -gt $((WT_POLL_INTERVAL_MAX * 1000)) ]; then
      wt_interval_bad=yes
    fi
  fi
  if [ -n "$wt_interval_bad" ]; then
    echo "error: FM_SPAWN_WORKTREE_POLL_INTERVAL must be a positive number of seconds from $WT_POLL_INTERVAL_MIN to $WT_POLL_INTERVAL_MAX (a decimal such as 0.5 or .5 is fine), got '${FM_SPAWN_WORKTREE_POLL_INTERVAL:-}'" >&2
    exit 1
  fi
  # Both knobs are in range on their own; the wait they arm together may still
  # not be. The ceiling belongs to the wall-clock window, not to either number,
  # so enforce it on the product now that both are proven safe to multiply.
  wt_window_ms=$((WT_POLLS * WT_POLL_INTERVAL_MS))
  if [ "$wt_window_ms" -gt $((WT_WINDOW_MAX_SECONDS * 1000)) ]; then
    echo "error: FM_SPAWN_WORKTREE_POLLS=$WT_POLLS with FM_SPAWN_WORKTREE_POLL_INTERVAL=$WT_POLL_INTERVAL arms a settle window of $((wt_window_ms / 1000)) seconds, past the $WT_WINDOW_MAX_SECONDS-second ceiling; the window is a real wait, so lower the poll count, the interval, or both" >&2
    exit 1
  fi
fi

# spawn_worktree_ok: true when <path> is itself the top of a git worktree
# distinct from PROJ_ABS_REAL. The one place that decides "is this an isolated
# worktree", shared by the poll below (probing non-fatally while waiting for
# the backend to actually move the pane there) and validate_spawn_worktree
# (the fatal final check) - see that function for why a naive "differs from
# PROJ_ABS_REAL" comparison alone is not sufficient.
spawn_worktree_ok() {  # <path>
  local p=$1 p_real top top_real
  p_real=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [ "$p_real" = "$top_real" ] && [ "$p_real" != "$PROJ_ABS_REAL" ]
}

# spawn_worktree_reject_reason: the concrete reason the settle poll below did not
# accept <path>, as a phrase for an operator-facing refusal. Diagnosis only - it
# never decides anything, so a path it cannot classify still reads as "not an
# isolated worktree" rather than silently passing. A path spawn_worktree_ok does
# accept was withheld only by the poll's acceptance rule, so state that rule
# rather than calling a genuine isolated worktree something it is not. The rule
# is the general one the loop enforces - no two CONSECUTIVE reads agreed on it -
# which covers both a worktree first seen on the final poll and one seen several
# times but never twice running.
spawn_worktree_reject_reason() {  # <path>
  local p=$1 p_real top top_real
  [ -n "$p" ] || { printf 'the backend reported no current path for that window\n'; return 0; }
  if spawn_worktree_ok "$p"; then
    printf 'it is an isolated worktree, but no two consecutive reads agreed on it, so it could not be confirmed\n'
    return 0
  fi
  [ -e "$p" ] || { printf 'that path does not exist\n'; return 0; }
  [ -d "$p" ] || { printf 'that path is not a directory\n'; return 0; }
  p_real=$(cd "$p" 2>/dev/null && pwd -P) || {
    printf 'that directory could not be entered\n'; return 0; }
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || {
    printf 'it is not inside a git repository\n'; return 0; }
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || top_real=$top
  if [ "$p_real" = "$PROJ_ABS_REAL" ]; then
    printf 'it is the primary checkout itself, not an isolated worktree\n'
    return 0
  fi
  if [ "$p_real" != "$top_real" ]; then
    if [ "$top_real" = "$PROJ_ABS_REAL" ]; then
      printf "it is a subdirectory of the primary checkout, not an isolated worktree\n"
    else
      printf "it is not the root of its worktree, whose root is '%s'\n" "$top"
    fi
    return 0
  fi
  printf 'it is not an isolated worktree\n'
}

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
  local source=$1 inspect_target=$2 wt_top
  if ! spawn_worktree_ok "$WT"; then
    wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
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
    HERDR_LABEL_HOME=$FM_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
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
          HERDR_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_parent_workspace_exact \
            "$HERDR_SES" "$HERDR_PARENT_LABEL" 2>/dev/null || true)
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
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL"
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
  fm_backend_current_path "$BACKEND" "$1" "$W"
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

if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  # Arm the settle-abort handler (spawn_settle_abort_reclaim) for exactly the
  # span where a window exists but no meta records it yet - it stays armed until
  # state/<id>.meta has actually been written, not merely until the worktree is
  # accepted. Every refusal in the poll below and the worktree re-check after it
  # sit inside that span, and so does everything between them and the meta
  # write: the per-task temp mkdir, the state-directory resolution, and the
  # per-harness hook writes all run under `set -eu` and can exit, leaving the
  # same unrecorded orphan. Those later exits keep the default report mode,
  # because a pane whose state nobody anticipated must leak loudly rather than
  # be killed. The stable id captured at creation is the handle. A PROJECTED
  # herdr task is excluded because its own exact projection cleanup already owns
  # that window.
  case "$BACKEND" in
    tmux | zellij | cmux)
      SETTLE_ABORT_TARGET=$WT_TARGET
      SETTLE_ABORT_CLEANUP=1
      ;;
    herdr)
      if [ "${HERDR_PROJECTED:-0}" -ne 1 ]; then
        SETTLE_ABORT_TARGET=$WT_TARGET
        SETTLE_ABORT_CLEANUP=1
      fi
      ;;
  esac
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to
  # the worktree. Target the stable window id, not the name: if the name is
  # ever lost (e.g. an automatic-rename slips through), display-message -t
  # <bad-name> falls back to the active client's window, which would misread
  # firstmate's OWN pane path as the worktree and tangle a hook into the
  # primary checkout. The window id never lies. A brand-new pane can also
  # report a transient pre-shell-init cwd (observed: the terminal
  # multiplexer's own default directory) on its very first poll(s), before it
  # actually lands in PROJ_ABS or the worktree; that transient also differs
  # from PROJ_ABS_REAL, so a plain "differs from PROJ_ABS_REAL" check can
  # latch onto it. Poll until the reported path itself resolves to a genuine,
  # isolated git worktree (spawn_worktree_ok), not merely until it differs
  # from the project path.
  #
  # A single read that passes spawn_worktree_ok is still not proof the pane
  # settled there: on some tmux/WSL setups a brand-new window's
  # pane_current_path transiently reports an unrelated stale path (seen live
  # as another real git checkout entirely) before the shell catches up with
  # treehouse get's cd. That stale path resolves to a real, distinct worktree
  # top-level too, so accepting it on one read alone silently records the
  # wrong worktree= in state/<id>.meta. Require two consecutive reads to agree
  # on the same physical worktree path before accepting it; a mismatch just
  # becomes the new candidate rather than resetting the wait, so a pane that
  # is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  # Fast-refusal early abort (the follow-up filed with the WSL race fix): a pane
  # parked on a NONEXISTENT path can never become an isolated worktree, so
  # refuse it early instead of burning the full settle window. This matters
  # under the herdr presentation-order lock, whose bounded (5s) contention
  # window sits around this poll: a slow abort forces a concurrent sibling
  # into its flat fallback.
  #
  # That refusal is GATED on having seen the pane at the project directory at
  # least once. The gate exists because this abort originally rested on the
  # claim that the pre-shell-init transient is always an existing directory, so
  # it could never collide with a nonexistent path. That claim is not provable
  # and was contradicted in the tree: the fixture in
  # tests/fm-spawn-worktree-race.test.sh reports a transient path it never
  # creates, and the transient can span more than one poll - on WSL a path can
  # also read as absent while a mount is still coming up. Two consecutive
  # nonexistent pre-init reads therefore aborted a spawn that would have
  # reached its worktree, which is the one failure this loop must never have.
  #
  # A confirmed sighting of PROJ_ABS_REAL is the proof that shell init finished
  # and treehouse get actually had its chance, so anything nonexistent after it
  # is a real parked pane rather than a pre-init artifact. This is the same
  # "require one confirmed sighting of the project directory before trusting a
  # divergence" shape the WSL race fix established. The gate can only ever
  # WITHHOLD the fast refusal and fall back to the full window, so a pane that
  # never reports the project directory stays slow instead of refusing wrongly.
  # Existing non-worktree paths are still never fast-refused at all.
  #
  # An EXISTING path is deliberately never fast-refused here, however stable it
  # looks: a live shell can cd at any moment, so "this pane is parked somewhere
  # that is not a worktree" is a statement about the pane's cwd right now, not a
  # proof about its future. The provable non-worktree cases are decided by the
  # two pre-flight refusals above, against the project path itself, before this
  # loop ever runs. A wrong refusal here would send project work into the
  # primary checkout's blast radius, so this loop stays slow on purpose.
  candidate=""
  missing_path=""
  missing_reads=0
  last_path=""
  # Set once the pane has been observed at the project directory, which unlocks
  # the nonexistent-path fast refusal above. Never reset: shell init happens once.
  proj_seen=0
  # WT_POLLS was resolved and validated with the pre-flight refusals, before this
  # window existed, so a malformed value never costs an orphaned window here. The
  # loop counts rather than iterating `seq 1 "$WT_POLLS"`, so a large window costs
  # nothing but time - a word list would have to be materialized in full up front.
  poll_n=0
  while [ "$poll_n" -lt "$WT_POLLS" ]; do
    poll_n=$((poll_n + 1))
    p=$(spawn_current_path "$WT_TARGET" || true)
    last_path=$p
    if [ -n "$p" ] && spawn_worktree_ok "$p"; then
      p_real=$(real_path_or_raw "$p")
      if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
        WT="$p"
        break
      fi
      candidate="$p_real"
      missing_path=""
      missing_reads=0
    else
      candidate=""
      if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" = "$PROJ_ABS_REAL" ]; then
        proj_seen=1
      fi
      if [ -n "$p" ] && [ ! -e "$p" ]; then
        if [ "$p" = "$missing_path" ]; then
          missing_reads=$((missing_reads + 1))
          if [ "$proj_seen" = 1 ] && [ "$missing_reads" -ge "$WT_MISSING_READS" ]; then
            # Consecutive reads of a nonexistent path after the project sighting
            # are proof the pane is parked, not mid-allocation, so this exit is
            # one of the two that may remove the window it created.
            SETTLE_ABORT_MODE=reclaim
            echo "error: treehouse get did not yield an isolated worktree: window $T is parked on nonexistent path '$p'; the pane reached '$PROJ_ABS' and then moved somewhere that does not exist, so no worktree can appear there" >&2
            exit 1
          fi
        else
          missing_path="$p"
          missing_reads=1
        fi
      else
        missing_path=""
        missing_reads=0
      fi
    fi
    sleep "$WT_POLL_INTERVAL"
  done
  if [ -z "$WT" ]; then
    # SETTLE_ABORT_MODE stays report here on purpose: the window merely ran out
    # of time, so `treehouse get` may still be allocating in that pane, and this
    # refusal sends the operator to read its scrollback. The handler names the
    # orphan and the by-hand commands rather than killing it.
    echo "error: treehouse get did not enter an isolated worktree within ${WT_POLLS} polls ${WT_POLL_INTERVAL}s apart: window $T is still on '${last_path:-<no path reported>}' ($(spawn_worktree_reject_reason "$last_path")). Expected an isolated git worktree of '$PROJ_ABS', distinct from that primary checkout. treehouse may be missing there, or the project may not be treehouse-managed." >&2
    exit 1
  fi

  # The re-check can still refuse, with the same reason and the same unrecorded
  # window, so it stays armed. Two agreeing reads already confirmed the worktree,
  # which means treehouse finished and the pane is parked, so its refusal is in
  # the same provably-safe category as the nonexistent-path abort above.
  SETTLE_ABORT_MODE=reclaim
  validate_spawn_worktree "treehouse get" "$T"
  # Back to report for the rest of the armed span: from here on an exit is one
  # nobody anticipated, so the pane's state is unknown and only a loud report is
  # safe.
  SETTLE_ABORT_MODE=report
fi

# The worktree is isolated, but not necessarily on the branch this project
# actually ships to: a worktree pool starts every worktree on origin's default
# branch, which is the wrong repository's on a fleet that ships to its own fork.
# Align it here, while it is provably empty and before the crewmate cuts its
# branch - unlanded work is never touched, and a worktree that cannot be aligned
# stops the spawn rather than producing an unreviewable pull request later.
if [ "$KIND" != secondmate ] && [ -n "$WT" ]; then
  "$SCRIPT_DIR/fm-worktree-base.sh" "$WT" "$PROJ_ABS" || exit 1
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
    pi|pi-signed)
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

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
SECONDMATE_LABEL=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
  # Session display name: registry label -> prior meta label= (backfill for a
  # registry line without one) -> derived fallback. Re-resolving here on every
  # spawn is what makes the captain's naming convention durable across
  # recovery, /updatefirstmate, and restart, exactly like the harness axis.
  SECONDMATE_LABEL=$(secondmate_registry_value "$ID" label || true)
  if [ -z "$SECONDMATE_LABEL" ] && [ -f "$STATE/$ID.meta" ]; then
    SECONDMATE_LABEL=$(grep '^label=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  [ -n "$SECONDMATE_LABEL" ] || SECONDMATE_LABEL=$(secondmate_derived_label "$ID")
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
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
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
    echo "label=$SECONDMATE_LABEL"
  fi
} > "$STATE/$ID.meta"
# The window is recorded now, so cleanup can find it: the span the settle-abort
# handler exists to cover has genuinely ended here.
SETTLE_ABORT_CLEANUP=0
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
NAMEFLAG=
if [ "$KIND" = secondmate ]; then
  NAMEFLAG=$(name_flag_for_harness "$HARNESS" "$SECONDMATE_LABEL")
fi
LAUNCH=${LAUNCH//__MODELFLAG__/"$MODELFLAG"}
LAUNCH=${LAUNCH//__EFFORTFLAG__/"$EFFORTFLAG"}
LAUNCH=${LAUNCH//__NAMEFLAG__/"$NAMEFLAG"}
LAUNCH=${LAUNCH//__BRIEF__/"$sq_brief"}
LAUNCH=${LAUNCH//__TURNEND__/"$sq_turnend"}
LAUNCH=${LAUNCH//__PIEXT__/"$sq_piext"}
LAUNCH=${LAUNCH//__PITURNEND__/"$sq_piturnend"}
LAUNCH=${LAUNCH//__PIWATCH__/"$sq_piwatch"}
LAUNCH=${LAUNCH//__OPINPUT__/"$sq_opinput"}
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
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
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
