#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires. A Firstmate missing-Review override must
# also leave a durable receipt in that same metadata before merge.
#
# Matrix:
#   (a) a green, mergeable PR records pr= and pr_head= before merging
#   (b) a non-green PR is refused unless --allow-red is explicit
#   (c) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (d) extra gh-axi pr merge args are forwarded after number and --repo
#   (e) merge is refused before gh-axi when task meta is missing
#   (f) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (g) malformed PR URL fails fast without calling gh-axi
#   (h) explicit merge method is not overridden by the default --squash
#   (i) repo override args fail fast because the repo comes from the URL
#   (j) a Firstmate self-merge rejects an empty body and every incomplete state
#   (k) a Firstmate self-merge accepts every completed Review rendering
#   (l) only the distinct captain-authorized flag bypasses a missing Review
#   (m) an override receipt write failure refuses the merge
#   (n) an override receipt survives a PR identity refresh that does not merge
#   (o) an override receipt does not follow the task onto a different PR, and
#       the discarded authorization is reported instead of vanishing
#   (p) a failed or interrupted receipt write leaves no staged metadata behind
#   (q) a project that cannot be resolved is guarded, not waved through
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# A real repository that is not this one, so the non-Firstmate cases below
# exercise "resolves to another project" rather than "cannot be resolved" -
# the two are distinct inputs to fm-pr-merge.sh's Review receipt guard.
OTHER_PROJECT="$TMP_ROOT/other-project"
git init -q "$OTHER_PROJECT"

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
    "project=$OTHER_PROJECT" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree on disk; fm-pr-check.sh tolerates a worktree it cannot stat and
  # simply skips the pr_head lookup via `gh` in that case, so give it one that
  # resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr checks") printf 'summary: "%s"\n' "${FM_FAKE_GH_CHECKS_SUMMARY:-2 passed, 0 failed, 2 total}" ;;
  api\ *)
    case "$*" in
      *mergeable_state*) printf '%s\n' "${FM_FAKE_GH_MERGEABLE:-true}" ;;
      *)
        jq_filter=${4:-}
        [ "${3:-}" = "--jq" ] && [ -n "$jq_filter" ] || exit 2
        jq -n --arg body "${FM_FAKE_GH_PR_BODY:-}" "{body: \$body} | $jq_filter"
        ;;
    esac
    ;;
esac
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

add_override_receipt_write_failure() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */.fm-pr-merge-meta.XXXXXX) exit 1 ;;
esac
command -p mktemp "$@"
SH
  chmod +x "$case_dir/fakebin/mktemp"
}

# Fails the receipt's final publish, so the staged file exists and has already
# passed every validation when the write path gives up.
add_override_receipt_publish_failure() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-merge-meta.*) exit 1 ;;
  esac
done
command -p mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# Signals the merge itself mid-staging without failing the command, so only the
# script's own signal and exit handling can remove the staged file.
add_override_receipt_signal_during_staging() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-merge-meta.*)
      command -p chmod "$@" || exit 1
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
done
command -p chmod "$@"
SH
  chmod +x "$case_dir/fakebin/chmod"
}

assert_no_staged_merge_meta() {  # <case-dir> <msg>
  local case_dir=$1 msg=$2 leftovers
  leftovers=$(find "$case_dir/state" -maxdepth 1 -name '.fm-pr-merge-meta.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "$msg (found $leftovers)"
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
  "pr checks") printf 'summary: "%s"\n' "${FM_FAKE_GH_CHECKS_SUMMARY:-2 passed, 0 failed, 2 total}" ;;
  api\ *) printf '%s\n' "${FM_FAKE_GH_MERGEABLE:-true}" ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
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

