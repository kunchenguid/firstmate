# shellcheck shell=bash
# Shared classification of a pull request's checks.
# Usage: . bin/fm-ci-checks-lib.sh; jq "$FM_CI_CHECKS_JQ_DEFS"'<program>'
#
# ONE OWNER for the question "did this repository's own suites actually run and
# pass on this commit?". Everything that reads a pull request's checks and turns
# them into a verdict - bin/fm-pr-ci-verify.sh for a single pull request,
# bin/fm-bearings-snapshot.sh for the bearings PR rows - classifies through the
# jq functions below, so the two can never disagree about what green means.
#
# The rule that makes this file necessary: an all-green check list is NOT
# evidence that this repository validated anything. A repository can receive
# check runs from third-party GitHub Apps - review bots, coverage services -
# that report on every commit whether or not a single workflow of this
# repository's own ever started. GitHub also holds a fork contributor's upstream
# workflow runs until a maintainer approves them, so a pull request from a fork
# routinely carries a third-party bot's pass and nothing else. Read as a total,
# that list is "1 passed, 0 failed, 1 total" - indistinguishable from success to
# anything that only counts passes and failures, and the reason a green verdict
# was reported three times for pull requests whose suites had never run.
#
# The discriminator is structural rather than a bot name to keep up to date:
# GitHub records the workflow that produced a check run in workflowName, and
# only GitHub Actions check runs have one. A check run created by a third-party
# App has no workflow run behind it and so carries no workflow name at all, and
# a legacy commit status (StatusContext) is not a check run in the first place.
# A rollup with no repository-owned check therefore reports no-repo-ci, which is
# a distinct state from passing and from an empty rollup's none, and no caller
# can collapse it into success by counting conclusions.
#
# GitHub offers this evidence in two shapes and the file owns both. A pull
# request carries a check rollup, which mixes everyone's checks together and so
# needs the workflowName discriminator above. A commit in a given repository
# carries workflow runs, which are that repository's own by construction, but
# still mix every workflow the repository owns together - the CI workflow
# alongside a PR-body policy check or a manually dispatched spike - so
# fm_ci_runs_state applies the same by-name filter to that shape too, rather
# than accepting any repository-owned run as a stand-in for the one that
# actually ran the suites. The second shape is what answers "did MY fork
# validate this commit?" when the first shape says the upstream pull request
# has no repository check on it.
#
# States, in the order the classifier decides them:
#   none        the commit carries no checks at all
#   no-repo-ci  checks exist, but the CI workflow itself never produced one
#   failing     at least one check reached a red conclusion
#   pending     at least one check has not finished
#   incomplete  the CI workflow reported, and everything it reported succeeded,
#               but fewer than its full required roster of suites is in there
#   passing     the CI workflow ran and every required suite succeeded
#
# failing and pending are judged over EVERY check, not only the repository's
# own, so a red third-party check refuses a green verdict instead of hiding
# behind the suites that passed. Deciding no-repo-ci before either of them keeps
# the missing-suites diagnosis from being reported as an ordinary red or an
# ordinary wait, which are different problems with different fixes.
#
# One green CI check is not the same claim as "CI ran": a rollup can carry a
# single passing Lint job because that is genuinely all that ran - the rest of
# the workflow's jobs never started or never reported - and read exactly like
# "1 passed, 0 failed" to anything that only tallies conclusions, the same
# false-green shape the no-repo-ci and other-workflow cases above already
# guard against. fm_ci_required_suites is the fix: the full job roster
# .github/workflows/ci.yml is expected to report, by the display name GitHub
# renders for each job (matrix jobs expanded, one name per shard). A rollup
# missing any of them is incomplete rather than passing, even when every check
# it does carry is green. incomplete is deliberately its own state rather than
# folded into no-repo-ci, because the two are different findings - "nothing of
# ours ran" against "some of ours ran, not all of it" - but a caller that only
# trusts "passing" is safe either way, and fm-pr-ci-verify.sh treats both the
# same: neither is evidence, so it falls through to ask the head repository.
#
# "Repository-owned" alone is not enough evidence: a commit can carry a
# passing check from some OTHER workflow this repository owns (the PR-body
# policy check in .github/workflows/no-mistakes-required.yml, a manually
# dispatched spike) while .github/workflows/ci.yml - the workflow whose jobs
# are the actual suites - never ran on it at all, because it did not trigger
# or its job graph failed to expand. That reads as "1 passed, 0 failed" to
# anything that only checks "is some repository check green", which is the
# same false-green shape as a third-party bot, just from inside the
# repository instead of outside it. fm_ci_workflow_name names the one
# workflow whose run is the actual evidence, and both classifiers require it
# by name rather than accepting any repository-owned check as a stand-in.
#
# A check or run that finished as SKIPPED, NEUTRAL, or STALE is also refused
# rather than treated as passing: those conclusions mean the job never
# actually validated anything, so a CI run that completed with one of its
# jobs in that state is a partially-skipped workflow, not a clean pass.

