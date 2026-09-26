#!/usr/bin/env bash
# Acceptance contract for bin/fm-pr-merge.sh's GitHub pre-merge gate.
# The GitHub path must match the existing GitLab path's fail-closed posture:
# verify the live pull request and every configured required check at its exact
# head before allowing one SHA-bound merge call, with no caller override path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-github-gate)
PR_URL=https://github.com/example/repo/pull/9
LIVE_HEAD=1111111111111111111111111111111111111111
OTHER_HEAD=2222222222222222222222222222222222222222
DEFAULT_REQUIRED_CHECKS=test,docker,review,security-review,test-integrity
DISTINCT_REVIEW_REQUIRED_CHECKS=test,docker,approval-check,security-review,test-integrity

make_case() {
  local name=$1 expected_head=${2:-$LIVE_HEAD} worktree_mode=${3:-missing}
  local case_dir fakebin worktree
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  worktree="$case_dir/missing-worktree"
  mkdir -p "$case_dir/home/state" "$fakebin"
  if [ "$worktree_mode" = existing ]; then
    worktree="$case_dir/worktree"
    mkdir -p "$worktree"
  fi
  # pr_head is the caller-recorded expectation that the live head must match.
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$PR_URL" \
    "pr_head=$expected_head"
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  add_forge_mocks "$case_dir"
  printf '%s\n' "$case_dir"
}

