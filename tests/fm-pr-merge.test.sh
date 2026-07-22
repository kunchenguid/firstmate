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
#   (i) a Codebase MR is merged by internal --mr-id, never by its number, and
#       never squashed by default
#   (j) Codebase merge-method shims map onto bytedcli's actual flags
#   (k) a lone --squash-commits does not suppress the default Codebase method
#   (l) flag-like, traversing, or single-segment Codebase repo paths fail fast
#   (r) an explicit squash of a merge-commit head is refused before bytedcli
#   (s) an explicit squash of an ordinary head still goes through
#   (t) an explicit squash is refused when the head commit cannot be read
#   (m) the armed merge poll wakes once, not silently, when its library is gone
#   (n) an MR version with no head commit does not shift its source ref left
#   (o) the armed merge poll increments failures before provider lookup
#   (p) the armed merge poll wakes once after repeated state-lookup failures
#   (q) one successful lookup resets the poll's consecutive-failure count
#
# The poll's own signal logic lives in bin/fm-poll-lib.sh and is covered by
# tests/fm-poll-lib.test.sh; the cases here cover only what arming produces.
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
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
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
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' 'ffffffffffffffffffffffffffffffffffffffff' ; exit 0 ;;
      *headRefOid*) printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffff' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# bytedcli mock for MR 24 in platform/team/repo. The MR's user-visible number is
# 24 but its internal id is 784897989989491, and only the internal id is a valid
# `codebase mr merge` selector - so a mock that answered to number 24 would hide
# exactly the bug this suite has to catch. Optional third arg is the head
# commit's parent count; 2 makes the head a merge commit.
add_bytedcli_mock() {
  local case_dir=$1 head=$2 parents=${3:-1} parents_json
  case "$parents" in
    2) parents_json='["1111111111111111111111111111111111111111","2222222222222222222222222222222222222222"]' ;;
    *) parents_json='["1111111111111111111111111111111111111111"]' ;;
  esac
  cat > "$case_dir/fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_BYTEDCLI_LOG"
case "\$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Id":784897989989491,"Number":24,"Status":"merged"},"version":{"SourceCommitId":"$head","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
  "--json codebase commit get -r $head -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"commit":{"Id":"$head","Parents":$parents_json}},"error":null}
JSON
    exit 0
    ;;
  codebase\\ mr\\ merge\\ --mr-id\\ 784897989989491\\ -R\\ platform/team/repo*)
    exit 0
    ;;
esac
echo "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

# Same MR, but its head commit cannot be read - so firstmate cannot rule out a
# merge commit and must refuse a squash rather than assume the head is ordinary.
add_bytedcli_mock_commit_unreadable() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_BYTEDCLI_LOG"
case "\$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Id":784897989989491,"Number":24,"Status":"merged"},"version":{"SourceCommitId":"$head","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
  "--json codebase commit get -r $head -R platform/team/repo")
    echo "bytedcli: transient commit lookup failure" >&2
    exit 1
    ;;
  codebase\\ mr\\ merge\\ --mr-id\\ 784897989989491\\ -R\\ platform/team/repo*)
    exit 0
    ;;
