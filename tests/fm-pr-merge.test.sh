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
#   (f) malformed PR/MR URLs fail fast without calling either forge
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the target comes from the URL
#   (i) GitLab.com and self-hosted nested projects use the exact derived target
#   (j) GitLab lookup, metadata, CLI, argument, and merge failures fail closed
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

add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
case "${1:-} ${2:-}" in
  "mr view")
    [ "${FM_TEST_GLAB_LOOKUP_FAIL:-0}" = 0 ] || exit 1
    printf 'title:\tfixture\nstate:\topened\nurl:\t%s\n--\nfixture body\n' "$FM_TEST_GLAB_URL"
    ;;
  "mr merge")
    [ "${FM_TEST_GLAB_MERGE_FAIL:-0}" = 0 ] || exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/glab"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_URL="${FM_TEST_GLAB_URL:-}" \
  FM_TEST_GLAB_LOOKUP_FAIL="${FM_TEST_GLAB_LOOKUP_FAIL:-0}" \
  FM_TEST_GLAB_MERGE_FAIL="${FM_TEST_GLAB_MERGE_FAIL:-0}" \
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
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/01' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed MR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/01' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_gitlab_com_success_records_exact_metadata() {
  local case_dir url
  case_dir=$(make_case gitlab-com-success)
  url=https://gitlab.com/example/repo/-/merge_requests/31
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitlab-com-success: merge failed"

  [ "$(grep -c '^pr=' "$case_dir/state/task-x1.meta")" -eq 1 ] \
    || fail "gitlab-com-success: metadata did not contain exactly one pr= line"
  grep -qxF "pr=$url" "$case_dir/state/task-x1.meta" \
    || fail "gitlab-com-success: canonical MR metadata was not exact"
  assert_no_grep '^pr_head=' "$case_dir/state/task-x1.meta" \
    "gitlab-com-success: GitLab unexpectedly recorded pr_head="
  grep -qxF 'mr view 31 -R https://gitlab.com/example/repo' "$case_dir/glab.log" \
    || fail "gitlab-com-success: lookup target was not exact"
  grep -qxF 'mr merge 31 -R https://gitlab.com/example/repo --squash --yes' "$case_dir/glab.log" \
    || fail "gitlab-com-success: default squash merge target was not exact"
  pass "fm-pr-merge records exact GitLab metadata and defaults to squash"
}

test_self_hosted_nested_project_and_explicit_method() {
  local case_dir url
  case_dir=$(make_case gitlab-self-hosted)
  url=https://gitlab.corp.example/platform/payments/runtime/service/-/merge_requests/42
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" -- --rebase --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitlab-self-hosted: merge failed"

  grep -qxF 'mr view 42 -R https://gitlab.corp.example/platform/payments/runtime/service' "$case_dir/glab.log" \
    || fail "gitlab-self-hosted: lookup lost host or nested project path"
  grep -qxF 'mr merge 42 -R https://gitlab.corp.example/platform/payments/runtime/service --yes --rebase --remove-source-branch' "$case_dir/glab.log" \
    || fail "gitlab-self-hosted: explicit rebase merge was not forwarded exactly"
  assert_no_grep 'mr merge .*--squash' "$case_dir/glab.log" \
    "gitlab-self-hosted: explicit rebase received default squash"
  pass "fm-pr-merge supports self-hosted nested GitLab projects and explicit methods"
}

test_gitlab_option_value_not_read_as_merge_method() {
  local case_dir url
  case_dir=$(make_case gitlab-value-not-method)
  url=https://gitlab.com/example/repo/-/merge_requests/47
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" -- --squash-message '-r' -m '-s' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitlab-value-not-method: merge failed"

  grep -qxF 'mr merge 47 -R https://gitlab.com/example/repo --squash --yes --squash-message -r -m -s' "$case_dir/glab.log" \
    || fail "gitlab-value-not-method: literal -r/-s option values suppressed the default --squash"
  pass "fm-pr-merge keeps default squash when option values look like merge methods"
}

test_gitlab_missing_cli_refuses_before_recording() {
  local case_dir rc url
  case_dir=$(make_case gitlab-missing-cli)
  url=https://gitlab.com/example/repo/-/merge_requests/43
  mkdir -p "$case_dir/wt"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:/usr/bin:/bin" \
    "$PR_MERGE" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-missing-cli: fm-pr-merge should refuse"
  assert_grep 'requires glab on PATH' "$case_dir/stderr" \
    "gitlab-missing-cli: refusal did not name glab"
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
    "gitlab-missing-cli: MR metadata was recorded without glab"
  pass "fm-pr-merge refuses GitLab merge when glab is missing"
}

