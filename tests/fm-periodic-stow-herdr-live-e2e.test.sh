#!/usr/bin/env bash
# Opt-in real Pi TUI verification for periodic stow in a guarded non-default
# Herdr lab. The home, session store, plugin install, and project are disposable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${FM_PERIODIC_STOW_HERDR_LIVE:-0}" = 1 ] || {
  echo "skip: set FM_PERIODIC_STOW_HERDR_LIVE=1 for the real Pi/Herdr periodic-stow guard"
  exit 0
}
command -v herdr >/dev/null 2>&1 || fail "herdr is required"
command -v pi >/dev/null 2>&1 || fail "pi is required"

HERDR_LAB_HELPER=/home/chengyuhang/firstmate/bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_HERDR_LAB_TASK:-implement-periodic-stow-20260924}")
TMP_ROOT=$(fm_test_tmproot fm-periodic-stow-herdr)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
CAPTURE="$TMP_ROOT/capture.jsonl"
CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${FM_HEARTBEAT_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_HEARTBEAT_EVIDENCE_DIR"
    cp -R "$HOME_DIR/data" "$HOME_DIR/state" "$PI_DIR/sessions" "$FM_HEARTBEAT_EVIDENCE_DIR/" 2>/dev/null || true
    cp "$CAPTURE" "$FM_HEARTBEAT_EVIDENCE_DIR/capture.jsonl" 2>/dev/null || true
    if [ -d "$PI_DIR/executor-sessions" ]; then
      cp -R "$PI_DIR/executor-sessions" "$FM_HEARTBEAT_EVIDENCE_DIR/" || rc=1
    fi
  fi
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the named non-default Herdr lab"

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" \
  "$PI_DIR/npm/node_modules" "$PI_DIR/sessions" "$PI_DIR/bin"
cp /home/chengyuhang/.pi/agent/bin/fd "$PI_DIR/bin/fd"
cp "$ROOT/.pi/extensions/fm-periodic-stow.ts" "$PROJECT/.pi/extensions/fm-periodic-stow.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$ROOT/.pi/extensions/lib/fm-async-exec.ts" \
  "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$PROJECT/.pi/extensions/lib/"
chmod +x "$PROJECT/bin/fm-stow-run.sh"
printf '%s\n' '# Isolated periodic-stow live fixture' >"$PROJECT/AGENTS.md"
printf '%s\n' '{"version":1,"enabled":true,"interval_seconds":3600,"min_interval_seconds":3600}' \
  >"$HOME_DIR/config/periodic-stow.json"
touch -t 202001010000 "$HOME_DIR/config/periodic-stow.json"

COMPAT_DIR=${FM_PI_CODEX_COMPAT_DIR:-/home/chengyuhang/.pi/agent/npm/node_modules/pi-openai-codex-compat}
[ "$(jq -r '.version' "$COMPAT_DIR/package.json" 2>/dev/null)" = 0.0.16 ] \
  || fail "isolated live guard requires pi-openai-codex-compat 0.0.16"
cp -R "$(dirname "$COMPAT_DIR")/." "$PI_DIR/npm/node_modules/"
printf '%s\n' '{"packages":["npm:pi-openai-codex-compat@0.0.16"],"compaction":{"enabled":false,"reserveTokens":1024,"keepRecentTokens":256}}' >"$PI_DIR/settings.json"

cat >"$CAPTURE_EXT" <<'TS'
import {
  type AssistantMessage,
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { installTaskContinuation } from "./project/.pi/extensions/lib/fm-task-continuation.ts";
const home = process.env.FM_HOME!;
const capture = process.env.FM_PERIODIC_STOW_CAPTURE!;
const log = (value: object) => appendFileSync(capture, `${JSON.stringify({ at: Date.now(), mono: performance.now(), ...value })}\n`);
function assistant(model: { api: string; provider: string; id: string }): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: Date.now(),
  };
}
export default function captureExtension(pi: ExtensionAPI) {
  const continuation = installTaskContinuation(pi, {
    root: process.env.FM_ROOT_OVERRIDE!, home, state: `${home}/state`, owns: () => true,
  });
  pi.registerProvider("periodic-local", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "offline-test-only",
    api: "periodic-local-api",
    models: [{
      id: "deterministic",
      name: "Deterministic periodic-stow provider",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 16384,
      maxTokens: 128,
    }],
    streamSimple(model, context) {
      const last = JSON.stringify(context.messages.at(-1)?.content || "");
      const reason = last.includes("FIRSTMATE HEARTBEAT CHECKLIST") ? "heartbeat"
        : last.includes("Live task continuation obligations") ? "continuation"
        : last.includes("independent fixture B") ? "B" : "seed-or-compaction";
      log({ event: "provider_call", reason, last });
      const stream = createAssistantMessageEventStream();
      const output = assistant(model);
      queueMicrotask(() => {
        const responseText = reason === "B" ? "fixture-B=42" : "periodic-stow lifecycle observed";
        const block = { type: "text" as const, text: responseText };
        output.content.push(block);
        stream.push({ type: "start", partial: output });
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        stream.push({ type: "text_delta", contentIndex: 0, delta: responseText, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: responseText, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      });
      return stream;
    },
  });
  pi.registerCommand("fixture-cold", {
    description: "Exercise a supported session initialization without a leaf",
    async handler(_args, ctx) {
      await ctx.newSession({ setup: async (manager) => { manager.resetLeaf(); } });
    },
  });
  pi.on("input", (event) => { if (event.text.includes("independent fixture B")) log({ event: "B_received" }); });
  pi.on("agent_before_settle", (event) => {
    const record = JSON.parse(readFileSync(`${home}/data/live-prerequisite/lifecycle.json`, "utf8"));
    log({ event: "before_settle", continued: event.continue, disposition: record.disposition,
      receipt: record.coordination?.receipt, receiver: record.coordination?.receiver,
      budgets: record.coordination?.budgets });
  });
  pi.on("agent_settled", () => log({ event: "agent_settled" }));
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", async (_event, ctx) => {
    log({ event: "cold_start_identity", leaf: ctx.sessionManager.getLeafId(), file: ctx.sessionManager.getSessionFile() });
    writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
    mkdirSync(`${home}/data/live-prerequisite`, { recursive: true });
    writeFileSync(`${home}/data/live-prerequisite/brief.md`, "Apply prerequisite and validate the operation.\n");
    await continuation.preserve(["live-prerequisite"]);
    log({ event: "session_start", pid: process.pid, session_id: ctx.sessionManager.getSessionId() });
  });
  pi.on("message_start", (event) => {
    const message = event.message as { role?: string; customType?: string };
    log({ event: "message_start", role: message.role, customType: message.customType });
  });
  pi.on("before_agent_start", () => {
    log({ event: "before_agent_start" });
  });
}
TS

