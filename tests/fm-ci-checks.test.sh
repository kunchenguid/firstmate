#!/usr/bin/env bash
# tests/fm-ci-checks.test.sh - the rule that a check list is only green when
# this repository's own suites are in it.
#
# Two interfaces, one rule (bin/fm-ci-checks-lib.sh): the classifier every
# reader shares, and bin/fm-pr-ci-verify.sh, the guard run before calling a pull
# request green. The case that matters is the one that produced three false
# green verdicts in practice: a pull request whose only check is a third-party
# review bot reporting success, which counts as "1 passed, 0 failed" to anything
# that only tallies conclusions.
#
# The guard also has to accept the case those three were really in: an upstream
# pull request with no suite of its own because GitHub is holding the run, whose
# commit the head repository already validated on the branch push. That has to
# come back green, and it has to say which repository the evidence came from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-ci-checks-lib.sh"

TMP=$(fm_test_tmproot fm-ci-checks)
FAKEBIN=$(fm_fakebin "$TMP")

# A GitHub Actions check run records the workflow that produced it; a check run
# created by a third-party App has no workflow behind it and so no name.
suite() {
  printf '{"__typename":"CheckRun","workflowName":"CI","name":"%s","status":"COMPLETED","conclusion":"%s"}' "$1" "$2"
}
bot() {
  printf '{"__typename":"CheckRun","workflowName":"","name":"%s","status":"COMPLETED","conclusion":"%s"}' "$1" "$2"
}

# --- the classifier ---------------------------------------------------------

[ "$(fm_ci_checks_state "[]")" = none ] \
  || fail "an empty rollup must be none"
pass "a commit with no checks at all classifies as none"

# The regression this file exists for.
ONLY_BOT="[$(bot 'Greptile Review' SUCCESS)]"
GOT=$(fm_ci_checks_state "$ONLY_BOT")
[ "$GOT" = no-repo-ci ] || fail "a lone passing third-party check must be no-repo-ci, got: $GOT"
[ "$GOT" != passing ] || fail "a lone passing third-party check must never be passing"
pass "a rollup of nothing but a passing third-party bot classifies as no-repo-ci, not passing"

# Several passing third-party checks are still no evidence: the state must come
# from where the checks came from, never from how many of them passed.
MANY_BOTS="[$(bot 'Greptile Review' SUCCESS),$(bot 'Coverage' SUCCESS),$(bot 'Sizebot' SUCCESS)]"
[ "$(fm_ci_checks_state "$MANY_BOTS")" = no-repo-ci ] \
  || fail "many passing third-party checks must still be no-repo-ci"
pass "no number of passing third-party checks adds up to repository CI"

# A legacy commit status is not a check run and cannot stand in for a suite.
LEGACY='[{"__typename":"StatusContext","context":"ci/external","state":"SUCCESS"}]'
[ "$(fm_ci_checks_state "$LEGACY")" = no-repo-ci ] \
  || fail "a passing legacy commit status must be no-repo-ci"
pass "a legacy commit status does not count as a repository-owned suite"

# One real suite is what changes the answer, and the bot may ride along.
WITH_SUITE="[$(suite Lint SUCCESS),$(bot 'Greptile Review' SUCCESS)]"
[ "$(fm_ci_checks_state "$WITH_SUITE")" = passing ] \
  || fail "a passing repository suite alongside a passing bot must be passing"
pass "a repository-owned suite is what makes an all-green rollup passing"

# The second false-green shape: a repository-owned check that is real, but is
# not the CI workflow - the PR-body policy check can pass while ci.yml never
# produced a check at all, and that must read the same as no CI having run.
other_workflow() {
  printf '{"__typename":"CheckRun","workflowName":"%s","name":"%s","status":"COMPLETED","conclusion":"%s"}' "$1" "$2" "$3"
}
ONLY_OTHER_WORKFLOW="[$(other_workflow 'Require no-mistakes' 'PR must be raised via no-mistakes' SUCCESS)]"
GOT=$(fm_ci_checks_state "$ONLY_OTHER_WORKFLOW")
[ "$GOT" = no-repo-ci ] \
  || fail "a passing check from a repository workflow other than CI must be no-repo-ci, got: $GOT"
