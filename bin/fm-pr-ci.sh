#!/usr/bin/env bash
# Wait a bounded number of times for terminal successful GitHub checks on one
# exact pull-request head SHA.
#
# The PR head is read immediately before and after each check snapshot.
# Missing, pending, skipped, failed, ambiguous, or different-head results are
# never green, regardless of a CLI's exit status.
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
NUMBER=$FM_PR_NUMBER
fm_pr_head_valid "$EXPECTED_HEAD" || usage
case "$ATTEMPTS" in ''|*[!0-9]*) usage ;; esac
case "$INTERVAL" in ''|*[!0-9]*) usage ;; esac
[ "$ATTEMPTS" -ge 1 ] && [ "$ATTEMPTS" -le 60 ] || usage
[ "$INTERVAL" -le 60 ] || usage
command -v gh >/dev/null 2>&1 || {
  echo "error: exact-head verification requires gh on PATH" >&2
  exit 1
}
command -v gh-axi >/dev/null 2>&1 || {
  echo "error: exact-head verification requires gh-axi on PATH" >&2
  exit 1
}

read_head() {
  gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null
}

FM_PR_CI_TOTAL=
summary_is_green() {  # <summary>
  local summary=$1 passed failed total
  [[ "$summary" =~ ^([0-9]+)[[:space:]]passed,[[:space:]]([0-9]+)[[:space:]]failed,[[:space:]]([0-9]+)[[:space:]]total$ ]] \
    || return 1
  passed=${BASH_REMATCH[1]}
  failed=${BASH_REMATCH[2]}
  total=${BASH_REMATCH[3]}
  FM_PR_CI_TOTAL=$total
  [ -n "$passed" ] && [ -n "$failed" ] && [ -n "$total" ] \
    && [ "$passed" -gt 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq "$total" ]
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
    checks_status=0
    checks=$(gh-axi pr checks "$NUMBER" --repo "$OWNER/$REPO" 2>&1) || checks_status=$?
    head_after=$(read_head) || head_after=
    if [ "$head_after" != "$EXPECTED_HEAD" ]; then
      echo "error: PR $URL changed head while checks were read; expected head $EXPECTED_HEAD, observed ${head_after:-unknown}" >&2
      exit 1
    fi
    summary_rows=$(printf '%s\n' "$checks" | grep -c '^summary:[[:space:]]*' || true)
    summary=$(printf '%s\n' "$checks" | sed -n 's/^summary:[[:space:]]*//p')
    if [ "$checks_status" -eq 0 ] && [ "$summary_rows" -eq 1 ] && summary_is_green "$summary"; then
      total=$FM_PR_CI_TOTAL
      echo "green: $URL head=$EXPECTED_HEAD checks=$total"
      exit 0
    fi
    if [ "$summary_rows" -eq 0 ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS no terminal successful checks for head $EXPECTED_HEAD" >&2
    elif [ "$summary_rows" -ne 1 ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS ambiguous check summary count=$summary_rows for head $EXPECTED_HEAD" >&2
    elif [ -z "$summary" ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS no terminal successful checks for head $EXPECTED_HEAD" >&2
    else
      echo "not-green: attempt=$attempt/$ATTEMPTS head=$EXPECTED_HEAD $summary" >&2
    fi
  fi
  [ "$attempt" -ge "$ATTEMPTS" ] || [ "$INTERVAL" -eq 0 ] || sleep "$INTERVAL"
  attempt=$((attempt + 1))
done

echo "error: PR $URL did not reach exact-head green within $ATTEMPTS attempt(s)" >&2
exit 1
