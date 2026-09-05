#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode whenever session-lock ownership was not verified.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# This guard does NOT report watcher liveness. It used to print a bordered
# "WATCHER DOWN - SUPERVISION IS OFF" banner whenever supervision looked
# unhealthy while work was in flight, and that output was removed outright
# rather than made smarter, because it could not tell a working watcher from a
# stopped one. Under the Claude Stop auto-arm model the watcher runs only
# BETWEEN turns, so mid-turn there is legitimately no live watcher and the
# beacon legitimately ages: the banner was a false alarm in essentially every
# printing. The 2026-09-04 supervision investigation measured one session in
# which it printed 21 times, was correct none of those times, and had led to 72
# of that session's 179 commands being wrapped in a filter to hide it - which
# also hid the independent queued-wakes and worktree-tangle alarms below.
# Nothing replaces it here: no conditional banner, no ledger tripwire, and no
# mid-turn repair. The cost is accepted deliberately - if supervision genuinely
# stops, this guard stays silent about it.
#
# What still protects supervision is unchanged and lives elsewhere:
# bin/fm-turnend-guard.sh refuses to let a turn end blind, the auto-arm emits
# its own once-per-episode failure notice, and the /afk daemon supervises
# independently while away. Those are turn-boundary safeguards, not passive
# warnings, and this change does not touch them.
#
# What this guard still does: the worktree-tangle alarm above, and the
# queued-wakes warning below. Both are independent of watcher liveness and were
# never part of the banner. The queued-wakes warning stays silent for the
# supervision branch actor (FM_SUPERVISION_ACTOR=branch), because that actor
# runs guarded commands while handling exactly the queued rows its grant covers
# and can drain nothing else. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

# The current actor (fm_lease_actor is the one owner of that identity); a
# malformed value is a wiring bug elsewhere, so the guard just warns as main.
GUARD_ACTOR=$(fm_lease_actor 2>/dev/null) || GUARD_ACTOR=main

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
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to a session with verified fleet-lock ownership.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute supervision need via the shared grace-based predicate
# (bin/fm-supervision-lib.sh). The guard needs only to know whether ANYTHING is
# riding on supervision, so it can decide whether a pending wake queue is worth
# warning about. It deliberately does NOT ask whether a watcher is alive: see
# the header for why that question was removed rather than refined.
fm_supervision_status "$STATE" "$GRACE"
needed=$FM_SUP_NEEDED
if [ "$needed" = false ]; then
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# Queued wakes are an independent hazard, unrelated to watcher liveness: warn
# whenever they are pending. This warning predates the removed watcher banner
# and is deliberately untouched by that removal.
# The supervision branch is the exception: it runs guarded commands (fm-peek,
# fm-crew-state) in the middle of handling the very rows that are queued, and
# "drain them before anything else" mid-handling reads as "an earlier wake is
# still pending", which is what made it re-run a previous acknowledgement in a
# loop. The branch can act on nothing outside its grant anyway, so for that
# actor the guard stays silent about queued rows.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership." >&2
  elif [ "$GUARD_ACTOR" != branch ]; then
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
