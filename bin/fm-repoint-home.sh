#!/usr/bin/env bash
# fm-repoint-home.sh - re-point ONE firstmate home between remote conventions,
# reversibly, one home at a time.
#
# The fleet is migrating to the standard fork-as-source convention:
#   original-as-origin (before):  origin = <original/upstream>,  fork = <fork>
#   fork-as-source     (after):   origin = <fork>,               upstream = <original>
# Under the "after" layout fm-update.sh fetches homes from origin (= the fork)
# with no extra config, and no-mistakes derives its PR base from origin (= the
# fork the captain can merge). The change is purely a rename/add of git remotes:
# it never touches the working tree, commits, branches, or any unlanded work, so
# it is safe on a home with in-flight work and is trivially reversible.
#
# This is a SUPERVISED, per-home step. Run `status` to inspect a home, run the
# transform with NO flag to see exactly what it would do (dry run), and only
# `--apply` mutates. Re-pointing the MAIN firstmate home (the one with the
# no-mistakes gate) also needs `no-mistakes init` afterward so the gate re-reads
# its PR base from the new origin - this tool prints that follow-up rather than
# touching the shared gate itself.
#
# Usage:
#   fm-repoint-home.sh status    <home>
#   fm-repoint-home.sh to-fork   <home> [--fork-url <url>] [--apply]
#   fm-repoint-home.sh to-origin <home> [--apply]
#   fm-repoint-home.sh --help
#
# Exit status: 0 on a clean status/dry-run/apply (including an idempotent no-op);
# 2 on a precondition error (not a repo, missing/unexpected remotes) so a caller
# can tell a real blocker from "already in the target layout".
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-repoint-home.sh status    <home>
  fm-repoint-home.sh to-fork   <home> [--fork-url <url>] [--apply]
  fm-repoint-home.sh to-origin <home> [--apply]
  to-fork:   origin=<original>,fork=<fork>  ->  origin=<fork>,upstream=<original>
  to-origin: origin=<fork>,upstream=<original>  ->  origin=<original>,fork=<fork>
  No flag = dry run (prints the exact git commands). --apply performs them.
  Never forces, never touches the working tree, commits, or unlanded work.
EOF
}

die() { echo "fm-repoint-home: $1" >&2; exit 2; }

remote_url() { git -C "$1" remote get-url "$2" 2>/dev/null || true; }
has_remote() { git -C "$1" remote get-url "$2" >/dev/null 2>&1; }

require_repo() {
  local home=$1
  [ -d "$home" ] || die "not a directory: $home"
  git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git repository: $home"
}

# Run a git remote command, or print it under dry run. All mutations funnel here.
git_do() {
  local home=$1; shift
  if [ "$APPLY" = yes ]; then
    git -C "$home" "$@"
  else
    echo "  git -C $home $*"
  fi
}

cmd_status() {
  local home=$1 r url src
  require_repo "$home"
  echo "home: $home"
  echo "remotes:"
  for r in $(git -C "$home" remote 2>/dev/null); do
    printf '  %-10s %s\n' "$r" "$(remote_url "$home" "$r")"
  done
  # Resolved update source uses the same library fm-update.sh does, invoked in a
  # child shell so there is exactly one owner of resolve_update_remote and no
  # library side effects leak into this script's scope.
  src=$(FM_HOME="$home" FM_ROOT="$home" bash -c \
    '. "$1/fm-ff-lib.sh"; resolve_update_remote "$2"' _ "$SCRIPT_DIR" "$home" 2>/dev/null)
  [ -n "$src" ] || src=origin
  url=$(remote_url "$home" "$src")
  echo "update source: $src${url:+ ($url)}"
  if has_remote "$home" upstream && ! has_remote "$home" fork; then
    echo "layout: fork-as-source (origin is the fork, upstream is the original)"
  elif has_remote "$home" fork && ! has_remote "$home" upstream; then
    echo "layout: original-as-origin (origin is the original, fork is the fork)"
  else
    echo "layout: unrecognized (inspect the remotes above before re-pointing)"
  fi
  echo "note: the MAIN home also needs 'no-mistakes init' after a re-point so the gate follows origin"
}

cmd_to_fork() {
  local home=$1 fork_url=$2
  require_repo "$home"
  # Idempotent: already fork-as-source.
  if has_remote "$home" upstream && ! has_remote "$home" fork; then
    echo "already fork-as-source: $home (origin is the fork, upstream is the original) - no change"
    return 0
  fi
  has_remote "$home" origin || die "$home has no origin remote to re-point"
  has_remote "$home" upstream && die "$home already has an upstream remote; unexpected state, refusing to re-point"
  if has_remote "$home" fork; then
    [ -n "$fork_url" ] && echo "fm-repoint-home: warning: --fork-url ignored; promoting the existing fork remote's URL to origin" >&2
    fork_url=$(remote_url "$home" fork)
  else
    [ -n "$fork_url" ] || die "$home has no fork remote; pass --fork-url <url>"
  fi
  echo "re-point to fork-as-source: $home"
  echo "  target: origin=$fork_url  upstream=$(remote_url "$home" origin)"
  git_do "$home" remote rename origin upstream
  if has_remote "$home" fork; then
    git_do "$home" remote rename fork origin
  else
    git_do "$home" remote add origin "$fork_url"
  fi
  if [ "$APPLY" = yes ]; then
    echo "done: $home is now fork-as-source"
    echo "next (MAIN home only): run 'no-mistakes init' in $home so the gate opens PRs against the fork"
  else
    echo "  # then, MAIN home only: (cd $home && no-mistakes init)"
    echo "(dry run - re-run with --apply to perform the above)"
  fi
}

cmd_to_origin() {
  local home=$1
  require_repo "$home"
  # Idempotent: already original-as-origin.
  if has_remote "$home" fork && ! has_remote "$home" upstream; then
    echo "already original-as-origin: $home - no change"
    return 0
  fi
  has_remote "$home" origin || die "$home has no origin remote to revert"
  has_remote "$home" upstream || die "$home has no upstream remote; nothing to revert"
  has_remote "$home" fork && die "$home already has a fork remote; unexpected state, refusing to revert"
  echo "revert to original-as-origin: $home"
  echo "  target: origin=$(remote_url "$home" upstream)  fork=$(remote_url "$home" origin)"
  git_do "$home" remote rename origin fork
  git_do "$home" remote rename upstream origin
  if [ "$APPLY" = yes ]; then
    echo "done: $home is back to original-as-origin"
    echo "next (MAIN home only): run 'no-mistakes init' in $home so the gate opens PRs against the original again"
  else
    echo "  # then, MAIN home only: (cd $home && no-mistakes init)"
    echo "(dry run - re-run with --apply to perform the above)"
  fi
}

# --- arg parse -------------------------------------------------------------

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
SUB=$1; shift

APPLY=no
FORK_URL=""
HOME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=yes; shift ;;
    --fork-url) FORK_URL=${2:-}; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$HOME_ARG" ] || die "unexpected extra argument: $1"; HOME_ARG=$1; shift ;;
  esac
done
[ -n "$HOME_ARG" ] || { usage; exit 2; }

case "$SUB" in
  status) cmd_status "$HOME_ARG" ;;
  to-fork) cmd_to_fork "$HOME_ARG" "$FORK_URL" ;;
  to-origin) cmd_to_origin "$HOME_ARG" ;;
  *) die "unknown subcommand: $SUB" ;;
esac
