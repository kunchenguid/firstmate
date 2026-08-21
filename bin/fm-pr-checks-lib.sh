#!/usr/bin/env bash
# fm-pr-checks-lib.sh - read the forge's own verdict on a GitHub pull request's
# checks, so bin/fm-pr-merge.sh can refuse a red merge instead of trusting
# silence. Sourced, never executed.
#
# Two independent sources are read, because either can be red on its own:
#
#   1. the pull request head's status check rollup, and
#   2. the newest merge-queue attempt for that pull request. A merge queue runs
#      the checks AGAIN on a combined commit published as a temporary
#      "gh-readonly-queue/<base>/pr-<number>-<base sha>" branch, so its verdict
#      is a different fact from the branch's own and can be red while every
#      branch check is green.
#
# Source 2 is not hypothetical. On 2026-08-10 the queue run for nguzen/aln pull
# request 182 failed at 17:54 UTC, the pull request was merged at 17:59 UTC, and
# the defect in that combined commit then blocked every production deploy for
# two days. A branch-only read would not have refused that merge.
#
# `gh pr checks` is deliberately unused: it exits non-zero both when a check has
# failed and when one is still running, so its exit status cannot classify a
# result (verified 2026-08-12) and only its human-facing lines carry the answer.
# The JSON reads below are classified by value instead.
#
# Every read failure - a missing tool, a failed call, a bound hit, output that
# does not parse, or a payload for a different pull request - is reported as
# "unreadable", never as a pass. Treating the absence of a red signal as green
# is the exact failure that produced the incident above, so the caller must
# refuse on "unreadable" as it refuses on "failing".
#
# The caller must have validated owner, repository and number through
# bin/fm-pr-lib.sh before calling in, because those values are passed to `gh`.
#
# GitHub only, deliberately. bin/fm-pr-lib.sh also parses GitLab merge requests
# for the watcher, but bin/fm-pr-merge.sh refuses a GitLab URL before it ever
# reaches this library, so a forge whose check state cannot be read here is
# refused by name at the merge entrypoint rather than mis-classified in here.
#
#   fm_pr_checks_read <owner> <repo> <number>
#       Sets FM_PR_CHECKS_STATE to one of:
#         failing     at least one check the forge reports as failed
#         pending     nothing failed, but something has not finished
#         green       every reported check succeeded (or was neutral/skipped)
#         none        the forge reports no checks at all for this pull request
#         unreadable  the state could not be established (see _REASON)
#       FM_PR_CHECKS_FAILING and FM_PR_CHECKS_PENDING carry one human-readable
#       line per check, FM_PR_CHECKS_REASON explains an unreadable state, and
#       FM_PR_CHECKS_QUEUE_REF names the merge-queue attempt that was read.
#       Always returns 0: the classification is the result, not the exit status.

set -u

# Every FM_PR_CHECKS_* value below is this library's OUTPUT: it is read by the
# sourcing caller (bin/fm-pr-merge.sh), never inside this file.
# shellcheck disable=SC2034
FM_PR_CHECKS_STATE=
FM_PR_CHECKS_FAILING=
FM_PR_CHECKS_PENDING=
FM_PR_CHECKS_REASON=
FM_PR_CHECKS_QUEUE_REF=

FM_PR_CHECKS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_PR_CHECKS_LIB_DIR/fm-timeout-lib.sh"

# Bound every forge read so a hung CLI cannot stall a merge indefinitely. A
# non-positive bound is not a bound (see bin/fm-timeout-lib.sh), so reject it.
fm_pr_checks_timeout() {
  local seconds=${FM_PR_CHECKS_TIMEOUT:-45}
  case "$seconds" in
    ''|*[!0-9]*) seconds=45 ;;
  esac
  [ "$seconds" -gt 0 ] || seconds=45
  printf '%s\n' "$seconds"
}