CREATE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$PROJECT" \
  --label periodic-stow-live --no-focus) || fail "could not create isolated live workspace"
PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "workspace create returned no root pane"
# Product backend readers also pass through the same guarded lab helper.
mkdir -p "$TMP_ROOT/guardbin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'FM_FIXTURE_SESSION=%q\nFM_FIXTURE_BASE_PATH=%q\nFM_FIXTURE_HELPER=%q\n' "$HERDR_LAB_SESSION" "$PATH" "$HERDR_LAB_HELPER"
  cat <<'SH'
args=("$@")
# The product's client-version check has no ambient session; scope it here too.
if [ "$#" -eq 2 ] && [ "$1" = status ] && [ "$2" = --json ]; then
  PATH="$FM_FIXTURE_BASE_PATH" exec "$FM_FIXTURE_HELPER" run "$FM_FIXTURE_SESSION" "$@"
fi
[ "${args[${#args[@]}-2]:-}" = --session ] && [ "${args[${#args[@]}-1]:-}" = "$FM_FIXTURE_SESSION" ] || exit 97
unset 'args[${#args[@]}-1]'
unset 'args[${#args[@]}-1]'
PATH="$FM_FIXTURE_BASE_PATH" exec "$FM_FIXTURE_HELPER" run "$FM_FIXTURE_SESSION" "${args[@]}"
SH
} >"$TMP_ROOT/guardbin/herdr"
chmod +x "$TMP_ROOT/guardbin/herdr"
export FM_FIXTURE_BASE_PATH="$PATH" FM_FIXTURE_HELPER="$HERDR_LAB_HELPER" FM_FIXTURE_SESSION="$HERDR_LAB_SESSION"
export FM_FIXTURE_GUARDBIN="$TMP_ROOT/guardbin"
PI_CMD=$(printf 'exec env -u FM_TASK_ID -u FIRSTMATE_OP -u FM_SUPERVISION_ACTOR PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PERIODIC_STOW_CAPTURE=%q FM_PERIODIC_STOW_TICK_MS=200 PATH=%q pi -e %q --model periodic-local/deterministic --no-context-files --session-dir %q' \
  "$PI_DIR" "$HOME_DIR" "$PROJECT" "$CAPTURE" "$FM_FIXTURE_GUARDBIN:$PATH" "$CAPTURE_EXT" "$PI_DIR/sessions")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" zsh >/dev/null \
  || fail "could not start the nested lab shell"