esac
echo "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
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
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
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
  run_pr_merge "$case_dir" task-x1 'https://github.com/example/repo/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  assert_no_grep 'pr=https://github.com/example/repo/merge_requests/1' "$case_dir/state/task-x1.meta" \
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
  assert_grep 'must not override the repository or MR parsed from the PR/MR URL' "$case_dir/stderr" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_codebase_url_records_head_and_invokes_bytedcli_merge() {
  local case_dir head poll_out
  case_dir=$(make_case codebase-merge)
  mkdir -p "$case_dir/wt"
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-merge: fm-pr-merge failed"

  assert_grep 'pr=https://code.byted.org/platform/team/repo/merge_requests/24' "$case_dir/state/task-x1.meta" \
    "codebase-merge: pr= was not recorded"
  assert_grep "pr_head=$head" "$case_dir/state/task-x1.meta" \
    "codebase-merge: Codebase pr_head= was not recorded"
  grep -qxF -- '--json codebase mr get 24 -R platform/team/repo' "$case_dir/bytedcli.log" \
    || fail "codebase-merge: bytedcli MR get was not invoked from URL"
  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits false' "$case_dir/bytedcli.log" \
    || fail "codebase-merge: bytedcli MR merge was not invoked with --mr-id <internal id> and a non-squash default"
  assert_no_grep 'mr merge 24' "$case_dir/bytedcli.log" \
    "codebase-merge: the user-visible MR number was passed as a selector, which bytedcli rejects"
  assert_no_grep 'squash-commits true' "$case_dir/bytedcli.log" \
    "codebase-merge: Codebase merges must never default to squash"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "codebase-merge: gh-axi was invoked for a Codebase MR"
  poll_out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh")
  [ "$poll_out" = merged ] || fail "codebase-merge: merge poll did not read merged state via bytedcli"
  pass "fm-pr-merge parses Codebase MR URLs, records head, and invokes bytedcli merge"
}

test_codebase_merge_method_shims_map_to_bytedcli_flags() {
  local case_dir
  case_dir=$(make_case codebase-methods)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --rebase --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-methods: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method rebase_merge --squash-commits false --remove-source-branch true' "$case_dir/bytedcli.log" \
    || fail "codebase-methods: Codebase merge-method shims did not map to bytedcli flags"
  pass "fm-pr-merge maps Codebase merge-method shims onto bytedcli flags"
}

test_codebase_squash_commits_keeps_default_merge_method() {
  local case_dir
  case_dir=$(make_case codebase-squash-commits)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash-commits false \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-squash-commits: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits false' "$case_dir/bytedcli.log" \
    || fail "codebase-squash-commits: --squash-commits suppressed firstmate's default --merge-method"
  pass "fm-pr-merge keeps its default Codebase merge method when only --squash-commits is passed"
}

