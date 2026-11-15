#!/usr/bin/env bash
# Tests for bin/fm-merge-gate-lib.sh and its wiring into bin/fm-pr-merge.sh and
# bin/fm-go-queue-run.sh.
#
# The defect these tests exist for is a gate that cannot fail: before this
# library, bin/fm-pr-merge.sh verified that a pull request was open, mergeable,
# and conflict-free, and then merged it without ever reading the review verdict.
# A NO-GO pull request merged exactly as easily as a GO one. So every refusal
# case below is written to fail against the ungated script: the gate has to
# refuse, name the reason, and leave the merge call unmade.
#
# Matrix:
#   (a) a qa-review NO-GO on the current head refuses
#   (b) an absent qa-review verdict refuses, because silence is not a GO
#   (c) a verdict recorded against an older head refuses on the current head
#   (d) any red check refuses, naming the check
#   (e) adk47's own credit-approval-guard red is the one standing allow
#   (f) the same red on anyone else's pull request refuses
#   (g) a master twin whose develop counterpart is unmerged refuses
#   (h) a master twin whose develop counterpart is merged passes
#   (h2) the twin rule is skipped outside the declared twin repositories
#   (i) a head that moved off the expected commit refuses
#   (j) an unreadable verdict refuses rather than merging blind
#   (k) a green head with a qa-review GO passes and reports what it verified
#   (l) an unattested red-check allow is rejected by the interface
#   (m) bin/fm-pr-merge.sh refuses before the merge call and records nothing
#       for every refusal case above, so the wiring itself is proven
#   (n) --override-gate records the reason, the operator, and the time, then
#       merges
#   (o) bin/fm-go-queue-run.sh merges only through the gate, and a refused row
#       is reported and skipped, including when the queue file follows --
#   (q) an unreadable twin list refuses rather than passing
#   (r) an unreadable twin PR referenced by the body refuses
#   (s) a repeated qa-review check reports its worst conclusion
#   (t) an unrelated issue reference is not read as a twin
#   (u) a null pending qa-review conclusion is not overwritten by a success
#   (v) prose around develop/beta is not read as a twin reference
#   (w) a skipped or neutral duplicate cannot outrank an earlier success
#   (x) a Muso-AI repository without a qa-review check still refuses
#   (y) declared no-QA coverage needs a green no-mistakes attestation
#   (z) an undeclared repository refuses until a recorded override
#   (aa) a red check whose name contains the old field delimiter still refuses
#   (ab) declared no-QA coverage applies on GitLab instead of a forge refusal,
#        and the GitHub-only twin rule notes its skip instead of refusing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-merge-gate-lib.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
QUEUE_RUN="$ROOT/bin/fm-go-queue-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-gate-tests)

JQ_BIN=$(command -v jq) || fail "these tests read fixtures with the real jq, which was not found"

REPO=Muso-AI/core-backend
HEAD=1111111111111111111111111111111111111111
OLD_HEAD=2222222222222222222222222222222222222222

# A fake gh that serves JSON fixtures through the real jq, so the gate's own
# --jq program is exercised rather than bypassed. Fixtures live in the case dir:
# pr-view.json, pr-list.json, pulls-<n>.json. A missing fixture
# is a failed read, which is how the unreadable-verdict case is built.
write_gh_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
jqprog=
prev=
for a in "$@"; do
  if [ "$prev" = --jq ]; then jqprog=$a; fi
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
serve() {
  [ -r "$1" ] || { echo "error: Not Found" >&2; exit 1; }
  if [ -n "$jqprog" ]; then jq -r "$jqprog" "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr)
    case "${2:-}" in
      view) serve "$FM_TEST_GH_FIXTURES/pr-view.json" ;;
      list) serve "$FM_TEST_GH_FIXTURES/pr-list.json" ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    path=${2:-}
    case "$path" in
      */pulls/*) serve "$FM_TEST_GH_FIXTURES/pulls-${path##*/}.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# make_case <name>: a sandbox with a fakebin, a fixtures dir, and a task meta.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/fixtures" "$case_dir/state"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$case_dir/gh.log"
  write_gh_mock "$case_dir"
  printf '%s\n' "$case_dir"
}

