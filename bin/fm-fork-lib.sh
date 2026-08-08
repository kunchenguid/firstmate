# shellcheck shell=bash
# Shared fork-main primitives.
# Usage: . bin/fm-fork-lib.sh
#
# Four facts are read by more than one fork script and must mean exactly the
# same thing in each, so they live here rather than being copied:
#   - which branch a remote's default is (origin/upstream default resolution);
#   - which ref is a divergence's canonical topic (published fork branch first,
#     then a local branch);
#   - whether a manifest path spec owns an actual changed path;
#   - what one commit's patch identity is.
#
# Path ownership in particular is a shared invariant between two competing
# consumers: fm-fork-merge.sh derives the affected-unit list for a conflict
# re-justification receipt from it, while fm-fork-status.sh decides "manifest
# unit <id> does not cover changed path <path>" from it. Two copies could drift
# apart and attribute a conflict to a unit the health report says does not own
# that path, which would then demand re-justification decisions for the wrong
# units.
#
# Patch identity is the same kind of shared invariant. fm-fork-merge.sh records
# the evidence that upstream accepted a divergence, and fm-fork-status.sh
# re-proves that recorded evidence. Both must compute the identity the same way
# or the merge would write proof the health owner cannot verify.

fm_fork_remote_branch() { # <repo> <remote>
  local repo=$1 remote=$2 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}" >/dev/null; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_fork_topic_ref() { # <repo> <topic>
  local repo=$1 topic=$2
  if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$topic^{commit}" >/dev/null; then
    printf 'refs/remotes/origin/%s\n' "$topic"
    return 0
  fi
  if git -C "$repo" rev-parse --verify --quiet "refs/heads/$topic^{commit}" >/dev/null; then
    printf 'refs/heads/%s\n' "$topic"
    return 0
  fi
  return 1
}

fm_fork_commit_patch_id() { # <repo> <commit>; prints the stable patch id
  # Git documents `git diff-tree` output as carrying the commit's object name,
  # which is what lets `git patch-id` map a patch identity back to its commit.
  # `--stable` is passed explicitly because Git's default is the unstable
  # algorithm and patchid.stable can change it per repository.
  local repo=$1 commit=$2 id
  id=$(git -C "$repo" diff-tree -p "$commit" | git patch-id --stable | awk 'NR == 1 { print $1 }') || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

fm_fork_path_covered() { # <manifest-spec> <actual-path>
  local spec=$1 actual=$2 prefix
  case "$spec" in
    */'**') prefix=${spec%'**'}; case "$actual" in "$prefix"*) return 0 ;; esac ;;
    */) case "$actual" in "$spec"*) return 0 ;; esac ;;
    *) [ "$actual" = "$spec" ] && return 0 ;;
  esac
  return 1
}
