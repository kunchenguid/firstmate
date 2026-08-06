#!/usr/bin/env bash
# Pin `gh`'s base-repo resolution to this checkout's own `origin`.
# Usage: fm-gh-resolve.sh [--check] [<repo>]
#        fm-gh-resolve.sh --help
#
# THE FAILURE THIS PREVENTS
# A firstmate home commonly runs from a FORK: `origin` is the fork the fleet
# actually ships to, and `upstream` is the fork parent, a third party's repo.
# When no remote carries a `gh-resolved` config key, `gh` resolves the base repo
# by REMOTE NAME and prefers a remote literally named `upstream` over `origin`.
# Every default `gh`/`gh-axi` call then silently reads the PARENT project:
# `gh pr list` returns the parent's pull requests as though they were ours, and
# a default-targeted `gh pr create` proposes our branch to the parent's repo.
# Both were observed on 2026-08-06 against VirtualRoboticHands/firstmate, whose
# parent is kunchenguid/firstmate (gh 2.97.0).
#
# THE FIX
# Set `remote.origin.gh-resolved=base`, which is exactly what `gh repo
# set-default <origin slug>` writes. `gh` then treats origin's repo as the base
# and the remote-name preference never runs. Deliberate work against the parent
# is UNAFFECTED: `gh -R <owner>/<repo> ...`, `GH_REPO=...`, and a later explicit
# `gh repo set-default` all still override this, so contributing upstream stays
# possible as an explicit act instead of being the silent default.
#
# WHAT IT NEVER DOES
# It writes one local git config key and nothing else. It never adds, renames,
# removes, or re-points a remote, never touches `upstream`, and never contacts
# any forge. It is scoped to firstmate's OWN repo: project clones under
# `projects/` are never written to (AGENTS.md hard rule 1).
#
# NON-CLOBBERING AND IDEMPOTENT
# If ANY remote already carries `gh-resolved`, that is a deliberate operator
# choice - including deliberately pinning the parent to contribute upstream -
# and this script is a silent no-op. It is also a no-op when the checkout has
# fewer than two GitHub remotes, because `gh` already resolves unambiguously and
# there is nothing to disambiguate. Re-running after a successful pin changes
# nothing and prints nothing.
#
# SURVIVING A FRESH CLONE OR A NEW WORKTREE
# `gh-resolved` is LOCAL git config, so it is not carried by `git clone`. It IS
# shared with every linked `git worktree`, which all read the same
# `.git/config`, so crewmate worktrees inherit the pin with no extra step.
# A fresh clone starts unpinned, and the durable answer is this script rather
# than the config value: `fm-bootstrap.sh` runs it on every LOCKED session
# start, so a fresh clone is pinned the first time firstmate opens a session in
# it. A clone that never runs a firstmate session start needs one manual
# `bin/fm-gh-resolve.sh` (or an equivalent `gh repo set-default <owner>/<repo>`).
#
# MODES
#   (default)  Repair. Pins origin when the checkout is ambiguous and unpinned.
#              Prints one BOOTSTRAP_INFO line only when it actually changed
#              something, and one GH_RESOLVE line when it cannot pin safely.
#   --check    Detect only. Never writes. Prints one GH_RESOLVE line when the
#              checkout is ambiguous and unpinned, or when origin is unusable.
#              This is the read-only session's path: a lock-refused session must
#              not mutate, but still needs to know its listings may be wrong.
#
# <repo> defaults to $FM_ROOT_OVERRIDE, else this script's parent directory.
# A path that is not a git work tree is silent and successful in both modes:
# there is nothing to resolve and nothing to warn about.
#
# Exit status is 0 for every reachable outcome, including a reported one; the
# diagnostic line, not the exit code, is the signal. A usage error exits 2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The leading comment block is the authoritative description, so --help prints it
# rather than a second, driftable copy of the same contract.
usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" \
    | sed -e '/^set -uo pipefail$/d' -e 's/^# \{0,1\}//'
}

CHECK_ONLY=0
REPO=
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "fm-gh-resolve.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$REPO" ] || { echo "fm-gh-resolve.sh: unexpected argument $1" >&2; exit 2; }
      REPO=$1
      ;;
  esac
  shift
done
[ -n "$REPO" ] || REPO="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Echo "<owner>/<repo>" when <remote> in <repo> points at a GitHub host, else
# return 1. Handles the scp-like (git@host:owner/repo) and URL
# (scheme://[user@]host[:port]/owner/repo) forms, with or without a .git suffix.
# The GitHub host is github.com plus $GH_HOST when set, matching how `gh` itself
# decides which remotes are candidates on a GitHub Enterprise checkout.
gh_remote_slug() {
  local repo=$1 remote=$2 url host path
  url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    *://*)
      host=${url#*://}
      host=${host#*@}
      path=${host#*/}
      host=${host%%/*}
      host=${host%%:*}
      ;;
    *:*)
      host=${url%%:*}
      host=${host#*@}
      path=${url#*:}
      ;;
    *) return 1 ;;
  esac
  case "$host" in
    github.com) : ;;
    "${GH_HOST:-}") [ -n "${GH_HOST:-}" ] || return 1 ;;
    *) return 1 ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  # Exactly one owner and one repo segment; anything else is not a repo URL.
  case "$path" in
    */*/*|*/|/*|'' ) return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# Echo the name of the remote already carrying a gh-resolved key, or nothing.
# Deliberately scope-wide rather than --local: `gh` honors whatever git config
# resolves, so a key set in any scope is still a deliberate choice to preserve.
resolved_remote() {
  local repo=$1 line
  while IFS= read -r line; do
    line=${line%% *}
    line=${line#remote.}
    printf '%s\n' "${line%.gh-resolved}"
    return 0
  done < <(git -C "$repo" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null)
}

report() {
  printf 'GH_RESOLVE: %s\n' "$1"
}

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# A deliberate existing choice always wins, in both modes.
existing=$(resolved_remote "$REPO")
[ -z "$existing" ] || exit 0

github_remotes=0
origin_slug=
while IFS= read -r remote; do
  [ -n "$remote" ] || continue
  slug=$(gh_remote_slug "$REPO" "$remote") || continue
  github_remotes=$((github_remotes + 1))
  [ "$remote" = origin ] && origin_slug=$slug
done < <(git -C "$REPO" remote 2>/dev/null)

# One GitHub remote (or none) leaves gh nothing to disambiguate.
[ "$github_remotes" -ge 2 ] || exit 0

if [ -z "$origin_slug" ]; then
  report "$REPO has $github_remotes GitHub remotes but no GitHub 'origin', so gh picks the base repo by remote name and may target the wrong project; set the intended base with: gh repo set-default <owner>/<repo>"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  report "$REPO has $github_remotes GitHub remotes and no pinned base repo, so default gh/gh-axi calls may target another project instead of $origin_slug; a session holding the fleet lock pins it, or pin it by hand with: gh repo set-default $origin_slug"
  exit 0
fi

if ! git -C "$REPO" config --local remote.origin.gh-resolved base; then
  report "could not pin gh's base repo to $origin_slug in $REPO; pin it by hand with: gh repo set-default $origin_slug"
  exit 0
fi
printf 'BOOTSTRAP_INFO: pinned gh base repo to %s (origin) in %s\n' "$origin_slug" "$REPO"
exit 0
