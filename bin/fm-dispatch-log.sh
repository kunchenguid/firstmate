#!/usr/bin/env bash
# fm-dispatch-log.sh - durable log of firstmate's own crewmate/scout/secondmate
# dispatches, and a query CLI over it.
#
# Why this exists: state/<id>.meta records harness=/model=/effort=/kind=/mode=/
# backend=/yolo= per task, but that file is deleted at teardown
# (bin/fm-teardown.sh), so nothing survives a task's cleanup to compare dispatch
# patterns - which harness/model got used, how often - across stretches of time
# or across dispatch-policy changes. This is that durable record.
#
# Log format: data/dispatch-log.jsonl (JSON Lines - one JSON object per line, no
# wrapping array). This is the single owner of that format; nowhere else
# restates it. Two event types, each appended best-effort/non-fatal by its
# owning script so a logging failure never fails a spawn or teardown:
#   spawn:    {"event":"spawn","ts":"<ISO8601 UTC>","id":"<task id>",
#              "harness":"...","model":"...","effort":"...","kind":"...",
#              "repo":"...","mode":"...","backend":"...","yolo":"..."}
#             Appended by bin/fm-spawn.sh right after it writes state/<id>.meta,
#             reusing that same already-resolved variables (never recomputed).
#             repo is blank for a kind=secondmate spawn: its resolved path is
#             the secondmate's firstmate home, not a project repo, so it is
#             left empty rather than mislabeled - grouped as "unknown" below.
#   teardown: {"event":"teardown","ts":"<ISO8601 UTC>","id":"<task id>"}
#             Appended by bin/fm-teardown.sh right before it deletes
#             state/<id>.meta. Deliberately minimal: id is the join key back to
#             the task's own spawn line; richer outcome detail (done/failed, PR
#             url) already lives in tasks-axi's own Done record keyed by the
#             same task id, so it is not duplicated here.
# The log is personal fleet data (data/ is gitignored as a whole; AGENTS.md
# section 2), never committed, and never pruned by this script.
#
# A missing data/dispatch-log.jsonl is a valid "no dispatches yet" state, not an
# error: a brand-new fleet has appended nothing. An EXISTING but unreadable log
# (e.g. bad permissions) is a real problem and errors loudly instead of quietly
# reporting zero.
#
# Usage: fm-dispatch-log.sh summary [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#                                    [--group-by model|harness|kind|repo|effort]
#   Filters spawn events (teardown events are join-only and never counted) by
#   ts date (UTC) when --since/--until are given (inclusive on both ends),
#   groups by the chosen field (default: model; a blank or missing value on
#   that field buckets as "unknown"), and prints one "<value>: <count>" line
#   per group - sorted by count descending, then value ascending - followed by
#   a "total: <N>" line. A malformed JSON line is skipped rather than aborting
#   the read. Exit 2 on a bad subcommand, flag, or value; exit 1 if the log
#   exists but cannot be read, or jq is missing; exit 0 otherwise, including
#   the empty-log and no-match cases.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$DATA/dispatch-log.jsonl"

usage() {
  sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SUB=${1:-}
if [ -z "$SUB" ]; then
  echo "error: missing subcommand; usage: fm-dispatch-log.sh summary [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--group-by model|harness|kind|repo|effort]" >&2
  exit 2
fi
case "$SUB" in
  summary) ;;
  *) echo "error: unknown subcommand '$SUB' (only 'summary' is supported)" >&2; exit 2 ;;
esac
shift

SINCE=
UNTIL=
GROUP_BY=model
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 2 ;;
    esac
    case "$want_value" in
      since) SINCE=$a ;;
      until) UNTIL=$a ;;
      group-by) GROUP_BY=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --since) want_value=since ;;
    --since=*) SINCE=${a#--since=} ;;
    --until) want_value=until ;;
    --until=*) UNTIL=${a#--until=} ;;
    --group-by) want_value=group-by ;;
    --group-by=*) GROUP_BY=${a#--group-by=} ;;
    *) echo "error: unknown flag '$a'" >&2; exit 2 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }

validate_date() {
  local label=$1 value=$2
  [ -n "$value" ] || return 0
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
  esac
  echo "error: --$label must be YYYY-MM-DD, got '$value'" >&2
  exit 2
}
validate_date since "$SINCE"
validate_date until "$UNTIL"

case "$GROUP_BY" in
  model|harness|kind|repo|effort) ;;
  *) echo "error: --group-by must be one of model, harness, kind, repo, effort; got '$GROUP_BY'" >&2; exit 2 ;;
esac

if [ ! -e "$LOG" ]; then
  echo "total: 0"
  echo "note: no dispatch log yet ($LOG not found) - no dispatches recorded so far"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not found on PATH" >&2; exit 1; }

if [ ! -r "$LOG" ]; then
  echo "error: dispatch log exists but is not readable: $LOG" >&2
  exit 1
fi

RESULT=$(jq -R -s \
  --arg since "$SINCE" --arg until "$UNTIL" --arg group "$GROUP_BY" '
  def bucket: if ((.[$group] // "") == "") then "unknown" else .[$group] end;
  split("\n")
  | map(select(length > 0))
  | map(try fromjson catch empty)
  | map(select(type == "object" and .event == "spawn"))
  | map(select(
      ($since == "" or ((.ts // "")[0:10] >= $since))
      and ($until == "" or ((.ts // "")[0:10] <= $until))
    ))
  | (group_by(bucket)
     | map({key: (.[0] | bucket), count: length})
     | sort_by(-.count, .key)) as $groups
  | {groups: $groups, total: ($groups | map(.count) | add // 0)}
' "$LOG") || { echo "error: failed to parse dispatch log $LOG" >&2; exit 1; }

printf '%s' "$RESULT" | jq -r '.groups[] | "\(.key): \(.count)"'
printf 'total: %s\n' "$(printf '%s' "$RESULT" | jq -r '.total')"
