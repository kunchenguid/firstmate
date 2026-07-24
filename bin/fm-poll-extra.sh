#!/usr/bin/env bash
# The extra questions this checkout's armed PR/MR poll asks, beyond "has it
# merged?", which bin/fm-pr-poll.sh owns alone.
#
# Usage (called only by bin/fm-pr-poll.sh, never by hand):
#   fm-poll-extra.sh <phase> <check-path> <provider> <url> <host> <path> <number>
#
#   <phase>       begin   before the provider lookup runs
#                 merged  the PR/MR is merged
#                 open    the lookup answered and it is not merged
#                 unknown the lookup could not answer at all
#   <check-path>  the poll's published state/<id>.check.sh path, which names both
#                 the task and the state directory holding its records
#
# Why this file exists at all: the merge poll is a byte-static program shared with
# upstream, and a direct-PR task needs two more answers that only this fleet's
# no-mistakes watch run can give. Keeping them here means the poll itself stays
# the upstream bytes, and this checkout's own questions live in a file upstream
# never ships. bin/fm-pr-poll.sh calls it when it is present and ignores it
# completely when it is not.
#
# The questions, both answered only for the run id state/<id>.meta records as
# THIS task's (nm_watch_run=, written by bin/fm-nm-watch.sh):
#   1. has this task's watch run parked?     -> "watch parked: ..."
#   2. is this task's watch run still alive? -> "watch gone: ..."
# Run-id scoping is a hard boundary. `no-mistakes parked` is a machine-wide
# record, and the captain runs no-mistakes on their own work outside the fleet:
# those runs belong to no task, and firstmate must never read, report, or answer
# them. A task with no recorded run id has no watch question to ask.
#
# The watcher's check contract is unchanged: output = wake firstmate, silence =
# keep sleeping, at most one line per poll. A signal not printed this cycle stays
# pending and prints on the next one.
#
# Silence on error, with one bounded exception. Every lookup here shells out to
# no-mistakes, which has its own timeouts and failure modes, and a lookup that
# cannot answer is never turned into a signal: a missing binary, a dead daemon,
# revoked auth, or a network failure prints nothing at all. What it does do is
# count, and after FM_CHECK_FAIL_WAKE_AFTER consecutive cycles in which something
# failed to answer, the poll reports ITSELF broken once - a diagnostic that says
# merge polling is not running, never a merge and never a park. That one line is
# the difference between a poll that is quiet because there is nothing to say and
# a poll that is quiet because it is dead. Any cycle that answers resets it.
#
# The decision logic is bin/fm-poll-lib.sh's, sourced here rather than copied, so
# a poll armed before a fix still gets the fix on its next cycle.
#
# State this owns under the state directory, all cleaned up by bin/fm-teardown.sh:
#   <id>.check.fails  consecutive lookup failures
#   <id>.check.error  the poll-broken diagnostic was already reported
#   <id>.check.nm     one-shot dedup for the watch signals (run=, parked=, gone=)
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$#" -eq 7 ] || exit 0
PHASE=$1
CHECK=$2
URL=$4

# The published poll path names the task; anything else is not one of ours.
case "$CHECK" in
  */*.check.sh) ;;
  *) exit 0 ;;
esac
STATE=${CHECK%/*}
ID=${CHECK##*/}
ID=${ID%.check.sh}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh" 2>/dev/null || exit 0
fm_pr_task_id_valid "$ID" || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

META="$STATE/$ID.meta"
MARKER="$STATE/$ID.check.error"
FAILFILE="$STATE/$ID.check.fails"
NMFILE="$STATE/$ID.check.nm"

read_fails() {
  local n
  n=$(cat "$FAILFILE" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

case "$PHASE" in
  begin)
    # Count the attempt BEFORE the lookup, so a poll the watcher kills at its
    # timeout still leaves the evidence that it never answered.
    printf '%s\n' "$(( $(read_fails) + 1 ))" > "$FAILFILE" 2>/dev/null || true
    exit 0
    ;;
  merged)
    # Landing ends the task's whole monitoring story: no watch question outlives
    # it, so the one-shot state goes with the failure count.
    rm -f "$FAILFILE" "$NMFILE"
    exit 0
    ;;
  open|unknown) ;;
  *) exit 0 ;;
esac

# shellcheck source=bin/fm-poll-lib.sh
. "$SCRIPT_DIR/fm-poll-lib.sh" 2>/dev/null || exit 0

ok=0
[ "$PHASE" = open ] && ok=1
FAILS=$(read_fails)
SIGNAL=

RUN=$(fm_poll_field "$META" nm_watch_run)
if [ -n "$RUN" ]; then
  SIGNAL=$(fm_poll_watch_signals "$META" "$RUN" "$NMFILE") || ok=0
fi

# A cycle in which everything answered ends the episode, marker included: the
# diagnostic below costs one wake per episode, not one per cycle, and a poll that
# recovered must be able to report a LATER breakage. Nothing else clears the
# marker on a live task - re-arming a poll no longer rewrites the state file that
# used to carry it away - so leaving it behind here would blind the task for good
# after its first broken episode.
if [ "$ok" = 1 ]; then
  rm -f "$FAILFILE" "$MARKER"
fi

if [ -n "$SIGNAL" ]; then
  printf '%s\n' "$SIGNAL"
  exit 0
fi

# Only a cycle in which something failed to answer can be a broken poll: the
# count is of CONSECUTIVE failures, and this cycle answering resets it.
if [ "$ok" != 1 ] && [ "$FAILS" -ge "$(fm_poll_wake_after)" ]; then
  fm_poll_report_broken "$MARKER" \
    "cannot read the PR/MR or its watch run after $FAILS consecutive lookup failures (check gh/bytedcli auth and no-mistakes)" \
    "$URL"
fi
exit 0
