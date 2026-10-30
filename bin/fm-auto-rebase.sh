#!/usr/bin/env bash
# Rebase a task branch onto its base without a model in the loop, so a worker
# spends model turns only on a real conflict.
#
# Usage: fm-auto-rebase.sh --mode <no-mistakes|direct-PR|local-only> [--base <branch>] [--repo <dir>]
#
# Runs inside a worker's task worktree (--repo, default the current directory)
# and acts only on the branch checked out there:
#   - The base is --base (the task's recorded base branch) or else the
#     project's default branch: origin/HEAD, then main, then master.
#   - local-only rebases onto the local base branch, never fetches, and never
#     pushes, because its landing fast-forwards that local branch.
#   - no-mistakes and direct-PR fetch origin and rebase onto origin/<base>.
#     Only direct-PR pushes, and only when origin already has the task branch:
#     a no-mistakes pipeline owns its own push, and a branch with no remote
#     copy is published by the delivery path, not here.
#   - The push is `--force-with-lease` pinned to the remote tip read before
#     the rebase, for refs/heads/<branch> only, and is refused when that remote
#     tip carries commits the local branch lacks (checked before rebasing),
#     so no remote work is lost.
#   - A branch that already contains the base is left alone (no rebase, no
#     push).
#   - On a conflict the rebase is aborted and the branch is left exactly where
#     it was; the conflicted paths are printed and the exit is 1.
# It refuses a detached HEAD, the base branch itself, tracked uncommitted
# changes, and a rebase, merge, or cherry-pick already in progress. No other
# local branch is written; fetch updates only remote-tracking refs.
#
# Exit: 0 rebased (and pushed when applicable) or already current,
#       1 conflict (aborted, branch untouched), 2 any other refusal or failure.
# tests/fm-auto-rebase.test.sh covers the clean, current, conflict, and
# local-only cases.
set -uo pipefail

usage() {
  echo "usage: fm-auto-rebase.sh --mode <no-mistakes|direct-PR|local-only> [--base <branch>] [--repo <dir>]" >&2
  exit 2
}

fail() {  # <message>
  echo "fm-auto-rebase: $1" >&2
  exit 2
}

mode='' base='' repo=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
    --base) [ "$#" -ge 2 ] || usage; base=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; repo=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) usage ;;
esac

g() { git -C "$repo" "$@"; }

g rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$repo is not a git work tree"
branch=$(g symbolic-ref --quiet --short HEAD) || fail "HEAD is detached; check out the task branch first"
git_dir=$(g rev-parse --absolute-git-dir) || fail "cannot read the git directory"
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  [ ! -e "$git_dir/$marker" ] || fail "a rebase, merge, or cherry-pick is already in progress; finish or abort it first"
done
[ -z "$(g status --porcelain --untracked-files=no)" ] || fail "uncommitted changes to tracked files; commit them first"

if [ -z "$base" ]; then
  base=$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) && base=${base#origin/}
  if [ -z "$base" ]; then
    for b in main master; do
      if g show-ref --verify --quiet "refs/heads/$b" || g show-ref --verify --quiet "refs/remotes/origin/$b"; then
        base=$b
        break
      fi
    done
  fi
  [ -n "$base" ] || fail "cannot determine the default branch (origin/HEAD, main, or master); pass --base"
fi
git check-ref-format --branch "$base" >/dev/null 2>&1 || fail "invalid base branch '$base'"
[ "$branch" != "$base" ] || fail "the checked-out branch is the base '$base' itself; refusing"

lease=''
if [ "$mode" = local-only ]; then
  onto="refs/heads/$base"
else
  # An explicit refspec updates exactly the two remote-tracking refs involved,
  # whatever the clone's configured fetch refspecs say.
  g fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 \
    || fail "cannot fetch $base from origin"
  if g ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    g fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 \
      || fail "cannot fetch $branch from origin"
    lease=$(g rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") \
      || fail "cannot read origin's copy of $branch"
  fi
  onto="refs/remotes/origin/$base"
fi
onto_sha=$(g rev-parse --verify --quiet "$onto^{commit}") || fail "base $onto does not exist"
old=$(g rev-parse HEAD)

if g merge-base --is-ancestor "$onto_sha" "$old"; then
  echo "current: $branch already contains $onto"
  exit 0
fi

push=0
if [ "$mode" = direct-PR ] && [ -n "$lease" ]; then
  g merge-base --is-ancestor "$lease" "$old" \
    || fail "origin's $branch has commits the local branch lacks; not rebasing - reconcile them by hand"
  push=1
fi

if ! out=$(g rebase "$onto_sha" 2>&1); then
  conflicts=$(g diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
  if [ -e "$git_dir/rebase-merge" ] || [ -e "$git_dir/rebase-apply" ]; then
    g rebase --abort >/dev/null 2>&1 || fail "rebase failed and could not be aborted; run 'git rebase --abort' by hand"
  fi
  [ "$(g rev-parse HEAD)" = "$old" ] && [ "$(g symbolic-ref --quiet --short HEAD)" = "$branch" ] \
    || fail "rebase failed and $branch did not return to $old; inspect by hand"
  if [ -n "$conflicts" ]; then
    echo "conflict: $branch onto $onto in: ${conflicts% }; rebase aborted, $branch left at $old" >&2
    exit 1
  fi
  printf '%s\n' "$out" >&2
  fail "rebase onto $onto failed without a conflict; $branch left at $old"
fi
echo "rebased: $branch $old -> $(g rev-parse HEAD) onto $onto"

if [ "$push" = 1 ]; then
  g push -q --force-with-lease="refs/heads/$branch:$lease" origin "HEAD:refs/heads/$branch" \
    || fail "push of $branch refused"
  echo "pushed: $branch"
fi
exit 0
