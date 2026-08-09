#!/usr/bin/env bash
# Preserve no-mistakes' `gh pr checks` contract when GitHub forbids the
# check-runs read but still permits workflow-runs reads.
#
# Usage: fm-gh-ci-fallback.sh <real-gh> pr checks <pr-number-or-url> --repo <owner/repo> --json <fields>
#        fm-gh-ci-fallback.sh --supports pr checks <pr-number-or-url> --repo <owner/repo> --json <fields>
#
# Token routing is deliberately least-privilege. The original check-runs call,
# the pull-request head lookup, and the exact-head workflow-runs lookup all use
# the caller's ambient GH_TOKEN/GITHUB_TOKEN unchanged. This script never calls
# fm-gh.sh, never injects config/gh-credential's broader PR-capable credential,
# and never prints a token. It falls back only after the original command reports
# the GraphQL personal-token denial whose error path names a `statusCheckRollup`
# component, at whatever depth GitHub currently reports it; every other result,
# including a denial for any other API, is replayed unchanged.
#
# The fallback is intentionally limited to the two literal argument vectors used
# by the supported no-mistakes CI monitor: a selector, `--repo owner/repository`,
# and `--json name,state,bucket,completedAt` with or without the final `link` field.
# Other `gh pr checks` invocations keep the real gh result, so installing the
# PATH-wide shim does not silently change an interactive command's output format.
#
# A fallback verdict is tied to the PR's exact current head SHA. The PR number
# and owner/repository are strictly validated, the head is read from
# repos/<owner>/<repo>/pulls/<number>, and Actions is queried through
# repos/<owner>/<repo>/actions/runs?head_sha=<exact-sha>. No branch name or local
# HEAD can certify green. All exact-head workflow runs are paginated, then mapped
# into the JSON check shape no-mistakes already consumes. An empty run list emits
# one pending placeholder, so absence of workflow evidence can never certify green.
# The PR head is read again after pagination and any drift refuses the fallback
# result, so a verdict can never describe a head that is no longer current.
# This evidence covers GitHub Actions only; it cannot reconstruct third-party
# check providers hidden behind the forbidden check-runs API.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fallback_shape_parse() {
  [ "$#" -eq 7 ] || return 1
  [ "${1:-}" = pr ] && [ "${2:-}" = checks ] || return 1
  [ "${4:-}" = --repo ] && [ "${6:-}" = --json ] || return 1
  SELECTOR=${3:-}
  REPO=${5:-}
  JSON_FIELDS=${7:-}

  case "$JSON_FIELDS" in
    name,state,bucket,completedAt|name,state,bucket,completedAt,link) ;;
    *) return 1 ;;
  esac

  case "$SELECTOR" in
    https://github.com/*)
      fm_pr_url_parse "$SELECTOR" || return 1
      [ "$FM_PR_PROVIDER" = github ] || return 1
      [ "$REPO" = "$FM_PR_PATH" ] || return 1
      REPO=$FM_PR_PATH
      NUMBER=$FM_PR_NUMBER
      ;;
    *)
      case "$SELECTOR" in
        ''|0|*[!0-9]*) return 1 ;;
      esac
      fm_pr_url_parse "https://github.com/$REPO/pull/$SELECTOR" || return 1
      [ "$FM_PR_PROVIDER" = github ] || return 1
      REPO=$FM_PR_PATH
      NUMBER=$FM_PR_NUMBER
      ;;
  esac
}

if [ "${1:-}" = --supports ]; then
  shift
  fallback_shape_parse "$@"
  exit $?
fi

[ "$#" -ge 5 ] || {
  echo "fm-gh-ci-fallback: invalid invocation" >&2
  exit 2
}
REAL_GH=$1
shift

ORIGINAL_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-out.XXXXXX")
ORIGINAL_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-err.XXXXXX")
FALLBACK_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-fallback-out.XXXXXX")
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  rm -f -- "$ORIGINAL_OUT" "$ORIGINAL_ERR" "$FALLBACK_OUT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ORIGINAL_STATUS=0
"$REAL_GH" "$@" > "$ORIGINAL_OUT" 2> "$ORIGINAL_ERR" || ORIGINAL_STATUS=$?
if [ "$ORIGINAL_STATUS" -eq 0 ]; then
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit 0
fi

