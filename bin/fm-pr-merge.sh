#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Attribution: before calling gh-axi pr merge, this records a durable
# merged_by_firstmate=<pr-url> marker (plus merged_ts=) in state/<id>.meta. That
# marker is the ground truth for "firstmate merged this PR", keyed by PR NUMBER
# (via the unique URL) and never by branch name, so the merge-attribution watch
# (bin/fm-pr-check.sh's generated check.sh) can tell firstmate's own merges apart
# from an out-of-band merge. The write PRECEDES the merge call so firstmate's own
# merges can never race into a false unattributed reading. A best-effort
# merged_commit=<sha> is recorded after a successful merge so teardown containment
# and the attribution record agree on the sha.
#
# No-CI merge gate (Fix 2): under an UNATTENDED yolo=on merge, this refuses when
# the PR's CI validation cannot be confirmed - pr_checks is 0, unknown, or unset -
# because a "green" with no CI checks validated nothing. It escalates for the
# captain's explicit word instead. An explicit captain merge is always allowed:
# pass --captain-approved (the standing captain authorization for this merge) to
# proceed on a no-CI PR. yolo=off already means the captain approves each merge,
# so the gate does not apply there. Absent CI is a legitimate repo posture (CI on
# the default branch only); the gate only stops calling it validated and stops an
# unattended merge on it, never brands the repo broken.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-approved] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-approved] [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-approved] [-- <extra gh-axi pr merge args>]}
shift 2
# Consume fm-pr-merge-level flags up to the optional -- separator; everything
# after -- is forwarded verbatim to gh-axi pr merge.
CAPTAIN_APPROVED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain-approved) CAPTAIN_APPROVED=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

# No-CI merge gate: refuse an unattended yolo merge that cannot confirm CI
# validation, and escalate for the captain's explicit word instead. An explicit
# captain merge (--captain-approved) is always allowed, even on a no-CI PR.
YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$YOLO" = on ] && [ "$CAPTAIN_APPROVED" != 1 ]; then
  PR_CHECKS=$(grep '^pr_checks=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$PR_CHECKS" in
    ''|unknown|0)
      echo "error: unattended yolo merge refused - PR CI validation could not be confirmed (pr_checks=${PR_CHECKS:-<unset>}). A green with no CI checks validated nothing; escalate to the captain and merge only on explicit approval, then re-run with --captain-approved." >&2
      exit 3 ;;
  esac
fi

# Attribution marker, written BEFORE the merge so firstmate's own merge can never
# race into a false unattributed reading. Keyed by the unique PR URL (number),
# never by branch name.
MERGED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
grep -qxF "merged_by_firstmate=$URL" "$META" || echo "merged_by_firstmate=$URL" >> "$META"
echo "merged_ts=$MERGED_TS" >> "$META"

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"

# The merge succeeded (set -e would have exited otherwise). Record the merge
# commit best-effort so teardown containment and the attribution record agree on
# the sha; its absence never affects authorship (the pre-merge marker owns that).
if command -v gh >/dev/null 2>&1 && MC=$(gh pr view "$URL" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null) && [ -n "$MC" ]; then
  echo "merged_commit=$MC" >> "$META"
fi
