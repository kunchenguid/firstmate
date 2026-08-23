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
# carries workflow runs, which are that repository's own by construction, so
# fm_ci_runs_state classifies those without needing to tell producers apart.
# The second shape is what answers "did MY fork validate this commit?" when the
# first shape says the upstream pull request has no repository check on it.
#
# States, in the order the classifier decides them:
#   none        the commit carries no checks at all
#   no-repo-ci  checks exist, but none of them came from this repository
#   failing     at least one check reached a red conclusion
#   pending     at least one check has not finished
#   passing     this repository's own checks ran and every check succeeded
#
# failing and pending are judged over EVERY check, not only the repository's
# own, so a red third-party check refuses a green verdict instead of hiding
# behind the suites that passed. Deciding no-repo-ci before either of them keeps
# the missing-suites diagnosis from being reported as an ordinary red or an
# ordinary wait, which are different problems with different fixes.

# jq function definitions. Prepend to a jq program; the program then calls
# fm_ci_state on an array of statusCheckRollup entries.
# $all and $own are jq variables, deliberately not shell expansions.
# shellcheck disable=SC2016
FM_CI_CHECKS_JQ_DEFS='
def fm_ci_repo_owned:
  ((.__typename // "") == "CheckRun") and (((.workflowName // "") | tostring) != "");
def fm_ci_check_red:
  (((.conclusion // .state // "") | tostring | ascii_upcase)) as $s
  | $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "CANCELLED"
    or $s == "ACTION_REQUIRED" or $s == "STARTUP_FAILURE";
def fm_ci_check_unfinished:
  (((.status // "") | tostring | ascii_upcase) != "COMPLETED")
  and (((.state // "") | tostring | ascii_upcase) != "SUCCESS");
def fm_ci_state:
  (. // []) as $all
  | [$all[] | select(fm_ci_repo_owned)] as $own
  | if ($all | length) == 0 then "none"
    elif ($own | length) == 0 then "no-repo-ci"
    elif any($all[]; fm_ci_check_red) then "failing"
    elif any($all[]; fm_ci_check_unfinished) then "pending"
    else "passing" end;
def fm_ci_run_red:
  (((.conclusion // "") | tostring | ascii_downcase)) as $c
  | $c == "failure" or $c == "cancelled" or $c == "timed_out"
    or $c == "action_required" or $c == "startup_failure" or $c == "stale";
def fm_ci_run_unfinished:
  ((.status // "") | tostring | ascii_downcase) != "completed";
def fm_ci_runs_state:
  (. // []) as $runs
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
# in that array came from the repository it was read from, so there is no
# producer to tell apart here.
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
