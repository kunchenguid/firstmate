#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

if [ "${FM_CONTEXT_HANDOFF_PI_LIVE_E2E:-0}" != 1 ]; then
  printf 'skip: set FM_CONTEXT_HANDOFF_PI_LIVE_E2E=1 to run the installed Pi handoff guard\n'
  exit 0
fi

command -v pi >/dev/null 2>&1 || fail "installed Pi handoff guard requires pi"
command -v jq >/dev/null 2>&1 || fail "installed Pi handoff guard requires jq"

fixture=$(fm_test_tmproot fm-context-handoff-pi-live)
agent_dir="$fixture/pi-home"
session_dir="$fixture/sessions"
session_file="$session_dir/session.jsonl"
extension="$fixture/offline-compaction.ts"
event_log="$fixture/events"
rpc_log="$fixture/rpc.jsonl"
mkdir -p "$agent_dir" "$session_dir"
printf '%s\n' '{"compaction":{"keepRecentTokens":1}}' > "$agent_dir/settings.json"
old_text=$(printf 'old %.0s' {1..5000})
printf '%s\n' \
  '{"type":"session","version":3,"id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-08-30T20:00:00.000Z","cwd":"'"$fixture"'"}' \
  '{"type":"message","id":"old","parentId":null,"timestamp":"2026-08-30T20:00:00.000Z","message":{"role":"user","content":"'"$old_text"'","timestamp":1788120000000}}' \
  '{"type":"message","id":"recent","parentId":"old","timestamp":"2026-08-30T20:00:01.000Z","message":{"role":"user","content":"recent","timestamp":1788120001000}}' > "$session_file"
cat > "$extension" <<'EOF'
import fs from "node:fs";

export default function (pi) {
  let finishCompaction;
  const compactionFinished = new Promise((resolve) => {
    finishCompaction = resolve;
  });
  pi.registerProvider("fm-synthetic", {
    baseUrl: "http://127.0.0.1:1/v1",
    apiKey: "synthetic",
    api: "openai-completions",
    models: [{
      id: "offline",
      name: "Offline synthetic",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    }],
  });
  pi.on("session_before_compact", async (event) => {
    fs.appendFileSync(process.env.FM_PI_EVENT_LOG, `extension:${event.type}:${event.reason}\n`);
    return {
      compaction: {
        summary: "synthetic offline compaction",
        firstKeptEntryId: event.preparation.firstKeptEntryId,
        tokensBefore: event.preparation.tokensBefore,
      },
    };
  });
  pi.on("session_compact", async (event) => {
    const entries = fs.readFileSync(process.env.FM_PI_SESSION_FILE, "utf8").trim().split("\n").map(JSON.parse);
    const persisted = entries.some((entry) => entry.type === "compaction" && entry.id === event.compactionEntry.id);
    fs.appendFileSync(process.env.FM_PI_EVENT_LOG, `extension:${event.type}:persisted=${persisted}\n`);
    finishCompaction();
  });
  pi.on("session_compact_failed", async (event) => {
    fs.appendFileSync(process.env.FM_PI_EVENT_LOG, `extension:${event.type}:${event.reason}\n`);
    finishCompaction();
  });
  pi.registerCommand("fm-context-handoff-live", {
    description: "Run a synthetic offline compaction",
    handler: async (_args, ctx) => {
      ctx.compact();
      await compactionFinished;
      ctx.shutdown();
    },
  });
}
EOF

printf '%s\n' '{"id":"compact","type":"prompt","message":"/fm-context-handoff-live"}' | \
  env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u GEMINI_API_KEY \
    PI_CODING_AGENT_DIR="$agent_dir" PI_OFFLINE=1 FM_PI_EVENT_LOG="$event_log" FM_PI_SESSION_FILE="$session_file" \
    pi --approve --mode rpc --offline --provider fm-synthetic --model offline --api-key synthetic \
      --no-tools --no-context-files --no-extensions --no-skills --no-prompt-templates --no-themes \
      --session-dir "$session_dir" --session "$session_file" -e "$extension" > "$rpc_log" || \
  fail "installed Pi executable offline compaction failed"

if [ "$(sed -n '1p' "$event_log" 2>/dev/null)" != 'extension:session_before_compact:manual' ]; then
  sed -n '1,40p' "$rpc_log" >&2
  fail "installed Pi executable did not invoke the synthetic compaction extension"
fi
[ "$(sed -n '2p' "$event_log")" = 'extension:session_compact:persisted=true' ] || fail "installed Pi executable reported success before durable persistence"
jq -se 'any(.type == "response" and .id == "compact" and .success == true) and any(.type == "compaction_end" and .reason == "manual" and .aborted == false)' "$rpc_log" >/dev/null || fail "installed Pi executable did not complete its public compaction lifecycle"
printf '%s\n' 'extension:session_before_compact:manual' 'extension:session_compact:persisted=true'
pass "installed Pi executable offline persistence-before-success"
