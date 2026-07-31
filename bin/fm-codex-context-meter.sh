#!/usr/bin/env bash
# fm-codex-context-meter.sh - report active Codex context use to a Herdr pane.
#
# Codex invokes this command from global SessionStart, PostToolUse, PostCompact,
# and Stop hooks. The hook reads at most the final 4 MiB of the transcript and
# uses the newest event_msg/token_count record. Active context comes from
# last_token_usage.total_tokens, never cumulative total_token_usage.
#
# Every path is silent and exits zero. Missing tools, input, transcript data,
# pane identity, or a working Herdr socket therefore cannot block Codex.
set +e
exec >/dev/null 2>&1

[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0

payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
transcript=$(printf '%s' "$payload" | jq -er '
  select(
    .hook_event_name == "SessionStart" or
    .hook_event_name == "PostToolUse" or
    .hook_event_name == "PostCompact" or
    .hook_event_name == "Stop"
  )
  | .transcript_path
  | strings
  | select(startswith("/"))
' 2>/dev/null) || exit 0
[ -f "$transcript" ] && [ -r "$transcript" ] || exit 0

context=$(
  tail -c 4194304 "$transcript" 2>/dev/null | jq -Rrs '
    def compact:
      if . >= 1000000 then
        (((. + 50000) / 100000 | floor) as $tenths
          | "\($tenths / 10 | floor).\($tenths % 10)m")
      elif . >= 1000 then
        (((. + 50) / 100 | floor) as $tenths
          | "\($tenths / 10 | floor).\($tenths % 10)k")
      else
        tostring
      end;
    [
      split("\n")[]
      | fromjson?
      | select(.type == "event_msg" and .payload.type == "token_count")
      | .payload.info
      | select(
          (.last_token_usage.total_tokens | type) == "number" and
          (.model_context_window | type) == "number" and
          .last_token_usage.total_tokens >= 0 and
          .model_context_window > 0
        )
      | {
          used: (.last_token_usage.total_tokens | floor),
          window: (.model_context_window | floor)
        }
    ]
    | last // empty
    | . + {percent: (((.used * 100 / .window) + 0.5) | floor)}
    | .percent = (if .percent > 100 then 100 else .percent end)
    | . + {filled: (((.percent + 5) / 10) | floor)}
    | ("█" * .filled) + ("░" * (10 - .filled)) +
      " \(.used | compact) / \(.window | compact) · \(.percent)%"
  ' 2>/dev/null
) || exit 0
[ -n "$context" ] || exit 0

# alarm survives exec and bounds an unavailable or wedged Herdr socket.
perl -e 'alarm shift; exec @ARGV' 1 \
  herdr pane report-metadata "$HERDR_PANE_ID" \
  --source firstmate:codex-context --agent codex \
  --token "context=$context" || true
exit 0
