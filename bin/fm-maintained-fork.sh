#!/usr/bin/env bash
# Integrate one explicitly selected upstream release into a maintained fork.
#
# The project registry marks the source relationship; the clone carries the
# fetch-only `upstream` (with an explicitly empty pushurl) and captain-owned
# backup `origin` remotes. This command
# fetches only an explicitly named upstream tag, merges it into an isolated
# worktree, validates the combined tree, and leaves the result on a local
# candidate branch. `accept` is the separate local-acceptance action that
# fast-forwards the deployed default branch to that candidate. Neither command
# pushes any remote.
# Usage: fm-maintained-fork.sh integrate [<project-dir-or-name>] <release> [--test-command <command>]
#        fm-maintained-fork.sh accept [<project-dir-or-name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-maintained-fork.sh integrate [<project-dir-or-name>] <release> [--test-command <command>]" >&2
  echo "       fm-maintained-fork.sh accept [<project-dir-or-name>]" >&2
}

fail() { echo "error: $*" >&2; exit 1; }

resolve_project() {
  local arg=${1:-} candidate
  [ -n "$arg" ] || { printf '%s\n' "$FM_ROOT"; return; }
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return; }
      ;;
    */*)
      [ -d "$arg" ] && { printf '%s\n' "$arg"; return; }
      ;;
    *)
      candidate="$PROJECTS/$arg"
      [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return; }
      [ -d "$arg" ] && { printf '%s\n' "$arg"; return; }
      ;;
  esac
  fail "project is not a directory: $arg"
}

project_source() {
  local project=$1 label
  label=$(basename "$(cd "$project" && pwd -P)")
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-project-mode.sh" --source "$label" 2>/dev/null
}

default_branch() {
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return
  fi
  for branch in main master; do
    git -C "$project" show-ref --verify --quiet "refs/heads/$branch" && {
      printf '%s\n' "$branch"
      return
    }
  done
  return 1
}

candidate_file() {
  printf '%s/maintained-fork/%s.candidate\n' "$STATE" "$(basename "$(cd "$1" && pwd -P)")"
}

require_maintained_fork() {
  local project=$1 origin_url upstream_url pushurl
  [ "$(project_source "$project")" = maintained-fork ] \
    || fail "project is not registered with the maintained-fork source"
  git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "project is not a git worktree: $project"
  git -C "$project" remote get-url origin >/dev/null 2>&1 \
    || fail "maintained fork requires the captain-owned origin backup remote"
  git -C "$project" remote get-url upstream >/dev/null 2>&1 \
    || fail "maintained fork requires an upstream remote"
  origin_url=$(git -C "$project" remote get-url origin)
  upstream_url=$(git -C "$project" remote get-url upstream)
  [ "$origin_url" != "$upstream_url" ] \
    || fail "maintained fork origin backup and upstream must be different remotes"
  pushurl=$(git -C "$project" config --get-regexp '^remote[.]upstream[.]pushurl$' 2>/dev/null || true)
  [ "$pushurl" = "remote.upstream.pushurl " ] \
    || fail "upstream must be fetch-only with an explicitly empty pushurl"
}

integrate() {
  local project=$1 release=$2 test_command='' default branch candidate release_sha candidate_sha marker
  require_maintained_fork "$project"
  case "$release" in
    ''|--*) fail "an upstream release tag is required" ;;
  esac
  git -C "$project" check-ref-format "refs/tags/$release" >/dev/null 2>&1 \
    || fail "invalid upstream release tag: $release"
  default=$(default_branch "$project") \
    || fail "cannot determine the project's default branch"
  [ "$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$default" ] \
    || fail "project must be checked out on its default branch: $default"
  [ -z "$(git -C "$project" status --porcelain 2>/dev/null)" ] \
    || fail "project has uncommitted changes; preserve them before integration"

  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test-command)
        [ "$#" -ge 2 ] || fail "--test-command requires a command"
        test_command=$2
        shift 2
        ;;
      *) usage; exit 2 ;;
    esac
  done

  echo "fetching upstream release $release (no push)" >&2
  git -C "$project" fetch --no-tags --quiet upstream \
    "refs/tags/$release:refs/tags/$release" \
    || fail "could not fetch upstream release tag: $release"
  release_sha=$(git -C "$project" rev-parse --verify "refs/tags/$release^{commit}") \
    || fail "upstream release is not a commit: $release"
  branch="fm/maintained-fork/$(printf '%s' "$release" | tr -c 'A-Za-z0-9._-' '-')-$release_sha"
  git -C "$project" show-ref --verify --quiet "refs/heads/$branch" \
    && fail "candidate branch already exists: $branch"
  candidate=$(mktemp -d "${TMPDIR:-/tmp}/fm-maintained-fork.XXXXXX")
  if ! git -C "$project" worktree add --quiet -b "$branch" "$candidate" "$default"; then
    rmdir "$candidate" 2>/dev/null || true
    fail "could not create an isolated integration worktree"
  fi
  if ! git -C "$candidate" merge --no-ff --no-edit "refs/tags/$release" >/dev/null 2>&1; then
    echo "candidate merge failed; isolated branch kept for inspection: $branch" >&2
    git -C "$project" worktree remove "$candidate" >/dev/null 2>&1 || true
    fail "upstream release does not merge cleanly"
  fi
  if ! git -C "$candidate" diff --check "$default"; then
    echo "candidate validation failed; isolated branch kept for inspection: $branch" >&2
    git -C "$project" worktree remove "$candidate" >/dev/null 2>&1 || true
    fail "combined result has whitespace errors"
  fi
  if [ -n "$test_command" ]; then
    if ! (cd "$candidate" && FM_PROJECT_ROOT="$candidate" sh -c "$test_command"); then
      echo "candidate validation failed; isolated branch kept for inspection: $branch" >&2
      git -C "$project" worktree remove "$candidate" >/dev/null 2>&1 || true
      fail "test command failed"
    fi
  fi
  candidate_sha=$(git -C "$candidate" rev-parse HEAD)
  marker=$(candidate_file "$project")
  mkdir -p "$(dirname "$marker")"
  {
    printf 'schema=fm-maintained-fork-candidate.v1\n'
    printf 'project=%s\n' "$project"
    printf 'default=%s\n' "$default"
    printf 'release=%s\n' "$release"
    printf 'release_sha=%s\n' "$release_sha"
    printf 'branch=%s\n' "$branch"
    printf 'candidate_sha=%s\n' "$candidate_sha"
  } > "$marker.tmp.$$"
  mv -f "$marker.tmp.$$" "$marker"
  if ! git -C "$project" worktree remove "$candidate" >/dev/null 2>&1; then
    echo "candidate worktree retained at $candidate" >&2
  fi
  printf 'candidate ready: %s\n' "$branch"
  printf 'accept locally with: %s accept %s\n' "$SCRIPT_DIR/fm-maintained-fork.sh" "$project"
}

accept() {
  local project=$1 marker default branch expected actual
  require_maintained_fork "$project"
  marker=$(candidate_file "$project")
  [ -f "$marker" ] || fail "no validated maintained-fork candidate is waiting for local acceptance"
  branch=$(sed -n 's/^branch=//p' "$marker" | head -1)
  default=$(sed -n 's/^default=//p' "$marker" | head -1)
  expected=$(sed -n 's/^candidate_sha=//p' "$marker" | head -1)
  [ -n "$branch" ] && [ -n "$default" ] && [ -n "$expected" ] \
    || fail "candidate record is incomplete"
  [ "$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$default" ] \
    || fail "project must be checked out on its default branch: $default"
  [ -z "$(git -C "$project" status --porcelain 2>/dev/null)" ] \
    || fail "project has uncommitted changes; acceptance would disturb them"
  actual=$(git -C "$project" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null) \
    || fail "candidate branch is missing: $branch"
  [ "$actual" = "$expected" ] || fail "candidate branch changed after validation"
  git -C "$project" merge --ff-only "$branch" >/dev/null \
    || fail "candidate is not a fast-forward of the deployed default branch"
  git -C "$project" branch -d "$branch" >/dev/null \
    || fail "candidate landed but its branch could not be retired"
  rm -f "$marker"
  printf 'accepted locally: %s\n' "$project"
}

[ "$#" -ge 1 ] || { usage; exit 2; }
command=$1
shift
case "$command" in
  integrate)
    if [ "$#" -eq 1 ]; then
      integrate "$FM_ROOT" "$1"
    elif [ "$#" -ge 2 ] && case "$2" in --*) true ;; *) false ;; esac; then
      integrate "$FM_ROOT" "$@"
    elif [ "$#" -ge 2 ]; then
      project=$(resolve_project "$1")
      shift
      integrate "$project" "$@"
    else
      usage; exit 2
    fi
    ;;
  accept)
    [ "$#" -le 1 ] || { usage; exit 2; }
    accept "$(resolve_project "${1:-$FM_ROOT}")"
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
