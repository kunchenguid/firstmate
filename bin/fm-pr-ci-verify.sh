#!/usr/bin/env bash
# Establish that a pull request's change was actually validated by repository
# suites, and refuse every outcome that only looks like it was.
# This is the check to run before reporting a pull request green, and the reason
# an all-green check LIST is never enough on its own: bin/fm-ci-checks-lib.sh
# owns why, and owns the classification itself.
#
# Two places can hold that evidence, and this script reads both in order:
#
#   1. The pull request's own checks, in the repository it targets. When those
#      include this repository's suites and everything passed, that is the
#      answer and nothing else is consulted.
#   2. Failing that, the head repository - your fork - at the same commit.
#      GitHub holds a fork contributor's upstream workflow runs until a
#      maintainer approves them, so an unapproved pull request routinely carries
#      no upstream suite at all. The fork ran them on the branch push, and that
#      run is real validation of the same commit. Accepting it is what makes an
#      upstream approval a contribution question rather than a validation one.
#      That acceptance is granted on the run's JOBS, never on the run's own
#      conclusion: a run concludes success whenever nothing in it failed, which
#      a run whose jobs were skipped or never expanded also does, so only the
#      required suite roster appearing green among those jobs is evidence.
#
# A commit validated only in the fork is reported as exactly that, naming the
# repository and run, so a green verdict always says where its evidence came
# from and is never confused with the upstream pull request having been checked.
#
# The roster of suites a green verdict requires belongs to the repository the
# pull request targets, and is resolved from it for every run of this script -
# see fm_ci_roster in bin/fm-ci-checks-lib.sh, which owns where it comes from
# and why. This script is asked about any repository the fleet works in, so it
# holds no roster of its own; a repository whose roster cannot be established is
# refused rather than judged against somebody else's.
#
# Usage: fm-pr-ci-verify.sh <pr-url>
# Env:   FM_CI_REQUIRED_SUITES  JSON array of job names to require instead of
#          the roster read from the target repository. The escape hatch for a
#          change that deliberately adds or removes a CI job, whose branch is
#          therefore judged against a roster the target branch has not
#          recorded yet.
# Exit:  0 repository suites ran and passed, upstream or in the head repository
#        1 they did not: none ran, one is red, one has not finished, or fewer
#          than the full required roster reported
#        2 the request or the reply could not be read
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ci-checks-lib.sh
. "$SCRIPT_DIR/fm-ci-checks-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

unreadable() {
  printf 'error: could not read %s\n' "$1" >&2
  exit 2
}

if [ "$#" -ne 1 ]; then
  echo "usage: fm-pr-ci-verify.sh <pr-url>" >&2
  exit 2
fi

# The URL is parsed by the same owner the rest of the pull request path uses, so
# this script accepts exactly the URLs those scripts accept and never reaches a
# forge from a string it has not validated.
if ! fm_pr_url_parse "$1"; then
  echo "error: not a pull request URL: $1" >&2
  exit 2
fi
if [ "$FM_PR_PROVIDER" != github ]; then
  # GitLab reports a head pipeline rather than check runs, and bin/fm-pr-merge.sh
  # already verifies that pipeline at the head it merges.
  echo "error: fm-pr-ci-verify.sh reads GitHub check runs; $1 is not a GitHub pull request" >&2
  exit 2
fi
URL=$FM_PR_URL
BASE_REPO="$FM_PR_OWNER/$FM_PR_REPO"

pr=$(gh pr view "$FM_PR_NUMBER" --repo "$BASE_REPO" \
  --json statusCheckRollup,headRefOid,headRepository,headRepositoryOwner,baseRefName 2>/dev/null) \
  || unreadable "the pull request $URL"

rollup=$(printf '%s' "$pr" | jq -c '.statusCheckRollup // []' 2>/dev/null) \
  || unreadable "the checks on $URL"
