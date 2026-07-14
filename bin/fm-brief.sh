#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab] [--base <branch>]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --base <branch> declares a non-default intended base branch for a ship task in
#   a PR-based mode (no-mistakes or direct-PR). HERE IT ONLY SHAPES THE BRIEF: it
#   roots the branch step on that base and writes the mode-specific path to a
#   correctly based PR. IT RECORDS NO STATE. state/<task-id>.meta is the single
#   source of truth for a task's base, and bin/fm-spawn.sh writes it - so pass the
#   SAME --base <branch> to fm-spawn.sh, which records base=. fm-pr-check.sh then
#   guards the PR's base before merge; its header owns that contract in full.
#   THE CREWMATE ASKS THE SAME QUESTION THE SCRIPTS ASK, AND ADJUDICATES NOTHING. A base
#   can stop being live between the writing of this brief and the run - the base lands
#   first and the child follows is the normal order of a stack - so the brief carries
#   fm-base-lib.sh's fm_base_liveness_brief_block: the crewmate's form of the one liveness
#   question (is `<base>` still on origin, and does it still carry anything the default
#   branch lacks), with a followable instruction for every answer. Only `live` lets the
#   crewmate proceed; absorbed, gone, and cannot-tell are each a distinct `blocked:` line
#   and a stop, so firstmate decides. It is asked twice - before the branch is rooted, and
#   again before a PR is pointed at the base.
#   It is never read off a command's exit status. A gone branch, an unfetchable default
#   branch, and an unreachable origin all fail identically, and an infrastructure failure
#   reported as a merged base is how a feature branch's unmerged work reaches the default
#   branch.
#   direct-PR opens the PR against the base directly (gh-axi pr create --base).
#   no-mistakes cannot be told a base: the pipeline always rebases onto the repo
#   default branch and opens the PR against it. So the brief has the crewmate
#   retarget the PR's base after it opens (gh-axi pr edit --base), which the
#   pipeline's monitor picks up - it re-rebases onto the new base and force-pushes.
#   The guard is what makes a wrong-based PR impossible to merge unnoticed.
#   The value must be a valid, non-empty git branch name that does not begin
#   with '-'. Rejected for --scout, --secondmate, and local-only mode; absent
#   means the repo default branch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
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

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-base-lib.sh
. "$SCRIPT_DIR/fm-base-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
BASE=
BASE_DECLARED=0
POS=()
want_base=
for a in "$@"; do
  if [ -n "$want_base" ]; then
    # A flag here means the branch name was omitted; consuming it silently would
    # record "--scout" as the base and drop the flag.
    case "$a" in
      -*) echo "error: --base requires a branch name, but got the flag '$a'" >&2; exit 1 ;;
    esac
    BASE=$a; BASE_DECLARED=1; want_base=; continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --base) want_base=1 ;;
    --base=*) BASE=${a#--base=}; BASE_DECLARED=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_base" ] || { echo "error: --base requires a value" >&2; exit 1; }
# --base declares a non-default intended base and only makes sense for a ship task
# in a PR-based mode. Reject it for scout/secondmate here; the local-only rejection
# happens once the delivery mode is resolved below. The branch name is validated
# up front because it reaches git as a refspec in fm-pr-check.sh and
# fm-review-diff.sh, where a leading dash would be read as an option.
# The specific cases below precede the shared predicate only to name the exact
# failure; fm_base_valid_branch_name is the rule the consumers re-assert on the
# way out of meta, so the two can never drift.
if [ "$BASE_DECLARED" -eq 1 ]; then
  [ -n "$BASE" ] || { echo "error: --base requires a non-empty branch name" >&2; exit 1; }
  case "$BASE" in
    -*) echo "error: --base branch name must not begin with '-': '$BASE'" >&2; exit 1 ;;
    *[[:space:]]*) echo "error: --base branch name must not contain whitespace: '$BASE'" >&2; exit 1 ;;
  esac
  fm_base_valid_branch_name "$BASE" \
    || { echo "error: --base is not a valid git branch name: '$BASE'" >&2; exit 1; }
  [ "$KIND" = ship ] || { echo "error: --base applies only to ship tasks, not --scout or --secondmate" >&2; exit 1; }
