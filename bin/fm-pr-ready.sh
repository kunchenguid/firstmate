#!/usr/bin/env bash
# Determine whether an open GitHub PR's current head is ready for review.
#
# This script owns Firstmate's reusable GitHub readiness classification.
# It reads the PR's current head, combined commit statuses, latest check runs,
# and exact-head deployments without caching any result.
# The caller supplies the expected full head SHA; a changed PR head makes the
# result not ready before status evidence is read, so stale readiness cannot be
# reused.
#
# Every status and check must have a passing GitHub state, with one narrow
# exception: a non-success commit status whose context is exactly `Vercel` is
# excluded only when the exact head has at least one Vercel-authored deployment
# and every Vercel-authored deployment for that head has environment `Preview`
# and production_environment=false.
# The deployment API fields, exact SHA, and Vercel deployment creator are the
# classification boundary; the ambiguous status display name alone is never
# enough.
# A production, mixed-environment, missing, or otherwise unclassified Vercel
# deployment remains blocking, as does every pending or failed ordinary check.
# Zero reported checks is not ready here because no-mistakes owns its settling
# period for repositories that genuinely have no CI.
#
# Readiness is not merge authority.
# This script only prints `ready` and exits 0; it never records approval, arms a
# merge poll, or invokes a merge command.
#
# Usage: fm-pr-ready.sh <canonical-pr-url> <expected-full-head-sha>
# Exit 0 means ready, 1 means not ready or authoritative data was unavailable,
# and 2 means invalid arguments.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ] || ! fm_pr_url_parse "$1" || ! fm_pr_head_valid "$2"; then
  echo "usage: fm-pr-ready.sh <canonical-pr-url> <expected-full-head-sha>" >&2
  exit 2
fi
URL=$FM_PR_URL
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
EXPECTED_HEAD=$2
TAB=$(printf '\t')

command -v gh >/dev/null 2>&1 || exit 1

PR_ROW=$(gh pr view "$URL" --json state,headRefOid --jq '[.state,.headRefOid] | @tsv' 2>/dev/null) || exit 1
IFS="$TAB" read -r PR_STATE PR_HEAD PR_EXTRA <<EOF
$PR_ROW
EOF
[ -z "${PR_EXTRA:-}" ] || exit 1
[ "$PR_STATE" = OPEN ] || exit 1
fm_pr_head_valid "$PR_HEAD" || exit 1
[ "$PR_HEAD" = "$EXPECTED_HEAD" ] || exit 1

STATUS_ROWS=$(gh api --paginate "/repos/$OWNER/$REPO/commits/$PR_HEAD/status?per_page=100" \
  --jq '.statuses[] | [.context,.state] | @tsv' 2>/dev/null) || exit 1
CHECK_ROWS=$(gh api --paginate "/repos/$OWNER/$REPO/commits/$PR_HEAD/check-runs?per_page=100&filter=latest" \
  --jq '.check_runs[] | [.name,.status,(.conclusion // "")] | @tsv' 2>/dev/null) || exit 1

STATUS_COUNT=0
CHECK_COUNT=0
VERCEL_BLOCKING=0
OTHER_BLOCKING=0
while IFS="$TAB" read -r CONTEXT STATUS EXTRA; do
  [ -n "$CONTEXT" ] || continue
  STATUS_COUNT=$((STATUS_COUNT + 1))
  [ -z "${EXTRA:-}" ] || { OTHER_BLOCKING=1; continue; }
  case "$STATUS" in
    success) ;;
    pending|failure|error)
      if [ "$CONTEXT" = Vercel ]; then
        VERCEL_BLOCKING=1
      else
        OTHER_BLOCKING=1
      fi
      ;;
    *) OTHER_BLOCKING=1 ;;
  esac
done <<EOF
$STATUS_ROWS
EOF

while IFS="$TAB" read -r NAME CHECK_STATUS CONCLUSION EXTRA; do
  [ -n "$NAME" ] || continue
  CHECK_COUNT=$((CHECK_COUNT + 1))
  [ -z "${EXTRA:-}" ] || { OTHER_BLOCKING=1; continue; }
  if [ "$CHECK_STATUS" != completed ]; then
    OTHER_BLOCKING=1
    continue
  fi
  case "$CONCLUSION" in
    success|neutral|skipped) ;;
    *) OTHER_BLOCKING=1 ;;
  esac
done <<EOF
$CHECK_ROWS
EOF

[ "$((STATUS_COUNT + CHECK_COUNT))" -gt 0 ] || exit 1
[ "$OTHER_BLOCKING" -eq 0 ] || exit 1

if [ "$VERCEL_BLOCKING" -eq 1 ]; then
  DEPLOYMENT_ROWS=$(gh api --paginate "/repos/$OWNER/$REPO/deployments?sha=$PR_HEAD&per_page=100" \
    --jq '.[] | [.sha,.environment,(.production_environment | tostring),(.creator.login // "")] | @tsv' \
    2>/dev/null) || exit 1
  VERCEL_DEPLOYMENTS=0
  VERCEL_PREVIEW_ONLY=1
  while IFS="$TAB" read -r DEPLOY_SHA ENVIRONMENT PRODUCTION CREATOR EXTRA; do
    [ -n "$DEPLOY_SHA" ] || continue
    [ -z "${EXTRA:-}" ] || { VERCEL_PREVIEW_ONLY=0; continue; }
    [ "$DEPLOY_SHA" = "$PR_HEAD" ] || { VERCEL_PREVIEW_ONLY=0; continue; }
    [ "$CREATOR" = 'vercel[bot]' ] || continue
    VERCEL_DEPLOYMENTS=$((VERCEL_DEPLOYMENTS + 1))
    if [ "$ENVIRONMENT" != Preview ] || [ "$PRODUCTION" != false ]; then
      VERCEL_PREVIEW_ONLY=0
    fi
  done <<EOF
$DEPLOYMENT_ROWS
EOF
  [ "$VERCEL_DEPLOYMENTS" -gt 0 ] || exit 1
  [ "$VERCEL_PREVIEW_ONLY" -eq 1 ] || exit 1
fi

printf 'ready\n'
exit 0
