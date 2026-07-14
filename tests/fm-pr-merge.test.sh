#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh and bin/fm-pr-check.sh's stacked-on-base guard.
#
# fm-pr-merge.sh is the one path firstmate uses to merge a task's PR, which must
# always record pr= and any available pr_head= into the task's meta before
# merging so fm-teardown.sh's landed-check has a PR reference to verify against,
# even on repos with no PR CI where the usual "checks green" fm-pr-check.sh
# trigger never fires.
#
# fm-pr-check.sh additionally, when a non-default base= was declared for the task
# (fm-spawn.sh --base), asserts the PR head is ROOTED IN THAT BASE'S UNMERGED
# HISTORY before recording pr= or arming the merge poll - catching a feature-branch
# fix that the pipeline rebased onto the repo default (data/learnings.md
# 2026-07-07). It deliberately does NOT require the head to descend from the base's
# current tip, so a base that merely advanced after the head was stacked still
# merges.
#
# Matrix (fm-pr-merge.sh):
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# WHETHER THE BASE BRANCH STILL EXISTS DECIDES NOTHING - it is an unsound proxy in both
# directions: a base can be deleted WITHOUT merging (an abandoned feature - its unmerged
# commits ride on the head, the original incident), and a base can merge and NOT be
# deleted (GitHub's delete-on-merge is off by default - guarding that would refuse a safe
# merge forever). Existence only chooses WHICH TIP the checks reason from: the live tip
# while the branch is there, the recorded spawn-time tip (base_sha=) once it is gone.
#
# WHAT DECIDES IS TWO INDEPENDENT QUESTIONS, ASKED IN THIS ORDER. WHERE IS THE HEAD
# ROOTED (fm_base_head_rooted) - in the default branch, or in the base's own commits?
# And HAS THE BASE'S WORK LANDED (fm_base_work_landed), which says what the first answer
# MEANS. Landedness alone is not a licence to stand down: it speaks for the default
# branch's CONTENT, and a squash merge leaves the base's COMMITS out of the default
# branch, so a head still rooted in that base still carries them (see the
# stacked-on-a-squash-merged-base cases below, which refuse).
#
# Matrix (fm-pr-check.sh based-on-base guard). Base UNLANDED - the live feature branch
# the guard exists for:
#   (i) base present, head stacked on it AND base label matches -> records pr=, arms the poll
#   (j) base present, base ADVANCED after the head was stacked -> still allowed (merely behind, not wrong-based)
#   (k) base present, PR head rebased onto main -> refuses, no pr=, no poll
#   (l) base present, head stacked but PR base label targets main -> refuses, no pr=, no poll
#   (m) base present, head rebased onto main but the PR ALREADY targets the base ->
#       still refuses, and prescribes the head's re-rebase rather than a retarget that
#       has already happened and would loop
#   (n) base GONE, recorded tip's work is NOT in main (deleted WITHOUT merging) ->
#       refuses: this is the original incident, and standing down would land the abandoned
#       base's commits on main
#
# Base LANDED and the head sits on the DEFAULT BRANCH - the base merged and the head
# carries none of its commits, so there is nothing left to drag anywhere and the guard
# must stand down rather than deadlock a legitimate merge. Standing down is not skipping
# the check: it re-checks the PR as the ordinary default-branch PR it now is, so the base
# label must be the DEFAULT branch:
#   (o) base still PRESENT on origin, squash-merged into main, head rebased onto main ->
#       stands down; enforcing rootedness against the base here would refuse forever,
#       with a recovery (retarget onto the base) that is a no-op
#   (p) base still PRESENT on origin, ancestor-merged into main, PR label is main ->
#       stands down; the label check against the BASE alone would refuse forever
#   (q) base GONE, recorded tip is an ANCESTOR of main (it merged and was auto-deleted)
#       -> stands down loudly and the PR proceeds
#   (r) base GONE, recorded tip's work is CONTAINED in main (squash-merged, firstmate's
#       own default) -> stands down too; an ancestor-only test would deadlock here
#   (s) base merged but NOT deleted, and the PR still targets THAT base -> refuses:
#       merging would merge into an already-merged branch, so the fix would never reach
#       main while the PR would still read MERGED and teardown would release the work
#
# Base LANDED but the head is STILL ROOTED IN IT - the case landedness alone cannot see.
# A squash merge puts the base's content in main without its commits, so this head still
# carries every one of them and merging would land them again:
#   (s2) base squash-merged, branch KEPT, head still stacked on it -> refuses, and
#        prescribes the head's REBASE onto main; a retarget alone leaves those commits
#        on the head
#   (s3) the same, with the branch DELETED too -> refuses identically; absence changes
#        only which tip the checks reason from, never the verdict
#
# Landedness INDETERMINATE or unaskable -> REFUSE. Passing is the guard's only relaxation
# and it takes proof; a head "stacked on" a base whose landedness was never settled is not
# a verified head, however present that base's branch is. If that base has in fact merged,
# merging its child into it lands the fix on a dead branch and never on main, while
# fm-teardown.sh reads a MERGED PR and releases the work - the very harm the stand-down
# refuses by name in the case it CAN see.
#   (t) base PRESENT, replaying it onto main conflicts and no squash or rebase merge of it
#       is in main, so landedness cannot be settled, head stacked -> REFUSES. The refusal
#       names both hazards and both recoveries: that base does not merge cleanly into main
#       as it stands, so its OWN PR is blocked on the same conflict. A merged base whose
#       lines main then edited conflicts the same way, which is why the patch proofs in
#       bin/fm-base-lib.sh exist - they keep THAT base LANDED rather than unsettleable
#   (u) base GONE and no base_sha= recorded -> refuses; merged and abandoned cannot be
#       told apart without it, and no rootedness check is left to fall back on
#   (v) base GONE and the recorded tip is not in the local object store -> refuses,
#       naming the reason rather than assuming
#   (w) base present but origin cannot be asked at all (auth, network) -> fail-closed refusal
#   (x) no base= (the common case) -> unchanged: records pr= and arms the poll
#
# There is no sidecar case to cover: state/<id>.meta is the single source of truth for a
# task's base, written by fm-spawn.sh --base, so there is no second record that could
# hold a base meta does not - and retiring a declaration is one edit to one file.
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
# fm-pr-check.sh's field lookup. fm-pr-check resolves the base label and the head
# sha in ONE `gh pr view --json baseRefName,headRefOid -q '... | @tsv'` call, so
# the mock must answer that combined query as real TSV: a bare undelimited sha
# here would only pass by exploiting a non-strict split, and would stop
# exercising the contract fm-pr-check actually depends on.
# Args: case_dir head_sha [base_label]
add_gh_mocks() {
  local case_dir=$1 head=$2 base=${3:-main}
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
      *baseRefName*headRefOid*|*headRefOid*baseRefName*)
        printf '%s\t%s\n' '$base' '$head' ; exit 0 ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *baseRefName*) printf '%s\n' '$base' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock returning a SINGLE undelimited field where fm-pr-check asked for two.
