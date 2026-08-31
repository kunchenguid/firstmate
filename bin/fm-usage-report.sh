#!/usr/bin/env bash
# fm-usage-report.sh - plain-text reader for data/usage-ledger.jsonl.
#
# Usage: fm-usage-report.sh [ledger-path]
#
# Prints per-model totals and one row per task from the usage ledger written
# by fm-usage-harvest.sh (that file owns the line schema; this script only
# consumes it). With no argument the ledger resolves from the operational
# home exactly as the harvester does.
#
# Output is aligned plain text; an absent or unavailable field renders as
# "-". The ledger's @tsv rows are read over the unit separator rather than the
# tab, because tab is an IFS whitespace character and an empty field would
# otherwise collapse and shift every later column left.
#
# Both renderings are computed BEFORE the first line is printed, so a ledger
# that jq cannot parse fails with a named diagnostic and a non-zero status
# instead of emitting a physical row count above empty sections.
# Exit status: 0 including when the ledger is absent or empty; 1 when the
# ledger exists but does not parse as JSON lines.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

command -v jq >/dev/null 2>&1 || { printf 'error: jq is required\n' >&2; exit 1; }

LEDGER=${1:-$DATA/usage-ledger.jsonl}
if [ ! -s "$LEDGER" ]; then
  printf 'no usage ledger at %s\n' "$LEDGER"
  exit 0
fi

# Render both sections first: an unparseable ledger must not be reported as a
# successful run with a row count and empty sections below it.
if ! MODEL_ROWS=$(jq -rs '
  [.[] | select(.source != "unavailable")] | sort_by(.model // "?") | group_by(.model // "?")[]
  | [ (.[0].model // "?"), (length | tostring),
      (map(.input_tokens // 0) | add | tostring),
      (map(.cached_input_tokens // 0) | add | tostring),
      (map(.output_tokens // 0) | add | tostring),
      (map(.reasoning_tokens // 0) | add | tostring),
      (map(.wall_secs // 0) | add | tostring) ] | @tsv' "$LEDGER"); then
  printf 'error: %s: ledger is not readable as JSON lines\n' "$LEDGER" >&2
  exit 1
fi
if ! TASK_ROWS=$(jq -r '
  [ (.task // "-"), (.harness // "-"),
    (.model // "-"), (.effort // "-"),
    (.input_tokens // "-"), (.cached_input_tokens // "-"),
    (.output_tokens // "-"), (.reasoning_tokens // "-"),
    (.wall_secs // "-"), (.source // "-") ] | @tsv' "$LEDGER"); then
  printf 'error: %s: ledger is not readable as JSON lines\n' "$LEDGER" >&2
  exit 1
fi

printf 'usage ledger: %s (%s rows)\n' "$LEDGER" "$(wc -l < "$LEDGER" | tr -d ' ')"
echo
echo "per-model totals (source-available rows):"
printf '%-24s %6s %12s %12s %12s %12s %10s\n' \
  model tasks input cached output reasoning wall_secs
if [ -n "$MODEL_ROWS" ]; then
  printf '%s\n' "$MODEL_ROWS" | tr '\t' '\037' |
  while IFS=$'\037' read -r model tasks it ct ot rt wall; do
    printf '%-24s %6s %12s %12s %12s %12s %10s\n' \
      "$model" "$tasks" "$it" "$ct" "$ot" "$rt" "$wall"
  done
fi
echo
echo "per-task rows:"
printf '%-24s %-8s %-20s %-8s %12s %12s %12s %12s %10s %-16s\n' \
  task harness model effort input cached output reasoning wall_secs source
if [ -n "$TASK_ROWS" ]; then
  printf '%s\n' "$TASK_ROWS" | tr '\t' '\037' |
  while IFS=$'\037' read -r task harness model effort it ct ot rt wall source; do
    printf '%-24s %-8s %-20s %-8s %12s %12s %12s %12s %10s %-16s\n' \
      "$task" "$harness" "$model" "$effort" "$it" "$ct" "$ot" "$rt" "$wall" "$source"
  done
fi
