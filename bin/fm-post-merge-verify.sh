#!/usr/bin/env bash
# Verify that approved content is present on a project's default branch before
# a task is considered complete (post-merge verification).
#
# Usage: fm-post-merge-verify.sh <project-dir> <base-sha> <head-sha> [--remote <name>]
#
# Semantics: content-based, not commit-based. A task's approved content is the
# blob state of every path changed between <base-sha> and <head-sha>. After any
# merge (squash, rebase, or fast-forward), the default branch must contain the
# same blobs for those paths, whatever the resulting commit hashes. This catches
# history rewrites that drop approved work while their commits still exist as
# detached objects (see the 2026-08-02 rebase-merge incident post-mortem).
#
# Behavior:
#   - Fetches <remote> (default origin) fresh before reading the default branch.
#   - Resolves the remote default branch (remote HEAD, then main, then master).
#   - For every path changed between base and head:
#       - present at head and present with the identical blob on the default
#         branch  -> OK
#       - deleted at head and absent from the default branch -> OK
#       - anything else -> MISSING or DIFFERS (listed, exit 1)
#   - Prints one line per changed path plus a summary, exits 0 only when every
#     changed path is confirmed on the default branch.
#
# A non-zero exit means approved content is not provably on the default branch:
# stop and investigate before teardown or completion. Never force, reset, or
# re-push around this check; it is a verification gate, not a repair tool.
set -eu

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

PROJECT_DIR=${1:-}
BASE_SHA=${2:-}
HEAD_SHA=${3:-}
REMOTE=origin
if [ "${4:-}" = "--remote" ]; then
  REMOTE=${5:-}
  [ -n "$REMOTE" ] || usage
fi
if [ -z "$PROJECT_DIR" ] || [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ]; then
  usage
fi
[ -d "$PROJECT_DIR/.git" ] || { echo "error: $PROJECT_DIR is not a git repository" >&2; exit 2; }

git -C "$PROJECT_DIR" fetch -q "$REMOTE"

default_branch=$(git -C "$PROJECT_DIR" symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)
if [ -z "$default_branch" ]; then
  for candidate in "main" "master"; do
    if git -C "$PROJECT_DIR" rev-parse -q --verify "refs/remotes/$REMOTE/$candidate" >/dev/null 2>&1; then
      default_branch="$REMOTE/$candidate"
      break
    fi
  done
fi
if [ -z "$default_branch" ]; then
  echo "error: cannot resolve the default branch of remote $REMOTE" >&2
  exit 2
fi
REMOTE_HEAD=$(git -C "$PROJECT_DIR" rev-parse --verify "refs/remotes/${default_branch#*/}" 2>/dev/null || git -C "$PROJECT_DIR" rev-parse --verify "$default_branch")
git -C "$PROJECT_DIR" rev-parse -q --verify "$BASE_SHA^{commit}" >/dev/null 2>&1 \
  || { echo "error: base sha $BASE_SHA does not exist locally" >&2; exit 2; }
git -C "$PROJECT_DIR" rev-parse -q --verify "$HEAD_SHA^{commit}" >/dev/null 2>&1 \
  || { echo "error: head sha $HEAD_SHA does not exist locally" >&2; exit 2; }

failures=0
total=0
while IFS= read -r -d '' path; do
  total=$((total + 1))
  head_blob=$(git -C "$PROJECT_DIR" rev-parse -q --verify "$HEAD_SHA:$path" 2>/dev/null || true)
  remote_blob=$(git -C "$PROJECT_DIR" rev-parse -q --verify "$REMOTE_HEAD:$path" 2>/dev/null || true)
  if [ -z "$head_blob" ]; then
    if [ -z "$remote_blob" ]; then
      echo "ok (deleted)  $path"
    else
      echo "DIFFERS       $path (deleted in approved head but present on $default_branch)"
      failures=$((failures + 1))
    fi
  elif [ "$head_blob" = "$remote_blob" ]; then
    echo "ok            $path"
  else
    echo "DIFFERS       $path (approved content not on $default_branch)"
    failures=$((failures + 1))
  fi
done < <(git -C "$PROJECT_DIR" diff --name-only -z "$BASE_SHA" "$HEAD_SHA")

if [ "$total" -eq 0 ]; then
  echo "warning: no changed paths between $BASE_SHA and $HEAD_SHA" >&2
  exit 2
fi
if [ "$failures" -eq 0 ]; then
  echo "post-merge verification PASS: $total changed paths confirmed on $default_branch ($REMOTE_HEAD)"
  exit 0
fi
echo "post-merge verification FAIL: $failures of $total changed paths missing or differing on $default_branch"
exit 1
