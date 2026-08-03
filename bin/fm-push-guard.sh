#!/usr/bin/env bash
# fm-push-guard.sh - refuse a task-branch push that could discard remote work.
#
# Usage:
#   fm-push-guard.sh
#   fm-push-guard.sh <remote> <remote-branch>
#
# With no arguments, the current branch's configured upstream is the target.
# The explicit form is for a first push before an upstream exists; both the
# configured remote name and exact remote branch must be supplied.
#
# The guard contacts the remote immediately before the push and fetches the
# exact target ref into a temporary private ref. It passes when that remote tip
# is an ancestor of HEAD. If histories diverged, it also passes when every
# remote-only single-parent commit has a verbatim patch-equivalent commit in the
# local-only history, which permits a content-preserving rebase or cherry-pick.
# A merge, empty patch, unreachable remote, missing upstream, malformed target,
# or any other result that cannot prove preservation fails closed.
#
# A provably absent remote branch passes only in the explicit two-argument form,
# allowing the first push of a new task branch without treating an offline
# remote as an empty one. This script has no bypass: discarding remote work is a
# captain-level operation and must not be normalized as a worker escape hatch.
set -u
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'error: fm-push-guard: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

case "$#" in
  0|2) ;;
  *) fail "usage: fm-push-guard.sh [<remote> <remote-branch>]" ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 \
  || fail "current directory is not inside a git worktree"

local_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
  || fail "HEAD is detached; cannot determine the task branch"
explicit_target=0
if [ "$#" -eq 2 ]; then
  explicit_target=1
  remote=$1
  remote_branch=${2#refs/heads/}
else
  remote=$(git config --get "branch.$local_branch.remote" 2>/dev/null || true)
  merge_ref=$(git config --get "branch.$local_branch.merge" 2>/dev/null || true)
  [ -n "$remote" ] && [ -n "$merge_ref" ] \
    || fail "branch '$local_branch' has no upstream; name the exact configured remote and remote branch for a first push"
  case "$merge_ref" in
    refs/heads/*) remote_branch=${merge_ref#refs/heads/} ;;
    *) fail "upstream for '$local_branch' is ambiguous: expected refs/heads/*, got '$merge_ref'" ;;
  esac
fi

[ -n "$remote" ] && [ "$remote" != . ] \
  || fail "remote target is ambiguous or local-only: '$remote'"
git remote get-url "$remote" >/dev/null 2>&1 \
  || fail "remote '$remote' is not a configured git remote"
git check-ref-format "refs/heads/$remote_branch" >/dev/null 2>&1 \
  || fail "remote branch '$remote_branch' is not a valid branch name"

target_ref="refs/heads/$remote_branch"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-guard.XXXXXX") || exit 1
guard_ref="refs/fm-push-guard/$$"
# shellcheck disable=SC2329 # Invoked indirectly by the traps below.
cleanup() {
  git update-ref -d "$guard_ref" >/dev/null 2>&1 || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if git ls-remote --exit-code --heads "$remote" "$target_ref" \
    > "$tmp_root/ls-remote.out" 2> "$tmp_root/ls-remote.err"; then
  :
else
  remote_status=$?
  if [ "$remote_status" -eq 2 ] && [ "$explicit_target" -eq 1 ]; then
    printf "fm-push-guard: safe: remote branch '%s/%s' does not exist; first push may create it.\n" \
      "$remote" "$remote_branch"
    exit 0
  fi
  printf "error: fm-push-guard: cannot determine remote head '%s/%s'; refusing the push.\n" \
    "$remote" "$remote_branch" >&2
  if [ "$remote_status" -eq 2 ]; then
    printf 'error: the configured upstream branch is absent; pass an explicit target only for a deliberate first push.\n' >&2
  else
    sed 's/^/remote: /' "$tmp_root/ls-remote.err" >&2
  fi
  exit 1
fi

line_count=$(wc -l < "$tmp_root/ls-remote.out" | tr -d ' ')
[ "$line_count" = 1 ] \
  || fail "remote head '$remote/$remote_branch' is ambiguous ($line_count matches)"
remote_advertised=$(awk 'NR == 1 { print $1 }' "$tmp_root/ls-remote.out")
[ -n "$remote_advertised" ] \
  || fail "remote head '$remote/$remote_branch' was advertised without an object id"

if ! git fetch --quiet --no-tags "$remote" "+$target_ref:$guard_ref" \
    > "$tmp_root/fetch.out" 2> "$tmp_root/fetch.err"; then
  printf "error: fm-push-guard: cannot fetch remote head '%s/%s'; refusing the push.\n" \
    "$remote" "$remote_branch" >&2
  sed 's/^/remote: /' "$tmp_root/fetch.err" >&2
  exit 1
fi
remote_head=$(git rev-parse --verify "$guard_ref^{commit}" 2>/dev/null) \
  || fail "remote head '$remote/$remote_branch' is not a commit"
[ "$remote_head" = "$remote_advertised" ] \
  || fail "remote head '$remote/$remote_branch' changed while it was being checked; retry immediately before pushing"
local_head=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || fail "local HEAD is not a commit"

if git merge-base --is-ancestor "$remote_head" "$local_head"; then
  printf "fm-push-guard: safe: '%s/%s' is an ancestor of local HEAD.\n" \
    "$remote" "$remote_branch"
  exit 0
fi

local_patches="$tmp_root/local-patches"
: > "$local_patches"
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  parent_count=$(git rev-list --parents -n 1 "$commit" | awk '{ print NF - 1 }')
  [ "$parent_count" -eq 1 ] || continue
  patch_id=$(git show --no-ext-diff --pretty=format: --binary "$commit" \
    | git patch-id --verbatim | awk 'NR == 1 { print $1 }')
  [ -n "$patch_id" ] && printf '%s\n' "$patch_id" >> "$local_patches"
done < <(git rev-list "$remote_head..$local_head")

unproven="$tmp_root/unproven"
: > "$unproven"
remote_only_count=0
reproduced_count=0
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  remote_only_count=$((remote_only_count + 1))
  parent_count=$(git rev-list --parents -n 1 "$commit" | awk '{ print NF - 1 }')
  patch_id=
  if [ "$parent_count" -eq 1 ]; then
    patch_id=$(git show --no-ext-diff --pretty=format: --binary "$commit" \
      | git patch-id --verbatim | awk 'NR == 1 { print $1 }')
  fi
  if [ -n "$patch_id" ] && grep -Fqx -- "$patch_id" "$local_patches"; then
    reproduced_count=$((reproduced_count + 1))
  else
    git show -s --format='%H %s' "$commit" >> "$unproven"
  fi
done < <(git rev-list --reverse "$local_head..$remote_head")

if [ ! -s "$unproven" ] && [ "$remote_only_count" -gt 0 ]; then
  printf "fm-push-guard: safe: all %s remote-only commit(s) have patch-equivalent local replacements.\n" \
    "$reproduced_count"
  exit 0
fi

printf "error: fm-push-guard: refusing push to '%s/%s'; local HEAD would lose these remote commits or their preservation cannot be proved:\n" \
  "$remote" "$remote_branch" >&2
sed 's/^/  /' "$unproven" >&2
printf 'error: fetch and fast-forward to the actual PR head before editing; do not reconcile this history by hand.\n' >&2
exit 1
