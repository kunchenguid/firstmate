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
#   (d) a PR with no task meta is merged, stating what it cannot record
#   (d2) the recorded path keeps pr=, pr_head=, and the armed poll intact
#   (d3) both paths issue the identical gh-axi merge command
#   (d4) a symlink occupying the meta path is still refused as tampering
#   (d5) a failing fm-pr-check.sh still aborts the merge for a recorded task
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
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

# An orphan PR - real, green, raised in a session whose runtime record is gone -
# has no meta and no worktree. Refusing it here only pushes the caller to run
# gh-axi directly and around this path, so it is served, and every guarantee it
# does not carry is named in the output rather than dropped silently.
test_unrecorded_pr_merges_and_states_lost_verification() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/unrecorded-pr"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" orphan-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unrecorded-pr: fm-pr-merge should serve a PR with no task record"
  grep -qxF 'pr merge 21 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "unrecorded-pr: gh-axi pr merge was not invoked for the unrecorded PR"

  # The caller must be able to see exactly which post-merge verification is gone.
  assert_grep 'notice: no runtime record at state/orphan-x1.meta' "$case_dir/stderr" \
    "unrecorded-pr: output did not say the task has no runtime record"
  assert_grep 'not recorded: pr=https://github.com/example/repo/pull/21' "$case_dir/stderr" \
    "unrecorded-pr: output did not say pr= goes unrecorded"
  assert_grep 'fm-teardown.sh has no PR reference to verify landed work' "$case_dir/stderr" \
    "unrecorded-pr: output did not name the landed-work verification it cannot perform"
  assert_grep 'not recorded: pr_head=' "$case_dir/stderr" \
    "unrecorded-pr: output did not say pr_head= goes unrecorded"
  assert_grep 'not armed: the merge poll' "$case_dir/stderr" \
    "unrecorded-pr: output did not say no merge poll is armed"

  # Serving the PR must not fabricate a task record or arm a watch for a task
  # that does not exist.
  assert_absent "$case_dir/state/orphan-x1.meta" \
    "unrecorded-pr: a task record was invented for a PR with no task"
  assert_absent "$case_dir/state/orphan-x1.check.sh" \
    "unrecorded-pr: a merge poll was armed for a task with no runtime record"
  pass "fm-pr-merge merges a PR with no task record and states what it cannot verify"
}

# Criterion for the untouched path: when meta IS present, every guarantee the
# recorded path carried before must still be there, and the reduced-guarantee
# notice must not appear.
test_recorded_pr_keeps_every_guarantee() {
  local case_dir rc
  case_dir=$(make_case recorded-guarantees)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "recorded-guarantees: fm-pr-merge should succeed"
  # fm-teardown.sh reads the PR reference back as `pr=<url>` on its own line.
  assert_line_in_file 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "recorded-guarantees: pr= is no longer recorded for teardown to verify landed work against"
  assert_line_in_file 'pr_head=abcabcabcabcabcabcabcabcabcabcabcabcabca' "$case_dir/state/task-x1.meta" \
    "recorded-guarantees: pr_head= is no longer recorded"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "recorded-guarantees: the merge poll is no longer armed"
  assert_no_grep 'notice: no runtime record' "$case_dir/stderr" \
    "recorded-guarantees: a task WITH a runtime record took the unrecorded path"
  assert_no_grep 'not recorded' "$case_dir/stderr" \
    "recorded-guarantees: a reduced guarantee was reported for a fully recorded task"
  pass "fm-pr-merge keeps pr=, pr_head=, and the armed poll when task meta is present"
}

