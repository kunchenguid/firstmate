#!/usr/bin/env bash
# fm-brain-usage.sh - read-only aggregation of this home's brain-axi usage log
# (~/.brain/usage.jsonl, resolved via fm-brain-lib.sh) into adoption answers.
#
# It reports who called brain-axi, deliberate vs automatic split, task adoption,
# and recall hit-rate / latency percentiles. It reads usage.jsonl and never
# writes to the store.
#
# brain-axi is an OPTIONAL dependency: an absent or empty usage.jsonl is a clean
# exit-0 no-op.
#
# Usage:
#   fm-brain-usage.sh [--since <ISO|Nd>] [--json]
#   fm-brain-usage.sh -h | --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-brain-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-brain-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

main() {
  local json_out=0 since="" since_days="" since_iso="" store usage_file

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --json)
        json_out=1
        shift
        ;;
      --since)
        [ $# -ge 2 ] || {
          printf 'error: --since requires an argument\n' >&2
          exit 2
        }
        since="$2"
        shift 2
        ;;
      *)
        printf 'error: unrecognized argument: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [ -n "$since" ]; then
    case "$since" in
      *[!0-9]d|d|'')
        since_iso="$since"
        ;;
      *d)
        since_days="${since%d}"
        ;;
      *)
        since_iso="$since"
        ;;
    esac

    if [ -n "$since_iso" ]; then
      if ! command -v jq >/dev/null 2>&1; then
        printf 'fm-brain-usage: jq is required to aggregate usage.jsonl\n' >&2
        exit 1
      fi
      if ! jq -n --arg iso "$since_iso" '($iso | fromdateiso8601)' >/dev/null 2>&1; then
        printf 'error: invalid --since timestamp or duration: %s\n' "$since" >&2
        exit 2
      fi
    fi
  fi

  store=$(fm_brain_store)
  usage_file="$store/usage.jsonl"

  if [ ! -f "$usage_file" ] || [ ! -s "$usage_file" ]; then
    if [ "$json_out" -eq 1 ]; then
      printf '{}\n'
    fi
    exit 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'fm-brain-usage: jq is required to aggregate usage.jsonl\n' >&2
    exit 1
  fi

  local result
  result=$(jq -s \
    --arg since_days "$since_days" \
    --arg since_iso "$since_iso" \
    --arg user "${USER:-}" '
    def non_task: ["firstmate-auto", "fm-remember", "cli", $user, ""];
    def is_task($b): ($b != null) and (non_task | index($b) | not);
    def percentile($a; $p):
      ($a | length) as $n
      | if $n == 0 then 0 else $a[ (($n - 1) * $p | floor) ] end;

    (if ($since_days != "") then
        map(select((try (.at | fromdateiso8601) catch 0) >= (now - ($since_days | tonumber) * 86400)))
     elif ($since_iso != "") then
        map(select((try (.at | fromdateiso8601) catch 0) >= ($since_iso | fromdateiso8601)))
     else . end) as $rows

    | ($rows | map(select(.by == "firstmate-auto")) | length) as $auto
    | ($rows | length) as $total
    | ($total - $auto) as $deliberate
    | ($rows
       | map(select(is_task(.by)))
       | map(select(.verb == "recall" or .verb == "remember"))
       | map(.by) | unique | length) as $adoption
    | ($rows | map(select(.verb == "recall"))) as $recalls
    | ($recalls | length) as $recall_count
    | ($recalls | map(select((.hits // 0) > 0)) | length) as $recall_hits
    | ($recalls | map(.ms // 0) | sort) as $lat
    | {
        total: $total,
        automatic: $auto,
        deliberate: $deliberate,
        automatic_ratio: (if $total > 0 then ($auto / $total) else 0 end),
        by: ($rows | group_by(.by // "(unset)") | map({
               by: (.[0].by // "(unset)"),
               total: length,
               verbs: (group_by(.verb // "(unset)") | map({ verb: (.[0].verb // "(unset)"), count: length }))
             })),
        adoption: $adoption,
        recall: {
          count: $recall_count,
          hit_rate: (if $recall_count > 0 then ($recall_hits / $recall_count) else 0 end),
          hits: $recall_hits,
          latency_ms: {
            p50: percentile($lat; 0.50),
            p95: percentile($lat; 0.95)
          }
        }
      }
  ' "$usage_file" 2>/dev/null) || result=""

  if [ -z "$result" ]; then
    if [ "$json_out" -eq 1 ]; then
      printf '{}\n'
    fi
    exit 0
  fi

  if [ "$json_out" -eq 1 ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$result" | jq -r '
      def pct($v): (($v * 1000) | floor) / 10;
      "brain-axi usage summary",
      "  total calls:      \(.total)",
      "  automatic:        \(.automatic) (firstmate-auto)",
      "  deliberate:       \(.deliberate)",
      "  automatic share:  \(pct(.automatic_ratio))%",
      "  task adoption:    \(.adoption) distinct task(s)",
      "",
      "per-by breakdown:",
      (if (.by | length) == 0 then
         "  (no records in window)"
       else
         (.by | sort_by(-.total) | .[] |
           "  \(.by): \(.total) call(s)  [" + ([.verbs[] | "\(.verb):\(.count)"] | join(", ")) + "]")
       end),
      "",
      "recall quality:",
      "  recalls:   \(.recall.count)",
      "  hit rate:  \(pct(.recall.hit_rate))% (\(.recall.hits)/\(.recall.count))",
      "  latency:   p50=\(.recall.latency_ms.p50)ms  p95=\(.recall.latency_ms.p95)ms"
    '
  fi
}

main "$@"