# `cut` without -s would echo that whole line for BOTH field requests, silently
# landing the same string in the base label and the head sha - and a bogus
# pr_head= (read downstream as a commit sha by fm-review-diff.sh and
# fm-teardown.sh) would be recorded from it. The split must be delimiter-strict.
add_gh_mock_malformed_fields() {
  local case_dir=$1 blob=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' '$blob' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
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
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
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

# A gh response carrying one undelimited field where two were asked for is
# malformed, and must NOT be smeared across both variables: recording the base
# label as pr_head= would put a branch name where fm-review-diff.sh and
# fm-teardown.sh expect a commit sha. The pr= recording still happens (that path
# never depended on gh); only the unresolvable pr_head= is withheld, loudly.
test_malformed_gh_fields_record_no_pr_head() {
  local case_dir rc
  case_dir=$(make_case malformed-fields)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1234567812345678123456781234567812345678
  add_gh_mock_malformed_fields "$case_dir" onlyonefield
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "malformed-fields: an unresolvable pr_head must not break the merge path"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "malformed-fields: pr= should still be recorded"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "malformed-fields: a bogus pr_head= was recorded from a response with no tab delimiter"
  assert_grep 'malformed' "$case_dir/stderr" \
    "malformed-fields: the malformed gh response was swallowed instead of reported"
  pass "fm-pr-check refuses to smear a malformed gh response across base label and pr_head="
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
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
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
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
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

# --- fm-pr-check.sh stacked-on-base guard ------------------------------------

PR_CHECK="$ROOT/bin/fm-pr-check.sh"

# Build a real git fixture: an origin with main, a feature/base branch stacked on
# main, and a PR head (refs/pull/9/head) parented on either feature/base (correctly
# based) or main (rebased onto the repo default - the incident). Echoes the case dir.
# The worktree shares the project clone's origin remote, so fm-pr-check.sh can fetch
# every ref it needs.
#
# advance_base=advance pushes a further commit onto feature/base AFTER the PR head
# was stacked, so the head is correctly based but merely behind - the routine state
# of a stacked PR whose own base is still under review, which must still merge.
make_git_case() {
  local name=$1 pr_parent=$2 base_label=${3:-main} advance_base=${4:-} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  (
    cd "$case_dir/_seed"
    git config user.email t@t
    git config user.name t
    printf 'base\n' > f.txt
    git add f.txt
    git commit -qm main-baseline
    git push -q origin main
    git checkout -q -b feature/base
    printf 'feature\n' >> f.txt
    git add f.txt
    git commit -qm feature-base-1
    git push -q origin feature/base
    if [ "$pr_parent" = feature ]; then
      git checkout -q -b prhead feature/base
    else
      git checkout -q -b prhead main
    fi
    printf 'fix\n' >> f.txt
    git add f.txt
    git commit -qm pr-fix
    git push -q origin prhead:refs/pull/9/head
    if [ "$advance_base" = advance ]; then
      git checkout -q feature/base
      printf 'feature-2\n' >> f.txt
      git add f.txt
      git commit -qm feature-base-2
      git push -q origin feature/base
    fi
  )
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # gh mock so the pr_head recording path runs and the base-label check and the
  # wrong-base diagnostic get a baseRefName; the based-on-base assertion itself uses
  # fetched refs, not gh. fm-pr-check resolves both fields in ONE gh call, so the
  # mock answers the combined query as TSV. The label is per-case configurable.
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *baseRefName*headRefOid*|*headRefOid*baseRefName*)
    printf '%s\t%s\n' '$base_label' 1111111111111111111111111111111111111111 ;;
  *headRefOid*) printf '%s\n' 1111111111111111111111111111111111111111 ;;
  *baseRefName*) printf '%s\n' '$base_label' ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Squash-merge feature/base into main on origin - firstmate's own default merge method, and
