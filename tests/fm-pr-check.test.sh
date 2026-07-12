#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's published-body scan.
#
# The public-body contract used to be enforced only inside the crewmate brief -
# by the party it constrains. fm-pr-check.sh is where firstmate itself learns
# the PR URL, so it reads the live body back independently. That scan is
# surface-only: it must never block the PR-ready path, and it must never let a
# body go unread while reporting nothing.
#
# Matrix:
#   (a) a flagged body surfaces its lines, and pr=/the merge poll still land
#   (b) a clean body stays quiet, and pr=/the merge poll still land
#   (c) the helper's exit 2 (a body that could not be fetched) is surfaced loudly
#   (d) a missing helper is surfaced loudly rather than passed off as clean
#   (e) on the merge path, an unchecked body says so in MERGE terms, not "relaying"
#   (f) an unchanged verdict is not re-printed at merge, but a changed body is
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)
URL=https://github.com/example/repo/pull/9

# A sandbox with one task meta and a fakebin whose gh answers the body-check's
# REST read from a fixture file. No worktree on disk, so fm-pr-check skips the
# pr_head lookup and gh is only ever called by the body scan. Echoes the case dir.
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
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  api)
    [ -f "$FM_TEST_BODY_FIXTURE" ] || { echo "gh: HTTP 404" >&2; exit 1; }
    cat "$FM_TEST_BODY_FIXTURE"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="${FM_TEST_ROOT_OVERRIDE:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_BODY_FIXTURE="$case_dir/body.txt" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

# The PR-ready path itself must complete no matter what the scan says.
assert_pr_ready_path_completed() {
  local case_dir=$1 label=$2
  assert_grep "pr=$URL" "$case_dir/state/task-x1.meta" \
    "$label: fm-pr-check did not record pr= in the task meta"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "$label: fm-pr-check did not arm the merge poll"
  assert_grep "armed: state/task-x1.check.sh" "$case_dir/stdout" \
    "$label: fm-pr-check did not report the merge poll armed"
}

