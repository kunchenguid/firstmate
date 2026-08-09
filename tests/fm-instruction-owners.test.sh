#!/usr/bin/env bash
# Contract coverage for instruction ownership in AGENTS.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

AGENTS="$ROOT/AGENTS.md"
TMP_ROOT=$(fm_test_tmproot fm-instruction-owners)

contains_unsafe_checkpoint_command() {
  local normalized
  normalized=$(printf '%s' "$1" \
    | sed 's/Never source or eval checkpoint bytes\.//g' \
    | sed -E 's/\$\{LEASE_CHECKPOINT\}/\$LEASE_CHECKPOINT/g' \
    | tr -d "\"'")
  grep -Eq '(^|[;&|()[:space:]])(\.|source|eval)([[:space:]]|\$\{?IFS\}?)+[^.;]*LEASE_CHECKPOINT' \
    <<<"$normalized"
}

BRIEF_HOME="$TMP_ROOT/direct-pr-home"
mkdir -p "$BRIEF_HOME/data" "$BRIEF_HOME/state"
printf '%s\n' \
  '- direct-project [direct-PR] - direct PR fixture (added 2026-07-26)' \
  '- local-project [local-only] - local fixture (added 2026-07-26)' \
  > "$BRIEF_HOME/data/projects.md"
FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" parallel-direct-pr direct-project >/dev/null \
  || fail "direct-PR brief scaffold failed"