test_non_green_pr_requires_explicit_override() {
  local case_dir rc
  case_dir=$(make_case non-green)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-green: fm-pr-merge should refuse"
  assert_grep 'error: refusing to merge non-green PR' "$case_dir/stderr" \
    "non-green: refusal did not explain the safety guard"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "non-green: gh-axi pr merge was invoked"

  : > "$case_dir/gh-axi.log"
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/12 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "non-green: explicit override did not permit the merge"
  grep -qxF 'pr merge 12 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "non-green: --allow-red was forwarded or merge did not run"
  pass "fm-pr-merge refuses a non-green PR unless --allow-red is explicit"
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
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
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

make_firstmate_review_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  mkdir -p "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$ROOT" \
    "kind=ship" \
    "mode=no-mistakes"
  add_gh_mocks "$case_dir" abcdefabcdefabcdefabcdefabcdefabcdefabcd
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

test_firstmate_merge_refuses_empty_review_body() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-empty)

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-empty: empty Review body should refuse"
  assert_grep 'refusing Firstmate merge without a recorded passing no-mistakes Review' "$case_dir/stderr" \
    "firstmate-review-empty: refusal did not name the missing Review receipt"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-empty: merge ran without a Review receipt"
  pass "fm-pr-merge refuses an empty Firstmate Review body"
}

test_firstmate_merge_refuses_failed_review() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-failed)

  set +e
  FM_FAKE_GH_PR_BODY='<summary>❌ **Review** - failed</summary>' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-failed: failed Review should refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-failed: merge ran after a failed Review"
  pass "fm-pr-merge refuses a failed Firstmate Review"
}

test_firstmate_merge_accepts_passing_review() {
  local case_dir
  case_dir=$(make_firstmate_review_case firstmate-review-passed)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  FM_FAKE_GH_PR_BODY='<summary>✅ **Review** - passed</summary>' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-passed: passing Review receipt did not permit the merge"
  grep -qxF 'pr merge 127 --repo example/firstmate --squash' "$case_dir/gh-axi.log" \
    || fail "firstmate-review-passed: merge did not run after the Review passed"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-passed: ordinary merge retained a stale override receipt"
  pass "fm-pr-merge accepts a passed Firstmate Review"
}

# Every rendering below comes from the Review step's own summary templates, so
# the guard must accept the shapes the renderer actually writes rather than a
# hand-kept list of the ones seen so far. The risk forms are what a review that
# returns no findings but rates the change medium or high emits.
test_firstmate_merge_accepts_every_completed_review_rendering() {
  local body i=0 case_dir
  for body in \
    '<summary>🔧 **Review** - 1 issue found → auto-fixed ✅</summary>' \
    '<summary>🔧 **Review** - 1 issue found → auto-fixed (2) ✅</summary>' \
    '<summary>⚠️ **Review** - 2 infos</summary>' \
    '<summary>⚠️ **Review** - medium risk</summary>' \
    '<summary>🚨 **Review** - high risk</summary>'
  do
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-completed-$i")
    FM_FAKE_GH_PR_BODY="$body" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "firstmate-review-completed-$i: completed Review receipt did not permit the merge ($body)"
    grep -qxF 'pr merge 127 --repo example/firstmate --squash' "$case_dir/gh-axi.log" \
      || fail "firstmate-review-completed-$i: merge did not run after a completed Review ($body)"
    assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
      "firstmate-review-completed-$i: reviewed merge recorded a false override receipt"
  done
  pass "fm-pr-merge accepts every completed Firstmate Review rendering"
}

# The closed set of statuses the Review step renders before it has a verdict.
# The guard accepts anything outside this set, so the set is what holds it shut.
test_firstmate_merge_refuses_every_incomplete_review_state() {
  local case_dir rc state
  case_dir=$(make_firstmate_review_case firstmate-review-incomplete)

  for state in pending running auto-fixing 'review fix' skipped failed \
    'awaiting approval' 'findings unavailable'
  do
    : > "$case_dir/gh-axi.log"
    set +e
    FM_FAKE_GH_PR_BODY="<summary>⏳ **Review** - $state</summary>" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-incomplete: '$state' should refuse"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "firstmate-review-incomplete: merge ran on a Review still reporting '$state'"
  done
  pass "fm-pr-merge refuses every incomplete Firstmate Review state"
}

# A merge attempt that refuses still refreshes PR identity through
# fm-pr-check.sh first. Only the ordinary reviewed merge retires the receipt, so
# a refusal in between must leave the authorized override on the record.
test_firstmate_merge_preserves_override_receipt_across_identity_refresh() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-preserved)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_PR_BODY='<summary>✅ **Review** - passed</summary>' \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-preserved: non-green PR should refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-receipt-preserved: merge ran on a non-green PR"
  grep -qxF 'pr=https://github.com/example/firstmate/pull/127' "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-receipt-preserved: PR identity was not refreshed"
  assert_grep 'missing_review_override_ts=2026-08-14T23:59:59Z' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-preserved: identity refresh dropped the authorized override receipt"
  pass "fm-pr-merge preserves an override receipt across a PR identity refresh"
}

