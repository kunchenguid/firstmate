#!/usr/bin/env bash
# Resolve the branch a ship or scout worker must actually stand on for a project.
# Prints three words to stdout: "<branch> <source> <remote>".
#
#   source=remote-default    the remote's OWN current default branch, read live
#   source=project-override  a base=<branch> override declared in data/projects.md
#   source=local-default     the repository configures NO remote at all, so the
#                            clone's own default branch is the answer
#   source=none              no default branch is resolvable at all; the caller
#                            must leave the worktree exactly where it already was
#
# THIS FILE OWNS THE RESOLUTION CONTRACT. Every other site states only what it
# needs and points here rather than restating it.
#
# "none" means the repository names no default branch anywhere: no remote is
# configured, no refs/remotes/<remote>/HEAD survives, and neither main nor master
# exists locally. A detached HEAD alone does NOT mean "none". The local default is
# read from the default-branch ref (bin/fm-ff-lib.sh's default_branch), never from
# whatever HEAD happens to point at, so a clone left stranded on a feature branch
# or at a detached HEAD still resolves to its real default branch and the worker
# IS placed there. That stranded position is an accident of the clone, not an
# instruction from anyone, and propagating it to every worker cut from that clone
# is the same wrong-code failure this script exists to prevent.
#
# WHICH REMOTE gets resolved against, in order:
#   1. the requested remote (FM_BASE_BRANCH_REMOTE, default origin) when the
#      repository configures it;
#   2. otherwise the repository's SOLE remote, whatever it is named - one remote
#      is unambiguous, so a clone made with `git clone -o upstream` resolves
#      against upstream and spawns normally;
#   3. otherwise, with SEVERAL remotes and none of them the requested one, a hard
#      error naming the project and every remote found, because nothing in the
#      repository says which of them the project's branches come from;
#   4. otherwise, with NO remote at all, the local path below.
# The third output field names the remote actually resolved, so the caller fetches
# from that same one. Whichever remote it is, the base branch still comes from that
# remote's own current state and never from a cached ref.
#
# For source=none the branch and remote fields are "-", so the line always has
# three fields and a caller can `read -r branch source remote` unconditionally.
# The remote field is "-" whenever no remote is configured at all, including the
# remote-less project-override case, so a caller decides "fetch it" versus "read
# the local ref" from the remote field rather than from the source label: an
# override is a declaration about which branch, never a promise that a remote
# exists to fetch it from.
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
# Every remote read runs under bin/fm-git-net-lib.sh's hard deadline, because a
# refusal that hangs instead of returning is no better than the silent fallback
# this script exists to prevent.
#
# Usage: fm-base-branch.sh <project-dir> [--name <project-name>]
#   <project-dir>    the project's primary clone (its basename is the registry
#                    name unless --name overrides it)
#   FM_BASE_BRANCH_REMOTE  remote to prefer (default: origin; see the order above)
#   FM_GIT_NET_TIMEOUT     seconds allowed per remote read (default: 20)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-git-net-lib.sh
. "$SCRIPT_DIR/fm-git-net-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REQUESTED_REMOTE=${FM_BASE_BRANCH_REMOTE:-origin}
REMOTE=

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

if git -C "$PROJ_ABS" remote get-url "$REQUESTED_REMOTE" >/dev/null 2>&1; then
  REMOTE=$REQUESTED_REMOTE
else
  CONFIGURED_REMOTES=$(git -C "$PROJ_ABS" remote 2>/dev/null || true)
  REMOTE_COUNT=$(printf '%s\n' "$CONFIGURED_REMOTES" | grep -c . || true)
  if [ "$REMOTE_COUNT" -eq 1 ]; then
    REMOTE=$(printf '%s\n' "$CONFIGURED_REMOTES" | head -n 1)
  elif [ "$REMOTE_COUNT" -gt 1 ]; then
    echo "error: project \"$NAME\" configures no \"$REQUESTED_REMOTE\" remote, and $PROJ_ABS has several remotes, so nothing says which one its branches come from: $(printf '%s\n' "$CONFIGURED_REMOTES" | tr '\n' ' ' | sed 's/ *$//')" >&2
    exit 1
  fi
fi

if [ -z "$REMOTE" ]; then
  # No remote to be stale against, and none to fetch from either, so the remote
  # field is reported as "-" and the caller reads the local ref directly.
  if [ -n "$DECLARED" ]; then
    if ! git -C "$PROJ_ABS" rev-parse --verify --quiet "refs/heads/$DECLARED" >/dev/null; then
      echo "error: project \"$NAME\" declares base branch \"$DECLARED\", but $PROJ_ABS has no such branch and configures no remote to fetch it from" >&2
      exit 1
    fi
    printf '%s %s %s\n' "$DECLARED" project-override -
    exit 0
  fi
  # bin/fm-ff-lib.sh's default_branch owns this resolution fleet-wide: the
  # default-branch ref first, then main/master, never the checked-out HEAD (see
  # the header's "none" contract).
  local_default=$(default_branch "$PROJ_ABS" || true)
  if [ -z "$local_default" ]; then
    printf '%s %s %s\n' - none -
    exit 0
  fi
  printf '%s %s %s\n' "$local_default" local-default -
  exit 0
fi

if [ -n "$DECLARED" ]; then
  set +e
  fm_git_net_run git -C "$PROJ_ABS" ls-remote --exit-code --heads "$REMOTE" "refs/heads/$DECLARED" >/dev/null 2>&1
  ls_status=$?
  set -e
  case "$ls_status" in
    0) ;;
    2)
      echo "error: project \"$NAME\" declares base branch \"$DECLARED\", but $REMOTE has no branch by that name" >&2
      exit 1
      ;;
    *)
      echo "error: could not reach $REMOTE to verify project \"$NAME\"'s declared base branch \"$DECLARED\": $(fm_git_net_reason "$ls_status")" >&2
      exit 1
      ;;
  esac
  printf '%s %s %s\n' "$DECLARED" project-override "$REMOTE"
  exit 0
fi

# The live read that the clone's cached refs/remotes/<remote>/HEAD cannot be
# trusted for. --symref makes the server itself name the branch HEAD points at.
set +e
symref=$(fm_git_net_run git -C "$PROJ_ABS" ls-remote --symref "$REMOTE" HEAD 2>/dev/null)
symref_status=$?
set -e
if [ "$symref_status" -ne 0 ]; then
  echo "error: could not reach $REMOTE to resolve project \"$NAME\"'s default branch: $(fm_git_net_reason "$symref_status")" >&2
  exit 1
fi
remote_default=$(printf '%s\n' "$symref" \
  | awk '$1=="ref:" && $3=="HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
if [ -z "$remote_default" ]; then
  echo "error: $REMOTE did not report a default branch for project \"$NAME\"; declare base=<branch> for it in the project registry" >&2
  exit 1
fi
printf '%s %s %s\n' "$remote_default" remote-default "$REMOTE"
