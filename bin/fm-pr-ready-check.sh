#!/usr/bin/env bash
# Generic bors-readiness watcher for a list of pull requests.
# Prints one line per PR that newly became bors-ready (state OPEN, mergeable
# MERGEABLE, no review-blocker label, all checks SUCCESS); prints nothing
# otherwise, including on every error, so a failed lookup can never be read as
# a ready PR. Transition-aware: each PR is reported once per distinct head
# oid, so a re-push that turns it ready again wakes firstmate again.
#
# Usage: fm-pr-ready-check.sh [<pr>...]
#   <pr>            bare PR number (repo from FM_PR_READY_REPO) or
#                   owner/repo#number
#
# Env:
#   FM_PR_READY_REPO   repo for bare PR numbers; a bare number is skipped
#                      (silently, per the no-false-positive contract above)
#                      when this is unset
#   FM_PR_READY_STATE  marker dir (default FM_HOME/state)
#
# Watcher integration: a thin per-task shim (state/<id>.check.sh) reads its PR
# list from a data sidecar (state/<id>.prs, one PR per line) and execs this
# script, so the PR list can change without re-binding the check trust. Arm a
# new watch with bin/fm-pr-ready-arm.sh <id> <pr...>.
set -u

FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${FM_PR_READY_REPO:-}"
MARK_DIR="${FM_PR_READY_STATE:-$FM_HOME/state}"
MARK="$MARK_DIR/.pr-ready"

mkdir -p "$MARK_DIR" 2>/dev/null || exit 0


for arg in "$@"; do
  case "$arg" in
    *'#'*)
      repo=${arg%#*}
      pr=${arg##*#}
      ;;
    ''|*[!0-9]*)
      continue
      ;;
    *)
      [ -n "$REPO" ] || continue
      repo=$REPO
      pr=$arg
      ;;
  esac
  case "$pr" in ''|*[!0-9]*) continue ;; esac

  key="${repo//\//-}#$pr"
  data=$(gh pr view "$pr" --repo "$repo" --json state,mergeable,headRefOid,labels 2>/dev/null) || continue
  [ "$(printf '%s' "$data" | jq -r .state)" = OPEN ] || continue
  [ "$(printf '%s' "$data" | jq -r .mergeable)" = MERGEABLE ] || continue
  n=$(printf '%s' "$data" | jq -r '[.labels[].name | select(. == "review-blocker")] | length')
  [ "$n" = 0 ] || continue
  checks=$(gh pr checks "$pr" --repo "$repo" --json state 2>/dev/null) || continue
  bad=$(printf '%s' "$checks" | jq -r '[.[] | select(.state != "SUCCESS")] | length')
  [ "$bad" = 0 ] || continue

  head=$(printf '%s' "$data" | jq -r .headRefOid)
  prev=$(awk -v k="$key" '$1 == k { print $2; exit }' "$MARK" 2>/dev/null || true)
  if [ "$prev" != "$head" ]; then
    printf 'ready: https://github.com/%s/pull/%s (head %s)\n' "$repo" "$pr" "${head:0:10}"
    printf '%s\t%s\n' "$key" "$head" >> "$MARK"
  fi
done