sleep 1
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null \
  || fail "could not launch real Pi TUI"

for _ in $(seq 1 80); do
  STATUS=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  [ "$STATUS" = idle ] && break
  sleep 0.25
done
[ "${STATUS:-}" = idle ] || fail "real Pi did not become idle before the seed message"
for _ in $(seq 1 80); do
  if [ -s "$CAPTURE" ] && jq -s -e 'any(.event == "session_start")' "$CAPTURE" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
[ -s "$CAPTURE" ] || fail "real Pi startup callback did not finish"
# The agent detector can report idle before the TUI finishes mounting.
sleep 2
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" 'seed persisted session entry' >/dev/null
sleep 1
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null

ready=0
for _ in $(seq 1 40); do
  if [ -s "$HOME_DIR/state/stow/state.json" ] && [ -s "$CAPTURE" ] \
    && jq -e '.active.attempts >= 1 and .active.attempts <= 3 and .active.phase == "requested"' "$HOME_DIR/state/stow/state.json" >/dev/null 2>&1 \
    && jq -s -e 'any(.event == "before_agent_start")' "$CAPTURE" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  STATE_DIAG=$(jq -c '.' "$HOME_DIR/state/stow/state.json" 2>/dev/null || echo '<no-state>')
  CAPTURE_DIAG=$(tr '\n' ' ' <"$CAPTURE" 2>/dev/null || echo '<no-capture>')
  AGENT_DIAG=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE" 2>&1 | tr '\n' ' ')
  PANE_DIAG=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent-unwrapped --lines 80 2>&1 | tr '\n' ' ')
  fail "real Pi did not accept a bounded due follow-up: state=$STATE_DIAG capture=$CAPTURE_DIAG agent=$AGENT_DIAG pane=$PANE_DIAG"
fi

# Real Pi must consume the continuation custom entry and keep the goal open
# after its provider returns success. No model text is semantic acceptance.
for _ in $(seq 1 40); do
  if rg -q '"customType":"fm-task-continuation"' "$PI_DIR/sessions" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
rg -q '"customType":"fm-task-continuation"' "$PI_DIR/sessions" >/dev/null \
  || fail "real Pi did not consume the candidate before-settle continuation entry"
jq -e '.disposition == "open" and .next_action == null' "$HOME_DIR/data/live-prerequisite/lifecycle.json" >/dev/null \
  || fail "provider success erased unfinished acceptance"
# While A stays pending, independent input B must be received and answered.
B_SENT=$(date +%s)
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" 'independent fixture B: answer fixture-B=42' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null
for _ in $(seq 1 40); do
  jq -s -e 'any(.event == "provider_call" and .reason == "B")' "$CAPTURE" >/dev/null && break
  sleep 0.25
done
if ! python3 - "$CAPTURE" "$HOME_DIR" "$B_SENT" <<'PYCHECK'
import json,sys,time
from pathlib import Path
capture,home,sent=Path(sys.argv[1]),Path(sys.argv[2]),int(sys.argv[3])*1000
rows=[json.loads(x) for x in capture.read_text().splitlines()]
assert any(r['event']=='B_received' and r['at']-sent<=5000 for r in rows),'B receive bound'
assert any(r['event']=='provider_call' and r.get('reason')=='B' and r['at']-sent<=10000 for r in rows),'B provider bound'
first=next(r['at'] for r in rows if r['event']=='provider_call')
# An unresolved/no-effect A remains pending for the full 95-second window.
while time.time()*1000-first < 95000:
    time.sleep(.25)
rows=[json.loads(x) for x in capture.read_text().splitlines()]
a=[r for r in rows if r['event']=='provider_call' and r.get('reason')=='continuation']
assert len(a)==2,('expected two paced continuation requests',a)
first_budget=next(next(iter(r['budgets'].values())) for r in rows if r['event']=='before_settle' and r.get('budgets') and next(iter(r['budgets'].values()))['attempts']==1)
assert a[1]['at']>=first_budget['not_before_ms'],('unpaced request before canonical not-before',a,first_budget)
r=json.loads((home/'data/live-prerequisite/lifecycle.json').read_text())
assert r['disposition']=='open' and r['next_action'] is None and r['assessment']['remaining_gap']
assert len(r['coordination']['budgets'])==1 and next(iter(r['coordination']['budgets'].values()))['attempts']==2
for event in rows:
    if event['event']=='before_settle' and not event['continued']:
        assert event.get('receipt') and event.get('receiver'),('bare release',event)
        assert event['receiver']['pid']==next(x['pid'] for x in rows if x['event']=='session_start')
