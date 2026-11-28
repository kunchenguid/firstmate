#!/usr/bin/env bash
# Stall detector for conflict-fix crewmates: wakes firstmate when a worker's
# worktree has a FROZEN HEAD with a dirty index past a stall threshold — the
# "uncommitted merge" trap where tests run against a half-state and fabricate
# spurious failures (learned on #5495, 2026-08-28).
#
# Usage: fm-worker-stall-check.sh <task-id> <worktree-path>
#   <task-id>       task id; marker written to state/.worker-stall-<task-id>
#   <worktree-path> the worker's git worktree to inspect
#
# Prints ONE line only when firstmate should wake:
#   stalled: <task> HEAD frozen at <sha> for <n>m with <staged> staged file(s) — merge not committed
# Silent otherwise (including every error, so a failed read can never read as a stall).
# Once a stall fires, remove/overwrite the marker to re-arm after resolution.
#
# Why git state and not pane activity: token counts and busy panes climb while
# HEAD is frozen. HEAD==unchanged + index-dirty is the single authoritative
# signal that a merge was staged but never committed.
set -u

FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STALL_MIN=${FM_WORKER_STALL_MIN:-30}   # minutes of frozen HEAD before flagging
WORKTREE=${2-}
TASK=${1-}

[ -n "$TASK" ] && [ -n "$WORKTREE" ] || exit 0
[ -e "$WORKTREE/.git" ] || exit 0   # git worktrees carry a .git FILE (gitdir pointer), not a dir

# Fresh HEAD? Record first-seen and exit silently; only a HEAD that stays
# frozen across polls can stall. The marker holds "sha epoch-first-seen", and
# that epoch must be written on the FIRST sighting too, not just later ones -
# a marker holding only the sha can never yield a nonzero age on a later poll.
head=$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null) || exit 0
marker="$STATE/.worker-stall-$TASK"
seen=""
[ -f "$marker" ] && [ ! -L "$marker" ] && seen=$(cat "$marker" 2>/dev/null || true)
now=$(date +%s)
case "$seen" in
  "$head "*) ;;          # same HEAD as before — measure the freeze
  *) printf '%s %s' "$head" "$now" > "$marker" 2>/dev/null || exit 0; exit 0 ;;
esac

# Frozen: how long, measured against the epoch persisted on first sighting.
first_seen=${seen#* }
case "$first_seen" in
  ''|*[!0-9]*) first_seen=$now ;;
esac
age=$(( (now - first_seen) / 60 ))
[ "$age" -ge "$STALL_MIN" ] || exit 0

# Frozen past threshold: is there actually an uncommitted merge (staged files)?
staged=$(git -C "$WORKTREE" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
[ "${staged:-0}" -ge 1 ] || exit 0
dirty=$(git -C "$WORKTREE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "${dirty:-0}" -ge 1 ] || exit 0

printf 'stalled: %s HEAD frozen at %s for %sm with %s staged file(s) (merge not committed) — tell worker to commit the merge, then test against the committed state\n' \
  "$TASK" "$head" "$age" "$staged"
exit 0
