#!/usr/bin/env bash
# Deterministic identity and content facts for one existing git worktree.
#
# This script is the SINGLE OWNER of the facts a governed resume dispatch
# authenticates (bin/fm-spawn.sh --resume-worktree). Every fact below comes from
# git plumbing; no model reasoning establishes any of them, and every command
# this script runs is READ-ONLY. In particular it never uses `git write-tree`
# for the staged state: write-tree writes to the object database and can race a
# live worker in the very worktree being authenticated. `git hash-object`
# without -w computes a digest and writes nothing.
#
# Usage:
#   fm-worktree-identity.sh facts <path>        # key=value lines, one per fact
#   fm-worktree-identity.sh fingerprint <path>  # the fingerprint digest alone
#
# Or source it as a library and call fm_worktree_identity_collect <path>, which
# sets FM_WT_PATH, FM_WT_REPO_COMMON_DIR, FM_WT_GIT_DIR, FM_WT_HEAD_COMMIT,
# FM_WT_HEAD_REF, FM_WT_DETACHED, FM_WT_STAGED_HASH, FM_WT_UNSTAGED_HASH,
# FM_WT_UNTRACKED_DIGEST, FM_WT_UNTRACKED_PRESENT, FM_WT_DIRTY and
# FM_WT_FINGERPRINT, or leaves FM_WT_IDENTITY_ERROR holding an actionable
# diagnostic and returns nonzero.
#
# Facts, and what each one is for:
#   path                canonical absolute worktree root (`cd` + `pwd -P`), which
#                       must equal the worktree's own `--show-toplevel`.
#   worktree_git_dir    `--absolute-git-dir`. This is IDENTITY: it is unique per
#                       worktree, so it is the only fact that may decide two
#                       worktrees are the same one.
#   repo_common_dir     `--git-common-dir`. This confirms same-REPOSITORY
#                       membership and nothing more. Sharing a repository, or a
#                       branch, must never be sufficient to treat two worktrees
#                       as interchangeable, so this value is never an identity
#                       test on its own.
#   head_commit         `--verify HEAD`, empty on an unborn branch.
#   head_ref            `symbolic-ref --quiet HEAD`, empty when HEAD is detached.
#   detached            1 when head_ref is empty, else 0.
#   staged_hash         digest of `git diff --cached --binary`.
#   unstaged_hash       digest of `git diff --binary`.
#   untracked_digest    digest of `git ls-files --others --exclude-standard -z`.
#   untracked_present   1 when that listing is non-empty, else 0.
#   dirty               1 when any of the three deltas is non-empty, else 0.
#                       Dirty is a SUPPORTED state here, recorded rather than
#                       normalized; this script never judges it.
#   fingerprint         one digest over path, worktree_git_dir, repo_common_dir,
#                       head_commit, head_ref, staged_hash, unstaged_hash and
#                       untracked_digest. Computing it twice - at authentication
#                       and again once the agent's shell has settled in the
#                       worktree - is what detects mutation or rebinding inside
#                       the authorize-then-dispatch window.
#
# The digest is `git hash-object --stdin`, deliberately: git is already a hard
# dependency of everything this feature touches, so the fingerprint needs no
# external digest tool and cannot vary with which one happens to be installed.
# Fingerprints are only ever compared against another fingerprint taken by this
# same script in the same repository, so the repository's object format is a
# non-issue.
set -u

FM_WT_IDENTITY_ERROR=

# Digest <stdin> using the worktree's own git. Never -w: nothing is written.
fm_worktree_identity_digest() { # <worktree>
  git -C "$1" hash-object --stdin 2>/dev/null
}

