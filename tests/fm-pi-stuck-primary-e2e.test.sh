#!/usr/bin/env bash
# Integration tests for Pi stuck-primary recovery fallback through tracked extensions.
# Primary dispatch-and-return contract lives in fm-pi-dispatch-return-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib/pi-primary-extension-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pi-primary-extension-fixture.sh"

export NODE_NO_WARNINGS=1
export FM_PI_STUCK_AFTER_ARM_MS=200
export FM_PI_STUCK_POLL_MS=50
export FM_PI_ARM_READY_TIMEOUT_MS=2000
TMP_ROOT=$(fm_test_tmproot fm-pi-stuck-primary-e2e)

command -v node >/dev/null 2>&1 || {
  echo "skip: node not found for Pi stuck-primary integration tests"
  exit 0
}

COMMON_NODE_HEADER=$(cat <<'NODE'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
if (process.env.FM_PI_STUCK_AFTER_ARM_MS !== "200") {
  throw new Error(`FM_PI_STUCK_AFTER_ARM_MS=${process.env.FM_PI_STUCK_AFTER_ARM_MS ?? ""}`);
}

const handlers = new Map();
let toolExecute = null;
let aborted = false;
let idle = false;
let pending = true;
const deliveries = [];

const ctx = {
  isIdle: () => idle,
  hasPendingMessages: () => pending,
  abort: () => {
    aborted = true;
  },
  sessionManager: {
    getSessionId: () => process.env.CASE_ID ?? "stuck-e2e",
  },
  ui: {
    notify() {},
  },
};

const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  events: { on() {} },
  registerCommand() {},
  registerTool(definition) {
    if (definition.name === "fm_watch_arm_pi") toolExecute = definition.execute;
  },
  sendMessage() {},
  async sendUserMessage(message, options) {
    deliveries.push({ message, options });
  },
};

const turnend = await import(pathToFileURL(process.env.TURNEND_EXT).href);
const watch = await import(pathToFileURL(process.env.WATCH_EXT).href);
turnend.default(pi);
watch.default(pi);

if (!toolExecute) throw new Error("fm_watch_arm_pi tool was not registered");

const agentStart = handlers.get("agent_start");
const agentSettled = handlers.get("agent_settled");
if (!agentStart || !agentSettled) throw new Error("turnend extension missing agent lifecycle handlers");

