#!/usr/bin/env bash
# Render the private closed-task history.
#
# Usage: fm-history.sh [--json] [--limit <n>] [<canonical-id|human-name>]
#        fm-history.sh [--json] [--limit <n>] --search <text>
#
# History reads only completed closure records under data/closed-tasks. Prepared
# records from an interrupted close stay hidden until fm-close.sh finishes them.
# Positional lookup is exact and accepts canonical ids or unambiguous human
# names, never retired t1-t99 references. --search is a case-insensitive bounded
# text search across identity, project, result, artifacts, and follow-up links.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARCHIVE_ROOT="$DATA/closed-tasks"
FORMAT=text
LIMIT=${FM_HISTORY_LIMIT:-50}
SELECTOR=
SEARCH=

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json; shift ;;
    --limit)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      LIMIT=$2; shift 2
      ;;
    --search)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SEARCH=$2; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'fm-history: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)
      [ -z "$SELECTOR" ] || { usage >&2; exit 2; }
      SELECTOR=$1; shift
      ;;
  esac
done
case "$LIMIT" in ''|*[!0-9]*|0) printf 'fm-history: --limit must be a positive integer\n' >&2; exit 2 ;; esac
[ "$LIMIT" -le 500 ] || LIMIT=500
[ -z "$SELECTOR" ] || [ -z "$SEARCH" ] || { printf 'fm-history: use exact lookup or --search, not both\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'fm-history: jq is required\n' >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-history.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
if [ -e "$ARCHIVE_ROOT" ] || [ -L "$ARCHIVE_ROOT" ]; then
  [ -d "$ARCHIVE_ROOT" ] && [ ! -L "$ARCHIVE_ROOT" ] || {
    printf 'fm-history: closed-task archive is unsafe at %s\n' "$ARCHIVE_ROOT" >&2
    exit 1
  }
  for record in "$ARCHIVE_ROOT"/*/closure.json; do
    [ -d "${record%/*}" ] && [ ! -L "${record%/*}" ] || continue
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    parsed=$(jq -c 'select(.version == 1 and (.disposition == "prepared" or .disposition == "closed")
      and (.id | type == "string") and (.name | type == "string"))' "$record" 2>/dev/null) || {
      printf 'fm-history: invalid closure record at %s\n' "$record" >&2
      exit 1
    }
    [ -n "$parsed" ] || {
      printf 'fm-history: invalid closure record at %s\n' "$record" >&2
      exit 1
    }
    archive_id=${record%/*}; archive_id=${archive_id##*/}
    [ "$(printf '%s\n' "$parsed" | jq -r '.id')" = "$archive_id" ] || {
      printf 'fm-history: closure identity does not match its archive directory at %s\n' "$record" >&2
      exit 1
    }
    [ "$(printf '%s\n' "$parsed" | jq -r '.disposition')" = closed ] || continue
    printf '%s\n' "$parsed" >> "$TMP"
  done
fi

MODEL=$(jq -s --arg selector "$SELECTOR" --arg search "$SEARCH" --argjson limit "$LIMIT" '
  sort_by([-(.closedEpoch // 0), .id])
  | if $selector != "" then
      map(select(.id == $selector or .name == $selector))
      | if length > 1 then error("ambiguous closed-task name; use a canonical id") else . end
    elif $search != "" then
      ($search | ascii_downcase) as $q
      | map(select(([
          .id, .name, .project, .kind, .result,
          (.artifacts[]?), (.retainedKnowledge[]?), (.followUps[]?)
        ] | map(select(. != null) | tostring) | join(" ") | ascii_downcase | contains($q))))
    else . end
  | .[:$limit]
' "$TMP" 2>&1) || { printf 'fm-history: %s\n' "$MODEL" >&2; exit 1; }

if [ "$(printf '%s\n' "$MODEL" | jq 'length')" -eq 0 ] && [ -n "$SELECTOR" ]; then
  printf 'fm-history: no closed task with canonical id or name %s\n' "$SELECTOR" >&2
  exit 1
fi
if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi
if [ "$(printf '%s\n' "$MODEL" | jq 'length')" -eq 0 ]; then
  printf 'No closed tasks.\n'
  exit 0
fi
printf '%s\n' "$MODEL" | jq -r '.[] |
  (.dates.closed // "unknown" | sub("T.*$"; "")) as $date
  | (.artifacts // []) as $artifacts
  | (if ($artifacts | length) == 0 then ""
     else " | " + ($artifacts | join(", ")) end) as $links
  | "\($date)  \(.name) [\(.id)]  \(.project // "-")/\(.kind // "task") - \(.result)\($links)"'
