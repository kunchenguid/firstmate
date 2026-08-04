#!/usr/bin/env bash
# Tests for the sole PR merge path.
#
# The merge gate must record live PR state, require a clear crosscheck for the
# exact live head and claims, and pass that reviewed SHA to GitHub's atomic
# merge API. The gh-axi double emits only recorded 0.1.25 TOON shapes and
# rejects the unsupported raw-gh and unguarded `pr merge` surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
API_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-api.toon"
CLAIMS_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-view-full.toon"
MERGE_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-merge-success.toon"
QUEUE_FIXTURE="$ROOT/tests/fixtures/gh-axi-merge-enqueued.toon"
PR_URL=https://github.com/ruby-dlee/firstmate/pull/72
HEAD_SHA=c9cbe79154013efcec9aa478f1476d0eff6c63df
BASE_SHA=68f014697d0eea733a4e7c0294becff4e76c7bcf
fm_test_tmproot_into TMP_ROOT fm-pr-merge-tests

make_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1" "$case_dir/wt" "$case_dir/fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=codex" \
    "model=gpt-5.5" \
    "account_home=$case_dir/author-home"
  install_gh_axi_fake "$case_dir"
  seed_clear_ledger "$case_dir"
  printf '%s\n' "$case_dir"
}

install_gh_axi_fake() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "api /repos/ruby-dlee/firstmate/pulls/72")
    case "${FM_TEST_DRAFT_MODE:-ready}" in
      ready)
        sed \
          -e "s/c9cbe79154013efcec9aa478f1476d0eff6c63df/$FM_TEST_HEAD/" \
          -e "s/68f014697d0eea733a4e7c0294becff4e76c7bcf/$FM_TEST_BASE/" \
          "$FM_TEST_API_FIXTURE"
        ;;
      draft)
        sed \
          -e 's/^draft: false$/draft: true/' \
          -e "s/c9cbe79154013efcec9aa478f1476d0eff6c63df/$FM_TEST_HEAD/" \
          -e "s/68f014697d0eea733a4e7c0294becff4e76c7bcf/$FM_TEST_BASE/" \
          "$FM_TEST_API_FIXTURE"
        ;;
      missing)
        sed \
          -e '/^draft: false$/d' \
          -e "s/c9cbe79154013efcec9aa478f1476d0eff6c63df/$FM_TEST_HEAD/" \
          -e "s/68f014697d0eea733a4e7c0294becff4e76c7bcf/$FM_TEST_BASE/" \
          "$FM_TEST_API_FIXTURE"
        ;;
      *) exit 98 ;;
    esac
    ;;
  "pr view")
    [ "$*" = "pr view 72 --repo ruby-dlee/firstmate --full" ] || exit 97
    cat "$FM_TEST_CLAIMS_FIXTURE"
    ;;
  "api PUT")
    case " $* " in
      *" --field sha=$FM_TEST_HEAD "*) ;;
      *)
        echo "merge omitted exact SHA" >&2
        exit 96
        ;;
    esac
    case "${FM_TEST_MERGE_MODE:-success}" in
      success) cat "$FM_TEST_MERGE_FIXTURE" ;;
      enqueued) cat "$FM_TEST_QUEUE_FIXTURE" ;;
      race)
        echo "error: HEAD WAS MODIFIED" >&2
        exit 41
        ;;
      *) exit 98 ;;
    esac
    ;;
  *)
    echo "unsupported fake gh-axi invocation: $*" >&2
    exit 97
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