await agentStart({ type: "agent_start" }, ctx);
if (process.env.CASE_IDLE === "1") idle = true;
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.dispatch-return`, `1\tstuck-e2e\n`);
const armResult = await toolExecute({}, ctx);
if (!armResult.content?.[0]?.text?.includes("started Pi extension arm child")) {
  throw new Error(`unexpected arm result: ${JSON.stringify(armResult)}`);
}
if (armResult.terminate !== true) {
  throw new Error(`successful arm must terminate the turn; got ${JSON.stringify(armResult.terminate)}`);
}
if (process.env.CASE_PROGRESS === "1") {
  for (let i = 0; i < 30; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    handlers.get("message_update")?.({ type: "message_update" });
  }
} else {
  for (let i = 0; i < 10; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
NODE
)

test_busy_stall_does_not_abort_turn() {
  local repo home
  repo="$TMP_ROOT/busy-root"
  home="$TMP_ROOT/busy-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_fleet_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "busy stall must not abort the live turn" \
    "${COMMON_NODE_HEADER}
idle = false;
for (let i = 0; i < 20; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (aborted) {
  throw new Error('busy stall must not call ctx.abort()');
}
if (deliveries.length > 0) {
  throw new Error('busy stall must not deliver recovery while the run is not idle');
}
"
  pass "Pi stuck-primary: busy stall does not abort the live turn"
}

test_idle_stall_triggers_turn_without_abort() {
  local repo home
  repo="$TMP_ROOT/idle-root"
  home="$TMP_ROOT/idle-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_fleet_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "idle stall must triggerTurn without abort" \
    "${COMMON_NODE_HEADER}
for (let i = 0; i < 20 && deliveries.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (aborted) throw new Error('idle stall should not abort');
const recovery = deliveries.find((item) => item.message.includes('STUCK-PRIMARY RECOVERY'));
if (!recovery) throw new Error('idle stall never delivered recovery follow-up');
if (recovery.options?.triggerTurn !== true) throw new Error('idle recovery missing triggerTurn');
" 1 0
  pass "Pi stuck-primary: idle stall triggers recovery turn without abort"
}

test_progress_suppresses_recovery_until_stall_returns() {
  local repo home
  repo="$TMP_ROOT/progress-root"
  home="$TMP_ROOT/progress-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_fleet_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "bash tool progress must suppress recovery until the stall window returns" \
    "
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

writeFileSync(\`\${process.env.FM_STATE_OVERRIDE}/.lock\`, \`\${process.pid}\\n\`);
const handlers = new Map();
let aborted = false;
let idle = false;
const deliveries = [];
const ctx = {
  isIdle: () => idle,
  hasPendingMessages: () => true,
  abort: () => { aborted = true; },
  sessionManager: { getSessionId: () => 'stuck-e2e' },
  ui: { notify() {} },
};
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  events: { on() {} },
  registerCommand() {},
  registerTool(definition) {
    if (definition.name === 'fm_watch_arm_pi') toolExecute = definition.execute;
  },
  sendMessage() {},
  async sendUserMessage(message, options) { deliveries.push({ message, options }); },
};
let toolExecute = null;
const turnend = await import(pathToFileURL(process.env.TURNEND_EXT).href);
const watch = await import(pathToFileURL(process.env.WATCH_EXT).href);
turnend.default(pi);
watch.default(pi);
writeFileSync(\`\${process.env.FM_STATE_OVERRIDE}/.dispatch-return\`, '1\\tstuck-e2e\\n');
await handlers.get('agent_start')({ type: 'agent_start' }, ctx);
await toolExecute({}, ctx);
const toolCall = handlers.get('tool_call');
if (!toolCall) throw new Error('turnend extension missing tool_call handler');
await toolCall({
  type: 'tool_call',
  toolName: 'bash',
  toolCallId: 'bash-progress',
  input: { command: 'echo progress' },
}, ctx);
for (let i = 0; i < 2 && !aborted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
if (aborted || deliveries.length > 0) {
  throw new Error('recent bash progress should suppress recovery');
}
for (let i = 0; i < 20 && !aborted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (aborted) throw new Error('recovery must not abort after progress stops while busy');
if (deliveries.length > 0) throw new Error('recovery must not trigger while the run is still busy');
"
  pass "Pi stuck-primary: bash progress resets the stall clock before recovery fires"
}

test_message_update_does_not_reset_stall_clock() {
  local repo home
  repo="$TMP_ROOT/message-update-root"
  home="$TMP_ROOT/message-update-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_fleet_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "message_update must not reset the stuck-primary stall clock" \
    "${COMMON_NODE_HEADER}
idle = true;
for (let i = 0; i < 30; i += 1) {
  handlers.get('message_update')?.({ type: 'message_update' });
  await new Promise((resolve) => setTimeout(resolve, 50));
}
for (let i = 0; i < 20 && deliveries.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (aborted) throw new Error('message_update noise must not abort the turn');
const recovery = deliveries.find((item) => item.message.includes('STUCK-PRIMARY RECOVERY'));
if (!recovery) throw new Error('idle recovery must still fire after message_update noise');
if (recovery.options?.triggerTurn !== true) throw new Error('idle recovery missing triggerTurn');
" 0 1
  pass "Pi stuck-primary: message_update does not reset the stall clock"
}

test_incomplete_cursor_replay_blocks_tool_without_aborting_turn() {
  local repo home
  repo="$TMP_ROOT/cursor-incomplete-root"
  home="$TMP_ROOT/cursor-incomplete-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_fleet_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "incomplete cursor-replay must complete the tool without ctx.abort" \
    "
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

writeFileSync(\`\${process.env.FM_STATE_OVERRIDE}/.lock\`, \`\${process.pid}\\n\`);
const handlers = new Map();
let aborted = false;
const ctx = {
  isIdle: () => false,
  hasPendingMessages: () => false,
  abort: () => { aborted = true; },
  sessionManager: { getSessionId: () => 'stuck-e2e' },
  ui: { notify() {} },
};
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  events: { on() {} },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
  async sendUserMessage() {},
};
const turnend = await import(pathToFileURL(process.env.TURNEND_EXT).href);
turnend.default(pi);
await handlers.get('agent_start')({ type: 'agent_start' }, ctx);
const blocked = await handlers.get('tool_call')({
  type: 'tool_call',
  toolName: 'cursor',
  toolCallId: 'cursor-replay-shell-incomplete',
  input: { activityTitle: 'Cursor shell', incomplete: true },
}, ctx);
if (blocked?.block !== true) throw new Error('incomplete cursor-replay must block as a failed tool result');
if (!String(blocked.reason || '').includes('did not complete')) {
  throw new Error('incomplete cursor-replay block reason must name the missing completion');
}
if (aborted) throw new Error('incomplete cursor-replay must not abort the whole turn');
"
  pass "Pi stuck-primary: incomplete cursor-replay completes the tool without aborting the turn"
}

test_busy_stall_does_not_abort_turn
test_idle_stall_triggers_turn_without_abort
test_progress_suppresses_recovery_until_stall_returns
test_message_update_does_not_reset_stall_clock
test_incomplete_cursor_replay_blocks_tool_without_aborting_turn