# The override was authorized against one pull request. Re-pointing the task at
# a different one must not carry that authorization onto a PR that never had it.
test_firstmate_merge_drops_override_receipt_when_the_pr_changes() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-other-pr)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_PR_BODY='<summary>✅ **Review** - passed</summary>' \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/931 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-other-pr: non-green PR should refuse"
  grep -qxF 'pr=https://github.com/example/firstmate/pull/931' "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-receipt-other-pr: PR identity was not re-pointed"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-other-pr: an override authorized for another PR was carried forward"
  assert_grep 'https://github.com/example/firstmate/pull/127' "$case_dir/stderr" \
    "firstmate-review-receipt-other-pr: the discarded authorization did not name the PR it was granted for"
  assert_grep 'https://github.com/example/firstmate/pull/931' "$case_dir/stderr" \
    "firstmate-review-receipt-other-pr: the notice did not name the PR that now needs its own authorization"
  pass "fm-pr-merge drops an override receipt when the task re-points at another PR"
}

# The same authorization, refreshed against the PR it was granted for, must
# survive without the discard notice: the notice reports a real loss, not noise
# on every refresh.
test_firstmate_merge_keeps_a_same_pr_receipt_without_a_discard_notice() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-same-pr-quiet)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_PR_BODY='<summary>✅ **Review** - passed</summary>' \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-same-pr-quiet: non-green PR should refuse"
  assert_grep 'missing_review_override_ts=2026-08-14T23:59:59Z' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-same-pr-quiet: the authorization for this PR was dropped"
  assert_no_grep 'discarding the captain-authorized missing-Review override' "$case_dir/stderr" \
    "firstmate-review-receipt-same-pr-quiet: a surviving authorization was reported as discarded"
  pass "fm-pr-merge keeps a same-PR override receipt and reports no discard"
}

test_firstmate_merge_removes_staged_receipt_when_publish_fails() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-publish-fails)
  add_override_receipt_publish_failure "$case_dir"

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-publish-fails: merge should refuse"
  assert_grep 'could not record the captain-authorized missing-Review override' \
    "$case_dir/stderr" "firstmate-review-override-publish-fails: refusal did not name the receipt failure"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-override-publish-fails: merge ran without a durable override receipt"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-override-publish-fails: failed publish left a false receipt"
  assert_no_staged_merge_meta "$case_dir" \
    "firstmate-review-override-publish-fails: staged metadata was left behind in state/"
  pass "fm-pr-merge removes its staged metadata when the receipt publish fails"
}

# The merge and check scripts both install an EXIT trap that would hide a leak,
# so the library's own promise - it never leaves a staged file behind for a
# caller to sweep up - is only observable with no trap installed at all.
test_meta_rewrite_removes_its_staged_file_without_a_caller_trap() {
  local case_dir rc
  case_dir=$(make_case meta-rewrite-self-cleanup)
  printf '%s\n' 'window=fm-task-x1' 'pr=https://github.com/example/firstmate/pull/127' \
    > "$case_dir/state/task-x1.meta"
  chmod 0600 "$case_dir/state/task-x1.meta"

  set +e
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    refuse_identity() { return 1; }
    fm_pr_meta_rewrite "$2/state/task-x1.meta" "$2/state" .fm-pr-merge-meta \
      pr:missing_review_override_ts refuse_identity \
      "pr=https://github.com/example/firstmate/pull/127"
  ' _ "$ROOT" "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "meta-rewrite-self-cleanup: a refused identity check should fail the rewrite"
  assert_no_staged_merge_meta "$case_dir" \
    "meta-rewrite-self-cleanup: the rewrite left its staged file for a caller trap to sweep up"
  pass "fm_pr_meta_rewrite removes its own staged metadata with no caller trap installed"
}