fi
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
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
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
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

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
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

# A non-default intended base only fits a PR-based mode. local-only has no remote
# and merges into local main, so reject --base there. When accepted, root the
# branch step on that base and add the Setup note that keeps the crewmate off the
# default branch. This writes no state: fm-spawn.sh --base owns the durable record
# (state/<id>.meta), so the same flag must be passed there too.
BASE_SETUP=""
# The crewmate asks the SAME liveness question the scripts ask - is `<base>` still on origin,
# and does it still carry anything the default branch lacks - and acts on the answer, with a
# followable instruction for every answer it can get back. bin/fm-base-lib.sh owns both forms
# of that question (fm_base_liveness for the scripts, fm_base_liveness_brief_block for the
# crewmate), so the crewmate and the merge gate cannot come to different conclusions about one
# base, and a base's state is never read off a command that happened to fail.
BASE_STATE_BLOCK=""
BRANCH_STEP="1. First action: create your branch: \`git checkout -b fm/$ID\`"
if [ -n "$BASE" ]; then
  if [ "$MODE" = local-only ]; then
    echo "error: --base does not apply to local-only mode (no remote or PR; merges into local main)" >&2
    exit 1
  fi
  BASE_META=$(shell_quote "$STATE/$ID.meta")
  BASE_STATE_BLOCK=$(fm_base_liveness_brief_block "$BASE")
  # The relaunch check comes FIRST. The base fetch exists only to ROOT a new branch, so a
  # relaunched task does not need it - and a relaunch is exactly when the base is most likely
  # to have merged, because a base landing mid-flight is the normal end-state of a stacked PR.
  # Ordered the other way, a crewmate reading top-down would fetch, fail, and report `blocked:`
  # on a task whose PR may be perfectly mergeable - the recovery bin/fm-spawn.sh deliberately
  # permits, dead-ended one step later by its own brief.
  BRANCH_STEP="1. First action: get onto your \`fm/$ID\` branch.

   If \`fm/$ID\` already exists (\`git rev-parse --verify --quiet fm/$ID\` prints a commit), this task has been RELAUNCHED: check it out with \`git checkout fm/$ID\` and carry on with the work already on it. It is already rooted where it belongs, so you do not need \`$BASE\` to resume and the rest of this step does not apply - skip to the next one.

   Otherwise this is a fresh start. Ask what state \`$BASE\` is in FIRST - the **Base branch** section below has the commands and what each answer means - and act on the answer it gives you. Only \`live\` means you root on it; every other answer is a \`blocked:\` line and a stop.
   Once it reads live, create the branch rooted on \`$BASE\` - NOT on the default branch this worktree starts on.
   \`\`\`
   git fetch origin $BASE && git checkout -b fm/$ID FETCH_HEAD
   \`\`\`"
  # The Setup note and the definition of done must not disagree about whether the branch
  # may end up rebased onto the default branch. Under direct-PR the crewmate owns the
  # branch end to end, so "never rebase onto the default" is the whole truth. Under
  # no-mistakes the pipeline WILL rebase it onto the default branch and there is no way to
  # stop it, so saying "never" here would read as a violation the moment the pipeline runs
  # and would send the crewmate to `blocked:` instead of to the retarget it is supposed to
  # perform. State that once, and let the definition of done own the recovery.
  BASE_ARMED="Firstmate's pre-merge base guard only runs when this task's meta records the base. Confirm it once, before you start: \`grep -qxF 'base=$BASE' $BASE_META\`. If that does not match, the guard is NOT armed and nothing would catch a wrong-based PR - append \`blocked: intended base $BASE is not recorded in this task's meta\` and stop."
  # The marker line bin/fm-spawn.sh requires before it will launch a task whose meta declares
  # this base. bin/fm-base-lib.sh owns its text, so the brief that writes it and the spawn that
  # reads it cannot drift apart.
  BASE_MARKER=$(fm_base_brief_marker "$BASE")
  if [ "$MODE" = direct-PR ]; then
    BASE_SETUP="

**Base branch.** $BASE_MARKER
Step 1 roots your \`fm/$ID\` branch on \`$BASE\`; keep it there and never rebase it onto the default branch yourself.
You open the PR against \`$BASE\` yourself - see the definition of done.
Firstmate refuses to record or merge a PR whose head is not rooted in \`$BASE\`'s history, or whose base label is not \`$BASE\`.

$BASE_STATE_BLOCK

$BASE_ARMED"
  else
    BASE_SETUP="

**Base branch.** $BASE_MARKER
Step 1 roots your \`fm/$ID\` branch on \`$BASE\`, and you must never rebase it onto the default branch by hand.
The no-mistakes pipeline WILL rebase it onto the default branch and open the PR there; it cannot be told a base. That is expected, it is not a failure, and it is not yours to fight.
The definition of done below owns what to do about it, and you are not done until you have done it.

$BASE_STATE_BLOCK

$BASE_ARMED"
  fi
fi

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.
EOF
)
    [ -z "$BASE" ] || DOD="$DOD

Before you open the PR, re-ask what state \`$BASE\` is in (the **Base branch** section's commands) and act on that answer, not on whether a command failed. A base merges most often exactly while its child is in flight, so the answer can differ from the one you got at step 1.
Only \`live\` means you open the PR against \`$BASE\`: \`gh-axi pr create --base $BASE ...\`, not against the repo default.
Any other answer means the matching \`blocked:\` line from that section and a stop. Do not retarget the PR at the default branch on your own judgement; a base that is not live is firstmate's call."
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    # A based task has one more gate than the stock flow, and both the gate and
    # the stricter done condition must sit BEFORE the "You are finished."
    # terminator: an instruction placed after it is one the crewmate stops
    # before reaching, so it would report done on a still-default-based PR and
    # stall on the pre-merge refusal.
    NM_BASE_SECTION=""
    NM_DONE="After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished."
    if [ -n "$BASE" ]; then
      NM_BASE_SECTION="## Base branch \`$BASE\` - required before you are done
$BASE_MARKER
The pipeline cannot be told a base: it always rebases onto the repo default branch and opens the PR against it. Do not try to talk it out of that, and do not hand-rebase mid-run.
Instead, let the PR open as it will, then retarget it once it exists.
First re-ask what state \`$BASE\` is in (the **Base branch** section in Setup has the commands and what each answer means) and act on that answer, not on whether a command failed. A base merges most often exactly while its child is in flight, so the answer can differ from the one you got at step 1.
Only \`live\` means you retarget: \`gh-axi pr edit {n} --base $BASE\`.
The pipeline's monitor picks the new base up, re-rebases your branch onto \`$BASE\`, and force-pushes a clean head; you do not rebuild anything by hand.
Then confirm \`gh-axi pr view {n} --json baseRefName\` reports \`$BASE\`.
Any other answer means the matching \`blocked:\` line from that section and a stop - leave the PR where the pipeline opened it, and do not decide for yourself what became of \`$BASE\`. A base that is not live is firstmate's call, and a wrong-based PR is refused before merge, so nothing slips through while you wait.
If the base reads live but the retarget or the re-rebase simply does not take, append \`blocked: PR still based on the default branch, not $BASE\` and stop; it will not slip through either - it will just sit.

"
      NM_DONE="This task is done only when BOTH hold: /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), AND the base branch section above is satisfied - \`gh-axi pr view {n} --json baseRefName\` reports \`$BASE\`, unless that section had you stop with a \`blocked:\` line because \`$BASE\` is no longer live, in which case you have already stopped and firstmate decides.
Reporting \`done\` while the PR is still based on the default branch is not done: it is refused before merge and will just sit.
When you are done, append \`done: PR {url} checks green\` and stop. You are finished."
    fi
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

$NM_BASE_SECTION$NM_DONE
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$BRANCH_STEP$SETUP2$BASE_SETUP

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
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
[ -z "$BASE" ] || echo "note: this brief only TELLS the crewmate about base '$BASE'; the durable record lives in meta, so spawn with the same flag or the PR-base guard never runs: fm-spawn.sh $ID <project> --base $BASE"
