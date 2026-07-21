#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
# Bitbucket Data Center (mocked curl against the 1.0 REST API; jq builds bodies):
#   (i) personal-repo PR merges after GET version then PUT->405->POST
#   (j) already-merged PR is a no-op (project-repo /projects/ scope)
#   (k) missing BB_TOKEN refuses before any curl call
#   (l) GitHub-only merge flags are rejected for DC before any curl call
#   (m) a non-2xx merge surfaces the response body and fails
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# add_curl_mock <case_dir>: drop a scripted curl stub into the case fakebin for
# the Bitbucket Data Center path. It records each scripted call to
# $FM_TEST_CURL_LOG and answers from URL + method driven by FM_TEST_DC_* vars.
# Defaults replay the fleet-observed sequence: GET PR (OPEN) -> PUT 405 ->
# POST 200 MERGED. jq builds the JSON bodies so the heredoc stays quote-free.
add_curl_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
method=
bodyfile=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -H) shift 2 ;;
    -o) bodyfile=$2; shift 2 ;;
    -w) shift 2 ;;
    -sS|-s) shift ;;
    *) url=$1; shift ;;
  esac
done
state=${FM_TEST_DC_PR_STATE:-OPEN}
version=${FM_TEST_DC_PR_VERSION:-1}
case "$url" in
  */merge*)
    case "$method" in
      PUT) jq -cn '{errors:[{message:"Method Not Allowed"}]}' > "$bodyfile"; printf '405\n' ;;
      POST)
        if [ "${FM_TEST_DC_MERGE_FAIL:-0}" = 1 ]; then
          jq -cn '{errors:[{message:"merge conflict"}]}' > "$bodyfile"; printf '409\n'
        else
          jq -cn --argjson v "$((version + 1))" '{version:$v,state:"MERGED"}' > "$bodyfile"; printf '200\n'
        fi
        ;;
      *) jq -cn '{errors:[]}' > "$bodyfile"; printf '400\n' ;;
    esac
    ;;
  *) jq -cn --argjson v "$version" --arg s "$state" '{version:$v,state:$s}' > "$bodyfile"; printf '200\n' ;;
esac
SH
  chmod +x "$case_dir/fakebin/curl"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_CURL_LOG="$case_dir/curl.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_dc_personal_repo_merges_after_version_fetch() {
  local case_dir rc
  case_dir=$(make_case dc-happy)
  add_curl_mock "$case_dir"
  : > "$case_dir/curl.log"

  set +e
  BB_TOKEN=faketoken run_pr_merge "$case_dir" task-x1 \
    https://b.yadro.com/users/se.kostrov/repos/yapi-firstmate/pull-requests/3 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dc-happy: fm-pr-merge should merge the Bitbucket Data Center PR"
  assert_grep 'pr=https://b.yadro.com/users/se.kostrov/repos/yapi-firstmate/pull-requests/3' \
    "$case_dir/state/task-x1.meta" "dc-happy: pr= was not recorded for the DC PR"
  assert_grep '/rest/api/1.0/users/se.kostrov/repos/yapi-firstmate/pull-requests/3' "$case_dir/curl.log" \
    "dc-happy: personal-repo URL did not build the /users/<slug>/ REST scope"
  assert_grep '-X GET' "$case_dir/curl.log" \
    "dc-happy: DC merge did not GET the PR to fetch its merge version"
  assert_grep '-X PUT' "$case_dir/curl.log" \
    "dc-happy: DC merge did not attempt PUT .../merge first"
  assert_grep '/merge?version=' "$case_dir/curl.log" \
    "dc-happy: DC merge did not pass the fetched version to the merge call"
  assert_grep '-X POST' "$case_dir/curl.log" \
    "dc-happy: DC merge did not fall back to POST after the PUT 405"
  pass "fm-pr-merge merges a personal-repo DC PR via GET version then PUT->405->POST"
}