# write_pr_view <case_dir> [<field>=<value> ...]
# A pull request payload that satisfies every gate condition, with the named
# fields overridden so one case drives exactly one refusal. checks= is a
# comma-separated list of name:conclusion pairs.
write_pr_view() {
  local case_dir=$1 kv key value
  local head=$HEAD author=someone base=develop headref=feature/x state=OPEN
  local merged_at=null body='Closes nothing.' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      head) head=$value ;;
      author) author=$value ;;
      base) base=$value ;;
      headref) headref=$value ;;
      state) state=$value ;;
      merged_at) merged_at=$value ;;
      body) body=$value ;;
      checks) checks=$value ;;
      *) fail "write_pr_view: unknown field '$key'" ;;
    esac
  done
  local rollup='' pair name conclusion
  local IFS=,
  for pair in $checks; do
    [ -n "$pair" ] || continue
    # pair = name:conclusion[@wf[#started]] - wf keys the workflow name,
    # started orders that workflow's runs.
    local extra='' run='' started=''
    name=${pair%%:*}
    conclusion=${pair#*:}
    case "$conclusion" in *@*) run=${conclusion#*@}; conclusion=${conclusion%%@*} ;; esac
    case "$run" in *#*) started=${run#*#}; run=${run%%#*} ;; esac
    [ -n "$run" ] && extra="$extra,\"workflowName\":\"wf-$run\",\"detailsUrl\":\"https://github.com/o/r/actions/runs/$run/job/1\""
    [ -n "$started" ] && extra="$extra,\"startedAt\":\"2026-11-15T$started:00Z\""
    [ -n "$rollup" ] && rollup="$rollup,"
    rollup="$rollup{\"__typename\":\"CheckRun\",\"name\":\"$name\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"$extra}"
  done
  unset IFS
  cat > "$case_dir/fixtures/pr-view.json" <<JSON
{
  "headRefOid": "$head",
  "author": {"login": "$author"},
  "baseRefName": "$base",
  "headRefName": "$headref",
  "state": "$state",
  "mergedAt": $merged_at,
  "body": "$body",
  "statusCheckRollup": [$rollup]
}
JSON
}

# write_pr_list <case_dir> <number> <base> <state> <mergedAt>: the pull requests
# on the same head branch, which is how a develop/beta twin is found.
write_pr_list() {
  local case_dir=$1 number=$2 base=$3 state=$4 merged_at=$5
  cat > "$case_dir/fixtures/pr-list.json" <<JSON
[{"number": $number, "baseRefName": "$base", "state": "$state", "mergedAt": $merged_at}]
JSON
}

# write_no_qa_repos <case_dir> <owner/repo>...: declare the local no-QA list.
write_no_qa_repos() {
  local case_dir=$1 repo
  shift
  mkdir -p "$case_dir/config"
  {
    printf '# local no-QA coverage declarations\n\n'
    for repo in "$@"; do printf '%s\n' "$repo"; done
  } > "$case_dir/config/merge-gate-no-qa-repos"
}

# write_glab_mock <case_dir>: serve a merge request and its commit statuses.
write_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/merge_requests/7") cat "$FM_TEST_GLAB_FIXTURES/mr.json" ;;
  *"/statuses"*) cat "$FM_TEST_GLAB_FIXTURES/statuses.json" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# run_gate <case_dir> [args...]: run the gate in check-only mode.
run_gate() {
  local case_dir=$1 rc
  shift
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$GATE" "$@" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  return "$rc"
}

# run_refusal_via_merge <case_dir> [args...]: drive the real merge entry point
# and prove the refusal leaves the forge merge call unmade.
run_refusal_via_merge() {
  local case_dir=$1
  shift
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" "$@"
}

# --- (a) a qa-review NO-GO on the current head refuses ----------------------

test_gate_refuses_qa_no_go() {
  local case_dir rc
  case_dir=$(make_case qa-no-go)
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a qa-review NO-GO must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the refusal must name the verdict and the head it was read on"
  assert_contains "$(cat "$case_dir/err")" "refusing to merge $REPO#9" \
    "the refusal must name the pull request"
  pass "a qa-review NO-GO on the current head refuses"
}