add_forge_mocks() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  *repos/example/repo/pulls/9*)
    [ ! -e "$FM_TEST_CASE_DIR/pull-read-fails" ] || exit 1
    cat "$FM_TEST_GITHUB_PR"
    ;;
  *repos/example/repo/commits/*/check-runs*)
    [ ! -e "$FM_TEST_CASE_DIR/check-runs-read-fails" ] || exit 1
    cat "$FM_TEST_GITHUB_CHECKS"
    ;;
  api\ graphql*)
    cat "$FM_TEST_GITHUB_OUTCOME"
    ;;
  *repos/example/repo/rules/branches/*)
    cat "$FM_TEST_GITHUB_RULES"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}"
    ;;
  *)
    printf 'unexpected gh-axi call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
}

write_pr() {
  local case_dir=$1 state=$2 mergeable_state=$3 head=$4 head_mode=${5:-value}
  local head_json
  case "$head_mode" in
    value) head_json="{\"sha\":\"$head\"}" ;;
    missing) head_json='{}' ;;
    null) head_json='{"sha":null}' ;;
    *) fail "write_pr: unknown head mode '$head_mode'" ;;
  esac
  case "$mergeable_state" in
    missing)
      printf '{"number":9,"state":"%s","head":%s}\n' \
        "$state" "$head_json" > "$case_dir/pull.json"
      ;;
    null)
      printf '{"number":9,"state":"%s","mergeable_state":null,"head":%s}\n' \
        "$state" "$head_json" > "$case_dir/pull.json"
      ;;
    *)
      printf '{"number":9,"state":"%s","mergeable_state":"%s","head":%s}\n' \
        "$state" "$mergeable_state" "$head_json" > "$case_dir/pull.json"
      ;;
  esac
}

write_checks() {
  local case_dir=$1 review_status=${2:-completed} review_conclusion=${3:-'"success"'}
  local include_integrity=${4:-true} review_head=${5:-$LIVE_HEAD} review_name=${6:-review}
  local total_count=5
  [ "$include_integrity" = true ] || total_count=4
  {
    printf '{"total_count":%s,"check_runs":[\n' "$total_count"
    printf '%s\n' \
      "{\"name\":\"test\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}," \
      "{\"name\":\"docker\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}," \
      "{\"name\":\"$review_name\",\"head_sha\":\"$review_head\",\"status\":\"$review_status\",\"conclusion\":$review_conclusion}," \
      "{\"name\":\"security-review\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}"
    if [ "$include_integrity" = true ]; then
      printf ',{"name":"test-integrity","head_sha":"%s","status":"completed","conclusion":"success"}\n' \
        "$LIVE_HEAD"
    else
      printf '\n'
    fi
    printf '%s\n' ']}'
  } > "$case_dir/check-runs.json"
}

write_bespoke_checks() {
  local case_dir=$1
  printf '{"total_count":1,"check_runs":[{"name":"bespoke-contract","head_sha":"%s","status":"completed","conclusion":"success"}]}\n' \
    "$LIVE_HEAD" > "$case_dir/check-runs.json"
}

write_checks_without_review() {
  local case_dir=$1
  printf '%s\n' \
    "{\"total_count\":4,\"check_runs\":[" \
    "{\"name\":\"test\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}," \
    "{\"name\":\"docker\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}," \
    "{\"name\":\"security-review\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}," \
    "{\"name\":\"test-integrity\",\"head_sha\":\"$LIVE_HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}" \
    ']}' > "$case_dir/check-runs.json"
}

write_no_checks() {
  printf '%s\n' '{"total_count":0,"check_runs":[]}' > "$1/check-runs.json"
}

run_merge() {
  local case_dir=$1 required_checks=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_PR_REQUIRED_CHECKS="$required_checks" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GITHUB_PR="$case_dir/pull.json" \
  FM_TEST_GITHUB_CHECKS="$case_dir/check-runs.json" \
  FM_TEST_GITHUB_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GITHUB_RULES="$case_dir/github-rules" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 "$PR_URL" "$@"
}

run_merge_with_required_checks_unset() {
  local case_dir=$1
  shift
  env -u FM_PR_REQUIRED_CHECKS \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_CASE_DIR="$case_dir" \
    FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GITHUB_PR="$case_dir/pull.json" \
    FM_TEST_GITHUB_CHECKS="$case_dir/check-runs.json" \
    FM_TEST_GITHUB_OUTCOME="$case_dir/github-outcome" \
    FM_TEST_GITHUB_RULES="$case_dir/github-rules" \
    PATH="$case_dir/fakebin:$PATH" \
      "$PR_MERGE" task-x1 "$PR_URL" "$@"
}

merge_call_count() {
  grep -c '^pr merge ' "$1/gh-axi.log" || true
}

assert_no_merge_call() {
  local case_dir=$1 clause=$2
  [ "$(merge_call_count "$case_dir")" -eq 0 ] \
    || fail "$clause: the GitHub merge command was reached"
}

assert_no_forge_call() {
  local case_dir=$1 clause=$2
  [ ! -s "$case_dir/gh.log" ] && [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "$clause: a forge call was made before the refusal"
}

assert_refusal_reason() {
  local case_dir=$1 clause=$2 token=$3
  grep -Fi -- "$token" "$case_dir/stderr" >/dev/null \
    || fail "$clause: refusal reason did not name '$token'"
}

assert_refused() {
  local case_dir=$1 rc=$2 clause=$3 token=$4
  expect_code 1 "$rc" "$clause: fm-pr-merge must refuse"
  assert_refusal_reason "$case_dir" "$clause" "$token"
  assert_no_merge_call "$case_dir" "$clause"
}

test_clause_1_refuses_non_open_pull_request() {
  local case_dir rc
  case_dir=$(make_case state-not-open)
  write_pr "$case_dir" closed clean "$LIVE_HEAD"
  write_checks "$case_dir"

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" "clause 1 state-not-open" "closed"
  pass "clause 1: GitHub merge refuses a pull request whose state is not open"
}

test_clause_2_refuses_every_non_clean_mergeable_state() {
  local mergeable_state reason_token case_dir rc
  for mergeable_state in blocked dirty behind unknown unstable has_hooks missing null; do
    case_dir=$(make_case "mergeable-$mergeable_state")
    write_pr "$case_dir" open "$mergeable_state" "$LIVE_HEAD"
    write_checks "$case_dir"

    run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?

    reason_token=$mergeable_state
    case "$mergeable_state" in
      missing|null) reason_token=mergeable_state ;;
    esac
    assert_refused "$case_dir" "$rc" \
      "clause 2 mergeable-state-$mergeable_state" "$reason_token"
  done
  pass "clause 2: GitHub merge allows only clean and refuses every other mergeable state"
}

test_clause_3_refuses_missing_configured_check() {
  local case_dir rc
  case_dir=$(make_case required-check-missing)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir" completed '"success"' false

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 required-check-missing" "test-integrity"
  pass "clause 3: GitHub merge refuses when a configured required check is missing"
}

test_clause_3_refuses_non_success_check_conclusions() {
  local name status conclusion case_dir rc
  while IFS='|' read -r name status conclusion; do
    case_dir=$(make_case "required-check-$name")
    write_pr "$case_dir" open clean "$LIVE_HEAD"
    write_checks "$case_dir" "$status" "$conclusion" true "$LIVE_HEAD" approval-check

    run_merge "$case_dir" "$DISTINCT_REVIEW_REQUIRED_CHECKS" \
      < /dev/null \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?

    assert_refused "$case_dir" "$rc" \
      "clause 3 required-check-$name" "approval-check"
  done <<'CASES'
failure|completed|"failure"
pending|in_progress|null
cancelled|completed|"cancelled"
CASES
  pass "clause 3: GitHub merge refuses failed, pending, and cancelled required checks"
}

test_clause_3_required_check_list_is_configurable() {
  local case_dir rc
  case_dir=$(make_case required-check-configurable)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir"

  run_merge "$case_dir" bespoke-contract \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 required-check-list-configurable" "bespoke-contract"
  pass "clause 3: the required-check list comes from repository configuration"
}

test_clause_3_required_check_names_match_exactly() {
  local case_dir rc
  case_dir=$(make_case required-check-name-exact)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks_without_review "$case_dir"

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 required-check-name-exact" "review"
  pass "clause 3: required check names use exact equality, never substring matching"
}

test_clause_3_unset_required_checks_enforces_non_empty_defaults() {
  local case_dir rc
  case_dir=$(make_case required-checks-unset)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_no_checks "$case_dir"

  run_merge_with_required_checks_unset "$case_dir" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 required-checks-unset-default" "check"
  pass "clause 3: an unset required-check configuration enforces non-empty defaults"
}

test_clause_3_empty_required_checks_refuses_before_forge_calls() {
  local name required_checks case_dir rc
  for name in empty whitespace; do
    case "$name" in
      empty) required_checks='' ;;
      whitespace) required_checks='   ' ;;
    esac
    case_dir=$(make_case "required-checks-$name" "$LIVE_HEAD" existing)
    write_pr "$case_dir" open clean "$LIVE_HEAD"
    write_checks "$case_dir"

    run_merge "$case_dir" "$required_checks" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?

    expect_code 1 "$rc" "clause 3 required-checks-$name: fm-pr-merge must refuse"
    assert_refusal_reason "$case_dir" "clause 3 required-checks-$name" "configuration"
    assert_no_forge_call "$case_dir" "clause 3 required-checks-$name"
  done
  pass "clause 3: empty and whitespace-only required-check configuration fail closed"
}

test_clause_3_refuses_unreadable_required_check_results() {
  local name case_dir rc
  for name in api-failure invalid-json; do
    case_dir=$(make_case "required-checks-$name")
    write_pr "$case_dir" open clean "$LIVE_HEAD"
    if [ "$name" = api-failure ]; then
      write_checks "$case_dir"
      : > "$case_dir/check-runs-read-fails"
    else
      printf '%s\n' 'not-json' > "$case_dir/check-runs.json"
    fi

    run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?

    assert_refused "$case_dir" "$rc" \
      "clause 3 required-checks-$name" "check"
  done
  pass "clause 3: unreadable required-check results fail closed"
}

test_clause_3_refuses_unreadable_pull_request_response() {
  local case_dir rc
  case_dir=$(make_case pull-response-unreadable)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir"
  : > "$case_dir/pull-read-fails"

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 pull-response-unreadable" "pull request"
  pass "clause 3: an unreadable pull request response fails closed distinctly"
}

test_clause_3_refuses_missing_or_null_live_head() {
  local head_mode case_dir rc
  for head_mode in missing null; do
    case_dir=$(make_case "live-head-$head_mode")
    write_pr "$case_dir" open clean "$LIVE_HEAD" "$head_mode"
    write_checks "$case_dir"

    run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?

    assert_refused "$case_dir" "$rc" \
      "clause 3 live-head-$head_mode" "head"
  done
  pass "clause 3: a missing or null live pull request head fails closed distinctly"
}

test_clause_3_refuses_successful_check_at_a_different_head() {
  local case_dir rc
  case_dir=$(make_case required-check-wrong-head)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir" completed '"success"' true "$OTHER_HEAD" approval-check

  run_merge "$case_dir" "$DISTINCT_REVIEW_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" \
    "clause 3 required-check-wrong-head" "approval-check"
  grep -F -- "$OTHER_HEAD" "$case_dir/stderr" >/dev/null \
    || fail "clause 3 required-check-wrong-head: refusal did not name the check's stale head"
  pass "clause 3: each successful required check must report the exact verified head"
}

test_clause_4_refuses_stale_expected_head() {
  local case_dir rc
  case_dir=$(make_case stale-expected-head "$OTHER_HEAD")
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir"

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  assert_refused "$case_dir" "$rc" "clause 4 stale-head" "$OTHER_HEAD"
  grep -F -- "$LIVE_HEAD" "$case_dir/stderr" >/dev/null \
    || fail "clause 4 stale-head: refusal did not name the live head"
  pass "clause 4: GitHub merge refuses when the caller's expected head is stale"
}

test_clause_5_refuses_caller_safety_overrides_before_forge_calls() {
  local name token case_dir rc
  while IFS= read -r name; do
    # An existing worktree makes fm-pr-check.sh's normal gh pr view observable,
    # so a zero-call assertion proves rejection precedes metadata recording.
    case_dir=$(make_case "override-$name" "$LIVE_HEAD" existing)
    write_pr "$case_dir" open clean "$LIVE_HEAD"
    write_checks "$case_dir"

    case "$name" in
      admin)
        token=--admin
        run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" -- --admin \
          < /dev/null \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        ;;
      admin-equals)
        token=--admin
        run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" -- --admin=true \
          < /dev/null \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        ;;
      match-head)
        token=--match-head-commit
        run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" -- --match-head-commit "$OTHER_HEAD" \
          < /dev/null \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        ;;
      match-head-equals)
        token=--match-head-commit
        run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" --match-head-commit="$OTHER_HEAD" \
          < /dev/null \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        ;;
    esac
    rc=$?

    expect_code 1 "$rc" "clause 5 override-$name: fm-pr-merge must refuse"
    assert_refusal_reason "$case_dir" "clause 5 override-$name" "$token"
    assert_no_forge_call "$case_dir" "clause 5 override-$name"
  done <<'CASES'
admin
admin-equals
match-head
match-head-equals
CASES
  pass "clause 5: GitHub merge refuses admin and head-binding overrides before every forge call"
}

test_green_exact_head_proceeds_to_one_sha_bound_merge() {
  local case_dir rc merge_line
  case_dir=$(make_case green-exact-head)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_checks "$case_dir"

  run_merge "$case_dir" "$DEFAULT_REQUIRED_CHECKS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "green exact-head: fm-pr-merge should proceed"
  [ "$(merge_call_count "$case_dir")" -eq 1 ] \
    || fail "green exact-head: expected exactly one GitHub merge call"
  merge_line=$(grep '^pr merge ' "$case_dir/gh-axi.log")
  case "$merge_line" in
    *"--match-head-commit $LIVE_HEAD"*|*"--match-head-commit=$LIVE_HEAD"*) ;;
    *) fail "green exact-head: merge call was not bound to verified head $LIVE_HEAD: $merge_line" ;;
  esac
  case "$merge_line" in
    *--admin*) fail "green exact-head: merge call reached for an admin override: $merge_line" ;;
  esac
  grep -F -- "repos/example/repo/commits/$LIVE_HEAD/check-runs" "$case_dir/gh.log" >/dev/null \
    || fail "green exact-head: required checks were not read at the verified head endpoint"
  pass "green exact-head: open, clean, green pull request reaches one SHA-bound merge call"
}

test_configured_green_check_list_proceeds() {
  local case_dir rc
  case_dir=$(make_case configured-green-check-list)
  write_pr "$case_dir" open clean "$LIVE_HEAD"
  write_bespoke_checks "$case_dir"

  run_merge "$case_dir" bespoke-contract \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "configured green check list: fm-pr-merge should proceed"
  [ "$(merge_call_count "$case_dir")" -eq 1 ] \
    || fail "configured green check list: expected exactly one GitHub merge call"
  pass "configured required-check list: a custom all-green list reaches one merge call"
}

test_clause_1_refuses_non_open_pull_request
test_clause_2_refuses_every_non_clean_mergeable_state
test_clause_3_refuses_missing_configured_check
test_clause_3_refuses_non_success_check_conclusions
test_clause_3_required_check_list_is_configurable
test_clause_3_required_check_names_match_exactly
test_clause_3_unset_required_checks_enforces_non_empty_defaults
test_clause_3_empty_required_checks_refuses_before_forge_calls
test_clause_3_refuses_unreadable_required_check_results
test_clause_3_refuses_unreadable_pull_request_response
test_clause_3_refuses_missing_or_null_live_head
test_clause_3_refuses_successful_check_at_a_different_head
test_clause_4_refuses_stale_expected_head
test_clause_5_refuses_caller_safety_overrides_before_forge_calls
test_green_exact_head_proceeds_to_one_sha_bound_merge
test_configured_green_check_list_proceeds
