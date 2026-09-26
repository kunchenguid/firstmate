#!/usr/bin/env bash
# Local telemetry aggregation for the Lavish board, using transcript and quota fixtures.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

tmp=$(fm_test_tmproot fm-bearings-metrics)
projects="$tmp/projects"
fakebin="$tmp/bin"
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$projects/nested" "$fakebin"
cat > "$projects/nested/session.jsonl" <<EOF
{"type":"assistant","timestamp":"$timestamp","message":{"usage":{"cache_read_input_tokens":60,"cache_creation_input_tokens":20,"input_tokens":20},"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Bash"}]}}
{"type":"assistant","timestamp":"$timestamp","message":{"usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"input_tokens":0},"content":[{"type":"tool_use","name":"Edit"}]}}
{"type":"user","timestamp":"$timestamp","message":{"content":[{"type":"tool_result","is_error":true},{"type":"tool_result","is_error":false}]}}
{"type":"assistant","timestamp":"2020-01-01T00:00:00Z","message":{"usage":{"cache_read_input_tokens":10000},"content":[{"type":"tool_use","name":"Old"}]}}
{"type":"user","timestamp":"2020-01-01T00:00:00Z","message":{"content":[{"type":"tool_result","is_error":true}]}}
EOF
cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"five_hour","percentRemaining":35},{"id":"seven_day","percentUsed":42}]}]}
JSON
SH
chmod +x "$fakebin/quota-axi"

out=$(PATH="$fakebin:$PATH" FM_BEARINGS_CLAUDE_PROJECTS="$projects" \
  node "$ROOT/bin/fm-bearings-metrics.mjs") || fail "metrics collector failed"
printf '%s' "$out" | jq -e '
  .cache_hit_rate == 60
  and .tool_error_rate == {errors:1,total:3}
  and .quota_session_used_percent == 65
  and .quota_weekly_used_percent == 42
  and (has("context_read_miss") | not)
  and (has("auto_continue") | not)
' >/dev/null || fail "metrics were not derived from transcript and quota fixtures: $out"

pass "the metrics collector emits sourced rates and omits unobservable counters"
