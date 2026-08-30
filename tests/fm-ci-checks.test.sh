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
# The roster every classifier call below is judged against. It is a fixture
# standing in for whatever repository is under test, deliberately not this
# repository's own job names: the classifier is told what to require, and a
# roster it could recognise on its own is exactly the bug this file guards -
# a roster of one repository's job names refuses every other repository by
# construction, however green that repository genuinely is.
ROSTER='["Lint","Test coverage guard","Repo invariants"]'

# Every suite the roster requires, all green - the only rollup shape that a
# real, fully-reported CI run produces.
complete_suite() {
  printf '%s' "$ROSTER" \
    | jq -c '[.[] | {"__typename":"CheckRun","workflowName":"CI","name":.,"status":"COMPLETED","conclusion":"SUCCESS"}]'
}

# --- the classifier ---------------------------------------------------------

[ "$(fm_ci_checks_state "[]" "$ROSTER")" = none ] \
  || fail "an empty rollup must be none"
pass "a commit with no checks at all classifies as none"

# The regression this file exists for.
ONLY_BOT="[$(bot 'Greptile Review' SUCCESS)]"
GOT=$(fm_ci_checks_state "$ONLY_BOT" "$ROSTER")
[ "$GOT" = no-repo-ci ] || fail "a lone passing third-party check must be no-repo-ci, got: $GOT"
[ "$GOT" != passing ] || fail "a lone passing third-party check must never be passing"
pass "a rollup of nothing but a passing third-party bot classifies as no-repo-ci, not passing"

# Several passing third-party checks are still no evidence: the state must come
# from where the checks came from, never from how many of them passed.
MANY_BOTS="[$(bot 'Greptile Review' SUCCESS),$(bot 'Coverage' SUCCESS),$(bot 'Sizebot' SUCCESS)]"
[ "$(fm_ci_checks_state "$MANY_BOTS" "$ROSTER")" = no-repo-ci ] \
  || fail "many passing third-party checks must still be no-repo-ci"
pass "no number of passing third-party checks adds up to repository CI"

# The two shapes actually recorded on the pull requests this rule exists for,
# copied from their own statusCheckRollup rather than reconstructed, so the
# regression is pinned to what GitHub really served. Both are a lone Greptile
# check with an empty workflowName and no suite anywhere, and the defect had
# both polarities: on 2584 the bot PASSED and was read as CI passing, and on
# 2855 the bot FAILED while the run that produced it still reported passed.
# Neither may ever classify as passing, and neither is a real CI result.
PR_2584_ROLLUP='[{"__typename":"CheckRun","completedAt":"2026-08-22T23:25:48Z","conclusion":"SUCCESS","detailsUrl":"https://greptile.com/","name":"Greptile Review","startedAt":"2026-08-22T23:18:08Z","status":"COMPLETED","workflowName":""}]'
PR_2855_ROLLUP='[{"__typename":"CheckRun","completedAt":"2026-08-23T10:58:04Z","conclusion":"FAILURE","detailsUrl":"https://greptile.com/","name":"Greptile Review","startedAt":"2026-08-23T10:56:06Z","status":"COMPLETED","workflowName":""}]'

GOT=$(fm_ci_checks_state "$PR_2584_ROLLUP" "$ROSTER")
[ "$GOT" != passing ] || fail "the recorded PR 2584 rollup must never be passing"
[ "$GOT" = no-repo-ci ] || fail "the recorded PR 2584 rollup must be no-repo-ci, got: $GOT"
pass "the passing-bot rollup recorded on PR 2584 classifies as no-repo-ci, not passing"

GOT=$(fm_ci_checks_state "$PR_2855_ROLLUP" "$ROSTER")
[ "$GOT" != passing ] || fail "the recorded PR 2855 rollup must never be passing"
[ "$GOT" = no-repo-ci ] || fail "the recorded PR 2855 rollup must be no-repo-ci, got: $GOT"
pass "the failing-bot rollup recorded on PR 2855 classifies as no-repo-ci, not passing"