pass "a passing check from an unrelated repository-owned workflow is not CI having run"

# A job that finished SKIPPED, NEUTRAL, or STALE never validated anything, so a
# workflow that completed with one of those among otherwise-green jobs is a
# partially-skipped run, not a clean pass.
[ "$(fm_ci_checks_state "[$(suite Lint SUCCESS),$(suite 'Test coverage guard' SKIPPED)]")" = failing ] \
  || fail "a skipped CI job among passing ones must refuse a passing verdict"
[ "$(fm_ci_checks_state "[$(suite Lint NEUTRAL)]")" = failing ] \
  || fail "a neutral CI job must refuse a passing verdict"
[ "$(fm_ci_checks_state "[$(suite Lint STALE)]")" = failing ] \
  || fail "a stale CI job must refuse a passing verdict"
pass "a partially-skipped CI workflow is refused rather than read as passing"

# The missing-suites diagnosis is decided before red and before waiting, so it
# is never reported as one of those different problems.
[ "$(fm_ci_checks_state "[$(bot 'Greptile Review' FAILURE)]")" = no-repo-ci ] \
  || fail "a red third-party check with no suites must still be no-repo-ci"
[ "$(fm_ci_checks_state "[$(bot 'Greptile Review' null)]")" = no-repo-ci ] \
  || fail "an unfinished third-party check with no suites must still be no-repo-ci"
pass "no-repo-ci is decided ahead of failing and pending, so missing suites are never mistaken for either"

[ "$(fm_ci_checks_state "[$(suite Lint FAILURE),$(bot 'Greptile Review' SUCCESS)]")" = failing ] \
  || fail "a red repository suite must be failing"
[ "$(fm_ci_checks_state "[$(suite Lint SUCCESS),$(bot 'Greptile Review' FAILURE)]")" = failing ] \
  || fail "a red third-party check alongside passing suites must be failing, not passing"
pass "any red check refuses a passing verdict, whoever produced it"

UNFINISHED='[{"__typename":"CheckRun","workflowName":"CI","name":"Lint","status":"IN_PROGRESS","conclusion":null}]'
[ "$(fm_ci_checks_state "$UNFINISHED")" = pending ] \
  || fail "an unfinished repository suite must be pending"
pass "a suite still running classifies as pending"

# Unreadable input is refused rather than classified, so a truncated or
# malformed payload can never arrive at a passing verdict.
if fm_ci_checks_state '{"not":"an array"}' >/dev/null 2>&1; then
  fail "a non-array payload must be refused, not classified"
fi
if fm_ci_checks_state 'not json at all' >/dev/null 2>&1; then
  fail "unparseable input must be refused, not classified"
fi
pass "an unreadable rollup is refused instead of being classified"

# --- the same question in the workflow-runs shape ----------------------------

# A repository can own more than one workflow, so this shape still narrows to
# the CI workflow's own runs by name before judging red, pending, or passing.
run() { printf '{"id":%s,"name":"CI","status":"%s","conclusion":%s,"event":"push"}' "$1" "$2" "$3"; }
named_run() { printf '{"id":%s,"name":"%s","status":"%s","conclusion":%s,"event":"push"}' "$1" "$2" "$3" "$4"; }

[ "$(fm_ci_runs_state '[]')" = none ] || fail "no workflow runs must be none"
[ "$(fm_ci_runs_state "[$(run 1 completed '"success"')]")" = passing ] \
  || fail "a successful workflow run must be passing"
[ "$(fm_ci_runs_state "[$(run 1 completed '"failure"')]")" = failing ] \
  || fail "a failed workflow run must be failing"
[ "$(fm_ci_runs_state "[$(run 1 completed '"cancelled"')]")" = failing ] \
  || fail "a cancelled workflow run must be failing"
[ "$(fm_ci_runs_state "[$(run 1 in_progress null)]")" = pending \
  ] || fail "an unfinished workflow run must be pending"
