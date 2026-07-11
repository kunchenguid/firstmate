#!/usr/bin/env bash
# fm-self-fix.sh <task-id> [--harness <name>] [--model <m>] [--effort <e>]
#
# Dispatch a crewmate to fix firstmate's OWN tracked code (bin/, AGENTS.md,
# .agents/skills/, docs/) in an isolated git worktree of this repo - no treehouse
# pooling required. The primary checkout stays on its default branch (tangle guard
# safe); the fix ships through the no-mistakes gate + captain merge like any
# project change. Author data/<id>/brief.md (a ship brief) BEFORE calling.
set -euo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
FM_ROOT=$(cd "$SELF/.." && pwd -P)          # the firstmate repo (primary checkout)

ID=${1:?usage: fm-self-fix.sh <task-id> [--harness <name>] [--model <m>] [--effort <e>]}
shift || true

DEFAULT_BRANCH=$(git -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)

# Scratch root OUTSIDE any FM_HOME, so the checkout can never be mistaken for an
# operational home. Override with FM_SELFFIX_ROOT.
WT_ROOT="${FM_SELFFIX_ROOT:-$HOME/.firstmate-selffix}"
WT="$WT_ROOT/$ID"
BRANCH="fix/$ID"

[ -f "$FM_ROOT/data/$ID/brief.md" ] || { echo "error: no brief at data/$ID/brief.md (author it first)" >&2; exit 1; }
[ ! -e "$WT" ] || { echo "error: worktree path already exists: $WT" >&2; exit 1; }
if git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "error: branch $BRANCH already exists; pick a fresh task id" >&2
  exit 1
fi

mkdir -p "$WT_ROOT"
git -C "$FM_ROOT" worktree add "$WT" -b "$BRANCH" "$DEFAULT_BRANCH"
echo "self-fix worktree: $WT (branch $BRANCH off $DEFAULT_BRANCH)"

# fm-spawn --worktree skips treehouse and uses this pre-created isolated worktree
# (running its own isolation assertion). Forwarded args carry --harness/--model/--effort.
exec "$FM_ROOT/bin/fm-spawn.sh" "$ID" "$FM_ROOT" --worktree "$WT" --backend tmux "$@"
