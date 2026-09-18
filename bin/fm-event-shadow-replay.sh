#!/usr/bin/env bash
# fm-event-shadow-replay.sh [--live | --response <json>]
# Replays the committed sanitized eight-event set through fm-event-shadow.sh.
# Default uses a synthetic response with one intentional high-confidence error
# to exercise confusion reporting; it is not empirical model accuracy evidence.
# --live makes one real batched request using runtime TYPESAFE_API_KEY; no key is
# read from a file or persisted. Missing credentials fail before making a call.
# Output: private call record, expected/predicted confusion rows, error examples,
# and hypothetical avoidable frontier inspections (true/false positive counts).
# Actual skipped decisions remain zero. No behavior is activated by this tool.
# Uses FM_STATE_OVERRIDE or FM_HOME/state for the journal, like the adapter.
# Offline reproduction of the recorded live response (no API request):
# Create a private state directory, set FM_STATE_OVERRIDE to it, then run
# bin/fm-event-shadow-replay.sh --response tests/fixtures/event-shadow/live-response.json
# This recomputes policy results; live-evidence.json retains original call
# provenance and costs, while replay output marks the source as replay.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}
FIXTURES="$ROOT/tests/fixtures/event-shadow"
case "${1:-}" in
  '') set -- --response "$FIXTURES/synthetic-response.json" ;;
  --response) [ $# -eq 2 ] || exit 2 ;;
  --live) [ $# -eq 1 ] && [ -n "${TYPESAFE_API_KEY:-}" ] || { echo 'live replay requires runtime TYPESAFE_API_KEY' >&2; exit 2; }; set -- ;;
  *) echo 'usage: fm-event-shadow-replay.sh [--live | --response <json>]' >&2; exit 2 ;;
esac
[ -d "$STATE" ] || { echo 'create a private state directory and set FM_STATE_OVERRIDE first' >&2; exit 2; }
# Isolate this call so a concurrent drain cannot confuse the measurement.
REPLAY=$(mktemp -d "$STATE/event-shadow-replay.XXXXXX")
trap 'rm -rf -- "$REPLAY"' EXIT
FM_EVENT_SHADOW=1 FM_STATE_OVERRIDE="$REPLAY" "$SCRIPT_DIR/fm-event-shadow.sh" --samples "$FIXTURES/samples.json" "$@" >&2
[ -f "$REPLAY/event-shadow/calls.jsonl" ] || { echo 'no replay record produced' >&2; exit 1; }
jq -s --slurpfile samples "$FIXTURES/samples.json" '
  .[0] as $call |
  ($call.results | map(. as $r | $r + {expected:($samples[0][]|select(.id==$r.id)|.expected)})) as $rows |
  {call:$call,confusion:($rows|group_by([.expected,.choice])|map({expected:.[0].expected,predicted:.[0].choice,count:length})),
   errors:($rows|map(select((.abstained|not) and .expected!=.choice))),
   abstentions:($rows|map(select(.abstained))),
   frontier_true_positives:($rows|map(select(.frontier_candidate and .expected=="declared_wait"))|length),
   frontier_false_positives:($rows|map(select(.frontier_candidate and .expected!="declared_wait"))|length),
   recommendation:"Keep shadow-only; this small declaration-only sample cannot establish safe autonomous behavior."}
' "$REPLAY/event-shadow/calls.jsonl"