# --- (b) an absent verdict refuses -----------------------------------------

test_gate_refuses_absent_qa_verdict() {
  local case_dir rc
  case_dir=$(make_case qa-absent)
  write_pr_view "$case_dir" checks='unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an absent qa-review verdict must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "no qa-review verdict exists on head $HEAD" \
    "the refusal must say the verdict is absent, not that it passed"
  pass "an absent qa-review verdict refuses"
}

# --- (c) a verdict on an older head does not authorize a newer one ---------

test_gate_refuses_verdict_on_older_head() {
  local case_dir rc
  case_dir=$(make_case qa-stale-head)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  printf 'pr_head=%s\n' "$OLD_HEAD" >> "$case_dir/state/task-x1.meta"

  # The verdict was read on OLD_HEAD; the pull request is now at HEAD.
  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a verdict recorded against an older head must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the recorded head $OLD_HEAD is not the current head $HEAD" \
    "the refusal must name both heads so the stale verdict is visible"
  pass "a verdict recorded against an older head refuses"
}

# --- (d) any red check refuses ---------------------------------------------

test_gate_refuses_red_check() {
  local case_dir rc
  case_dir=$(make_case red-check)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:FAILURE'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a red check must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the check unit-tests is FAILURE on head $HEAD" \
    "the refusal must name the red check"
  pass "a red check refuses"
}

# --- (e) adk47's own credit-approval-guard is the standing allow -----------

test_gate_allows_adk47_credit_guard() {
  local case_dir rc
  case_dir=$(make_case adk47-credit-guard)
  write_pr_view "$case_dir" author=adk47 \
    checks='qa-review:SUCCESS,credit-approval-guard:FAILURE'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "adk47's own credit-approval-guard red must not refuse"
  assert_contains "$(cat "$case_dir/out")" "allowed reds=credit-approval-guard" \
    "the pass must report the red it allowed"
  pass "adk47's own credit-approval-guard red is allowed"
}

# --- (f) the same red on anyone else refuses -------------------------------

test_gate_refuses_credit_guard_for_other_author() {
  local case_dir rc
  case_dir=$(make_case other-author-credit-guard)
  write_pr_view "$case_dir" author=someone-else \
    checks='qa-review:SUCCESS,credit-approval-guard:FAILURE'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "the credit-approval-guard allow is adk47's alone"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the check credit-approval-guard is FAILURE" \
    "the refusal must name the check"
  pass "the credit-approval-guard red refuses for any other author"
}

# --- (g) an unmerged develop twin refuses ----------------------------------

test_gate_refuses_unmerged_develop_twin() {
  local case_dir rc
  case_dir=$(make_case unmerged-twin)
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  write_pr_list "$case_dir" 12 develop OPEN null

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a master twin with an unmerged develop counterpart must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "pull request #12 targets develop and is not merged" \
    "the refusal must name the unmerged twin"
  pass "a master twin with an unmerged develop counterpart refuses"
}

# --- (h) a merged develop twin passes --------------------------------------

test_gate_allows_merged_develop_twin() {
  local case_dir rc
  case_dir=$(make_case merged-twin)
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  write_pr_list "$case_dir" 12 develop MERGED '"2026-11-03T10:00:00Z"'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a merged develop twin must not refuse"
  pass "a master twin whose develop counterpart is merged passes"
}

# --- (h2) a repository outside the twin list skips the twin rule ------------

test_gate_skips_twin_check_for_other_repositories() {
  local case_dir rc
  case_dir=$(make_case non-twin-repository)
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" Muso-AI/repo 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a repository outside the twin list must skip the twin rule"
  assert_contains "$(cat "$case_dir/out")" \
    "twin check skipped for Muso-AI/repo#9: the repository is not declared a twin repository" \
    "the pass must note that the twin check was skipped"
  pass "the twin rule is skipped outside the declared twin repositories"
}

# --- (i) a moved head refuses ----------------------------------------------

