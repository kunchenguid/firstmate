#!/usr/bin/env bash
# fm-status.sh - report one status line to this home's status file.
#
# Usage: fm-status.sh <task-id> "<state>: <one short line>"
#        FM_HOME=<home> fm-status.sh <task-id> "done: ..."
#
# States: working, needs-decision, blocked, done, failed.
#
# WHY THIS EXISTS, RATHER THAN `echo "..." >> state/<id>.status`
#
# The redirect form does not work for the agents that need it. The global
# permission profile denies Edit(~/firstmate/**), and a shell redirect into that
# tree is classified as an edit and refused. A crewmate whose brief told it to
# report that way was refused five times in a single task; the status file was
# never created, and no status line ever reached firstmate. The work got done
# and the supervisor could not see it - a silently dead channel, which is the
# worst failure mode a reporting path can have, because it looks like silence
# rather than an error.
#
# The append happens INSIDE this script, which the profile permits. That is the
# whole point: reporting is a verb, not a redirect. Briefs teach this form
# (bin/fm-brief.sh), and gate fm-status-verb freezes the property that a
# crewmate whose direct redirect is refused can still report through it.
#
# Each appended line wakes firstmate, so this writes exactly one line per call
# and refuses an empty message. Report sparingly: phase changes a supervisor
# would act on, and the needs-decision/blocked/done/failed states.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: $(basename "$0") <task-id> \"<state>: <one short line>\"" >&2
  echo "  states: working, needs-decision, blocked, done, failed" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ID=$1
MSG=$2

[ -n "$ID" ] || usage
# The id names a file in this home's state dir and nothing else. A separator or
# a traversal would silently write outside it, which is exactly the kind of
# quiet misdirection this script exists to remove.
case "$ID" in
  */*|*\\*|.|..|.*|"") echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac

# An empty or whitespace-only message would append a blank line, which still
# wakes firstmate but tells it nothing. Refuse it rather than spend a wake.
[ -n "$(printf '%s' "$MSG" | tr -d '[:space:]')" ] \
  || { echo "error: refusing to report an empty status line" >&2; exit 2; }

# One call, one line, one wake. A message carrying newlines would otherwise
# forge extra records - each of which firstmate reads as a separate report.
MSG=$(printf '%s' "$MSG" | tr '\n\r' '  ')

mkdir -p "$STATE"
printf '%s\n' "$MSG" >> "$STATE/$ID.status"
