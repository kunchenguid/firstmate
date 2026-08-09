#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-disposition)
STATE="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"
export FM_STATE_OVERRIDE="$STATE"
export FM_HOME="$TMP_ROOT/home"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$ROOT/bin/fm-disposition-lib.sh"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_GH_BODY:-}"
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

new_pr_attempt() {  # <key> <copy>
  local key=$1 copy=$2 aid head
  fm_git_init_commit "$copy"
  head=$(git -C "$copy" rev-parse HEAD)
  git init -q --bare "$copy-remote.git"
  git -C "$copy" remote add origin "$copy-remote.git"
  git -C "$copy" push -q origin HEAD:main
  git -C "$copy" fetch -q origin main
  aid=$(fm_attempt_alloc pi "$key" holu) || fail alloc
  fm_attempt_freeze_allocation "$aid" 1 "$(jq -nc --arg c "$copy" '{provider:"tmux",copy:$c}')" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","repo_identity":"https://github.com/acme/widgets.git"}' || fail freeze
  fm_attempt_observe "$aid" 1 forge "$(jq -nc --arg key "$key" --arg head "$head" \
    '{provider:"github",repo:"acme/widgets",source:$key,target:null,head:$head,state:"merged",before_sha:null,after_sha:null,pr:"https://github.com/acme/widgets/pull/7"}')" || fail forge
  printf '%s\n' "$aid"
}

disposition_json() {
  fm_disposition_evidence_live "$1"
}

test_exact_merged_pr_is_landed_with_evidence() {
  local aid copy head out
  copy="$TMP_ROOT/wt-merged"
  aid=$(new_pr_attempt dos-a "$copy")
  head=$(git -C "$copy" rev-parse HEAD)
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"MERGED",headRefOid:$head,baseRefName:"main"}')"
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.disposition')" = landed ] || fail "$out"
  printf '%s' "$out" | jq -e --arg head "$head" '.reason == "merged-exact-pr-head" and .evidence.copy_head == $head' >/dev/null || fail "missing deterministic merge evidence"
  pass "exact merged PR identity, target, and content produce landed evidence"
}

test_multi_commit_squash_is_landed_by_exact_content() {
  local aid copy landed base head out
  copy="$TMP_ROOT/wt-squash"
  landed="$TMP_ROOT/landed-squash"
  fm_git_init_commit "$copy"
  git init -q --bare "$copy-remote.git"
  git -C "$copy" remote add origin "$copy-remote.git"
  git -C "$copy" push -q origin HEAD:main
  git -C "$copy" fetch -q origin main
  base=$(git -C "$copy" rev-parse HEAD)
  printf 'first\n' > "$copy/first.txt"
  git -C "$copy" add first.txt
  git -C "$copy" -c user.name=test -c user.email=test@example.com commit -qm first
  printf 'second\n' > "$copy/second.txt"
  git -C "$copy" add second.txt
  git -C "$copy" -c user.name=test -c user.email=test@example.com commit -qm second
  head=$(git -C "$copy" rev-parse HEAD)
  git clone -q -b main "$copy-remote.git" "$landed"
  git -C "$copy" diff --binary "$base" "$head" | git -C "$landed" apply
  git -C "$landed" add .
  git -C "$landed" -c user.name=test -c user.email=test@example.com commit -qm 'squash feature'
  git -C "$landed" push -q origin HEAD:main
  aid=$(fm_attempt_alloc pi dos-squash holu) || fail alloc
  fm_attempt_freeze_allocation "$aid" 1 "$(jq -nc --arg c "$copy" '{provider:"tmux",copy:$c}')" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","repo_identity":"https://github.com/acme/widgets.git"}' || fail freeze
  fm_attempt_observe "$aid" 1 forge "$(jq -nc --arg head "$head" \
    '{provider:"github",repo:"acme/widgets",source:"dos-squash",target:null,head:$head,state:"merged",before_sha:null,after_sha:null,pr:"https://github.com/acme/widgets/pull/8"}')" || fail forge
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"MERGED",headRefOid:$head,baseRefName:"main"}')"
  out=$(disposition_json "$aid")
  printf '%s' "$out" | jq -e '.disposition == "landed" and .reason == "merged-exact-pr-head"' >/dev/null \
    || fail "multi-commit squash was not recognized by exact content: $out"
  pass "multi-commit squash landing is recognized by exact target content"
}

test_active_open_pr_is_unknown() {
  local aid copy head out
  copy="$TMP_ROOT/wt-open"
  aid=$(new_pr_attempt dos-open "$copy")
  head=$(git -C "$copy" rev-parse HEAD)
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"OPEN",headRefOid:$head,baseRefName:"main"}')"
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.disposition')" = unknown ] || fail "OPEN PR was preserved-unlanded: $out"
  pass "an active OPEN PR is unknown"
}