# GitHub's most common setting. The base's CONTENT reaches main; its COMMITS do not.
squash_merge_base_into_main() {  # <case-dir>
  local case_dir=$1 tree parent squash
  tree=$(git -C "$case_dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$squash"
}

# Move origin's main on by a commit that rewrites the very lines the base changed, so a
# 3-way replay of the base onto main can no longer resolve. Both a LIVE base drifting from
# main and a MERGED base whose lines main has since edited look like this, which is exactly
# why the replay alone cannot settle landedness - and why one of them is refused and the
# other is proved merged by patch id.
advance_main_conflicting() {
  local case_dir=$1 blob parent tree commit
  blob=$(printf 'base\nmain-conflict\n' | git -C "$case_dir/origin.git" hash-object -w --stdin)
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  tree=$(printf '100644 blob %s\tf.txt\n' "$blob" | git -C "$case_dir/origin.git" mktree)
  commit=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'conflicting work on main')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$commit"
}

# Move origin's main on by one unrelated commit, so a containment check is pinned to
# "the base's work is in main" rather than the accident of main still equalling the
# squash commit's tree.
advance_main() {
  local case_dir=$1 tree parent blob commit
  blob=$(printf 'later\n' | git -C "$case_dir/origin.git" hash-object -w --stdin)
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  tree=$(
    {
      git -C "$case_dir/origin.git" ls-tree "$parent"
      printf '100644 blob %s\tlater.txt\n' "$blob"
    } | git -C "$case_dir/origin.git" mktree
  )
  commit=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'unrelated work on main')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$commit"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_pr_check_accepts_stacked_base() {
  local case_dir rc
  case_dir=$(make_git_case stacked feature feature/base)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stacked-base: fm-pr-check should accept a PR head stacked on its base"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "stacked-base: pr= should be recorded for a correctly stacked PR"
  assert_present "$case_dir/state/task-x1.check.sh" "stacked-base: the merge poll should be armed"
  assert_no_grep 'not stacked on its intended base' "$case_dir/stderr" \
    "stacked-base: a stacked PR must not trip the guard"
  pass "fm-pr-check accepts a PR head stacked on the declared base"
}