test_gate_refuses_moved_head() {
  local case_dir rc
  case_dir=$(make_case moved-head)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash --match-head-commit "$OLD_HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a head that moved off the expected commit must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the head moved: expected $OLD_HEAD, the pull request is at $HEAD" \
    "the refusal must name both heads"
  pass "a head that moved off the expected commit refuses"
}

# --- (j) an unreadable verdict refuses -------------------------------------

test_gate_refuses_unreadable_verdict() {
  local case_dir rc
  case_dir=$(make_case unreadable)
  # No pr-view.json: the read fails, and a failed read is not a GO.

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an unreadable verdict must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "could not be read" \
    "the refusal must say the read failed rather than implying a verdict"
  pass "an unreadable verdict refuses"
}

# --- (k) a green head with a GO passes -------------------------------------

test_gate_passes_green_with_qa_go() {
  local case_dir rc
  case_dir=$(make_case green)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS,lint:SKIPPED'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a green head with a qa-review GO must pass"
  assert_contains "$(cat "$case_dir/out")" "authorized at head $HEAD" \
    "the pass must report the head it verified"
  assert_contains "$(cat "$case_dir/out")" "qa-review=SUCCESS" \
    "the pass must report the verdict it read"
  pass "a green head with a qa-review GO passes and reports what it verified"
}

# --- (l) an unattested red-check allow is rejected by the interface --------

test_gate_rejects_unrecorded_red_allow() {
  local case_dir rc
  case_dir=$(make_case unrecorded-red-allow)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,verify-twin-label:FAILURE'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD" --allow-red verify-twin-label
  rc=$?
  set -e
  expect_code 2 "$rc" "a bare --allow-red must be an unknown option, not an escape hatch"
  assert_contains "$(cat "$case_dir/err")" "unknown merge gate option: --allow-red" \
    "the refusal must name the unsupported option"
  pass "an unrecorded red-check allow is rejected"
}

# --- (q) an unreadable twin list refuses rather than passing ---------------

test_gate_refuses_unreadable_twin_list() {
  local case_dir rc
  case_dir=$(make_case unreadable-twin-list)
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a failed twin-list read must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "twin list could not be read" \
    "the refusal must say the twin state was unreadable"
  pass "an unreadable twin list refuses"
}

# --- (r) an unreadable twin referenced by the body refuses -----------------

test_gate_refuses_unreadable_body_twin() {
  local case_dir rc
  case_dir=$(make_case unreadable-body-twin)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='twin develop #42' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an unreadable body-referenced twin must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "pull request #42 referenced by the body could not be read" \
    "the refusal must say the twin could not be read"
  pass "an unreadable body-referenced twin refuses"
}

# --- (s) a repeated qa-review check reports its worst conclusion -----------

test_gate_duplicate_qa_reports_worst_conclusion() {
  local case_dir rc
  case_dir=$(make_case duplicate-qa)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,qa-review:PENDING'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a later pending duplicate must outrank an earlier success"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is PENDING" \
    "the refusal must report the worst duplicate conclusion"
  pass "a repeated qa-review check reports its worst conclusion"
}

# --- (t) an unrelated issue reference is not read as a twin ----------------

test_gate_ignores_unrelated_issue_reference() {
  local case_dir rc
  case_dir=$(make_case unrelated-issue)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "an unrelated issue reference must not be treated as a twin"
  pass "an unrelated issue reference is not read as a twin"
}

# --- (u) a null pending verdict is not overwritten by a success ------------

test_gate_null_pending_qa_before_success_refuses() {
  local case_dir rc
  case_dir=$(make_case null-pending-qa)
  write_pr_view "$case_dir" checks='qa-review:,qa-review:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a null pending conclusion must outrank a later success"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is PENDING, not SUCCESS" \
    "the refusal must report the pending verdict, not the later success"
  pass "a null pending qa-review conclusion is not overwritten by a success"
}

# --- (u2) a cancelled duplicate is superseded by a later run ----------------

test_gate_cancelled_duplicate_is_superseded() {
  local case_dir rc
  case_dir=$(make_case cancelled-dup)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,pr-title:CANCELLED,pr-title:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a cancelled run superseded by a later run of the same check must not refuse"
  pass "a cancelled duplicate check is superseded by its later run"
}