# A legacy commit status is not a check run and cannot stand in for a suite.
LEGACY='[{"__typename":"StatusContext","context":"ci/external","state":"SUCCESS"}]'
[ "$(fm_ci_checks_state "$LEGACY" "$ROSTER")" = no-repo-ci ] \
  || fail "a passing legacy commit status must be no-repo-ci"
pass "a legacy commit status does not count as a repository-owned suite"

# One real suite moves the answer off no-repo-ci, but one suite is not the
# whole roster: it stays incomplete, never passing, until every required
# suite has reported. The bot may still ride along either way.
WITH_SUITE="[$(suite Lint SUCCESS),$(bot 'Greptile Review' SUCCESS)]"
GOT=$(fm_ci_checks_state "$WITH_SUITE" "$ROSTER")
[ "$GOT" = incomplete ] \
  || fail "a passing repository suite short of the full roster must be incomplete, got: $GOT"
pass "a repository-owned suite short of the full roster classifies as incomplete, not passing"

# The whole required roster, every one of them green, is what actually makes
# a rollup passing. This is the P1 false-green shape reported against
# fm_ci_state: a single green CI job read as "CI ran" when most of the
# roster never reported at all.
COMPLETE_SUITE=$(complete_suite)
WITH_COMPLETE_SUITE=$(printf '%s' "$COMPLETE_SUITE" | jq -c ". + [$(bot 'Greptile Review' SUCCESS)]")
[ "$(fm_ci_checks_state "$WITH_COMPLETE_SUITE" "$ROSTER")" = passing ] \
  || fail "every required suite passing alongside a passing bot must be passing"
pass "the complete required-suite roster is what makes an all-green rollup passing"

# Missing even one required suite out of an otherwise all-green roster is
# still incomplete, not passing - conclusion-tallying alone cannot tell the
# two apart, which is exactly why fm_ci_missing_suites exists.
ALMOST_COMPLETE=$(printf '%s' "$COMPLETE_SUITE" | jq -c '.[1:]')
GOT=$(fm_ci_checks_state "$ALMOST_COMPLETE" "$ROSTER")
[ "$GOT" = incomplete ] \
  || fail "a roster missing one required suite must be incomplete, got: $GOT"
pass "a rollup missing part of the required suite roster is incomplete even when everything present is green"

# The second false-green shape: a repository-owned check that is real, but is
# not the CI workflow - the PR-body policy check can pass while ci.yml never
# produced a check at all, and that must read the same as no CI having run.
other_workflow() {
  printf '{"__typename":"CheckRun","workflowName":"%s","name":"%s","status":"COMPLETED","conclusion":"%s"}' "$1" "$2" "$3"
}
ONLY_OTHER_WORKFLOW="[$(other_workflow 'Require no-mistakes' 'PR must be raised via no-mistakes' SUCCESS)]"
GOT=$(fm_ci_checks_state "$ONLY_OTHER_WORKFLOW" "$ROSTER")
[ "$GOT" = no-repo-ci ] \
  || fail "a passing check from a repository workflow other than CI must be no-repo-ci, got: $GOT"
pass "a passing check from an unrelated repository-owned workflow is not CI having run"

# A job that finished SKIPPED, NEUTRAL, or STALE never validated anything, so a
# workflow that completed with one of those among otherwise-green jobs is a
# partially-skipped run, not a clean pass.
[ "$(fm_ci_checks_state "[$(suite Lint SUCCESS),$(suite 'Test coverage guard' SKIPPED)]" "$ROSTER")" = failing ] \
  || fail "a skipped CI job among passing ones must refuse a passing verdict"
[ "$(fm_ci_checks_state "[$(suite Lint NEUTRAL)]" "$ROSTER")" = failing ] \
  || fail "a neutral CI job must refuse a passing verdict"
[ "$(fm_ci_checks_state "[$(suite Lint STALE)]" "$ROSTER")" = failing ] \
  || fail "a stale CI job must refuse a passing verdict"
