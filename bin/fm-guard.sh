#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts and
# by fm-wake-drain.sh after it empties queued wakes.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. Normal wake handling (watcher
# briefly down between a wake and its re-arm) stays inside the grace window and
# stays silent. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
queue_pending=false

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref. Restore the primary to '%s':\n" "$tangle_branch" "$tangle_default"
    printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
    printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    printf '●%s\n' "$trule"
  } >&2
fi

# Portable mtime; see fm-watch.sh for why the `stat -f || stat -c` fallback breaks on Linux.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Only act with tasks in flight; count them so the banner can say how much is
# riding on an absent watcher.
in_flight=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  in_flight=$((in_flight + 1))
done
[ "$in_flight" -eq 0 ] && exit 0

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# Resolve the watcher's liveness from its beacon: fresh within GRACE means a
# watcher is alive and we stay quiet about it.
BEAT="$STATE/.last-watcher-beat"
watcher_fresh=false
beacon_desc=never
if [ -e "$BEAT" ]; then
  m=$(stat_mtime "$BEAT")
  if [ -n "$m" ]; then
    age=$(( $(date +%s) - m ))
    beacon_desc="${age}s ago"
    [ "$age" -lt "$GRACE" ] && watcher_fresh=true
  else
    beacon_desc=unknown
  fi
fi

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line.
if [ "$watcher_fresh" = false ]; then
  if "$queue_pending"; then
    fix='After draining queued wakes, re-arm the watcher: run bin/fm-watch-arm.sh as the harness-tracked background task (never a shell & that gets reaped).'
  else
    fix='Re-arm it NOW: run bin/fm-watch-arm.sh as the harness-tracked background task (never a shell & that gets reaped).'
  fi
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
    printf '●  Trust bin/fm-watch-arm.sh for the true state: it confirms a live watcher and a fresh beacon, or fails loudly.\n'
    printf '●  %s\n' "$fix"
    printf '●%s\n' "$rule"
  } >&2
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
if "$queue_pending"; then
  echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
fi
exit 0