head_sha=$(printf '%s' "$pr" | jq -r '.headRefOid // ""' 2>/dev/null) || head_sha=''
base_ref=$(printf '%s' "$pr" | jq -r '.baseRefName // ""' 2>/dev/null) || base_ref=''
head_repo=$(printf '%s' "$pr" | jq -r '
  ((.headRepositoryOwner.login // "") | tostring) as $o
  | ((.headRepository.name // "") | tostring) as $n
  | if $o == "" or $n == "" then "" else $o + "/" + $n end' 2>/dev/null) || head_repo=''

# The standard is settled before any verdict is read against it. A roster that
# cannot be established is a refusal in its own right, because without it no
# rollup can be told apart from a rollup missing half of itself.
if ! fm_ci_roster "$BASE_REPO" "$base_ref"; then
  {
    printf 'error: refusing to call %s green: could not establish what %s requires of a commit.\n' \
      "$URL" "$BASE_REPO"
    echo "See the reason above. Set FM_CI_REQUIRED_SUITES to the JSON array of job names"
    echo "this change expects if the roster is one the target branch has not recorded yet."
  } >&2
  exit 1
fi
ROSTER=$FM_CI_ROSTER

state=$(fm_ci_checks_state "$rollup" "$ROSTER") || unreadable "the checks on $URL"

# The roster is printed for every outcome, including the passing one, so the
# evidence behind a green verdict is on the record rather than only its verdict.
printf '%s\n' "$URL"
printf 'required suites: %s, from %s\n' \
  "$(printf '%s' "$ROSTER" | jq -r 'length')" "$FM_CI_ROSTER_SOURCE"
roster=$(printf '%s' "$rollup" | jq -r --argjson fm_ci_roster "$ROSTER" "$FM_CI_CHECKS_JQ_DEFS"'
  def row: "  " + (if fm_ci_repo_owned then "suite " else "other " end)
    + ((.conclusion // .state // "pending") | tostring)
    + "\t" + (((.workflowName // "") | tostring) as $w | if $w == "" then "-" else $w end)
    + " / " + ((.name // .context // "-") | tostring);
  [.[] | select(fm_ci_repo_owned) | row] + [.[] | select(fm_ci_repo_owned | not) | row]
  | .[]' 2>/dev/null) || roster=''
[ -z "$roster" ] || printf '%s\n' "$roster"

own=$(printf '%s' "$rollup" | jq --argjson fm_ci_roster "$ROSTER" "$FM_CI_CHECKS_JQ_DEFS"'
  [.[] | select(fm_ci_repo_owned)] | length' 2>/dev/null) || own='?'
printf '%s checks: %s (%s repository-owned)\n' "$BASE_REPO" "$state" "$own"

# An incomplete roster names what it is missing, the same way a red or
# pending check names its own state above, so the refusal is never just "not
# passing" with no way to tell what would make it so.
if [ "$state" = incomplete ]; then
  missing=$(printf '%s' "$rollup" | jq -r --argjson fm_ci_roster "$ROSTER" \
    "$FM_CI_CHECKS_JQ_DEFS"'fm_ci_missing_suites | .[]' 2>/dev/null) || missing=''
  [ -z "$missing" ] || printf 'missing required suites:\n%s\n' "$(printf '%s\n' "$missing" | sed 's/^/  /')"
fi

if [ "$state" = passing ]; then
  printf 'validated: %s suites passed on %s in %s\n' "$BASE_REPO" "$head_sha" "$BASE_REPO"
  exit 0
fi

# A red or unfinished upstream suite is a real result about this commit, so it
# is reported as-is rather than looked past in the hope the fork disagrees.
case "$state" in
  failing|pending)
    printf 'error: refusing to call %s green: its %s checks are %s (see the roster above).\n' \
      "$URL" "$BASE_REPO" "$state" >&2
    exit 1
    ;;
esac

# Nothing upstream validated this commit: no-repo-ci and incomplete are both
# "the base repository is not evidence", just for different reasons - nothing
# of ours ran, or only part of it did - so both fall through the same way to
# ask the head repository, which is where an unapproved fork pull request's
# suites actually ran.
if [ "$state" = incomplete ]; then
  base_reason="$BASE_REPO checks do not cover the required suite roster"
else
  base_reason="no $BASE_REPO suite ran on this commit"
fi

if [ -z "$head_repo" ] || [ -z "$head_sha" ] || [ "$head_repo" = "$BASE_REPO" ]; then
  {
    printf 'error: refusing to call %s green: %s.\n' "$URL" "$base_reason"
    echo "A third-party check passing is not this repository's CI passing, and there is"
    echo "no separate head repository whose own run could have validated it."
  } >&2
  exit 1
fi

printf '%s; reading %s at %s\n' "$base_reason" "$head_repo" "$head_sha"
runs=$(gh api "repos/$head_repo/actions/runs?head_sha=$head_sha&per_page=100" \
  --jq '[.workflow_runs[] | {id, name, status, conclusion, event}]' 2>/dev/null) \
  || unreadable "the workflow runs in $head_repo"
[ -n "$runs" ] || unreadable "the workflow runs in $head_repo"

# The run's own conclusion cannot answer whether the required suites ran, so
# the jobs of every CI run at this commit are read and judged against the same
# roster the rollup shape uses. bin/fm-ci-checks-lib.sh owns why a successful
# run is not that evidence.
ci_run_ids=$(printf '%s' "$runs" | jq -r --argjson fm_ci_roster "$ROSTER" "$FM_CI_CHECKS_JQ_DEFS"'
  .[] | select(fm_ci_run_from_ci_workflow) | (.id // empty) | tostring' 2>/dev/null) \
  || unreadable "the workflow runs in $head_repo"

ci_jobs='[]'
for run_id in $ci_run_ids; do
  # A run with more jobs than one page would truncate the roster, which can
  # only ever lose a required suite and so can only refuse, never pass.
  run_jobs=$(gh api "repos/$head_repo/actions/runs/$run_id/jobs?per_page=100" \
    --jq '[.jobs[] | {name, status, conclusion}]' 2>/dev/null) \
    || unreadable "the jobs of run $run_id in $head_repo"
  [ -n "$run_jobs" ] || unreadable "the jobs of run $run_id in $head_repo"
  ci_jobs=$(jq -cn --argjson a "$ci_jobs" --argjson b "$run_jobs" '$a + $b' 2>/dev/null) \
    || unreadable "the jobs of run $run_id in $head_repo"
done

fork_state=$(fm_ci_run_jobs_state "$runs" "$ci_jobs" "$ROSTER") \
  || unreadable "the workflow runs in $head_repo"
fork_roster=$(printf '%s' "$runs" | jq -r '
  .[] | "  run " + ((.id // "-") | tostring) + " " + ((.conclusion // .status) | tostring)
    + "\t" + ((.name // "-") | tostring) + " (" + ((.event // "-") | tostring) + ")"' 2>/dev/null) \
  || fork_roster=''
[ -z "$fork_roster" ] || printf '%s\n' "$fork_roster"
# The jobs are printed for every outcome, the passing one included, so a green
# verdict carries the suite names it was granted on rather than only a state.
job_roster=$(printf '%s' "$ci_jobs" | jq -r '
  .[] | "  job " + ((.conclusion // .status // "pending") | tostring)
    + "\t" + ((.name // "-") | tostring)' 2>/dev/null) || job_roster=''
[ -z "$job_roster" ] || printf '%s\n' "$job_roster"
printf '%s runs: %s\n' "$head_repo" "$fork_state"

if [ "$fork_state" = incomplete ]; then
  fork_missing=$(printf '%s' "$ci_jobs" | jq -r --argjson fm_ci_roster "$ROSTER" "$FM_CI_CHECKS_JQ_DEFS"'
    fm_ci_jobs_missing_suites | .[]' 2>/dev/null) || fork_missing=''
  if [ -n "$fork_missing" ]; then
    printf 'missing required suites:\n%s\n' "$(printf '%s\n' "$fork_missing" | sed 's/^/  /')"
  fi
fi

case "$fork_state" in
  passing)
    # Named as fork-validated so the verdict can never be read as the upstream
    # pull request having been checked. Upstream approval remains outstanding
    # and is a contribution question, not a validation one.
    printf 'validated: %s suites passed on %s in %s; %s has not run its own and does not need to for this to be validated\n' \
      "$head_repo" "$head_sha" "$head_repo" "$BASE_REPO"
    exit 0
    ;;
  none)
    {
      printf 'error: refusing to call %s green: no suite ran on this commit in either %s or %s.\n' \
        "$URL" "$BASE_REPO" "$head_repo"
      printf 'Push the branch to %s and let its own run validate the commit.\n' "$head_repo"
    } >&2
    exit 1
    ;;
  incomplete)
    {
      printf 'error: refusing to call %s green: the %s CI run does not cover the required suite roster (see above).\n' \
        "$URL" "$head_repo"
      echo "A workflow run concludes success when no job failed, which a run whose jobs"
      echo "were skipped or never expanded also does, so that is not evidence the suites ran."
    } >&2
    exit 1
    ;;
  *)
    printf 'error: refusing to call %s green: the %s runs are %s (see above).\n' \
      "$URL" "$head_repo" "$fork_state" >&2
    exit 1
    ;;
esac