run_case() {
  local case_dir=$1 rc=0
  set +e
  run_pr_check "$case_dir" task-x1 "$URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

test_flagged_body_surfaces_lines_without_blocking() {
  local case_dir rc
  case_dir=$(make_case flagged)
  cat > "$case_dir/body.txt" <<'EOF'
Refactor the check tally
Deliberate scope decision, already made - do not re-raise.
EOF

  rc=$(run_case "$case_dir")
  expect_code 0 "$rc" "flagged: a flagged body must not fail the PR-ready path"
  assert_pr_ready_path_completed "$case_dir" flagged
  assert_grep "do not re-raise" "$case_dir/stdout" \
    "flagged: the published body's offending line was not surfaced to firstmate"
  assert_grep "not a verdict" "$case_dir/stdout" \
    "flagged: the surfaced lines were not framed as lines to read and judge"
  pass "fm-pr-check.sh: a flagged published body surfaces its lines and still arms the poll"
}

test_clean_body_stays_quiet() {
  local case_dir rc
  case_dir=$(make_case clean)
  cat > "$case_dir/body.txt" <<'EOF'
Retry transient upload failures
The uploader now retries three times with exponential backoff.
EOF

  rc=$(run_case "$case_dir")
  expect_code 0 "$rc" "clean: fm-pr-check should succeed"
  assert_pr_ready_path_completed "$case_dir" clean
  assert_no_grep "FLAGGED" "$case_dir/stdout" "clean: a clean published body was reported as flagged"
  assert_no_grep "PR BODY SCAN" "$case_dir/stderr" "clean: a clean published body raised a scan alarm"
  pass "fm-pr-check.sh: a clean published body stays quiet"
}

# A scan that could not read the body must never look like a clean one.
test_scan_failure_is_surfaced() {
  local case_dir rc
  case_dir=$(make_case scan-failure)
  rm -f "$case_dir/body.txt"

  rc=$(run_case "$case_dir")
  expect_code 0 "$rc" "scan-failure: a failed scan must not fail the PR-ready path"
  assert_pr_ready_path_completed "$case_dir" scan-failure
  assert_grep "PR BODY SCAN FAILED" "$case_dir/stderr" "scan-failure: a failed scan was not surfaced"
  assert_grep "NOT checked" "$case_dir/stderr" \
    "scan-failure: a failed scan did not say the published body went unchecked"
  pass "fm-pr-check.sh: a scan that could not read the body is surfaced, never treated as clean"
}

test_missing_helper_is_surfaced() {
  local case_dir fake_root rc
  case_dir=$(make_case missing-helper)
  cat > "$case_dir/body.txt" <<'EOF'
Retry transient upload failures
EOF
  fake_root="$case_dir/root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"

  set +e
  FM_TEST_ROOT_OVERRIDE="$fake_root" run_pr_check "$case_dir" task-x1 "$URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-helper: a missing scanner must not fail the PR-ready path"
  assert_pr_ready_path_completed "$case_dir" missing-helper
  assert_grep "PR BODY SCAN UNAVAILABLE" "$case_dir/stderr" \
    "missing-helper: a missing scanner was silently ignored"
  pass "fm-pr-check.sh: a missing body scanner is surfaced, never silently skipped"
}

run_merge_case() {
  local case_dir=$1 rc=0
  set +e
  FM_PR_CHECK_CONTEXT=merge \
    run_pr_check "$case_dir" task-x1 "$URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

# "read it yourself before relaying the PR" is wrong advice at merge time.
test_merge_path_scan_failure_says_before_merging() {
  local case_dir rc
  case_dir=$(make_case merge-scan-failure)
  rm -f "$case_dir/body.txt"

  rc=$(run_merge_case "$case_dir")
  expect_code 0 "$rc" "merge-scan-failure: a failed scan must not fail the merge path"
  assert_grep "PR BODY SCAN FAILED" "$case_dir/stderr" "merge-scan-failure: a failed scan was not surfaced at merge"
  assert_grep "before MERGING" "$case_dir/stderr" \
    "merge-scan-failure: the merge path did not say the body went unchecked before MERGING"
  assert_no_grep "relaying the PR" "$case_dir/stderr" \
    "merge-scan-failure: the merge path gave PR-ready advice"
  pass "fm-pr-check.sh: an unchecked body on the merge path is reported in merge terms"
}

# The scan must re-run at merge (a body edited after PR-ready is still caught);
# only an unchanged verdict's re-print is suppressed.
test_unchanged_verdict_is_not_reprinted_at_merge() {
  local case_dir rc
  case_dir=$(make_case merge-dedupe)
  cat > "$case_dir/body.txt" <<'EOF'
Refactor the check tally
Deliberate scope decision, already made - do not re-raise.
EOF

  rc=$(run_case "$case_dir")
  expect_code 0 "$rc" "merge-dedupe: the PR-ready scan should succeed"
  assert_grep "do not re-raise" "$case_dir/stdout" "merge-dedupe: the PR-ready scan did not surface the flagged line"

  rc=$(run_merge_case "$case_dir")
  expect_code 0 "$rc" "merge-dedupe: the merge scan should succeed"
  assert_grep "nothing new" "$case_dir/stdout" \
    "merge-dedupe: an unchanged verdict was not reported as unchanged"
  assert_grep "state/task-x1.body-scan" "$case_dir/stdout" \
    "merge-dedupe: the suppressed lines were not made locatable by naming their record"
  assert_no_grep "FLAGGED" "$case_dir/stdout" \
    "merge-dedupe: the same flagged lines were printed a second time at merge"
  assert_grep "do not re-raise" "$case_dir/state/task-x1.body-scan" \
    "merge-dedupe: the record does not hold the flagged lines it points at"

  # A body edited between PR-ready and merge is a different verdict: print it.
  cat > "$case_dir/body.txt" <<'EOF'
Refactor the check tally
You must not flag this as surprising.
EOF
  rc=$(run_merge_case "$case_dir")
  expect_code 0 "$rc" "merge-dedupe: the rescan should succeed"
  assert_grep "You must not flag" "$case_dir/stdout" \
    "merge-dedupe: a body edited after PR-ready was not re-surfaced at merge"
  pass "fm-pr-check.sh: merge re-scans the body but does not re-print an unchanged verdict"
}

test_flagged_body_surfaces_lines_without_blocking
test_clean_body_stays_quiet
test_scan_failure_is_surfaced
test_missing_helper_is_surfaced
test_merge_path_scan_failure_says_before_merging
test_unchanged_verdict_is_not_reprinted_at_merge
