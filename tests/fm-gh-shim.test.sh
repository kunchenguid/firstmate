#!/usr/bin/env bash
# Behavioral regressions for the gh shim's pull-request credential route, its
# exact-head workflow-runs CI fallback, and fm-gh.sh's credential-prefix contract.
#
# The routed invocation under test is the exact argument vector the no-mistakes PR
# step builds for GitHub. Nothing here touches the real gh, the real daemon, or any
# network: a fake gh records how it was called, and a fake credential runner stands in
# for whatever the home configures. CI cases feed raw workflow-run pages through the
# same jq expression the helper gives gh, so they exercise the public command contract
# rather than asserting implementation bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-gh-shim.sh"
WRAPPER="$ROOT/bin/fm-gh.sh"
CI_FALLBACK="$ROOT/bin/fm-gh-ci-fallback.sh"
INSTALLER="$ROOT/bin/fm-gh-shim-install.sh"
assert_present "$CI_FALLBACK" "bin/fm-gh-ci-fallback.sh is missing"
[ -x "$CI_FALLBACK" ] || fail "bin/fm-gh-ci-fallback.sh must be executable"
TMP_ROOT=$(fm_test_tmproot fm-gh-shim)
# Create before normalizing, then normalize: $TMPDIR often carries a trailing slash and
# these cases compare fixture paths against the installer's own `cd`-normalized output,
# so the path must be resolved rather than compared raw. The mkdir is not redundant,
# because a cleanup trap registered inside the command substitution above can remove the
# directory before it is ever used, which would make the normalizing `cd` fail.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_fake_gh <dir>: a stand-in real gh that appends its argv and the credential the
# environment handed it to <dir>/gh.calls.
make_fake_gh() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" << 'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'token:%s\n' "${GITHUB_TOKEN:-<none>}" >> "$FAKE_GH_LOG"
printf 'gh-token:%s\n' "${GH_TOKEN:-<none>}" >> "$FAKE_GH_LOG"
printf 'effective-token:%s\n' "${GH_TOKEN:-${GITHUB_TOKEN:-<none>}}" >> "$FAKE_GH_LOG"
echo "https://github.com/o/r/pull/1"
EOF
  chmod +x "$dir/gh"
}

# make_home <home> <prefix-line>: a home whose config/gh-credential holds <prefix-line>.
make_home() {
  local home=$1 line=$2
  mkdir -p "$home/config"
  printf '%s\n' "$line" > "$home/config/gh-credential"
}

# make_git_checkout <dir> [origin]: make an empty checkout, optionally with origin.
make_git_checkout() {
  local dir=$1 origin=${2:-}
  git init -q "$dir"
  [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
}

# make_fake_cred <dir>: a credential runner that injects a known token then execs the
# rest of its arguments, which is the shape config/gh-credential must satisfy.
make_fake_cred() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/fakecred" << 'EOF'
#!/usr/bin/env bash
# usage: fakecred <TOKEN_VALUE> -- <command> [args...]
token=$1
shift
[ "${1:-}" = "--" ] && shift
GITHUB_TOKEN="$token" exec "$@"
EOF
  chmod +x "$dir/fakecred"
}

# make_fake_ci_gh <dir>: a gh double whose `pr checks` read is forbidden while the
# pull-request and workflow-runs APIs remain readable with the same ambient token.
# FM_TEST_WORKFLOW_PAGES and FM_TEST_STALE_PAGES are outer arrays holding the
# response pages in order; the double streams them one page at a time, because
# real `gh api --paginate` applies a --jq expression to each page on its own.
# It reproduces GitHub CLI 2.92.0's refusal of `--slurp` alongside `--jq`, and
# sorts result keys the way gh's own encoder does.
make_fake_ci_gh() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" << 'EOF'
#!/usr/bin/env bash
# pipefail keeps an unreadable page fixture a failed api call, the way a real
# failed workflow-runs read is, instead of a silent empty page sequence.
set -o pipefail
printf 'argv:%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'token:%s\n' "${GITHUB_TOKEN:-<none>}" >> "$FAKE_GH_LOG"

if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
  case "${FM_TEST_CHECKS_ERROR:-403}" in
    403)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup)" >&2
      ;;
    403-rate-limit)
      echo "HTTP 403: API rate limit exceeded (check-runs)" >&2
      ;;
    403-deep-path)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)" >&2
      ;;
    403-other-api)
      echo "GraphQL: Resource not accessible by personal access token (organization.t000)" >&2
      ;;
    403-lookalike)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollupSummary.nodes.0)" >&2
      ;;
    *)
      echo "HTTP ${FM_TEST_CHECKS_ERROR}: simulated non-authorization failure" >&2
      ;;
  esac
  exit 1