pass "a partially-skipped CI workflow is refused rather than read as passing"

# The missing-suites diagnosis is decided before red and before waiting, so it
# is never reported as one of those different problems.
[ "$(fm_ci_checks_state "[$(bot 'Greptile Review' FAILURE)]" "$ROSTER")" = no-repo-ci ] \
  || fail "a red third-party check with no suites must still be no-repo-ci"
[ "$(fm_ci_checks_state "[$(bot 'Greptile Review' null)]" "$ROSTER")" = no-repo-ci ] \
  || fail "an unfinished third-party check with no suites must still be no-repo-ci"
pass "no-repo-ci is decided ahead of failing and pending, so missing suites are never mistaken for either"

[ "$(fm_ci_checks_state "[$(suite Lint FAILURE),$(bot 'Greptile Review' SUCCESS)]" "$ROSTER")" = failing ] \
  || fail "a red repository suite must be failing"
[ "$(fm_ci_checks_state "[$(suite Lint SUCCESS),$(bot 'Greptile Review' FAILURE)]" "$ROSTER")" = failing ] \
  || fail "a red third-party check alongside passing suites must be failing, not passing"
pass "any red check refuses a passing verdict, whoever produced it"

UNFINISHED='[{"__typename":"CheckRun","workflowName":"CI","name":"Lint","status":"IN_PROGRESS","conclusion":null}]'
[ "$(fm_ci_checks_state "$UNFINISHED" "$ROSTER")" = pending ] \
  || fail "an unfinished repository suite must be pending"
pass "a suite still running classifies as pending"

# Unreadable input is refused rather than classified, so a truncated or
# malformed payload can never arrive at a passing verdict.
if fm_ci_checks_state '{"not":"an array"}' "$ROSTER" >/dev/null 2>&1; then
  fail "a non-array payload must be refused, not classified"
fi
if fm_ci_checks_state 'not json at all' "$ROSTER" >/dev/null 2>&1; then
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

