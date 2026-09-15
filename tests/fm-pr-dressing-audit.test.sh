#!/usr/bin/env bash
# Tests for fm-pr-dressing-audit.sh through its executable interface.
#
# The partial-failure fixture records a pull request observed on 2026-09-13,
# when its assignees applied but its reviewer list was empty.
# That condition was corrected before this audit existed, so a fixture is the
# only honest deterministic proof that its detection remains covered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-pr-dressing-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-dressing-audit)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/config" "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

write_config() {
  local case_dir=$1 repo=${2:-owner/repository}
  cat > "$case_dir/home/config/pr-dressing-audit.json" <<JSON
{
  "repositories": {
    "$repo": {
      "integration_branch": "develop",
      "reviewer_team": "owner/team-slug",
      "assignees": ["login-one", "login-two"],
      "required_checks": ["CI gate"]
    }
  }
}
JSON
}

# One page of the slurped `gh api graphql --paginate --slurp` response.
page() {
  printf '{"data":{"repository":{"pullRequests":{"nodes":%s}}}}' "$1"
}

write_gh() {
  local case_dir=$1 payload=$2
  printf '%s\n' "$payload" > "$case_dir/pull-requests.json"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api graphql")
    typed=
    for arg in "$@"; do
      if [ "$typed" = 1 ]; then
        case "${arg#*=}" in
          ''|*[!0-9]*) ;;
          *) exit 1 ;;
        esac
      fi
      typed=
      [ "$arg" = -F ] && typed=1
    done
    cat "$FM_TEST_PR_DRESSING_PAYLOAD"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_audit() {
  local case_dir=$1 out=$2 repo=${3:-owner/repository} status=0
  env FM_HOME="$case_dir/home" FM_TEST_PR_DRESSING_PAYLOAD="$case_dir/pull-requests.json" \
    PATH="$case_dir/fakebin:$PATH" "$AUDIT" "$repo" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "audit exit"
}

test_partial_failure_fixture_and_live_case_shape_are_reported() {
  local case_dir out report
  case_dir=$(make_case acceptance-cases)
  write_config "$case_dir"
  write_gh "$case_dir" "[$(page '[
    {"number":480,"url":"https://github.com/owner/repository/pull/480","baseRefName":"main","headRefName":"feature-480","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}},
    {"number":485,"url":"https://github.com/owner/repository/pull/485","baseRefName":"main","headRefName":"feature-485","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[]},"reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}}
  ]'),$(page '[
    {"number":486,"url":"https://github.com/owner/repository/pull/486","baseRefName":"main","headRefName":"develop","isCrossRepository":true,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}
  ]')]"
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'https://github.com/owner/repository/pull/480: reviewer team missing: owner/team-slug' 'missing team reviewer was not reported with its qualified slug'
  assert_contains "$report" 'https://github.com/owner/repository/pull/485: base branch is main; expected develop' 'live-case production branch was not reported'
  assert_contains "$report" 'https://github.com/owner/repository/pull/485: assignees missing: login-one, login-two' 'live-case assignees were not reported'
  assert_contains "$report" 'https://github.com/owner/repository/pull/485: required check failing: CI gate' 'live-case failing check was not reported'
  assert_contains "$report" 'https://github.com/owner/repository/pull/486: base branch is main; expected develop' 'fork branch named like the integration branch on a later page was not reported'
  pass 'the partial-failure fixture and live-case violation shape are reported across pages'
}

test_compliant_pull_request_is_silent() {
  local case_dir out
  case_dir=$(make_case compliant)
  write_config "$case_dir"
  write_gh "$case_dir" "[$(page '[{"number":484,"url":"https://github.com/owner/repository/pull/484","baseRefName":"develop","headRefName":"feature-484","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}}]')]"
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  [ ! -s "$out" ] || fail "compliant pull request was not silent: $(cat "$out")"
  pass 'a compliant pull request is silent'
}

