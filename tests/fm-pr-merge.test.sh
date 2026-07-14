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
# (fm-brief.sh --base), asserts the PR head is ROOTED IN THAT BASE'S UNMERGED
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
# Matrix (fm-pr-check.sh based-on-base guard):
#   (i) base= present, head stacked on the base AND base label matches -> records pr=, arms the poll
#   (j) base= present, base ADVANCED after the head was stacked -> still allowed (merely behind, not wrong-based)
#   (k) base= present, PR head rebased onto main -> refuses, no pr=, no poll
#   (l) base= present, head stacked but PR base label targets main -> refuses, no pr=, no poll
#   (m) base= present in the data/<id>/base sidecar but never promoted into meta -> refuses (no silent fail-open)
#   (n) base= present but the base branch is GONE from origin (it merged and was
#       auto-deleted, the normal end-state of a stacked PR) -> the guard stands down
#       loudly and the PR proceeds; refusing would deadlock a legitimate merge forever
#   (o) base= present but origin cannot be asked at all (auth, network) -> fail-closed refusal
#   (p) no base= (the common case) -> unchanged: records pr= and arms the poll
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

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

# Write the data/<id>/base sidecar fm-brief.sh records and fm-spawn.sh promotes.
write_base_sidecar() {
  local case_dir=$1 id=$2 base=$3
  mkdir -p "$case_dir/data/$id"
  printf '%s\n' "$base" > "$case_dir/data/$id/base"
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

# The normal END-STATE of a stacked PR: the intended base merged and GitHub deleted
# the branch (it does so by default), retargeting this PR to main. The hazard the
# guard exists for went with it - there is no unmerged feature history left to drag
# into main - so the guard must stand down loudly and let the now-ordinary PR
# proceed. Refusing here would deadlock a legitimate merge forever, with a recovery
# message ('gh-axi pr edit --base <base>') that is impossible to follow because the
# base branch is gone.
test_pr_check_stands_down_when_base_gone_from_origin() {
  local case_dir rc
  case_dir=$(make_git_case gonebase feature main)
  # feature/base merges into main, then origin deletes the branch.
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

  expect_code 0 "$rc" "gone-base: a base that merged and was deleted must not deadlock the PR"
  assert_grep 'no longer exists on origin' "$case_dir/stderr" \
    "gone-base: standing the guard down must be said out loud, not done silently"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "gone-base: pr= should be recorded once the guard stands down"
  assert_present "$case_dir/state/task-x1.check.sh" "gone-base: the merge poll should be armed"
  pass "fm-pr-check stands down (loudly) when the declared base is gone from origin"
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

# The sidecar -> meta promotion (fm-spawn.sh) is the one link that could disarm the
# guard silently: with no base= in meta, the assertion would be skipped entirely and
# a wrong-based PR would sail through. A sidecar that disagrees with meta must refuse.
test_pr_check_refuses_when_sidecar_never_reached_meta() {
  local case_dir rc
  case_dir=$(make_git_case orphansidecar main)
  write_base_sidecar "$case_dir" task-x1 feature/base
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-sidecar: a declared base missing from meta must refuse, not silently skip the guard"
  assert_grep 'never reached meta' "$case_dir/stderr" \
    "orphan-sidecar: refusal did not explain the lost base declaration"
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "orphan-sidecar: an unguarded PR must not record pr= before merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "orphan-sidecar: an unguarded PR must not arm the merge poll"
  pass "fm-pr-check refuses when a declared base sidecar never reached meta (no silent fail-open)"
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
test_pr_check_allows_base_advanced_since_head
test_pr_check_refuses_wrong_base
test_pr_check_refuses_wrong_base_label
test_pr_check_refuses_when_sidecar_never_reached_meta
test_pr_check_stands_down_when_base_gone_from_origin
test_pr_check_fail_closed_when_base_probe_fails
test_pr_check_no_base_arms_normally