# --- the roster in the workflow-runs shape ------------------------------------
#
# fm_ci_runs_state above answers only "is any CI run here red or unfinished".
# A run concludes success whenever no job in it failed, and a job that never
# ran because it was skipped does not fail, so that answer cannot establish
# that the required suites ran. The shape is real and recorded: cli/cli run
# 32701833535 concluded success with one job successful and two skipped. That
# is the P1 false-green reported against this file - a successful head-repository
# run authorizing a green claim with the roster absent - and fm_ci_run_jobs_state
# is what closes it, by judging the run JOBS against the same roster the rollup
# shape uses.
job() { printf '{"name":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3"; }
complete_jobs() {
  printf '%s' "$ROSTER" \
    | jq -c '[.[] | {name: ., status: "completed", conclusion: "success"}]'
}
GOOD_RUN="[$(run 42 completed '"success"')]"
COMPLETE_JOBS=$(complete_jobs)

# The demonstration that the run-level answer alone is the defect: the exact
# same successful run is passing to fm_ci_runs_state and refused once its jobs
# are read. Without this change the guard acts on the first answer.
[ "$(fm_ci_runs_state "$GOOD_RUN")" = passing ] \
  || fail "the run-level classifier must still call a successful CI run passing"
ONLY_LINT_JOB="[$(job Lint completed '"success"')]"
GOT=$(fm_ci_run_jobs_state "$GOOD_RUN" "$ONLY_LINT_JOB" "$ROSTER")
[ "$GOT" != passing ] || fail "a successful CI run carrying only one job must never be passing"
[ "$GOT" = incomplete ] \
  || fail "a successful CI run short of the required roster must be incomplete, got: $GOT"
pass "a successful head-repository CI run whose jobs are short of the roster is incomplete, not passing"

# The recorded cli/cli 32701833535 shape: the run succeeded, and it succeeded
# because skipped jobs do not fail a run.
SKIPPED_JOBS="[$(job Lint completed '"success"'),$(job 'Repo invariants' completed '"skipped"')]"
GOT=$(fm_ci_run_jobs_state "$GOOD_RUN" "$SKIPPED_JOBS" "$ROSTER")
[ "$GOT" != passing ] || fail "a successful CI run with a skipped job must never be passing"
pass "a successful CI run whose jobs were skipped is refused rather than read as a clean pass"

# The roster read from the jobs is what a passing verdict now rests on.
[ "$(fm_ci_run_jobs_state "$GOOD_RUN" "$COMPLETE_JOBS" "$ROSTER")" = passing ] \
  || fail "a successful CI run carrying the complete green roster must be passing"
pass "the complete required-suite roster among the run jobs is what makes a head-repository run passing"

ALMOST_JOBS=$(printf '%s' "$COMPLETE_JOBS" | jq -c '.[1:]')
[ "$(fm_ci_run_jobs_state "$GOOD_RUN" "$ALMOST_JOBS" "$ROSTER")" = incomplete ] \
  || fail "a run roster missing one required suite must be incomplete"
pass "a head-repository run missing one required suite is incomplete even when every job present is green"

# Jobs that could not be read at all are not inherited from the run conclusion.
[ "$(fm_ci_run_jobs_state "$GOOD_RUN" '[]' "$ROSTER")" = incomplete ] \
  || fail "a successful run whose jobs could not be read must be incomplete"
pass "a run whose jobs are unreadable is incomplete rather than inheriting the verdict of the run itself"

# A red or unfinished job refuses the verdict the same way the rollup does.
RED_JOBS=$(printf '%s' "$COMPLETE_JOBS" | jq -c '.[0].conclusion = "failure"')
[ "$(fm_ci_run_jobs_state "$GOOD_RUN" "$RED_JOBS" "$ROSTER")" = failing ] \
  || fail "a red job in an otherwise complete roster must be failing"
PENDING_JOBS=$(printf '%s' "$COMPLETE_JOBS" | jq -c '.[0] = {name: "Lint", status: "in_progress", conclusion: null}')
[ "$(fm_ci_run_jobs_state "$GOOD_RUN" "$PENDING_JOBS" "$ROSTER")" = pending ] \
  || fail "an unfinished job in an otherwise complete roster must be pending"
pass "a red or unfinished job refuses a passing head-repository verdict"

# The run-level states still decide first, so a red or unfinished run is never
# reported as a roster problem, and no CI run at all is still none.
[ "$(fm_ci_run_jobs_state "[$(run 42 completed '"failure"')]" "$COMPLETE_JOBS" "$ROSTER")" = failing ] \
  || fail "a red CI run must be failing whatever its jobs say"
[ "$(fm_ci_run_jobs_state "[$(run 42 in_progress null)]" "$COMPLETE_JOBS" "$ROSTER")" = pending ] \
  || fail "an unfinished CI run must be pending whatever its jobs say"
[ "$(fm_ci_run_jobs_state '[]' "$COMPLETE_JOBS" "$ROSTER")" = none ] \
  || fail "no CI run at all must be none"
[ "$(fm_ci_run_jobs_state "$ONLY_OTHER_RUN" "$COMPLETE_JOBS" "$ROSTER")" = none ] \
  || fail "a run of a workflow other than CI must not count as CI having run"
pass "the run-level states are decided before the roster, so each refusal names its own cause"

if fm_ci_run_jobs_state "$GOOD_RUN" 'not json' "$ROSTER" >/dev/null 2>&1; then
  fail "an unreadable jobs payload must be refused, not classified"
fi
if fm_ci_run_jobs_state 'not json' "$COMPLETE_JOBS" "$ROSTER" >/dev/null 2>&1; then
  fail "an unreadable runs payload must be refused, not classified"
fi
if fm_ci_run_jobs_state "$GOOD_RUN" '{"jobs":[]}' "$ROSTER" >/dev/null 2>&1; then
  fail "a non-array jobs payload must be refused, not classified"
fi
pass "an unreadable runs or jobs payload is refused instead of being classified"

# --- the guard ---------------------------------------------------------------

# gh is stubbed for every read on the path - the pull request itself, the
# roster lookup in the base repository, and the head repository workflow runs -
# so the whole path runs without a network call. An empty FM_TEST_HEAD_REPO
# means the pull request has no separate head repository, which is the
# same-repository case. The base repository is example/repo, so the roster
# reads are the ones addressed to it and the evidence reads are the rest.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/example/repo/actions/workflows/*/runs*) printf '%s\n' "${FM_TEST_CI_RUNS:-}" ;;
    repos/example/repo/actions/workflows*)        printf '%s\n' "${FM_TEST_WORKFLOWS:-}" ;;
    repos/example/repo/actions/runs/*/jobs*)      printf '%s\n' "${FM_TEST_ROSTER_JOBS:-}" ;;
    repos/example/repo)                           printf '%s\n' "${FM_TEST_REPO_META:-}" ;;
    # The evidence reads: the workflow runs at the commit in the head
    # repository, and then the jobs of each CI run among them.
    */jobs*)                                      printf '%s\n' "${FM_TEST_JOBS:-[]}" ;;
    *)                                            printf '%s\n' "${FM_TEST_RUNS:-[]}" ;;
  esac
  exit 0