test_gate_only_cancelled_run_still_refuses() {
  local case_dir rc
  case_dir=$(make_case cancelled-only)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,pr-title:CANCELLED,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a check whose only run is cancelled is still red"
  pass "a check with only a cancelled run still refuses"
}

test_gate_rerun_in_same_run_supersedes_failure() {
  local case_dir rc
  case_dir=$(make_case rerun-same-run)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,verify:FAILURE@11#07:43,verify:SUCCESS@11#12:06,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a later run of the same workflow that passed must supersede its earlier failure"
  pass "a later run within one workflow supersedes its earlier failure"
}

test_gate_failure_in_other_run_still_refuses() {
  local case_dir rc
  case_dir=$(make_case other-run-failure)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,verify:FAILURE@11#07:43,verify:SUCCESS@12#12:06,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a failure in a different workflow sharing the check name is still red"
  pass "a same-named failure in another workflow still refuses"
}

# --- (v) prose around develop/beta is not a twin reference -----------------

test_gate_ignores_develop_beta_prose() {
  local case_dir rc
  case_dir=$(make_case develop-beta-prose)
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='This develops the 2026 roadmap and beta testing #5.' \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "prose around develop/beta must not be read as a twin"
  pass "prose around develop/beta is not read as a twin reference"
}

# --- (w) a skipped or neutral duplicate cannot outrank a success -----------

test_gate_skipped_or_neutral_qa_outranks_success() {
  local case_dir rc conclusion
  for conclusion in SKIPPED NEUTRAL; do
    case_dir=$(make_case "duplicate-qa-$conclusion")
    write_pr_view "$case_dir" checks="qa-review:SUCCESS,qa-review:$conclusion"

    set +e
    run_refusal_via_merge "$case_dir" -- --squash
    rc=$?
    set -e
    expect_code 1 "$rc" "a later $conclusion duplicate must outrank an earlier success"
    assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
    assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is $conclusion" \
      "the refusal must report $conclusion, not the earlier success"
  done
  pass "a skipped or neutral duplicate cannot outrank an earlier success"
}

# --- (x) Muso-AI remains qa-review-covered without any workflow inference ---

test_gate_muso_ai_without_qa_check_refuses() {
  local case_dir rc
  case_dir=$(make_case muso-ai-no-qa-check)
  write_pr_view "$case_dir" checks='unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a Muso-AI repository without a qa-review check must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "no qa-review verdict exists on head $HEAD" \
    "the refusal must apply the declared Muso-AI class, not an absent workflow"
  pass "a Muso-AI repository without a qa-review check still refuses"
}

test_gate_muso_ai_with_qa_go_passes_without_workflow_fixture() {
  local case_dir rc
  case_dir=$(make_case muso-ai-qa-go)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a Muso-AI qa-review GO must pass even with no workflow fixture"
  assert_contains "$(cat "$case_dir/out")" "qa-review=SUCCESS" \
    "the pass must report the declared class's verdict"
  pass "a Muso-AI repository with a current qa-review GO passes"
}

# --- (y) declared no-QA coverage uses the no-mistakes attestation ----------

test_gate_declared_no_qa_attestation_green_passes() {
  local case_dir rc
  case_dir=$(make_case no-qa-attested)
  write_no_qa_repos "$case_dir" Acme/widgets
  write_pr_view "$case_dir" checks='PR must be raised via no-mistakes:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" Acme/widgets 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a declared no-QA repository with a green attestation must pass"
  assert_contains "$(cat "$case_dir/out")" "no-mistakes-attestation=SUCCESS" \
    "the pass must report the attestation it verified"
  pass "a declared no-QA repository with a green attestation passes"
}

test_gate_declared_no_qa_attestation_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case no-qa-attestation-absent)
  write_no_qa_repos "$case_dir" Acme/widgets
  write_pr_view "$case_dir" checks='unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" Acme/widgets 9 "$HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a declared no-QA repository without the attestation must refuse"
  assert_contains "$(cat "$case_dir/err")" "no no-mistakes attestation named 'PR must be raised via no-mistakes' exists on head $HEAD" \
    "the refusal must name the absent attestation"
  pass "a declared no-QA repository without the attestation refuses"
}

