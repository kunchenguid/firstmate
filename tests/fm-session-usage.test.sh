#!/usr/bin/env bash
# tests/fm-session-usage.test.sh - executable Phase 0 parser coverage.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARSER="$ROOT/bin/fm-session-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-usage)
FULL="$TMP_ROOT/full.jsonl"; MISSING="$TMP_ROOT/missing.jsonl"; MALFORMED="$TMP_ROOT/malformed.jsonl"; UNSTABLE="$TMP_ROOT/unstable.jsonl"; OPTIONAL="$TMP_ROOT/optional.jsonl"; LATE="$TMP_ROOT/late.jsonl"; COST_INVALID="$TMP_ROOT/cost-invalid.jsonl"; COST_PARTIAL="$TMP_ROOT/cost-partial.jsonl"
cat >"$FULL" <<'EOF'
{"type":"session","version":3,"id":"session-phase0","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/secret/project","parentSession":"/secret/parent.jsonl"}
{"type":"message","id":"user-1","message":{"role":"user","content":"PROMPT_SECRET_DO_NOT_PRINT"}}
{"type":"message","id":"assistant-1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"REASONING_SECRET_DO_NOT_PRINT"},{"type":"toolCall","id":"tool-1","name":"read","arguments":{"path":"/secret/input"}},{"type":"toolCall","id":"tool-2","name":"bash","arguments":{"command":"printf TOOL_ARGUMENT_SECRET"}}],"provider":"anthropic","model":"claude-sonnet-test","usage":{"input":100,"output":30,"cacheRead":20,"cacheWrite":5,"reasoning":10,"totalTokens":155,"cost":{"input":0.10,"output":0.30,"cacheRead":0.02,"cacheWrite":0.01,"total":0.43}}}}
{"type":"message","id":"tool-result-1","message":{"role":"toolResult","toolCallId":"tool-1","content":[{"type":"text","text":"TOOL_RESULT_SECRET_DO_NOT_PRINT"}],"usage":{"input":2,"output":3,"cacheRead":0,"cacheWrite":0,"totalTokens":5,"cost":{"input":0.02,"output":0.03,"cacheRead":0,"cacheWrite":0,"total":0.05}}}}
{"type":"message","id":"assistant-2","message":{"role":"assistant","content":[{"type":"text","text":"visible reply"}],"provider":"openai","model":"gpt-test","usage":{"input":7,"output":13,"cacheRead":11,"cacheWrite":0,"totalTokens":31,"cost":{"input":0.07,"output":0.13,"cacheRead":0,"cacheWrite":0,"total":0.20}}}}
{"type":"compaction","id":"compact-1","usage":{"input":4,"output":6,"cacheRead":1,"cacheWrite":0,"reasoning":2,"totalTokens":11,"cost":{"input":0.04,"output":0.06,"cacheRead":0.01,"cacheWrite":0,"total":0.11}},"retainedTail":[{"role":"assistant","provider":"anthropic","usage":{"input":9000,"output":9000,"cacheRead":9000,"cacheWrite":9000,"reasoning":9000,"totalTokens":36000,"cost":{"input":9000,"output":9000,"cacheRead":9000,"cacheWrite":9000,"total":36000}},"content":"RETAINED_TAIL_SECRET_DO_NOT_PRINT"}]}
{"type":"branch_summary","id":"branch-1","usage":{"input":3,"output":4,"cacheRead":0,"cacheWrite":0,"totalTokens":7,"cost":{"input":0.03,"output":0.04,"cacheRead":0,"cacheWrite":0,"total":0.07}},"summary":"BRANCH_SUMMARY_SECRET_DO_NOT_PRINT"}
{"type":"model_change","provider":"google","modelId":"gemini-test"}
EOF
printf '%s\n' \
 '{"type":"session","version":3,"id":"session-missing","cwd":"/redacted"}' \
 '{"type":"message","message":{"role":"assistant","content":[],"provider":"anthropic","model":"unknown-usage-model"}}' >"$MISSING"
printf '%s\n' \
 '{"type":"session","version":3,"id":"session-malformed","cwd":"/redacted"}' \
 '{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"valid-model","usage":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}' \
 'not-json' '42' >"$MALFORMED"
printf '%s\n' '{"type":"session","version":3,"id":"session-unstable","cwd":"/redacted"}' >"$UNSTABLE"
cat >"$OPTIONAL" <<'EOF'
{"type":"session","version":3,"id":"optional-parity","cwd":"/tmp/phase0"}
{"type":"message","id":"assistant-optional","message":{"role":"assistant","content":[{"type":"toolCall","id":"tool-optional","name":"read","arguments":{}}],"provider":"proxy","model":"requested-model","responseModel":"served-model","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"cost":{"input":0.1,"output":0.2,"cacheRead":0.3,"cacheWrite":0.4,"total":1.0}},"stopReason":"toolUse"}}
{"type":"message","id":"tool-optional","message":{"role":"toolResult","toolCallId":"tool-optional","toolName":"read","content":[],"isError":false}}
{"type":"compaction","id":"compact-optional","summary":"summary","tokensBefore":10}
{"type":"branch_summary","id":"branch-optional","summary":"branch","fromId":"assistant-optional"}
EOF
cat >"$LATE" <<'EOF'
{"type":"message","id":"user-late","message":{"role":"user","content":"late"}}
{"type":"session","version":3,"id":"late-header","cwd":"/tmp/phase0"}
EOF
cat >"$COST_INVALID" <<'EOF'
{"type":"session","version":3,"id":"cost-invalid","cwd":"/tmp/phase0"}
{"type":"message","message":{"role":"assistant","provider":"test-provider","model":"test-model","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10}}}
{"type":"message","message":{"role":"assistant","provider":"test-provider","model":"test-model","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"cost":"not-an-object"}}}
EOF
cat >"$COST_PARTIAL" <<'EOF'
{"type":"session","version":3,"id":"cost-partial","cwd":"/tmp/phase0"}
{"type":"message","message":{"role":"assistant","provider":"test-provider","model":"test-model","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"cost":{"input":0.1,"output":"invalid","cacheRead":0.2,"total":0.3}}}}
EOF

check() { local input=$1 filter=$2 message=$3; shift 3; printf '%s\n' "$input" | jq -e "$@" "$filter" >/dev/null || fail "$message"; }
report=$("$PARSER" --run-label phase0-measurement --role worker --task token-minimization --attempt 0 --settle-ms 0 "$FULL") || fail 'complete fixture must parse'
check "$report" '.artifact.format == "pi-session-jsonl" and .artifact.stability == "stable" and .artifact.final and .session.id == "4d5604d79a794d1662d745d204d09fcc6cc19f76ce42018b7fc42442693e7d5c" and .metadata == {run_label:"phase0-measurement",role:"worker",task:"token-minimization",attempt:0} and .entry_counts == {parsed:8,malformed:0,session:1,message:4,user_message:1,assistant_message:2,tool_result_message:1,compaction:1,branch_summary:1,other:1} and .calls == {assistant:2,tool:2,tool_result:1,compaction:1,branch_summary:1,measured:5} and .totals.provider_usage == {input:116,cache_read:32,cache_write:5,output:56,reasoning:null,provider_total:209} and ((.totals.model_rate_cost_estimate.total - .86)|fabs) < 0.0000001 and (.limitations[0] | contains("observed-stable"))' 'complete fixture totals and counts are reported'
check "$report" '([.records[]|select(.entry_class=="assistant" and .provider=="anthropic")][0]) as $a | ([.records[]|select(.entry_class=="assistant" and .provider=="openai")][0]) as $o | ([.records[]|select(.entry_class=="tool_result")][0]) as $t | ([.records[]|select(.entry_class=="compaction")][0]) as $c | ([.records[]|select(.entry_class=="branch_summary")][0]) as $b | $a.model == "claude-sonnet-test" and $a.provider_usage == {input:100,cache_read:20,cache_write:5,output:30,reasoning:10,provider_total:155} and ($a.model_rate_cost_estimate.total-.43|fabs)<.0000001 and $o.provider_usage.cache_read==11 and $o.provider_usage.reasoning==null and $t.provider==null and $t.model==null and $t.provider_usage.provider_total==5 and $c.provider_usage.reasoning==2 and $b.provider_usage.provider_total==7' 'provider, cached input, reasoning, and cost stay distinct'
for secret in PROMPT_SECRET_DO_NOT_PRINT TOOL_RESULT_SECRET_DO_NOT_PRINT REASONING_SECRET_DO_NOT_PRINT RETAINED_TAIL_SECRET_DO_NOT_PRINT /secret/project /secret/parent.jsonl session-phase0 "$FULL"; do assert_not_contains "$report" "$secret" 'report must be content-free'; done
pass 'observed-stable records remain privacy-safe and top-level retained-tail usage is not counted twice'
optional_report=$("$PARSER" --settle-ms 0 "$OPTIONAL") || fail 'optional-usage parity fixture must parse'
check "$optional_report" '.artifact.final and .session.id == "997d7cf59c4a95139ff7e7aebb9f009c4e9252fa227a8ab026ede7e5e35b6843" and (.records|length)==1 and .records[0].model=="served-model" and .calls == {assistant:1,tool:1,tool_result:1,compaction:1,branch_summary:1,measured:1} and .totals.provider_usage == {input:1,cache_read:3,cache_write:4,output:2,reasoning:null,provider_total:10} and .totals.model_rate_cost_estimate.total==1 and (all(.warnings[];.code!="missing_usage"))' 'optional no-usage records are omitted, responseModel wins, and native totals stay exact'
assert_not_contains "$optional_report" optional-parity 'aggregate session IDs must be digests'
late_report=$("$PARSER" --settle-ms 0 "$LATE") || fail 'late-header fixture must parse'
check "$late_report" '.artifact.final==false and .session.id == "9327569034341341751ad3db62e5a74554cd479dddfd0a7208ea91744615a4d3" and any(.warnings[];.code=="session_header_not_first" and .line==2)' 'a late session header is not final'
missing_report=$("$PARSER" --settle-ms 0 "$MISSING") || fail 'missing-usage fixture must parse'
check "$missing_report" '.artifact.final and .calls.assistant==1 and .calls.measured==0 and .records[0].usage_state=="missing" and .records[0].provider_usage==null and .records[0].model_rate_cost_estimate==null and .totals.provider_usage.input==null and .totals.provider_usage.output==null and any(.warnings[];.code=="missing_usage")' 'missing usage remains unknown instead of zero'
pass 'missing usage is warned and represented as unknown'
cost_invalid_report=$("$PARSER" --settle-ms 0 "$COST_INVALID") || fail 'missing and non-object cost fixture must parse'
check "$cost_invalid_report" '.artifact.final and (.records|length)==2 and .calls.measured==2 and all(.records[];.model_rate_cost_estimate==null) and .totals.model_rate_cost_estimate == {input:null,cache_read:null,cache_write:null,output:null,total:null} and ([.warnings[]|select(.code=="unknown_model_rate_cost")]|length)==2 and ([.warnings[]|select(.code=="unknown_model_rate_cost_field")]|length)==0' 'missing and non-object costs remain unknown with section warnings'
pass 'missing and non-object model-rate costs are warned without aborting'
cost_partial_report=$("$PARSER" --settle-ms 0 "$COST_PARTIAL") || fail 'partially invalid cost fixture must parse'
check "$cost_partial_report" '.artifact.final and .totals.model_rate_cost_estimate.input==0.1 and .totals.model_rate_cost_estimate.cache_read==0.2 and .totals.model_rate_cost_estimate.output==null and .totals.model_rate_cost_estimate.cache_write==null and .totals.model_rate_cost_estimate.total==0.3 and ([.warnings[]|select(.code=="unknown_model_rate_cost_field" and .field=="output")]|length)==1 and ([.warnings[]|select(.code=="unknown_model_rate_cost_field" and .field=="cacheWrite")]|length)==1 and ([.warnings[]]|length)==2' 'partial model-rate costs preserve valid values and warn on invalid fields'
pass 'partial model-rate costs warn on missing and invalid scalars'
malformed_report=$("$PARSER" --settle-ms 0 "$MALFORMED") || fail 'malformed fixture must parse'
check "$malformed_report" '.artifact.final==false and .entry_counts.parsed==2 and .entry_counts.malformed==2 and .totals.provider_usage.input==1 and any(.warnings[];.code=="malformed_json" and .line==3) and any(.warnings[];.code=="record_not_object" and .line==4)' 'malformed records remain measurable without becoming final'
pass 'malformed records are warned and make the report non-final'
(
  i=0; while [ "$i" -lt 30 ]; do sleep 0.01; printf '%s\n' '{"type":"message","message":{"role":"user","content":"GROWING_SECRET"}}' >>"$UNSTABLE"; i=$((i + 1)); done
) & MUTATOR=$!
unstable_report=$("$PARSER" --settle-ms 100 "$UNSTABLE") || fail 'unstable fixture must parse'; wait "$MUTATOR" || fail 'unstable fixture mutator failed'
check "$unstable_report" '.artifact.final==false and .artifact.stability=="unstable" and any(.warnings[];.code=="unstable_file")' 'growing files are non-final'
pass 'growing session files are detected'
if command -v pi >/dev/null 2>&1 && [ "$(pi --version 2>/dev/null | head -n1)" = 0.83.0 ] && command -v node >/dev/null 2>&1; then
  PI_ROOT=$(node -p 'const fs=require("fs"),p=require("path"),x=fs.realpathSync(process.argv[1]);p.resolve(p.dirname(x),"..")' "$(command -v pi)") || fail 'installed Pi path could not be resolved'; PI_CWD="$TMP_ROOT/pi-cwd"; mkdir -p "$PI_CWD"
  pi_stats=$(PI_ROOT="$PI_ROOT" node --input-type=module - "$FULL" "$OPTIONAL" "$PI_CWD" <<'NODE'
import { pathToFileURL } from "node:url";
const [file,optionalFile,cwd]=process.argv.slice(2),root=process.env.PI_ROOT;
const {createAgentSession,SessionManager}=await import(pathToFileURL(`${root}/dist/index.js`).href);
const stats=async (path)=>{const {session}=await createAgentSession({cwd,agentDir:`${cwd}/agent`,sessionManager:SessionManager.open(path,undefined,cwd),noTools:"all"});return session.getSessionStats();};
process.stdout.write(JSON.stringify({full:await stats(file),optional:await stats(optionalFile)}));
NODE
  ) || fail 'Pi 0.83.0 session-stat comparison failed'
  check "$report" '.entry_counts.message==$stats.full.totalMessages and .calls.assistant==$stats.full.assistantMessages and .calls.tool==$stats.full.toolCalls and .calls.tool_result==$stats.full.toolResults and .totals.provider_usage.input==$stats.full.tokens.input and .totals.provider_usage.output==$stats.full.tokens.output and .totals.provider_usage.cache_read==$stats.full.tokens.cacheRead and .totals.provider_usage.cache_write==$stats.full.tokens.cacheWrite and ((.totals.provider_usage.input+.totals.provider_usage.output+.totals.provider_usage.cache_read+.totals.provider_usage.cache_write)==$stats.full.tokens.total) and ((.totals.model_rate_cost_estimate.total-$stats.full.cost)|fabs)<0.0000001' 'parser totals must match installed Pi 0.83.0 session statistics' --argjson stats "$pi_stats"
  check "$optional_report" '.entry_counts.message==$stats.optional.totalMessages and .calls.assistant==$stats.optional.assistantMessages and .calls.tool==$stats.optional.toolCalls and .calls.tool_result==$stats.optional.toolResults and .totals.provider_usage.input==$stats.optional.tokens.input and .totals.provider_usage.output==$stats.optional.tokens.output and .totals.provider_usage.cache_read==$stats.optional.tokens.cacheRead and .totals.provider_usage.cache_write==$stats.optional.tokens.cacheWrite and ((.totals.provider_usage.input+.totals.provider_usage.output+.totals.provider_usage.cache_read+.totals.provider_usage.cache_write)==$stats.optional.tokens.total) and ((.totals.model_rate_cost_estimate.total-$stats.optional.cost)|fabs)<0.0000001' 'optional parser totals must match installed Pi 0.83.0 statistics' --argjson stats "$pi_stats"
  pass 'parser totals match installed Pi 0.83.0 session statistics for full and optional-usage fixtures'
else
  pass 'Pi 0.83.0 comparison skipped because the installed interface is unavailable'
fi
