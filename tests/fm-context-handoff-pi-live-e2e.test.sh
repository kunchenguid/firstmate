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
command -v node >/dev/null 2>&1 || fail "installed Pi handoff guard requires node"

pi_entry=$(realpath "$(command -v pi)")
pi_root=$(dirname "$(dirname "$(dirname "$pi_entry")")")
[ -f "$pi_root/dist/index.js" ] || fail "installed Pi public package entry is unavailable"

output=$(PI_ROOT="$pi_root" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";

const { AgentSession } = await import(pathToFileURL(`${process.env.PI_ROOT}/dist/index.js`));
const events = [];
let persisted = false;
let entries = [];
const entry = (id, parentId, text) => ({
  type: "message",
  id,
  parentId,
  timestamp: "2026-08-30T20:00:00.000Z",
  message: { role: "user", content: text, timestamp: 1788120000000 },
});
const branch = [entry("old", null, "old ".repeat(5000)), entry("recent", "old", "recent")];
const runner = {
  hasHandlers: () => true,
  async emit(event) {
    if (event.type === "session_before_compact") {
      events.push(`extension:${event.type}:${event.reason}`);
      return { compaction: { summary: "synthetic", firstKeptEntryId: "recent", tokensBefore: 5001 } };
    }
    if (event.type === "session_compact") {
      events.push(`extension:${event.type}:persisted=${persisted}`);
    }
  },
};
const probe = {
  abort: async () => {},
  model: { provider: "synthetic" },
  settingsManager: { getCompactionSettings: () => ({ keepRecentTokens: 1 }) },
  sessionManager: {
    getBranch: () => branch,
    appendCompaction(summary, firstKeptEntryId, tokensBefore) {
      persisted = true;
      events.push("persistence:appendCompaction");
      entries = [{ type: "compaction", summary, firstKeptEntryId, tokensBefore }];
    },
    getEntries: () => entries,
    buildSessionContext: () => ({ messages: [] }),
  },
  agent: { state: { messages: [] } },
  _extensionRunner: runner,
  _getSummarizationRequestAuth: async model => ({ model, apiKey: undefined, headers: undefined, env: undefined }),
  _runDefaultCompaction: async () => { throw new Error("synthetic extension compaction called a model"); },
  _emit: event => events.push(`public:${event.type}:${event.reason}:aborted=${event.aborted ?? "unset"}`),
};
await AgentSession.prototype.compact.call(probe);
console.log(events.join("\n"));
EOF
) || fail "installed Pi public compaction guard failed"

expected=$(printf '%s\n' \
  'public:compaction_start:manual:aborted=unset' \
  'extension:session_before_compact:manual' \
  'persistence:appendCompaction' \
  'extension:session_compact:persisted=true' \
  'public:compaction_end:manual:aborted=false')
[ "$output" = "$expected" ] || fail "installed Pi success event preceded durable compaction persistence"
printf '%s\n' "$output"
pass "installed Pi public persistence-before-success order"