fm_pr_checks_gh() {
  fm_run_timed "$(fm_pr_checks_timeout)" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

# A CheckRun carries status+conclusion, a StatusContext carries only state, and
# both shapes appear side by side in one rollup. CANCELLED and STALE on the
# branch itself are treated as failures rather than noise: the branch is not
# green and nothing else re-runs them.
# The jq program is deliberately literal: $want is a jq argument, not a shell one.
# shellcheck disable=SC2016
FM_PR_CHECKS_ROLLUP_JQ='
def norm: (. // "") | tostring | ascii_upcase;
def verdict:
  (.conclusion | norm) as $c
  | ((.status // .state) | norm) as $s
  | if ($c == "FAILURE" or $c == "ERROR" or $c == "TIMED_OUT" or $c == "CANCELLED"
        or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE" or $c == "STALE"
        or $s == "FAILURE" or $s == "ERROR") then "fail"
    elif ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED" or $s == "SUCCESS") then "ok"
    else "pending" end;
def check_name: (.name // .context // "check") | tostring;
def check_detail: (.conclusion // .status // .state // "unknown") | tostring;
if (has("number") | not) or (has("baseRefName") | not) or (has("statusCheckRollup") | not) then "invalid"
elif ((.number | tostring) != ($want | tostring)) then "identity"
else
  ("base\t" + ((.baseRefName // "") | tostring)),
  ("total\t" + ((.statusCheckRollup // []) | length | tostring)),
  ((.statusCheckRollup // [])[] | (verdict + "\t" + check_name + "\t" + check_detail))
end
'

# Merge-queue runs are Actions runs on the queue branch. Only the NEWEST attempt
# for this pull request is judged, so a superseded red attempt cannot keep
# refusing a pull request that has since been re-queued green; within that
# attempt the newest run per workflow wins, so a re-run replaces its own result.
# cancelled/stale queue attempts are inconclusive rather than failures: the
# queue discards and re-runs them as PRs ahead of this one land.
# $prefix is a jq argument, not a shell one.
# shellcheck disable=SC2016
FM_PR_CHECKS_QUEUE_JQ='
def norm: (. // "") | tostring | ascii_upcase;
def verdict:
  (.conclusion | norm) as $c
  | (.status | norm) as $s
  | if ($c == "FAILURE" or $c == "TIMED_OUT" or $c == "ACTION_REQUIRED"
        or $c == "STARTUP_FAILURE") then "fail"
    elif ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED") then "ok"
    else "pending" end;
if (has("workflow_runs") | not) then "invalid" else
[ (.workflow_runs // [])[]
  | select(((.head_branch // "") | tostring) | startswith($prefix)) ]
| (sort_by((.created_at // "") | tostring) | reverse) as $runs
| if ($runs | length) == 0 then "queue_none"
  else (($runs[0].head_branch) | tostring) as $ref
  | ("queue_ref\t" + $ref),
    ( [ $runs[] | select((((.head_branch // "") | tostring)) == $ref) ]
      | group_by((.name // "") | tostring)
      | map(sort_by([((.created_at // "") | tostring), ((.run_attempt // 0) | tonumber? // 0)]) | last)
      | .[]
      | (verdict + "\t" + ((.name // "run") | tostring) + "\t"
         + ((.conclusion // .status // "unknown") | tostring)) )
  end
end
'

fm_pr_checks_unreadable() {
  FM_PR_CHECKS_STATE=unreadable
  FM_PR_CHECKS_REASON=$1
  return 0
}

fm_pr_checks_read() {
  local owner=$1 repo=$2 number=$3
  local head_json runs_json parsed prefix
  local kind field_a field_b base='' total=0 queue_seen=0 fail_count=0 pend_count=0

  # Reset the caller-visible outputs, which this file only ever writes.
  # shellcheck disable=SC2034
  FM_PR_CHECKS_STATE=
  FM_PR_CHECKS_FAILING=
  FM_PR_CHECKS_PENDING=
  # shellcheck disable=SC2034
  FM_PR_CHECKS_REASON=
  # shellcheck disable=SC2034
  FM_PR_CHECKS_QUEUE_REF=

  command -v gh >/dev/null 2>&1 \
    || { fm_pr_checks_unreadable 'gh not found, so the forge check state cannot be read'; return 0; }
  command -v jq >/dev/null 2>&1 \
    || { fm_pr_checks_unreadable 'jq not found, so the forge check state cannot be classified'; return 0; }

  head_json=$(fm_pr_checks_gh pr view "$number" --repo "$owner/$repo" \
    --json number,baseRefName,statusCheckRollup 2>/dev/null) \
    || { fm_pr_checks_unreadable "gh pr view failed for $owner/$repo#$number"; return 0; }
  [ -n "$head_json" ] \
    || { fm_pr_checks_unreadable "gh pr view returned no data for $owner/$repo#$number"; return 0; }

  parsed=$(printf '%s' "$head_json" \
    | jq -r --arg want "$number" "$FM_PR_CHECKS_ROLLUP_JQ" 2>/dev/null) \
    || { fm_pr_checks_unreadable "the pull request check payload for $owner/$repo#$number did not parse"; return 0; }
  case $parsed in
    identity|identity$'\n'*)
      fm_pr_checks_unreadable "the check payload did not describe $owner/$repo#$number"
      return 0
      ;;
    invalid|invalid$'\n'*)
      fm_pr_checks_unreadable "the check payload for $owner/$repo#$number was missing the fields that were asked for"
      return 0
      ;;
  esac

  while IFS=$'\t' read -r kind field_a field_b; do
    case $kind in
      base) base=$field_a ;;
      total)
        case $field_a in
          ''|*[!0-9]*)
            fm_pr_checks_unreadable "the check count of $owner/$repo#$number was not a number"
            return 0
            ;;
        esac
        total=$field_a
        ;;
      fail)
        fail_count=$((fail_count + 1))
        FM_PR_CHECKS_FAILING="${FM_PR_CHECKS_FAILING}branch check: $field_a ($field_b)"$'\n'
        ;;
      pending)
        pend_count=$((pend_count + 1))
        FM_PR_CHECKS_PENDING="${FM_PR_CHECKS_PENDING}branch check: $field_a ($field_b)"$'\n'
        ;;
      ok|'') ;;
      *)
        fm_pr_checks_unreadable "the pull request check payload for $owner/$repo#$number was not understood"
        return 0
        ;;
    esac
  done <<EOF
$parsed
EOF

  [ -n "$base" ] \
    || { fm_pr_checks_unreadable "the base branch of $owner/$repo#$number could not be read"; return 0; }

  # The merge-queue read is a required source, not an optional enrichment: a
  # failure here means the queue verdict is unknown, which must refuse.
  prefix="gh-readonly-queue/$base/pr-$number-"
  runs_json=$(fm_pr_checks_gh api \
    "repos/$owner/$repo/actions/runs?event=merge_group&per_page=100" 2>/dev/null) \
    || { fm_pr_checks_unreadable "the merge-queue check runs of $owner/$repo could not be listed"; return 0; }
  [ -n "$runs_json" ] \
    || { fm_pr_checks_unreadable "the merge-queue check runs of $owner/$repo returned no data"; return 0; }

  parsed=$(printf '%s' "$runs_json" \
    | jq -r --arg prefix "$prefix" "$FM_PR_CHECKS_QUEUE_JQ" 2>/dev/null) \
    || { fm_pr_checks_unreadable "the merge-queue check payload of $owner/$repo did not parse"; return 0; }

  while IFS=$'\t' read -r kind field_a field_b; do
    case $kind in
      queue_none|'') ;;
      invalid)
        fm_pr_checks_unreadable "the merge-queue payload of $owner/$repo did not list any workflow runs field"
        return 0
        ;;
      queue_ref)
        # shellcheck disable=SC2034 # Read by the sourcing caller.
        FM_PR_CHECKS_QUEUE_REF=$field_a
        queue_seen=1
        ;;
      fail)
        fail_count=$((fail_count + 1))
        FM_PR_CHECKS_FAILING="${FM_PR_CHECKS_FAILING}merge-queue check: $field_a ($field_b)"$'\n'
        ;;
      pending)
        pend_count=$((pend_count + 1))
        FM_PR_CHECKS_PENDING="${FM_PR_CHECKS_PENDING}merge-queue check: $field_a ($field_b)"$'\n'
        ;;
      ok) ;;
      *)
        fm_pr_checks_unreadable "the merge-queue check payload of $owner/$repo was not understood"
        return 0
        ;;
    esac
  done <<EOF
$parsed
EOF

  if [ "$fail_count" -gt 0 ]; then
    FM_PR_CHECKS_STATE=failing
  elif [ "$pend_count" -gt 0 ]; then
    FM_PR_CHECKS_STATE=pending
  elif [ "$total" -eq 0 ] && [ "$queue_seen" -eq 0 ]; then
    FM_PR_CHECKS_STATE=none
  else
    # shellcheck disable=SC2034 # Read by the sourcing caller.
    FM_PR_CHECKS_STATE=green
  fi
  return 0
}