test_codebase_squash_of_merge_head_is_refused() {
  local case_dir rc
  case_dir=$(make_case codebase-squash-merge-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 2
  : > "$case_dir/bytedcli.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "codebase-squash-merge-head: squashing a merge-commit head must be refused"
  assert_grep 'is a merge commit' "$case_dir/stderr" \
    "codebase-squash-merge-head: refusal did not name the merge commit"
  assert_no_grep 'mr merge' "$case_dir/bytedcli.log" \
    "codebase-squash-merge-head: bytedcli merged an MR whose head is a merge commit"
  pass "fm-pr-merge refuses to squash a Codebase MR whose head is a merge commit"
}

test_codebase_squash_of_ordinary_head_proceeds() {
  local case_dir
  case_dir=$(make_case codebase-squash-ordinary-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca 1
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-squash-ordinary-head: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits true' "$case_dir/bytedcli.log" \
    || fail "codebase-squash-ordinary-head: an explicitly requested squash of an ordinary head was not performed"
  pass "fm-pr-merge still squashes a Codebase MR when the caller asks and the head is an ordinary commit"
}

test_codebase_squash_refused_when_head_unreadable() {
  local case_dir rc
  case_dir=$(make_case codebase-squash-unknown-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock_commit_unreadable "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/bytedcli.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "codebase-squash-unknown-head: an unreadable head must not be assumed ordinary"
  assert_grep 'cannot rule out a merge commit' "$case_dir/stderr" \
    "codebase-squash-unknown-head: refusal did not explain the unverifiable head"
  assert_no_grep 'mr merge' "$case_dir/bytedcli.log" \
    "codebase-squash-unknown-head: bytedcli squashed an MR whose head could not be verified"
  pass "fm-pr-merge refuses a squash it cannot prove is safe"
}

test_rejects_unsafe_codebase_repo_paths() {
  local case_dir rc url
  for url in https://code.byted.org/-R/merge_requests/1 \
    https://code.byted.org/platform/../etc/merge_requests/1 \
    https://code.byted.org/lonely/merge_requests/1; do
    case_dir=$(make_case "unsafe-codebase-$RANDOM")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
    add_bytedcli_mock "$case_dir" dddddddddddddddddddddddddddddddddddddddd
    : > "$case_dir/bytedcli.log"

    set +e
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "unsafe-codebase: fm-pr-merge should refuse $url"
    assert_no_grep "pr=$url" "$case_dir/state/task-x1.meta" \
      "unsafe-codebase: $url was recorded in meta"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "unsafe-codebase: $url armed a merge poll"
    [ ! -s "$case_dir/bytedcli.log" ] || fail "unsafe-codebase: bytedcli was invoked for $url"
  done
  pass "fm-pr-merge refuses Codebase MR URLs with flag-like, traversing, or single-segment repo paths"
}

test_merge_poll_reports_a_broken_poll_lib_once() {
  local case_dir shim first second
  case_dir=$(make_case broken-poll-lib)
  mkdir -p "$case_dir/wt" "$case_dir/root/bin"
  cp "$ROOT/bin/fm-poll-lib.sh" "$ROOT/bin/fm-scm-lib.sh" "$case_dir/root/bin/"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  FM_ROOT_OVERRIDE="$case_dir/root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/31 >/dev/null 2>&1 \
    || fail "broken-poll-lib: fm-pr-check failed to arm the poll"

  shim="$case_dir/state/task-x1.check.sh"
  # The generated poll is a shell around bin/fm-poll-lib.sh, so an unloadable
  # library is the one failure it must handle with its own inlined code.
  rm -f "$case_dir/root/bin/fm-poll-lib.sh"
  first=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" 2>/dev/null)
  second=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" 2>/dev/null)

  assert_contains "$first" 'poll broken' \
    "broken-poll-lib: an unloadable poll library must wake firstmate instead of polling silently"
  [ -z "$second" ] || fail "broken-poll-lib: the diagnostic must not repeat on every poll"
  assert_present "$case_dir/state/task-x1.check.error" \
    "broken-poll-lib: no durable marker was left for the broken poll"
  pass "the merge poll surfaces an unloadable poll library once instead of going blind"
}

# bytedcli mock for an MR whose latest version carries a SourceRef but no
# SourceCommitId - the empty middle field of fm_scm_pr_info's record.
add_bytedcli_mock_headless() {
  local case_dir=$1
  cat > "$case_dir/fakebin/bytedcli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_BYTEDCLI_LOG"
case "$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Number":24,"Status":"opened"},"version":{"SourceCommitId":"","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
esac
echo "unexpected bytedcli args: $*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

test_codebase_empty_head_does_not_shift_source_ref() {
  local case_dir info fields
  case_dir=$(make_case codebase-empty-head)
  mkdir -p "$case_dir/wt"
  add_bytedcli_mock_headless "$case_dir"
  : > "$case_dir/bytedcli.log"

  info=$(
    FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
    PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$1/bin/fm-scm-lib.sh"
        fm_scm_pr_info "" "https://code.byted.org/platform/team/repo/merge_requests/24"' _ "$ROOT"
  ) || fail "codebase-empty-head: fm_scm_pr_info failed"

  IFS=$'\037' read -r _ _ head source_ref <<EOF
$info
EOF
  [ -z "$head" ] \
    || fail "codebase-empty-head: an absent SourceCommitId was read as head '$head'"
  [ "$source_ref" = refs/merge-requests/24/24/1 ] \
    || fail "codebase-empty-head: source ref was lost or shifted, got '$source_ref'"

  fields=$(printf '%s' "$info" | tr -cd '\037' | wc -c | tr -d ' ')
  [ "$fields" = 3 ] || fail "codebase-empty-head: expected 4 unit-separated fields, got $((fields + 1))"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 \
    >/dev/null 2>&1 || fail "codebase-empty-head: fm-pr-check failed to arm the poll"

  assert_no_grep 'pr_head=refs/' "$case_dir/state/task-x1.meta" \
    "codebase-empty-head: a source ref was recorded as the MR head commit"
  pass "an MR version with no SourceCommitId keeps its source ref in the right field"
}

# gh mock whose `pr view` fails until $case_dir/gh-ok exists, so a poll can be
# driven through consecutive failures and then a recovery.
add_gh_mock_pr_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ -e '$case_dir/gh-ok' ]; then
  printf '%s\t%s\n' 'OPEN' '9999999999999999999999999999999999999999'
  exit 0
fi
echo "gh: authentication failed" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

arm_failing_poll() {
  local case_dir=$1
  add_gh_mock_pr_view_fails "$case_dir"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/31 >/dev/null 2>&1 \
    || fail "fm-pr-check failed to arm the poll"
}

run_poll() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh" 2>/dev/null
}

test_merge_poll_counts_timeout_killed_lookup() {
  local case_dir rc fails
  case_dir=$(make_case poll-timeout-killed)
  arm_failing_poll "$case_dir"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$case_dir/fakebin/gh"

  rc=0
  PATH="$case_dir/fakebin:$PATH" perl -e '
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec @ARGV or die "exec failed: $!" }
    sleep 1;
    kill "TERM", $pid;
    waitpid($pid, 0);
    exit 124;
  ' bash "$case_dir/state/task-x1.check.sh" >/dev/null 2>&1 || rc=$?

  [ "$rc" != 0 ] || fail "poll-timeout-killed: killed poll unexpectedly succeeded"
  fails=$(cat "$case_dir/state/task-x1.check.fails" 2>/dev/null || true)
  [ "$fails" = 1 ] \
    || fail "poll-timeout-killed: provider timeout did not persist the pre-incremented failure count (got '$fails')"
  pass "the merge poll counts provider lookups killed before returning"
}

test_merge_poll_wakes_after_repeated_lookup_failures() {
  local case_dir first second third fourth
  case_dir=$(make_case poll-lookup-failure)
  arm_failing_poll "$case_dir"

  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")
  third=$(run_poll "$case_dir")
  fourth=$(run_poll "$case_dir")

  [ -z "$first" ] || fail "poll-lookup-failure: a single transient lookup failure must stay quiet"
  [ -z "$second" ] || fail "poll-lookup-failure: a second transient lookup failure must stay quiet"
  assert_contains "$third" 'poll broken' \
    "poll-lookup-failure: a persistent lookup failure must wake firstmate instead of polling silently"
  [ -z "$fourth" ] || fail "poll-lookup-failure: the diagnostic must not repeat on every poll"
  assert_present "$case_dir/state/task-x1.check.error" \
    "poll-lookup-failure: no durable marker was left for the broken poll"
  pass "the merge poll wakes once after repeated PR/MR state lookup failures"
}

test_merge_poll_failure_count_resets_on_success() {
  local case_dir out
  case_dir=$(make_case poll-failure-reset)
  arm_failing_poll "$case_dir"

  run_poll "$case_dir" >/dev/null
  run_poll "$case_dir" >/dev/null
  : > "$case_dir/gh-ok"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "poll-failure-reset: an OPEN PR must not wake firstmate, got '$out'"
  assert_absent "$case_dir/state/task-x1.check.fails" \
    "poll-failure-reset: a successful lookup must clear the consecutive-failure count"

  rm -f "$case_dir/gh-ok"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "poll-failure-reset: failures before a success must not count toward the wake"
  assert_absent "$case_dir/state/task-x1.check.error" \
    "poll-failure-reset: a single failure after a success must not mark the poll broken"
  pass "one successful lookup resets the merge poll's consecutive-failure count"
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
test_codebase_url_records_head_and_invokes_bytedcli_merge
test_codebase_merge_method_shims_map_to_bytedcli_flags
test_codebase_squash_commits_keeps_default_merge_method
test_codebase_squash_of_merge_head_is_refused
test_codebase_squash_of_ordinary_head_proceeds
test_codebase_squash_refused_when_head_unreadable
test_rejects_unsafe_codebase_repo_paths
test_merge_poll_reports_a_broken_poll_lib_once
test_codebase_empty_head_does_not_shift_source_ref
test_merge_poll_counts_timeout_killed_lookup
test_merge_poll_wakes_after_repeated_lookup_failures
test_merge_poll_failure_count_resets_on_success