test_gate_declared_no_qa_attestation_red_refuses() {
  local case_dir rc
  case_dir=$(make_case no-qa-attestation-red)
  write_no_qa_repos "$case_dir" 'Acme/widgets  # local declaration'
  write_pr_view "$case_dir" checks='PR must be raised via no-mistakes:FAILURE,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" Acme/widgets 9 "$HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a red no-mistakes attestation must refuse"
  assert_contains "$(cat "$case_dir/err")" "the no-mistakes attestation on head $HEAD is FAILURE, not SUCCESS" \
    "the refusal must name the attestation and its conclusion"
  pass "a declared no-QA repository with a red attestation refuses"
}

# --- (z) an undeclared repository refuses until a recorded override --------

test_gate_undeclared_repository_refuses() {
  local case_dir rc
  case_dir=$(make_case undeclared-repo)
  write_no_qa_repos "$case_dir" Acme/other
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" Acme/widgets 9 "$HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "an undeclared repository must refuse"
  assert_contains "$(cat "$case_dir/err")" "QA coverage unknown" \
    "the refusal must say coverage is unknown, not silently allow"
  pass "an undeclared repository refuses with QA coverage unknown"
}

test_pr_merge_undeclared_repository_override_passes_and_records() {
  local case_dir rc meta
  case_dir=$(make_case undeclared-override)
  write_no_qa_repos "$case_dir" Acme/other
  write_pr_view "$case_dir" checks='unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=develop' \
    > "$case_dir/github-outcome"
  : > "$case_dir/gh-axi.log"
  meta="$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/Acme/widgets/pull/9" \
    --override-gate "captain accepted unknown coverage" -- --squash
  rc=$?
  set -e
  expect_code 0 "$rc" "an explicit recorded override must authorize an undeclared repository"
  assert_grep "pr merge" "$case_dir/gh-axi.log" "the overridden merge call must be made"
  assert_grep "merge_gate_override=captain accepted unknown coverage" "$meta" \
    "the override reason must be recorded"
  assert_grep "merge_gate_override_by=" "$meta" "the override operator must be recorded"
  assert_grep "merge_gate_override_at=" "$meta" "the override time must be recorded"
  pass "an undeclared repository merges only through a recorded override"
}

# --- (aa) a check name carrying the old delimiter still refuses ------------

test_gate_red_check_name_with_pipe_refuses() {
  local case_dir rc
  case_dir=$(make_case red-check-pipe)
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,build | linux:FAILURE'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a red check whose name contains | must still refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the check build | linux is FAILURE on head $HEAD" \
    "the refusal must preserve the whole check name and its conclusion"
  pass "a red check whose name contains the old delimiter still refuses"
}

# A backfill over past merges needs the verdict of a pull request that already
# merged, so --check-only evaluates it instead of short-circuiting.
test_gate_check_only_audits_a_merged_pull_request() {
  local case_dir rc
  case_dir=$(make_case check-only-merged)
  write_pr_view "$case_dir" state=MERGED merged_at='"2026-11-03T12:00:00Z"' \
    checks='qa-review:FAILURE,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "an already-merged pull request must short-circuit without --check-only"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD" --check-only
  rc=$?
  set -e
  expect_code 1 "$rc" "--check-only must evaluate a merged pull request's verdict"
  assert_contains "$(cat "$case_dir/err")" "the qa-review verdict on head $HEAD is FAILURE" \
    "--check-only must name the verdict it refused"
  pass "--check-only audits an already-merged pull request instead of short-circuiting"
}

# --- (m) fm-pr-merge.sh refuses before the merge call ----------------------

