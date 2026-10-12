#!/usr/bin/env bash
# fm-propel.sh - the bounded Beads propulsion dispatcher (small change controller,
# not a scheduler). Usage: bin/fm-propel.sh [--emit-wakes] [--only-tasks=<id>[,<id>...]]
# docs/propel.md owns the state machine this header cross-references:
#   DISCOVER -> FILTER -> CLASSIFY -> ASSIGN -> RECURSE -> TIME GATES.
# DISCOVER: home-ready beads (config/propel-beads-dir names the home's .beads
# working directory; default: the FM_HOME itself when it holds .beads),
# intersected with $FM_BOARD (default /Users/jubin/Git/jubin-marut/beads) so the
# shared board's dependency graph and captain beads stay authoritative.
# FILTER: drop beads whose status the board does not call ready (bd ready
# already excludes blocked/deferred/in-progress), whose title is already In
# flight in this home's backlog, whose roster pane is known blocked, or that a
# matching state/<task-id>.meta proves is under way in any home.
# CLASSIFY: captain-class beads (label captain) are surfaced as captain
# decision lines in the plan, never dispatched; ship and scout classes pair
# with an accountable assignee.
# ASSIGN: prefer an idle registered roster pane, then a registered secondmate
# whose scope names the bead's domain (data/secondmates.md), then at most one
# fresh crewmate spawn per run - and only when bin/fm-quota-choose.sh agrees a
# codex or claude window still has measured headroom. Project and machine
# capacity come from config/project-capacity through bin/fm-project-capacity-lib.sh.
# RECURSE: when a bead's board deps name an open blocker, the blocker is the
# actionable item, never the waiter.
# TIME GATES: deferred beads (bd status deferred or defer_until) are external
# waits; --emit-wakes records one fm-inbox note per fresh gate surface.
# SAFETY: read-only against every board and home registry; the only writes are
# state/.propel-plan.json (mode 0600) and the durable wake notes under
# --emit-wakes. Unknown data anywhere makes the verdict `unknown` and emits no
# dispatch at all - never a guessed assignment, never a spawn that pretends a
# capacity gate is an external wait.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
BOARD="${FM_BOARD:-/Users/jubin/Git/jubin-marut/beads}"
PLAN_TMP=

usage() {
  printf 'usage: fm-propel.sh [--emit-wakes] [--only-tasks=<id>[,<id>...]]\n' >&2
  exit 2
}
die_unknown() { # <reason>
  printf 'error: %s\n' "$1" >&2
  exit 2
}
EMIT_WAKES=0 ONLY_TASKS=
for arg in "$@"; do
  case "$arg" in
    --emit-wakes) EMIT_WAKES=1 ;;
    --only-tasks=*) ONLY_TASKS=${arg#--only-tasks=} ;;
    -h|--help) printf 'usage: fm-propel.sh [--emit-wakes] [--only-tasks=<id>[,<id>...]]\n'; exit 0 ;;
    *) usage ;;
  esac
done
# PROJECT/ROOT environment from a no-mistakes or launch daemon run can pin bd's
# actor override or harness-emitted git vars (e.g. a cloned GIT_CONFIG_COUNT).
# The dispatcher reads only its own environment's answer; obvious
# harness-emitted or ambient BD_/BEADS_ or project pins are neutralized
# explicitly so a run cannot silently target the wrong store.
unset BEADS_DIR BD_ACTOR BD_DB BD_GOY BEADS_GOY GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 2>/dev/null || true

command -v bd >/dev/null 2>&1 || die_unknown 'bd is not on PATH'
command -v tasks-axi >/dev/null 2>&1 || die_unknown 'tasks-axi is not on PATH'
command -v jq >/dev/null 2>&1 || die_unknown 'jq is not on PATH'
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die_unknown 'state directory is unavailable'
[ -d "$BOARD/.beads" ] || die_unknown "shared board is unavailable: $BOARD"

umask 077
mkdir -p "$STATE/.propel-wake-gates" 2>/dev/null || true
PLAN="$STATE/.propel-plan.json"

run_bd() { # <cwd> <args...> - readonly sandbox read; silent on failure.
  local bd_cwd=$1
  shift
  (cd "$bd_cwd" && bd --readonly --sandbox "$@" 2>/dev/null)
}

# --- Discover ---------------------------------------------------------------
# The home's own board (when configured) is the discover surface; the captain's
# shared board is the dependency and captain-bead surface. FM_BOARD overrides
# the shared board so tests and scratch runs never touch the live one. When
# the home has no .beads at all, the shared board IS the discover surface.
HOME_BEADS_DIR=
if [ -f "$FM_HOME/config/propel-beads-dir" ]; then
  HOME_BEADS_DIR=$(head -1 "$FM_HOME/config/propel-beads-dir" 2>/dev/null | tr -d '[:space:]')
fi
[ -n "$HOME_BEADS_DIR" ] || { [ -d "$FM_HOME/.beads" ] && HOME_BEADS_DIR=$FM_HOME; }

READY_JSON='[]'
if [ -n "$HOME_BEADS_DIR" ]; then
  READY_JSON=$(run_bd "$HOME_BEADS_DIR" ready --limit 0 --json) || READY_JSON=
  printf '%s' "$READY_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die_unknown "bd ready against $HOME_BEADS_DIR did not return an issue array"
