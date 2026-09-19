#!/usr/bin/env bash
# Integration tests for Pi dispatch-and-return behavior.
#
# Models Pi's post-tool turn contract: successful fm_watch_arm_pi must return
# terminate: true so Pi skips the post-arm LLM pass and the captain is not left
# in a false-busy Working state. Upstream lacks terminate; these tests guard the
# fork fix and document the behavioral delta.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib/pi-primary-extension-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pi-primary-extension-fixture.sh"

export NODE_NO_WARNINGS=1
export FM_PI_ARM_READY_TIMEOUT_MS=2000
TMP_ROOT=$(fm_test_tmproot fm-pi-dispatch-return-e2e)

command -v node >/dev/null 2>&1 || {
  echo "skip: node not found for Pi dispatch-return integration tests"
  exit 0
}

MOCK_PI_HOST=$(cat <<'NODE'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);

const handlers = new Map();
let toolExecute = null;
let idle = true;
let pending = false;
const deliveries = [];

const ctx = {
  isIdle: () => idle,
  hasPendingMessages: () => pending,
  abort: () => {},
  sessionManager: {
    getSessionId: () => process.env.CASE_ID ?? "dispatch-return-e2e",
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
const { encodeFirstmateOperationalInput } = await import(
  pathToFileURL(process.env.TURNEND_EXT.replace("fm-primary-turnend-guard.ts", "lib/fm-operational-input.ts")).href,
);
turnend.default(pi);
watch.default(pi);

if (!toolExecute) throw new Error("fm_watch_arm_pi tool was not registered");

const agentStart = handlers.get("agent_start");
const agentSettled = handlers.get("agent_settled");
if (!agentStart || !agentSettled) throw new Error("turnend extension missing agent lifecycle handlers");

async function simulatePiTurnAfterArm(armResult) {
  let postArmModelPasses = 0;
  let settled = false;

  idle = false;
  await agentStart({ type: "agent_start" }, ctx);

  const result = armResult ?? (await toolExecute({}, ctx));
  if (!result.terminate) {
    postArmModelPasses += 1;
  }

  idle = true;
  settled = true;
  await agentSettled({ type: "agent_settled" }, ctx);

  return { postArmModelPasses, settled, result, deliveries };
}
NODE
)

test_fork_arm_terminates_turn() {
  local repo home
  repo="$TMP_ROOT/terminate-root"
  home="$TMP_ROOT/terminate-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "successful arm must return terminate: true" \
    "$MOCK_PI_HOST
writeFileSync(\`\${process.env.FM_STATE_OVERRIDE}/.dispatch-return\`, '1\\tsmoke\\n');
const { postArmModelPasses, result } = await simulatePiTurnAfterArm();
if (result.terminate !== true) {
  throw new Error(\`expected terminate true, got \${JSON.stringify(result.terminate)}\`);
}
if (postArmModelPasses !== 0) {
  throw new Error(\`terminate must skip post-arm model pass; got \${postArmModelPasses}\`);
}
"
  pass "Pi dispatch-return: successful arm returns terminate and skips post-arm model pass"
}

test_idle_arm_does_not_terminate_turn() {
  local repo home
  repo="$TMP_ROOT/idle-root"
  home="$TMP_ROOT/idle-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "idle arm must not terminate when no dispatch marker or live workers exist" \
    "$MOCK_PI_HOST
const { postArmModelPasses, result } = await simulatePiTurnAfterArm();
if (result.terminate !== false) {
  throw new Error(\`expected terminate false on idle arm, got \${JSON.stringify(result.terminate)}\`);
}
if (postArmModelPasses !== 1) {
  throw new Error(\`idle arm must allow one post-arm model pass; got \${postArmModelPasses}\`);
}
"
  pass "Pi dispatch-return: idle arm does not terminate the turn"
}

test_stale_dispatch_marker_does_not_terminate_turn() {
  local repo home
  repo="$TMP_ROOT/stale-root"
  home="$TMP_ROOT/stale-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "stale dispatch marker must not terminate the turn" \
    "$MOCK_PI_HOST
writeFileSync(\`\${process.env.FM_STATE_OVERRIDE}/.dispatch-return\`, '99\\tstale\\n');
const { postArmModelPasses, result } = await simulatePiTurnAfterArm();
if (result.terminate !== false) {
  throw new Error(\`expected terminate false for stale marker, got \${JSON.stringify(result.terminate)}\`);
}
if (postArmModelPasses !== 1) {
  throw new Error(\`stale marker must allow one post-arm model pass; got \${postArmModelPasses}\`);
}
"
  pass "Pi dispatch-return: stale dispatch marker does not terminate the turn"
}

test_live_workers_without_marker_do_not_terminate_turn() {
  local repo home
  repo="$TMP_ROOT/live-workers-root"
  home="$TMP_ROOT/live-workers-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  cat > "$repo/bin/fm-fleet-live-count.sh" <<'SH'
#!/usr/bin/env bash
printf '1\n'
SH
  chmod +x "$repo/bin/fm-fleet-live-count.sh"
  run_pi_extension_node_case "$home" "$repo" \
    "live workers without a dispatch marker must not terminate the turn" \
    "$MOCK_PI_HOST
const { postArmModelPasses, result } = await simulatePiTurnAfterArm();
if (result.terminate !== false) {
  throw new Error(\`expected terminate false when workers are live without a marker, got \${JSON.stringify(result.terminate)}\`);
}
if (postArmModelPasses !== 1) {
  throw new Error(\`live workers without a marker must allow one post-arm model pass; got \${postArmModelPasses}\`);
}
"
  pass "Pi dispatch-return: live workers without a marker do not terminate the turn"
}

test_upstream_shape_without_terminate_would_continue() {
  local repo home
  repo="$TMP_ROOT/upstream-root"
  home="$TMP_ROOT/upstream-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "upstream-shaped arm result without terminate would schedule another model pass" \
    "$MOCK_PI_HOST
const upstreamShaped = {
  content: [{ type: 'text', text: 'watcher: started Pi extension arm child 1' }],
  details: { ok: true },
};
const { postArmModelPasses } = await simulatePiTurnAfterArm(upstreamShaped);
if (postArmModelPasses !== 1) {
  throw new Error(\`upstream-shaped result must model one post-arm model pass; got \${postArmModelPasses}\`);
}
"
  pass "Pi dispatch-return: upstream-shaped arm result models false-busy post-arm continuation"
}

test_clean_dispatch_settle_skips_stuck_recovery() {
  local repo home
  repo="$TMP_ROOT/clean-root"
  home="$TMP_ROOT/clean-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "clean dispatch settle must not emit stuck-primary recovery" \
    "$MOCK_PI_HOST
process.env.FM_PI_STUCK_AFTER_ARM_MS = '200';
process.env.FM_PI_STUCK_POLL_MS = '50';
await simulatePiTurnAfterArm();
for (let i = 0; i < 20; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
const recovery = deliveries.find((item) => item.message.includes('STUCK-PRIMARY RECOVERY'));
if (recovery) {
  throw new Error(\`unexpected stuck recovery on clean settle: \${recovery.message}\`);
}
"
  pass "Pi dispatch-return: clean settle does not trigger stuck-primary recovery"
}

test_dispatch_return_then_watcher_wake_delivers() {
  local repo home
  repo="$TMP_ROOT/wake-root"
  home="$TMP_ROOT/wake-home"
  install_pi_primary_extension_fixture "$repo"
  prepare_pi_extension_idle_state "$home"
  run_pi_extension_node_case "$home" "$repo" \
    "settled primary can receive watcher followUp after dispatch return" \
    "$MOCK_PI_HOST
const { result } = await simulatePiTurnAfterArm({
  content: [{ type: 'text', text: 'watcher: started Pi extension arm child 1' }],
  details: { ok: true },
  terminate: true,
});

const wakeBody = 'FIRSTMATE WATCHER WAKE: signal: done: smoke ok';
const wake = encodeFirstmateOperationalInput(
  'watcher',
  \`\${wakeBody}\\n\\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.\`,
);
await pi.sendUserMessage(wake, { deliverAs: 'followUp' });

const delivered = deliveries.find((item) => item.message.includes('FIRSTMATE WATCHER WAKE'));
if (!delivered) throw new Error('watcher followUp was not delivered after settlement');
if (delivered.options?.deliverAs !== 'followUp') {
  throw new Error('watcher wake must use followUp delivery');
}
"
  pass "Pi dispatch-return: watcher followUp delivers after turn settlement"
}

test_fork_arm_terminates_turn
test_idle_arm_does_not_terminate_turn
test_stale_dispatch_marker_does_not_terminate_turn
test_live_workers_without_marker_do_not_terminate_turn
test_upstream_shape_without_terminate_would_continue
test_clean_dispatch_settle_skips_stuck_recovery
test_dispatch_return_then_watcher_wake_delivers