test_firstmate_merge_removes_staged_receipt_when_interrupted() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-interrupted)
  add_override_receipt_signal_during_staging "$case_dir"

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-interrupted: a signal during staging should refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-override-interrupted: merge ran after the run was interrupted"
  assert_no_staged_merge_meta "$case_dir" \
    "firstmate-review-override-interrupted: interrupted staging left metadata in state/"
  pass "fm-pr-merge removes its staged metadata when interrupted mid-write"
}

# An absent or unresolvable project= is "cannot tell", not "another project":
# a broken meta must not be a silent way past the Review receipt guard.
test_firstmate_merge_guards_unresolvable_project() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-unresolvable-project)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/vanished-project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-unresolvable-project: unresolvable project should refuse"
  assert_grep "could not resolve this task's project as a repository" "$case_dir/stderr" \
    "firstmate-review-unresolvable-project: the unresolvable project was not disclosed"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-unresolvable-project: merge ran without a Review receipt"
  pass "fm-pr-merge guards a task whose project cannot be resolved"
}

test_other_project_merge_skips_the_review_guard() {
  local case_dir
  case_dir=$(make_case other-project-unguarded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "other-project-unguarded: a task in another repository should merge without a Review receipt"
  grep -qxF 'pr merge 31 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "other-project-unguarded: merge did not run for a task outside this repository"
  assert_no_grep "could not resolve this task's project" "$case_dir/stderr" \
    "other-project-unguarded: a resolvable other project was reported as unresolvable"
  pass "fm-pr-merge leaves another repository's merge unguarded"
}

test_firstmate_merge_missing_review_requires_distinct_override() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override)

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override: --allow-red must not authorize a missing Review"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-override: --allow-red bypassed the distinct Review guard"

  : > "$case_dir/gh-axi.log"
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-override: explicit missing-Review override did not permit the merge"
  assert_grep 'captain-authorized override: merging Firstmate PR without a recorded passing no-mistakes Review' \
    "$case_dir/stderr" "firstmate-review-override: override was not disclosed"
  grep -Eq '^missing_review_override_ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-override: durable override receipt was not recorded"
  [ "$(grep -c '^missing_review_override_ts=' "$case_dir/state/task-x1.meta")" -eq 1 ] \
    || fail "firstmate-review-override: durable override receipt was not singular"
  grep -qxF 'pr merge 127 --repo example/firstmate --squash' "$case_dir/gh-axi.log" \
    || fail "firstmate-review-override: override was forwarded or merge did not run"
  pass "fm-pr-merge requires a distinct captain-authorized override for a missing Review"
}

test_firstmate_merge_refuses_when_override_receipt_cannot_be_written() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-write-fails)
  add_override_receipt_write_failure "$case_dir"

  set +e
  FM_FAKE_GH_PR_BODY='' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-write-fails: merge should refuse"
  assert_grep 'could not record the captain-authorized missing-Review override' \
    "$case_dir/stderr" "firstmate-review-override-write-fails: refusal did not name the receipt failure"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "firstmate-review-override-write-fails: merge ran without a durable override receipt"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-override-write-fails: failed write left a false receipt"
  pass "fm-pr-merge fails closed when its override receipt cannot be written"
}

test_records_pr_and_head_before_merging
test_non_green_pr_requires_explicit_override
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_firstmate_merge_refuses_empty_review_body
test_firstmate_merge_refuses_failed_review
test_firstmate_merge_refuses_every_incomplete_review_state
test_firstmate_merge_accepts_passing_review
test_firstmate_merge_accepts_every_completed_review_rendering
test_firstmate_merge_missing_review_requires_distinct_override
test_firstmate_merge_refuses_when_override_receipt_cannot_be_written
test_firstmate_merge_preserves_override_receipt_across_identity_refresh
test_firstmate_merge_drops_override_receipt_when_the_pr_changes
test_firstmate_merge_keeps_a_same_pr_receipt_without_a_discard_notice
test_firstmate_merge_removes_staged_receipt_when_publish_fails
test_meta_rewrite_removes_its_staged_file_without_a_caller_trap
test_firstmate_merge_removes_staged_receipt_when_interrupted
test_firstmate_merge_guards_unresolvable_project
test_other_project_merge_skips_the_review_guard