test_missing_assignee_mergeability_and_failed_required_check_are_reported() {
  local case_dir out report
  case_dir=$(make_case remaining-rules)
  write_config "$case_dir"
  write_gh "$case_dir" "[$(page '[{"number":485,"url":"https://github.com/owner/repository/pull/485","baseRefName":"develop","headRefName":"feature-485","isCrossRepository":false,"mergeable":"CONFLICTING","assignees":{"nodes":[{"login":"login-one"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}}]')]"
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'assignees missing: login-two' 'missing assignee was not reported'
  assert_contains "$report" 'mergeable is CONFLICTING, not MERGEABLE' 'unmergeable pull request was not reported'
  assert_contains "$report" 'required check failing: CI gate' 'failed configured required check was not reported'
  pass 'remaining configured violations are reported'
}

test_indeterminate_and_satisfied_states_are_silent() {
  local case_dir out
  case_dir=$(make_case satisfied-states)
  write_config "$case_dir"
  write_gh "$case_dir" "[$(page '[
    {"number":490,"url":"https://github.com/owner/repository/pull/490","baseRefName":"develop","headRefName":"feature-490","isCrossRepository":false,"mergeable":"UNKNOWN","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}},
    {"number":491,"url":"https://github.com/owner/repository/pull/491","baseRefName":"develop","headRefName":"feature-491","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[]},"reviews":{"nodes":[{"onBehalfOf":{"nodes":[{"combinedSlug":"owner/team-slug"}]}}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-13T10:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-13T10:05:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]}}}}]}},
    {"number":492,"url":"https://github.com/owner/repository/pull/492","baseRefName":"main","headRefName":"develop","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"CI gate","state":"PENDING"}]}}}}]}}
  ]')]"
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  [ ! -s "$out" ] || fail "pending, superseded, reviewed-for-team, or release pull requests were not silent: $(cat "$out")"
  pass 'pending checks, superseded failures, unknown mergeability, team reviews, and release pull requests are silent'
}

test_numeric_repository_name_is_audited() {
  local case_dir out
  case_dir=$(make_case numeric-repository)
  write_config "$case_dir" owner/2048
  write_gh "$case_dir" "[$(page '[{"number":7,"url":"https://github.com/owner/2048/pull/7","baseRefName":"develop","headRefName":"feature-7","isCrossRepository":false,"mergeable":"MERGEABLE","assignees":{"nodes":[{"login":"login-one"},{"login":"login-two"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"owner/team-slug"}}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}]')]"
  out="$case_dir/out"
  run_audit "$case_dir" "$out" owner/2048
  [ ! -s "$out" ] || fail "numeric repository name was not audited: $(cat "$out")"
  pass 'a repository with a numeric name is audited'
}

test_unreadable_pull_requests_fail_closed() {
  local case_dir out status=0
  case_dir=$(make_case unreadable-pull-requests)
  write_config "$case_dir"
  write_gh "$case_dir" 'not json'
  out="$case_dir/out"
  env FM_HOME="$case_dir/home" FM_TEST_PR_DRESSING_PAYLOAD="$case_dir/pull-requests.json" \
    PATH="$case_dir/fakebin:$PATH" "$AUDIT" owner/repository >"$out" 2>&1 || status=$?
  expect_code 2 "$status" "unreadable pull requests exit"
  assert_contains "$(cat "$out")" 'could not read open pull requests for owner/repository' 'unreadable pull requests were not reported'
  pass 'unreadable pull request data stops the audit instead of reporting nothing'
}

test_help_states_the_unchecked_scope() {
  local out status=0
  out="$TMP_ROOT/help"
  "$AUDIT" --help >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  assert_contains "$(cat "$out")" 'It does not infer branch protection, review approvals, merge authority, or' 'help did not state the audit boundary'
  pass 'help states what the audit does not check'
}

test_partial_failure_fixture_and_live_case_shape_are_reported
test_compliant_pull_request_is_silent
test_missing_assignee_mergeability_and_failed_required_check_are_reported
test_indeterminate_and_satisfied_states_are_silent
test_numeric_repository_name_is_audited
test_unreadable_pull_requests_fail_closed
test_help_states_the_unchecked_scope
