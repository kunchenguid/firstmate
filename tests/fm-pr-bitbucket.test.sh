#!/usr/bin/env bash
# Tests for Bitbucket Cloud pull request support across the PR scripts: URL
# parsing in bin/fm-pr-lib.sh, recording and arming in bin/fm-pr-check.sh, the
# static merge poll in bin/fm-pr-poll.sh, state reads in bin/fm-pr-lib.sh and
# bin/fm-pr-state.sh, and the guarded merge in bin/fm-pr-merge.sh. The
# Bitbucket API is the stub tests/lib.sh's fm_fake_bitbucket_curl drops, so no
# case reaches the network; landed-work proof after a squash merge is covered by
# tests/fm-teardown.test.sh, which owns the teardown fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-pr-bitbucket-tests)
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the scripts' own jq programs over API-shaped JSON with the real jq, which was not found"

BB_PATH=example-team/sample_repo
BB_URL="https://bitbucket.org/$BB_PATH/pull-requests/7"
BB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BB_ABBREV=${BB_HEAD:0:12}
BB_OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# A synthetic credential whose token carries both characters curl's config
# syntax must escape, so the escaping itself is under test.
BB_EMAIL=captain@example.invalid
BB_TOKEN='synthetic"tok\en-0123'
BB_EXPECT_USER='captain@example.invalid:synthetic\"tok\\en-0123'

# A sandbox for one case: task metadata, a worktree, a backlog for the
# captain-hold read, and a fakebin holding the Bitbucket API stub plus inert
# GitHub CLIs so nothing reaches a real forge. Echoes the case directory.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_fake_exit0 "$fakebin" gh gh-axi glab
  fm_fake_bitbucket_curl "$fakebin" "$case_dir/bb"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" > "$case_dir/bb/pr.json"
  fm_bitbucket_pr_json 7 MERGED "$BB_ABBREV" > "$case_dir/bb/pr-post.json"
  printf '{"hash":"%s"}\n' "$BB_HEAD" > "$case_dir/bb/commit.json"
  printf '%s\n' '{"values":[{"key":"pipeline","name":"Pipeline #1","state":"SUCCESSFUL"}],"pagelen":100,"page":1}' \
    > "$case_dir/bb/statuses.json"
  printf '%s\n' '{"values":[],"pagelen":100,"page":1}' > "$case_dir/bb/restrictions.json"
  printf '%s\n' '{"type":"pullrequest","id":7,"state":"MERGED"}' > "$case_dir/bb/merge.json"
  printf '%s\n' "$case_dir"
}

bb_env() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  HOME="$case_dir/user-home" \
  NO_MISTAKES_BITBUCKET_EMAIL="${FM_TEST_BB_EMAIL-$BB_EMAIL}" \
  NO_MISTAKES_BITBUCKET_API_TOKEN="${FM_TEST_BB_TOKEN-$BB_TOKEN}" \
  FM_TEST_BB_EXPECT_USER="$BB_EXPECT_USER" \
  FM_PR_BITBUCKET_CONFIRM_ATTEMPTS="${FM_PR_BITBUCKET_CONFIRM_ATTEMPTS:-2}" \
  FM_PR_BITBUCKET_CONFIRM_INTERVAL=0 \
  PATH="$case_dir/fakebin:$PATH" \
    "$@"
}

run_merge() {
  local case_dir=$1
  shift
  bb_env "$case_dir" "$ROOT/bin/fm-pr-merge.sh" task-x1 "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
}

run_check() {
  local case_dir=$1
  bb_env "$case_dir" "$ROOT/bin/fm-pr-check.sh" task-x1 "$BB_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
}

assert_token_never_in_argv() {
  local case_dir=$1 label=$2
  [ -s "$case_dir/bb/curl-argv.log" ] || fail "$label: the Bitbucket API was never called"
  if grep -qF 'synthetic' "$case_dir/bb/curl-argv.log"; then
    fail "$label: the API token reached a curl argument"
  fi
}

test_url_parse_accepts_canonical_bitbucket_urls() {
  local out
  out=$(bash -c '. "$1"; fm_pr_url_parse "$2" || exit 1
    printf "%s|%s|%s|%s|%s|%s\n" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$FM_PR_OWNER" "$FM_PR_URL"' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$BB_URL") || fail "the canonical Bitbucket URL did not parse"
  assert_equals "bitbucket|bitbucket.org|$BB_PATH|7||$BB_URL" "$out" \
    "a Bitbucket URL must parse into the provider-tagged identity with no GitHub owner"
  bash -c '. "$1"; fm_pr_url_parse "$2"' _ "$ROOT/bin/fm-pr-lib.sh" \
    'https://bitbucket.org/my-team_2/repo.name-x/pull-requests/12345' \
    || fail "a workspace and slug using every allowed character must parse"
  pass "canonical Bitbucket Cloud pull request URLs parse"
}