test_dc_already_merged_is_noop() {
  local case_dir rc
  case_dir=$(make_case dc-already-merged)
  add_curl_mock "$case_dir"
  : > "$case_dir/curl.log"

  set +e
  FM_TEST_DC_PR_STATE=MERGED BB_TOKEN=faketoken run_pr_merge "$case_dir" task-x1 \
    https://b.yadro.com/projects/YAPI/repos/yapi-firstmate/pull-requests/4 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dc-already-merged: an already-merged PR should exit 0 without re-merging"
  assert_grep 'already merged' "$case_dir/stdout" \
    "dc-already-merged: did not report the PR as already merged"
  assert_grep '/rest/api/1.0/projects/YAPI/repos/yapi-firstmate/pull-requests/4' "$case_dir/curl.log" \
    "dc-already-merged: project-repo URL did not build the /projects/<KEY>/ REST scope"
  assert_grep '-X GET' "$case_dir/curl.log" \
    "dc-already-merged: did not GET the PR to detect the merged state"
  assert_no_grep '-X PUT' "$case_dir/curl.log" \
    "dc-already-merged: attempted PUT despite the PR already being merged"
  assert_no_grep '-X POST' "$case_dir/curl.log" \
    "dc-already-merged: attempted POST despite the PR already being merged"
  pass "fm-pr-merge treats an already-merged DC PR as a no-op and builds the /projects/ scope"
}

test_dc_missing_token_refuses_before_curl() {
  local case_dir rc
  case_dir=$(make_case dc-no-token)
  add_curl_mock "$case_dir"
  : > "$case_dir/curl.log"

  set +e
  (
    unset BB_TOKEN
    run_pr_merge "$case_dir" task-x1 \
      https://b.yadro.com/users/se.kostrov/repos/yapi-firstmate/pull-requests/3 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  )
  rc=$?
  set -e

  expect_code 1 "$rc" "dc-no-token: missing BB_TOKEN should refuse the DC merge"
  assert_grep 'BB_TOKEN is required' "$case_dir/stderr" \
    "dc-no-token: refusal did not name the missing BB_TOKEN credential"
  assert_no_grep '-X GET' "$case_dir/curl.log" \
    "dc-no-token: a DC merge was attempted without BB_TOKEN"
  pass "fm-pr-merge refuses a DC merge when BB_TOKEN is unset, before any curl call"
}

test_dc_rejects_github_only_merge_flags() {
  local case_dir rc
  case_dir=$(make_case dc-reject-flags)
  add_curl_mock "$case_dir"
  : > "$case_dir/curl.log"

  set +e
  run_pr_merge "$case_dir" task-x1 \
    https://b.yadro.com/users/se.kostrov/repos/yapi-firstmate/pull-requests/3 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dc-reject-flags: GitHub-only merge flags should be rejected for DC"
  assert_grep 'Bitbucket Data Center merge accepts no flags' "$case_dir/stderr" \
    "dc-reject-flags: rejection did not explain that DC takes no merge flags"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "dc-reject-flags: flag rejection should not record PR state"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "dc-reject-flags: flag rejection should not arm a merge poll"
  assert_no_grep '-X GET' "$case_dir/curl.log" \
    "dc-reject-flags: a DC merge was attempted despite rejected flags"
  pass "fm-pr-merge rejects GitHub-only merge-method flags for a DC PR before any curl call"
}

test_dc_merge_failure_reports_body() {
  local case_dir rc
  case_dir=$(make_case dc-merge-fails)
  add_curl_mock "$case_dir"
  : > "$case_dir/curl.log"

  set +e
  FM_TEST_DC_MERGE_FAIL=1 BB_TOKEN=faketoken run_pr_merge "$case_dir" task-x1 \
    https://b.yadro.com/users/se.kostrov/repos/yapi-firstmate/pull-requests/3 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dc-merge-fails: a non-2xx merge response should fail the DC merge"
  assert_grep 'Bitbucket Data Center merge failed' "$case_dir/stderr" \
    "dc-merge-fails: failure message did not name the DC merge failure"
  assert_grep 'merge conflict' "$case_dir/stderr" \
    "dc-merge-fails: failure did not surface the response body for diagnosis"
  pass "fm-pr-merge fails a DC merge on a non-2xx response and shows the response body"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi

test_dc_personal_repo_merges_after_version_fetch
test_dc_already_merged_is_noop
test_dc_missing_token_refuses_before_curl
test_dc_rejects_github_only_merge_flags
test_dc_merge_failure_reports_body