seed_clear_ledger() {
  local case_dir=$1 claims_digest
  claims_digest=$(python3 -c '
import hashlib, json
claims = {"number": 72, "title": "feat: observed contract fixture", "body": "Complete claims returned by --full."}
print(hashlib.sha256(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
')
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<EOF
{
  "schema": "firstmate.crosscheck-ledger.v2",
  "task_id": "task-x1",
  "pull_request": "$PR_URL",
  "findings": [],
  "runs": [{
    "at": "2026-08-02T00:00:00Z",
    "head_sha": "$HEAD_SHA",
    "base_sha": "$BASE_SHA",
    "claims_sha256": "$claims_digest",
    "reviewer": {"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh","account_home":"/reviewer"},
    "state": "clear",
    "summary": "clear",
    "citations": [{"path":"app.txt","line":1}],
    "updated_findings": [],
    "new_findings": [],
    "active_blockers": [],
    "suspicions": []
  }]
}
EOF
}

run_pr_merge() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_GH_AXI_BIN="$case_dir/fakebin/gh-axi" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_API_FIXTURE="$API_FIXTURE" \
  FM_TEST_CLAIMS_FIXTURE="$CLAIMS_FIXTURE" \
  FM_TEST_MERGE_FIXTURE="$MERGE_FIXTURE" \
  FM_TEST_QUEUE_FIXTURE="$QUEUE_FIXTURE" \
  FM_TEST_HEAD="${FM_TEST_HEAD:-$HEAD_SHA}" \
  FM_TEST_BASE="$BASE_SHA" \
    "$PR_MERGE" "$@"
}

test_exact_head_is_recorded_and_merged_atomically() {
  local case_dir output
  case_dir=$(make_case exact-head)
  : > "$case_dir/gh-axi.log"
  output=$(run_pr_merge "$case_dir" task-x1 "$PR_URL") \
    || fail "exact-head merge should succeed"
  assert_contains "$output" '"merged": true' "merge success was not confirmed"
  assert_contains "$output" '"outcome": "merged"' \
    "merge success did not report the merged outcome"
  assert_contains "$output" '"observed_state": "merged"' \
    "merge success did not report the merged observed state"
  assert_grep "pr=$PR_URL" "$case_dir/state/task-x1.meta" \
    "PR URL was not recorded before merge"
  assert_grep "pr_head=$HEAD_SHA" "$case_dir/state/task-x1.meta" \
    "exact reviewed head was not recorded before merge"
  assert_grep 'fm-github-pr.py state' "$case_dir/state/task-x1.check.sh" \
    "merge poll did not use the observed gh-axi adapter"
  assert_no_grep 'gh pr view' "$case_dir/state/task-x1.check.sh" \
    "merge poll regressed to raw gh"
  assert_grep "api PUT /repos/ruby-dlee/firstmate/pulls/72/merge --field sha=$HEAD_SHA --field merge_method=squash" "$case_dir/gh-axi.log" \
    "merge did not use the atomic expected-head API"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "merge regressed to the unguarded gh-axi pr merge surface"
  pass "merge records and atomically submits the exact crosschecked SHA"
}

test_merge_queue_acceptance_is_enqueued_unconfirmed() {
  local case_dir output
  case_dir=$(make_case merge-queue)
  : > "$case_dir/gh-axi.log"
  output=$(FM_TEST_MERGE_MODE=enqueued run_pr_merge "$case_dir" task-x1 "$PR_URL") \
    || fail "successful queue submission was reported as a merge failure"
  assert_contains "$output" '"merged": false' \
    "queue submission claimed the PR was merged"
  assert_contains "$output" '"outcome": "enqueued/unconfirmed"' \
    "queue submission did not report enqueued/unconfirmed"
  assert_contains "$output" '"observed_state": "open"' \
    "queue submission did not report the independent open readback"
  case "$output" in
    *'"merged": true'*) fail "queue submission claimed merged success" ;;
  esac
  [ "$(grep -c '^api /repos/ruby-dlee/firstmate/pulls/72$' "$case_dir/gh-axi.log")" -eq 5 ] \
    || fail "queue submission did not add exactly one independent PR readback"
  pass "merge queue acceptance is enqueued/unconfirmed, not merged or failed"
}

test_draft_and_undeterminable_status_refuse_before_merge() {
  local mode case_dir rc
  for mode in draft missing; do
    case_dir=$(make_case "draft-$mode")
    : > "$case_dir/gh-axi.log"
    set +e
    FM_TEST_DRAFT_MODE=$mode run_pr_merge "$case_dir" task-x1 "$PR_URL" \
      > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "draft mode $mode"
    assert_grep "pr=$PR_URL" "$case_dir/state/task-x1.meta" \
      "draft mode $mode did not preserve PR metadata before refusal"
    assert_grep "pr_head=$HEAD_SHA" "$case_dir/state/task-x1.meta" \
      "draft mode $mode did not preserve the live head before refusal"
    assert_no_grep '^api PUT ' "$case_dir/gh-axi.log" \
      "draft mode $mode reached the merge mutation"
  done
  assert_grep 'because it is a draft' "$TMP_ROOT/draft-draft/err" \
    "draft merge refusal did not name the draft"
  assert_grep 'draft status could not be determined' "$TMP_ROOT/draft-missing/err" \
    "undeterminable draft status did not fail closed"
  pass "draft and undeterminable draft status refuse after recording, before merge"
}

test_missing_or_malformed_ledger_blocks_merge() {
  local mode case_dir rc
  for mode in missing malformed; do
    case_dir=$(make_case "$mode-ledger")
    if [ "$mode" = missing ]; then
      rm "$case_dir/data/task-x1/crosscheck-ledger.json"
    else
      printf '{"schema":"firstmate.crosscheck-ledger.v2","task_id":"task-x1","pull_request":"%s","findings":null,"runs":[]}\n' "$PR_URL" \
        > "$case_dir/data/task-x1/crosscheck-ledger.json"
    fi
    : > "$case_dir/gh-axi.log"
    set +e
    run_pr_merge "$case_dir" task-x1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode ledger"
    assert_no_grep 'api PUT' "$case_dir/gh-axi.log" \
      "$mode ledger reached the merge API"
    assert_grep 'CROSSCHECK UNREVIEWED' "$case_dir/err" \
      "$mode ledger did not block loudly"
  done
  pass "missing and malformed findings ledgers are unreviewed"
}

test_changed_head_blocks_before_merge() {
  local case_dir rc changed_head
  case_dir=$(make_case changed-head)
  changed_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  set +e
  FM_TEST_HEAD=$changed_head run_pr_merge "$case_dir" task-x1 "$PR_URL" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "changed head"
  assert_grep 'no crosscheck attempt exists for the live head, base, and PR claims' "$case_dir/err" \
    "changed head did not invalidate the old verdict"
  assert_no_grep 'api PUT' "$case_dir/gh-axi.log" \
    "changed head reached the merge API"
  pass "a force-pushed head invalidates the earlier crosscheck verdict"
}

test_post_verify_race_is_rejected_by_github() {
  local case_dir rc
  case_dir=$(make_case post-verify-race)
  : > "$case_dir/gh-axi.log"
  set +e
  FM_TEST_MERGE_MODE=race run_pr_merge "$case_dir" task-x1 "$PR_URL" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "post-verify head race"
  assert_grep "--field sha=$HEAD_SHA" "$case_dir/gh-axi.log" \
    "race request did not carry the reviewed SHA"
  assert_grep 'HEAD WAS MODIFIED' "$case_dir/err" \
    "atomic merge rejection was not surfaced"
  pass "a head change after verification is rejected by the atomic merge request"
}

test_merge_options_translate_to_api_fields() {
  local case_dir
  case_dir=$(make_case options)
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 "$PR_URL" -- --method=rebase --subject 'Release title' --body 'Release body' \
    > "$case_dir/out" 2> "$case_dir/err" || fail "supported merge options failed"
  assert_grep '--field merge_method=rebase --field commit_title=Release title --field commit_message=Release body' "$case_dir/gh-axi.log" \
    "supported merge options did not map to API fields"
  pass "supported merge options retain atomic expected-head semantics"
}

test_unsupported_async_and_delete_flags_fail_before_state_change() {
  local flag case_dir rc
  for flag in --auto --delete-branch; do
    case_dir=$(make_case "unsupported-${flag#--}")
    : > "$case_dir/gh-axi.log"
    set +e
    run_pr_merge "$case_dir" task-x1 "$PR_URL" -- "$flag" \
      > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$flag"
    assert_grep 'incompatible with an atomic expected-head merge' "$case_dir/err" \
      "$flag refusal did not explain the atomicity conflict"
    [ ! -s "$case_dir/gh-axi.log" ] || fail "$flag performed GitHub operations before refusal"
    assert_no_grep "pr=$PR_URL" "$case_dir/state/task-x1.meta" \
      "$flag recorded merge state before refusal"
  done
  pass "async and branch-delete flags cannot bypass atomic merge semantics"
}

test_missing_meta_and_malformed_url_fail_fast() {
  local case_dir rc
  case_dir=$(make_case fail-fast)
  rm "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing meta reached GitHub"

  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$case_dir/wt"
  set +e
  run_pr_merge "$case_dir" task-x1 https://gitlab.com/example/repo/pull/1 \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed URL"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "malformed URL reached GitHub"
  pass "missing metadata and malformed PR URLs fail before GitHub operations"
}

test_exact_head_is_recorded_and_merged_atomically
test_draft_and_undeterminable_status_refuse_before_merge
test_merge_queue_acceptance_is_enqueued_unconfirmed
test_missing_or_malformed_ledger_blocks_merge
test_changed_head_blocks_before_merge
test_post_verify_race_is_rejected_by_github
test_merge_options_translate_to_api_fields
test_unsupported_async_and_delete_flags_fail_before_state_change
test_missing_meta_and_malformed_url_fail_fast
