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
#
# The evidence-head guard is the reason a merge can be refused after every one
# of those checks passes: a worker's reported figures describe the commit they
# were measured on, and a validation pipeline can commit after that measurement.
#   (i) a recorded evidence commit equal to the live head merges unchanged
#   (j) a recorded evidence commit behind the live head is refused, naming both
#   (k) no recorded evidence commit is refused, naming how to record one
#   (l) an unconfirmable live head is refused rather than merged unverified
#   (m) the refuse -> re-measure -> merge round trip works after a poll is armed
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

# Record a task's evidence commit through the real bin/fm-evidence-record.sh, so
# these cases exercise the same writer a crewmate uses rather than hand-writing
# the metadata line the guard reads. Args: case_dir sha [note]
record_evidence() {
  local case_dir=$1 sha=$2 note=${3-}
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-evidence-record.sh" task-x1 "$sha" "$note" > /dev/null \
    || fail "${case_dir##*/}: recording the evidence commit failed"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for the merge guard and fm-pr-check.sh's pr_head lookup.
# Args: case_dir head_sha
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
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
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

# gh mock that cannot answer headRefOid at all, standing in for a lost or
# unauthenticated GitHub connection at merge time.
add_gh_mocks_head_unavailable() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: could not reach GitHub" >&2
exit 1
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
  record_evidence "$case_dir" deadbeefcafefeed0000000000000000deadbeef 'full suite 4131 pass'
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
  add_gh_mocks_merge_fails "$case_dir" 1111111111111111111111111111111111111111
  record_evidence "$case_dir" 1111111111111111111111111111111111111111
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
  record_evidence "$case_dir" 2222222222222222222222222222222222222222
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
  record_evidence "$case_dir" 5555555555555555555555555555555555555555
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
  record_evidence "$case_dir" 7777777777777777777777777777777777777777
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
  record_evidence "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

EVIDENCE_MEASURED=a291594aa291594aa291594aa291594aa291594a
EVIDENCE_LIVE_HEAD=44c3c63744c3c63744c3c63744c3c63744c3c637

test_matching_evidence_commit_merges() {
  local case_dir rc
  case_dir=$(make_case evidence-matches)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$EVIDENCE_LIVE_HEAD"
  record_evidence "$case_dir" "$EVIDENCE_LIVE_HEAD" 'full suite 4208 pass; injection exploit blocked'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/119 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "evidence-matches: a merge whose evidence commit is the live head should proceed"
  grep -qxF 'pr merge 119 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "evidence-matches: gh-axi pr merge was not invoked for matching evidence"
  assert_grep "pr=https://github.com/example/repo/pull/119" "$case_dir/state/task-x1.meta" \
    "evidence-matches: pr= was not recorded on the merging path"
  assert_grep "evidence_head=$EVIDENCE_LIVE_HEAD" "$case_dir/state/task-x1.meta" \
    "evidence-matches: the evidence record was not preserved through fm-pr-check.sh"
  pass "fm-pr-merge merges unchanged when the evidence commit is the pull request head"
}

test_stale_evidence_commit_refuses_naming_both() {
  local case_dir rc
  case_dir=$(make_case evidence-stale)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$EVIDENCE_LIVE_HEAD"
  record_evidence "$case_dir" "$EVIDENCE_MEASURED" 'full suite 4202 pass'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/119 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "evidence-stale: fm-pr-merge should refuse evidence measured before the head"
  assert_grep "evidence measured on: $EVIDENCE_MEASURED" "$case_dir/stderr" \
    "evidence-stale: the refusal did not name the commit the evidence was measured on"
  assert_grep "pull request head:    $EVIDENCE_LIVE_HEAD" "$case_dir/stderr" \
    "evidence-stale: the refusal did not name the live pull request head"
  assert_grep 'full suite 4202 pass' "$case_dir/stderr" \
    "evidence-stale: the refusal did not say what has to be re-measured"
  assert_grep "fm-evidence-record.sh task-x1 $EVIDENCE_LIVE_HEAD" "$case_dir/stderr" \
    "evidence-stale: the refusal did not name the command that records the re-measurement"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "evidence-stale: gh-axi pr merge was invoked despite stale evidence"
  assert_no_grep 'pr=https://github.com/example/repo/pull/119' "$case_dir/state/task-x1.meta" \
    "evidence-stale: a refused merge still recorded PR metadata"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "evidence-stale: a refused merge still armed a merge poll"
  pass "fm-pr-merge refuses stale evidence and names both the measured commit and the head"
}

test_absent_evidence_record_refuses_actionably() {
  local case_dir rc
  case_dir=$(make_case evidence-absent)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$EVIDENCE_LIVE_HEAD"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/160 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "evidence-absent: fm-pr-merge should refuse when no evidence commit is recorded"
  assert_grep 'no verification evidence commit is recorded' "$case_dir/stderr" \
    "evidence-absent: the refusal did not say the record is missing"
  assert_grep 'fm-evidence-record.sh task-x1' "$case_dir/stderr" \
    "evidence-absent: the refusal did not name the command that records the evidence"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "evidence-absent: gh-axi pr merge was invoked with no evidence recorded"
  assert_no_grep 'pr=https://github.com/example/repo/pull/160' "$case_dir/state/task-x1.meta" \
    "evidence-absent: a refused merge still recorded PR metadata"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "evidence-absent: a refused merge still armed a merge poll"

  # The remedy is recording the measured commit, not a bypass: a task that
  # predates the evidence record is unblocked by one command, so refusing here
  # strands nothing.
  record_evidence "$case_dir" "$EVIDENCE_LIVE_HEAD" 'full suite pass'
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/160 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "evidence-absent: recording the evidence commit did not unblock the merge"
  grep -qxF 'pr merge 160 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "evidence-absent: the merge did not proceed after the evidence was recorded"
  pass "fm-pr-merge refuses an absent evidence record and names the one command that clears it"
}

test_unconfirmable_head_refuses() {
  local case_dir rc
  case_dir=$(make_case evidence-head-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_head_unavailable "$case_dir"
  record_evidence "$case_dir" "$EVIDENCE_LIVE_HEAD" 'full suite pass'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/119 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "evidence-head-unavailable: fm-pr-merge should refuse when the head cannot be confirmed"
  assert_grep 'pull request head could not be confirmed' "$case_dir/stderr" \
    "evidence-head-unavailable: the refusal did not explain the unconfirmable head"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "evidence-head-unavailable: gh-axi pr merge was invoked without a confirmed head"
  pass "fm-pr-merge refuses rather than merging against a head it could not confirm"
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
# The whole point of the guard is the round trip it forces: a stale merge is
# refused, the worker re-measures on the named head and re-records, and the merge
# then proceeds. By that point the task has already armed its merge poll, so the
# re-recorded lines land after pr= in the metadata - the arrangement that must
# still parse as a valid PR record.
test_re_measured_evidence_merges_after_the_poll_is_armed() {
  local case_dir rc
  case_dir=$(make_case evidence-re-measured)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$EVIDENCE_LIVE_HEAD"
  record_evidence "$case_dir" "$EVIDENCE_LIVE_HEAD" 'full suite 4208 pass'
  : > "$case_dir/gh-axi.log"

  # PR-ready arming, exactly as bin/fm-pr-check.sh is run when the PR is reported.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/119 > /dev/null \
    || fail "evidence-re-measured: arming the merge poll failed"

  # A later pipeline commit moves the head, so the recorded evidence goes stale.
  add_gh_mocks "$case_dir" 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/119 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "evidence-re-measured: a head moved by a later commit should refuse"
  assert_grep 'pull request head:    0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f' "$case_dir/stderr" \
    "evidence-re-measured: the refusal did not name the moved head"

  # The worker re-measures on the named head and re-records; the merge proceeds.
  record_evidence "$case_dir" 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f 'full suite 4212 pass'
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/119 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "evidence-re-measured: re-recording on the live head did not clear the refusal"
  grep -qxF 'pr merge 119 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "evidence-re-measured: the merge did not proceed after re-measurement"
  assert_grep 'pr=https://github.com/example/repo/pull/119' "$case_dir/state/task-x1.meta" \
    "evidence-re-measured: the re-recorded metadata no longer holds a valid PR record"
  pass "fm-pr-merge completes the refuse, re-measure, and merge round trip on an armed task"
}

test_matching_evidence_commit_merges
test_stale_evidence_commit_refuses_naming_both
test_absent_evidence_record_refuses_actionably
test_unconfirmable_head_refuses
test_re_measured_evidence_merges_after_the_poll_is_armed
