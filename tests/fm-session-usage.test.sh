#!/usr/bin/env bash
# tests/fm-session-usage.test.sh - focused executable coverage for the read-only
# Pi 0.83.0 session usage parser and its closed-artifact stability boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARSER="$ROOT/bin/fm-session-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-usage)
FULL="$TMP_ROOT/full.jsonl"
MISSING="$TMP_ROOT/missing.jsonl"
MALFORMED="$TMP_ROOT/malformed.jsonl"
UNSTABLE="$TMP_ROOT/unstable.jsonl"

cat >"$FULL" <<'EOF'
{"type":"session","version":3,"id":"session-phase0","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/secret/project","parentSession":"/secret/parent.jsonl"}
{"type":"message","id":"user-1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"PROMPT_SECRET_DO_NOT_PRINT","timestamp":1}}
{"type":"message","id":"assistant-1","parentId":"user-1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"REASONING_SECRET_DO_NOT_PRINT"},{"type":"toolCall","id":"tool-1","name":"read","arguments":{"path":"/secret/input"}},{"type":"toolCall","id":"tool-2","name":"bash","arguments":{"command":"printf TOOL_ARGUMENT_SECRET"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-test","usage":{"input":100,"output":30,"cacheRead":20,"cacheWrite":5,"reasoning":10,"totalTokens":155,"cost":{"input":0.10,"output":0.30,"cacheRead":0.02,"cacheWrite":0.01,"total":0.43}},"stopReason":"toolUse","timestamp":2}}
{"type":"message","id":"tool-result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"toolResult","toolCallId":"tool-1","toolName":"read","content":[{"type":"text","text":"TOOL_RESULT_SECRET_DO_NOT_PRINT"}],"details":{"path":"/secret/output"},"usage":{"input":2,"output":3,"cacheRead":0,"cacheWrite":0,"totalTokens":5,"cost":{"input":0.02,"output":0.03,"cacheRead":0,"cacheWrite":0,"total":0.05}},"isError":false,"timestamp":3}}
{"type":"message","id":"assistant-2","parentId":"tool-result-1","timestamp":"2026-01-01T00:00:04.000Z","message":{"role":"assistant","content":[{"type":"text","text":"visible reply"}],"api":"openai-responses","provider":"openai","model":"gpt-test","usage":{"input":7,"output":13,"cacheRead":11,"cacheWrite":0,"totalTokens":31,"cost":{"input":0.07,"output":0.13,"cacheRead":0,"cacheWrite":0,"total":0.20}},"stopReason":"stop","timestamp":4}}
{"type":"compaction","id":"compact-1","parentId":"assistant-2","timestamp":"2026-01-01T00:00:05.000Z","summary":"COMPACTION_SECRET_DO_NOT_PRINT","firstKeptEntryId":"assistant-2","tokensBefore":500,"usage":{"input":4,"output":6,"cacheRead":1,"cacheWrite":0,"reasoning":2,"totalTokens":11,"cost":{"input":0.04,"output":0.06,"cacheRead":0.01,"cacheWrite":0,"total":0.11}},"retainedTail":[{"role":"assistant","provider":"anthropic","model":"claude-sonnet-test","usage":{"input":9000,"output":9000,"cacheRead":9000,"cacheWrite":9000,"reasoning":9000,"totalTokens":36000,"cost":{"input":9000,"output":9000,"cacheRead":9000,"cacheWrite":9000,"total":36000}},"content":"RETAINED_TAIL_SECRET_DO_NOT_PRINT"}]}
{"type":"branch_summary","id":"branch-1","parentId":"compact-1","timestamp":"2026-01-01T00:00:06.000Z","fromId":"assistant-1","summary":"BRANCH_SUMMARY_SECRET_DO_NOT_PRINT","usage":{"input":3,"output":4,"cacheRead":0,"cacheWrite":0,"totalTokens":7,"cost":{"input":0.03,"output":0.04,"cacheRead":0,"cacheWrite":0,"total":0.07}}}
{"type":"model_change","id":"model-1","parentId":"branch-1","timestamp":"2026-01-01T00:00:07.000Z","provider":"google","modelId":"gemini-test"}
EOF

cat >"$MISSING" <<'EOF'
{"type":"session","version":3,"id":"session-missing","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/redacted"}
{"type":"message","id":"assistant-missing","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[],"provider":"anthropic","model":"unknown-usage-model","stopReason":"error"}}
EOF

cat >"$MALFORMED" <<'EOF'
{"type":"session","version":3,"id":"session-malformed","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/redacted"}
{"type":"message","id":"assistant-valid","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[],"provider":"anthropic","model":"valid-model","usage":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop"}}
not-json
42
EOF

cat >"$UNSTABLE" <<'EOF'
{"type":"session","version":3,"id":"session-unstable","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/redacted"}
EOF

report=$(
  "$PARSER" --run-label phase0-measurement --role worker --task token-minimization \
    --attempt 0 --settle-ms 0 "$FULL"
) || fail 'the complete closed fixture must parse'

printf '%s\n' "$report" | jq -e '
  .artifact.format == "pi-session-jsonl" and
  .artifact.stability == "stable" and
  .artifact.final == true and
  .session.id == "session-phase0" and
  .metadata.run_label == "phase0-measurement" and
  .metadata.role == "worker" and
  .metadata.task == "token-minimization" and
  .metadata.attempt == 0 and
  .entry_counts.parsed == 8 and
  .entry_counts.malformed == 0 and
  .entry_counts.message == 4 and
  .entry_counts.assistant_message == 2 and
  .entry_counts.tool_result_message == 1 and
  .entry_counts.compaction == 1 and
  .entry_counts.branch_summary == 1 and
  .calls.assistant == 2 and
  .calls.tool == 2 and
  .calls.tool_result == 1 and
  .calls.compaction == 1 and
  .calls.branch_summary == 1 and
  .calls.measured == 5 and
  .totals.provider_usage.input == 116 and
  .totals.provider_usage.cache_read == 32 and
  .totals.provider_usage.cache_write == 5 and
  .totals.provider_usage.output == 56 and
  .totals.provider_usage.provider_total == 209 and
  .totals.provider_usage.reasoning == null and
  (.totals.model_rate_cost_estimate.total - 0.86 | fabs) < 0.0000001
' >/dev/null || fail 'complete fixture totals, counts, and metadata are reported'
pass 'closed fixture reports entry classes, calls, totals, and explicit metadata'

printf '%s\n' "$report" | jq -e '
  ([.records[] | select(.entry_class == "assistant" and .provider == "anthropic")][0]) as $anthropic |
  ([.records[] | select(.entry_class == "assistant" and .provider == "openai")][0]) as $openai |
  ([.records[] | select(.entry_class == "tool_result")][0]) as $tool |
  ([.records[] | select(.entry_class == "compaction")][0]) as $compaction |
  ([.records[] | select(.entry_class == "branch_summary")][0]) as $branch |
  $anthropic.provider_usage.input == 100 and
  $anthropic.provider_usage.output == 30 and
  $anthropic.provider_usage.reasoning == 10 and
  $anthropic.provider_usage.provider_total == 155 and
  ($anthropic.model_rate_cost_estimate.total - 0.43 | fabs) < 0.0000001 and
  $openai.provider_usage.cache_read == 11 and
  $openai.provider_usage.cache_write == 0 and
  $openai.provider_usage.reasoning == null and
  $tool.provider == null and
  $tool.model == null and
  $tool.provider_usage.provider_total == 5 and
  $compaction.provider == null and
  $compaction.provider_usage.reasoning == 2 and
  $branch.provider_usage.provider_total == 7 and
  $anthropic.provider_usage.output != ($anthropic.provider_usage.output + $anthropic.provider_usage.reasoning)
' >/dev/null || fail 'provider fields, cached input, optional reasoning, and separate cost stay distinct'
pass 'provider-native records keep reasoning as an output subset and do not guess summary providers'

assert_not_contains "$report" 'PROMPT_SECRET_DO_NOT_PRINT' 'report must not expose prompts'
assert_not_contains "$report" 'TOOL_RESULT_SECRET_DO_NOT_PRINT' 'report must not expose tool results'
assert_not_contains "$report" 'REASONING_SECRET_DO_NOT_PRINT' 'report must not expose thinking content'
assert_not_contains "$report" 'RETAINED_TAIL_SECRET_DO_NOT_PRINT' 'report must not expose retained history'
assert_not_contains "$report" '/secret/project' 'report must not expose session cwd paths'
assert_not_contains "$report" '/secret/parent.jsonl' 'report must not expose parent session paths'
assert_not_contains "$report" "$FULL" 'report must not expose the source path'
pass 'report is content-free and omits authenticated content and secret-bearing paths'

missing_report=$("$PARSER" --settle-ms 0 "$MISSING") || fail 'missing-usage fixture must still produce a report'
printf '%s\n' "$missing_report" | jq -e '
  .artifact.final == true and
  .calls.assistant == 1 and
  .calls.measured == 0 and
  .records[0].usage_state == "missing" and
  .records[0].provider_usage == null and
  .records[0].model_rate_cost_estimate == null and
  .totals.provider_usage.input == null and
  .totals.provider_usage.output == null and
  any(.warnings[]; .code == "missing_usage")
' >/dev/null || fail 'missing usage remains unknown instead of becoming zero'
pass 'missing usage is warned and represented as unknown'

malformed_report=$("$PARSER" --settle-ms 0 "$MALFORMED") || fail 'malformed fixture must produce a partial report'
printf '%s\n' "$malformed_report" | jq -e '
  .artifact.final == false and
  .entry_counts.parsed == 2 and
  .entry_counts.malformed == 2 and
  .totals.provider_usage.input == 1 and
  any(.warnings[]; .code == "malformed_json" and .line == 3) and
  any(.warnings[]; .code == "record_not_object" and .line == 4)
' >/dev/null || fail 'malformed records are warned without leaking their contents'
pass 'malformed records make the report non-final while valid records remain measurable'

(
  i=0
  while [ "$i" -lt 30 ]; do
    sleep 0.01
    printf '%s\n' '{"type":"message","message":{"role":"user","content":"GROWING_SECRET"}}' >>"$UNSTABLE"
    i=$((i + 1))
  done
) &
MUTATOR=$!
unstable_report=$("$PARSER" --settle-ms 100 "$UNSTABLE") || fail 'unstable fixture must still produce a report'
wait "$MUTATOR" || fail 'unstable fixture mutator failed'
printf '%s\n' "$unstable_report" | jq -e '
  .artifact.final == false and
  .artifact.stability == "unstable" and
  any(.warnings[]; .code == "unstable_file")
' >/dev/null || fail 'a growing file is explicitly marked non-final'
pass 'growing session files are detected without mutating or recursively rereading them'

resolve_pi_root() {
  local pi_bin=$1 link entry
  if [ -L "$pi_bin" ]; then
    link=$(readlink "$pi_bin") || return 1
    case "$link" in
      /*) entry=$link ;;
      *) entry=$(dirname "$pi_bin")/$link ;;
    esac
  else
    entry=$pi_bin
  fi
  entry=$(cd "$(dirname "$entry")" && pwd)/$(basename "$entry") || return 1
  cd "$(dirname "$entry")/.." && pwd
}

if command -v pi >/dev/null 2>&1 && [ "$(pi --version 2>/dev/null | head -n 1)" = "0.83.0" ] &&
  command -v node >/dev/null 2>&1; then
  PI_ROOT=$(resolve_pi_root "$(command -v pi)") || fail 'installed Pi path could not be resolved'
  PI_CWD="$TMP_ROOT/pi-cwd"
  mkdir -p "$PI_CWD"
  pi_stats=$(PI_ROOT="$PI_ROOT" node --input-type=module - "$FULL" "$PI_CWD" 2>"$TMP_ROOT/pi-stats.stderr" <<'NODE'
import { pathToFileURL } from "node:url";

const [file, cwd] = process.argv.slice(2);
const root = process.env.PI_ROOT;
if (!root) throw new Error("missing Pi root");
const { createAgentSession, SessionManager } = await import(
  pathToFileURL(`${root}/dist/index.js`).href,
);
const manager = SessionManager.open(file, undefined, cwd);
const { session } = await createAgentSession({
  cwd,
  agentDir: `${cwd}/agent`,
  sessionManager: manager,
  noTools: "all",
});
process.stdout.write(JSON.stringify(session.getSessionStats()));
NODE
  ) || {
    cat "$TMP_ROOT/pi-stats.stderr" >&2
    fail 'Pi 0.83.0 session-stat comparison failed'
  }
  printf '%s\n' "$report" | jq -e --argjson stats "$pi_stats" '
    .entry_counts.message == $stats.totalMessages and
    .calls.assistant == $stats.assistantMessages and
    .calls.tool == $stats.toolCalls and
    .calls.tool_result == $stats.toolResults and
    .totals.provider_usage.input == $stats.tokens.input and
    .totals.provider_usage.output == $stats.tokens.output and
    .totals.provider_usage.cache_read == $stats.tokens.cacheRead and
    .totals.provider_usage.cache_write == $stats.tokens.cacheWrite and
    ((.totals.provider_usage.input + .totals.provider_usage.output + .totals.provider_usage.cache_read + .totals.provider_usage.cache_write) == $stats.tokens.total) and
    ((.totals.model_rate_cost_estimate.total - $stats.cost) | fabs) < 0.0000001
  ' >/dev/null || fail 'parser totals must match installed Pi 0.83.0 session statistics'
  pass 'parser totals match installed Pi 0.83.0 session-stat behavior'
else
  pass 'Pi 0.83.0 session-stat comparison skipped because the installed interface is unavailable'
fi
