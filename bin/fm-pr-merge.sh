#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Before merging, bin/fm-evidence-check.sh runs against the actual GitHub PR
# head - gh-axi pr merge lands whatever is currently on the PR branch on
# GitHub, not necessarily the local task worktree's HEAD, so the head is
# resolved the same way bin/fm-review-diff.sh does: a freshly fetched
# refs/pull/<n>/head first, falling back to the pr_head= recorded by
# bin/fm-pr-check.sh, and only then to the local worktree HEAD with a
# warning. The check is scoped to the directories this PR's own commits
# touched (a best-effort diff against the worktree's origin default branch,
# or the local main/master branch when no remote default can be resolved),
# so a pre-existing unrelated leftover pair elsewhere in the repo tree can
# never refuse a merge it has nothing to do with; when no base can be
# determined at all, the check falls back to scanning the whole ref, but
# when a base is found and every changed path is root-level (no directory
# component to scope to), the check is skipped rather than widened back to
# the whole ref. A byte-identical before/after evidence image pair with no
# opt-out marker refuses the merge. bin/fm-evidence-check.sh's own header
# comment owns the pairing convention and opt-out mechanism. If the task's
# recorded worktree is missing or not a git repository, no ref can be
# resolved at all, or the check itself cannot run (e.g. missing python3), a
# loud warning goes to stderr and the merge still proceeds unverified rather
# than failing closed.
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
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# gh-axi pr merge lands whatever is currently on GitHub as the PR head, which
# may differ from the local task worktree's HEAD (e.g. a pooled project clone
# that has not fetched the latest push). Resolve the actual remote PR head the
# same way bin/fm-review-diff.sh does before running the evidence check
# against it, so stale local state can never hide the real, mergeable content.
fetch_pull_head() {
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin \
    "+refs/pull/$PR_NUMBER/head:refs/fm-merge/pull/$PR_NUMBER/head" >/dev/null 2>&1 || return 1
  git -C "$WT" rev-parse --verify "refs/fm-merge/pull/$PR_NUMBER/head^{commit}" 2>/dev/null
}

resolve_pr_head() {
  local recorded_head=$1 resolved
  if resolved=$(fetch_pull_head) && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
    return 0
  fi
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

# Best-effort base for scoping the evidence check to paths this PR actually
# changed. Prints nothing and fails when no base can be determined; the
# caller then falls back to scanning the whole ref rather than treating that
# as an error.
resolve_evidence_base() {
  local remote_default resolved branch
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    remote_default=$(git -C "$WT" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
    if [ -n "$remote_default" ] && git -C "$WT" fetch --quiet origin \
      "+refs/heads/$remote_default:refs/fm-merge/base/$remote_default" >/dev/null 2>&1; then
      resolved=$(git -C "$WT" rev-parse --verify -q \
        "refs/fm-merge/base/$remote_default^{commit}" 2>/dev/null || true)
      if [ -n "$resolved" ] && [ "$resolved" != "$EVIDENCE_REF" ]; then
        printf '%s' "$resolved"
        return 0
      fi
    fi
  fi
  for branch in main master; do
    resolved=$(git -C "$WT" rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ "$resolved" != "$EVIDENCE_REF" ]; then
      printf '%s' "$resolved"
      return 0
    fi
  done
  return 1
}

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$WT" ] && [ -d "$WT" ] && git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
  PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  EVIDENCE_REF=
  if PR_HEAD=$(resolve_pr_head "$PR_HEAD_RECORDED"); then
    EVIDENCE_REF=$PR_HEAD
  elif git -C "$WT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    EVIDENCE_REF=$(git -C "$WT" rev-parse HEAD)
    echo "warning: PR head unavailable; evidence check may lag the open PR (using local worktree HEAD)" >&2
  fi
  if [ -n "$EVIDENCE_REF" ]; then
    EVIDENCE_PATHSPECS=()
    EVIDENCE_BASE_RESOLVED=false
    if EVIDENCE_BASE=$(resolve_evidence_base); then
      diff_output=$(git -C "$WT" diff --name-only "$EVIDENCE_BASE...$EVIDENCE_REF" -- 2>/dev/null) \
        && diff_rc=0 || diff_rc=$?
      if [ "$diff_rc" -eq 0 ]; then
        EVIDENCE_BASE_RESOLVED=true
        while IFS= read -r changed_dir; do
          [ -n "$changed_dir" ] && [ "$changed_dir" != "." ] || continue
          EVIDENCE_PATHSPECS+=("$changed_dir")
        done < <(printf '%s' "$diff_output" \
          | while IFS= read -r changed_path; do dirname "$changed_path"; done \
          | sort -u)
      else
        echo "warning: evidence check base diff for task $ID failed (exit $diff_rc); scanning entire ref unscoped" >&2
      fi
    fi
    if "$EVIDENCE_BASE_RESOLVED" && [ "${#EVIDENCE_PATHSPECS[@]}" -eq 0 ]; then
      echo "warning: evidence check SKIPPED for task $ID; PR changed no paths with a directory component to scope the check to" >&2
    else
      evidence_rc=0
      "$SCRIPT_DIR/fm-evidence-check.sh" --ref "$EVIDENCE_REF" --root "$WT" -- \
        "${EVIDENCE_PATHSPECS[@]+"${EVIDENCE_PATHSPECS[@]}"}" || evidence_rc=$?
      case "$evidence_rc" in
        0) ;;
        1)
          echo "error: byte-identical before/after evidence image pair detected, merge refused" >&2
          exit 1
          ;;
        *)
          echo "warning: evidence check for task $ID could not run (exit $evidence_rc); merging unverified" >&2
          ;;
      esac
    fi
  else
    echo "warning: evidence check SKIPPED for task $ID; no resolvable PR head or worktree HEAD, merging unverified" >&2
  fi
else
  echo "warning: evidence check SKIPPED for task $ID; recorded worktree (${WT:-<empty>}) is missing or not a git repository, merging unverified" >&2
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