replay_original() {
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit "$ORIGINAL_STATUS"
}

# Requiring GitHub's exact denial sentence together with a whole
# `statusCheckRollup` component inside its GraphQL error path keeps a changed gh
# failure from being reinterpreted as CI state, while tolerating the deeper
# property paths GitHub appends to that same denial as its check-runs selection
# set evolves. A component match is deliberate: a path that merely starts with
# those characters, and any denial for another API, still replays unchanged.
DENIAL_PATTERN='GraphQL: Resource not accessible by personal access token \(([A-Za-z0-9_]+\.)*statusCheckRollup(\.[A-Za-z0-9_]+)*\)'
if ! grep -Eq "$DENIAL_PATTERN" "$ORIGINAL_OUT" "$ORIGINAL_ERR"; then
  replay_original
fi

fallback_shape_parse "$@" || replay_original

read_exact_pr_head() {
  local head
  head=$("$REAL_GH" api -X GET "repos/$REPO/pulls/$NUMBER" --jq .head.sha 2>/dev/null) || return 1
  head=${head//$'\r'/}
  head=${head//$'\n'/}
  fm_pr_head_valid "$head" || return 1
  printf '%s\n' "$head"
}

PR_HEAD=
if ! PR_HEAD=$(read_exact_pr_head); then
  echo "fm-gh-ci-fallback: exact PR head lookup failed; preserving the original gh pr checks failure" >&2
  replay_original
fi

# gh's built-in jq evaluator applies this after --paginate --slurp has wrapped
# every Actions response page in one outer array. Producing one object per
# workflow run lets the existing no-mistakes classifier reach green, red,
# cancelled, skipped, and pending verdicts without any upstream patch.
# shellcheck disable=SC2016 # This is a literal jq program; its $ names belong to jq.
RUNS_JQ='[
  .[].workflow_runs[]
  | .status as $status
  | .conclusion as $conclusion
  | {
      name: (.name // "GitHub Actions workflow"),
      state: (if $status != "completed" then ($status // "pending") else ($conclusion // "pending") end),
      bucket: (
        if $status != "completed" or $conclusion == null then "pending"
        elif $conclusion == "success" then "pass"
        elif $conclusion == "cancelled" then "cancel"
        elif ($conclusion == "skipped" or $conclusion == "neutral" or $conclusion == "stale") then "skipping"
        elif ($conclusion == "failure" or $conclusion == "timed_out" or $conclusion == "action_required" or $conclusion == "startup_failure") then "fail"
        else "pending"
        end
      ),
      completedAt: (if $status == "completed" then (.updated_at // "") else "" end),
      link: (.html_url // "")
    }
] | if length == 0 then [{
  name: "GitHub Actions workflows",
  state: "pending",
  bucket: "pending",
  completedAt: "",
  link: ""
}] else . end'

RUNS_ENDPOINT="repos/$REPO/actions/runs?head_sha=$PR_HEAD&per_page=100"
if "$REAL_GH" api -X GET "$RUNS_ENDPOINT" --paginate --slurp --jq "$RUNS_JQ" \
  > "$FALLBACK_OUT" 2>/dev/null; then
  PR_HEAD_AFTER=
  if ! PR_HEAD_AFTER=$(read_exact_pr_head); then
    echo "fm-gh-ci-fallback: exact PR head recheck failed; preserving the original gh pr checks failure" >&2
    replay_original
  fi
  if [ "$PR_HEAD_AFTER" != "$PR_HEAD" ]; then
    echo "fm-gh-ci-fallback: PR head changed during workflow-runs lookup; preserving the original gh pr checks failure" >&2
    replay_original
  fi
  cat "$FALLBACK_OUT"
  exit 0
fi

echo "fm-gh-ci-fallback: exact-head workflow-runs lookup failed; preserving the original gh pr checks failure" >&2
replay_original