fi
if [ -n "${FM_TEST_HEAD_REPO:-}" ]; then
  printf '{"statusCheckRollup":%s,"headRefOid":"%s","baseRefName":"%s","headRepositoryOwner":{"login":"%s"},"headRepository":{"name":"%s"}}\n' \
    "${FM_TEST_ROLLUP:-[]}" "${FM_TEST_SHA:-deadbeef}" "${FM_TEST_BASE_REF:-main}" \
    "${FM_TEST_HEAD_REPO%%/*}" "${FM_TEST_HEAD_REPO#*/}"
else
  printf '{"statusCheckRollup":%s,"headRefOid":"%s","baseRefName":"%s","headRepositoryOwner":null,"headRepository":null}\n' \
    "${FM_TEST_ROLLUP:-[]}" "${FM_TEST_SHA:-deadbeef}" "${FM_TEST_BASE_REF:-main}"
fi
SH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"
# The stub is a separate process, so its inputs must be exported rather than
# only set in this shell.
FM_TEST_ROLLUP='[]'
FM_TEST_RUNS='[]'
# The default head-repository run reports its whole roster green, so a test
# that is not about the roster gets the ordinary validated-fork case.
FM_TEST_JOBS=$COMPLETE_JOBS
FM_TEST_SHA=deadbeef
FM_TEST_HEAD_REPO=
FM_TEST_BASE_REF=main
# What the base repository's own CI workflow last reported on main: one
# workflow named CI, one successful run of it, and the roster of jobs that run
# carried. This is what the guard now asks the repository under test for
# instead of carrying a roster of its own.
export FM_TEST_WORKFLOWS='{"total_count":2,"workflows":[{"id":9,"name":"Require no-mistakes"},{"id":77,"name":"CI"}]}'
export FM_TEST_CI_RUNS='{"workflow_runs":[{"id":5150,"name":"CI"}]}'
export FM_TEST_ROSTER_JOBS
FM_TEST_ROSTER_JOBS=$(printf '%s' "$ROSTER" | jq -c '{total_count: length, jobs: [.[] | {name: .}]}')
export FM_TEST_REPO_META='{"default_branch":"main"}'
export PATH FM_TEST_ROLLUP FM_TEST_RUNS FM_TEST_JOBS FM_TEST_SHA FM_TEST_HEAD_REPO FM_TEST_BASE_REF

URL=https://github.com/example/repo/pull/7
verify() { "$ROOT/bin/fm-pr-ci-verify.sh" "$URL" 2>&1; }

# --- the roster the repository under test asks for ---------------------------
#
# The regression this whole change exists for: a roster held as a constant of
# one repository's job names cannot be drifted into on a second repository, it
# simply does not describe it, so every other project fails the completeness
# test by construction. fm_ci_roster reads it from the repository instead.
fm_ci_roster example/repo main || fail "a repository with a successful CI run must yield a roster"
[ "$FM_CI_ROSTER" = "$(printf '%s' "$ROSTER" | jq -c 'unique')" ] \
  || fail "the roster must be the job names of that run, got: $FM_CI_ROSTER"