# A gh-axi mock that records every call, so a test can prove the merge call was
# never made.
write_gh_axi_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# The gh mock also has to answer the outcome read fm-pr-merge.sh makes after a
# merge, so a case that does merge can reach its verified result.
extend_gh_mock_for_outcome() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
jqprog=
prev=
for a in "$@"; do
  if [ "$prev" = --jq ]; then jqprog=$a; fi
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
serve() {
  [ -r "$1" ] || { echo "error: Not Found" >&2; exit 1; }
  if [ -n "$jqprog" ]; then jq -r "$jqprog" "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)
        case " $* " in
          *statusCheckRollup*) serve "$FM_TEST_GH_FIXTURES/pr-view.json" ;;
          *headRefOid*) printf '%s\n' "$FM_TEST_GH_HEAD" ;;
          *) exit 1 ;;
        esac
        ;;
      list) serve "$FM_TEST_GH_FIXTURES/pr-list.json" ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    path=${2:-}
    case "$path" in
      graphql) cat "$FM_TEST_GH_OUTCOME" ;;
      */pulls/*) serve "$FM_TEST_GH_FIXTURES/pulls-${path##*/}.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_TEST_GH_HEAD="$HEAD" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  return "$rc"
}

test_pr_merge_refuses_before_merge_call() {
  local case_dir rc
  case_dir=$(make_case pr-merge-refuses)
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "fm-pr-merge.sh must refuse a NO-GO pull request"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the refusal must name the verdict"
  assert_no_grep "pr=" "$case_dir/state/task-x1.meta" \
    "a refused merge must not record pr="
  pass "fm-pr-merge.sh refuses before the merge call and records nothing"
}

# --- (n) --override-gate records the reason and merges ---------------------

test_pr_merge_override_records_and_merges() {
  local case_dir rc meta
  case_dir=$(make_case pr-merge-override)
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=develop' \
    > "$case_dir/github-outcome"
  : > "$case_dir/gh-axi.log"
  meta="$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" \
    --override-gate "captain said merge it anyway" -- --squash
  rc=$?
  set -e
  expect_code 0 "$rc" "an overridden gate must let the merge proceed"
  assert_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must be made"
  assert_grep "merge_gate_override=captain said merge it anyway" "$meta" \
    "the override reason must be recorded"
  assert_grep "merge_gate_override_by=" "$meta" "the operator must be recorded"
  assert_grep "merge_gate_override_at=" "$meta" "the time must be recorded"
  assert_contains "$(cat "$case_dir/err")" "the merge gate is overridden" \
    "the override must be announced, not silent"
  pass "--override-gate records the reason, the operator, and the time, then merges"
}

# --- (o) the queue merges only through the gate ---------------------------

test_go_queue_refuses_row_and_continues() {
  local case_dir rc queue
  case_dir=$(make_case go-queue)
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"
  queue="$case_dir/queue.txt"
  printf '%s\n' "# task repo pr head method" \
    "task-x1 $REPO 9 $HEAD squash" > "$queue"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_TEST_GH_HEAD="$HEAD" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$QUEUE_RUN" "$queue" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a refused row must make the queue exit non-zero"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "a refused row must never reach the merge call"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the queue must surface the gate's own reason"
  assert_contains "$(cat "$case_dir/out")" "0 merged, 1 not merged" \
    "the queue must report the row as not merged"
  pass "the queue merges only through the gate, and a refused row is skipped"
}

test_go_queue_accepts_double_dash_separator() {
  local case_dir rc queue
  case_dir=$(make_case go-queue-double-dash)
  queue=$case_dir/queue.txt
  printf '%s\n' '# empty queue' > "$queue"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$QUEUE_RUN" -- "$queue" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "a queue file after -- must be accepted"
  assert_contains "$(cat "$case_dir/out")" "queue: 0 merged, 0 not merged, 0 malformed" \
    "the queue after -- must be read"
  pass "the queue runner accepts a queue file after --"
}