# A base whose landedness CANNOT BE SETTLED is not a live base, and "stacked on it" is not
# a verified head. The guard has no way to see the one thing it would need to: if that base
# has in fact already squash-merged, this PR targets a dead branch, and merging it would
# land the fix on that branch and never on main - while the PR reads MERGED and teardown
# releases the work. Passing here would be a fail-open, so it refuses and says why, naming
# the recovery for both of the things that might be true.
test_pr_check_refuses_a_base_whose_landedness_cannot_be_settled() {
  local case_dir rc
  case_dir=$(make_git_case conflictingbase feature feature/base)
  advance_main_conflicting "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsettleable-base: a landedness that could not be settled must refuse, never pass a PR the guard did not verify"
  assert_grep 'could not be determined' "$case_dir/stderr" \
    "unsettleable-base: the refusal does not name the question that went unanswered"
  assert_grep "does not merge cleanly into 'main'" "$case_dir/stderr" \
    "unsettleable-base: the refusal does not tell the operator that the base's own PR is blocked on the same conflict, which is the state that has to change"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "unsettleable-base: an unverified PR must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsettleable-base: an unverified PR must not arm the merge poll"
  assert_no_grep 'stands down' "$case_dir/stderr" \
    "unsettleable-base: an unprovable landedness must never relax the guard"
  pass "fm-pr-check refuses when the base's landedness cannot be settled, instead of passing an unverified PR"
}

# The mirror case, and the reason the refusal above is honest rather than merely strict: a
# base that DID merge conflicts with main in exactly the same way once main edits its lines,
# and it must still read LANDED. Its child PR - rebased onto main by the pipeline - is an
# ordinary default-branch PR now, and refusing it would deadlock a merge whose hazard is
# long gone.
test_pr_check_stands_down_for_a_merged_base_that_now_conflicts() {
  local case_dir rc
  case_dir=$(make_git_case mergedconflicting main main)
  squash_merge_base_into_main "$case_dir"
  advance_main_conflicting "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-conflicting-base: a base that demonstrably merged must stand the guard down even when replaying it onto main no longer resolves"
  assert_grep 'stands down' "$case_dir/stderr" \
    "merged-conflicting-base: the stand-down was not announced"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "merged-conflicting-base: the ordinary default-branch PR of a merged base should record pr="
  assert_present "$case_dir/state/task-x1.check.sh" \
    "merged-conflicting-base: the merge poll should be armed"
  pass "fm-pr-check still proves a merged base LANDED when the default branch has edited its lines"
}

test_pr_check_refuses_wrong_base() {
  local case_dir rc
  case_dir=$(make_git_case wrongbase main)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-base: fm-pr-check should refuse a PR head not stacked on its base"
  assert_grep 'not stacked on its intended base' "$case_dir/stderr" \
    "wrong-base: refusal did not explain the stacking failure"
  assert_grep 'feature/base' "$case_dir/stderr" "wrong-base: refusal did not name the intended base"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "wrong-base: a wrong-based PR must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "wrong-base: a wrong-based PR must not arm the merge poll"
  pass "fm-pr-check refuses (loud, pre-merge) a PR head rebased onto the wrong base"
}

test_pr_check_refuses_wrong_base_label() {
  local case_dir rc
  # Head is correctly stacked on feature/base (content is fine), but the PR was
  # opened against main (base label = main), which would merge the feature base's
  # commits into main. The label check must catch this after stacking passes.
  case_dir=$(make_git_case wronglabel feature main)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-base-label: fm-pr-check should refuse a PR opened against the wrong base"
  assert_grep 'opened against base' "$case_dir/stderr" \
    "wrong-base-label: refusal did not explain the base label mismatch"
  assert_grep 'feature/base' "$case_dir/stderr" \
    "wrong-base-label: refusal did not name the intended base"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "wrong-base-label: a wrong-labeled PR must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "wrong-base-label: a wrong-labeled PR must not arm the merge poll"
  pass "fm-pr-check refuses (loud, pre-merge) a stacked PR opened against the wrong base label"
}

# The base's tip on origin, as fm-spawn.sh records it in meta at spawn time. Read it
# BEFORE a test deletes the branch from origin; that is the whole point of recording
# it - it is the only fact that survives the deletion.
base_tip() {
  local case_dir=$1
  git -C "$case_dir/origin.git" rev-parse refs/heads/feature/base
}

