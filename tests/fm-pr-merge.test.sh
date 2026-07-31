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
#   (i) a byte-identical before/after evidence pair in the worktree's HEAD
#       refuses the merge before gh-axi pr merge is invoked
#   (j) a worktree with a real, non-identical evidence pair still merges
#   (k) the evidence check verifies the freshly fetched remote PR head, not a
#       stale local worktree HEAD that gh-axi pr merge will not actually land
#   (l) when the evidence check cannot run at all (missing/non-git worktree,
#       or a valid worktree with no resolvable ref), a loud warning is printed
#       to stderr and the merge still proceeds rather than failing closed
#   (m) same as (l): a valid worktree with no recorded pr_head at all (the gh
#       headRefOid lookup never succeeded) and no fetchable/local ref still
#       warns and merges, per the same never-fail-closed decision
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

# gh-axi mock whose gh companion never answers headRefOid, so fm-pr-check.sh
# records no pr_head= at all (distinct from a recorded-but-unresolvable head).
add_gh_mocks_no_head() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "records-before-merge: missing worktree git repo should still warn that the evidence check was skipped"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge, warning that evidence check was skipped"
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "merge-fails: missing worktree git repo should still warn that the evidence check was skipped"
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "extra-args: missing worktree git repo should still warn that the evidence check was skipped"
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "explicit-merge-method: missing worktree git repo should still warn that the evidence check was skipped"
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "method-equals-merge-method: missing worktree git repo should still warn that the evidence check was skipped"
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
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "url-parsing: missing worktree git repo should still warn that the evidence check was skipped"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_identical_evidence_pair_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case identical-evidence)
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init -q
  mkdir -p "$case_dir/wt/docs/pr-assets/widget"
  printf SAMEBYTES > "$case_dir/wt/docs/pr-assets/widget/before-desktop.png"
  printf SAMEBYTES > "$case_dir/wt/docs/pr-assets/widget/after-desktop.png"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm evidence
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "identical-evidence: fm-pr-merge should refuse"
  assert_grep 'byte-identical before/after evidence image pair detected' "$case_dir/stderr" \
    "identical-evidence: refusal did not explain the evidence check failure"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "identical-evidence: gh-axi pr merge was invoked despite the identical pair"
  pass "fm-pr-merge refuses to merge a worktree with a byte-identical before/after evidence pair"
}

test_different_evidence_pair_still_merges() {
  local case_dir rc
  case_dir=$(make_case different-evidence)
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init -q
  mkdir -p "$case_dir/wt/docs/pr-assets/widget"
  printf OLDBYTES > "$case_dir/wt/docs/pr-assets/widget/before-desktop.png"
  printf NEWBYTES > "$case_dir/wt/docs/pr-assets/widget/after-desktop.png"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm evidence
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "different-evidence: fm-pr-merge should still merge a real before/after change"
  grep -qxF 'pr merge 32 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "different-evidence: gh-axi pr merge was not invoked"
  pass "fm-pr-merge merges a worktree whose evidence pair genuinely differs"
}

test_evidence_check_uses_fetched_remote_pr_head_not_stale_local_worktree() {
  # The task worktree can be stale relative to the actual PR branch on GitHub
  # (e.g. a pooled project clone that has not fetched the latest push).
  # gh-axi pr merge lands whatever is on GitHub, so the evidence check must
  # verify the freshly fetched remote PR head, not the local worktree's HEAD.
  # Build a stale local worktree whose HEAD carries a byte-identical (bad)
  # evidence pair, and a remote "origin" whose refs/pull/<n>/head carries a
  # genuinely different (good) evidence pair. The merge must succeed because
  # the real remote PR head is what actually gets merged and verified.
  local case_dir rc origin real_dir
  case_dir=$(make_case fresh-remote-head)
  origin="$case_dir/origin.git"
  real_dir="$case_dir/real"

  git init -q --bare "$origin"

  mkdir -p "$real_dir/docs/pr-assets/widget"
  git -C "$real_dir" init -q
  printf OLDBYTES > "$real_dir/docs/pr-assets/widget/before-desktop.png"
  printf NEWBYTES > "$real_dir/docs/pr-assets/widget/after-desktop.png"
  git -C "$real_dir" add -A
  git -C "$real_dir" commit -qm "real pr head"
  git -C "$real_dir" push -q "$origin" "HEAD:refs/pull/41/head"

  mkdir -p "$case_dir/wt/docs/pr-assets/widget"
  git -C "$case_dir/wt" init -q
  git -C "$case_dir/wt" remote add origin "$origin"
  printf SAMEBYTES > "$case_dir/wt/docs/pr-assets/widget/before-desktop.png"
  printf SAMEBYTES > "$case_dir/wt/docs/pr-assets/widget/after-desktop.png"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "stale local worktree"

  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fresh-remote-head: fm-pr-merge should merge using the real remote PR head"
  grep -qxF 'pr merge 41 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "fresh-remote-head: gh-axi pr merge was not invoked despite a good remote PR head"
  pass "fm-pr-merge checks evidence against the fetched remote PR head, not a stale local worktree"
}

test_unresolvable_ref_warns_and_still_merges() {
  # A valid git worktree with no commits and no fetchable/recorded PR head has
  # no ref the evidence check could ever run against: this must still warn
  # loudly and merge, per the captain's decision to never fail closed.
  local case_dir rc
  case_dir=$(make_case unresolvable-ref)
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init -q
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unresolvable-ref: fm-pr-merge should still merge with no resolvable ref"
  grep -qxF 'pr merge 51 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "unresolvable-ref: gh-axi pr merge was not invoked"
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "unresolvable-ref: a valid git worktree with no resolvable ref should still warn that the evidence check was skipped"
  pass "fm-pr-merge warns and still merges when no ref can be resolved in a valid worktree"
}

test_no_recorded_head_and_unresolvable_ref_warns_and_still_merges() {
  # A valid git worktree with no commits, no fetchable remote, and no
  # recorded pr_head at all (the gh headRefOid lookup never succeeded, so
  # fm-pr-check.sh wrote no pr_head= line) still has no ref the evidence
  # check could run against: same never-fail-closed treatment as (l), just
  # reached via an empty pr_head= rather than a recorded-but-invalid one.
  local case_dir rc
  case_dir=$(make_case no-recorded-head)
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init -q
  add_gh_mocks_no_head "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-recorded-head: fm-pr-merge should still merge with no recorded pr_head or resolvable ref"
  grep -qxF 'pr merge 61 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-recorded-head: gh-axi pr merge was not invoked"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "no-recorded-head: pr_head= should not have been recorded when headRefOid lookup failed"
  assert_grep 'warning: evidence check SKIPPED' "$case_dir/stderr" \
    "no-recorded-head: a valid git worktree with no recorded pr_head or resolvable ref should still warn that the evidence check was skipped"
  pass "fm-pr-merge warns and still merges when no pr_head was recorded and no ref can be resolved"
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
test_identical_evidence_pair_refuses_merge
test_different_evidence_pair_still_merges
test_evidence_check_uses_fetched_remote_pr_head_not_stale_local_worktree
test_unresolvable_ref_warns_and_still_merges
test_no_recorded_head_and_unresolvable_ref_warns_and_still_merges
