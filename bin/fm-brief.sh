#!/usr/bin/env bash
# Scaffold one concise crewmate brief or persistent secondmate charter.
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
# --scout produces a report-only scratch-worktree contract.
# --secondmate uses FM_SECONDMATE_CHARTER and optional FM_SECONDMATE_SCOPE.
# --no-projects declares a firstmate-repo domain with no separate project clones.
# --herdr-lab is required for any task that drives Herdr lifecycle behavior.
# Ship delivery mode comes from data/projects.md through fm-project-mode.sh.
# Exact status, safety, report, and definition-of-done text is generated here so
# task briefs add only their result, acceptance criteria, constraints, and context.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

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

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-report-contract-lib.sh
. "$SCRIPT_DIR/fm-report-contract-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
FM_HOME_ARG=$(shell_quote "$FM_HOME")
NM_REATTACH_HELPER=$(shell_quote "$FM_ROOT/bin/fm-no-mistakes-reattach.sh")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crewmates take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crewmates take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate.
Own routed outcomes through delivery and cleanup; do not invent work.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
Your isolated home's \`AGENTS.md\` is your job description, and its private state and projects are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work through the normal firstmate lifecycle and keep one live owner until each routed outcome is finished.
Act only on tasks the main firstmate routes to you; never spawn a survey, audit, or any self-directed work.

# Requests and replies
A leading \`$FM_FROMFIRST_LABEL\` marker identifies a request from the main firstmate.
Return a marked request through the status path below, using a durable home-local document plus a status pointer when the answer is detailed; a chat-only reply is lost.
An unmarked message is direct captain input: answer it conversationally and treat it as authoritative.

# Escalation to main firstmate
Append one sparse actionable line with \`echo "{state}: {one short line}" >> $STATUS_FILE\`.
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` only for a known external wait expected to clear on its own.
Before \`blocked:\`, recursively exhaust safe in-scope routes while unaffected work continues.
Append \`resolved: {how}\` with the same optional \`[key=<slug>]\` when a decision or blocker clears.
Routine progress, retries, supervision, and child churn stay inside this home.

# Definition of done
You are persistent and do not exit for an empty queue.
On startup, run normal firstmate bootstrap and recovery only to RECONCILE work that is already yours through \`bin/fm-session-start.sh\`.
With no assigned or active work, go idle and wait silently for the main firstmate.
If the charter is impossible after safe routes are exhausted, append a narrow evidence-backed \`blocked:\` or \`failed:\` line.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

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
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker managed by firstmate.
Own the requested outcome; do not wait unless only a human decision or proven external blocker remains.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable scratch worktree of $REPO on a clean default base.
This is a SCOUT task: produce a report, never a PR.
Only the report survives cleanup, so put every durable finding in it.

# Rules
1. Never push or open a PR.
2. Write only inside this worktree plus the report and status paths below.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
4. Append only actionable status with \`echo "{state}: {one short line}" >> $STATUS_FILE\`.
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Use \`$PAUSED_VERB: {why}\` only for a known external wait expected to clear on its own.
5. Treat a blocker recursively: try safe in-scope alternatives while unaffected work continues, and use \`blocked:\` only when captain or firstmate action is required or materially independent safe routes are exhausted with evidence.
6. Use \`needs-decision:\` only for a human-owned choice, then append matching \`resolved: {how}\` with the same optional \`[key=<slug>]\` when work resumes.

# Definition of done
Write a standalone \`$DATA/$ID/report.md\` with level-two Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups sections.
Include the conclusion, evidence, file references, and recommendation.
Append \`done: {one-line conclusion}\` only after the report is complete.
If implementation should follow, recommend promotion in the report rather than changing delivery mode yourself.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

USABILITY_CONTRACT=$(cat <<'EOF'
Before completion, exercise the real user-visible path when the change has one.
Tests and screenshots prove execution, not usability; verify the actual outcome end to end.
If the real path cannot be exercised, report that limit plainly and do not claim it verified.
EOF
)

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
Commit the implementation on your branch.
$USABILITY_CONTRACT
Push the branch, open a PR with \`gh-axi\`, append \`done: PR {url}\`, and remain available for corrections.
Do not run no-mistakes; the captain owns merge approval.
EOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push or open a PR. Work only on \`fm/$ID\`; firstmate owns the approved local merge."
    DOD=$(cat <<EOF
# Definition of done
Commit the implementation on \`fm/$ID\` without pushing, opening a PR, or merging.
$USABILITY_CONTRACT
Rebase onto an advanced default branch when needed to preserve a clean fast-forward.
Append \`done: ready in branch fm/$ID\` and remain available for review corrections.
EOF
)
    ;;
  *)
    SETUP2="
2. Run \`no-mistakes doctor\`; run \`no-mistakes init\` only when this worktree is not initialized."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
Commit the implementation on your branch.
$USABILITY_CONTRACT
Append \`done: {summary}\` for focused implementation review by firstmate, and do not start no-mistakes until firstmate instructs you.
Once validation starts, own every synchronous gate return through CI green, failure with evidence, or a new decision.
Use the loaded no-mistakes skill, current \`axi run --help\`, and response \`help\` for mechanics.
Do not hand-edit or commit around pipeline-owned fixes, answer your own ask-user finding, or use \`--yes\`.
After an ask-user decision returns, send it through \`no-mistakes axi respond\` and continue the same run.
At the first CI-green return, append \`done: PR {url} checks green\`; do not wait for merge monitoring.
EOF
)
    ;;
esac

REPORT_CONTRACT=$(fm_completion_report_contract "$DATA" "$ID")

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker managed by firstmate.
Own the requested outcome through implementation and proof; do not wait unless only a human decision or proven external blocker remains.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable worktree of $REPO on a clean detached default base.
Before branching, run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must name this isolated task worktree, not firstmate's primary checkout.
The path check is authoritative; Git-dir paths do not prove isolation.
If isolation fails, do not branch or edit; append \`blocked: launched in primary checkout, not an isolated worktree\` and stop.
Run \`git checkout -b fm/$ID\` as your first project change.$SETUP2

# Rules
$RULE1
2. Write only inside this worktree plus the authorized completion-report and status paths.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
4. Append only actionable status with \`echo "{state}: {one short line}" >> $STATUS_FILE\`.
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Use \`$PAUSED_VERB: {why}\` only for a known external wait expected to clear on its own, never for active validation.
5. Treat blockers recursively: try safe in-scope alternatives while unaffected work continues, and use \`blocked:\` only when firstmate action is required or materially independent safe routes are exhausted with evidence.
6. Use \`needs-decision:\` only for a human-owned choice, then append matching \`resolved: {how}\` with the same optional \`[key=<slug>]\` when work resumes.
7. Never stop, restart, or update the shared no-mistakes daemon.
   For the exact reconciliation socket-read timeout, run \`FM_HOME=$FM_HOME_ARG $NM_REATTACH_HELPER $ID\`; append \`blocked:\` only if it exhausts retries or a different daemon error remains.

$REPORT_CONTRACT

# Project memory
When durable project-intrinsic knowledge exists or agent-memory files already exist, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` and update \`AGENTS.md\` proportionally.
Keep only knowledge useful to almost every future project session and point to authoritative code or docs instead of copying mechanics.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