# The red-PR bar lives in gh-axi and the forge, so serving an unrecorded PR must
# not change one byte of the merge command - no --admin, no bypass flag, no
# different method.
test_unrecorded_pr_merge_command_is_identical_to_recorded() {
  local recorded_dir unrecorded_dir
  recorded_dir=$(make_case identical-recorded)
  mkdir -p "$recorded_dir/wt"
  add_gh_mocks "$recorded_dir" 1010101010101010101010101010101010101010
  : > "$recorded_dir/gh-axi.log"

  unrecorded_dir="$TMP_ROOT/identical-unrecorded"
  mkdir -p "$unrecorded_dir/state" "$unrecorded_dir/fakebin"
  add_gh_mocks "$unrecorded_dir" 1010101010101010101010101010101010101010
  : > "$unrecorded_dir/gh-axi.log"

  run_pr_merge "$recorded_dir" task-x1 https://github.com/example/repo/pull/42 -- --delete-branch \
    > "$recorded_dir/stdout" 2> "$recorded_dir/stderr" \
    || fail "identical-command: recorded merge failed"
  run_pr_merge "$unrecorded_dir" orphan-x1 https://github.com/example/repo/pull/42 -- --delete-branch \
    > "$unrecorded_dir/stdout" 2> "$unrecorded_dir/stderr" \
    || fail "identical-command: unrecorded merge failed"

  # The recorded run's log also carries fm-pr-check.sh's own gh-axi calls, so
  # compare the merge invocations rather than the whole logs.
  grep '^pr merge ' "$recorded_dir/gh-axi.log" > "$recorded_dir/merge-calls"
  grep '^pr merge ' "$unrecorded_dir/gh-axi.log" > "$unrecorded_dir/merge-calls"
  [ -s "$recorded_dir/merge-calls" ] || fail "identical-command: recorded run issued no merge"
  cmp -s "$recorded_dir/merge-calls" "$unrecorded_dir/merge-calls" \
    || fail "identical-command: the unrecorded path changed the gh-axi merge command: $(cat "$unrecorded_dir/merge-calls")"
  assert_no_grep 'admin' "$unrecorded_dir/merge-calls" \
    "identical-command: the unrecorded path added a protection-bypass flag"
  pass "fm-pr-merge issues the same gh-axi merge command with and without a task record"
}

# The recorded path merges only after fm-pr-check.sh succeeds. A hardlinked meta
# is one thing fm-pr-check.sh refuses, and that refusal must still stop the merge
# rather than fall through to the unrecorded path.
test_pr_check_failure_aborts_the_merge() {
  local case_dir rc
  case_dir=$(make_case check-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"
  ln "$case_dir/state/task-x1.meta" "$case_dir/state/task-x1.meta.hardlink"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "check-fails: fm-pr-merge should abort when fm-pr-check.sh refuses"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "check-fails: the refusal from fm-pr-check.sh was not surfaced"
  assert_no_grep 'notice: no runtime record' "$case_dir/stderr" \
    "check-fails: a refused recording fell through to the unrecorded path"
  # fm-pr-check.sh's own non-zero exit is what stops the merge. The later
  # `pr=` grep is a second line of defence, not the one that must fire: a
  # future partial write could satisfy it while the recording still failed.
  assert_no_grep 'PR metadata recording failed' "$case_dir/stderr" \
    "check-fails: the merge continued past fm-pr-check.sh's refusal and only the pr= grep stopped it"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "check-fails: gh-axi pr merge ran despite a refused recording"
  pass "fm-pr-merge aborts the merge when fm-pr-check.sh refuses a recorded task"
}

# An absent record is an orphan PR; a symlink sitting on the metadata path is a
# tampering signal, and keeps the original refusal.
test_symlinked_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/symlinked-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"
  fm_write_meta "$case_dir/elsewhere.meta" "window=fm-task-x1" "kind=ship"
  ln -s "$case_dir/elsewhere.meta" "$case_dir/state/linked-x1.meta"

  set +e
  run_pr_merge "$case_dir" linked-x1 https://github.com/example/repo/pull/23 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "symlinked-meta: fm-pr-merge should refuse a symlinked task record"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "symlinked-meta: refusal did not explain the unusable meta"
  assert_no_grep 'notice: no runtime record' "$case_dir/stderr" \
    "symlinked-meta: tampering was treated as an absent record"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "symlinked-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/linked-x1.check.sh" \
    "symlinked-meta: a poll was armed through a symlinked meta"
  pass "fm-pr-merge still refuses when a symlink occupies the task metadata path"
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

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_unrecorded_pr_merges_and_states_lost_verification
test_recorded_pr_keeps_every_guarantee
test_unrecorded_pr_merge_command_is_identical_to_recorded
test_symlinked_meta_refuses_before_merge
test_pr_check_failure_aborts_the_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
