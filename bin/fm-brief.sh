#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--display-title <title>] [--scout]
#        fm-brief.sh <task-id> <repo-name> --scope-contract <scope.tsv>
#        fm-brief.sh <task-id> [--display-title <title>] --secondmate <project>...
#   --display-title sanitizes and persists a deterministic 1-28 character
#   presentation phrase at data/<task-id>/display-title for fm-spawn.sh.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-task-label-lib.sh
. "$SCRIPT_DIR/fm-task-label-lib.sh"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "brief creation" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
DISPLAY_TITLE=
DISPLAY_TITLE_SET=0
SCOPE_CONTRACT=
SCOPE_CONTRACT_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      display-title) DISPLAY_TITLE=$a; DISPLAY_TITLE_SET=1 ;;
      scope-contract) SCOPE_CONTRACT=$a; SCOPE_CONTRACT_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --display-title) want_value=display-title ;;
    --display-title=*) DISPLAY_TITLE=${a#--display-title=}; DISPLAY_TITLE_SET=1 ;;
    --scope-contract) want_value=scope-contract ;;
    --scope-contract=*) SCOPE_CONTRACT=${a#--scope-contract=}; SCOPE_CONTRACT_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
ID=${POS[0]}

if [ "$SCOPE_CONTRACT_SET" -eq 1 ]; then
  [ -n "$SCOPE_CONTRACT" ] || { echo "error: --scope-contract requires a value" >&2; exit 1; }
  [ "$KIND" = ship ] || { echo "error: --scope-contract is available only for ship tasks" >&2; exit 1; }
  "$SCRIPT_DIR/fm-scope-contract.sh" validate-spec "$SCOPE_CONTRACT" || exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"
if [ "$DISPLAY_TITLE_SET" -eq 1 ]; then
  DISPLAY_TITLE=$(fm_task_label_sanitize_phrase "$DISPLAY_TITLE") || exit 1
  [ -n "$DISPLAY_TITLE" ] || {
    echo "error: --display-title has no usable characters" >&2
    exit 1
  }
fi

publish_display_title() {
  [ "$DISPLAY_TITLE_SET" -eq 1 ] || return 0
  printf '%s\n' "$DISPLAY_TITLE" > "$DATA/$ID/display-title"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
LEASE_CHECKPOINT_FILE=$(shell_quote "$STATE/$ID.direct-pr-lease")
LEASE_CHECKPOINT_TMP_FILE=$(shell_quote "$STATE/$ID.direct-pr-lease.tmp")

COGNEE_BRIEF_RULES=$(cat <<'EOF'
# Cognee memory hints
Cognee is memory/context only. It is not proof, source of truth, durable archive, or action authority.
Official docs expose raw readback and session/model cost surfaces, but Firstmate still treats raw retention/source-authority guarantees and per-wrapper-call cost correlation as unproven.
Do not run automatic Cognee lookup for every task.
Use a Cognee hint only when this brief says all of these are true:
- Firstmate manually performed the lookup.
- The hint maps to a local manifest row or known local report.
- Firstmate reopened and checked the local source path before attaching it.
- The hint is labeled as memory/context only.
- The hint includes stale-risk and says live state still needs verification.
- `external_action_authorized=false`.

Never use raw Cognee answer text as proof.
Never use memory to authorize merge, deploy, cleanup, vendor/customer action, purchase, refresh, import, or deletion.
If a Cognee hint lacks a reopened local source path, ignore it and proceed from repo files, named local reports, live endpoints, GitHub state, service state, and canonical proof artifacts.
EOF
)

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
[ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project" >&2; exit 1; }
publish_display_title
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
PROJECT_LIST=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_LIST

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
The projects above are local clones for work you supervise; they are not an exclusive ownership claim.
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

$COGNEE_BRIEF_RULES

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Escalate only true captain-relevant outcomes by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, done, failed.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
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

if [ "$KIND" = scout ]; then
publish_display_title
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

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
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - one instance serves
   every lane/home, so restarting it can kill another lane's in-flight pipeline. On any
   no-mistakes daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages it.

$COGNEE_BRIEF_RULES

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
publish_display_title

STATUS_STATES="working, needs-decision, blocked, done, failed."
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    RULE2="2. Stay inside this worktree except for the status file, the task-specific Firstmate checkpoint at $LEASE_CHECKPOINT_FILE, and its exact stable temporary sibling at $LEASE_CHECKPOINT_TMP_FILE; modify nothing else outside it."
    STATUS_STATES="working, needs-decision, blocked, done, failed, plus the exact actionable post-conflict handoff PR ready: {url} checkpoint={checkpoint} task={task} workflow=post-conflict post_head={oid}."
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Before initial direct-PR publication:
1. Resolve exactly one validated \`PUSH_ENDPOINT\` from \`git remote get-url --push --all origin\`, including a configured \`remote.origin.pushurl\`; accept only one credential-free GitHub SSH or HTTPS endpoint with no query or fragment, and normalize it to \`CURRENT_REMOTE_REPO=owner/repo\` without \`.git\`. Define the portable helper \`fm_checkpoint_mode() { if [ "\$(uname)" = Darwin ]; then stat -f %Lp "\$1" 2>/dev/null; else stat -c %a "\$1" 2>/dev/null; fi; }\` in this fresh-shell prelude. Query the live default with \`git ls-remote --symref "\$PUSH_ENDPOINT" HEAD\`; require exactly one \`ref: refs/heads/<branch> HEAD\` symref and its matching HEAD OID, validate the short branch name, set \`CURRENT_BASE_REF=refs/heads/<branch>\`, \`CURRENT_BASE_BRANCH=<branch>\`, and \`DEFAULT=\$CURRENT_BASE_BRANCH\`, and require \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$CURRENT_BASE_REF"\` to return exactly that one base OID and set \`LIVE_BASE_OID\` to it. Lookup failure, missing or ambiguous symref or OID, multiple push endpoints, an unsupported URL, or ambiguity must append \`blocked: direct-PR endpoint or base identity lookup failed; checkpoint retained\` and stop. For a fresh workflow bind \`PUSH_ENDPOINT\` to that exact validated endpoint and set \`REMOTE_REPO=\$CURRENT_REMOTE_REPO\`, \`BASE_REF=\$CURRENT_BASE_REF\`, and \`BASE_BRANCH=\$CURRENT_BASE_BRANCH\`. Before every recovery, fetch, lease lookup, push, or PR lookup, repeat these live endpoint and symref lookups and require the exact endpoint, canonical repository, full base ref, and short base branch to equal the bound \`PUSH_ENDPOINT\`, \`REMOTE_REPO\`, \`BASE_REF\`, and \`BASE_BRANCH\`; endpoint retargeting, default-branch change, lookup failure, deletion, or ambiguity must append \`blocked: direct-PR endpoint or base identity changed; checkpoint retained\` and stop without cleanup. Set \`TASK_ID=$ID\`, \`FEATURE_REF=refs/heads/fm/$ID\`, \`BRANCH=fm/$ID\`, \`WORKFLOW=initial-publication\`, \`REPO_ID=\$(git rev-parse --path-format=absolute --git-common-dir)\`, \`LEASE_CHECKPOINT=$LEASE_CHECKPOINT_FILE\`, and \`LEASE_CHECKPOINT_TMP=\$LEASE_CHECKPOINT.tmp\`. Derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` when attached. An attached branch must equal \`BRANCH\`; a detached \`HEAD\` is allowed only when \`LEASE_CHECKPOINT\` exists and step 3 proves an active rebase for the bound branch and base. Otherwise append \`blocked: direct-PR requires attached branch fm/$ID\` and stop. This Firstmate-owned task state is outside the project worktree and Git index.
2. Validate the primary checkpoint before handling the stable task-specific temporary target. Reject a checkpoint that is a symlink, non-regular file, unexpectedly owned, not mode 0600 according to \`fm_checkpoint_mode "\$LEASE_CHECKPOINT"\`, or malformed by appending \`blocked: direct-PR lease checkpoint invalid; refusing recovery\` and stop. If \`LEASE_CHECKPOINT_TMP\` exists, reject it when it is a symlink, non-regular file, or unexpectedly owned; otherwise remove that exact same-task stale temporary file without parsing it, preserving the primary checkpoint. A valid checkpoint must contain exactly \`repo=\`, \`push_endpoint=\`, \`remote_repo=\`, \`base_ref=\`, \`base_branch=\`, \`task=\`, \`feature_ref=\`, \`branch=\`, \`workflow=\`, \`expected=\`, \`default_oid=\`, \`pre_head=\`, \`post_head=\`, \`pr_url=\`, \`phase=\`, and \`attempt=\`. Parse it only as data: read exactly one line for each literal key, split each line only at its first \`=\`, and assign \`CHECKPOINT_REPO\`, \`CHECKPOINT_PUSH_ENDPOINT\`, \`CHECKPOINT_REMOTE_REPO\`, \`CHECKPOINT_BASE_REF\`, \`CHECKPOINT_BASE_BRANCH\`, \`CHECKPOINT_TASK\`, \`CHECKPOINT_FEATURE_REF\`, \`CHECKPOINT_BRANCH\`, \`CHECKPOINT_WORKFLOW\`, \`CHECKPOINT_EXPECTED\`, \`CHECKPOINT_DEFAULT_OID\`, \`CHECKPOINT_PRE_HEAD\`, \`CHECKPOINT_POST_HEAD\`, \`CHECKPOINT_PR_URL\`, \`CHECKPOINT_PHASE\`, and \`CHECKPOINT_ATTEMPT\`; reject duplicate, missing, unknown, or invalid fields. Never source or eval checkpoint bytes. Require the checkpoint identities to equal \`REPO_ID\`, \`TASK_ID\`, \`FEATURE_REF\`, and \`BRANCH\`, require \`CHECKPOINT_PUSH_ENDPOINT == PUSH_ENDPOINT\`, \`CHECKPOINT_REMOTE_REPO == CURRENT_REMOTE_REPO\`, \`CHECKPOINT_BASE_REF == CURRENT_BASE_REF\`, and \`CHECKPOINT_BASE_BRANCH == CURRENT_BASE_BRANCH\`, and require \`CHECKPOINT_WORKFLOW=initial-publication\`; when \`HEAD\` is attached, also require freshly derived \`CURRENT_BRANCH == BRANCH\`. Otherwise append \`blocked: direct-PR lease checkpoint identity mismatch; refusing recovery\` and stop. After all validation, explicitly hydrate \`REPO_ID=\$CHECKPOINT_REPO\`, \`PUSH_ENDPOINT=\$CHECKPOINT_PUSH_ENDPOINT\`, \`REMOTE_REPO=\$CHECKPOINT_REMOTE_REPO\`, \`BASE_REF=\$CHECKPOINT_BASE_REF\`, \`BASE_BRANCH=\$CHECKPOINT_BASE_BRANCH\`, \`DEFAULT=\$CHECKPOINT_BASE_BRANCH\`, \`TASK_ID=\$CHECKPOINT_TASK\`, \`FEATURE_REF=\$CHECKPOINT_FEATURE_REF\`, \`BRANCH=\$CHECKPOINT_BRANCH\`, \`WORKFLOW=\$CHECKPOINT_WORKFLOW\`, \`EXPECTED=\$CHECKPOINT_EXPECTED\`, \`DEFAULT_OID=\$CHECKPOINT_DEFAULT_OID\`, \`PRE_HEAD=\$CHECKPOINT_PRE_HEAD\`, \`POST_HEAD=\$CHECKPOINT_POST_HEAD\`, \`PR_URL=\$CHECKPOINT_PR_URL\`, \`PHASE=\$CHECKPOINT_PHASE\`, and \`ATTEMPT=\$CHECKPOINT_ATTEMPT\` before any recovery action. Enforce the exact phase tuple before action: \`rebase-in-progress\` requires \`ATTEMPT=0\` and empty \`POST_HEAD\`; \`ready-to-push\` requires nonempty \`POST_HEAD\` and \`ATTEMPT\` 0, 1, or 2; \`push-exhausted\` requires nonempty \`POST_HEAD\` and \`ATTEMPT=2\`; \`published-awaiting-pr\` requires nonempty \`POST_HEAD\`, empty \`PR_URL\`, and \`ATTEMPT\` 0, 1, or 2; \`pr-check-pending\` and \`pr-check-confirmed\` each require nonempty \`POST_HEAD\`, canonical nonempty \`PR_URL\`, and \`ATTEMPT\` 0, 1, or 2. Every earlier phase requires empty \`PR_URL\`. Any other tuple must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. Fresh-shell rule: never rely on variables surviving a prior agent command call. Before every command invocation in steps 2-10, use that same invocation to repeat step 1 identity initialization and, when the checkpoint exists, this complete typed validation and hydration. Before the checkpoint exists, a fresh invocation in steps 4-7 must also replay every earlier state-producing fetch or lookup needed by that step. Rebase continuation, post-rebase checkpointing, publication, retry, cleanup, and PR opening each require the prelude in their own invocation.
3. On recovery, branch on \`PHASE\` before inspecting \`HEAD\`, reflogs, or active-rebase metadata. If \`PHASE=published-awaiting-pr\`, require the bound workflow, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD\` to equal the nonempty \`POST_HEAD\`, then enter the separate step 10 PR-reconciliation path directly; never enter step 9 or perform another push. If \`PHASE=pr-check-pending\`, require the bound workflow, attached branch, exact \`POST_HEAD\`, and canonical nonempty \`PR_URL\`, then stop for the Firstmate-owned artifact-reconciliation path; the worker must not run \`fm-pr-check\`, clean up, or emit \`done\`. If \`PHASE=pr-check-confirmed\`, require the same bound identity and enter only the step 10 receipt-finalization branch; never publish metadata or a poll again. If \`PHASE=push-exhausted\`, require \`ATTEMPT=2\`, the bound workflow, attached branch, and exact \`POST_HEAD\`; retain the checkpoint, append \`blocked: direct-PR publication retry exhausted; checkpoint retained\`, and stop without any automatic push. If \`PHASE=ready-to-push\`, require \`ATTEMPT\` to be 0, 1, or 2 and require \`WORKFLOW=initial-publication\`, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD\` to equal the nonempty \`POST_HEAD\`, then enter step 9 directly and execute its complete initial-publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, transition to published-awaiting-pr, and separate PR reconciliation, and the following single terminal completion or blocked status. Never perform only a bare push. Only when \`PHASE=rebase-in-progress\` may recovery inspect active-rebase metadata, \`HEAD\`, or reflogs; any other phase must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. In that rebase-in-progress branch, detect active rebase metadata before remote-movement cleanup. An active rebase is valid only when metadata records \`refs/heads/\$BRANCH\` as the original branch, \`PRE_HEAD\` as the original head, and \`DEFAULT_OID\` as the exact onto target; Git's expected detached \`HEAD\` is allowed only in that validated state, otherwise append \`blocked: active direct-PR rebase metadata mismatch\` and stop. Run \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` and classify its status: exit 0 supplies the remote OID, exit 2 means no matching ref, and any other status must append \`blocked: direct-PR lease recovery lookup failed\` and stop. The remote matches only when exit 0 supplies \`EXPECTED\`, or when exit 2 and \`EXPECTED\` is empty for this bound initial-publication workflow; every other exit 0 or 2 outcome is confirmed remote movement. If the remote moved during that validated active rebase, retain \`LEASE_CHECKPOINT\` and its bound state, append \`blocked: remote feature moved during active direct-PR rebase; checkpoint retained\`, and stop without cleanup or restart. If the remote moved with no active rebase, remove the validated checkpoint and its stable task-specific \`LEASE_CHECKPOINT_TMP\`, then restart safe validation from step 1. If the remote still matches, resume only the validated active rebase. With no active rebase, require attached \`CURRENT_BRANCH == BRANCH\`. When \`HEAD == PRE_HEAD\`, either use the complete sixteen-field atomic transition to preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, set \`post_head=\$PRE_HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`, write with mode 0600 through \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\` for a proven no-op where \`DEFAULT_OID\` is already an ancestor of \`HEAD\`; or safely restart \`git rebase "\$DEFAULT_OID"\` and perform that same complete ready-state transition after it completes. When \`HEAD\` differs, accept completed rebase recovery only when the latest metadata-bound matching rebase finish is the newest branch reflog entry, that finish result OID equals current \`HEAD\`, no later branch movement exists, the recorded branch equals \`BRANCH\`, the matching rebase transition's source OID equals \`PRE_HEAD\`, the matching rebase start names \`DEFAULT_OID\`, and \`DEFAULT_OID\` is an ancestor of \`HEAD\`. If the source OID differs from \`PRE_HEAD\`, the finish result differs from \`HEAD\`, or any later branch movement exists, append \`blocked: completed direct-PR rebase transition mismatch; refusing recovery\` and stop. Then use the complete sixteen-field atomic transition to preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, set \`post_head\` to that exact \`HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`, write with mode 0600 through \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. If that recovery rewrite fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR recovered ready checkpoint write failed\`, and stop without pushing. After any successful ready-state rewrite, start a fresh invocation with the required prelude and enter step 9. Any other detached state or head, workflow, branch, repository, task, ref, or onto mismatch must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. Do not rerun pre-rebase ancestry validation against rewritten \`HEAD\`.
4. Derive the task-scoped private refs \`PRIVATE_REF_ROOT=refs/firstmate/direct-pr/\$TASK_ID\`, \`BASE_FETCH_REF=\$PRIVATE_REF_ROOT/base\`, and \`FEATURE_FETCH_REF=\$PRIVATE_REF_ROOT/feature\`; their destination namespace is bound by the validated checkpoint to this task, repository, base, and feature identity and must not be shared with another task. Run \`git fetch "\$PUSH_ENDPOINT" "+\$BASE_REF:\$BASE_FETCH_REF"\`. Every base or feature private-ref fetch must exit zero, and its fetched OID must equal the immediately preceding live lookup OID before any \`rev-parse\`, rebase, lease, or ancestry use; otherwise append \`blocked: direct-PR private fetch failed or mismatched live lookup; private refs retained\` and stop.
5. Run \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` and inspect its exit status: 0 means the feature ref exists and sets \`LIVE_FEATURE_OID\` to that returned OID, 2 means it is absent, and any other status is a lookup failure that must append \`blocked: remote feature lookup failed\` and stop.
6. When the feature ref exists, run \`git fetch "\$PUSH_ENDPOINT" "+\$FEATURE_REF:\$FEATURE_FETCH_REF"\`, snapshot \`EXPECTED=\$(git rev-parse "\$FEATURE_FETCH_REF")\`, and require \`git merge-base --is-ancestor "\$EXPECTED" HEAD\`; fetch failure, fetched/live OID mismatch, or ancestry failure must append \`blocked: direct-PR feature fetch failed, stale, or divergent\` and stop before consuming stale state; if the ancestry check fails, append \`blocked: remote feature branch diverged; refusing to overwrite remote-only commits\` and stop. When exit 2 confirmed the feature ref is absent, set \`EXPECTED=\`.
7. Set \`DEFAULT_OID=\$(git rev-parse "\$BASE_FETCH_REF")\` and \`PRE_HEAD=\$(git rev-parse HEAD)\`, derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` again, and require \`CURRENT_BRANCH == BRANCH\`; detached \`HEAD\` or mismatch must append \`blocked: direct-PR branch changed before rebase\` and stop. Atomically write all sixteen bound fields, including \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, and \`base_branch=\$BASE_BRANCH\`, through \`LEASE_CHECKPOINT_TMP\` with mode 0600, \`workflow=initial-publication\`, \`default_oid=\$DEFAULT_OID\`, \`post_head=\` empty, \`pr_url=\` empty, \`phase=rebase-in-progress\`, and \`attempt=0\`, then rename it to \`LEASE_CHECKPOINT\`. A write or rename failure must remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR lease checkpoint write failed\`, and stop.
8. Rebase onto the immutable \`DEFAULT_OID\` with \`git rebase "\$DEFAULT_OID"\` and resolve ordinary conflicts. Set \`POST_HEAD=\$(git rev-parse HEAD)\`, derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` again, and require \`CURRENT_BRANCH == BRANCH\`; detached \`HEAD\` or mismatch must append \`blocked: direct-PR branch changed after rebase\` and stop. Atomically rewrite all sixteen bound fields through \`LEASE_CHECKPOINT_TMP\`, preserving \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, while setting \`post_head=\$POST_HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`. If this second write or rename fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR ready checkpoint write failed; recover from rebase-in-progress state\`, and stop without pushing.
9. Before publication, require \`WORKFLOW=initial-publication\`, \`PHASE=ready-to-push\`, \`ATTEMPT\` equal to 0, 1, or 2, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD == POST_HEAD\`; otherwise append \`blocked: direct-PR publication state changed; refusing push\` and stop. The checkpoint attempt is the total authorized push count across every invocation. Immediately before every remote classification or push, repeat the step 1 exact endpoint and live symref revalidation and retain the checkpoint on any blocker. Every attempt or exhaustion transition must atomically preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, \`pre_head=\$PRE_HEAD\`, and \`post_head=\$POST_HEAD\`, preserve \`pr_url=\$PR_URL\`, and change only the defined \`phase\` and \`attempt\`, write all sixteen validated fields with mode 0600 through stable \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. On any such write or rename failure, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, retain the primary checkpoint, append \`blocked: direct-PR publication checkpoint transition failed\`, and stop without pushing. Classify \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` as exit 0 with its OID, exit 2 with no ref, or any other status as \`blocked: remote feature retry lookup failed\` and stop. Exit 0 at \`POST_HEAD\` proves publication already succeeded; exit 0 at \`EXPECTED\`, or exit 2 only when \`EXPECTED\` is empty, means unchanged; every other exit 0 or 2 means movement. On movement, remove the validated checkpoint and stable task-specific \`LEASE_CHECKPOINT_TMP\`, then restart safe validation. For \`ATTEMPT=0\`, atomically rewrite the validated checkpoint with \`attempt=1\` and, after the rename succeeds, set \`ATTEMPT=1\` in memory before the first \`git push --force-with-lease="\$FEATURE_REF:\$EXPECTED" "\$PUSH_ENDPOINT" "\$POST_HEAD:\$FEATURE_REF"\`; a transition failure uses that cleanup and blocker without pushing. If that push fails or recovery starts with \`ATTEMPT=1\`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites \`attempt=2\` and, after the rename succeeds, sets \`ATTEMPT=2\` in memory before the second and final identical push. If that transition fails, use that cleanup and blocker without pushing. If the second push fails or recovery starts with \`ATTEMPT=2\`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites \`phase=push-exhausted\` with \`attempt=2\`, retains the checkpoint, appends \`blocked: direct-PR publication retry exhausted; checkpoint retained\`, and stops without another push. Recovery from \`PHASE=push-exhausted\` performs no remote lookup or automatic push and retains that blocker. After either push succeeds or remote classification proves \`POST_HEAD\` is published, atomically preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, \`pre_head=\$PRE_HEAD\`, \`post_head=\$POST_HEAD\`, and \`attempt=\$ATTEMPT\`, set \`pr_url=\` empty and \`phase=published-awaiting-pr\`, write all sixteen fields with mode 0600 through stable \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. If that write or rename fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, retain the durable prior checkpoint, append \`blocked: direct-PR published checkpoint transition failed; prior checkpoint retained\`, and stop before any PR action. Then enter step 10.
10. PR reconciliation is a separate \`PHASE=published-awaiting-pr\` path. Require \`WORKFLOW=initial-publication\`, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD == POST_HEAD\`. Immediately repeat the step 1 exact endpoint and live symref revalidation, then revalidate \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\`: exit 0 must return exactly \`POST_HEAD\`; exit 2 must append \`blocked: published direct-PR feature ref deleted; checkpoint retained\`; any other status must append \`blocked: published direct-PR feature lookup failed; checkpoint retained\`; and a different OID must append \`blocked: published direct-PR feature moved; checkpoint retained\`. Stop on every blocker without cleanup or PR creation. List PRs in all states using the exact filters repository \`REMOTE_REPO\`, head \`BRANCH\`, and base branch \`BASE_BRANCH\`, and require every match to have those exact repository, head, and base identities. Multiple matches or lookup failure must append \`blocked: direct-PR PR identity reconciliation failed; checkpoint retained\` and stop. If the sole match is closed or merged, append \`blocked: direct-PR PR is {url} ({state}); checkpoint retained\` and stop without creating a replacement. If the sole match is open, require its head OID to equal \`POST_HEAD\`; otherwise append \`blocked: direct-PR PR head moved; checkpoint retained\` and stop. With no match, open exactly one PR with \`gh-axi\`, then re-list all states and require exactly one open match whose head OID equals \`POST_HEAD\`; any create or confirmation failure appends \`blocked: direct-PR publication succeeded but PR reconciliation failed; checkpoint retained\` and stops. Only after one open PR is confirmed at \`POST_HEAD\` may the validated checkpoint and stable task-specific \`LEASE_CHECKPOINT_TMP\` be removed. Never create a replacement for a closed or merged PR.
Initial-publication finalization must preserve \`PR_URL=\` empty in every sixteen-field transition, require every private-ref fetch to exit zero and match its immediately preceding live OID before use, validate that \`PRIVATE_REF_ROOT\` contains only \`BASE_FETCH_REF\` and optional \`FEATURE_FETCH_REF\`, delete those exact refs in one \`git update-ref --stdin\` transaction, and only then remove checkpoint state; ambiguity or transaction failure retains the checkpoint and blocks.
If firstmate later tells you that parallel work made the open PR conflict, you still own reconciliation:
1. Resolve exactly one validated \`PUSH_ENDPOINT\` from \`git remote get-url --push --all origin\`, including a configured \`remote.origin.pushurl\`; accept only one credential-free GitHub SSH or HTTPS endpoint with no query or fragment, and normalize it to \`CURRENT_REMOTE_REPO=owner/repo\` without \`.git\`. Define the portable helper \`fm_checkpoint_mode() { if [ "\$(uname)" = Darwin ]; then stat -f %Lp "\$1" 2>/dev/null; else stat -c %a "\$1" 2>/dev/null; fi; }\` in this fresh-shell prelude. Query the live default with \`git ls-remote --symref "\$PUSH_ENDPOINT" HEAD\`; require exactly one \`ref: refs/heads/<branch> HEAD\` symref and its matching HEAD OID, validate the short branch name, set \`CURRENT_BASE_REF=refs/heads/<branch>\`, \`CURRENT_BASE_BRANCH=<branch>\`, and \`DEFAULT=\$CURRENT_BASE_BRANCH\`, and require \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$CURRENT_BASE_REF"\` to return exactly that one base OID and set \`LIVE_BASE_OID\` to it. Lookup failure, missing or ambiguous symref or OID, multiple push endpoints, an unsupported URL, or ambiguity must append \`blocked: direct-PR endpoint or base identity lookup failed; checkpoint retained\` and stop. For a fresh workflow bind \`PUSH_ENDPOINT\` to that exact validated endpoint and set \`REMOTE_REPO=\$CURRENT_REMOTE_REPO\`, \`BASE_REF=\$CURRENT_BASE_REF\`, and \`BASE_BRANCH=\$CURRENT_BASE_BRANCH\`. Before every recovery, fetch, lease lookup, push, or PR lookup, repeat these live endpoint and symref lookups and require the exact endpoint, canonical repository, full base ref, and short base branch to equal the bound \`PUSH_ENDPOINT\`, \`REMOTE_REPO\`, \`BASE_REF\`, and \`BASE_BRANCH\`; endpoint retargeting, default-branch change, lookup failure, deletion, or ambiguity must append \`blocked: direct-PR endpoint or base identity changed; checkpoint retained\` and stop without cleanup. Set \`TASK_ID=$ID\`, \`FEATURE_REF=refs/heads/fm/$ID\`, \`BRANCH=fm/$ID\`, \`WORKFLOW=post-conflict\`, \`REPO_ID=\$(git rev-parse --path-format=absolute --git-common-dir)\`, \`LEASE_CHECKPOINT=$LEASE_CHECKPOINT_FILE\`, and \`LEASE_CHECKPOINT_TMP=\$LEASE_CHECKPOINT.tmp\`. Derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` when attached. An attached branch must equal \`BRANCH\`; a detached \`HEAD\` is allowed only when \`LEASE_CHECKPOINT\` exists and step 3 proves an active rebase for the bound branch and base. Otherwise append \`blocked: direct-PR requires attached branch fm/$ID\` and stop. This Firstmate-owned task state is outside the project worktree and Git index.
2. Validate the primary checkpoint before handling the stable task-specific temporary target. Reject a checkpoint that is a symlink, non-regular file, unexpectedly owned, not mode 0600 according to \`fm_checkpoint_mode "\$LEASE_CHECKPOINT"\`, or malformed by appending \`blocked: direct-PR lease checkpoint invalid; refusing recovery\` and stop. If \`LEASE_CHECKPOINT_TMP\` exists, reject it when it is a symlink, non-regular file, or unexpectedly owned; otherwise remove that exact same-task stale temporary file without parsing it, preserving the primary checkpoint. A valid checkpoint must contain exactly \`repo=\`, \`push_endpoint=\`, \`remote_repo=\`, \`base_ref=\`, \`base_branch=\`, \`task=\`, \`feature_ref=\`, \`branch=\`, \`workflow=\`, \`expected=\`, \`default_oid=\`, \`pre_head=\`, \`post_head=\`, \`pr_url=\`, \`phase=\`, and \`attempt=\`. Parse it only as data: read exactly one line for each literal key, split each line only at its first \`=\`, and assign \`CHECKPOINT_REPO\`, \`CHECKPOINT_PUSH_ENDPOINT\`, \`CHECKPOINT_REMOTE_REPO\`, \`CHECKPOINT_BASE_REF\`, \`CHECKPOINT_BASE_BRANCH\`, \`CHECKPOINT_TASK\`, \`CHECKPOINT_FEATURE_REF\`, \`CHECKPOINT_BRANCH\`, \`CHECKPOINT_WORKFLOW\`, \`CHECKPOINT_EXPECTED\`, \`CHECKPOINT_DEFAULT_OID\`, \`CHECKPOINT_PRE_HEAD\`, \`CHECKPOINT_POST_HEAD\`, \`CHECKPOINT_PR_URL\`, \`CHECKPOINT_PHASE\`, and \`CHECKPOINT_ATTEMPT\`; reject duplicate, missing, unknown, or invalid fields. Never source or eval checkpoint bytes. Require the checkpoint identities to equal \`REPO_ID\`, \`TASK_ID\`, \`FEATURE_REF\`, and \`BRANCH\`, require \`CHECKPOINT_PUSH_ENDPOINT == PUSH_ENDPOINT\`, \`CHECKPOINT_REMOTE_REPO == CURRENT_REMOTE_REPO\`, \`CHECKPOINT_BASE_REF == CURRENT_BASE_REF\`, and \`CHECKPOINT_BASE_BRANCH == CURRENT_BASE_BRANCH\`, and require \`CHECKPOINT_WORKFLOW=post-conflict\`; when \`HEAD\` is attached, also require freshly derived \`CURRENT_BRANCH == BRANCH\`. Otherwise append \`blocked: direct-PR lease checkpoint identity mismatch; refusing recovery\` and stop. After all validation, explicitly hydrate \`REPO_ID=\$CHECKPOINT_REPO\`, \`PUSH_ENDPOINT=\$CHECKPOINT_PUSH_ENDPOINT\`, \`REMOTE_REPO=\$CHECKPOINT_REMOTE_REPO\`, \`BASE_REF=\$CHECKPOINT_BASE_REF\`, \`BASE_BRANCH=\$CHECKPOINT_BASE_BRANCH\`, \`DEFAULT=\$CHECKPOINT_BASE_BRANCH\`, \`TASK_ID=\$CHECKPOINT_TASK\`, \`FEATURE_REF=\$CHECKPOINT_FEATURE_REF\`, \`BRANCH=\$CHECKPOINT_BRANCH\`, \`WORKFLOW=\$CHECKPOINT_WORKFLOW\`, \`EXPECTED=\$CHECKPOINT_EXPECTED\`, \`DEFAULT_OID=\$CHECKPOINT_DEFAULT_OID\`, \`PRE_HEAD=\$CHECKPOINT_PRE_HEAD\`, \`POST_HEAD=\$CHECKPOINT_POST_HEAD\`, \`PR_URL=\$CHECKPOINT_PR_URL\`, \`PHASE=\$CHECKPOINT_PHASE\`, and \`ATTEMPT=\$CHECKPOINT_ATTEMPT\` before any recovery action. Enforce the exact phase tuple before action: \`rebase-in-progress\` requires \`ATTEMPT=0\` and empty \`POST_HEAD\`; \`ready-to-push\` requires nonempty \`POST_HEAD\` and \`ATTEMPT\` 0, 1, or 2; \`push-exhausted\` requires nonempty \`POST_HEAD\` and \`ATTEMPT=2\`; \`published-awaiting-pr\` requires nonempty \`POST_HEAD\`, empty \`PR_URL\`, and \`ATTEMPT\` 0, 1, or 2; \`pr-check-pending\` and \`pr-check-confirmed\` each require nonempty \`POST_HEAD\`, canonical nonempty \`PR_URL\`, and \`ATTEMPT\` 0, 1, or 2. Every earlier phase requires empty \`PR_URL\`. Any other tuple must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. Fresh-shell rule: never rely on variables surviving a prior agent command call. Before every command invocation in steps 2-10, use that same invocation to repeat step 1 identity initialization and, when the checkpoint exists, this complete typed validation and hydration. Before the checkpoint exists, a fresh invocation in steps 4-7 must also replay every earlier state-producing fetch or lookup needed by that step. Rebase continuation, post-rebase checkpointing, publication, retry, cleanup, and open-PR continuation each require the prelude in their own invocation.
3. On recovery, branch on \`PHASE\` before inspecting \`HEAD\`, reflogs, or active-rebase metadata. If \`PHASE=published-awaiting-pr\`, require the bound workflow, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD\` to equal the nonempty \`POST_HEAD\`, then enter the separate step 10 PR-reconciliation path directly; never enter step 9 or perform another push. If \`PHASE=pr-check-pending\`, require the bound workflow, attached branch, exact \`POST_HEAD\`, and canonical nonempty \`PR_URL\`, then stop for the Firstmate-owned artifact-reconciliation path; the worker must not run \`fm-pr-check\`, clean up, or emit \`done\`. If \`PHASE=pr-check-confirmed\`, require the same bound identity and enter only the step 10 receipt-finalization branch; never publish metadata or a poll again. If \`PHASE=push-exhausted\`, require \`ATTEMPT=2\`, the bound workflow, attached branch, and exact \`POST_HEAD\`; retain the checkpoint, append \`blocked: direct-PR publication retry exhausted; checkpoint retained\`, and stop without any automatic push. If \`PHASE=ready-to-push\`, require \`ATTEMPT\` to be 0, 1, or 2 and require \`WORKFLOW=post-conflict\`, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD\` to equal the nonempty \`POST_HEAD\`, then enter step 9 directly and execute its complete post-conflict publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, transition to published-awaiting-pr, separate open-PR reconciliation, a nonterminal Firstmate-owned readiness-check handoff, and the following single terminal completion after confirmation or blocked status. Never perform only a bare push. Only when \`PHASE=rebase-in-progress\` may recovery inspect active-rebase metadata, \`HEAD\`, or reflogs; any other phase must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. In that rebase-in-progress branch, detect active rebase metadata before remote-movement cleanup. An active rebase is valid only when metadata records \`refs/heads/\$BRANCH\` as the original branch, \`PRE_HEAD\` as the original head, and \`DEFAULT_OID\` as the exact onto target; Git's expected detached \`HEAD\` is allowed only in that validated state, otherwise append \`blocked: active direct-PR rebase metadata mismatch\` and stop. Run \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` and classify its status: exit 0 supplies the remote OID, exit 2 means no matching ref, and any other status must append \`blocked: direct-PR lease recovery lookup failed\` and stop. For this bound post-conflict workflow, the remote matches only when exit 0 supplies \`EXPECTED\`; exit 2 is confirmed remote deletion, and any different OID from exit 0 is confirmed remote movement. If the remote moved during that validated active rebase, retain \`LEASE_CHECKPOINT\` and its bound state, append \`blocked: remote feature moved during active direct-PR rebase; checkpoint retained\`, and stop without cleanup or restart. If the remote moved with no active rebase, remove the validated checkpoint and its stable task-specific \`LEASE_CHECKPOINT_TMP\`, then restart safe validation from step 1. If the remote still matches, resume only the validated active rebase. With no active rebase, require attached \`CURRENT_BRANCH == BRANCH\`. When \`HEAD == PRE_HEAD\`, either use the complete sixteen-field atomic transition to preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, set \`post_head=\$PRE_HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`, write with mode 0600 through \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\` for a proven no-op where \`DEFAULT_OID\` is already an ancestor of \`HEAD\`; or safely restart \`git rebase "\$DEFAULT_OID"\` and perform that same complete ready-state transition after it completes. When \`HEAD\` differs, accept completed rebase recovery only when the latest metadata-bound matching rebase finish is the newest branch reflog entry, that finish result OID equals current \`HEAD\`, no later branch movement exists, the recorded branch equals \`BRANCH\`, the matching rebase transition's source OID equals \`PRE_HEAD\`, the matching rebase start names \`DEFAULT_OID\`, and \`DEFAULT_OID\` is an ancestor of \`HEAD\`. If the source OID differs from \`PRE_HEAD\`, the finish result differs from \`HEAD\`, or any later branch movement exists, append \`blocked: completed direct-PR rebase transition mismatch; refusing recovery\` and stop. Then use the complete sixteen-field atomic transition to preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, set \`post_head\` to that exact \`HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`, write with mode 0600 through \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. If that recovery rewrite fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR recovered ready checkpoint write failed\`, and stop without pushing. After any successful ready-state rewrite, start a fresh invocation with the required prelude and enter step 9. Any other detached state or head, workflow, branch, repository, task, ref, or onto mismatch must append \`blocked: direct-PR lease checkpoint state mismatch; refusing recovery\` and stop. Do not rerun pre-rebase ancestry validation against rewritten \`HEAD\`.
4. Derive the task-scoped private refs \`PRIVATE_REF_ROOT=refs/firstmate/direct-pr/\$TASK_ID\`, \`BASE_FETCH_REF=\$PRIVATE_REF_ROOT/base\`, and \`FEATURE_FETCH_REF=\$PRIVATE_REF_ROOT/feature\`; their destination namespace is bound by the validated checkpoint to this task, repository, base, and feature identity and must not be shared with another task. Run \`git fetch "\$PUSH_ENDPOINT" "+\$BASE_REF:\$BASE_FETCH_REF"\`. Every base or feature private-ref fetch must exit zero, and its fetched OID must equal the immediately preceding live lookup OID before any \`rev-parse\`, rebase, lease, or ancestry use; otherwise append \`blocked: direct-PR private fetch failed or mismatched live lookup; private refs retained\` and stop.
5. Run \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` and require exit 0, setting \`LIVE_FEATURE_OID\` to that returned OID; exit 2 means the published feature ref is missing, and any other status is a lookup failure, so append \`blocked: published remote feature lookup failed\` and stop for either case.
6. Run \`git fetch "\$PUSH_ENDPOINT" "+\$FEATURE_REF:\$FEATURE_FETCH_REF"\`, snapshot \`EXPECTED=\$(git rev-parse "\$FEATURE_FETCH_REF")\`, and require \`git merge-base --is-ancestor "\$EXPECTED" HEAD\`; fetch failure, fetched/live OID mismatch, or ancestry failure must append \`blocked: direct-PR feature fetch failed, stale, or divergent\` and stop before consuming stale state; if the ancestry check fails, append \`blocked: remote feature branch diverged; refusing to overwrite remote-only commits\` and stop.
7. Set \`DEFAULT_OID=\$(git rev-parse "\$BASE_FETCH_REF")\` and \`PRE_HEAD=\$(git rev-parse HEAD)\`, derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` again, and require \`CURRENT_BRANCH == BRANCH\`; detached \`HEAD\` or mismatch must append \`blocked: direct-PR branch changed before rebase\` and stop. Atomically write all sixteen bound fields, including \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, and \`base_branch=\$BASE_BRANCH\`, through \`LEASE_CHECKPOINT_TMP\` with mode 0600, \`workflow=post-conflict\`, \`default_oid=\$DEFAULT_OID\`, \`post_head=\` empty, \`pr_url=\` empty, \`phase=rebase-in-progress\`, and \`attempt=0\`, then rename it to \`LEASE_CHECKPOINT\`. A write or rename failure must remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR lease checkpoint write failed\`, and stop.
8. Rebase onto the immutable \`DEFAULT_OID\` with \`git rebase "\$DEFAULT_OID"\` and resolve ordinary conflicts. Set \`POST_HEAD=\$(git rev-parse HEAD)\`, derive \`CURRENT_BRANCH=\$(git symbolic-ref --quiet --short HEAD)\` again, and require \`CURRENT_BRANCH == BRANCH\`; detached \`HEAD\` or mismatch must append \`blocked: direct-PR branch changed after rebase\` and stop. Atomically rewrite all sixteen bound fields through \`LEASE_CHECKPOINT_TMP\`, preserving \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, and \`pre_head=\$PRE_HEAD\`, while setting \`post_head=\$POST_HEAD\`, \`pr_url=\` empty, \`phase=ready-to-push\`, and \`attempt=0\`. If this second write or rename fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, append \`blocked: direct-PR ready checkpoint write failed; recover from rebase-in-progress state\`, and stop without pushing.
9. Before publication, require \`WORKFLOW=post-conflict\`, \`PHASE=ready-to-push\`, \`ATTEMPT\` equal to 0, 1, or 2, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD == POST_HEAD\`; otherwise append \`blocked: direct-PR publication state changed; refusing push\` and stop. The checkpoint attempt is the total authorized push count across every invocation. Immediately before every remote classification or push, repeat the step 1 exact endpoint and live symref revalidation and retain the checkpoint on any blocker. Every attempt or exhaustion transition must atomically preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, \`pre_head=\$PRE_HEAD\`, and \`post_head=\$POST_HEAD\`, preserve \`pr_url=\$PR_URL\`, and change only the defined \`phase\` and \`attempt\`, write all sixteen validated fields with mode 0600 through stable \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. On any such write or rename failure, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, retain the primary checkpoint, append \`blocked: direct-PR publication checkpoint transition failed\`, and stop without pushing. Classify \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\` as exit 0 with its OID, exit 2 with no ref, or any other status as \`blocked: remote feature retry lookup failed\` and stop. Exit 0 at \`POST_HEAD\` proves publication already succeeded; exit 0 at \`EXPECTED\` means unchanged; a different OID or exit 2 means movement. On movement, remove the validated checkpoint and stable task-specific \`LEASE_CHECKPOINT_TMP\`, then restart safe validation. For \`ATTEMPT=0\`, atomically rewrite the validated checkpoint with \`attempt=1\` and, after the rename succeeds, set \`ATTEMPT=1\` in memory before the first \`git push --force-with-lease="\$FEATURE_REF:\$EXPECTED" "\$PUSH_ENDPOINT" "\$POST_HEAD:\$FEATURE_REF"\`; a transition failure uses that cleanup and blocker without pushing. If that push fails or recovery starts with \`ATTEMPT=1\`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites \`attempt=2\` and, after the rename succeeds, sets \`ATTEMPT=2\` in memory before the second and final identical push. If that transition fails, use that cleanup and blocker without pushing. If the second push fails or recovery starts with \`ATTEMPT=2\`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites \`phase=push-exhausted\` with \`attempt=2\`, retains the checkpoint, appends \`blocked: direct-PR publication retry exhausted; checkpoint retained\`, and stops without another push. Recovery from \`PHASE=push-exhausted\` performs no remote lookup or automatic push and retains that blocker. After either push succeeds or remote classification proves \`POST_HEAD\` is published, atomically preserve \`repo=\$REPO_ID\`, \`push_endpoint=\$PUSH_ENDPOINT\`, \`remote_repo=\$REMOTE_REPO\`, \`base_ref=\$BASE_REF\`, \`base_branch=\$BASE_BRANCH\`, \`task=\$TASK_ID\`, \`feature_ref=\$FEATURE_REF\`, \`branch=\$BRANCH\`, \`workflow=\$WORKFLOW\`, \`expected=\$EXPECTED\`, \`default_oid=\$DEFAULT_OID\`, \`pre_head=\$PRE_HEAD\`, \`post_head=\$POST_HEAD\`, and \`attempt=\$ATTEMPT\`, set \`pr_url=\` empty and \`phase=published-awaiting-pr\`, write all sixteen fields with mode 0600 through stable \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`. If that write or rename fails, remove only the validated stable \`LEASE_CHECKPOINT_TMP\`, retain the durable prior checkpoint, append \`blocked: direct-PR published checkpoint transition failed; prior checkpoint retained\`, and stop before any PR action. Then enter step 10.
10. PR reconciliation is a separate \`PHASE=published-awaiting-pr\` path. Require \`WORKFLOW=post-conflict\`, attached \`CURRENT_BRANCH == BRANCH\`, and current \`HEAD == POST_HEAD\`. Immediately repeat the step 1 exact endpoint and live symref revalidation, then revalidate \`git ls-remote --exit-code "\$PUSH_ENDPOINT" "\$FEATURE_REF"\`: exit 0 must return exactly \`POST_HEAD\`; exit 2 must append \`blocked: published direct-PR feature ref deleted; checkpoint retained\`; any other status must append \`blocked: published direct-PR feature lookup failed; checkpoint retained\`; and a different OID must append \`blocked: published direct-PR feature moved; checkpoint retained\`. Stop on every blocker without cleanup. List PRs in all states using the exact filters repository \`REMOTE_REPO\`, head \`BRANCH\`, and base branch \`BASE_BRANCH\`, and require every match to have those exact repository, head, and base identities. Require exactly one match. No match, multiple matches, or lookup failure must append \`blocked: direct-PR PR identity reconciliation failed; checkpoint retained\` and stop. If the sole match is closed or merged, append \`blocked: direct-PR PR is {url} ({state}); checkpoint retained\` and stop without creating a replacement. Require the sole open PR head OID to equal \`POST_HEAD\`; otherwise append \`blocked: direct-PR PR head moved; checkpoint retained\` and stop. When \`PHASE=published-awaiting-pr\`, after exact PR reconciliation append exactly one nonterminal status line \`PR ready: {url} checkpoint=\$LEASE_CHECKPOINT task=\$TASK_ID workflow=\$WORKFLOW post_head=\$POST_HEAD\` and stop, retaining both exact state files. This existing actionable status must wake Firstmate immediately through the shared status classifier. Do not run \`fm-pr-check\`, remove checkpoint state, or emit \`done\`. The handoff authorizes only the Firstmate-owned phase transition below; the worker remains stopped until an exact \`pr-check-confirmed\` receipt is present.
Firstmate-owned phase transitions: before invoking the guarded check, Firstmate must parse the primary sixteen-field checkpoint, revalidate the exact repository/head/base identity and require the PR head OID equals \`POST_HEAD\`, then atomically preserve every field, set canonical \`pr_url={canonical url}\` and \`phase=pr-check-pending\`, write mode 0600 through \`LEASE_CHECKPOINT_TMP\`, and rename it to \`LEASE_CHECKPOINT\`; failure retains the prior checkpoint and blocks before the check. In \`pr-check-pending\`, Firstmate must invoke the operational helper at the validated safe path \`"\$FM_ROOT/bin/fm-pr-check.sh" --expected-head "\$POST_HEAD" --prior-head "\$EXPECTED" --expected-repo "\$REMOTE_REPO" --expected-base "\$BASE_BRANCH" --expected-branch "\$BRANCH" "\$TASK_ID" "\$PR_URL"\`; it uses the canonical Firstmate state directory and \`"\$FM_ROOT/bin/fm-pr-poll.sh"\` template and validates the complete task, repository, PR URL, base, feature branch, and head identity before any write. The helper accepts only one of three states: a complete internally consistent artifact set already bound to \`POST_HEAD\`, a complete internally consistent artifact set bound to the same task and canonical identity at the immediately checkpointed prior published head \`EXPECTED\`, or metadata with neither \`pr=\` nor \`pr_head=\` and all three poll artifacts provably absent. Exact \`POST_HEAD\` artifacts return success without republishing. Exact prior-generation artifacts are transactionally replaced for \`POST_HEAD\`; the helper refuses partial, foreign, ambiguous, unbound, or any other generation. Its expected-head guard must successfully resolve the live canonical PR head as exactly \`POST_HEAD\` before metadata, poll, registration, migration, or retirement writes, and lookup failure or mismatch must produce zero writes. After helper exit zero, Firstmate must use that same operational validation interface to require the complete exact artifact set and metadata \`pr_head=POST_HEAD\`, then atomically advance to \`pr-check-confirmed\` without a second publication. Any failed or interrupted publication retains \`pr-check-pending\`, appends \`blocked: direct-PR PR-check artifact reconciliation failed; checkpoint retained\`, and never reruns unless the guarded helper proves an exact prior generation or provable absence. Both phase transitions preserve all sixteen fields, the canonical \`PR_URL\`, exact \`POST_HEAD\`, mode 0600, stable-temp atomic rename, and prior-checkpoint retention on failure. In \`pr-check-confirmed\`, the worker must require that exact receipt, repeat all live endpoint, default, feature, and PR identity checks including head OID equality, validate the private namespace contains only \`BASE_FETCH_REF\` and \`FEATURE_FETCH_REF\`, delete both exact refs in one \`git update-ref --stdin\` transaction, remove only the validated checkpoint files, and emit the single terminal \`done\`; any failure retains state and blocks without publishing metadata or a poll again.
After initial PR opening, or after Firstmate-confirmed post-conflict cleanup, append \`done: PR {url}\` to the status file and stop. The post-conflict \`PR ready:\` handoff is nonterminal and must not use this line. When that later \`done\` arrives, Firstmate relays the already-armed PR state and must not run \`fm-pr-check\` or publish its metadata and poll a second time.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.
EOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    RULE2="2. Stay inside this worktree except for the status file; modify nothing else outside it."
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
    RULE2="2. Stay inside this worktree except for the status file; modify nothing else outside it."
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow no-mistakes' own guidance for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green, append \`done: PR {url} checks green\` and stop. You are finished.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable treehouse worktree you were launched in, typically a path under a \`.treehouse/\` pool, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
$RULE2
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: $STATUS_STATES
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - one instance serves
   every lane/home, so restarting it can kill another lane's in-flight pipeline. On any
   no-mistakes daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages it.

$COGNEE_BRIEF_RULES

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
If this task produced durable project-intrinsic knowledge, record it in \`AGENTS.md\` as part of your change.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
if [ "$SCOPE_CONTRACT_SET" -eq 1 ]; then
  "$SCRIPT_DIR/fm-scope-contract.sh" publish-marker "$DATA/$ID/scope-contract-enabled" || exit 1
  # Publish the protected opt-in first. A crash or append failure therefore
  # leaves a marker whose missing/invalid brief fails closed at spawn, never a
  # marker-free contract fence that could be mistaken for a legacy brief.
  "$SCRIPT_DIR/fm-scope-contract.sh" append-brief "$SCOPE_CONTRACT" "$BRIEF" "$MODE" || exit 1
fi
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