fi

if [ "${1:-}" = api ]; then
  endpoint=
  query=
  slurp=0
  jq_given=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      repos/*) endpoint=$1; shift ;;
      --jq) query=$2; jq_given=1; shift 2 ;;
      --template) jq_given=1; shift 2 ;;
      --slurp) slurp=1; shift ;;
      *) shift ;;
    esac
  done
  if [ "$slurp" = 1 ] && [ "$jq_given" = 1 ]; then
    echo 'the `--slurp` option is not supported with `--jq` or `--template`' >&2
    exit 1
  fi
  case "$endpoint" in
    "repos/o/r/pulls/7")
      pull_calls=$(grep -c 'argv:api -X GET repos/o/r/pulls/7' "$FAKE_GH_LOG")
      if [ "$pull_calls" -gt 1 ]; then
        printf '%s\n' "${FM_TEST_PR_HEAD_AFTER:-$FM_TEST_PR_HEAD}"
      else
        printf '%s\n' "$FM_TEST_PR_HEAD"
      fi
      exit 0
      ;;
    "repos/o/r/actions/runs?head_sha=$FM_TEST_PR_HEAD&per_page=100")
      "$FM_TEST_JQ" -c '.[]' "$FM_TEST_WORKFLOW_PAGES" | "$FM_TEST_JQ" -S -c "$query"
      exit $?
      ;;
    repos/o/r/actions/runs*)
      "$FM_TEST_JQ" -c '.[]' "$FM_TEST_STALE_PAGES" | "$FM_TEST_JQ" -S -c "$query"
      exit $?
      ;;
  esac
fi

echo "unexpected fake gh invocation: $*" >&2
exit 2
EOF
  chmod +x "$dir/gh"
}

# assert_run_field <jq> <output> <run-name> <field> <expected> <message>: read the
# emitted check array as JSON and assert one named run's field, so the assertions
# depend on the documented check shape rather than on key order or spacing.
assert_run_field() {
  local jq_bin=$1 out=$2 name=$3 field=$4 expected=$5 message=$6 json actual
  json=$(printf '%s\n' "$out" | grep -E '^\[' | tail -1)
  [ -n "$json" ] || fail "$message (no JSON check array in the output)"
  # shellcheck disable=SC2016 # A literal jq program; its $ names belong to jq.
  actual=$(printf '%s' "$json" | "$jq_bin" -r --arg n "$name" --arg f "$field" \
    'map(select(.name == $n)) | if length == 0 then "<absent>" else (.[0][$f] // "<null>") end') ||
    fail "$message (the emitted check output is not valid JSON)"
  [ "$actual" = "$expected" ] ||
    fail "$message (expected $name.$field=$expected, got $actual)"
}

write_ci_pages() {
  local path=$1 name=$2 status=$3 conclusion=$4
  cat > "$path" << EOF
[
  {
    "workflow_runs": [
      {
        "name": "$name",
        "status": "$status",
        "conclusion": $conclusion,
        "updated_at": "2026-08-07T12:34:56Z",
        "html_url": "https://github.com/o/r/actions/runs/123"
      }
    ]
  }
]
EOF
}

write_empty_ci_pages() {
  local path=$1
  printf '[{"workflow_runs":[]}]\n' > "$path"
}

write_multi_bucket_ci_pages() {
  local path=$1
  cat > "$path" << 'EOF'
[
  {
    "workflow_runs": [
      {
        "name": "cancelled-workflow",
        "status": "completed",
        "conclusion": "cancelled",
        "updated_at": "2026-08-07T12:34:56Z",
        "html_url": "https://github.com/o/r/actions/runs/201"
      }
    ]
  },
  {
    "workflow_runs": [
      {
        "name": "skipped-workflow",
        "status": "completed",
        "conclusion": "skipped",
        "updated_at": "2026-08-07T12:35:56Z",
        "html_url": "https://github.com/o/r/actions/runs/202"
      },
      {
        "name": "queued-workflow",
        "status": "queued",
        "conclusion": null,
        "updated_at": "2026-08-07T12:36:56Z",
        "html_url": "https://github.com/o/r/actions/runs/203"
      }
    ]
  }
]
EOF
}

test_ci_403_falls_back_to_exact_head_green_without_privileged_token() {
  local case_dir real_dir shim_dir home head out status jq_bin
  case_dir="$TMP_ROOT/ci-green"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  write_ci_pages "$case_dir/exact.json" exact-head completed '"success"'
  write_ci_pages "$case_dir/stale.json" stale-head completed '"failure"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 0 "$status" "exact-head workflow fallback green verdict"
  assert_run_field "$jq_bin" "$out" exact-head bucket pass \
    "successful exact-head workflow run did not become a green check"
  assert_grep "argv:api -X GET repos/o/r/actions/runs?head_sha=$head&per_page=100 --paginate --jq" \
    "$case_dir/gh.calls" \
    "fallback did not filter workflow runs by the exact PR head SHA"
  assert_no_grep 'token:pr-capable-token' "$case_dir/gh.calls" \
    "CI fallback exposed config/gh-credential's broader token"
  assert_grep 'token:narrow-ci-token' "$case_dir/gh.calls" \
    "CI fallback did not preserve the ambient narrow token"
  pass "a check-runs 403 reaches a green exact-head workflow verdict without the privileged token"
}

test_ci_deeper_denial_path_falls_back_to_exact_head_green() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-deep-path"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=9999999999999999999999999999999999999999
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" exact-head completed '"success"'
  write_ci_pages "$case_dir/stale.json" stale-head completed '"failure"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_CHECKS_ERROR=403-deep-path \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 0 "$status" "deeper denial path exact-head workflow fallback"
  assert_run_field "$jq_bin" "$out" exact-head bucket pass \
    "a deeper denial path did not reach the green exact-head workflow verdict"
  assert_grep "argv:api -X GET repos/o/r/actions/runs?head_sha=$head&per_page=100 --paginate --jq" \
    "$case_dir/gh.calls" \
    "a deeper denial path did not filter workflow runs by the exact PR head SHA"
  pass "a denial naming statusCheckRollup deeper in its path still reaches the exact-head verdict"
}

test_ci_403_falls_back_to_exact_head_red() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-red"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" failing-workflow completed '"failure"'
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt,link 2>&1) || status=$?

  expect_code 0 "$status" "exact-head workflow fallback red verdict transport"
  assert_run_field "$jq_bin" "$out" failing-workflow state failure \
    "failed exact-head workflow run lost its provider conclusion"
  assert_run_field "$jq_bin" "$out" failing-workflow bucket fail \
    "failed exact-head workflow run did not become a red check"
  assert_run_field "$jq_bin" "$out" failing-workflow link \
    "https://github.com/o/r/actions/runs/123" \
    "failed workflow result did not retain its Actions run link"
  pass "a check-runs 403 reaches a red exact-head workflow verdict"
}

test_ci_zero_exact_head_runs_stays_pending() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-empty"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=dddddddddddddddddddddddddddddddddddddddd
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_empty_ci_pages "$case_dir/exact.json"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 0 "$status" "empty exact-head workflow fallback transport"
  assert_run_field "$jq_bin" "$out" "GitHub Actions workflows" bucket pending \
    "empty exact-head workflow evidence did not emit a pending placeholder check"
  assert_not_contains "$out" '"bucket":"pass"' \
    "empty exact-head workflow evidence incorrectly certified green"
  pass "zero exact-head workflow runs remain explicitly pending"
}

test_ci_maps_cancel_skipping_and_pending_across_pages() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-multi-bucket"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=1212121212121212121212121212121212121212
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_multi_bucket_ci_pages "$case_dir/exact.json"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt,link 2>&1) || status=$?

  expect_code 0 "$status" "multi-page exact-head workflow fallback transport"
  assert_run_field "$jq_bin" "$out" cancelled-workflow bucket cancel \
    "completed cancellation did not map to the cancellation bucket"
  assert_run_field "$jq_bin" "$out" cancelled-workflow state cancelled \
    "completed cancellation lost its provider conclusion"
  assert_run_field "$jq_bin" "$out" skipped-workflow bucket skipping \
    "completed skip did not map to the skipping bucket"
  assert_run_field "$jq_bin" "$out" queued-workflow bucket pending \
    "queued workflow did not remain pending"
  assert_run_field "$jq_bin" "$out" queued-workflow state queued \
    "queued workflow lost its provider status"
  pass "paginated exact-head runs map cancellation, skipping, and pending buckets"
}

test_ci_pagination_avoids_the_rejected_slurp_and_jq_combination() {
  local case_dir real_dir head out status jq_bin probe_out probe_status
  case_dir="$TMP_ROOT/ci-slurp-rejecting-gh"
  real_dir="$case_dir/real"
  head=3434343434343434343434343434343434343434
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_multi_bucket_ci_pages "$case_dir/exact.json"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'

  # Prove the double actually refuses the combination first, so a fallback that
  # regressed to `--paginate --slurp --jq` could never pass this case silently.
  probe_status=0
  probe_out=$(FAKE_GH_LOG="$case_dir/probe.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" \
    "$real_dir/gh" api -X GET "repos/o/r/actions/runs?head_sha=$head&per_page=100" \
    --paginate --slurp --jq '.[]' 2>&1) || probe_status=$?
  expect_code 1 "$probe_status" "the gh double accepted --slurp together with --jq"
  # shellcheck disable=SC2016 # GitHub CLI's own message quotes its flags in backticks.
  assert_contains "$probe_out" 'the `--slurp` option is not supported with `--jq` or `--template`' \
    "the gh double did not reproduce GitHub CLI 2.92.0's flag refusal"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token \
    "$CI_FALLBACK" "$real_dir/gh" pr checks 7 --repo o/r \
    --json name,state,bucket,completedAt,link 2>&1) || status=$?

  expect_code 0 "$status" "exact-head workflow fallback against a gh that rejects --slurp with --jq"
  assert_run_field "$jq_bin" "$out" cancelled-workflow bucket cancel \
    "the first page's run was lost against a gh that rejects --slurp with --jq"
  assert_run_field "$jq_bin" "$out" queued-workflow bucket pending \
    "a later page's run was lost against a gh that rejects --slurp with --jq"
  assert_no_grep 'slurp' "$case_dir/gh.calls" \
    "the fallback still asked gh for --slurp alongside --jq"
  assert_grep "argv:api -X GET repos/o/r/actions/runs?head_sha=$head&per_page=100 --paginate --jq" \
    "$case_dir/gh.calls" \
    "the fallback stopped paginating the exact-head workflow-runs read"
  pass "exact-head pagination reaches a verdict on a gh that rejects --slurp with --jq"
}

test_ci_workflow_runs_failure_preserves_the_gh_error() {
  local case_dir real_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-runs-error"
  real_dir="$case_dir/real"
  head=5656565656565656565656565656565656565656
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'

  # No FM_TEST_WORKFLOW_PAGES fixture exists, so the workflow-runs read fails the
  # way any broken gh invocation would, and its own stderr must survive.
  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/missing.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token \
    "$CI_FALLBACK" "$real_dir/gh" pr checks 7 --repo o/r \
    --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 1 "$status" "workflow-runs read failure"
  assert_contains "$out" "exact-head workflow-runs lookup failed" \
    "a failed workflow-runs read did not report the fallback's own refusal"
  assert_contains "$out" "$case_dir/missing.json" \
    "a failed workflow-runs read suppressed the underlying gh error"
  assert_contains "$out" "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup)" \
    "a failed workflow-runs read did not preserve the original gh pr checks failure"
  pass "a failed workflow-runs read keeps the real gh error visible"
}

test_ci_pr_head_drift_refuses_stale_verdict() {
  local case_dir real_dir shim_dir head changed_head out status jq_bin
  case_dir="$TMP_ROOT/ci-head-drift"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  changed_head=ffffffffffffffffffffffffffffffffffffffff
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" superseded-head completed '"success"'
  write_ci_pages "$case_dir/stale.json" unrelated-head completed '"failure"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_PR_HEAD_AFTER="$changed_head" FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" \
    FM_TEST_STALE_PAGES="$case_dir/stale.json" FM_TEST_JQ="$jq_bin" \
    GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 1 "$status" "workflow fallback while the PR head advances"
  assert_contains "$out" "PR head changed during workflow-runs lookup" \
    "head drift did not refuse the workflow fallback result"
  assert_contains "$out" "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup)" \
    "head drift did not preserve the original gh pr checks failure"
  assert_not_contains "$out" '"bucket":"pass"' \
    "a superseded head's green workflow verdict escaped the fallback"
  pass "a moving PR head cannot emit a stale workflow verdict"
}

test_ci_unrelated_failures_preserve_original_result() {
  local case_dir real_dir shim_dir head out status jq_bin error expected
  case_dir="$TMP_ROOT/ci-unrelated-failures"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=cccccccccccccccccccccccccccccccccccccccc
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" exact-head completed '"success"'
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  for error in 500 403-rate-limit 403-other-api 403-lookalike; do
    case "$error" in
      500) expected="HTTP 500" ;;
      403-rate-limit) expected="HTTP 403: API rate limit exceeded" ;;
      403-other-api) expected="GraphQL: Resource not accessible by personal access token (organization.t000)" ;;
      403-lookalike) expected="GraphQL: Resource not accessible by personal access token (node.statusCheckRollupSummary.nodes.0)" ;;
    esac
    status=0
    out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
      FM_TEST_CHECKS_ERROR="$error" FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" \
      FM_TEST_STALE_PAGES="$case_dir/stale.json" FM_TEST_JQ="$jq_bin" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

    expect_code 1 "$status" "unrelated gh pr checks failure: $error"
    assert_contains "$out" "$expected" \
      "unrelated failure was not replayed unchanged: $error"
  done
  assert_no_grep 'argv:api' "$case_dir/gh.calls" \
    "an unrelated failure incorrectly reached the workflow-runs fallback"
  pass "unrelated check failures are preserved without an API fallback"
}

test_ci_unsupported_shapes_exec_real_gh_directly() {
  local case_dir real_dir shim_dir out status invocation
  case_dir="$TMP_ROOT/ci-unsupported-shapes"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_ci_gh "$real_dir"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"
  cat > "$case_dir/fallback" << 'EOF'
#!/usr/bin/env bash
printf 'invoked\n' > "$FM_TEST_FALLBACK_LOG"
exit 99
EOF
  chmod +x "$case_dir/fallback"

  for invocation in \
    "pr checks 7 --repo o/r --json name,state,bucket,completedAt --watch" \
    "pr checks 7 -R o/r --json name,state,bucket,completedAt" \
    "pr checks 7 --repo=o/r --json=name,state,bucket,completedAt" \
    "pr checks 7 --json name,state,bucket,completedAt --repo o/r" \
    "pr checks 7 --repo o/r --repo o/r --json name,state,bucket,completedAt" \
    "pr checks https://github.com/o/r/pull/7 --json name,state,bucket,completedAt"; do
    status=0
    # shellcheck disable=SC2086 # Deliberate word splitting of the fixture argv.
    out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_FALLBACK_LOG="$case_dir/fallback.calls" \
      FM_GH_SHIM_CI_FALLBACK="$case_dir/fallback" PATH="$shim_dir:$real_dir:$PATH" \
      gh $invocation 2>&1) || status=$?

    expect_code 1 "$status" "unsupported gh pr checks shape: $invocation"
    assert_contains "$out" "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup)" \
      "unsupported gh pr checks shape did not retain real gh behavior: $invocation"
  done
  assert_no_grep 'argv:api' "$case_dir/gh.calls" \
    "an unsupported gh pr checks invocation incorrectly reached the CI fallback"
  assert_absent "$case_dir/fallback.calls" \
    "an unsupported gh pr checks invocation entered the capturing fallback helper"
  pass "unsupported gh pr checks shapes exec the real gh directly"
}

test_pr_create_without_repo_injects_origin_target() {
  local case_dir real_dir shim_dir home checkout out
  case_dir="$TMP_ROOT/route"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  checkout="$case_dir/checkout"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  make_git_checkout "$checkout" "git@github.com:fork-owner/fork-repo.git"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  local out
  out=$(
    cd "$checkout" || exit 1
    FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" gh pr create --head feature --base main --title T \
      < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "routed pr create did not return the real gh's output"
  assert_grep 'argv:pr create --repo fork-owner/fork-repo --head feature --base main --title T' \
    "$case_dir/gh.calls" \
    "routed pr create did not receive the fork origin as an explicit --repo target"
  assert_grep 'token:pr-capable-token' "$case_dir/gh.calls" \
    "routed pr create did not receive the credential injected by config/gh-credential"
  pass "gh pr create without --repo injects its checkout origin into the credential route"
}

test_pr_option_values_cannot_mask_origin_target() {
  local case_dir real_dir shim_dir home checkout
  case_dir="$TMP_ROOT/repo-like-option-value"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  checkout="$case_dir/checkout"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  make_git_checkout "$checkout" "https://github.com/fork-owner/fork-repo.git"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  (
    cd "$checkout" || exit 1
    FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" gh pr create --body-file -Rnotes.md --title T \
      < /dev/null > /dev/null 2>&1
  )

  assert_grep 'argv:pr create --repo fork-owner/fork-repo --body-file -Rnotes.md --title T' \
    "$case_dir/gh.calls" \
    "a repository-like body-file value suppressed the explicit origin target"

  (
    cd "$checkout" || exit 1
    FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" gh pr edit 7 --add-assignee=Ruser \
      < /dev/null > /dev/null 2>&1
  )

  assert_grep 'argv:pr edit --repo fork-owner/fork-repo 7 --add-assignee=Ruser' \
    "$case_dir/gh.calls" \
    "an attached long-option value suppressed the explicit origin target"
  pass "repository-like option values cannot suppress origin targeting"
}

test_pr_create_with_repo_preserves_caller_target() {
  local case_dir real_dir shim_dir home checkout out
  case_dir="$TMP_ROOT/caller-repo"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  checkout="$case_dir/checkout"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  make_git_checkout "$checkout"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  out=$(cd "$checkout" && FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" PATH="$shim_dir:$real_dir:$PATH" \
    gh pr create --head feature --base main --repo caller-owner/caller-repo --title T < /dev/null 2>&1)

  out=$(cd "$checkout" && FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" PATH="$shim_dir:$real_dir:$PATH" \
    gh pr create -dRcaller-owner/caller-repo --head feature --title T < /dev/null 2>&1)

  assert_grep 'argv:pr create --head feature --base main --repo caller-owner/caller-repo --title T' \
    "$case_dir/gh.calls" \
    "a caller-supplied --repo did not reach real gh unchanged"
  assert_grep 'argv:pr create -dRcaller-owner/caller-repo --head feature --title T' \
    "$case_dir/gh.calls" \
    "a clustered caller-supplied -R did not reach real gh unchanged"
  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "a clustered caller-supplied -R did not complete the credential route"
  pass "caller-supplied --repo and -R always win over the checkout origin"
}

test_pr_edit_without_origin_refuses_before_credential_route() {
  local case_dir real_dir shim_dir home checkout out status
  case_dir="$TMP_ROOT/no-origin"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  checkout="$case_dir/checkout"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  make_git_checkout "$checkout"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(cd "$checkout" && FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" PATH="$shim_dir:$real_dir:$PATH" \
    gh pr edit 7 --title T < /dev/null 2>&1) || status=$?

  expect_code 1 "$status" "credential-routed pr edit with no origin"
  assert_contains "$out" "refusing credential-routed gh pr edit without --repo" \
    "a no-origin credential route did not fail loudly"
  assert_absent "$case_dir/gh.calls" \
    "a no-origin credential route delegated to real gh and let it guess the repository"
  pass "credential-routed pr edit without --repo refuses when origin is unavailable"
}

test_non_pr_invocations_pass_through_untouched() {
  local case_dir real_dir shim_dir home
  case_dir="$TMP_ROOT/passthrough"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  # `pr list` and `pr view` are the pipeline's read calls; the ambient credential is
  # sufficient for them, so the shim must not spend the privileged credential there.
  local invocation
  for invocation in "pr list --head feature" "pr view 1" "api user"; do
    # shellcheck disable=SC2086 # Deliberate word splitting of the fixture argv.
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh $invocation < /dev/null > /dev/null 2>&1
  done

  assert_grep 'argv:pr list --head feature' "$case_dir/gh.calls" \
    "pr list did not reach the real gh"
  assert_grep 'argv:pr view 1' "$case_dir/gh.calls" \
    "pr view did not reach the real gh"
  assert_no_grep 'token:pr-capable-token' "$case_dir/gh.calls" \
    "a non-mutating invocation was routed through the privileged credential"
  pass "pr list, pr view, and api pass through the shim without the privileged credential"
}

test_wrapper_without_config_is_transparent() {
  local case_dir real_dir home out
  case_dir="$TMP_ROOT/transparent"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  mkdir -p "$home/config"

  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      GH_TOKEN="ambient-gh-token" GITHUB_TOKEN="ambient-github-token" \
      "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "unconfigured wrapper did not exec the command"
  assert_grep 'argv:pr create --title T' "$case_dir/gh.calls" \
    "unconfigured wrapper altered the argument vector"
  assert_grep 'gh-token:ambient-gh-token' "$case_dir/gh.calls" \
    "unconfigured wrapper cleared the ambient GH_TOKEN"
  assert_grep 'token:ambient-github-token' "$case_dir/gh.calls" \
    "unconfigured wrapper cleared the ambient GITHUB_TOKEN"
  pass "fm-gh.sh with no config/gh-credential execs the command unchanged"
}

test_configured_wrapper_replaces_ambient_tokens() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/token-precedence"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred prefix-token --"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_TOKEN="hostile-gh-token" GITHUB_TOKEN="hostile-github-token" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'gh-token:<none>' "$case_dir/gh.calls" \
    "configured wrapper left the higher-precedence ambient GH_TOKEN in place"
  assert_grep 'token:prefix-token' "$case_dir/gh.calls" \
    "configured wrapper did not replace the ambient GITHUB_TOKEN"
  assert_grep 'effective-token:prefix-token' "$case_dir/gh.calls" \
    "prefix-injected credential did not win gh token precedence"
  pass "configured fm-gh.sh exposes only the prefix-injected GitHub token"
}

test_wrapper_ignores_comments_and_blank_lines() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/comments"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"
  {
    printf '# a comment line\n'
    printf '\n'
    printf '   \n'
    printf '  %s second-line-token --  \n' "$case_dir/tools/fakecred"
    printf '%s ignored-token --\n' "$case_dir/tools/fakecred"
  } > "$home/config/gh-credential"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'token:second-line-token' "$case_dir/gh.calls" \
    "wrapper did not use the first non-comment, whitespace-trimmed prefix line"
  assert_no_grep 'token:ignored-token' "$case_dir/gh.calls" \
    "wrapper consumed a prefix line after the first usable one"
  pass "fm-gh.sh reads only the first non-empty, non-comment, trimmed prefix line"
}

test_wrapper_ignores_indented_comments() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/indented-comments"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"
  {
    printf '  # an indented comment line  \n'
    printf '%s indented-comment-token --\n' "$case_dir/tools/fakecred"
  } > "$home/config/gh-credential"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'token:indented-comment-token' "$case_dir/gh.calls" \
    "wrapper classified an indented comment as a credential prefix"
  pass "fm-gh.sh ignores credential comments after trimming whitespace"
}

test_shim_does_not_recurse_when_credential_resolves_gh_through_it() {
  local case_dir real_dir shim_dir home out
  case_dir="$TMP_ROOT/recursion"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir" "$case_dir/tools"
  ln -sf "$SHIM" "$shim_dir/gh"
  # A credential runner that resolves `gh` from PATH again. Without the recursion
  # stop this re-enters the shim forever instead of reaching the real gh.
  cat > "$case_dir/tools/loopcred" << 'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--" ] && shift
shift             # drop the resolved real gh path the shim passed
exec gh "$@"      # resolve gh from PATH again, hitting the shim a second time
EOF
  chmod +x "$case_dir/tools/loopcred"
  make_home "$home" "$case_dir/tools/loopcred --"

  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh pr create --title T < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "recursive credential resolution did not terminate at the real gh"
  local calls
  calls=$(grep -c '^argv:' "$case_dir/gh.calls")
  [ "$calls" = "1" ] || fail "expected exactly one real gh invocation, got $calls"
  pass "the shim routes at most once even when the credential re-resolves gh from PATH"
}

# find_bash32: echo the path of an available bash 3.2, or nothing. macOS still ships
# 3.2 as the system bash, and firstmate scripts must keep working under it.
find_bash32() {
  local candidate
  for candidate in /bin/bash /usr/bin/bash; do
    [ -x "$candidate" ] || continue
    case "$("$candidate" --version 2> /dev/null | head -1)" in
      *'version 3.'*)
        printf '%s\n' "$candidate"
        return 0
        ;;
    esac
  done
  return 1
}

test_bash32_runs_both_credential_paths() {
  local bash32 case_dir real_dir home out
  bash32=$(find_bash32) || {
    echo "skip: no bash 3.2 available for the legacy-shell regression"
    return 0
  }
  case_dir="$TMP_ROOT/bash32"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"

  # The unconfigured path is the one every home without config/gh-credential takes, and
  # under `set -u` bash 3.2 rejects an empty array's "${arr[@]}" expansion as unbound.
  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$bash32" "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null 2>&1
  )
  assert_not_contains "$out" "unbound variable" \
    "unconfigured wrapper hit an unbound-variable error on bash 3.2"
  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "unconfigured wrapper did not exec the command on bash 3.2"

  make_home "$home" "$case_dir/tools/fakecred legacy-shell-token --"
  FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$bash32" "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null > /dev/null 2>&1
  assert_grep 'token:legacy-shell-token' "$case_dir/gh.calls" \
    "configured wrapper did not inject the credential on bash 3.2"
  pass "fm-gh.sh runs both the unconfigured and configured paths under bash 3.2"
}

test_installer_reports_and_enforces_precedence() {
  local case_dir real_dir shim_dir out status
  case_dir="$TMP_ROOT/installer"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir"

  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  assert_contains "$out" "shim: not installed" "check did not report an absent shim"
  expect_code 1 "$status" "check on an absent shim"

  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1)
  assert_contains "$out" "installed:" "install did not report the created link"
  assert_contains "$out" "delegates to: $real_dir/gh" "install did not report the real gh"
  [ -L "$shim_dir/gh" ] || fail "install did not create a symlink named gh"

  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 0 "$status" "check on a winning installed shim"
  assert_contains "$out" "precedence: $shim_dir wins" "check did not confirm precedence"

  # Losing precedence must be reported, because a shim the daemon never resolves is
  # indistinguishable from no shim at all.
  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$real_dir:$shim_dir" 2>&1) || status=$?
  expect_code 1 "$status" "check on a shim that loses precedence"
  assert_contains "$out" "does NOT win" "check did not report lost precedence"

  out=$("$INSTALLER" --uninstall --dir "$shim_dir" 2>&1)
  assert_contains "$out" "removed:" "uninstall did not report removal"
  assert_absent "$shim_dir/gh" "uninstall left the shim in place"
  pass "the installer creates, verifies, reports precedence for, and removes the shim"
}

test_installer_refuses_to_replace_a_foreign_gh() {
  local case_dir real_dir shim_dir status out
  case_dir="$TMP_ROOT/foreign"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  make_fake_gh "$shim_dir"

  status=0
  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 1 "$status" "install over a real file"
  assert_contains "$out" "this installer does not own it; remove it yourself first" \
    "installer did not refuse to overwrite an existing gh binary"

  # An unrelated gh symlink is equally not ours to delete.
  rm -f "$shim_dir/gh"
  ln -sf "$real_dir/gh" "$shim_dir/gh"
  status=0
  out=$("$INSTALLER" --uninstall --dir "$shim_dir" 2>&1) || status=$?
  expect_code 1 "$status" "uninstall of a foreign symlink"
  assert_present "$shim_dir/gh" "uninstall removed a symlink it does not own"
  pass "the installer refuses to overwrite or remove a gh it does not own"
}

test_installer_refuses_to_replace_a_foreign_symlink() {
  local case_dir real_dir shim_dir status out target
  case_dir="$TMP_ROOT/foreign-symlink"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir"
  ln -s "$real_dir/gh" "$shim_dir/gh"
  target=$(readlink "$shim_dir/gh")

  status=0
  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 1 "$status" "install over a foreign symlink"
  assert_contains "$out" "this installer does not own it; remove it yourself first" \
    "installer did not refuse to overwrite a foreign gh symlink"
  [ -L "$shim_dir/gh" ] || fail "installer removed a foreign gh symlink"
  [ "$(readlink "$shim_dir/gh")" = "$target" ] || \
    fail "installer changed the target of a foreign gh symlink"
  pass "the installer refuses a foreign gh symlink and leaves it intact"
}

test_pr_create_without_repo_injects_origin_target
test_pr_option_values_cannot_mask_origin_target
test_pr_create_with_repo_preserves_caller_target
test_pr_edit_without_origin_refuses_before_credential_route
test_ci_403_falls_back_to_exact_head_green_without_privileged_token
test_ci_deeper_denial_path_falls_back_to_exact_head_green
test_ci_403_falls_back_to_exact_head_red
test_ci_zero_exact_head_runs_stays_pending
test_ci_maps_cancel_skipping_and_pending_across_pages
test_ci_pagination_avoids_the_rejected_slurp_and_jq_combination
test_ci_workflow_runs_failure_preserves_the_gh_error
test_ci_pr_head_drift_refuses_stale_verdict
test_ci_unrelated_failures_preserve_original_result
test_ci_unsupported_shapes_exec_real_gh_directly
test_non_pr_invocations_pass_through_untouched
test_wrapper_without_config_is_transparent
test_configured_wrapper_replaces_ambient_tokens
test_wrapper_ignores_comments_and_blank_lines
test_wrapper_ignores_indented_comments
test_shim_does_not_recurse_when_credential_resolves_gh_through_it
test_bash32_runs_both_credential_paths
test_installer_reports_and_enforces_precedence
test_installer_refuses_to_replace_a_foreign_gh
test_installer_refuses_to_replace_a_foreign_symlink