test_gate_gitlab_declared_no_qa_attestation_passes() {
  local case_dir rc
  case_dir=$(make_case gitlab-no-qa-green)
  write_no_qa_repos "$case_dir" group/project
  write_glab_mock "$case_dir"
  mkdir -p "$case_dir/glabfixtures"
  cat > "$case_dir/glabfixtures/mr.json" <<JSON
{"sha":"$HEAD","author":{"username":"someone"},"target_branch":"main","source_branch":"feature/x","state":"opened","merged_at":null,"description":"Closes nothing."}
JSON
  cat > "$case_dir/glabfixtures/statuses.json" <<JSON
[{"name":"PR must be raised via no-mistakes","status":"success"},{"name":"unit-tests","status":"success"}]
JSON

  set +e
  FM_PR_HOST=gitlab.example \
  FM_TEST_GLAB_FIXTURES="$case_dir/glabfixtures" \
  run_gate "$case_dir" group/project 7 "$HEAD" --forge gitlab
  rc=$?
  set -e
  expect_code 0 "$rc" "a declared no-QA repository with a green attestation must merge on GitLab"
  assert_contains "$(cat "$case_dir/out")" "no-mistakes-attestation=SUCCESS" \
    "the gate must report the attestation it verified on GitLab"
  assert_contains "$(cat "$case_dir/out")" \
    "twin check skipped for group/project#7: the develop/beta twin rule is GitHub-only" \
    "a main-targeting GitLab merge must note the skipped twin rule"
  pass "declared no-QA coverage applies on GitLab instead of a forge refusal"
}

test_gate_gitlab_qa_coverage_refuses_without_a_verdict_source() {
  local case_dir rc
  case_dir=$(make_case gitlab-qa)
  set +e
  run_gate "$case_dir" Muso-AI/project 7 "$HEAD" --forge gitlab
  rc=$?
  set -e
  expect_code 1 "$rc" "a QA-covered repository must refuse on a forge with no verdict source"
  assert_contains "$(cat "$case_dir/err")" \
    "QA-covered repo, no verdict source on this forge" \
    "the refusal must name the missing verdict source"
  assert_contains "$(cat "$case_dir/err")" "refusing to merge Muso-AI/project#7" \
    "the refusal must name the merge request"
  pass "a QA-covered repository refuses on a forge with no verdict source"
}

# A named test may be run alone, which is how the ungated-script proof in the
# pull request body was produced: each refusal case run against the script as it
# stood before this library existed.
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    "$name"
  done
  exit 0
fi

test_gate_refuses_qa_no_go
test_gate_refuses_absent_qa_verdict
test_gate_refuses_verdict_on_older_head
test_gate_refuses_red_check
test_gate_allows_adk47_credit_guard
test_gate_refuses_credit_guard_for_other_author
test_gate_refuses_unmerged_develop_twin
test_gate_allows_merged_develop_twin
test_gate_skips_twin_check_for_other_repositories
test_gate_refuses_moved_head
test_gate_refuses_unreadable_verdict
test_gate_passes_green_with_qa_go
test_gate_rejects_unrecorded_red_allow
test_gate_check_only_audits_a_merged_pull_request
test_gate_refuses_unreadable_twin_list
test_gate_refuses_unreadable_body_twin
test_gate_duplicate_qa_reports_worst_conclusion
test_gate_ignores_unrelated_issue_reference
test_gate_null_pending_qa_before_success_refuses
test_gate_cancelled_duplicate_is_superseded
test_gate_only_cancelled_run_still_refuses
test_gate_rerun_in_same_run_supersedes_failure
test_gate_failure_in_other_run_still_refuses
test_gate_ignores_develop_beta_prose
test_gate_skipped_or_neutral_qa_outranks_success
test_gate_muso_ai_without_qa_check_refuses
test_gate_muso_ai_with_qa_go_passes_without_workflow_fixture
test_gate_declared_no_qa_attestation_green_passes
test_gate_declared_no_qa_attestation_absent_refuses
test_gate_declared_no_qa_attestation_red_refuses
test_gate_undeclared_repository_refuses
test_pr_merge_undeclared_repository_override_passes_and_records
test_gate_red_check_name_with_pipe_refuses
test_pr_merge_refuses_before_merge_call
test_pr_merge_override_records_and_merges
test_go_queue_refuses_row_and_continues
test_go_queue_accepts_double_dash_separator
test_gate_gitlab_declared_no_qa_attestation_passes
test_gate_gitlab_qa_coverage_refuses_without_a_verdict_source