assert_contains "$FM_CI_ROSTER_SOURCE" "5150" "the roster must say which run it came from"
assert_contains "$FM_CI_ROSTER_SOURCE" "example/repo" "the roster must say which repository it came from"
pass "fm_ci_roster reads the required suite roster from the repository under test"

# The proof that it is the repository's roster and not a built-in one: a second
# repository with entirely different job names yields entirely different names.
# The fixture is set and put back rather than prefixed onto the call, because a
# variable assignment in front of a FUNCTION is not reliably temporary across
# shells and a leaked fixture would quietly rewrite every test after it.
OTHER_JOBS='{"total_count":2,"jobs":[{"name":"build"},{"name":"vet"}]}'
ROSTER_JOBS_DEFAULT=$FM_TEST_ROSTER_JOBS
FM_TEST_ROSTER_JOBS=$OTHER_JOBS
fm_ci_roster example/repo main \
  || fail "a repository whose CI names nothing familiar must still yield its roster"
[ "$FM_CI_ROSTER" = '["build","vet"]' ] \
  || fail "the roster must follow the repository, got: $FM_CI_ROSTER"
FM_TEST_ROSTER_JOBS=$ROSTER_JOBS_DEFAULT
pass "a repository whose CI job names look nothing like this one still gets its own roster"

# Branch omitted: the repository's own default branch is asked for rather than
# guessed, because the roster of a branch nobody names is not this file's to
# invent.
fm_ci_roster example/repo || fail "an omitted branch must fall back to the default branch"
assert_contains "$FM_CI_ROSTER_SOURCE" "on main" "the fallback must name the branch it resolved"
pass "fm_ci_roster falls back to the repository default branch when none is named"

# Every way the lookup can come up empty is a refusal, never an empty roster:
# a caller cannot tell an empty roster apart from a repository that requires
# nothing, and against an empty roster every green rollup reads as passing.
WORKFLOWS_DEFAULT=$FM_TEST_WORKFLOWS
CI_RUNS_DEFAULT=$FM_TEST_CI_RUNS
FM_TEST_WORKFLOWS='{"total_count":1,"workflows":[{"id":9,"name":"Require no-mistakes"}]}'
fm_ci_roster example/repo main 2>/dev/null \
  && fail "a repository with no CI workflow must be refused, not given an empty roster"
[ -z "$FM_CI_ROSTER" ] || fail "a refused lookup must leave no roster behind"
FM_TEST_WORKFLOWS=$WORKFLOWS_DEFAULT

FM_TEST_CI_RUNS='{"workflow_runs":[]}'
fm_ci_roster example/repo main 2>/dev/null \
  && fail "a repository with no successful CI run must be refused"
FM_TEST_CI_RUNS=$CI_RUNS_DEFAULT

FM_TEST_ROSTER_JOBS='{"total_count":0,"jobs":[]}'
fm_ci_roster example/repo main 2>/dev/null \
  && fail "a run naming no jobs must be refused"
# One page of job names cannot describe a run with more of them, and a roster
# short of what the run actually carried can only ever grant a pass that was
# not earned.
FM_TEST_ROSTER_JOBS='{"total_count":140,"jobs":[{"name":"Lint"}]}'
fm_ci_roster example/repo main 2>/dev/null \
  && fail "a run with more jobs than one page can name must be refused, not truncated"
FM_TEST_ROSTER_JOBS=$ROSTER_JOBS_DEFAULT
pass "every roster lookup that cannot name the whole roster refuses instead of returning a short one"

