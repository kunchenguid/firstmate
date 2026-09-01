#!/usr/bin/env bash
# Wait a bounded number of times for terminal successful GitHub checks on one
# exact pull-request head SHA.
#
# Check runs and commit statuses are read directly for the expected SHA, while
# the PR head is confirmed immediately before and after each snapshot.
# Missing, pending, skipped, failed, ambiguous, stale, or different-head
# results are never green, regardless of a CLI's exit status.
# Usage: fm-pr-ci.sh <full-pr-url> <exact-head-sha> [--attempts <1-60>] [--interval <0-60>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-pr-ci.sh <full-pr-url> <exact-head-sha> [--attempts <1-60>] [--interval <0-60>]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
RAW_URL=$1
EXPECTED_HEAD=$2
shift 2
ATTEMPTS=30
INTERVAL=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attempts) [ "$#" -ge 2 ] || usage; ATTEMPTS=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || usage; INTERVAL=$2; shift 2 ;;
    *) usage ;;
  esac
done

fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || usage
URL=$FM_PR_URL
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
fm_pr_head_valid "$EXPECTED_HEAD" || usage
case "$ATTEMPTS" in ''|*[!0-9]*) usage ;; esac
case "$INTERVAL" in ''|*[!0-9]*) usage ;; esac
[ "$ATTEMPTS" -ge 1 ] && [ "$ATTEMPTS" -le 60 ] || usage
[ "$INTERVAL" -le 60 ] || usage
command -v gh >/dev/null 2>&1 || {
  echo "error: exact-head verification requires gh on PATH" >&2
  exit 1
}
read_head() {
  gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null
}

read_check_runs() {
  gh api --paginate -H 'Accept: application/vnd.github+json' \
    "repos/$OWNER/$REPO/commits/$EXPECTED_HEAD/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | ["check", .head_sha, .name, .status, (.conclusion // "")] | @tsv' 2>/dev/null
}

read_commit_statuses() {
  gh api --paginate -H 'Accept: application/vnd.github+json' \
    "repos/$OWNER/$REPO/commits/$EXPECTED_HEAD/status?per_page=100" \
    --jq '[{head: .sha, item: .statuses[]}][] | ["status", .head, .item.context, "completed", .item.state] | @tsv' 2>/dev/null
}

validate_exact_head_evidence() {
  awk -F '\t' -v expected="$EXPECTED_HEAD" '
    function reject(reason) {
      if (problem == "") problem = reason
    }
    NF == 0 { next }
    {
      if (NF != 5) {
        reject("malformed exact-head check evidence")
        next
      }
      kind = $1
      sha = $2
      name = $3
      status = $4
      conclusion = $5
      if (kind != "check" && kind != "status") reject("unknown exact-head check evidence type")
      if (sha != expected) reject("different-head check evidence for " name)
      if (name == "") reject("unnamed exact-head check evidence")
      if (++seen[name] > 1) reject("ambiguous exact-head check evidence for " name)
      successful = status == "completed" && conclusion == "success"
      if (name == "Verify exact PR head") {
        canonical++
        if (!successful) canonical_failed = 1
      } else if (!successful) {
        reject("check is not terminal-successful: " name)
      }
      total++
    }
    END {
      if (problem != "") {
        print "not-green: " problem
        exit 1
      }
      if (total == 0) {
        print "not-green: no exact-head checks or statuses were found"
        exit 1
      }
      if (canonical == 0) {
        print "not-green: canonical Verify exact PR head check is missing"
        exit 1
      }
      if (canonical_failed) {
        print "not-green: canonical Verify exact PR head check is not terminal-successful"
        exit 1
      }
      print "green: " total
    }
  '
}

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  head_before=$(read_head) || head_before=
  if ! fm_pr_head_valid "$head_before"; then
    echo "not-green: attempt=$attempt/$ATTEMPTS could not read a valid PR head" >&2
  elif [ "$head_before" != "$EXPECTED_HEAD" ]; then
    echo "error: PR $URL is at head $head_before; expected head $EXPECTED_HEAD" >&2
    exit 1
  else
    check_runs_status=0
    check_runs=$(read_check_runs) || check_runs_status=$?
    statuses_status=0
    statuses=$(read_commit_statuses) || statuses_status=$?
    head_after=$(read_head) || head_after=
    if [ "$head_after" != "$EXPECTED_HEAD" ]; then
      echo "error: PR $URL changed head while checks were read; expected head $EXPECTED_HEAD, observed ${head_after:-unknown}" >&2
      exit 1
    elif [ "$check_runs_status" -ne 0 ] || [ "$statuses_status" -ne 0 ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS exact-head check evidence is unavailable for head $EXPECTED_HEAD" >&2
    fi
    if [ "$check_runs_status" -eq 0 ] && [ "$statuses_status" -eq 0 ]; then
      evidence_status=0
      evidence_result=$(printf '%s\n%s\n' "$check_runs" "$statuses" \
        | validate_exact_head_evidence) || evidence_status=$?
      if [ "$evidence_status" -eq 0 ]; then
        total=${evidence_result#green: }
        echo "green: $URL head=$EXPECTED_HEAD checks=$total"
        exit 0
      fi
      echo "not-green: attempt=$attempt/$ATTEMPTS head=$EXPECTED_HEAD ${evidence_result#not-green: }" >&2
    fi
  fi
  [ "$attempt" -ge "$ATTEMPTS" ] || [ "$INTERVAL" -eq 0 ] || sleep "$INTERVAL"
  attempt=$((attempt + 1))
done

echo "error: PR $URL did not reach exact-head green within $ATTEMPTS attempt(s)" >&2
exit 1
