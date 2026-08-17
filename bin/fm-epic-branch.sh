#!/usr/bin/env bash
# fm-epic-branch.sh - cut or verify an epic/<slug> branch from a repo's declared
# production branch (gflow "cổng #2", epic gitflow enforcement).
#
# The epic gitflow convention (docs/epic-convention.md, seeded by the gflow epic)
# says every story ships on an epic/<slug> branch cut from that repo's PRODUCTION
# branch, one epic branch per involved repo. This script owns cutting and
# verifying that branch. gflow-04's spawn gate calls `verify` before it will
# spawn a story worker; the epic handoff calls `create` once per involved repo.
#
#   create <epic-slug> <project>
#       Resolve the project's production branch (bin/fm-project-mode.sh
#       --branches), fetch it, and create origin's epic/<slug> at production's
#       tip. Idempotent and never-clobber:
#         - epic/<slug> absent            -> create it at production, push.
#         - epic/<slug> at/ahead of prod  -> no-op, report (production is an
#                                            ancestor of the epic tip).
#         - epic/<slug> behind/diverged   -> REFUSE (never move an existing
#                                            epic branch; that would clobber
#                                            work based on it).
#       Refuses if production is undeclared (register it first, gflow-02).
#
#   verify <epic-slug> <project>
#       Exit 0 if origin's epic/<slug> exists, non-zero otherwise. Quiet enough
#       to gate on: the exit code is the verdict.
#
# Operates only through `git -C <clone>` against origin refs. It never checks out
# or switches a working checkout's branch: the branch is created by pushing a
# resolved SHA to refs/heads/epic/<slug>, and reads go through fetch/ls-remote.
# Every git call is bounded (bin/fm-timeout-lib.sh); a hung fetch/push cannot
# wedge a caller. gflow itself is the bootstrap exception and ships on main with
# no epic branch (see the epic's convention doc); every later epic uses this.
#
# The <project> argument is a bare name resolved against this home's projects dir
# (or a path), same as bin/fm-fleet-sync.sh.
#
# Usage:
#   fm-epic-branch.sh create <epic-slug> <project>
#   fm-epic-branch.sh verify <epic-slug> <project>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
GIT_NET_TIMEOUT="${FM_EPIC_GIT_TIMEOUT:-60}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_ROOT/bin/fm-timeout-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-branch.sh create <epic-slug> <project>   cut epic/<slug> from production, push
  fm-epic-branch.sh verify <epic-slug> <project>   exit 0 iff origin epic/<slug> exists

Cuts/verifies one epic/<slug> branch per repo from that repo's declared
production branch (bin/fm-project-mode.sh --branches). create is idempotent and
never clobbers an existing epic branch. Operates via git -C <clone>/origin only.
EOF
  exit "$code"
}

# Bounded git. Turns the shared timeout convention (exit 124 = bound hit) into a
# clear error, and otherwise passes the command's own exit status through.
git_bounded() {
  local rc=0
  fm_run_timed "$GIT_NET_TIMEOUT" git "$@" || rc=$?
  [ "$rc" -ne 124 ] || die "a git operation timed out after ${GIT_NET_TIMEOUT}s: git $*"
  return "$rc"
}

# resolve_clone <arg>: a path used as-is when it exists, or a bare/"projects/<name>"
# name resolved against $PROJECTS. Mirrors bin/fm-fleet-sync.sh's resolver.
resolve_clone() {
  local arg=$1 candidate
  case "$arg" in
    projects/*) candidate="$PROJECTS/${arg#projects/}" ;;
    */*)        candidate="$arg" ;;
    *)          candidate="$PROJECTS/$arg" ;;
  esac
  if [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -d "$arg" ]; then
    printf '%s\n' "$arg"
    return 0
  fi
  return 1
}

epic_ref() { printf 'refs/heads/epic/%s' "$1"; }

# origin_has_epic <clone> <slug>: 0 if origin carries epic/<slug>, 1 if not.
origin_has_epic() {
  local clone=$1 slug=$2 rc=0
  git_bounded -C "$clone" ls-remote --exit-code origin "$(epic_ref "$slug")" >/dev/null 2>&1 || rc=$?
  # ls-remote --exit-code: 0 found, 2 not found, other = real error.
  case "$rc" in
    0) return 0 ;;
    2) return 1 ;;
    *) die "cannot reach origin for $clone (git ls-remote failed)" ;;
  esac
}

cmd=${1:-}; [ -n "$cmd" ] || usage
case "$cmd" in create|verify) ;; -h|--help|help) usage 0 ;; *) usage ;; esac
slug=${2:-}; project=${3:-}
[ -n "$slug" ] && [ -n "$project" ] || usage
# Never let a leading dash smuggle in a git option, and pin the ref name to
# git's own rules (rejects spaces, .., ~^:? , control chars, etc.).
case "$slug" in -*) die "invalid epic slug: $slug" ;; esac
git check-ref-format "$(epic_ref "$slug")" 2>/dev/null || die "invalid epic slug: $slug (not a valid branch name)"

clone=$(resolve_clone "$project") || die "project \"$project\" not found under $PROJECTS (or as a path)"

if [ "$cmd" = verify ]; then
  if origin_has_epic "$clone" "$slug"; then
    echo "epic/$slug exists in $project"
    exit 0
  fi
  echo "epic/$slug missing in $project" >&2
  exit 1
fi

# --- create ---------------------------------------------------------------
read -r production _staging < <("$FM_ROOT/bin/fm-project-mode.sh" --branches "$project")
[ -n "${production:-}" ] || die "production branch undeclared for \"$project\"; register it first (--production, gflow-02)"

# Production tip: fetch the declared branch and read the fetched head directly,
# so we don't depend on the clone's remote-tracking refspec.
git_bounded -C "$clone" fetch --quiet origin "$production" \
  || die "cannot fetch origin/$production for $project (does the branch exist on origin?)"
prod_sha=$(git -C "$clone" rev-parse FETCH_HEAD) || die "cannot resolve production tip"

if origin_has_epic "$clone" "$slug"; then
  # Bring the epic objects local so we can compare, then never move it.
  git_bounded -C "$clone" fetch --quiet origin "epic/$slug" \
    || die "epic/$slug exists on origin but could not be fetched for $project"
  epic_sha=$(git -C "$clone" rev-parse FETCH_HEAD) || die "cannot resolve epic/$slug tip"
  if [ "$epic_sha" = "$prod_sha" ] || git -C "$clone" merge-base --is-ancestor "$prod_sha" "$epic_sha"; then
    echo "epic/$slug already at/ahead of $production in $project (no-op)"
    exit 0
  fi
  die "epic/$slug in $project is not at/ahead of $production (behind or diverged); refusing to move it"
fi

# Absent: create it at production's tip. No --force, so a racing create that
# already advanced the ref is rejected rather than clobbered.
git_bounded -C "$clone" push origin "$prod_sha:$(epic_ref "$slug")" \
  || die "failed to push epic/$slug to origin for $project"
echo "epic/$slug cut from $production ($prod_sha) in $project"
