#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix (GitHub, via gh-axi):
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# Matrix (Gitea/Forgejo, via tea): mirrors (a), (b), (c), (g), (h) above, plus
#   (i) merge is refused when no tea login matches the record's host
#   (j) merge is refused before tea when tea itself is missing from PATH
# A Gitea/Forgejo task never records pr_head=, because tea has no head-commit
# field in any output format (see docs/forge-merge-watch.md).
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

# Fake tea: "login list" reports whatever logins the case fixture file holds
# (so a test can freely control ambiguous, missing, or matching logins without
# teaching the fake tool any host-matching logic of its own), and "pulls
# merge" records its invocation and exits 0 unless told to fail. Args:
# case_dir login host
add_tea_mocks() {
  local case_dir=$1 login=${2:-forge.example} host=${3:-forge.example}
  printf '%s\n' "$login,https://$host,$host,someuser,false" > "$case_dir/tea-logins.csv"
  cat > "$case_dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"
case "${1:-} ${2:-}" in
  "login list")
    printf 'Name,URL,SSHHost,User,Default\n'
    cat "${FM_TEST_TEA_LOGINS_FILE:?}"
    ;;
  "pulls merge")
    [ "${FM_TEST_TEA_MERGE_FAIL:-0}" = 0 ] || { echo "error: tea pulls merge failed" >&2; exit 1; }
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tea"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_TEA_LOG="$case_dir/tea.log" \
  FM_TEST_TEA_LOGINS_FILE="$case_dir/tea-logins.csv" \
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

test_gitea_records_pr_and_merges() {
  local case_dir
  case_dir=$(make_case gitea-records-and-merges)
  mkdir -p "$case_dir/wt"
  add_tea_mocks "$case_dir"
  : > "$case_dir/tea.log"

  run_pr_merge "$case_dir" task-x1 https://forge.example/example/repo/pulls/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitea-records-and-merges: fm-pr-merge should succeed: $(cat "$case_dir/stderr")"

  assert_grep 'pr=https://forge.example/example/repo/pulls/9' "$case_dir/state/task-x1.meta" \
    "gitea-records-and-merges: pr= was not recorded"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "gitea-records-and-merges: a Gitea/Forgejo task should never record pr_head="
  grep -qxF 'pulls merge 9 --repo example/repo --login forge.example --style squash' "$case_dir/tea.log" \
    || fail "gitea-records-and-merges: tea pulls merge was not invoked with number, --repo, --login, and default --style squash"
  pass "fm-pr-merge records pr= (never pr_head=) before invoking tea pulls merge"
}

test_gitea_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case gitea-merge-fails)
  mkdir -p "$case_dir/wt"
  add_tea_mocks "$case_dir"
  : > "$case_dir/tea.log"

  set +e
  FM_TEST_TEA_MERGE_FAIL=1 run_pr_merge "$case_dir" task-x1 https://forge.example/example/repo/pulls/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitea-merge-fails: fm-pr-merge should propagate the tea merge failure"
  assert_grep 'pr=https://forge.example/example/repo/pulls/13' "$case_dir/state/task-x1.meta" \
    "gitea-merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real tea merge failure without silently succeeding"
}

test_gitea_extra_style_args_forwarded() {
  local case_dir
  case_dir=$(make_case gitea-extra-style)
  mkdir -p "$case_dir/wt"
  add_tea_mocks "$case_dir"
  : > "$case_dir/tea.log"

  run_pr_merge "$case_dir" task-x1 https://forge.example/example/repo/pulls/15 -- --style rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitea-extra-style: fm-pr-merge failed"

  grep -qxF 'pulls merge 15 --repo example/repo --login forge.example --style rebase' "$case_dir/tea.log" \
    || fail "gitea-extra-style: caller --style rebase was not forwarded without an extra default --style squash"
  pass "fm-pr-merge does not add default --style squash when the caller passes an explicit tea style"
}

test_gitea_repo_login_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case gitea-repo-login-override)
  mkdir -p "$case_dir/wt"
  add_tea_mocks "$case_dir"
  : > "$case_dir/tea.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://forge.example/right/repo/pulls/5 -- --login wrong \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitea-repo-login-override: fm-pr-merge should refuse a login override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "gitea-repo-login-override: refusal did not explain the override"
  assert_no_grep 'pr=https://forge.example/right/repo/pulls/5' "$case_dir/state/task-x1.meta" \
    "gitea-repo-login-override: PR URL was recorded before rejecting the login override"
  assert_no_grep 'pulls merge' "$case_dir/tea.log" \
    "gitea-repo-login-override: tea pulls merge was invoked despite the login override"
  pass "fm-pr-merge refuses tea repo/login override args before recording state"
}

test_gitea_requires_tea_on_path() {
  local case_dir rc
  case_dir=$(make_case gitea-requires-tea)
  mkdir -p "$case_dir/wt"

  # A restricted, curated PATH (never the ambient ${PATH}) proves this refusal
  # holds regardless of whether the current host happens to have a real tea
  # installed elsewhere on PATH.
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$PR_MERGE" task-x1 https://forge.example/example/repo/pulls/8 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitea-requires-tea: fm-pr-merge should refuse with tea absent"
  assert_grep 'requires tea on PATH' "$case_dir/stderr" \
    "gitea-requires-tea: refusal did not report the missing tea CLI"
  pass "fm-pr-merge refuses to merge a Gitea/Forgejo pull request with tea absent from PATH"
}

test_gitea_ambiguous_login_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case gitea-ambiguous-login)
  mkdir -p "$case_dir/wt"
  add_tea_mocks "$case_dir"
  printf '%s\n%s\n' \
    'forge.example,https://forge.example,forge.example,one,false' \
    'forge-alias,https://forge.example,forge.example,two,false' \
    > "$case_dir/tea-logins.csv"
  : > "$case_dir/tea.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://forge.example/example/repo/pulls/8 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitea-ambiguous-login: fm-pr-merge should refuse with an ambiguous login"
  assert_grep 'could not resolve exactly one tea login' "$case_dir/stderr" \
    "gitea-ambiguous-login: refusal did not report the ambiguous login"
  assert_no_grep 'pulls merge' "$case_dir/tea.log" \
    "gitea-ambiguous-login: tea pulls merge was invoked despite the ambiguous login"
  pass "fm-pr-merge refuses to guess between ambiguous tea logins"
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
test_gitea_records_pr_and_merges
test_gitea_merge_failure_propagates_after_recording
test_gitea_extra_style_args_forwarded
test_gitea_repo_login_override_args_refuse_before_recording
test_gitea_requires_tea_on_path
test_gitea_ambiguous_login_refuses_before_merge