fm_worktree_identity_canonical() { # <path>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

# Establish every fact for <path>, or fail with an actionable diagnostic.
fm_worktree_identity_collect() { # <path>
  local path=$1 top top_real untracked
  FM_WT_IDENTITY_ERROR=
  FM_WT_PATH=
  FM_WT_REPO_COMMON_DIR=
  FM_WT_GIT_DIR=
  FM_WT_HEAD_COMMIT=
  FM_WT_HEAD_REF=
  FM_WT_DETACHED=0
  FM_WT_STAGED_HASH=
  FM_WT_UNSTAGED_HASH=
  FM_WT_UNTRACKED_DIGEST=
  FM_WT_UNTRACKED_PRESENT=0
  FM_WT_DIRTY=0
  FM_WT_FINGERPRINT=

  if [ -z "$path" ]; then
    FM_WT_IDENTITY_ERROR="no worktree path was given"
    return 1
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_WT_IDENTITY_ERROR="'$path' does not exist"
    return 1
  fi
  if [ ! -d "$path" ]; then
    FM_WT_IDENTITY_ERROR="'$path' is not a directory"
    return 1
  fi
  if ! FM_WT_PATH=$(fm_worktree_identity_canonical "$path"); then
    FM_WT_IDENTITY_ERROR="'$path' is not a readable directory"
    return 1
  fi

  # An empty toplevel must never reach `cd`: bash before 5.3 accepts `cd ""` as
  # a successful no-op, which would silently resolve to this script's own cwd.
  top=$(git -C "$FM_WT_PATH" rev-parse --show-toplevel 2>/dev/null || true)
  top_real=
  if [ -n "$top" ]; then
    top_real=$(fm_worktree_identity_canonical "$top") || top_real=
  fi
  if [ -z "$top_real" ]; then
    FM_WT_IDENTITY_ERROR="'$FM_WT_PATH' is not inside a git worktree"
    return 1
  fi
  if [ "$top_real" != "$FM_WT_PATH" ]; then
    FM_WT_IDENTITY_ERROR="'$FM_WT_PATH' is a subdirectory of worktree root '$top_real', not a worktree root"
    return 1
  fi

  FM_WT_GIT_DIR=$(git -C "$FM_WT_PATH" rev-parse --absolute-git-dir 2>/dev/null) &&
    FM_WT_GIT_DIR=$(fm_worktree_identity_canonical "$FM_WT_GIT_DIR") || FM_WT_GIT_DIR=
  if [ -z "$FM_WT_GIT_DIR" ]; then
    FM_WT_IDENTITY_ERROR="the git directory of '$FM_WT_PATH' could not be resolved"
    return 1
  fi
  FM_WT_REPO_COMMON_DIR=$(git -C "$FM_WT_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    FM_WT_REPO_COMMON_DIR=$(fm_worktree_identity_canonical "$FM_WT_REPO_COMMON_DIR") || FM_WT_REPO_COMMON_DIR=
  if [ -z "$FM_WT_REPO_COMMON_DIR" ]; then
    FM_WT_IDENTITY_ERROR="the repository of '$FM_WT_PATH' could not be resolved"
    return 1
  fi

  # An unborn branch has no HEAD commit; that is a legal state to resume into,
  # so it records an empty commit rather than refusing.
  FM_WT_HEAD_COMMIT=$(git -C "$FM_WT_PATH" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  FM_WT_HEAD_REF=$(git -C "$FM_WT_PATH" symbolic-ref --quiet HEAD 2>/dev/null || true)
  [ -n "$FM_WT_HEAD_REF" ] || FM_WT_DETACHED=1

  FM_WT_STAGED_HASH=$(git -C "$FM_WT_PATH" diff --cached --binary 2>/dev/null |
    fm_worktree_identity_digest "$FM_WT_PATH") || FM_WT_STAGED_HASH=
  FM_WT_UNSTAGED_HASH=$(git -C "$FM_WT_PATH" diff --binary 2>/dev/null |
    fm_worktree_identity_digest "$FM_WT_PATH") || FM_WT_UNSTAGED_HASH=
  if [ -z "$FM_WT_STAGED_HASH" ] || [ -z "$FM_WT_UNSTAGED_HASH" ]; then
    FM_WT_IDENTITY_ERROR="the working-tree state of '$FM_WT_PATH' could not be digested"
    return 1
  fi

  untracked=$(git -C "$FM_WT_PATH" ls-files --others --exclude-standard -z 2>/dev/null || true)
  [ -z "$untracked" ] || FM_WT_UNTRACKED_PRESENT=1
  FM_WT_UNTRACKED_DIGEST=$(printf '%s' "$untracked" |
    fm_worktree_identity_digest "$FM_WT_PATH") || FM_WT_UNTRACKED_DIGEST=
  if [ -z "$FM_WT_UNTRACKED_DIGEST" ]; then
    FM_WT_IDENTITY_ERROR="the untracked-file listing of '$FM_WT_PATH' could not be digested"
    return 1
  fi

  # The empty-diff digest is the digest of empty input, so comparing against it
  # decides dirtiness without a second status read.
  local empty
  empty=$(printf '%s' '' | fm_worktree_identity_digest "$FM_WT_PATH") || empty=
  if [ -z "$empty" ]; then
    FM_WT_IDENTITY_ERROR="the empty-input digest for '$FM_WT_PATH' could not be computed"
    return 1
  fi
  if [ "$FM_WT_STAGED_HASH" != "$empty" ] ||
    [ "$FM_WT_UNSTAGED_HASH" != "$empty" ] ||
    [ "$FM_WT_UNTRACKED_PRESENT" = 1 ]; then
    FM_WT_DIRTY=1
  fi

  FM_WT_FINGERPRINT=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$FM_WT_PATH" "$FM_WT_GIT_DIR" "$FM_WT_REPO_COMMON_DIR" \
    "$FM_WT_HEAD_COMMIT" "$FM_WT_HEAD_REF" \
    "$FM_WT_STAGED_HASH" "$FM_WT_UNSTAGED_HASH" "$FM_WT_UNTRACKED_DIGEST" |
    fm_worktree_identity_digest "$FM_WT_PATH") || FM_WT_FINGERPRINT=
  if [ -z "$FM_WT_FINGERPRINT" ]; then
    FM_WT_IDENTITY_ERROR="the workspace fingerprint of '$FM_WT_PATH' could not be computed"
    return 1
  fi
  return 0
}

fm_worktree_identity_print_facts() {
  printf 'path=%s\n' "$FM_WT_PATH"
  printf 'worktree_git_dir=%s\n' "$FM_WT_GIT_DIR"
  printf 'repo_common_dir=%s\n' "$FM_WT_REPO_COMMON_DIR"
  printf 'head_commit=%s\n' "$FM_WT_HEAD_COMMIT"
  printf 'head_ref=%s\n' "$FM_WT_HEAD_REF"
  printf 'detached=%s\n' "$FM_WT_DETACHED"
  printf 'staged_hash=%s\n' "$FM_WT_STAGED_HASH"
  printf 'unstaged_hash=%s\n' "$FM_WT_UNSTAGED_HASH"
  printf 'untracked_digest=%s\n' "$FM_WT_UNTRACKED_DIGEST"
  printf 'untracked_present=%s\n' "$FM_WT_UNTRACKED_PRESENT"
  printf 'dirty=%s\n' "$FM_WT_DIRTY"
  printf 'fingerprint=%s\n' "$FM_WT_FINGERPRINT"
}

fm_worktree_identity_usage() {
  cat <<'EOF'
Usage: fm-worktree-identity.sh facts <worktree-path>
       fm-worktree-identity.sh fingerprint <worktree-path>

Prints deterministic, read-only git facts for an existing worktree root, or
exits 1 with an actionable diagnostic on stderr. See the script header for what
each fact means and which one is identity.
EOF
}

# Only run the CLI when executed, so sourcing stays side-effect free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  facts | fingerprint)
    if [ "$#" -ne 2 ]; then
      fm_worktree_identity_usage >&2
      exit 2
    fi
    if ! fm_worktree_identity_collect "$2"; then
      echo "error: $FM_WT_IDENTITY_ERROR" >&2
      exit 1
    fi
    if [ "$1" = facts ]; then
      fm_worktree_identity_print_facts
    else
      printf '%s\n' "$FM_WT_FINGERPRINT"
    fi
    ;;
  -h | --help)
    fm_worktree_identity_usage
    ;;
  *)
    fm_worktree_identity_usage >&2
    exit 2
    ;;
  esac
fi