stow=json.loads((home/'state/stow/state.json').read_text())
assert 1<=stow['active']['attempts']<=3
heartbeats=[r for r in rows if r['event']=='provider_call' and r.get('reason')=='heartbeat']
assert heartbeats and heartbeats[0]['at']-first<=10000,('heartbeat starved',heartbeats)
print('ok - 95s: two paced A requests, actual coordinator receipts, heartbeat <=10s, independent B responsive')
PYCHECK
then
  fail "95-second no-progress acceptance failed"
fi
# A real runtime reload must retain the canonical task budget.
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/reload' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null
sleep 2
for _ in $(seq 1 80); do
  STATUS=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$STATUS" != idle ] || break
  sleep 0.25
done
sleep 1
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/compact' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null
for _ in $(seq 1 60); do
  if rg -q '"type":"compaction"' "$PI_DIR/sessions"; then break; fi
  sleep 0.25
done
if ! rg -q '"type":"compaction"' "$PI_DIR/sessions"; then
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent-unwrapped --lines 60
  cat "$CAPTURE"
  fail "real Pi did not persist compaction"
fi
jq -e '.disposition == "open"' "$HOME_DIR/data/live-prerequisite/lifecycle.json" >/dev/null \
  || fail "compaction erased pending continuation"

COUNT=$(jq -s '[.[] | select(.event == "provider_call" and .reason == "continuation")] | length' "$CAPTURE")
[ "$COUNT" -eq 2 ] || fail "reload/compaction reset the canonical continuation budget: $COUNT"
RUN_ID=$(jq -r '.active.run_id' "$HOME_DIR/state/stow/state.json")
[ -n "$RUN_ID" ] && [ "$RUN_ID" != null ] || fail "real Pi run has no stable run_id"
jq -s -e 'any(.event == "session_start") and any(.event == "before_agent_start")' "$CAPTURE" >/dev/null \
  || fail "real Pi lifecycle evidence is incomplete"

python3 "$ROOT/tests/continuation-host-matrix.py" "$PROJECT" "$HOME_DIR" "$PI_DIR" "$CAPTURE" "$HERDR_LAB_HELPER" "$HERDR_LAB_SESSION" \
  || fail "real Pi additional continuation matrix failed"

# Supported new-session setup leaves no current leaf. The first real prompt
# must activate the same coordinator while retaining the existing task budget.
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/fixture-cold' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null
for _ in $(seq 1 40); do
  if jq -s -e 'any(.event == "cold_start_identity" and (.leaf == null))' "$CAPTURE" >/dev/null; then break; fi
  sleep 0.25
done
jq -s -e 'any(.event == "cold_start_identity" and (.leaf == null))' "$CAPTURE" >/dev/null \
  || fail "supported cold-session fixture did not start without a leaf"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" 'cold-start fixture input' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null
if ! python3 - "$CAPTURE" "$HOME_DIR/data/live-prerequisite/lifecycle.json" <<'PYCOLD'
import json,sys,time
from pathlib import Path
capture,record=map(Path,sys.argv[1:])
rows=[json.loads(x) for x in capture.read_text().splitlines()]
start=[x for x in rows if x['event']=='session_start'][-1]
limit=time.monotonic()+30
while time.monotonic()<limit:
    r=json.loads(record.read_text())
    if r.get('coordination',{}).get('receiver',{}).get('session_id')==start['session_id']:
        assert r['disposition']=='open' and r['next_action'] is None
        assert len(r['coordination']['budgets'])==1
        assert next(iter(r['coordination']['budgets'].values()))['attempts']==2
        print('ok - actual Pi cold session without leaf acquired coordinator after the first persisted boundary; A budget unchanged')
        break
    time.sleep(.2)
else:
    raise AssertionError('cold session did not reacquire actual continuation readback')
PYCOLD
then
  fail "real Pi cold-session recovery failed"
fi

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/quit' >/dev/null || true
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null || true
echo "ok - real Pi $(pi --version 2>/dev/null | head -1) with pi-openai-codex-compat 0.0.16 accepted heartbeat and retained live continuation through provider success and compaction"