# The normal END-STATE of a stacked PR: the intended base merged and GitHub deleted
# the branch (it does so by default), retargeting this PR to main. The hazard the
# guard exists for went with it - there is no unmerged feature history left to drag
# into main - so the guard must stand down loudly and let the now-ordinary PR
# proceed. Refusing here would deadlock a legitimate merge forever, with a recovery
# message ('gh-axi pr edit --base <base>') that is impossible to follow because the
# base branch is gone.
#
# The proof that it MERGED, though, is not that the branch is gone - an abandoned base
# looks exactly the same to origin (see the abandoned case below). It is that the tip
# recorded at spawn is carried by main. Here it is an ancestor of main outright.
test_pr_check_stands_down_when_base_merged_and_deleted() {
  local case_dir rc tip
  case_dir=$(make_git_case gonebase feature main)
  tip=$(base_tip "$case_dir")
  # feature/base merges into main, then origin deletes the branch.
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$tip"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gone-base: a base that merged and was deleted must not deadlock the PR"
  assert_grep 'no longer exists on origin' "$case_dir/stderr" \
    "gone-base: standing the guard down must be said out loud, not done silently"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "gone-base: pr= should be recorded once the guard stands down"
  assert_present "$case_dir/state/task-x1.check.sh" "gone-base: the merge poll should be armed"
  pass "fm-pr-check stands down (loudly) when the declared base merged and was deleted"
}

