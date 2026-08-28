# shellcheck shell=bash
# Shared default-branch, lifecycle-base, and primary-checkout tangle resolution.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.

# Resolve local main/master without consulting remote-tracking refs.
# Echoes the name, or returns 1.
fm_local_default_branch() {
  local dir=$1 branch
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the default branch name of the git repo at <dir>: use a recorded
# origin/HEAD only when origin is configured, then a local main/master. Lifecycle
# operations that require a fresh validated origin use fm_project_base_resolve below.
fm_default_branch() {
  local dir=$1 remotes ref
  remotes=$(git -C "$dir" remote 2>/dev/null) || return 1
  if [ -n "$remotes" ] && printf '%s\n' "$remotes" | grep -qx origin; then
    ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    case "$ref" in
      origin/?*) printf '%s\n' "${ref#origin/}"; return 0 ;;
    esac
  fi
  fm_local_default_branch "$dir"
}

# Resolve the authoritative base shared by spawn, promotion, review, local
# landing, and cleanup. Origin-backed resolution asks origin for its current
# default branch and fetches its tip. Remote-less resolution is available only
# when the caller opts in, both the authoritative project and task worktree have
# no configured remotes, and the project is registered local-only; it chooses
# local main/master without consulting stale remote-tracking refs. Any configured
# remote stays on the origin path, and PR-backed callers may additionally require
# origin in the task worktree. Inspection, fetch, and default-resolution failures
# never fall back. On success the FM_PROJECT_BASE_* values describe the base; on
# failure FM_PROJECT_BASE_ERROR describes the refusal.
FM_PROJECT_BASE_KIND=
FM_PROJECT_BASE_BRANCH=
FM_PROJECT_BASE_REF=
FM_PROJECT_BASE_COMMIT=
FM_PROJECT_BASE_ERROR=

fm_registered_project_posture() {
  local project=$1 script_dir line posture
  script_dir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  line=$("$script_dir/fm-project-mode.sh" --raw "$(basename "$project")" 2>/dev/null) || return 1
  posture=${line%% *}
  case "$posture" in
    no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$posture"
}

fm_project_base_resolve() {
  local project=$1 worktree=$2 allow_remoteless=${3:-no} require_task_origin=${4:-no}
  local project_remotes worktree_remotes remote_dir remote_head default ref commit posture
  FM_PROJECT_BASE_KIND=
  FM_PROJECT_BASE_BRANCH=
  FM_PROJECT_BASE_REF=
  FM_PROJECT_BASE_COMMIT=
  FM_PROJECT_BASE_ERROR=

  worktree_remotes=$(git -C "$worktree" remote 2>/dev/null) || {
    FM_PROJECT_BASE_ERROR="could not inspect configured remotes for task worktree '$worktree'"
    return 1
  }
  project_remotes=$(git -C "$project" remote 2>/dev/null) || {
    FM_PROJECT_BASE_ERROR="could not inspect configured remotes for authoritative project '$project'"
    return 1
  }

  if [ -z "$worktree_remotes" ] && [ -z "$project_remotes" ]; then
    if [ "$allow_remoteless" != yes ]; then
      FM_PROJECT_BASE_ERROR="task worktree '$worktree' has no origin remote; this lifecycle requires a valid origin"
      return 1
    fi
    posture=$(fm_registered_project_posture "$project") || {
      FM_PROJECT_BASE_ERROR="could not resolve the registered posture for project '$(basename "$project")'"
      return 1
    }
    if [ "$posture" != local-only ]; then
      FM_PROJECT_BASE_ERROR="registered $posture project '$(basename "$project")' requires a valid origin"
      return 1
    fi
    default=$(fm_local_default_branch "$project") || {
      FM_PROJECT_BASE_ERROR="could not determine the local default branch for remote-less project '$project'"
      return 1
    }
    ref="refs/heads/$default"
    commit=$(git -C "$project" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || {
      FM_PROJECT_BASE_ERROR="local default branch '$default' is not a commit for remote-less project '$project'"
      return 1
    }
    git -C "$worktree" cat-file -e "$commit^{commit}" 2>/dev/null || {
      FM_PROJECT_BASE_ERROR="local default branch '$default' is unavailable in task worktree '$worktree'"
      return 1
    }
    FM_PROJECT_BASE_KIND=local
  else
    if [ "$require_task_origin" = yes ] \
        && ! printf '%s\n' "$worktree_remotes" | grep -qx origin; then
      FM_PROJECT_BASE_ERROR="task worktree '$worktree' has no origin remote; a PR-backed task contract requires origin"
      return 1
    fi
    remote_dir=
    if printf '%s\n' "$worktree_remotes" | grep -qx origin; then
      remote_dir=$worktree
    elif printf '%s\n' "$project_remotes" | grep -qx origin; then
      remote_dir=$project
    else
      FM_PROJECT_BASE_ERROR="project '$project' or task worktree '$worktree' has configured remotes but no origin remote"
      return 1
    fi
    remote_head=$(git -C "$remote_dir" ls-remote --symref origin HEAD 2>/dev/null) || {
      FM_PROJECT_BASE_ERROR="could not fetch origin for task worktree '$worktree'"
      return 1
    }
    default=$(printf '%s\n' "$remote_head" \
      | sed -n 's/^ref: refs\/heads\/\(.*\)[[:space:]]HEAD$/\1/p' \
      | head -1)
    [ -n "$default" ] || {
      FM_PROJECT_BASE_ERROR="could not resolve origin's current default branch for task worktree '$worktree'"
      return 1
    }
    ref="refs/remotes/origin/$default"
    git -C "$remote_dir" fetch --quiet origin "+refs/heads/$default:$ref" || {
      FM_PROJECT_BASE_ERROR="could not fetch 'origin/$default' for task worktree '$worktree'"
      return 1
    }
    git -C "$remote_dir" symbolic-ref refs/remotes/origin/HEAD "$ref" 2>/dev/null || {
      FM_PROJECT_BASE_ERROR="could not record origin's current default branch for task worktree '$worktree'"
      return 1
    }
    commit=$(git -C "$worktree" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || {
      FM_PROJECT_BASE_ERROR="'origin/$default' is not a commit for task worktree '$worktree'"
      return 1
    }
    FM_PROJECT_BASE_KIND=origin
  fi

  FM_PROJECT_BASE_BRANCH=$default
  FM_PROJECT_BASE_REF=$ref
  FM_PROJECT_BASE_COMMIT=$commit
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}
