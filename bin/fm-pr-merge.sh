#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# A task released before its pull request lands keeps a durable landing record
# instead of a meta, and this path lands it through that record. A task released
# before landing records existed keeps neither, so its record is rebuilt from a
# forge read of the request. Either way the request must still be open at its
# forge, and a request that resolves to nothing is refused as before.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
# Landing identity comes from whichever durable record the task still has, and
# from the pull request itself when it has none. A live task keeps its meta and
# takes the unchanged path below. A released task keeps only the landing record
# bin/fm-teardown.sh left behind, and a task released before landing records
# existed keeps neither: its pull request is then the authority for its own
# identity and the record is rebuilt from a forge read, never from the caller.
LANDING="$STATE/$ID.landing"
REBUILD=0
RECORD=$(fm_pr_identity_record_path "$STATE" "$ID") || { RECORD=$LANDING; REBUILD=1; }

if [ "$RECORD" != "$LANDING" ]; then
  if [ ! -f "$RECORD" ] || [ -L "$RECORD" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
else
  # A released task has no worktree, no worker, and nothing left to tear down,
  # and the merge below is synchronous, so no merge poll is armed for it. The
  # forge decides here instead: the request must still be open, and the landing
  # record is then written from what the forge reported rather than from a stale
  # local value or anything the caller asserted.
  RECORD_PROJECT=
  [ "$REBUILD" = 1 ] \
    || RECORD_PROJECT=$(grep '^project=' "$RECORD" | tail -1 | cut -d= -f2- || true)
  if ! fm_pr_forge_view "$URL"; then
    if [ "$REBUILD" = 1 ]; then
      echo "error: task metadata is unavailable" >&2
      echo "No record for task $ID, and $URL could not be resolved at its forge." >&2
    else
      echo "error: $URL could not be resolved at its forge" >&2
    fi
    exit 1
  fi
  if [ "$FM_PR_FORGE_STATE" != open ]; then
    if [ "$REBUILD" = 1 ]; then
      echo "error: task metadata is unavailable" >&2
      echo "No record for task $ID, and $URL is $FM_PR_FORGE_STATE at its forge rather than an open pull request." >&2
    else
      echo "error: $URL is $FM_PR_FORGE_STATE at its forge rather than an open pull request" >&2
    fi
    exit 1
  fi
  fm_pr_landing_record_write "$STATE" "$ID" "$URL" "$FM_PR_FORGE_HEAD" "$RECORD_PROJECT" || {
    echo "error: task landing record could not be written" >&2
    exit 1
  }
  [ "$REBUILD" = 0 ] || printf 'rebuilt: state/%s.landing from %s\n' "$ID" "$URL"
fi
grep -qxF "pr=$URL" "$RECORD" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# The landing record exists only so a released task's pull request can still be
# landed here, so it is spent once that merge succeeds. It is retained while a
# merge poll is still armed against it, because the poll's registration binds to
# it and the watcher would otherwise reject an authentic check.
if [ "$RECORD" = "$LANDING" ] && [ -f "$LANDING" ] && [ ! -L "$LANDING" ] \
  && [ ! -e "$STATE/$ID.check.sh" ] && [ ! -L "$STATE/$ID.check.sh" ] \
  && [ ! -e "$STATE/$ID.pr-poll" ] && [ ! -L "$STATE/$ID.pr-poll" ]; then
  rm -f -- "$LANDING" || true
fi