[ "$(fm_ci_runs_state "[$(run 1 completed '"success"'),$(run 2 completed '"failure"')]")" = failing ] \
  || fail "one failed run among successes must be failing"
pass "fm_ci_runs_state classifies a repository own workflow runs at a commit"

# A successful run of some OTHER repository workflow is not evidence the CI
# workflow ran - the same false-green shape as the rollup's unrelated check.
ONLY_OTHER_RUN="[$(named_run 1 'Require no-mistakes' completed '"success"')]"
[ "$(fm_ci_runs_state "$ONLY_OTHER_RUN")" = none ] \
  || fail "a passing run of a workflow other than CI must not count as CI having run"
[ "$(fm_ci_runs_state "[$(named_run 1 'Require no-mistakes' completed '"success"'),$(run 2 completed '"success"')]")" = passing ] \
  || fail "a passing CI run must still be passing alongside an unrelated workflow's run"
pass "fm_ci_runs_state ignores runs from workflows other than CI"

# A run that completed with a skipped or neutral conclusion never validated
# anything and must not be read as a clean pass.
[ "$(fm_ci_runs_state "[$(run 1 completed '"skipped"')]")" = failing ] \
  || fail "a skipped CI run must refuse a passing verdict"
[ "$(fm_ci_runs_state "[$(run 1 completed '"neutral"')]")" = failing ] \
  || fail "a neutral CI run must refuse a passing verdict"
pass "fm_ci_runs_state refuses a skipped or neutral CI run"

if fm_ci_runs_state '{"workflow_runs":[]}' >/dev/null 2>&1; then
  fail "a non-array runs payload must be refused, not classified"
fi
pass "an unreadable workflow-runs payload is refused instead of being classified"

# --- the guard ---------------------------------------------------------------

# gh is stubbed for both reads the guard makes - the pull request itself and the
# head repository workflow runs - so the whole path runs without a network call.
# An empty FM_TEST_HEAD_REPO means the pull request has no separate head
# repository, which is the same-repository case.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  printf '%s\n' "${FM_TEST_RUNS:-[]}"
  exit 0
fi
if [ -n "${FM_TEST_HEAD_REPO:-}" ]; then
  printf '{"statusCheckRollup":%s,"headRefOid":"%s","headRepositoryOwner":{"login":"%s"},"headRepository":{"name":"%s"}}\n' \
    "${FM_TEST_ROLLUP:-[]}" "${FM_TEST_SHA:-deadbeef}" \
    "${FM_TEST_HEAD_REPO%%/*}" "${FM_TEST_HEAD_REPO#*/}"
else
  printf '{"statusCheckRollup":%s,"headRefOid":"%s","headRepositoryOwner":null,"headRepository":null}\n' \
    "${FM_TEST_ROLLUP:-[]}" "${FM_TEST_SHA:-deadbeef}"
fi
SH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"
# The stub is a separate process, so its inputs must be exported rather than
# only set in this shell.
FM_TEST_ROLLUP='[]'
FM_TEST_RUNS='[]'
FM_TEST_SHA=deadbeef
FM_TEST_HEAD_REPO=
export PATH FM_TEST_ROLLUP FM_TEST_RUNS FM_TEST_SHA FM_TEST_HEAD_REPO

URL=https://github.com/example/repo/pull/7
verify() { "$ROOT/bin/fm-pr-ci-verify.sh" "$URL" 2>&1; }

# The regression, end to end: a lone third-party pass with nothing behind it.
FM_TEST_ROLLUP="$ONLY_BOT"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "the guard must refuse a lone third-party pass, exited $CODE"
assert_contains "$OUT" "no-repo-ci" "the refusal must name the state"
assert_contains "$OUT" "Greptile Review" "the refusal must name the check it did see"
assert_contains "$OUT" "0 repository-owned" "the refusal must say how many suites it found"
pass "fm-pr-ci-verify.sh refuses a pull request whose only check is a third-party bot"