test_url_parse_refuses_malformed_bitbucket_urls() {
  local url
  for url in \
    "https://bitbucket.org/$BB_PATH/pull-requests/7/" \
    "https://bitbucket.org/$BB_PATH/pull-requests/7/overview" \
    "https://bitbucket.org/$BB_PATH/pull-requests/07" \
    "https://bitbucket.org/$BB_PATH/pull-requests/0" \
    "https://bitbucket.org/$BB_PATH/pull-requests/7?at=main" \
    "http://bitbucket.org/$BB_PATH/pull-requests/7" \
    "https://www.bitbucket.org/$BB_PATH/pull-requests/7" \
    'https://bitbucket.org/ExampleTeam/repo/pull-requests/7' \
    'https://bitbucket.org/ws/-repo/pull-requests/7' \
    'https://bitbucket.org/-ws/repo/pull-requests/7' \
    'https://bitbucket.org/ws/../pull-requests/7' \
    'https://bitbucket.org/ws/repo/extra/pull-requests/7' \
    'https://bitbucket.org/ws/pull-requests/7' \
    'https://bitbucket.org/ws/repo/pull/7' \
    'https://bitbucket.org/ws/repo/-/merge_requests/7' \
    'https://bitbucket.org/c/project/+/7' \
    'https://bitbucket.example/projects/P/repos/r/pull-requests/7'; do
    if bash -c '. "$1"; fm_pr_url_parse "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$url"; then
      fail "a malformed or non-Cloud Bitbucket URL parsed: $url"
    fi
  done
  pass "malformed Bitbucket URLs, other forges' shapes on bitbucket.org, and Data Center URLs are refused"
}