# The complete roster this repository's CI workflow (.github/workflows/ci.yml)
# reports for every commit it validates, by the display name GitHub renders
# for each job - matrix jobs expanded, one name per shard. Kept in sync with
# that file by hand: a job ci.yml gains, loses, or renames must be mirrored
# here, or a rollup missing the new job would still read as passing.
FM_CI_REQUIRED_SUITES='[
  "Lint",
  "Test coverage guard",
  "Behavior portable parallel 1",
  "Behavior portable parallel 2",
  "Behavior portable serial 1",
  "Behavior portable serial 2",
  "Behavior portable serial 3",
  "Behavior portable serial 4",
  "Behavior tests (Herdr)",
  "Behavior timing aggregate",
  "Stock macOS Bash snapshot compatibility",
  "Repo invariants"
]'

# jq function definitions. Prepend to a jq program; the program then calls
# fm_ci_state on an array of statusCheckRollup entries.
# $all and $own are jq variables, deliberately not shell expansions.
# shellcheck disable=SC2016
FM_CI_CHECKS_JQ_DEFS='
def fm_ci_workflow_name: "CI";
def fm_ci_required_suites: '"$FM_CI_REQUIRED_SUITES"';
def fm_ci_repo_owned:
  ((.__typename // "") == "CheckRun") and (((.workflowName // "") | tostring) != "");
def fm_ci_from_ci_workflow:
  fm_ci_repo_owned and (((.workflowName // "") | tostring) == fm_ci_workflow_name);
def fm_ci_check_red:
  (((.conclusion // .state // "") | tostring | ascii_upcase)) as $s
  | $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "CANCELLED"
    or $s == "ACTION_REQUIRED" or $s == "STARTUP_FAILURE" or $s == "SKIPPED"
    or $s == "NEUTRAL" or $s == "STALE";
def fm_ci_check_unfinished:
  (((.status // "") | tostring | ascii_upcase) != "COMPLETED")
  and (((.state // "") | tostring | ascii_upcase) != "SUCCESS");
def fm_ci_missing_suites:
  (. // []) as $all
  | ([$all[] | select(fm_ci_from_ci_workflow) | ((.name // .context // "") | tostring)] | unique) as $ci_names
  | fm_ci_required_suites - $ci_names;
def fm_ci_state:
  (. // []) as $all
  | [$all[] | select(fm_ci_from_ci_workflow)] as $ci
  | if ($all | length) == 0 then "none"
    elif ($ci | length) == 0 then "no-repo-ci"
    elif any($all[]; fm_ci_check_red) then "failing"
    elif any($all[]; fm_ci_check_unfinished) then "pending"
    elif (($all | fm_ci_missing_suites) | length) > 0 then "incomplete"
    else "passing" end;
# No fm_ci_missing_suites counterpart here: a workflow run entry is an
# aggregate GitHub computes over the full job graph scheduled for that run -
# it cannot conclude "success" while any job in it is still missing,
# unfinished, or red - so the roster is already enforced by the platform for
# this shape. The rollup shape above has no such guarantee: a
# statusCheckRollup entry is one job check run, so a rollup that never
# received a job check run is structurally missing evidence, not
# disagreeing with it.
def fm_ci_run_from_ci_workflow:
  ((.name // "") | tostring) == fm_ci_workflow_name;
def fm_ci_run_red:
  (((.conclusion // "") | tostring | ascii_downcase)) as $c
  | $c == "failure" or $c == "cancelled" or $c == "timed_out"
    or $c == "action_required" or $c == "startup_failure" or $c == "stale"
    or $c == "skipped" or $c == "neutral";
def fm_ci_run_unfinished:
  ((.status // "") | tostring | ascii_downcase) != "completed";
def fm_ci_runs_state:
  (. // []) as $all
  | [$all[] | select(fm_ci_run_from_ci_workflow)] as $runs
  | if ($runs | length) == 0 then "none"
    elif any($runs[]; fm_ci_run_red) then "failing"
    elif any($runs[]; fm_ci_run_unfinished) then "pending"
    else "passing" end;
'

# fm_ci_checks_state <rollup-json>: print the state of one statusCheckRollup
# array. Unreadable input is refused rather than classified, so a malformed or
# truncated payload can never be reported as passing.
fm_ci_checks_state() {
  fm_ci_classify "$1" fm_ci_state
}

# fm_ci_runs_state <workflow-runs-json>: print the state of one repository's own
# workflow runs at a commit, refusing unreadable input the same way. Every run
# in that array came from the repository it was read from, but a repository
# can own more than one workflow, so this still narrows to the CI workflow's
# own runs before judging red, pending, or passing.
fm_ci_runs_state() {
  fm_ci_classify "$1" fm_ci_runs_state
}

fm_ci_classify() {
  local payload=$1 fn=$2 state
  state=$(printf '%s' "$payload" | jq -r "$FM_CI_CHECKS_JQ_DEFS"'
    if type == "array" then '"$fn"' else error("payload is not an array") end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}