# The escape hatch for the case observation cannot serve: a change that
# deliberately adds or removes a CI job, whose branch is judged against a
# roster the target branch has not recorded yet.
FM_CI_REQUIRED_SUITES='["only-this"]'
fm_ci_roster example/repo main || fail "an explicit roster override must be honoured"
[ "$FM_CI_ROSTER" = '["only-this"]' ] || fail "the override must be the roster, got: $FM_CI_ROSTER"
FM_CI_REQUIRED_SUITES='"Lint"'
fm_ci_roster example/repo main 2>/dev/null \
  && fail "an override that is not an array of job names must be refused"
unset FM_CI_REQUIRED_SUITES
pass "FM_CI_REQUIRED_SUITES overrides the lookup, and a malformed override is refused"

# A repository whose roster cannot be established is refused outright rather
# than judged against somebody else's, even with a rollup that is entirely
# green.
FM_TEST_ROLLUP=$(complete_suite)
FM_TEST_WORKFLOWS='{"total_count":0,"workflows":[]}'
OUT=$(verify); CODE=$?
FM_TEST_WORKFLOWS=$WORKFLOWS_DEFAULT
[ "$CODE" = 1 ] || fail "an unestablished roster must refuse a verdict, exited $CODE: $OUT"
assert_contains "$OUT" "could not establish what example/repo requires" \
  "the refusal must say the standard is missing, not that the checks failed"
assert_not_contains "$OUT" "validated:" "an unestablished roster must never produce a green verdict"
pass "fm-pr-ci-verify.sh refuses a pull request whose repository roster it could not establish"

# The whole verdict, driven off the repository's own roster end to end.
FM_TEST_ROLLUP=$(printf '%s' "$OTHER_JOBS" \
  | jq -c '[.jobs[] | {"__typename":"CheckRun",workflowName:"CI",name:.name,status:"COMPLETED",conclusion:"SUCCESS"}]')
FM_TEST_ROSTER_JOBS=$OTHER_JOBS
OUT=$(verify); CODE=$?
[ "$CODE" = 0 ] || fail "a repository green against its own roster must be accepted, exited $CODE: $OUT"
assert_contains "$OUT" "required suites: 2" "the verdict must say how many suites the roster held"
assert_contains "$OUT" "run 5150" "the verdict must name where the roster came from"
pass "fm-pr-ci-verify.sh accepts a repository whose own two-job roster ran and passed"

# The same repository one job short of its own roster: still refused, so the
# completeness rule survives the roster becoming the repository's.
FM_TEST_ROLLUP='[{"__typename":"CheckRun","workflowName":"CI","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "a rollup short of the repository roster must be refused, exited $CODE: $OUT"
assert_contains "$OUT" "vet" "the refusal must name the repository job that never reported"
FM_TEST_ROSTER_JOBS=$ROSTER_JOBS_DEFAULT
pass "a rollup short of the repository own roster is still incomplete, not passing"

# The rest of the guard is not about roster discovery, so it states the roster
# it is testing against outright through the documented override.
FM_TEST_ROLLUP='[]'
export FM_CI_REQUIRED_SUITES=$ROSTER

# The regression, end to end: a lone third-party pass with nothing behind it.
FM_TEST_ROLLUP="$ONLY_BOT"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "the guard must refuse a lone third-party pass, exited $CODE"
assert_contains "$OUT" "no-repo-ci" "the refusal must name the state"
assert_contains "$OUT" "Greptile Review" "the refusal must name the check it did see"
assert_contains "$OUT" "0 repository-owned" "the refusal must say how many suites it found"
pass "fm-pr-ci-verify.sh refuses a pull request whose only check is a third-party bot"

FM_TEST_ROLLUP="$WITH_COMPLETE_SUITE"
OUT=$(verify); CODE=$?
[ "$CODE" = 0 ] || fail "the guard must accept the complete required-suite roster, exited $CODE: $OUT"
assert_contains "$OUT" "validated" "the accepting run must state the verdict"
assert_contains "$OUT" "Lint" "the roster must name the suite that ran"
pass "fm-pr-ci-verify.sh accepts a pull request whose own suites ran and passed"

