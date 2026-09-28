#!/usr/bin/env bash
# Scaffold a crewmate brief at data/<task-id>/brief.md under the active
# Firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Ship and scout `# Task` sections have two subsections Firstmate
# fills before dispatch: `{TASK}` under `## Captain's intent` (the captain's
# own ask plus the context needed to read it, including the substance of any
# report, decision, or PR the ask refers to, without added speaker labels or
# direct address) and `{FIRSTMATE_SPEC}`
# under `## Firstmate spec` (build instructions, including the intended outcome,
# observable acceptance evidence, allowed scope and exclusions, and hard-block
# stop condition, which are never the captain's intent). bin/fm-dod-lib.sh owns the no-mistakes `--intent` contract those
# subsections feed; bin/fm-spawn.sh refuses leftover placeholders and a
# `## Captain's intent` line opening with a Captain label or address. Firstmate may adjust other
# sections when the task genuinely deviates (e.g. working an existing external
# PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab]
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   Scout findings are delivered through the durable report and ordinary chat.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} and {FIRSTMATE_SPEC} are filled
#   after scaffolding and the caller-supplied repo string cannot reliably
#   identify this repo. Briefs made without it carry a loud declaration so an
#   omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  ordinary: implement -> /no-mistakes pipeline -> PR -> configured merge authority;
#                deployable ByteDance BITS/PPE: use the accepted task's bits-development
#                sequence before its final limited /no-mistakes pass
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --mode is refused on scout scaffolds because a scout's deliverable is a report
# rather than a merge.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/fm-task-inbox-lib.sh).
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and defers self-governance recognition and insertion to
# fm-ensure-agents-md.sh's contract.
# Scaffolds carry no role scope: fm-spawn.sh supplies fm_brief_worker_role from
# fm-dod-lib.sh to every ship/scout launch brief, so this file never becomes a
# second owner of a contract that must stay current across relaunches.
# Refuses to overwrite an existing brief.
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

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

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

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
MODE=
MODE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) echo "error: --secondmate is no longer supported" >&2; exit 2 ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) echo "error: --no-projects is no longer supported" >&2; exit 2 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report rather than a merge" >&2
  exit 1
fi
ID=${POS[0]}

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

ASK_USER_BLOCK=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  ASK_USER_BLOCK=$(fm_ask_user_escalation_block "$DATA" "$ID")
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/fm-task-inbox-lib.sh; the doorbell itself is self-describing,
# so this section is reinforcement for the natural-checkpoint habit, not the
# only carrier of the instruction.
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Firstmate instruction inbox
Firstmate steers you through durable message files in $INBOX_DIR.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list $INBOX_DIR/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: \`mv $INBOX_DIR/NNN.msg $INBOX_DIR/handled/\`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no inbox action and does not replace progress on the goal in your task brief.
EOF
INBOX_SECTION=${INBOX_SECTION%$'\n'}

REPO=${POS[1]}
REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

IFS= read -r -d '' TASK_SECTION <<'EOF' || true
# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}
EOF
TASK_SECTION=${TASK_SECTION%$'\n'}

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

$TASK_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. When you know when the wait clears, say so in the line with
   \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) and firstmate rechecks at that time instead.
   Use \`blocked:\` when you are stuck and need help.
5. If an attempt fails, use its evidence to choose a genuinely different authorized diagnostic or recovery path rather than rerunning it indefinitely.
   If the same obstacle remains after bounded retries and that different path, append \`blocked: {what remains, what you tried, and what is needed next}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs; only firstmate
   manages the daemon.
   Before you append \`blocked:\` about the pipeline, run \`no-mistakes daemon status\` and
   \`no-mistakes axi status\`. If the daemon socket refuses connections or is missing, append
   \`blocked: {the daemon error}\` and stop even when the local run record still says running or
   fixing, because that record can be stale after the daemon exits. A run record failed with a
   daemon error is also a real block.
   Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
   going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
   the daemon accepts \`respond\` immediately and runs the round in the background, so a killed or
   timed-out call was only waiting for a read while the run kept working.

$INBOX_SECTION

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Deliver findings through the durable report and ordinary chat; do not require a separate presentation service.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any structured review.
Report existence is not objective acceptance: before reporting done, verify that the report's evidence satisfies the intended outcome and acceptance checks in the task brief.
When that evidence is complete, append \`done: {one-line conclusion}\` to the status file and stop so firstmate can perform semantic acceptance and archive completed research automatically after the unresolved-decision gate.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK} and {FIRSTMATE_SPEC})"
exit 0
fi

# Ship task: shape Setup / Rule 1 by this task's explicit delivery mode, validated
# above, and render the Definition of done from its single owner, bin/fm-dod-lib.sh,
# which bin/fm-promote.sh renders too so a promoted scout receives the same contract.
# The block opens with the fixed "Delivery contract: mode=<mode>" line that
# bin/fm-spawn.sh checks against its own explicit --mode before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    ;;
  local-only)
    SETUP2=""
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    ;;
esac
RULE1=$(fm_ship_rule_one "$MODE" "$ID") || exit 1
DOD=$(fm_dod_block "$MODE" "$ID") || exit 1

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

$TASK_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If an attempt fails, use its evidence to choose a genuinely different authorized diagnostic or recovery path rather than rerunning it indefinitely.
   If the same obstacle remains after bounded retries and that different path, append \`blocked: {what remains, what you tried, and what is needed next}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
$ASK_USER_BLOCK
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs; only firstmate
   manages the daemon.
   Before you append \`blocked:\` about the pipeline, run \`no-mistakes daemon status\` and
   \`no-mistakes axi status\`. If the daemon socket refuses connections or is missing, append
   \`blocked: {the daemon error}\` and stop even when the local run record still says running or
   fixing, because that record can be stale after the daemon exits. A run record failed with a
   daemon error is also a real block.
   Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
   going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
   the daemon accepts \`respond\` immediately and runs the round in the background, so a killed or
   timed-out call was only waiting for a read while the run kept working.

$INBOX_SECTION

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\`, follow \`$FM_ROOT/bin/fm-ensure-agents-md.sh\`'s self-governance contract in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK} and {FIRSTMATE_SPEC})"
