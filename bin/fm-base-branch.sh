#!/usr/bin/env bash
# Resolve the branch a ship or scout worker must actually stand on for a project.
# Prints three words to stdout: "<branch> <source> <remote>".
#
#   source=remote-default    the remote's OWN current default branch, read live
#   source=project-override  a base=<branch> override declared in data/projects.md
#   source=local-default     no remote is configured, so the clone's own default
#   source=none              nothing could be resolved; the caller must leave the
#                            worktree exactly where it already was
# For source=none the branch and remote fields are "-", so the line always has
# three fields and a caller can `read -r branch source remote` unconditionally.
#
# WHY THIS EXISTS. A task worktree is cut from whatever the local clone happens to
# hold. A clone records the remote's default branch once, at clone time, in
# refs/remotes/<remote>/HEAD, and nothing refreshes it afterwards. When a project
# later changes its default branch, every worker keeps being handed the old one and
# reads code that no longer reflects the project - an audit once concluded a live
# subsystem "is not shipped" because the files were absent from the stale branch it
# was given. So the default branch is read from the remote at spawn time and the
# cached value is never trusted.
#
# The per-project base=<branch> override (bin/fm-project-mode.sh owns the registry
# format) is the secondary escape hatch for the rare project whose development
# branch genuinely differs from its remote's default. It is deliberately not the
# main mechanism, and a project whose development branch IS its remote default
# needs no registry entry.
#
# Failure is loud, never a quiet fall back to the local cache: a worker that fails
# to launch is recoverable, and a worker silently reading the wrong branch is the
# exact defect this script exists to prevent. A declared override missing from the
# remote, an unreachable remote, and a remote that reports no default branch are
# all hard errors.
#
# Usage: fm-base-branch.sh <project-dir> [--name <project-name>]
#   <project-dir>    the project's primary clone (its basename is the registry
#                    name unless --name overrides it)
#   FM_BASE_BRANCH_REMOTE  remote to resolve against (default: origin)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REMOTE=${FM_BASE_BRANCH_REMOTE:-origin}

PROJ_DIR=
NAME=
want_name=0
for a in "$@"; do
  if [ "$want_name" -eq 1 ]; then
    NAME=$a
    want_name=0
    continue
  fi
  case "$a" in
    --name) want_name=1 ;;
    -*) echo "error: unknown option $a" >&2; exit 1 ;;
    *)
      [ -z "$PROJ_DIR" ] || { echo "error: unexpected extra argument $a" >&2; exit 1; }
      PROJ_DIR=$a
      ;;
  esac
done
[ "$want_name" -eq 0 ] || { echo "error: --name requires a value" >&2; exit 1; }
[ -n "$PROJ_DIR" ] || { echo "usage: fm-base-branch.sh <project-dir> [--name <project-name>]" >&2; exit 1; }

PROJ_ABS=$(CDPATH='' cd -- "$PROJ_DIR" 2>/dev/null && pwd -P) || {
  echo "error: project directory cannot be resolved: $PROJ_DIR" >&2
  exit 1
}
[ -n "$NAME" ] || NAME=$(basename "$PROJ_ABS")

if ! git -C "$PROJ_ABS" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $PROJ_ABS is not a git repository; cannot resolve a base branch for $NAME" >&2
  exit 1
fi

# A hard error here (a malformed base= declaration) must stop the spawn.
DECLARED=$("$FM_ROOT/bin/fm-project-mode.sh" --base "$NAME") || exit 1

# Never prompt for credentials: an interactive prompt in a spawn path hangs the
# launch instead of failing it.
export GIT_TERMINAL_PROMPT=0

if ! git -C "$PROJ_ABS" remote get-url "$REMOTE" >/dev/null 2>&1; then
  # No remote to be stale against. A declared override still has to exist.
  if [ -n "$DECLARED" ]; then
    if ! git -C "$PROJ_ABS" rev-parse --verify --quiet "refs/heads/$DECLARED" >/dev/null; then
      echo "error: project \"$NAME\" declares base branch \"$DECLARED\", but $PROJ_ABS has no such branch and no \"$REMOTE\" remote to fetch it from" >&2
      exit 1
    fi
    printf '%s %s %s\n' "$DECLARED" project-override "$REMOTE"
    exit 0
  fi
  local_default=$(git -C "$PROJ_ABS" symbolic-ref --short --quiet HEAD || true)
  if [ -z "$local_default" ]; then
    # A remote-less clone sitting on a detached HEAD names no default branch at
    # all. Report nothing rather than inventing one; the caller leaves the
    # worktree where it already was, exactly as before this resolution existed.
    printf '%s %s %s\n' - none -
    exit 0
  fi
  printf '%s %s %s\n' "$local_default" local-default "$REMOTE"
  exit 0
fi

if [ -n "$DECLARED" ]; then
  set +e
  git -C "$PROJ_ABS" ls-remote --exit-code --heads "$REMOTE" "refs/heads/$DECLARED" >/dev/null 2>&1
  ls_status=$?
  set -e
  case "$ls_status" in
    0) ;;
    2)
      echo "error: project \"$NAME\" declares base branch \"$DECLARED\", but $REMOTE has no branch by that name" >&2
      exit 1
      ;;
    *)
      echo "error: could not reach $REMOTE to verify project \"$NAME\"'s declared base branch \"$DECLARED\"" >&2
      exit 1
      ;;
  esac
  printf '%s %s %s\n' "$DECLARED" project-override "$REMOTE"
  exit 0
fi

# The live read that the clone's cached refs/remotes/<remote>/HEAD cannot be
# trusted for. --symref makes the server itself name the branch HEAD points at.
symref=$(git -C "$PROJ_ABS" ls-remote --symref "$REMOTE" HEAD 2>/dev/null) || {
  echo "error: could not reach $REMOTE to resolve project \"$NAME\"'s default branch" >&2
  exit 1
}
default_branch=$(printf '%s\n' "$symref" \
  | awk '$1=="ref:" && $3=="HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
if [ -z "$default_branch" ]; then
  echo "error: $REMOTE did not report a default branch for project \"$NAME\"; declare base=<branch> for it in the project registry" >&2
  exit 1
fi
printf '%s %s %s\n' "$default_branch" remote-default "$REMOTE"