# A rollup short of the complete roster is not evidence either, even though
# every check it does carry is green - this is the P1 false-green shape
# reported against fm-pr-ci-verify.sh: a lone passing CI job authorizing a
# validation verdict without establishing the rest of the roster ran.
FM_TEST_ROLLUP="$WITH_SUITE"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "the guard must refuse a rollup short of the required roster, exited $CODE: $OUT"
assert_contains "$OUT" "incomplete" "the refusal must name the incomplete state"
assert_contains "$OUT" "required suite roster" "the refusal must say the roster is incomplete"
assert_contains "$OUT" "missing required suites" "the refusal must list what is missing"
assert_contains "$OUT" "Test coverage guard" "the missing-suites list must name a suite that never reported"
pass "fm-pr-ci-verify.sh refuses a pull request whose rollup is short of the required suite roster"

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

# incomplete falls through to the head repository exactly like no-repo-ci: a
# rollup short of the required roster is not evidence either, but the fork
# may still have validated the commit in full.
FM_TEST_ROLLUP="$WITH_SUITE"
FM_TEST_RUNS="[$(run 42 completed '"success"')]"
OUT=$(verify); CODE=$?
[ "$CODE" = 0 ] || fail "an incomplete base-repo rollup must still fall through to a validated fork run, exited $CODE: $OUT"
assert_contains "$OUT" "example/fork" "the verdict must name the repository the evidence came from"
assert_contains "$OUT" "checks do not cover the required suite roster" \
  "the verdict must say why the base repository was not evidence"
pass "fm-pr-ci-verify.sh falls through an incomplete base-repo rollup to a validated head-repository run"

# The head-repository false green, end to end: the upstream pull request has
# only the bot, the fork run concluded success, and its roster is a single job.
# Before the roster was read from the jobs this exited 0 and reported the commit
# validated - the P1 finding against this guard.
FM_TEST_ROLLUP="$ONLY_BOT"
FM_TEST_RUNS="$GOOD_RUN"
FM_TEST_JOBS="$ONLY_LINT_JOB"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "a successful fork run short of the roster must be refused, exited $CODE: $OUT"
assert_contains "$OUT" "incomplete" "the refusal must name the incomplete fork state"
assert_contains "$OUT" "required suite roster" "the refusal must say the fork roster is short"
assert_contains "$OUT" "Test coverage guard" "the refusal must name a required suite that never ran"
assert_not_contains "$OUT" "validated:" "a roster-short fork run must not be reported as validated"
pass "fm-pr-ci-verify.sh refuses a successful head-repository run whose jobs are short of the required roster"

# The same run with a skipped job: still success at the run level, still refused.
FM_TEST_JOBS="$SKIPPED_JOBS"
OUT=$(verify); CODE=$?
[ "$CODE" = 1 ] || fail "a fork run with a skipped job must be refused, exited $CODE: $OUT"
assert_not_contains "$OUT" "validated:" "a partially-skipped fork run must not be reported as validated"
pass "fm-pr-ci-verify.sh refuses a head-repository run that concluded success with a skipped job"

# The recorded pull requests, driven through the whole guard. 2584 is the
# passing bot and 2855 the failing one; with nothing behind either, both are
# refused, and neither may be reported as validated.
FM_TEST_JOBS='[]'
FM_TEST_RUNS='[]'
for recorded in "$PR_2584_ROLLUP" "$PR_2855_ROLLUP"; do
  FM_TEST_ROLLUP=$recorded
  OUT=$(verify); CODE=$?
  [ "$CODE" = 1 ] || fail "a recorded lone-bot pull request must be refused, exited $CODE: $OUT"
  assert_contains "$OUT" "Greptile Review" "the refusal must name the check it did see"
  assert_not_contains "$OUT" "validated:" "a lone-bot pull request must never be reported as validated"
done
pass "fm-pr-ci-verify.sh refuses both recorded lone-bot pull requests, whichever way the bot concluded"

FM_TEST_JOBS=$COMPLETE_JOBS
FM_TEST_ROLLUP="$ONLY_BOT"
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