FM_TEST_ROLLUP="$WITH_SUITE"
OUT=$(verify); CODE=$?
[ "$CODE" = 0 ] || fail "the guard must accept a passing repository suite, exited $CODE: $OUT"
assert_contains "$OUT" "validated" "the accepting run must state the verdict"
assert_contains "$OUT" "Lint" "the roster must name the suite that ran"
pass "fm-pr-ci-verify.sh accepts a pull request whose own suites ran and passed"

FM_TEST_ROLLUP="[$(suite Lint FAILURE)]"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "the guard must refuse a red suite, exited $CODE"
assert_contains "$OUT" "failing" "the refusal must name the failing state"
pass "fm-pr-ci-verify.sh refuses a red suite"

FM_TEST_ROLLUP='[]'
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "the guard must refuse a commit with no checks, exited $CODE"
pass "fm-pr-ci-verify.sh refuses a pull request carrying no checks"

# --- the held-upstream-run case the three stuck pull requests were in --------

FM_TEST_HEAD_REPO=example/fork
FM_TEST_ROLLUP="$ONLY_BOT"
FM_TEST_RUNS="[$(run 42 completed '"success"')]"
OUT=$(verify); CODE=$?
[ "$CODE" = 0 ] || fail "a commit the head repository validated must be accepted, exited $CODE: $OUT"
assert_contains "$OUT" "example/fork" "the verdict must name the repository the evidence came from"
assert_contains "$OUT" "42" "the verdict must name the run behind it"
assert_contains "$OUT" "validated" "the verdict must state that the commit was validated"
pass "fm-pr-ci-verify.sh accepts a commit the head repository validated while the upstream run is held"

# The evidence is not laundered: a fork-validated commit must never be reported
# as the upstream pull request having been checked.
assert_contains "$OUT" "no example/repo suite ran on this commit" \
  "the verdict must still say the base repository ran nothing"
pass "a fork-validated verdict still states that the base repository ran no suite of its own"

FM_TEST_RUNS="[$(run 42 completed '"failure"')]"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "a red head-repository run must be refused, exited $CODE"
assert_contains "$OUT" "failing" "the refusal must name the failing head-repository state"
pass "fm-pr-ci-verify.sh refuses a commit whose head-repository run failed"

FM_TEST_RUNS="[$(run 42 in_progress null)]"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "an unfinished head-repository run must be refused, exited $CODE"
assert_contains "$OUT" "pending" "the refusal must name the pending head-repository state"
pass "fm-pr-ci-verify.sh refuses a commit whose head-repository run has not finished"

FM_TEST_RUNS='[]'
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "no run in either repository must be refused, exited $CODE"
assert_contains "$OUT" "example/fork" "the refusal must name where the branch should be pushed"
pass "fm-pr-ci-verify.sh refuses a commit no repository has validated and says where to run it"

# A red or unfinished upstream suite is a real result about the commit, so the
# head repository is never consulted in the hope that it disagrees.
FM_TEST_ROLLUP="[$(suite Lint FAILURE)]"
FM_TEST_RUNS="[$(run 42 completed '"success"')]"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "a passing fork run must not overturn a red upstream suite, exited $CODE"
assert_not_contains "$OUT" "example/fork" "a red upstream suite must not fall through to the head repository"
pass "a passing head-repository run never overturns a red suite in the base repository"

# --- input the guard refuses to interpret ------------------------------------

FM_TEST_HEAD_REPO=
OUT=$("$ROOT/bin/fm-pr-ci-verify.sh" "https://gitlab.com/group/proj/-/merge_requests/3" 2>&1); CODE=$?
[ "$CODE" = 2 ] || fail "a GitLab merge request must be refused as unreadable input, exited $CODE"
pass "fm-pr-ci-verify.sh refuses a GitLab merge request rather than misreading it"

OUT=$("$ROOT/bin/fm-pr-ci-verify.sh" "not-a-url" 2>&1); CODE=$?
[ "$CODE" = 2 ] || fail "a malformed URL must exit 2, exited $CODE"
pass "fm-pr-ci-verify.sh refuses a malformed pull request URL"