DIRECT_PR_BRIEF="$BRIEF_HOME/data/parallel-direct-pr/brief.md"
PRE_PR_PATH=$(sed -n '/^Before initial direct-PR publication:/,/^If firstmate later tells you that parallel work made the open PR conflict/p' "$DIRECT_PR_BRIEF" | sed '$d')
POST_CONFLICT_PATH=$(sed -n '/^If firstmate later tells you that parallel work made the open PR conflict, you still own reconciliation:/,/^After initial PR opening, or after Firstmate-confirmed post-conflict cleanup/p' "$DIRECT_PR_BRIEF" | sed '$d')
for path_name in PRE_PR_PATH POST_CONFLICT_PATH; do
  path=${!path_name}
  assert_contains "$path" 'Query the live default with `git ls-remote --symref "$PUSH_ENDPOINT" HEAD`' \
    "$path_name lost DEFAULT initialization"
  assert_contains "$path" 'Set `TASK_ID=parallel-direct-pr`, `FEATURE_REF=refs/heads/fm/parallel-direct-pr`, `BRANCH=fm/parallel-direct-pr`' \
    "$path_name lost task, feature, or branch initialization"
  assert_contains "$path" 'Derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)`' \
    "$path_name lost current symbolic branch derivation"
  assert_contains "$path" 'An attached branch must equal `BRANCH`; a detached `HEAD` is allowed only when `LEASE_CHECKPOINT` exists and step 3 proves an active rebase for the bound branch and base' \
    "$path_name lost bounded detached-HEAD recovery entry"
  assert_contains "$path" 'Otherwise append `blocked: direct-PR requires attached branch fm/parallel-direct-pr` and stop' \
    "$path_name lost initial branch-state blocker"
  assert_contains "$path" '`REPO_ID=$(git rev-parse --path-format=absolute --git-common-dir)`' \
    "$path_name lost repository identity initialization"
  assert_contains "$path" 'set `CURRENT_BASE_REF=refs/heads/<branch>`, `CURRENT_BASE_BRANCH=<branch>`, and `DEFAULT=$CURRENT_BASE_BRANCH`' \
    "$path_name lost exact base-ref initialization"
  assert_contains "$path" 'Resolve exactly one validated `PUSH_ENDPOINT` from `git remote get-url --push --all origin`' \
    "$path_name lost canonical push-repository lookup"
  assert_contains "$path" 'including a configured `remote.origin.pushurl`' \
    "$path_name ignores a distinct origin push endpoint"
  assert_contains "$path" 'Define the portable helper `fm_checkpoint_mode() { if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi; }` in this fresh-shell prelude' \
    "$path_name does not define an operational portable mode helper"
  assert_contains "$path" 'require `git ls-remote --exit-code "$PUSH_ENDPOINT" "$CURRENT_BASE_REF"` to return exactly that one base OID' \
    "$path_name lost live base-ref existence proof"
  assert_contains "$path" 'Before every recovery, fetch, lease lookup, push, or PR lookup, repeat these live endpoint and symref lookups and require the exact endpoint, canonical repository, full base ref, and short base branch to equal the bound `PUSH_ENDPOINT`, `REMOTE_REPO`, `BASE_REF`, and `BASE_BRANCH`' \
    "$path_name lost remote/base revalidation boundary"
  assert_contains "$path" 'endpoint retargeting, default-branch change, lookup failure, deletion, or ambiguity must append `blocked: direct-PR endpoint or base identity changed; checkpoint retained` and stop without cleanup' \
    "$path_name does not fail closed on remote/base movement"
  assert_contains "$path" "LEASE_CHECKPOINT='$BRIEF_HOME/state/parallel-direct-pr.direct-pr-lease'" \
    "$path_name lost index-safe task checkpoint location"
  assert_contains "$path" '`LEASE_CHECKPOINT_TMP=$LEASE_CHECKPOINT.tmp`' \
    "$path_name lost stable atomic temporary checkpoint path"
  assert_contains "$path" 'outside the project worktree and Git index' \
    "$path_name lost index-safe checkpoint contract"
  assert_contains "$path" 'A valid checkpoint must contain exactly `repo=`, `push_endpoint=`, `remote_repo=`, `base_ref=`, `base_branch=`, `task=`, `feature_ref=`, `branch=`, `workflow=`, `expected=`, `default_oid=`, `pre_head=`, `post_head=`, `pr_url=`, `phase=`, and `attempt=`' \
    "$path_name lost complete checkpoint binding"
  assert_contains "$path" 'Parse it only as data: read exactly one line for each literal key, split each line only at its first `=`, and assign `CHECKPOINT_REPO`, `CHECKPOINT_PUSH_ENDPOINT`, `CHECKPOINT_REMOTE_REPO`, `CHECKPOINT_BASE_REF`, `CHECKPOINT_BASE_BRANCH`, `CHECKPOINT_TASK`, `CHECKPOINT_FEATURE_REF`, `CHECKPOINT_BRANCH`, `CHECKPOINT_WORKFLOW`, `CHECKPOINT_EXPECTED`, `CHECKPOINT_DEFAULT_OID`, `CHECKPOINT_PRE_HEAD`, `CHECKPOINT_POST_HEAD`, `CHECKPOINT_PR_URL`, `CHECKPOINT_PHASE`, and `CHECKPOINT_ATTEMPT`; reject duplicate, missing, unknown, or invalid fields' \
    "$path_name lost safe checkpoint parsing"
  assert_contains "$path" 'Never source or eval checkpoint bytes' \
    "$path_name can execute checkpoint bytes"
  assert_contains "$path" 'After all validation, explicitly hydrate `REPO_ID=$CHECKPOINT_REPO`, `PUSH_ENDPOINT=$CHECKPOINT_PUSH_ENDPOINT`, `REMOTE_REPO=$CHECKPOINT_REMOTE_REPO`, `BASE_REF=$CHECKPOINT_BASE_REF`, `BASE_BRANCH=$CHECKPOINT_BASE_BRANCH`, `DEFAULT=$CHECKPOINT_BASE_BRANCH`, `TASK_ID=$CHECKPOINT_TASK`, `FEATURE_REF=$CHECKPOINT_FEATURE_REF`, `BRANCH=$CHECKPOINT_BRANCH`, `WORKFLOW=$CHECKPOINT_WORKFLOW`, `EXPECTED=$CHECKPOINT_EXPECTED`, `DEFAULT_OID=$CHECKPOINT_DEFAULT_OID`, `PRE_HEAD=$CHECKPOINT_PRE_HEAD`, `POST_HEAD=$CHECKPOINT_POST_HEAD`, `PR_URL=$CHECKPOINT_PR_URL`, `PHASE=$CHECKPOINT_PHASE`, and `ATTEMPT=$CHECKPOINT_ATTEMPT` before any recovery action' \
    "$path_name lost checkpoint-to-variable hydration"
  assert_contains "$path" '`published-awaiting-pr` requires nonempty `POST_HEAD`, empty `PR_URL`, and `ATTEMPT` 0, 1, or 2; `pr-check-pending` and `pr-check-confirmed` each require nonempty `POST_HEAD`, canonical nonempty `PR_URL`, and `ATTEMPT` 0, 1, or 2. Every earlier phase requires empty `PR_URL`' \
    "$path_name lost exact phase and attempt tuples"
  assert_contains "$path" 'Any other tuple must append `blocked: direct-PR lease checkpoint state mismatch; refusing recovery` and stop' \
    "$path_name lost invalid phase-tuple blocker"
  assert_contains "$path" 'Fresh-shell rule: never rely on variables surviving a prior agent command call' \
    "$path_name depends on cross-command shell state"
  assert_contains "$path" 'Before every command invocation in steps 2-10, use that same invocation to repeat step 1 identity initialization and, when the checkpoint exists, this complete typed validation and hydration' \
    "$path_name lost per-invocation state hydration"
  assert_contains "$path" 'Before the checkpoint exists, a fresh invocation in steps 4-7 must also replay every earlier state-producing fetch or lookup needed by that step' \
    "$path_name lost pre-checkpoint fresh-shell reconstruction"
  assert_contains "$path" 'Validate the primary checkpoint before handling the stable task-specific temporary target' \
    "$path_name lost primary-before-temporary validation ordering"
  assert_contains "$path" 'Reject a checkpoint that is a symlink, non-regular file, unexpectedly owned, not mode 0600 according to `fm_checkpoint_mode "$LEASE_CHECKPOINT"`, or malformed' \
    "$path_name accepts a non-private durable checkpoint"
  assert_contains "$path" 'If `LEASE_CHECKPOINT_TMP` exists, reject it when it is a symlink, non-regular file, or unexpectedly owned; otherwise remove that exact same-task stale temporary file without parsing it, preserving the primary checkpoint' \
    "$path_name lost bounded stale temporary recovery"
  CHECKPOINT_STEP=$(printf '%s\n' "$path" | sed -n '/^2\./p')
  if grep -Fq 'fm_checkpoint_mode "$LEASE_CHECKPOINT_TMP"' <<<"$CHECKPOINT_STEP"; then
    fail "$path_name incorrectly requires a mode for the interruption-prone stale temp"
  fi
  assert_contains "$path" 'require `CHECKPOINT_PUSH_ENDPOINT == PUSH_ENDPOINT`, `CHECKPOINT_REMOTE_REPO == CURRENT_REMOTE_REPO`, `CHECKPOINT_BASE_REF == CURRENT_BASE_REF`, and `CHECKPOINT_BASE_BRANCH == CURRENT_BASE_BRANCH`' \
    "$path_name accepts retargeted remote or base identity"
  assert_contains "$path" 'Otherwise append `blocked: direct-PR lease checkpoint identity mismatch; refusing recovery` and stop' \
    "$path_name lost fail-closed checkpoint identity validation"
  assert_contains "$path" 'exit 0 supplies the remote OID, exit 2 means no matching ref, and any other status must append `blocked: direct-PR lease recovery lookup failed` and stop' \
    "$path_name lost explicit recovery lookup outcomes"
  assert_contains "$path" 'On recovery, branch on `PHASE` before inspecting `HEAD`, reflogs, or active-rebase metadata' \
    "$path_name lost phase-first recovery ordering"
  assert_contains "$path" 'If `PHASE=push-exhausted`, require `ATTEMPT=2`, the bound workflow, attached branch, and exact `POST_HEAD`; retain the checkpoint, append `blocked: direct-PR publication retry exhausted; checkpoint retained`, and stop without any automatic push' \
    "$path_name lost exhausted-state recovery blocker"
  assert_contains "$path" 'If `PHASE=published-awaiting-pr`, require the bound workflow, attached `CURRENT_BRANCH == BRANCH`, and current `HEAD` to equal the nonempty `POST_HEAD`, then enter the separate step 10 PR-reconciliation path directly; never enter step 9 or perform another push' \
    "$path_name lost published PR-only recovery"
  assert_contains "$path" 'If `PHASE=pr-check-pending`, require the bound workflow, attached branch, exact `POST_HEAD`, and canonical nonempty `PR_URL`, then stop for the Firstmate-owned artifact-reconciliation path' \
    "$path_name lost pending receipt routing"
  assert_contains "$path" 'If `PHASE=pr-check-confirmed`, require the same bound identity and enter only the step 10 receipt-finalization branch' \
    "$path_name lost confirmed receipt routing"
  assert_contains "$path" 'If `PHASE=ready-to-push`, require `ATTEMPT` to be 0, 1, or 2' \
    "$path_name lost ready-state attempt validation"
  assert_contains "$path" 'Only when `PHASE=rebase-in-progress` may recovery inspect active-rebase metadata, `HEAD`, or reflogs' \
    "$path_name permits HEAD or reflog recovery outside rebase-in-progress"
  assert_contains "$path" 'In that rebase-in-progress branch, detect active rebase metadata before remote-movement cleanup' \
    "$path_name lost active-rebase-first recovery ordering"
  assert_contains "$path" 'An active rebase is valid only when metadata records `refs/heads/$BRANCH` as the original branch, `PRE_HEAD` as the original head, and `DEFAULT_OID` as the exact onto target' \
    "$path_name lost active-rebase branch, head, and onto proof"
  assert_contains "$path" 'Git'\''s expected detached `HEAD` is allowed only in that validated state, otherwise append `blocked: active direct-PR rebase metadata mismatch` and stop' \
    "$path_name lost active-rebase metadata blocker"
  assert_contains "$path" 'If the remote moved during that validated active rebase, retain `LEASE_CHECKPOINT` and its bound state, append `blocked: remote feature moved during active direct-PR rebase; checkpoint retained`, and stop without cleanup or restart' \
    "$path_name lost active-rebase remote-movement checkpoint retention"
  assert_contains "$path" 'If the remote moved with no active rebase, remove the validated checkpoint and its stable task-specific `LEASE_CHECKPOINT_TMP`, then restart safe validation' \
    "$path_name lost bounded non-active remote-movement cleanup"
  assert_contains "$path" 'With no active rebase, require attached `CURRENT_BRANCH == BRANCH`' \
    "$path_name lost attached-state recovery boundary"
  assert_contains "$path" 'When `HEAD == PRE_HEAD`, either use the complete sixteen-field atomic transition to preserve `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, and `pre_head=$PRE_HEAD`, set `post_head=$PRE_HEAD`, `pr_url=` empty, `phase=ready-to-push`, and `attempt=0`, write with mode 0600 through `LEASE_CHECKPOINT_TMP`, and rename it to `LEASE_CHECKPOINT` for a proven no-op where `DEFAULT_OID` is already an ancestor of `HEAD`; or safely restart `git rebase "$DEFAULT_OID"` and perform that same complete ready-state transition after it completes' \
    "$path_name lost no-active pre-head restart and no-op recovery"
  assert_contains "$path" 'When `HEAD` differs, accept completed rebase recovery only when the latest metadata-bound matching rebase finish is the newest branch reflog entry, that finish result OID equals current `HEAD`, no later branch movement exists, the recorded branch equals `BRANCH`, the matching rebase transition'\''s source OID equals `PRE_HEAD`, the matching rebase start names `DEFAULT_OID`, and `DEFAULT_OID` is an ancestor of `HEAD`' \
    "$path_name lost exact immutable completed-rebase proof"
  assert_contains "$path" 'If the source OID differs from `PRE_HEAD`, the finish result differs from `HEAD`, or any later branch movement exists, append `blocked: completed direct-PR rebase transition mismatch; refusing recovery` and stop' \
    "$path_name lost completed-rebase transition blocker"
  assert_contains "$path" 'Then use the complete sixteen-field atomic transition to preserve `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, and `pre_head=$PRE_HEAD`, set `post_head` to that exact `HEAD`, `pr_url=` empty, `phase=ready-to-push`, and `attempt=0`, write with mode 0600 through `LEASE_CHECKPOINT_TMP`, and rename it to `LEASE_CHECKPOINT`' \
    "$path_name lost recoverable ready-state transition"
  assert_contains "$path" 'If that recovery rewrite fails, remove only the validated stable `LEASE_CHECKPOINT_TMP`, append `blocked: direct-PR recovered ready checkpoint write failed`, and stop without pushing' \
    "$path_name lost fail-closed recovered ready-state rewrite"
  assert_contains "$path" 'If `PHASE=ready-to-push`, require `ATTEMPT` to be 0, 1, or 2 and require `WORKFLOW=' \
    "$path_name lost direct ready-state publication branch"
  assert_contains "$path" 'then enter step 9 directly and execute its complete' \
    "$path_name does not route ready state directly to publication"
  assert_contains "$path" 'After any successful ready-state rewrite, start a fresh invocation with the required prelude and enter step 9' \
    "$path_name lost fresh-shell transition after rebase recovery"
  assert_contains "$path" 'Any other detached state or head, workflow, branch, repository, task, ref, or onto mismatch must append `blocked: direct-PR lease checkpoint state mismatch; refusing recovery` and stop' \
    "$path_name lost recovery state and onto mismatch blocker"
  assert_contains "$path" 'Do not rerun pre-rebase ancestry validation against rewritten `HEAD`' \
    "$path_name reruns invalid ancestry checks during recovery"
  assert_contains "$path" 'Set `DEFAULT_OID=$(git rev-parse "$BASE_FETCH_REF")` and `PRE_HEAD=$(git rev-parse HEAD)`' \
    "$path_name lost default and pre-rebase HEAD snapshots"
  assert_contains "$path" 'derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)` again, and require `CURRENT_BRANCH == BRANCH`; detached `HEAD` or mismatch must append `blocked: direct-PR branch changed before rebase` and stop' \
    "$path_name lost pre-rebase attached-branch validation"
  assert_contains "$path" 'Atomically write all sixteen bound fields, including `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, and `base_branch=$BASE_BRANCH`, through `LEASE_CHECKPOINT_TMP` with mode 0600, `workflow=' \
    "$path_name lost durable rebase-in-progress checkpoint"
  assert_contains "$path" '`post_head=` empty, `pr_url=` empty, `phase=rebase-in-progress`, and `attempt=0`' \
    "$path_name lost initial attempt state"
  assert_contains "$path" 'Set `POST_HEAD=$(git rev-parse HEAD)`' \
    "$path_name lost publication HEAD snapshot"
  assert_contains "$path" 'derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)` again, and require `CURRENT_BRANCH == BRANCH`; detached `HEAD` or mismatch must append `blocked: direct-PR branch changed after rebase` and stop' \
    "$path_name lost post-rebase attached-branch validation"
  assert_contains "$path" 'preserving `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, and `pre_head=$PRE_HEAD`, while setting `post_head=$POST_HEAD`, `pr_url=` empty, `phase=ready-to-push`, and `attempt=0`' \
    "$path_name lost ready-to-push identity and HEAD binding"
  assert_contains "$path" 'If this second write or rename fails, remove only the validated stable `LEASE_CHECKPOINT_TMP`, append `blocked: direct-PR ready checkpoint write failed; recover from rebase-in-progress state`, and stop without pushing' \
    "$path_name lost fail-closed second checkpoint rewrite"
  assert_contains "$path" 'Before publication, require `WORKFLOW=' \
    "$path_name lost pre-push branch and HEAD validation"
  assert_contains "$path" 'otherwise append `blocked: direct-PR publication state changed; refusing push` and stop' \
    "$path_name lost fail-closed publication-state validation"
  assert_contains "$path" 'A write or rename failure must remove only the validated stable `LEASE_CHECKPOINT_TMP`, append `blocked: direct-PR lease checkpoint write failed`, and stop' \
    "$path_name lost atomic-write cleanup and blocker"
  assert_contains "$path" 'remove the validated checkpoint and its stable task-specific `LEASE_CHECKPOINT_TMP`, then restart safe validation' \
    "$path_name lost confirmed-remote-movement cleanup"
  assert_contains "$path" 'After either push succeeds or remote classification proves `POST_HEAD` is published, atomically preserve `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, `pre_head=$PRE_HEAD`, `post_head=$POST_HEAD`, and `attempt=$ATTEMPT`, set `pr_url=` empty and `phase=published-awaiting-pr`' \
    "$path_name lost durable post-publication transition"
  assert_contains "$path" 'FEATURE_REF=refs/heads/fm/parallel-direct-pr' \
    "$path_name lost FEATURE_REF initialization"
  assert_contains "$path" 'If the remote still matches, resume only the validated active rebase' \
    "$path_name lost checkpoint remote-match validation"
  assert_contains "$path" '`PRIVATE_REF_ROOT=refs/firstmate/direct-pr/$TASK_ID`, `BASE_FETCH_REF=$PRIVATE_REF_ROOT/base`, and `FEATURE_FETCH_REF=$PRIVATE_REF_ROOT/feature`' \
    "$path_name lost task-scoped private fetch refs"
  assert_contains "$path" 'destination namespace is bound by the validated checkpoint to this task, repository, base, and feature identity and must not be shared with another task' \
    "$path_name lost private-ref identity binding"
  assert_contains "$path" 'git fetch "$PUSH_ENDPOINT" "+$BASE_REF:$BASE_FETCH_REF"' \
    "$path_name lost explicit default-ref fetch"
  assert_contains "$path" 'Every base or feature private-ref fetch must exit zero' \
    "$path_name can consume a failed base fetch"
  assert_contains "$path" 'its fetched OID must equal the immediately preceding live lookup OID' \
    "$path_name can consume a stale base private ref"
  assert_contains "$path" 'git ls-remote --exit-code "$PUSH_ENDPOINT" "$FEATURE_REF"' \
    "$path_name lost remote feature lookup guard"
  assert_contains "$path" 'git fetch "$PUSH_ENDPOINT" "+$FEATURE_REF:$FEATURE_FETCH_REF"' \
    "$path_name lost explicit feature-ref fetch"
  assert_contains "$path" 'Every base or feature private-ref fetch must exit zero' \
    "$path_name can consume a failed feature fetch"
  assert_contains "$path" 'its fetched OID must equal the immediately preceding live lookup OID' \
    "$path_name can consume a stale feature private ref"
  assert_contains "$path" 'EXPECTED=$(git rev-parse "$FEATURE_FETCH_REF")' \
    "$path_name lost fetched feature OID snapshot"
  assert_contains "$path" 'git merge-base --is-ancestor "$EXPECTED" HEAD' \
    "$path_name lost feature-history ancestry guard"
  assert_contains "$path" 'blocked: remote feature branch diverged; refusing to overwrite remote-only commits' \
    "$path_name lost feature-history divergence blocker"
  assert_contains "$path" 'Rebase onto the immutable `DEFAULT_OID` with `git rebase "$DEFAULT_OID"` and resolve ordinary conflicts' \
    "$path_name lost immutable-base conflict resolution"
  assert_contains "$path" 'git push --force-with-lease="$FEATURE_REF:$EXPECTED" "$PUSH_ENDPOINT" "$POST_HEAD:$FEATURE_REF"' \
    "$path_name lost immutable publication OID and explicit lease"
  assert_contains "$path" 'before the second and final identical push' \
    "$path_name lost bounded identical retry"
  assert_contains "$path" 'if the ancestry check fails, append `blocked: remote feature branch diverged; refusing to overwrite remote-only commits` and stop' \
    "$path_name lost fail-closed divergence blocker"
  if contains_unsafe_checkpoint_command "$path"; then
    fail "$path_name contains an executable source, dot, or eval checkpoint command"
  fi
  RECOVERY_STEP=$(printf '%s\n' "$path" | sed -n '/^3\./p')
  REBASE_SCOPE='Only when `PHASE=rebase-in-progress` may recovery inspect active-rebase metadata, `HEAD`, or reflogs'
  assert_contains "$RECOVERY_STEP" "$REBASE_SCOPE" \
    "$path_name lost rebase-in-progress recovery scope"
  BEFORE_REBASE_SCOPE=${RECOVERY_STEP%%"$REBASE_SCOPE"*}
  AFTER_REBASE_SCOPE=${RECOVERY_STEP#*"$REBASE_SCOPE"}
  if grep -Fq 'When `HEAD == PRE_HEAD`' <<<"$BEFORE_REBASE_SCOPE" \
    || grep -Fq 'When `HEAD` differs, accept completed rebase recovery' <<<"$BEFORE_REBASE_SCOPE"; then
    fail "$path_name permits HEAD transition recovery before the rebase-in-progress branch"
  fi
  assert_contains "$AFTER_REBASE_SCOPE" 'When `HEAD == PRE_HEAD`' \
    "$path_name lost scoped unchanged-HEAD recovery"
  assert_contains "$AFTER_REBASE_SCOPE" 'When `HEAD` differs, accept completed rebase recovery' \
    "$path_name lost scoped reflog transition recovery"
done
for unsafe_checkpoint_fixture in \
  'source ${LEASE_CHECKPOINT}' \
  '. "$LEASE_CHECKPOINT"' \
  'eval "$(<"$LEASE_CHECKPOINT")"'; do
  contains_unsafe_checkpoint_command "$unsafe_checkpoint_fixture" \
    || fail "checkpoint command detector missed '$unsafe_checkpoint_fixture'"
done
assert_contains "$PRE_PR_PATH" 'then enter step 9 directly and execute its complete initial-publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, transition to published-awaiting-pr, and separate PR reconciliation' \
  'initial ready-state recovery lost the complete publication workflow'
assert_contains "$POST_CONFLICT_PATH" 'then enter step 9 directly and execute its complete post-conflict publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, transition to published-awaiting-pr, separate open-PR reconciliation, a nonterminal Firstmate-owned readiness-check handoff, and the following single terminal completion after confirmation or blocked status' \
  'post-conflict ready-state recovery lost the complete publication workflow'
assert_contains "$PRE_PR_PATH" '`WORKFLOW=initial-publication`' \
  'initial publication lost workflow initialization'
assert_contains "$PRE_PR_PATH" 'require `CHECKPOINT_WORKFLOW=initial-publication`' \
  'initial recovery accepts another workflow owner'
assert_contains "$PRE_PR_PATH" '`workflow=initial-publication`' \
  'initial checkpoint lost workflow binding'
assert_contains "$PRE_PR_PATH" 'The remote matches only when exit 0 supplies `EXPECTED`, or when exit 2 and `EXPECTED` is empty for this bound initial-publication workflow; every other exit 0 or 2 outcome is confirmed remote movement' \
  'initial recovery lost absent-ref and movement classification'
assert_contains "$POST_CONFLICT_PATH" '`WORKFLOW=post-conflict`' \
  'post-conflict publication lost workflow initialization'
assert_contains "$POST_CONFLICT_PATH" 'require `CHECKPOINT_WORKFLOW=post-conflict`' \
  'post-conflict recovery accepts another workflow owner'
assert_contains "$POST_CONFLICT_PATH" '`workflow=post-conflict`' \
  'post-conflict checkpoint lost workflow binding'
assert_contains "$POST_CONFLICT_PATH" 'For this bound post-conflict workflow, the remote matches only when exit 0 supplies `EXPECTED`; exit 2 is confirmed remote deletion, and any different OID from exit 0 is confirmed remote movement' \
  'post-conflict recovery lost deletion and movement classification'
if grep -Fq -- 'then resume only `git push' "$DIRECT_PR_BRIEF"; then
  fail 'legacy bare-push-only recovery clause remains'
fi
PRE_PR_STEP9=$(printf '%s\n' "$PRE_PR_PATH" | sed -n '/^9\./,$p')
POST_CONFLICT_STEP9=$(printf '%s\n' "$POST_CONFLICT_PATH" | sed -n '/^9\./,$p')
for step_name in PRE_PR_STEP9 POST_CONFLICT_STEP9; do
  step=${!step_name}
  assert_contains "$step" 'attached `CURRENT_BRANCH == BRANCH`, and current `HEAD == POST_HEAD`; otherwise append `blocked: direct-PR publication state changed; refusing push` and stop' \
    "$step_name lost publication-state precondition"
  assert_contains "$step" 'The checkpoint attempt is the total authorized push count across every invocation' \
    "$step_name lost cross-invocation attempt bound"
  assert_contains "$step" 'Immediately before every remote classification or push, repeat the step 1 exact endpoint and live symref revalidation and retain the checkpoint on any blocker' \
    "$step_name lost pre-push remote/base revalidation"
  assert_contains "$step" 'Every attempt or exhaustion transition must atomically preserve `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, `pre_head=$PRE_HEAD`, and `post_head=$POST_HEAD`, preserve `pr_url=$PR_URL`, and change only the defined `phase` and `attempt`, write all sixteen validated fields with mode 0600 through stable `LEASE_CHECKPOINT_TMP`, and rename it to `LEASE_CHECKPOINT`' \
    "$step_name lost complete atomic attempt-transition contract"
  assert_contains "$step" 'On any such write or rename failure, remove only the validated stable `LEASE_CHECKPOINT_TMP`, retain the primary checkpoint, append `blocked: direct-PR publication checkpoint transition failed`, and stop without pushing' \
    "$step_name lost attempt-transition failure cleanup"
  assert_contains "$step" 'Classify `git ls-remote --exit-code "$PUSH_ENDPOINT" "$FEATURE_REF"` as exit 0 with its OID, exit 2 with no ref, or any other status as `blocked: remote feature retry lookup failed` and stop' \
    "$step_name lost explicit retry lookup outcomes"
  assert_contains "$step" 'On movement, remove the validated checkpoint and stable task-specific `LEASE_CHECKPOINT_TMP`, then restart safe validation' \
    "$step_name lost lease-rejection cleanup and restart"
  assert_contains "$step" 'For `ATTEMPT=0`, atomically rewrite the validated checkpoint with `attempt=1` and, after the rename succeeds, set `ATTEMPT=1` in memory before the first `git push --force-with-lease="$FEATURE_REF:$EXPECTED" "$PUSH_ENDPOINT" "$POST_HEAD:$FEATURE_REF"`; a transition failure uses that cleanup and blocker without pushing' \
    "$step_name does not persist the first authorized attempt"
  assert_contains "$step" 'If that push fails or recovery starts with `ATTEMPT=1`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites `attempt=2` and, after the rename succeeds, sets `ATTEMPT=2` in memory before the second and final identical push' \
    "$step_name lost interruption-safe first-failure recovery"
  assert_contains "$step" 'If that transition fails, use that cleanup and blocker without pushing' \
    "$step_name lost second-attempt transition failure cleanup"
  assert_contains "$step" 'If the second push fails or recovery starts with `ATTEMPT=2`, classify the remote first: published proceeds to the published-state transition, movement restarts, and unchanged atomically rewrites `phase=push-exhausted` with `attempt=2`, retains the checkpoint, appends `blocked: direct-PR publication retry exhausted; checkpoint retained`, and stops without another push' \
    "$step_name lost durable retry exhaustion"
  assert_contains "$step" 'Recovery from `PHASE=push-exhausted` performs no remote lookup or automatic push and retains that blocker' \
    "$step_name grants new attempts after exhaustion"
  assert_contains "$step" 'After either push succeeds or remote classification proves `POST_HEAD` is published, atomically preserve `repo=$REPO_ID`, `push_endpoint=$PUSH_ENDPOINT`, `remote_repo=$REMOTE_REPO`, `base_ref=$BASE_REF`, `base_branch=$BASE_BRANCH`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, `pre_head=$PRE_HEAD`, `post_head=$POST_HEAD`, and `attempt=$ATTEMPT`, set `pr_url=` empty and `phase=published-awaiting-pr`, write all sixteen fields with mode 0600 through stable `LEASE_CHECKPOINT_TMP`, and rename it to `LEASE_CHECKPOINT`' \
    "$step_name lost published-awaiting-pr transition"
  assert_contains "$step" 'If that write or rename fails, remove only the validated stable `LEASE_CHECKPOINT_TMP`, retain the durable prior checkpoint, append `blocked: direct-PR published checkpoint transition failed; prior checkpoint retained`, and stop before any PR action' \
    "$step_name lost fail-closed published transition"
  assert_contains "$step" 'Immediately repeat the step 1 exact endpoint and live symref revalidation, then revalidate `git ls-remote --exit-code "$PUSH_ENDPOINT" "$FEATURE_REF"`: exit 0 must return exactly `POST_HEAD`; exit 2 must append `blocked: published direct-PR feature ref deleted; checkpoint retained`; any other status must append `blocked: published direct-PR feature lookup failed; checkpoint retained`; and a different OID must append `blocked: published direct-PR feature moved; checkpoint retained`' \
    "$step_name lost published remote-head revalidation"
  assert_contains "$step" 'List PRs in all states using the exact filters repository `REMOTE_REPO`, head `BRANCH`, and base branch `BASE_BRANCH`' \
    "$step_name does not reconcile all PR states"
  assert_contains "$step" 'require every match to have those exact repository, head, and base identities' \
    "$step_name lost exact PR identity validation"
  assert_contains "$step" 'If the sole match is closed or merged, append `blocked: direct-PR PR is {url} ({state}); checkpoint retained` and stop without creating a replacement' \
    "$step_name can duplicate a closed or merged PR"
done
assert_contains "$PRE_PR_STEP9" 'Exit 0 at `POST_HEAD` proves publication already succeeded; exit 0 at `EXPECTED`, or exit 2 only when `EXPECTED` is empty, means unchanged; every other exit 0 or 2 means movement' \
  'initial retry lookup lost absent-ref classification'
assert_contains "$POST_CONFLICT_STEP9" 'Exit 0 at `POST_HEAD` proves publication already succeeded; exit 0 at `EXPECTED` means unchanged; a different OID or exit 2 means movement' \
  'post-conflict retry lookup lost deletion classification'
assert_contains "$PRE_PR_STEP9" 'before the first `git push --force-with-lease="$FEATURE_REF:$EXPECTED" "$PUSH_ENDPOINT" "$POST_HEAD:$FEATURE_REF"`' \
  "initial publication step lost guarded push"
assert_contains "$PRE_PR_STEP9" 'With no match, open exactly one PR with `gh-axi`, then re-list all states and require exactly one open match whose head OID equals `POST_HEAD`' \
  "initial publication step lost existing-PR reconciliation"
assert_contains "$PRE_PR_STEP9" 'If the sole match is open, require its head OID to equal `POST_HEAD`; otherwise append `blocked: direct-PR PR head moved; checkpoint retained` and stop' \
  "initial publication accepts an open PR at another head"
assert_contains "$PRE_PR_STEP9" 'Multiple matches or lookup failure must append `blocked: direct-PR PR identity reconciliation failed; checkpoint retained` and stop' \
  "initial publication does not block ambiguous PR identity"
assert_contains "$POST_CONFLICT_STEP9" 'before the first `git push --force-with-lease="$FEATURE_REF:$EXPECTED" "$PUSH_ENDPOINT" "$POST_HEAD:$FEATURE_REF"`' \
  "post-conflict publication step lost guarded push"
assert_contains "$POST_CONFLICT_STEP9" 'the worker remains stopped until an exact `pr-check-confirmed` receipt is present' \
  "post-conflict publication step lost Firstmate confirmation boundary"
assert_contains "$POST_CONFLICT_STEP9" 'Require the sole open PR head OID to equal `POST_HEAD`; otherwise append `blocked: direct-PR PR head moved; checkpoint retained` and stop' \
  "post-conflict publication accepts an open PR at another head"
assert_contains "$POST_CONFLICT_STEP9" 'No match, multiple matches, or lookup failure must append `blocked: direct-PR PR identity reconciliation failed; checkpoint retained` and stop' \
  "post-conflict publication does not block missing or ambiguous PR identity"
assert_contains "$PRE_PR_PATH" '0 means the feature ref exists and sets `LIVE_FEATURE_OID` to that returned OID, 2 means it is absent, and any other status is a lookup failure' \
  "pre-PR path lost distinct feature lookup outcomes"
assert_contains "$PRE_PR_PATH" 'any other status is a lookup failure that must append `blocked: remote feature lookup failed` and stop' \
  "pre-PR path lost lookup-failure blocker"
assert_contains "$PRE_PR_PATH" 'set `EXPECTED=`' \
  "pre-PR path lost absent-feature lease initialization"
assert_contains "$PRE_PR_PATH" 'Only after one open PR is confirmed at `POST_HEAD` may the validated checkpoint and stable task-specific `LEASE_CHECKPOINT_TMP` be removed' \
  "pre-PR path can clean up before PR confirmation"
assert_contains "$POST_CONFLICT_PATH" 'require exit 0, setting `LIVE_FEATURE_OID` to that returned OID; exit 2 means the published feature ref is missing, and any other status is a lookup failure' \
  "post-conflict path lost published feature lookup guard"
assert_contains "$POST_CONFLICT_PATH" 'append `blocked: published remote feature lookup failed` and stop for either case' \
  "post-conflict path lost published-feature blocker"
assert_contains "$POST_CONFLICT_PATH" 'When `PHASE=published-awaiting-pr`, after exact PR reconciliation append exactly one nonterminal status line `PR ready: {url} checkpoint=$LEASE_CHECKPOINT task=$TASK_ID workflow=$WORKFLOW post_head=$POST_HEAD` and stop, retaining both exact state files' \
  "post-conflict path lost the precise nonterminal readiness handoff"
assert_contains "$POST_CONFLICT_PATH" 'This existing actionable status must wake Firstmate immediately through the shared status classifier' \
  "post-conflict path lost the actionable classifier contract"
assert_contains "$POST_CONFLICT_PATH" 'Do not run `fm-pr-check`, remove checkpoint state, or emit `done`' \
  "post-conflict path lets the worker cross the Firstmate ownership boundary"
assert_contains "$POST_CONFLICT_PATH" 'before invoking the guarded check, Firstmate must parse the primary sixteen-field checkpoint, revalidate the exact repository/head/base identity and require the PR head OID equals `POST_HEAD`, then atomically preserve every field, set canonical `pr_url={canonical url}` and `phase=pr-check-pending`' \
  "post-conflict path can publish before the pending receipt"
assert_contains "$POST_CONFLICT_PATH" '"$FM_ROOT/bin/fm-pr-check.sh" --expected-head "$POST_HEAD" --prior-head "$EXPECTED" --expected-repo "$REMOTE_REPO" --expected-base "$BASE_BRANCH" --expected-branch "$BRANCH" "$TASK_ID" "$PR_URL"' \
  "post-conflict pending recovery lacks an operational guarded helper invocation"
assert_contains "$POST_CONFLICT_PATH" 'a complete internally consistent artifact set bound to the same task and canonical identity at the immediately checkpointed prior published head `EXPECTED`' \
  "post-conflict pending recovery rejects the exact prior generation"
assert_contains "$POST_CONFLICT_PATH" 'the helper refuses partial, foreign, ambiguous, unbound, or any other generation' \
  "post-conflict pending recovery accepts an unsafe artifact generation"
assert_contains "$POST_CONFLICT_PATH" 'before metadata, poll, registration, migration, or retirement writes, and lookup failure or mismatch must produce zero writes' \
  "post-conflict guarded check can publish before expected-head validation"
assert_contains "$POST_CONFLICT_PATH" 'Any failed or interrupted publication retains `pr-check-pending`, appends `blocked: direct-PR PR-check artifact reconciliation failed; checkpoint retained`' \
  "post-conflict pending recovery does not fail closed"
assert_contains "$POST_CONFLICT_PATH" 'After helper exit zero, Firstmate must use that same operational validation interface to require the complete exact artifact set and metadata `pr_head=POST_HEAD`, then atomically advance to `pr-check-confirmed`' \
  "post-conflict first publication lacks confirmed receipt"
assert_contains "$POST_CONFLICT_PATH" 'validate the private namespace contains only `BASE_FETCH_REF` and `FEATURE_FETCH_REF`, delete both exact refs in one `git update-ref --stdin` transaction' \
  "post-conflict finalization does not retire exact private refs transactionally"
assert_grep "Stay inside this worktree except for the status file, the task-specific Firstmate checkpoint at '$BRIEF_HOME/state/parallel-direct-pr.direct-pr-lease', and its exact stable temporary sibling at '$BRIEF_HOME/state/parallel-direct-pr.direct-pr-lease.tmp'; modify nothing else outside it." "$DIRECT_PR_BRIEF" \
  "generated direct-PR brief lost its bounded state-path exception"
for forbidden_endpoint_command in \
  'git fetch origin' \
  'git ls-remote --exit-code origin' \
  'origin "$POST_HEAD:$FEATURE_REF"'; do
  if grep -Fq "$forbidden_endpoint_command" "$DIRECT_PR_BRIEF"; then
    fail "generated direct-PR brief uses origin instead of the bound push endpoint: $forbidden_endpoint_command"
  fi
done
if grep -Fq 'refs/remotes/origin/' "$DIRECT_PR_BRIEF"; then
  fail "generated direct-PR brief writes shared origin tracking refs"
fi
CLASSIFIER_STATUS="$BRIEF_HOME/state/direct-pr-reconciliation.status"
printf '%s\n' 'PR ready: https://github.com/example/repo/pull/1 checkpoint=/tmp/checkpoint task=task workflow=post-conflict post_head=abc' > "$CLASSIFIER_STATUS"
signal_reason_is_actionable "$CLASSIFIER_STATUS" \
  || fail "existing status classifier did not surface the direct-PR PR-ready handoff"
assert_grep 'States: working, needs-decision, blocked, done, failed, plus the exact actionable post-conflict handoff PR ready:' "$DIRECT_PR_BRIEF" \
  "generated direct-PR status contract omits PR ready"
FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" ordinary-local local-project >/dev/null \
  || fail "ordinary brief scaffold failed"
assert_grep 'States: working, needs-decision, blocked, done, failed.' "$BRIEF_HOME/data/ordinary-local/brief.md" \
  "generic status contract changed for other modes"
assert_grep 'A mid-task `working:` line (including setup complete) is nonterminal:' "$BRIEF_HOME/data/ordinary-local/brief.md" \
  "ordinary ship brief does not protect multi-stage work from setup-complete termination"
DONE_SIGNAL_COUNT=$(grep -Fc 'append `done: PR {url}`' "$DIRECT_PR_BRIEF")
[ "$DONE_SIGNAL_COUNT" -eq 1 ] \
  || fail "generated direct-PR brief must emit one completion signal"
assert_grep 'After initial PR opening, or after Firstmate-confirmed post-conflict cleanup, append `done: PR {url}` to the status file and stop.' "$DIRECT_PR_BRIEF" \
  "generated direct-PR brief lost terminal completion boundary"
assert_grep 'When that later `done` arrives, Firstmate relays the already-armed PR state and must not run `fm-pr-check` or publish its metadata and poll a second time.' "$DIRECT_PR_BRIEF" \
  "generated direct-PR brief can register post-conflict PR state twice"

make_direct_pr_teardown_fixture() {
  local id=$1 fake
  fake="$TMP_ROOT/teardown-$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data" "$fake/config"
  ln -s "$ROOT/bin/fm-teardown.sh" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-tool-path-lib.sh" "$fake/bin/fm-tool-path-lib.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-watcher-protocol-lib.sh" "$fake/bin/fm-watcher-protocol-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-slot-owner-lib.sh" "$fake/bin/fm-slot-owner-lib.sh"
  ln -s "$ROOT/bin/fm-agent-cwd-lib.sh" "$fake/bin/fm-agent-cwd-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-worker-isolation-lib.sh" "$fake/bin/fm-worker-isolation-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/bin/fm-task-identity-lib.sh" <<'SH'
fm_assert_task_branch_matches_meta() { return 0; }
SH
  cat > "$fake/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/bin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TREEHOUSE_TEST_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TREEHOUSE_TEST_LOG"
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh" "$fake/bin/fm-fleet-sync.sh" "$fake/bin/tmux" "$fake/bin/treehouse"
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$fake/nonexistent-worktree
project=$fake/nonexistent-project
harness=claude
kind=ship
mode=direct-PR
yolo=off
backend=tmux
META
  printf '%s\n' "$fake"
}

MODE_REFUSAL_ID=direct-pr-mode-refusal
MODE_REFUSAL_HOME=$(make_direct_pr_teardown_fixture "$MODE_REFUSAL_ID")
MODE_REFUSAL_PRIMARY="$MODE_REFUSAL_HOME/state/$MODE_REFUSAL_ID.direct-pr-lease"
MODE_REFUSAL_TEMP="$MODE_REFUSAL_HOME/state/$MODE_REFUSAL_ID.direct-pr-lease.tmp"
printf '%s\n' fixture > "$MODE_REFUSAL_PRIMARY"
printf '%s\n' partial > "$MODE_REFUSAL_TEMP"
chmod 0644 "$MODE_REFUSAL_PRIMARY"
chmod 0644 "$MODE_REFUSAL_TEMP"
MODE_REFUSAL_ERR="$MODE_REFUSAL_HOME/teardown.err"
if ( cd "$MODE_REFUSAL_HOME" && env -u NO_MISTAKES_GATE \
  PATH="$MODE_REFUSAL_HOME/bin:$PATH" FM_HOME="$MODE_REFUSAL_HOME" \
  FM_ROOT_OVERRIDE="$MODE_REFUSAL_HOME" FM_STATE_OVERRIDE="$MODE_REFUSAL_HOME/state" \
  "$MODE_REFUSAL_HOME/bin/fm-teardown.sh" "$MODE_REFUSAL_ID" --force >/dev/null 2>"$MODE_REFUSAL_ERR" ); then
  fail "teardown accepted a mode-0644 durable direct-PR checkpoint"
fi
grep -qxF "REFUSED: unsafe direct-PR task state $MODE_REFUSAL_PRIMARY; preserving task state." "$MODE_REFUSAL_ERR" \
  || fail "teardown mode refusal did not report the exact unsafe primary checkpoint"
[ -f "$MODE_REFUSAL_PRIMARY" ] \
  || fail "teardown removed the refused mode-0644 durable checkpoint"
[ -f "$MODE_REFUSAL_TEMP" ] \
  || fail "teardown removed the stale temp after refusing the durable checkpoint"
[ -f "$MODE_REFUSAL_HOME/state/$MODE_REFUSAL_ID.meta" ] \
  || fail "teardown removed task state after refusing the durable checkpoint"

chmod 0600 "$MODE_REFUSAL_PRIMARY"
if ! ( cd "$MODE_REFUSAL_HOME" && env -u NO_MISTAKES_GATE \
  PATH="$MODE_REFUSAL_HOME/bin:$PATH" FM_HOME="$MODE_REFUSAL_HOME" \
  FM_ROOT_OVERRIDE="$MODE_REFUSAL_HOME" FM_STATE_OVERRIDE="$MODE_REFUSAL_HOME/state" \
  "$MODE_REFUSAL_HOME/bin/fm-teardown.sh" "$MODE_REFUSAL_ID" --force >/dev/null 2>"$MODE_REFUSAL_ERR" ); then
  sed -n '1,20p' "$MODE_REFUSAL_ERR" >&2
  fail "teardown rejected a private primary with a same-owner non-private stale temp"
fi
[ ! -e "$MODE_REFUSAL_PRIMARY" ] && [ ! -e "$MODE_REFUSAL_TEMP" ] \
  || fail "teardown did not remove both exact validated direct-PR state files"
[ ! -e "$MODE_REFUSAL_HOME/state/$MODE_REFUSAL_ID.meta" ] \
  || fail "teardown did not complete after the same primary was changed to mode 0600"

REF_CLEANUP_ID=direct-pr-ref-cleanup
REF_CLEANUP_HOME=$(make_direct_pr_teardown_fixture "$REF_CLEANUP_ID")
# A task worktree is a pooled linked worktree stamped by its owner: only that
# shape lets the ownership gate authorize the return this ordering check needs.
REF_CLEANUP_PROJECT="$REF_CLEANUP_HOME/project"
REF_CLEANUP_REPO="$REF_CLEANUP_HOME/worktree"
git init -q "$REF_CLEANUP_PROJECT"
git -C "$REF_CLEANUP_PROJECT" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m fixture
git -C "$REF_CLEANUP_PROJECT" worktree add -q --detach "$REF_CLEANUP_REPO" >/dev/null 2>&1
( . "$ROOT/bin/fm-slot-owner-lib.sh" \
  && fm_slot_stamp_write "$REF_CLEANUP_REPO" "$REF_CLEANUP_ID" "$REF_CLEANUP_HOME" ) \
  || fail "the direct-PR ref-cleanup fixture could not stamp its pooled slot"
REF_CLEANUP_OID=$(git -C "$REF_CLEANUP_REPO" rev-parse HEAD)
git -C "$REF_CLEANUP_REPO" update-ref "refs/firstmate/direct-pr/$REF_CLEANUP_ID/base" "$REF_CLEANUP_OID"
git -C "$REF_CLEANUP_REPO" update-ref "refs/firstmate/direct-pr/$REF_CLEANUP_ID/feature" "$REF_CLEANUP_OID"
git -C "$REF_CLEANUP_REPO" update-ref "refs/firstmate/direct-pr/$REF_CLEANUP_ID/ambiguous" "$REF_CLEANUP_OID"
cat > "$REF_CLEANUP_HOME/state/$REF_CLEANUP_ID.meta" <<META
window=fakeses:fm-$REF_CLEANUP_ID
worktree=$REF_CLEANUP_REPO
project=$REF_CLEANUP_PROJECT
harness=claude
kind=ship
mode=direct-PR
yolo=off
backend=tmux
META
REF_CLEANUP_ERR="$REF_CLEANUP_HOME/ref-cleanup.err"
if ( cd "$REF_CLEANUP_HOME" && env -u NO_MISTAKES_GATE \
  PATH="$REF_CLEANUP_HOME/bin:$PATH" FM_HOME="$REF_CLEANUP_HOME" \
  FM_ROOT_OVERRIDE="$REF_CLEANUP_HOME" FM_STATE_OVERRIDE="$REF_CLEANUP_HOME/state" \
  "$REF_CLEANUP_HOME/bin/fm-teardown.sh" "$REF_CLEANUP_ID" --force >/dev/null 2>"$REF_CLEANUP_ERR" ); then
  fail "teardown accepted an ambiguous direct-PR private ref namespace"
fi
grep -qF 'REFUSED: ambiguous direct-PR private ref namespace' "$REF_CLEANUP_ERR" \
  || fail "teardown did not report private-ref namespace ambiguity"
git -C "$REF_CLEANUP_REPO" update-ref -d "refs/firstmate/direct-pr/$REF_CLEANUP_ID/ambiguous"
REF_CLEANUP_LEASE="$REF_CLEANUP_HOME/state/$REF_CLEANUP_ID.direct-pr-lease"
REF_CLEANUP_LEASE_TMP="$REF_CLEANUP_HOME/state/$REF_CLEANUP_ID.direct-pr-lease.tmp"
printf 'durable-checkpoint\n' > "$REF_CLEANUP_LEASE"
chmod 0600 "$REF_CLEANUP_LEASE"
printf 'stable-temporary\n' > "$REF_CLEANUP_LEASE_TMP"
REF_CLEANUP_LEASE_HASH=$(shasum -a 256 "$REF_CLEANUP_LEASE")
REF_CLEANUP_LEASE_TMP_HASH=$(shasum -a 256 "$REF_CLEANUP_LEASE_TMP")
REF_TRANSACTION_FLAG="$REF_CLEANUP_HOME/fail-ref-transaction"
REF_TRANSACTION_HOOK="$REF_CLEANUP_PROJECT/.git/hooks/reference-transaction"
cat > "$REF_TRANSACTION_HOOK" <<EOF
#!/bin/sh
[ "\$1" != prepared ] || [ ! -e "$REF_TRANSACTION_FLAG" ]
EOF
chmod +x "$REF_TRANSACTION_HOOK"
touch "$REF_TRANSACTION_FLAG"
REF_CLEANUP_RETURN_LOG="$REF_CLEANUP_HOME/treehouse-return.log"
if ( cd "$REF_CLEANUP_HOME" && env -u NO_MISTAKES_GATE \
  PATH="$REF_CLEANUP_HOME/bin:$PATH" FM_HOME="$REF_CLEANUP_HOME" \
  FM_ROOT_OVERRIDE="$REF_CLEANUP_HOME" FM_STATE_OVERRIDE="$REF_CLEANUP_HOME/state" \
  FM_TREEHOUSE_TEST_LOG="$REF_CLEANUP_RETURN_LOG" \
  "$REF_CLEANUP_HOME/bin/fm-teardown.sh" "$REF_CLEANUP_ID" --force >/dev/null 2>"$REF_CLEANUP_ERR" ); then
  fail "teardown accepted a failed transactional direct-PR ref cleanup"
fi
grep -qF 'REFUSED: transactional direct-PR private ref cleanup failed' "$REF_CLEANUP_ERR" \
  || fail "teardown did not report transactional private-ref cleanup failure"
[ -s "$REF_CLEANUP_RETURN_LOG" ] \
  || fail "teardown attempted private-ref cleanup before worktree return"
[ -f "$REF_CLEANUP_HOME/state/$REF_CLEANUP_ID.meta" ] \
  || fail "teardown removed task state after transactional private-ref cleanup failed"
[ "$(shasum -a 256 "$REF_CLEANUP_LEASE")" = "$REF_CLEANUP_LEASE_HASH" ] \
  && [ "$(shasum -a 256 "$REF_CLEANUP_LEASE_TMP")" = "$REF_CLEANUP_LEASE_TMP_HASH" ] \
  || fail "transactional private-ref cleanup failure changed direct-PR checkpoints"
[ -n "$(git -C "$REF_CLEANUP_REPO" show-ref --verify --hash "refs/firstmate/direct-pr/$REF_CLEANUP_ID/base")" ] \
  && [ -n "$(git -C "$REF_CLEANUP_REPO" show-ref --verify --hash "refs/firstmate/direct-pr/$REF_CLEANUP_ID/feature")" ] \
  || fail "transactional private-ref cleanup failure deleted only part of the ref set"
rm -f "$REF_TRANSACTION_FLAG"
if ! ( cd "$REF_CLEANUP_HOME" && env -u NO_MISTAKES_GATE \
  PATH="$REF_CLEANUP_HOME/bin:$PATH" FM_HOME="$REF_CLEANUP_HOME" \
  FM_ROOT_OVERRIDE="$REF_CLEANUP_HOME" FM_STATE_OVERRIDE="$REF_CLEANUP_HOME/state" \
  "$REF_CLEANUP_HOME/bin/fm-teardown.sh" "$REF_CLEANUP_ID" --force >/dev/null 2>"$REF_CLEANUP_ERR" ); then
  sed -n '1,20p' "$REF_CLEANUP_ERR" >&2
  fail "teardown rejected the exact direct-PR private ref namespace"
fi
[ -z "$(git -C "$REF_CLEANUP_REPO" for-each-ref --format='%(refname)' "refs/firstmate/direct-pr/$REF_CLEANUP_ID/")" ] \
  || fail "teardown retained task-private direct-PR refs"
[ ! -e "$REF_CLEANUP_LEASE" ] && [ ! -e "$REF_CLEANUP_LEASE_TMP" ] \
  || fail "successful retry retained direct-PR checkpoints"

pass "intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work"