test_record_read_reports_state_and_merged() {
  local case_dir out
  case_dir=$(make_case record-read)
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  out=$(bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_record "$2" 7 || exit 1
    printf "%s %s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"' _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH") \
    || fail "record-read: an open pull request could not be read"
  assert_equals "OPEN false" "$out" "record-read: an open pull request must read as open and unmerged"
  cp "$case_dir/bb/pr-post.json" "$case_dir/bb/pr.json"
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  out=$(bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_record "$2" 7 || exit 1
    printf "%s %s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"' _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH") \
    || fail "record-read: a merged pull request could not be read"
  assert_equals "MERGED true" "$out" "record-read: a merged pull request must read as merged"
  fm_bitbucket_pr_json 8 MERGED "$BB_ABBREV" > "$case_dir/bb/pr.json"
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  if bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_record "$2" 7' _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH"; then
    fail "record-read: a record for another pull request was accepted"
  fi
  printf '401\n' > "$case_dir/bb/pr.code"
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  if bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_record "$2" 7' _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH"; then
    fail "record-read: an unauthorized answer was read as a state"
  fi
  assert_token_never_in_argv "$case_dir" record-read
  assert_grep "user = \"$BB_EXPECT_USER\"" "$case_dir/bb/curl-config.log" \
    "record-read: the credential was not handed to curl on stdin, escaped"
  pass "the Bitbucket record read reports state and merged, refuses another record, and keeps the token out of argv"
}

test_statuses_read_follows_pagination_only_under_the_api_base() {
  local case_dir out
  case_dir=$(make_case statuses-pages)
  printf '%s\n' "{\"values\":[{\"key\":\"a\",\"state\":\"SUCCESSFUL\"}],\"next\":\"https://api.bitbucket.org/2.0/repositories/$BB_PATH/commit/$BB_HEAD/statuses?pagelen=100&page=2\"}" \
    > "$case_dir/bb/statuses.json"
  printf '%s\n' '{"values":[{"key":"b","name":"B","state":"FAILED"}]}' > "$case_dir/bb/statuses-2.json"
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  out=$(bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_statuses "$2" "$3" || exit 1
    printf "%s" "$FM_PR_BITBUCKET_VALUES" | jq -c "map(.key + \"=\" + .state)"' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH" "$BB_HEAD") || fail "statuses-pages: a two-page status list could not be read"
  assert_equals '["a=SUCCESSFUL","b=FAILED"]' "$out" "statuses-pages: both pages must be read"
  printf '%s\n' '{"values":[],"next":"https://evil.example/2.0/steal?page=2"}' > "$case_dir/bb/statuses.json"
  # shellcheck disable=SC2016 # bash -c expands its own positional arguments.
  if bb_env "$case_dir" bash -c '. "$1"; fm_pr_bitbucket_read_statuses "$2" "$3"' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$BB_PATH" "$BB_HEAD"; then
    fail "statuses-pages: a next link to another host was followed or ignored instead of refused"
  fi
  if grep -q 'evil.example' "$case_dir/bb/curl-argv.log"; then
    fail "statuses-pages: the credential was sent to the host a next link named"
  fi
  pass "the status read follows pagination and refuses a next link that leaves the API base"
}

test_check_records_full_head_and_arms_the_poll() {
  local case_dir rc=0
  case_dir=$(make_case check-arms)
  run_check "$case_dir" || rc=$?
  expect_code 0 "$rc" "check-arms: a ready Bitbucket pull request should arm"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "pr=$BB_URL" "$case_dir/state/task-x1.meta" "check-arms: pr= was not recorded"
  assert_grep "pr_head=$BB_HEAD" "$case_dir/state/task-x1.meta" \
    "check-arms: the abbreviated head was not recorded as the full resolved hash"
  assert_equals bitbucket "$(head -1 "$case_dir/state/task-x1.pr-poll")" \
    "check-arms: the poll sidecar is not tagged as a Bitbucket pull request"
  assert_present "$case_dir/state/task-x1.check.sh" "check-arms: no poll was armed"
  assert_token_never_in_argv "$case_dir" check-arms
  pass "fm-pr-check records a Bitbucket pull request with its full head and arms the poll"
}

test_check_refuses_a_draft() {
  local case_dir rc=0
  case_dir=$(make_case check-draft)
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" true > "$case_dir/bb/pr.json"
  run_check "$case_dir" || rc=$?
  expect_code 1 "$rc" "check-draft: a draft Bitbucket pull request must not arm"
  assert_grep 'is a draft pull request' "$case_dir/stderr" "check-draft: the refusal did not name the draft"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" "check-draft: a draft was recorded"
  assert_absent "$case_dir/state/task-x1.check.sh" "check-draft: a draft armed a poll"
  pass "fm-pr-check refuses a draft Bitbucket pull request"
}

test_check_refuses_without_the_credential() {
  local case_dir rc=0
  case_dir=$(make_case check-no-credential)
  FM_TEST_BB_TOKEN='' run_check "$case_dir" || rc=$?
  expect_code 1 "$rc" "check-no-credential: arming without the token must refuse"
  assert_grep 'requires the NO_MISTAKES_BITBUCKET_API_TOKEN environment variable' "$case_dir/stderr" \
    "check-no-credential: the refusal did not name the missing variable"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" "check-no-credential: the URL was recorded anyway"
  assert_absent "$case_dir/state/task-x1.check.sh" "check-no-credential: a poll was armed anyway"
  assert_absent "$case_dir/bb/curl-argv.log" "check-no-credential: the API was called without a credential"
  pass "fm-pr-check refuses a Bitbucket watch without the credential and names it"
}

test_poll_wakes_only_on_an_exact_merged_record() {
  local case_dir out
  case_dir=$(make_case poll)
  poll() {
    bb_env "$case_dir" "$ROOT/bin/fm-pr-poll.sh" --validated bitbucket "$1" bitbucket.org "$BB_PATH" 7
  }
  out=$(poll "$BB_URL")
  assert_equals '' "$out" "poll: an open pull request woke the poll"
  cp "$case_dir/bb/pr-post.json" "$case_dir/bb/pr.json"
  out=$(poll "$BB_URL")
  assert_equals merged "$out" "poll: a merged pull request did not wake the poll"
  out=$(poll "https://bitbucket.org/other/repo/pull-requests/7")
  assert_equals '' "$out" "poll: a URL that does not rebuild from the identity was polled"
  printf '500\n' > "$case_dir/bb/pr.code"
  out=$(poll "$BB_URL")
  assert_equals '' "$out" "poll: an error status woke the poll"
  rm -f "$case_dir/bb/pr.code"
  out=$(FM_TEST_BB_TOKEN='' poll "$BB_URL")
  assert_equals '' "$out" "poll: a poll without the credential woke"
  assert_token_never_in_argv "$case_dir" poll
  pass "the Bitbucket merge poll wakes only on the exact merged record and stays silent otherwise"
}

test_pr_state_reports_bitbucket_blockers() {
  local case_dir out participants
  case_dir=$(make_case pr-state)
  out=$(bb_env "$case_dir" "$ROOT/bin/fm-pr-state.sh" "$BB_URL") || fail "pr-state: a clean pull request errored"
  assert_equals '' "$out" "pr-state: a clean open pull request must print nothing"
  participants='[{"user":{"nickname":"reviewer1"},"role":"REVIEWER","approved":false,"state":"changes_requested"},{"user":{"nickname":"reviewer2"},"approved":true,"state":"approved"}]'
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" true main "$participants" > "$case_dir/bb/pr.json"
  printf '%s\n' '{"values":[{"key":"pipeline","state":"FAILED"},{"key":"lint","state":"SUCCESSFUL"},{"key":"deploy","state":"INPROGRESS"}]}' \
    > "$case_dir/bb/statuses.json"
  out=$(bb_env "$case_dir" "$ROOT/bin/fm-pr-state.sh" "$BB_URL") || fail "pr-state: a blocked pull request errored"
  assert_equals "DRAFT: pull request is not ready for review
CHECK: pipeline (FAILED)
CHECK: deploy (INPROGRESS)
REVIEW: reviewer1 CHANGES_REQUESTED" "$out" "pr-state: the Bitbucket blockers were not reported"
  printf '%s\n' '{"values":[]}' > "$case_dir/bb/statuses.json"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" > "$case_dir/bb/pr.json"
  out=$(bb_env "$case_dir" "$ROOT/bin/fm-pr-state.sh" "$BB_URL") || fail "pr-state: an unbuilt pull request errored"
  assert_equals 'CHECKS: none reported yet' "$out" "pr-state: an unbuilt head was read as ready"
  cp "$case_dir/bb/pr-post.json" "$case_dir/bb/pr.json"
  out=$(bb_env "$case_dir" "$ROOT/bin/fm-pr-state.sh" "$BB_URL") || fail "pr-state: a merged pull request errored"
  assert_equals 'STATE: merged' "$out" "pr-state: a merged pull request must report only that"
  pass "fm-pr-state reports a Bitbucket pull request's state, draft, builds, and requested changes"
}

test_merge_succeeds_with_read_back_and_keeps_the_branch() {
  local case_dir rc=0
  case_dir=$(make_case merge-ok)
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-ok: a green open pull request should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals '{"type":"pullrequest","close_source_branch":false}' "$(cat "$case_dir/bb/merge-body.json")" \
    "merge-ok: the merge request must keep the source branch and use the branch's own strategy"
  assert_grep "verified: $BB_URL is merged at the verified head $BB_HEAD" "$case_dir/stdout" \
    "merge-ok: the landed merge was not proven by reading it back"
  assert_grep "pr=$BB_URL" "$case_dir/state/task-x1.meta" "merge-ok: pr= was not recorded before merging"
  assert_present "$case_dir/state/task-x1.pr-poll-merge-notified" "merge-ok: the landed outcome was not recorded"
  assert_token_never_in_argv "$case_dir" merge-ok
  pass "fm-pr-merge merges a green Bitbucket pull request, keeps its branch, and proves the merge by reading it back"
}

test_merge_passes_a_requested_strategy() {
  local case_dir rc=0
  case_dir=$(make_case merge-squash)
  run_merge "$case_dir" "$BB_URL" -- --squash || rc=$?
  expect_code 0 "$rc" "merge-squash: a squash merge should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals '{"type":"pullrequest","close_source_branch":false,"merge_strategy":"squash"}' \
    "$(cat "$case_dir/bb/merge-body.json")" "merge-squash: the requested strategy was not sent"
  case_dir=$(make_case merge-rebase)
  rc=0
  run_merge "$case_dir" "$BB_URL" -- --rebase || rc=$?
  expect_code 0 "$rc" "merge-rebase: the shared --rebase spelling should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals '{"type":"pullrequest","close_source_branch":false,"merge_strategy":"rebase_fast_forward"}' \
    "$(cat "$case_dir/bb/merge-body.json")" "merge-rebase: --rebase was not sent as rebase_fast_forward"
  case_dir=$(make_case merge-delete-branch)
  rc=0
  run_merge "$case_dir" "$BB_URL" -- --delete-branch || rc=$?
  expect_code 1 "$rc" "merge-delete-branch: branch deletion without an attended override must refuse"
  assert_absent "$case_dir/bb/merge-called" "merge-delete-branch: a merge was requested anyway"
  rc=0
  run_merge "$case_dir" "$BB_URL" --attended-override -- --delete-branch || rc=$?
  expect_code 0 "$rc" "merge-delete-branch: an attended branch deletion should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals '{"type":"pullrequest","close_source_branch":true}' "$(cat "$case_dir/bb/merge-body.json")" \
    "merge-delete-branch: the attended deletion was not sent"
  case_dir=$(make_case merge-bad-arg)
  local arg
  for arg in --subject --fast-forward; do
    rc=0
    run_merge "$case_dir" "$BB_URL" -- "$arg" || rc=$?
    expect_code 1 "$rc" "merge-bad-arg: $arg has no Bitbucket meaning and must refuse"
    assert_grep "extra merge argument '$arg' does not apply to a Bitbucket pull request" "$case_dir/stderr" \
      "merge-bad-arg: the $arg refusal did not explain"
  done
  assert_absent "$case_dir/bb/merge-called" "merge-bad-arg: a merge was requested anyway"
  pass "fm-pr-merge sends a requested Bitbucket strategy and refuses arguments it cannot translate"
}

test_merge_refuses_red_and_unreported_required_builds() {
  local case_dir rc=0
  case_dir=$(make_case merge-red)
  printf '%s\n' '{"values":[{"key":"pipeline","state":"FAILED"},{"key":"deploy","state":"INPROGRESS"}]}' \
    > "$case_dir/bb/statuses.json"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-red: a red pull request must not merge"
  assert_grep "build 'pipeline' is FAILED, not SUCCESSFUL" "$case_dir/stderr" "merge-red: the failed build was not named"
  assert_grep "build 'deploy' is INPROGRESS, not SUCCESSFUL" "$case_dir/stderr" "merge-red: the running build was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-red: a merge was requested anyway"

  case_dir=$(make_case merge-required)
  printf '%s\n' '{"values":[{"kind":"require_passing_builds_to_merge","branch_match_kind":"glob","pattern":"ma*","value":2},{"kind":"require_passing_builds_to_merge","branch_match_kind":"glob","pattern":"release/*","value":5}]}' \
    > "$case_dir/bb/restrictions.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-required: a head short of the required builds must not merge"
  assert_grep "base branch main requires 2 successful builds, and 1 reported at head $BB_HEAD" "$case_dir/stderr" \
    "merge-required: the unmet required build count was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-required: a merge was requested anyway"

  case_dir=$(make_case merge-required-model)
  printf '%s\n' '{"values":[{"kind":"require_passing_builds_to_merge","branch_match_kind":"branching_model","branch_type":"development","value":3}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' '{"development":{"name":"main","use_mainbranch":true,"branch":{"name":"main"}},"branch_types":[]}' \
    > "$case_dir/bb/model.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-required-model: a branching-model requirement must apply to its development branch"
  assert_grep "base branch main requires 3 successful builds" "$case_dir/stderr" \
    "merge-required-model: the branching-model requirement was not applied"

  # A named branch type matches by the branching model's own prefix for that
  # type: it applies to a destination under the prefix and to no other.
  local feature_model='{"development":{"name":"main","use_mainbranch":true,"branch":{"name":"main"}},"branch_types":[{"kind":"release","prefix":"release/"},{"kind":"feature","prefix":"feature/"}]}'
  case_dir=$(make_case merge-type-unmet)
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false feature/login > "$case_dir/bb/pr.json"
  printf '%s\n' '{"values":[{"kind":"require_passing_builds_to_merge","branch_match_kind":"branching_model","branch_type":"feature","value":2}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' "$feature_model" > "$case_dir/bb/model.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-type-unmet: a named branch type requirement must apply under its prefix"
  assert_grep "base branch feature/login requires 2 successful builds, and 1 reported at head $BB_HEAD" "$case_dir/stderr" \
    "merge-type-unmet: the named branch type requirement was not applied"
  assert_absent "$case_dir/bb/merge-called" "merge-type-unmet: a merge was requested anyway"

  case_dir=$(make_case merge-type-met)
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false feature/login > "$case_dir/bb/pr.json"
  printf '%s\n' '{"values":[{"kind":"require_passing_builds_to_merge","branch_match_kind":"branching_model","branch_type":"feature","value":1}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' "$feature_model" > "$case_dir/bb/model.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-type-met: a met named branch type requirement must not refuse"$'\n'"$(cat "$case_dir/stderr")"
  assert_present "$case_dir/bb/merge-called" "merge-type-met: the eligible merge was not requested"

  case_dir=$(make_case merge-type-other-branch)
  printf '%s\n' '{"values":[{"kind":"require_passing_builds_to_merge","branch_match_kind":"branching_model","branch_type":"feature","value":3}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' "$feature_model" > "$case_dir/bb/model.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-type-other-branch: a named branch type requirement must not apply outside its prefix"$'\n'"$(cat "$case_dir/stderr")"
  assert_present "$case_dir/bb/merge-called" "merge-type-other-branch: the eligible merge was not requested"

  case_dir=$(make_case merge-restrictions-unreadable)
  printf '%s\n' '{"type":"error","error":{"message":"Access denied"}}' > "$case_dir/bb/restrictions.json"
  printf '403\n' > "$case_dir/bb/restrictions.code"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-restrictions-unreadable: an unreadable restriction set must refuse"
  assert_grep "branch restrictions for base branch main could not be read (HTTP 403; reading them needs repository admin access), so an unmet merge check cannot be ruled out" \
    "$case_dir/stderr" "merge-restrictions-unreadable: the refusal did not name the missing read"
  assert_absent "$case_dir/bb/merge-called" "merge-restrictions-unreadable: a merge was requested anyway"
  pass "fm-pr-merge refuses red builds and an unmet required build count, applies a named branch type only under its prefix, and refuses an unreadable restriction set"
}

test_merge_refuses_draft_closed_and_missing_credentials() {
  local case_dir rc=0
  case_dir=$(make_case merge-draft)
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" true > "$case_dir/bb/pr.json"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-draft: a draft must not merge"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" "merge-draft: the draft was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-draft: a merge was requested anyway"

  case_dir=$(make_case merge-declined)
  fm_bitbucket_pr_json 7 DECLINED "$BB_ABBREV" > "$case_dir/bb/pr.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-declined: a declined pull request must not merge"
  assert_grep 'state is "DECLINED", not OPEN' "$case_dir/stderr" "merge-declined: the state was not named"

  case_dir=$(make_case merge-no-credential)
  rc=0
  FM_TEST_BB_EMAIL='' run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-no-credential: a merge without the credential must refuse"
  assert_grep 'requires the NO_MISTAKES_BITBUCKET_EMAIL environment variable' "$case_dir/stderr" \
    "merge-no-credential: the refusal did not name the missing variable"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" "merge-no-credential: state was recorded before the refusal"
  pass "fm-pr-merge refuses a draft, a closed pull request, and a missing credential"
}

test_merge_waivers_follow_the_attended_rules() {
  local case_dir rc=0
  case_dir=$(make_case merge-allow-red)
  printf '%s\n' '{"values":[{"key":"flaky","state":"FAILED"},{"key":"pipeline","state":"SUCCESSFUL"}]}' \
    > "$case_dir/bb/statuses.json"
  run_merge "$case_dir" "$BB_URL" --allow-red flaky || rc=$?
  expect_code 0 "$rc" "merge-allow-red: an attended waiver of the exact failed key should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_present "$case_dir/bb/merge-called" "merge-allow-red: the waived merge was not requested"

  case_dir=$(make_case merge-allow-red-other)
  printf '%s\n' '{"values":[{"key":"flaky","state":"FAILED"}]}' > "$case_dir/bb/statuses.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" --allow-red other || rc=$?
  expect_code 1 "$rc" "merge-allow-red-other: a waiver naming another key must not merge"
  assert_absent "$case_dir/bb/merge-called" "merge-allow-red-other: a merge was requested anyway"

  case_dir=$(make_case merge-allow-missing)
  rc=0
  run_merge "$case_dir" "$BB_URL" --allow-missing pipeline || rc=$?
  expect_code 2 "$rc" "merge-allow-missing: --allow-missing must be refused on Bitbucket"
  assert_grep 'does not apply to Bitbucket' "$case_dir/stderr" "merge-allow-missing: the refusal did not explain"

  case_dir=$(make_case merge-allow-red-away)
  printf '%s\n' '{"values":[{"key":"flaky","state":"FAILED"}]}' > "$case_dir/bb/statuses.json"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge task-x1 when green' >/dev/null \
    || fail "merge-allow-red-away: could not write the away record"
  rc=0
  run_merge "$case_dir" "$BB_URL" --allow-red flaky || rc=$?
  expect_code 2 "$rc" "merge-allow-red-away: --allow-red must be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" "merge-allow-red-away: the refusal did not explain"
  assert_absent "$case_dir/bb/merge-called" "merge-allow-red-away: a merge was requested anyway"
  pass "Bitbucket build waivers match the exact key, stay attended-only, and --allow-missing is refused"
}

test_merge_under_away_authority_is_synchronous_and_gated() {
  local case_dir rc=0
  case_dir=$(make_case merge-away)
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge task-x1 when green' >/dev/null \
    || fail "merge-away: could not write the away record"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-away: a green pull request should merge under away authority"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'away' "$case_dir/state/task-x1.merge-authority" \
    "merge-away: the merge was not recorded under away authority"

  case_dir=$(make_case merge-away-red)
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge task-x1 when green' >/dev/null \
    || fail "merge-away-red: could not write the away record"
  printf '%s\n' '{"values":[{"key":"pipeline","state":"FAILED"}]}' > "$case_dir/bb/statuses.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-away-red: away authority must not merge a red pull request"
  assert_absent "$case_dir/bb/merge-called" "merge-away-red: a merge was requested anyway"
  pass "a Bitbucket merge under away authority stays synchronous, records that authority, and keeps the green gate"
}

test_merge_refuses_a_head_that_moved_before_the_request() {
  local case_dir rc=0
  case_dir=$(make_case merge-moved)
  fm_bitbucket_pr_json 7 OPEN "${BB_OTHER_HEAD:0:12}" > "$case_dir/bb/pr-moved.json"
  printf '{"hash":"%s"}\n' "$BB_OTHER_HEAD" > "$case_dir/bb/commit-${BB_OTHER_HEAD:0:12}.json"
  # Reads one and two are the recording and the verification; the third is the
  # final read inside the away-record lock, which is where the head has moved.
  printf '3\n' > "$case_dir/bb/pr-moved.at"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-moved: a head that moved after verification must not merge"
  assert_grep 'changed after verification' "$case_dir/stderr" "merge-moved: the moved head was not reported"
  assert_grep 'nothing was merged' "$case_dir/stderr" "merge-moved: the refusal did not say nothing merged"
  assert_absent "$case_dir/bb/merge-called" "merge-moved: a merge was requested anyway"
  pass "fm-pr-merge re-reads the Bitbucket head immediately before merging and refuses a moved head"
}

test_merge_reports_forge_refusal_unconfirmed_and_wrong_head() {
  local case_dir rc=0
  case_dir=$(make_case merge-forge-refuses)
  printf '%s\n' '{"type":"error","error":{"message":"You can'"'"'t merge until you resolve all merge conflicts."}}' \
    > "$case_dir/bb/merge.json"
  printf '400\n' > "$case_dir/bb/merge.code"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-forge-refuses: a refused merge request must fail"
  assert_grep 'Bitbucket refused the merge request' "$case_dir/stderr" "merge-forge-refuses: the refusal was not reported"
  assert_grep 'resolve all merge conflicts' "$case_dir/stderr" "merge-forge-refuses: Bitbucket's own reason was not quoted"
  assert_absent "$case_dir/state/task-x1.pr-poll-merge-notified" "merge-forge-refuses: a landed outcome was recorded"

  case_dir=$(make_case merge-unconfirmed)
  printf '202\n' > "$case_dir/bb/merge.code"
  rm -f "$case_dir/bb/pr-post.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-unconfirmed: an accepted merge that has not landed yet must not fail the run"
  assert_grep 'landed state could not be confirmed; the merge poll remains armed' "$case_dir/stderr" \
    "merge-unconfirmed: the unconfirmed landing was not reported"
  assert_absent "$case_dir/state/task-x1.pr-poll-merge-notified" "merge-unconfirmed: an unproven merge was recorded as landed"
  assert_present "$case_dir/state/task-x1.check.sh" "merge-unconfirmed: the merge poll was not left armed"

  case_dir=$(make_case merge-wrong-head)
  fm_bitbucket_pr_json 7 MERGED "${BB_OTHER_HEAD:0:12}" > "$case_dir/bb/pr-post.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-wrong-head: a merge that landed another head must exit non-zero"
  assert_grep "reads back at head ${BB_OTHER_HEAD:0:12}, not the verified head $BB_HEAD" "$case_dir/stderr" \
    "merge-wrong-head: the unverified landed head was not reported"
  assert_present "$case_dir/state/task-x1.pr-poll-merge-notified" \
    "merge-wrong-head: the landed outcome must still be recorded"
  pass "fm-pr-merge quotes Bitbucket's refusal, leaves an unconfirmed merge armed, and flags a landed head it did not verify"
}

test_merge_refuses_unmet_review_merge_checks() {
  local case_dir rc=0 approved changes
  approved='[{"user":{"uuid":"{alice}","nickname":"alice"},"role":"REVIEWER","approved":true,"state":"approved"}]'
  changes='[{"user":{"uuid":"{bob}","nickname":"bob"},"role":"REVIEWER","approved":false,"state":"changes_requested"}]'

  case_dir=$(make_case merge-approvals)
  printf '%s\n' '{"values":[{"kind":"require_approvals_to_merge","branch_match_kind":"glob","pattern":"main","value":1},{"kind":"require_approvals_to_merge","branch_match_kind":"glob","pattern":"release/*","value":4},{"kind":"push","branch_match_kind":"glob","pattern":"main","users":[]}]}' \
    > "$case_dir/bb/restrictions.json"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-approvals: a pull request short of the required approvals must not merge"
  assert_grep "base branch main requires 1 approvals, and the pull request has 0" "$case_dir/stderr" \
    "merge-approvals: the unmet approval count was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-approvals: a merge was requested anyway"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false main "$approved" > "$case_dir/bb/pr.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-approvals: an approved pull request should merge"$'\n'"$(cat "$case_dir/stderr")"

  case_dir=$(make_case merge-default-reviewers)
  printf '%s\n' '{"values":[{"kind":"require_default_reviewer_approvals_to_merge","branch_match_kind":"glob","pattern":"*","value":1}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' '{"values":[{"type":"default_reviewer","reviewer_type":"repository","user":{"uuid":"{carol}"}}]}' \
    > "$case_dir/bb/default-reviewers.json"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false main "$approved" > "$case_dir/bb/pr.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-default-reviewers: an approval from someone other than a default reviewer must not count"
  assert_grep "base branch main requires 1 approvals from default reviewers, and the pull request has 0" "$case_dir/stderr" \
    "merge-default-reviewers: the unmet default-reviewer approval count was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-default-reviewers: a merge was requested anyway"
  printf '%s\n' '{"values":[{"type":"default_reviewer","reviewer_type":"repository","user":{"uuid":"{alice}"}}]}' \
    > "$case_dir/bb/default-reviewers.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-default-reviewers: a default reviewer's approval should merge"$'\n'"$(cat "$case_dir/stderr")"

  case_dir=$(make_case merge-default-reviewers-unreadable)
  printf '%s\n' '{"values":[{"kind":"require_default_reviewer_approvals_to_merge","branch_match_kind":"glob","pattern":"main","value":1}]}' \
    > "$case_dir/bb/restrictions.json"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false main "$approved" > "$case_dir/bb/pr.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-default-reviewers-unreadable: unreadable default reviewers must refuse"
  assert_grep "the default reviewers for base branch main could not be read (HTTP 404)" "$case_dir/stderr" \
    "merge-default-reviewers-unreadable: the missing read was not named"

  case_dir=$(make_case merge-changes-requested)
  printf '%s\n' '{"values":[{"kind":"require_no_changes_requested","branch_match_kind":"branching_model","branch_type":"development","value":null}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' '{"development":{"name":"main","use_mainbranch":true,"branch":{"name":"main"}},"branch_types":[]}' \
    > "$case_dir/bb/model.json"
  fm_bitbucket_pr_json 7 OPEN "$BB_ABBREV" false main "$changes" > "$case_dir/bb/pr.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" --allow-red pipeline || rc=$?
  expect_code 1 "$rc" "merge-changes-requested: requested changes must not merge, and --allow-red must not waive them"
  assert_grep "base branch main requires no requested changes, and changes are requested by bob" "$case_dir/stderr" \
    "merge-changes-requested: the reviewer requesting changes was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-changes-requested: a merge was requested anyway"

  case_dir=$(make_case merge-tasks)
  printf '%s\n' '{"values":[{"kind":"require_tasks_to_be_completed","branch_match_kind":"glob","pattern":"main"}]}' \
    > "$case_dir/bb/restrictions.json"
  printf '%s\n' '{"values":[{"id":1,"state":"RESOLVED"},{"id":2,"state":"UNRESOLVED"}]}' > "$case_dir/bb/tasks.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-tasks: an unresolved task must not merge"
  assert_grep "base branch main requires every task resolved, and 1 are unresolved" "$case_dir/stderr" \
    "merge-tasks: the unresolved task was not named"
  assert_absent "$case_dir/bb/merge-called" "merge-tasks: a merge was requested anyway"
  printf '%s\n' '{"values":[{"id":1,"state":"RESOLVED"}]}' > "$case_dir/bb/tasks.json"
  rc=0
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 0 "$rc" "merge-tasks: every task resolved should merge"$'\n'"$(cat "$case_dir/stderr")"
  pass "fm-pr-merge refuses a Bitbucket pull request that misses an approval, default-reviewer, changes-requested, or task merge check"
}

test_merge_reads_back_after_a_transport_failure() {
  local case_dir rc=0
  case_dir=$(make_case merge-transport)
  : > "$case_dir/bb/merge.transport-failure"
  run_merge "$case_dir" "$BB_URL" || rc=$?
  expect_code 1 "$rc" "merge-transport: a merge request with no HTTP response must fail"
  assert_grep "the merge request for $BB_URL got no HTTP response, and the pull request reads back as MERGED at head $BB_ABBREV; the merge poll remains armed" \
    "$case_dir/stderr" "merge-transport: the observed state was not read back and reported"
  assert_no_grep 'Bitbucket refused the merge request' "$case_dir/stderr" \
    "merge-transport: a transport failure was reported as a refusal"
  assert_absent "$case_dir/state/task-x1.pr-poll-merge-notified" "merge-transport: an unconfirmed merge was recorded as landed"
  assert_present "$case_dir/state/task-x1.check.sh" "merge-transport: the merge poll was not left armed"
  pass "fm-pr-merge reads a Bitbucket pull request back after its merge request got no response"
}

test_url_parse_accepts_canonical_bitbucket_urls
test_url_parse_refuses_malformed_bitbucket_urls
test_record_read_reports_state_and_merged
test_statuses_read_follows_pagination_only_under_the_api_base
test_check_records_full_head_and_arms_the_poll
test_check_refuses_a_draft
test_check_refuses_without_the_credential
test_poll_wakes_only_on_an_exact_merged_record
test_pr_state_reports_bitbucket_blockers
test_merge_succeeds_with_read_back_and_keeps_the_branch
test_merge_passes_a_requested_strategy
test_merge_refuses_red_and_unreported_required_builds
test_merge_refuses_draft_closed_and_missing_credentials
test_merge_waivers_follow_the_attended_rules
test_merge_under_away_authority_is_synchronous_and_gated
test_merge_refuses_a_head_that_moved_before_the_request
test_merge_reports_forge_refusal_unconfirmed_and_wrong_head
test_merge_refuses_unmet_review_merge_checks
test_merge_reads_back_after_a_transport_failure