# The base merged but its branch was NOT deleted - GitHub's "automatically delete head
# branches" is off by default, so this end-state is at least as common as the deleted
# one. It is a SQUASH merge (firstmate's own default), so the base's tip is not an
# ancestor of main, and the pipeline has rebased the head onto main as it always does.
# A guard that only stands down for an ABSENT base enforces rootedness here, finds the
# head rooted in main, and refuses - forever, with a recovery ('retarget onto the base')
# that would retarget the PR onto an already-merged branch. But the base's work IS in
# main: there is no unmerged feature history left to drag anywhere, so the hazard is
# gone and the guard must stand down exactly as it does for the deleted case. Branch
# existence decides nothing; landedness does.
test_pr_check_stands_down_when_present_base_squash_merged() {
  local case_dir rc tree parent squash
  case_dir=$(make_git_case presentsquash main main)
  tree=$(git -C "$case_dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$squash"
  advance_main "$case_dir"
  # No base_sha=: the live branch IS the fact on this path, so the guard must not need
  # the recorded spawn-time tip to see that the base merged.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "present-squash: a base that merged but was not deleted must not deadlock the PR"
  assert_grep 'already merged' "$case_dir/stderr" \
    "present-squash: standing the guard down must be said out loud, and must name the reason"
  assert_grep 'contained' "$case_dir/stderr" \
    "present-squash: the stand-down should say the base's work is carried by the default branch"
  assert_no_grep 'not stacked on its intended base' "$case_dir/stderr" \
    "present-squash: a merged base has no unmerged history to be rooted in - rootedness must not be enforced"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "present-squash: pr= should be recorded once the guard stands down"
  assert_present "$case_dir/state/task-x1.check.sh" "present-squash: the merge poll should be armed"
  pass "fm-pr-check stands down when the declared base squash-merged and its branch was kept"
}

# The same, reached by an ancestor merge with the branch kept. Rootedness is not the
# refusal here - the base tip IS an ancestor of main, so that check is skipped - but the
# base LABEL check still refuses, because the pipeline opened the PR against main. Same
# deadlock, same reason: the base's work is in main, so there is nothing left to guard,
# and 'retarget onto feature/base' is advice that cannot help.
test_pr_check_stands_down_when_present_base_ancestor_merged() {
  local case_dir rc
  case_dir=$(make_git_case presentmerged feature main)
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "present-merged: a merged base whose branch was kept must not deadlock on the base label"
  assert_grep 'already merged' "$case_dir/stderr" \
    "present-merged: the stand-down must be said out loud"
  assert_no_grep 'opened against base' "$case_dir/stderr" \
    "present-merged: the base label check must not refuse a PR whose base has already merged"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "present-merged: pr= should be recorded once the guard stands down"
  assert_present "$case_dir/state/task-x1.check.sh" "present-merged: the merge poll should be armed"
  pass "fm-pr-check stands down when the declared base ancestor-merged and its branch was kept"
}

# The same end-state, reached by a SQUASH merge - firstmate's own default merge method
# and GitHub's most common setting. The recorded tip is not an ancestor of main any
# more (the squash rewrote it), so an ancestor-only test would call this an abandoned
# base and deadlock the merge. Its work IS in main, which is what actually matters.
# main also advances afterwards, so this pins containment rather than tip equality.
# The head is where the pipeline leaves it - rebased onto main - so it carries none of
# the base's own commits. A head still STACKED on that squash-merged base is a different
# state entirely and must refuse; that is the case below this one.
test_pr_check_stands_down_when_base_squash_merged_and_deleted() {
  local case_dir rc tip tree parent squash
  case_dir=$(make_git_case squashedbase main main)
  tip=$(base_tip "$case_dir")
  # Squash feature/base into main: one new commit on main carrying the base's tree,
  # with no ancestry back to the base's own commits. Then origin deletes the branch,
  # and main moves on.
  tree=$(git -C "$case_dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$squash"
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  advance_main "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$tip"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squashed-base: a squash-merged, deleted base must not deadlock the PR"
  assert_grep 'contained' "$case_dir/stderr" \
    "squashed-base: the stand-down should say the base's work is carried by the default branch, not just that the branch is gone"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "squashed-base: pr= should be recorded once the guard stands down"
  assert_present "$case_dir/state/task-x1.check.sh" "squashed-base: the merge poll should be armed"
  pass "fm-pr-check stands down when the declared base was squash-merged and deleted"
}

# The hole a landedness-only stand-down opens, and it is the ORIGINAL incident reached
# through the other door. The base SQUASH-merged (firstmate's own default merge method,
# and GitHub's most common setting), so its CONTENT is in main but its COMMITS are not -
# main carries one new commit with a different id. A head still STACKED on that base -
# the ordinary direct-PR shape, where the crewmate owns its branch and never rebases it -
# therefore still carries every one of the base's pre-squash commits. Merging it into
# main lands them a second time, and its diff shows the base's already-merged changes as
# this task's. Landedness says "no unmerged content left"; rootedness says "this head
# still carries the base's commits". BOTH are true, and only the second one is about the
# head. So the guard asks rootedness FIRST and refuses here - and it must prescribe the
# head's REBASE, because retargeting the label leaves those commits exactly where they are.
test_pr_check_refuses_head_still_stacked_on_squash_merged_base() {
  local case_dir rc tree parent squash
  case_dir=$(make_git_case stackedonsquashed feature feature/base)
  tree=$(git -C "$case_dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$squash"
  advance_main "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-on-squashed: a head still carrying a squash-merged base's commits must not be waved through"
  assert_grep 'still stacked on its intended base' "$case_dir/stderr" \
    "stacked-on-squashed: the refusal did not say the head still sits on the merged base"
  assert_grep 'git rebase --onto origin/main' "$case_dir/stderr" \
    "stacked-on-squashed: the refusal did not prescribe the head's rebase, which is the only thing that resolves this state"
  assert_no_grep 'guard stands down' "$case_dir/stderr" \
    "stacked-on-squashed: the guard stood down for a head that still carries the base's pre-squash commits"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "stacked-on-squashed: a head carrying the merged base's commits must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "stacked-on-squashed: a head carrying the merged base's commits must not arm the merge poll"
  pass "fm-pr-check refuses a head still rooted in a squash-merged base, and prescribes the rebase"
}

# The same head, after the squash-merged base's branch was deleted too. Absence changes
# only which tip the checks reason from (the spawn-time base_sha=), never the verdict:
# the head still carries the base's pre-squash commits, so merging still lands them.
test_pr_check_refuses_head_still_stacked_on_squash_merged_gone_base() {
  local case_dir rc tip tree parent squash
  case_dir=$(make_git_case stackedonsquashedgone feature main)
  tip=$(base_tip "$case_dir")
  tree=$(git -C "$case_dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$case_dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$squash"
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  advance_main "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$tip"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-on-squashed-gone: a deleted base does not make the head's carried commits disappear"
  assert_grep 'still stacked on its intended base' "$case_dir/stderr" \
    "stacked-on-squashed-gone: the refusal did not say the head still sits on the merged base"
  assert_grep 'git rebase --onto origin/main' "$case_dir/stderr" \
    "stacked-on-squashed-gone: the refusal did not prescribe the head's rebase"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "stacked-on-squashed-gone: a head carrying the merged base's commits must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "stacked-on-squashed-gone: a head carrying the merged base's commits must not arm the merge poll"
  pass "fm-pr-check refuses a head still rooted in a squash-merged base whose branch was deleted"
}

# The hole a "gone means merged" stand-down would open, and it is the ORIGINAL
# incident reached through the escape hatch: the base was deleted WITHOUT merging (an
# abandoned feature, a closed base PR, a force-deleted branch). `git ls-remote` cannot
# tell this from the merged case above. The pipeline has already rebased the head onto
# main, replaying the base's never-merged commits onto it, so merging would land that
# abandoned work on main. This MUST refuse.
test_pr_check_refuses_when_base_deleted_without_merging() {
  local case_dir rc tip
  case_dir=$(make_git_case abandonedbase main main)
  tip=$(base_tip "$case_dir")
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$tip"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "abandoned-base: a base deleted WITHOUT merging must refuse - its unmerged work rides on the PR head"
  assert_grep 'WITHOUT merging' "$case_dir/stderr" \
    "abandoned-base: the refusal must name the reason, not read like a generic wrong-base verdict"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "abandoned-base: an abandoned base's work must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "abandoned-base: an abandoned base's work must not arm the merge poll"
  pass "fm-pr-check refuses when the declared base was deleted from origin without merging"
}

# No recorded tip, no way to tell the two cases above apart. Guessing is what opened
# the hole; refusing is the only sound answer, and it has to name the way out.
test_pr_check_refuses_gone_base_with_no_recorded_tip() {
  local case_dir rc
  case_dir=$(make_git_case notipbase feature main)
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-tip-base: a gone base with no recorded tip cannot be shown to have merged, so it must refuse"
  assert_grep 'no base_sha= tip was recorded' "$case_dir/stderr" \
    "no-tip-base: the refusal must explain that the deciding fact is missing"
  assert_grep 'fm-review-diff.sh' "$case_dir/stderr" \
    "no-tip-base: a merge-blocking refusal must name a way forward"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "no-tip-base: an unverifiable base must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "no-tip-base: an unverifiable base must not arm the merge poll"
  pass "fm-pr-check refuses a gone base whose tip was never recorded (no guessing)"
}

# A recorded tip that is not in the local object store cannot be compared against main
# at all, so landedness is INDETERMINATE - and with the branch gone there is no
# rootedness check left to fall back on either. Standing down is the guard's only
# relaxation and it takes proof, so an unanswerable question refuses and names why.
test_pr_check_refuses_gone_base_with_unknowable_tip() {
  local case_dir rc
  case_dir=$(make_git_case unknowabletip feature main)
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" \
    "base_sha=0123456789abcdef0123456789abcdef01234567"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unknowable-tip: an indeterminate landedness must refuse, never stand down"
  assert_grep 'could not be determined' "$case_dir/stderr" \
    "unknowable-tip: the refusal must say the question could not be answered"
  assert_grep 'object store' "$case_dir/stderr" \
    "unknowable-tip: the refusal must name why it could not be answered"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "unknowable-tip: an unverifiable base must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unknowable-tip: an unverifiable base must not arm the merge poll"
  pass "fm-pr-check refuses a gone base whose recorded tip cannot be compared against the default branch"
}

# The state a reader can actually reach by FOLLOWING the base-label refusal: they
# retarget the PR, then re-run the check before the pipeline's monitor has re-rebased
# and force-pushed. The head is still rooted in main, so the guard still refuses - and
# telling them to retarget again would send them in a circle with no way forward.
test_pr_check_rootedness_recovery_is_state_aware() {
  local case_dir rc
  case_dir=$(make_git_case retargeted main feature/base)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "retargeted: a head still rooted in main must still refuse"
  assert_grep 'already targets' "$case_dir/stderr" \
    "retargeted: the refusal did not notice the retarget had already landed"
  assert_grep 'has not been re-rebased' "$case_dir/stderr" \
    "retargeted: the refusal did not say what is actually missing (the head's re-rebase)"
  assert_no_grep 'pr edit' "$case_dir/stderr" \
    "retargeted: the refusal told the reader to redo the retarget they already did - a no-op that loops"
  pass "fm-pr-check's rootedness refusal prescribes the re-rebase, not another retarget, once the PR already targets the base"
}

# An origin that cannot be ASKED is not a base that is gone. We know nothing, so the
# refusal stays fail-closed - and it names git's own error so an auth or network
# failure is diagnosable instead of masquerading as a wrong-base verdict.
test_pr_check_fail_closed_when_base_probe_fails() {
  local case_dir rc
  case_dir=$(make_git_case probefails feature feature/base)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "probe-fails: fm-pr-check should fail closed when the base cannot be verified at all"
  assert_grep 'could not be asked' "$case_dir/stderr" \
    "probe-fails: refusal did not explain that the probe itself failed"
  assert_grep 'git:' "$case_dir/stderr" \
    "probe-fails: refusal did not surface git's own error"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "probe-fails: an unverifiable base must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "probe-fails: an unverifiable base must not arm the merge poll"
  pass "fm-pr-check fails closed when origin cannot be asked whether the base exists"
}

# The base branch advanced after the PR head was stacked on it. The head is
# correctly based - it carries feature/base's unmerged history - it is just behind
# the base tip, which is the routine state of a stacked PR whose own base is still
# under review. Refusing here would turn every ordinary base advance into a hard
# merge refusal, so this MUST be allowed.
test_pr_check_allows_base_advanced_since_head() {
  local case_dir rc
  case_dir=$(make_git_case baseadvanced feature feature/base advance)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "base-advanced: a head correctly based on a base that merely ADVANCED must not be refused"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "base-advanced: pr= should be recorded for a correctly based PR whose base advanced"
  assert_present "$case_dir/state/task-x1.check.sh" "base-advanced: the merge poll should be armed"
  assert_no_grep 'not stacked on its intended base' "$case_dir/stderr" \
    "base-advanced: a merely-behind head must not trip the guard"
  pass "fm-pr-check allows a correctly based PR whose base advanced after the head was stacked"
}

# Standing the guard down means the PR is re-checked as the ORDINARY DEFAULT-BRANCH PR
# it now is, not that checking stops. This is the state that proves the difference: the
# base merged WITHOUT being deleted (GitHub's delete-on-merge is off by default) and the
# PR still targets it - exactly what the no-mistakes brief REQUIRES the crewmate to do,
# since it must retarget onto the base before reporting done. Merging that PR merges into
# feature/base, an already-merged branch: the fix never reaches main, while the PR reads
# MERGED and fm-teardown.sh releases the worktree and the task goes to Done. A stand-down
# that only skips the base checks would wave it straight through.
test_pr_check_refuses_stand_down_pr_still_targeting_the_merged_base() {
  local case_dir rc
  case_dir=$(make_git_case landedlabel feature feature/base)
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "base=feature/base" "base_sha=$(base_tip "$case_dir")"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "landed-label: a PR still targeting a base that has already merged must refuse, not sail through the stand-down"
  assert_grep 'already merged' "$case_dir/stderr" \
    "landed-label: the refusal did not say the base it targets has merged"
  assert_grep 'pr edit 9 --base main' "$case_dir/stderr" \
    "landed-label: the refusal did not prescribe retargeting back to the default branch"
  # In a merge gate the message is the only signal. Announcing the stand-down above a
  # refusal the very same call reaches would have the output contradict itself.
  assert_no_grep 'guard stands down' "$case_dir/stderr" \
    "landed-label: the stand-down was announced before the check that then refused, so the output claims an outcome it never reached"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "landed-label: a PR that would merge into a merged branch must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "landed-label: a PR that would merge into a merged branch must not arm the merge poll"
  pass "fm-pr-check refuses a stood-down PR that still targets its now-merged base"
}

test_pr_check_no_base_arms_normally() {
  local case_dir rc
  case_dir=$(make_git_case nobase feature)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-base: fm-pr-check should behave exactly as before without base="
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "no-base: pr= should be recorded on the default (no-base) path"
  assert_present "$case_dir/state/task-x1.check.sh" "no-base: the merge poll should be armed"
  assert_no_grep 'not stacked' "$case_dir/stderr" "no-base: the stacking guard must not run without base="
  pass "fm-pr-check without base= records pr= and arms the poll unchanged"
}

test_records_pr_and_head_before_merging
test_malformed_gh_fields_record_no_pr_head
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_pr_check_accepts_stacked_base
test_pr_check_refuses_a_base_whose_landedness_cannot_be_settled
test_pr_check_stands_down_for_a_merged_base_that_now_conflicts
test_pr_check_allows_base_advanced_since_head
test_pr_check_refuses_wrong_base
test_pr_check_refuses_wrong_base_label
test_pr_check_rootedness_recovery_is_state_aware
test_pr_check_refuses_stand_down_pr_still_targeting_the_merged_base
test_pr_check_stands_down_when_base_merged_and_deleted
test_pr_check_stands_down_when_base_squash_merged_and_deleted
test_pr_check_stands_down_when_present_base_squash_merged
test_pr_check_stands_down_when_present_base_ancestor_merged
test_pr_check_refuses_head_still_stacked_on_squash_merged_base
test_pr_check_refuses_head_still_stacked_on_squash_merged_gone_base
test_pr_check_refuses_when_base_deleted_without_merging
test_pr_check_refuses_gone_base_with_no_recorded_tip
test_pr_check_refuses_gone_base_with_unknowable_tip
test_pr_check_fail_closed_when_base_probe_fails
test_pr_check_no_base_arms_normally