test_gitlab_lookup_and_target_verification_fail_closed() {
  local case_dir rc url
  case_dir=$(make_case gitlab-lookup-failure)
  url=https://gitlab.com/example/repo/-/merge_requests/44
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  set +e
  FM_TEST_GLAB_URL="$url" FM_TEST_GLAB_LOOKUP_FAIL=1 \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-lookup-failure: lookup failure should refuse"
  assert_grep 'GitLab merge request lookup failed' "$case_dir/stderr" \
    "gitlab-lookup-failure: refusal was unclear"
  assert_no_grep '^mr merge ' "$case_dir/glab.log" \
    "gitlab-lookup-failure: merge ran after lookup failure"

  case_dir=$(make_case gitlab-target-mismatch)
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"
  set +e
  FM_TEST_GLAB_URL=https://gitlab.com/example/other/-/merge_requests/44 \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-target-mismatch: target mismatch should refuse"
  assert_grep 'target could not be verified' "$case_dir/stderr" \
    "gitlab-target-mismatch: refusal was unclear"
  assert_no_grep '^mr merge ' "$case_dir/glab.log" \
    "gitlab-target-mismatch: merge ran against an unverified target"
  pass "fm-pr-merge fails closed on GitLab lookup or canonical-target failure"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc url
  case_dir=$(make_case gitlab-merge-failure)
  url=https://gitlab.com/example/repo/-/merge_requests/45
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  set +e
  FM_TEST_GLAB_URL="$url" FM_TEST_GLAB_MERGE_FAIL=1 \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-failure: merge failure should propagate"
  grep -qxF "pr=$url" "$case_dir/state/task-x1.meta" \
    || fail "gitlab-merge-failure: exact metadata was not recorded first"
  grep -qxF 'mr merge 45 -R https://gitlab.com/example/repo --squash --yes' "$case_dir/glab.log" \
    || fail "gitlab-merge-failure: merge command was not exact"
  pass "fm-pr-merge propagates GitLab merge-command failure"
}

test_gitlab_target_override_spellings_refuse() {
  local spelling name case_dir rc url
  url=https://gitlab.com/right/repo/-/merge_requests/46
  for spelling in '--repo wrong/repo' '--repo=wrong/repo' '-R wrong/repo' '-Rwrong/repo'; do
    name=$(printf '%s' "$spelling" | tr -c 'A-Za-z0-9' '_')
    case_dir=$(make_case "gitlab-override-$name")
    mkdir -p "$case_dir/wt"
    add_glab_mock "$case_dir"
    : > "$case_dir/glab.log"
    set +e
    # Word splitting is deliberate: each fixture models the CLI spelling shown.
    # shellcheck disable=SC2086
    FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" -- $spelling \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "gitlab-override-$name: override should refuse"
    assert_grep 'must not override the repository' "$case_dir/stderr" \
      "gitlab-override-$name: refusal was unclear"
    assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
      "gitlab-override-$name: metadata changed before argument refusal"
    [ ! -s "$case_dir/glab.log" ] || fail "gitlab-override-$name: glab ran despite override"
  done
  pass "fm-pr-merge rejects every documented glab repository-selector spelling"
}

test_gitlab_argument_injection_is_data_and_unknown_flags_refuse() {
  local case_dir rc url marker
  case_dir=$(make_case gitlab-argument-injection)
  url=https://gitlab.com/example/repo/-/merge_requests/47
  marker="$case_dir/injected"
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"

  FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" -- \
    --squash-message "\$(touch $marker)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-argument-injection: safe message was rejected"
  [ ! -e "$marker" ] || fail "gitlab-argument-injection: argument bytes executed"

  case_dir=$(make_case gitlab-unknown-target-flag)
  mkdir -p "$case_dir/wt"
  add_glab_mock "$case_dir"
  : > "$case_dir/glab.log"
  set +e
  FM_TEST_GLAB_URL="$url" run_pr_merge "$case_dir" task-x1 "$url" -- --hostname evil.example \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-unknown-target-flag: unknown target flag should refuse"
  assert_grep 'unsupported GitLab merge argument' "$case_dir/stderr" \
    "gitlab-unknown-target-flag: refusal was unclear"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-unknown-target-flag: glab ran"
  pass "fm-pr-merge keeps safe GitLab values as data and rejects unknown flags"
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
test_gitlab_com_success_records_exact_metadata
test_self_hosted_nested_project_and_explicit_method
test_gitlab_option_value_not_read_as_merge_method
test_gitlab_missing_cli_refuses_before_recording
test_gitlab_lookup_and_target_verification_fail_closed
test_gitlab_merge_failure_propagates
test_gitlab_target_override_spellings_refuse
test_gitlab_argument_injection_is_data_and_unknown_flags_refuse