fi
OPEN_JSON=$(run_bd "$BOARD" list --status open --limit 0 --json) || OPEN_JSON=
printf '%s' "$OPEN_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_unknown 'bd list against the shared board did not return an issue array'
DEFERRED_JSON=$(run_bd "$BOARD" list --status deferred --limit 0 --json) || DEFERRED_JSON='[]'
printf '%s' "$DEFERRED_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || DEFERRED_JSON='[]'
if [ -z "$HOME_BEADS_DIR" ]; then
  # Home without its own board: the shared board drives ready work too.
  READY_JSON=$(run_bd "$BOARD" ready --limit 0 --json) || READY_JSON=
  printf '%s' "$READY_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die_unknown 'bd ready against the shared board did not return an issue array'
fi

# --- Evidence: backlog, roster, quota, pane-free ----------------------------
BACKLOG_TITLES=$(cd "$FM_HOME" && "$FM_ROOT/bin/fm-tasks-axi.sh" list --state in_flight 2>/dev/null \
  && "$FM_ROOT/bin/fm-tasks-axi.sh" list --state queued 2>/dev/null) || BACKLOG_TITLES=
ROSTER_JSON=
[ -f "$FM_ROOT/bin/fm-peer-roster.sh" ] \
  && ROSTER_JSON=$(FM_HOME=$FM_HOME "$FM_ROOT/bin/fm-peer-roster.sh" --json 2>/dev/null)
if [ -z "$ROSTER_JSON" ] || ! printf '%s' "$ROSTER_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  ROSTER_JSON='{"peers":[],"sources":{"herdr":"unknown","beads":"unknown","peers":"unknown"}}'
fi
QUOTA_SNAPSHOT=$(quota-axi 2>/dev/null) || die_unknown 'quota-axi default TOON is unavailable'
HARNESS_PICK=$(printf '%s\n' "$QUOTA_SNAPSHOT" | "$FM_ROOT/bin/fm-quota-choose.sh" --candidate codex --candidate claude 2>/dev/null) || HARNESS_PICK=

SECONDMATE_SCOPES=
[ -f "$FM_HOME/data/secondmates.md" ] \
  && SECONDMATE_SCOPES=$(grep -oE 'scope: [^;)]*' "$FM_HOME/data/secondmates.md" | cut -d: -f2-)

# --- Filter + Classify + Assign (one deterministic pass) ---------------------
# bin/fm-propel-policy-lib.py owns the classification, masking, and pairing
# rules; this script owns the tool reads, the plan publication, and the wakes.
PLAN_JSON=$(READY_JSON=$READY_JSON OPEN_JSON=$OPEN_JSON DEFERRED_JSON=$DEFERRED_JSON \
  BACKLOG_TITLES=$BACKLOG_TITLES ROSTER_JSON=$ROSTER_JSON HARNESS_PICK=$HARNESS_PICK \
  SECONDMATE_SCOPES=$SECONDMATE_SCOPES ONLY_TASKS=$ONLY_TASKS BOARD=$BOARD STATE=$STATE \
  python3 "$SCRIPT_DIR/fm-propel-policy-lib.py" 2>&1) || die_unknown "policy pass failed: $PLAN_JSON"
umask 077
if printf '%s' "$PLAN_JSON" | jq -e 'type == "object" and (.actions | type == "array")' >/dev/null 2>&1; then
  PLAN_TMP=$(mktemp "$STATE/.propel-plan.XXXXXX") || die_unknown 'cannot stage plan'
  if printf '%s\n' "$PLAN_JSON" > "$PLAN_TMP" && chmod 0600 "$PLAN_TMP"; then
    mv -f "$PLAN_TMP" "$PLAN" || die_unknown 'cannot publish plan'
  else
    die_unknown 'cannot publish plan'
  fi
else
  die_unknown "unexpected plan shape: ${PLAN_JSON:0:160}"
fi

VERDICT=$(printf '%s' "$PLAN_JSON" | jq -r '
  if ([.actions[]? | select(.kind != "skip" and .kind != "route-blocker")] | length) == 0
  then "idle - no dispatch warranted" else "actionable" end')
printf 'propel %s\n' "$VERDICT"
printf '%s' "$PLAN_JSON" | jq -r '.actions[] |
  "  \(.bead)\t\(.kind)\t\(.assignee // .reason // .decision // .blocker // .until // "-")"'

# Waking once per fresh surface: the plan print above is the dry-run surface;
# --emit-wakes publishes to stdout for the watcher check, keeping the output
# sparse so repeated polls print nothing at all.
[ "$EMIT_WAKES" -eq 1 ] || exit 0

printf '%s' "$PLAN_JSON" | jq -r '
  .actions[] | select(.kind == "captain") | "propel: captain decision \(.bead): \(.decision)"' | \
while read -r wake_line; do
  wake_key=$(printf '%s' "$wake_line" | cksum | awk '{print $1}')
  gate_file="$STATE/.propel-wake-gates/$wake_key"
  if [ ! -e "$gate_file" ]; then
    printf '%s\n' "$wake_line"
    : > "$gate_file" 2>/dev/null || true
  fi
done
printf '%s' "$PLAN_JSON" | jq -r '
  .time_gates[] | "propel: gate \(.bead) clears at \(.until) - \(.title)"' | \
while read -r wake_line; do
  wake_key=$(printf '%s' "$wake_line" | cksum | awk '{print $1}')
  gate_file="$STATE/.propel-wake-gates/$wake_key"
  if [ ! -e "$gate_file" ]; then
    printf '%s\n' "$wake_line"
    : > "$gate_file" 2>/dev/null || true
  fi
done
exit 0
