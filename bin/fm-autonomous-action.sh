#!/usr/bin/env bash
# fm-autonomous-action.sh - append one recent autonomous action for Mission Control.
#
# This is the only writer for $FM_HOME/state/autonomous-actions.ndjson.
# Each line is one JSON object with a timestamp and one of exactly two narrow kinds:
#
#   decision <project> <finding> <decision>
#     Record an ask-user finding firstmate decided under standing authority.
#
#   merge <project> <https-pr-url>
#     Record a PR firstmate merged under standing authority.
#
# The record is forward-only and append-only.
# Mission Control renders at most eight valid entries from its most recent 12-hour window.
# This is awareness rather than project history.
# No caller edits the record format by hand.
#
# Usage:
#   fm-autonomous-action.sh decision <project> <finding> <decision>
#   fm-autonomous-action.sh merge <project> <https-pr-url>
#
# Environment:
#   FM_HOME                         active firstmate home (defaults to this repo)
#   FM_AUTONOMOUS_ACTION_NOW_EPOCH  fixed timestamp for deterministic tests only
#
# Exit codes: 0 appended, 1 refused or write failure, 2 usage error.
set -u

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'fm-autonomous-action: %s\n' "$1" >&2; exit 1; }

valid_text() {  # <value> <maximum-length>
  local value=$1 maximum=$2
  [ -n "$value" ] && [ "${#value}" -le "$maximum" ] || return 1
  case "$value" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EVENTS="$STATE/autonomous-actions.ndjson"

KIND=${1:-}
shift 2>/dev/null || usage
PROJECT=${1:-}
[ -n "$PROJECT" ] || usage
shift
valid_text "$PROJECT" 160 || die "project must be non-empty, single-line text of at most 160 characters"

case "$KIND" in
  decision)
    FINDING=${1:-}
    DECISION=${2:-}
    [ "$#" -eq 2 ] || usage
    valid_text "$FINDING" 400 || die "finding must be non-empty, single-line text of at most 400 characters"
    valid_text "$DECISION" 400 || die "decision must be non-empty, single-line text of at most 400 characters"
    ;;
  merge)
    PR_URL=${1:-}
    [ "$#" -eq 1 ] || usage
    valid_text "$PR_URL" 2048 || die "PR URL must be non-empty, single-line text"
    case "$PR_URL" in https://*) ;; *) die "PR URL must use https" ;; esac
    ;;
  *) usage ;;
esac

NOW=${FM_AUTONOMOUS_ACTION_NOW_EPOCH:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) die "timestamp must be a positive integer epoch" ;; esac
[ "$NOW" -gt 0 ] || die "timestamp must be a positive integer epoch"

[ -d "$STATE" ] || die "state directory not found: $STATE"
[ ! -L "$EVENTS" ] || die "event record must not be a symlink"

if [ "$KIND" = decision ]; then
  RECORD=$(jq -cn --argjson ts "$NOW" --arg project "$PROJECT" \
    --arg finding "$FINDING" --arg decision "$DECISION" \
    '{ts: $ts, kind: "decision", project: $project, finding: $finding, decision: $decision}') \
    || die "could not encode decision event"
else
  RECORD=$(jq -cn --argjson ts "$NOW" --arg project "$PROJECT" --arg pr_url "$PR_URL" \
    '{ts: $ts, kind: "merge", project: $project, pr_url: $pr_url}') \
    || die "could not encode merge event"
fi

old_umask=$(umask)
umask 077
printf '%s\n' "$RECORD" >> "$EVENTS" || {
  umask "$old_umask"
  die "could not append event"
}
umask "$old_umask"
printf '%s\n' "$RECORD"