test_closed_pr_requires_exact_durable_recovery() {
  local aid copy head out
  copy="$TMP_ROOT/wt-closed"
  aid=$(new_pr_attempt dos-closed "$copy")
  head=$(git -C "$copy" rev-parse HEAD)
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"CLOSED",headRefOid:$head,baseRefName:"main"}')"
  out=$(disposition_json "$aid")
  printf '%s' "$out" | jq -e '.disposition == "preserved_unlanded" and .evidence.recovery.durable == true' >/dev/null \
    || fail "closed exact PR lacked recovery evidence: $out"
  pass "closed-unmerged is preserved only with exact durable PR-head recovery"
}

test_pr_identity_target_and_content_mismatches_are_unknown() {
  local aid copy head out empty_tree unrelated
  copy="$TMP_ROOT/wt-mismatch"
  aid=$(new_pr_attempt dos-mm "$copy")
  head=$(git -C "$copy" rev-parse HEAD)
  export FAKE_GH_BODY='{"state":"MERGED","headRefOid":"different","baseRefName":"main"}'
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.reason')" = pr-content-mismatch ] || fail "$out"
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"MERGED",headRefOid:$head,baseRefName:"release"}')"
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.reason')" = pr-target-mismatch ] || fail "$out"
  empty_tree=$(git -C "$copy" mktree < /dev/null)
  unrelated=$(printf 'unrelated\n' | git -C "$copy" -c user.name=test -c user.email=test@example.com commit-tree "$empty_tree")
  git -C "$copy" push -q --force origin "$unrelated:refs/heads/main"
  git -C "$copy" fetch -q origin main
  export FAKE_GH_BODY="$(jq -nc --arg head "$head" '{state:"MERGED",headRefOid:$head,baseRefName:"main"}')"
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.reason')" = target-content-not-equivalent ] || fail "$out"
  git -C "$copy" push -q --force origin "$head:refs/heads/main"
  git -C "$copy" fetch -q origin main
  fm_attempt_observe "$aid" 1 forge "$(jq -nc --arg head "$head" \
    '{provider:"github",repo:"other/widgets",source:"dos-mm",head:$head,state:"merged",pr:"https://github.com/acme/widgets/pull/7"}')" || fail forge
  out=$(disposition_json "$aid")
  [ "$(printf '%s' "$out" | jq -r '.reason')" = pr-repo-mismatch ] || fail "$out"
  pass "PR head, target, content, and repository mismatches fail closed"
}

test_authorized_local_only_merge_is_landed() {
  local project copy before after aid out
  project="$TMP_ROOT/local-project"
  copy="$TMP_ROOT/local-copy"
  fm_git_init_commit "$project"
  git -C "$project" branch -M main
  before=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --detach "$copy" HEAD >/dev/null
  printf 'local content\n' > "$copy/local.txt"
  git -C "$copy" add local.txt
  git -C "$copy" -c user.name=test -c user.email=test@example.com commit -qm local
  after=$(git -C "$copy" rev-parse HEAD)
  git -C "$project" merge --ff-only "$after" >/dev/null
  aid=$(fm_attempt_alloc pi dos-local holu) || fail alloc
  fm_attempt_freeze_allocation "$aid" 1 "$(jq -nc --arg c "$copy" '{provider:"tmux",copy:$c}')" \
    "$(jq -nc --arg repo "$project" '{mode:"local-only",base:"main",target:"origin/main",repo_identity:$repo}')" || fail freeze
  fm_attempt_observe "$aid" 1 forge "$(jq -nc --arg repo "$project" --arg before "$before" --arg after "$after" \
    '{provider:"local",repo:$repo,source:"dos-local",target:"main",head:$after,state:"merged",before_sha:$before,after_sha:$after,pr:null}')" || fail forge
  out=$(FM_REFILL_PROJECT="$project" disposition_json "$aid")
  printf '%s' "$out" | jq -e '.disposition == "landed" and .reason == "authorized-local-merge"' >/dev/null || fail "$out"
  pass "authorized local-only fast-forward evidence is recognized"
}

test_authority_is_bound_to_all_present_identity_fields() {
  local file out
  file="$STATE/authority-current.json"
  printf '%s\n' '{"transition":"close","task_key":"dos-auth","attempt_id":"dos-auth-a1","generation":1,"authority":"captain:merge"}' > "$file"
  out=$(FM_AUTHORITY_FILE="$file" fm_authority_for close dos-auth dos-auth-a1 1) || fail authority
  [ "$out" = captain:merge ] || fail "$out"
  fm_authority_for close other dos-auth-a1 1 >/dev/null 2>&1 && fail "task mismatch accepted"
  fm_authority_for close dos-auth wrong 1 >/dev/null 2>&1 && fail "attempt mismatch accepted"
  fm_authority_for close dos-auth dos-auth-a1 2 >/dev/null 2>&1 && fail "generation mismatch accepted"
  fm_authority_for claim dos-auth dos-auth-a1 1 >/dev/null 2>&1 && fail "transition mismatch accepted"
  pass "authority binds transition, task, attempt, and generation"
}

test_exact_merged_pr_is_landed_with_evidence
test_multi_commit_squash_is_landed_by_exact_content
test_active_open_pr_is_unknown
test_closed_pr_requires_exact_durable_recovery
test_pr_identity_target_and_content_mismatches_are_unknown
test_authorized_local_only_merge_is_landed
test_authority_is_bound_to_all_present_identity_fields
