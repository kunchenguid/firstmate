#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# After the local fast-forward, this is also the single owner of keeping a
# local-mirror origin's default branch in step with it (fm-fleet-sync.sh's
# mode=local-only skip cross-references this instead of duplicating it). Some
# local-only projects point origin at a local bare mirror that exists only so
# bin/fm-spawn.sh's pooled-worktree refresh has something to fetch from (never a
# real forge - local-only never pushes there). Left alone, that mirror goes stale
# the moment this script advances the project's real local default branch, and
# the next pooled spawn fetches the stale mirror and silently drops already-merged
# work from the new task's base. So: fast-forward the mirror's copy of the default
# branch to match (a plain `git push`, which git itself refuses if the mirror has
# diverged; never forced) - but only when every URL `git push origin` would
# actually use is a filesystem path or file:// URL, never network-addressed
# (no https/http/ssh/git:// scheme and no scp-like [user@]host:path form).
# The decision is made on push URLs, not the fetch URL: a separately configured
# remote.origin.pushurl (or several, via repeated `remote set-url --add --push`)
# overrides the fetch URL entirely for `git push`, so a local-path fetch URL
# paired with a hosted pushurl must still be treated as a real hosted origin, and
# is - `git remote get-url --push --all` returns the configured pushurl(s) when
# set and falls back to the fetch URL only when none is configured, so checking
# every one of those exactly mirrors what `git push origin` would actually target.
# A single hosted URL anywhere in that list disqualifies the whole remote from
# this sync, silently and without a push attempt, identical to today's contract
# for an ordinary hosted origin: local-only's no-push, no-PR contract is
# unchanged for it. A failed mirror update (e.g. the mirror has diverged) is
# reported loudly on stderr but never fails this script's exit status - the local
# fast-forward above already succeeded and remains this script's primary
# guarantee.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# True (0) when $1 is clearly network-addressed: an https/http/ssh/git:// URL, or
# scp-like [user@]host:path. Anything else - an absolute path, a file:// URL, or
# any other form - is treated as the local-mirror case (see header comment).
origin_is_network_addressed() {
  local url=$1 before_colon
  case "$url" in
    https://* | http://* | ssh://* | git://*) return 0 ;;
    /* | file://*) return 1 ;;
  esac
  case "$url" in
    *:*)
      before_colon=${url%%:*}
      case "$before_colon" in
        */*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# True (0) only when every URL `git push origin` would actually use is a local
# filesystem path or file:// URL - see header comment for why this must be push
# URLs, never the fetch URL alone.
origin_push_is_local_mirror() {
  local urls u
  urls=$(git -C "$PROJ" remote get-url --push --all origin 2>/dev/null) || return 1
  [ -n "$urls" ] || return 1
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    origin_is_network_addressed "$u" && return 1
  done <<< "$urls"
  return 0
}

ORIGIN_URL=$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)
if [ -n "$ORIGIN_URL" ] && origin_push_is_local_mirror; then
  if PUSH_OUT=$(git -C "$PROJ" push origin "refs/heads/$DEFAULT:refs/heads/$DEFAULT" 2>&1); then
    case "$PUSH_OUT" in
      *"Everything up-to-date"*) ;;
      *) echo "origin mirror updated: $DEFAULT now at $after ($ORIGIN_URL)" ;;
    esac
  else
    echo "warning: could not fast-forward local-mirror origin '$ORIGIN_URL' to $DEFAULT ($after); pooled worktrees fetched from this mirror may still see stale history until this is fixed. git push said: $PUSH_OUT" >&2
  fi
fi
