#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-pi-watch-extension
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"

stage_opencode_module() {
  local source=$1 target=$2
  cp "$source" "$target" || fail "could not stage OpenCode plugin module: $source"
}

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_pi_extension_runtime_configuration_contract() {
  local repo home config_dir plugin arm_log out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi runtime configuration check"; return; }
  repo="$TMP_ROOT/pi-runtime-contract-root"
  home="$TMP_ROOT/pi-runtime-contract-home"
  config_dir="$TMP_ROOT/pi-runtime-contract-config"
  arm_log="$TMP_ROOT/pi-runtime-contract-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$config_dir"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'export FM_POLL=17\n' > "$config_dir/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'config=%s script=%s poll=%s args=%s\n' \
  "$FM_CONFIG_OVERRIDE" "$FM_WATCH_ARM_SCRIPT" "${FM_POLL:-}" "$*" > "$FM_ARM_LOG"
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
exec sleep 600
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning \
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CONFIG_OVERRIDE="$config_dir" \
    FM_ARM_LOG="$arm_log" FM_CHILD_PID_FILE="$TMP_ROOT/pi-runtime-contract-child.pid" \
    node --input-type=module 2>&1 <<'EOF'
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool;
const ctx = {
  isIdle: () => true,
  sessionManager: { getBranch: () => [] },
  ui: { notify() {} },
};
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  appendEntry() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage() {},
};
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
async function waitFor(predicate, label) {
  for (let i = 0; i < 100; i += 1) {
    if (predicate()) return;
    await sleep(20);
  }
  throw new Error(`timed out waiting for ${label}`);
}
function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, "1\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
const refused = await tool.execute("arm-without-lock", {}, undefined, undefined, ctx);
if (refused.details?.ok !== false || !refused.content?.[0]?.text.includes("read-only")) {
  throw new Error(`arm did not refuse another session lock: ${JSON.stringify(refused)}`);
}
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("arm child started without session lock ownership");

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
const started = await tool.execute("arm-owned", {}, undefined, undefined, ctx);
if (started.details?.ok !== true || !started.content?.[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`owned arm did not start: ${JSON.stringify(started)}`);
}
await waitFor(() => existsSync(process.env.FM_ARM_LOG), "effective arm configuration");
const expectedArm = `config=${process.env.FM_CONFIG_OVERRIDE} script=${process.env.FM_ROOT_OVERRIDE}/bin/fm-watch-arm.sh poll=17 args=--restart`;
const armLog = readFileSync(process.env.FM_ARM_LOG, "utf8").trim();
if (armLog !== expectedArm) throw new Error(`unexpected effective arm configuration: ${armLog}`);

const marker = readFileSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`, "utf8").trim().split("\n");
const expectedVersion = `sha256:${createHash("sha256").update(readFileSync(process.env.PLUGIN)).digest("hex")}`;
if (marker[0] !== expectedVersion || marker[1] !== String(process.pid)) {
  throw new Error(`loaded marker did not bind extension content and process: ${JSON.stringify(marker)}`);
}
const childPid = Number(readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim());
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
await waitFor(() => !alive(childPid), "session shutdown cleanup");
EOF
)
  status=$?
  [ "$status" -eq 0 ] || printf '%s\n' "$out" >&2
  expect_code 0 "$status" "Pi extension runtime must enforce lock, config, marker, arm, and cleanup contracts"
  [ -z "$out" ] || fail "Pi runtime configuration test printed output: $out"
  pass "Pi extension enforces its runtime lock, config, marker, arm, and cleanup contracts"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "-e __PITURNEND__ -e __PIWATCH__" "Pi secondmate launch template does not include both primary extensions"
  assert_contains "$text" "\$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts" "fm-spawn does not point the Pi secondmate watch placeholder at the tracked extension"
  assert_not_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn should no longer generate the Pi watch extension before launch"
  assert_contains "$text" "__PITURNEND__" "fm-spawn does not replace the Pi turn-end guard extension placeholder"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes both tracked primary extensions"
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi external-healthy watcher check"; return; }
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
let promptType = "";
let promptOptions = null;
const pi = {
  on() {},
  appendEntry() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendMessage(message, options) {
    prompt = message.content;
    promptType = message.customType;
    promptOptions = options;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 50 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (promptType !== "firstmate-watcher-wake") {
  console.error(`wake was not a custom watcher message: ${promptType}`);
  process.exit(1);
}
if (promptOptions?.deliverAs !== "followUp" || promptOptions?.triggerTurn !== true) {
  console.error(`unexpected custom wake delivery: ${JSON.stringify(promptOptions)}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi tool-result check"; return; }
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  appendEntry() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage() {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool returns text content and structured details"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi exit-listener lifecycle check"; return; }
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  appendEntry() {},
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before) {
  throw new Error("session_shutdown did not remove the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must install once and unregister on session shutdown"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener has a bounded lifecycle"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi exit-cleanup arm-child check"; return; }
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "cleaned\n" > "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  appendEntry() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage() {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 50 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  i=0
  while [ "$i" -lt 50 ] && [ ! -f "$cleanup_log" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -f "$cleanup_log" ] || fail "Pi process-exit fallback did not deliver TERM to the arm child"
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_pi_durable_cycle_retries_delivery_and_rearms() {
  local repo home plugin out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi durable-cycle check"; return; }
  repo="$TMP_ROOT/pi-durable-cycle-root"
  home="$TMP_ROOT/pi-durable-cycle-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FM_HOME/state/.fixture-arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$$" > "$FM_HOME/state/.fixture-arm-$count.pid"
printf 'launch=%s pid=%s\n' "$count" "$$" > "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
case "$count" in
  1|2)
    while [ ! -e "$FM_HOME/state/.fixture-fire-$count" ]; do sleep 0.01; done
    printf '%s\t%s\tsignal\tfixture-%s\tsignal: durable wake %s\n' \
      "$(date +%s)" "$count" "$count" "$count" >> "$FM_HOME/state/.wake-queue"
    printf 'signal: durable wake %s\n' "$count"
    ;;
  *) exec sleep 600 ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning \
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_PI_WAKE_RETRY_BASE_MS=10 FM_PI_WAKE_RETRY_MAX_MS=20 \
    FM_PI_ARM_RESTART_BASE_MS=10 FM_PI_ARM_RESTART_MAX_MS=20 \
    node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const branch = [];
let tool;
let idle = true;
let sendAttempts = 0;
let admissions = 0;
let triggeredTurns = 0;
const deliveryAttempts = [];
const admittedMessages = [];
const ctx = {
  sessionManager: { getBranch: () => branch },
  isIdle: () => idle,
  ui: { notify() {} },
};
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  appendEntry() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage(message, options) {
    sendAttempts += 1;
    deliveryAttempts.push({
      deliveryId: message.details?.deliveryId,
      attempt: message.details?.attempt,
    });
    if (message.customType !== "firstmate-watcher-wake" || message.display !== true) {
      throw new Error(`wake was not a visible custom message: ${JSON.stringify(message)}`);
    }
    if (options?.deliverAs !== "followUp" || options?.triggerTurn !== true) {
      throw new Error(`wake did not use triggering follow-up delivery: ${JSON.stringify(options)}`);
    }
    if (sendAttempts === 1) {
      setTimeout(() => void admitMessage(message), 80);
      return; // Reproduce asynchronous admission after the old retry timer would have fired.
    }
    if (sendAttempts === 2) {
      idle = false;
      return; // Reproduce a handoff that reaches settlement without observable admission.
    }
    queueMicrotask(() => void admitMessage(message));
  },
};
async function admitMessage(message) {
  idle = false;
  triggeredTurns += 1;
  await handlers.get("agent_start")?.({ type: "agent_start" }, ctx);
  const customMessage = { role: "custom", ...message, timestamp: Date.now() };
  await handlers.get("message_end")?.({ type: "message_end", message: customMessage }, ctx);
  branch.push({
    type: "custom_message",
    id: `wake-${admissions + 1}`,
    parentId: branch.at(-1)?.id ?? null,
    timestamp: new Date().toISOString(),
    customType: message.customType,
    content: message.content,
    display: message.display,
    details: message.details,
  });
  admittedMessages.push(customMessage);
  admissions += 1;
  idle = true;
  await handlers.get("agent_settled")?.({ type: "agent_settled" }, ctx);
}
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
async function waitFor(predicate, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (predicate()) return;
    await sleep(10);
  }
  throw new Error(`timed out waiting for ${label}`);
}
function launchCount() {
  try {
    return Number(readFileSync(`${process.env.FM_HOME}/state/.fixture-arm-count`, "utf8").trim());
  } catch {
    return 0;
  }
}
function armPid(number) {
  try {
    return Number(readFileSync(`${process.env.FM_HOME}/state/.fixture-arm-${number}.pid`, "utf8").trim());
  } catch {
    return 0;
  }
}
function alive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
function queuePending() {
  try {
    return readFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "utf8").length > 0;
  } catch {
    return false;
  }
}
function assertSingleLiveArm(expected) {
  const live = [];
  for (let number = 1; number <= launchCount(); number += 1) {
    if (alive(armPid(number))) live.push(number);
  }
  if (live.length !== 1 || live[0] !== expected) {
    throw new Error(`expected only arm ${expected} live, saw ${JSON.stringify(live)}`);
  }
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("arm-initial", {}, undefined, undefined, ctx);
await waitFor(() => launchCount() === 1 && alive(armPid(1)), "initial arm child");
assertSingleLiveArm(1);

writeFileSync(`${process.env.FM_HOME}/state/.fixture-fire-1`, "fire\n");
await waitFor(() => queuePending(), "first durable queued wake");
await waitFor(() => launchCount() >= 2 && alive(armPid(2)), "successor after first wake");
if (!queuePending()) throw new Error("first queue drained before successor proof");
assertSingleLiveArm(2);
const firstBeacon = readFileSync(`${process.env.FM_HOME}/state/.last-watcher-beat`, "utf8");
if (!firstBeacon.includes("launch=2")) throw new Error(`successor beacon was not fresh: ${firstBeacon}`);
await waitFor(() => sendAttempts === 1, "first delayed delivery attempt");
await sleep(50);
if (sendAttempts !== 1) throw new Error(`in-flight handoff was duplicated before admission: ${sendAttempts}`);
await waitFor(() => admissions >= 1 && triggeredTurns >= 1, "asynchronous admission of first wake");
if (sendAttempts !== 1 || deliveryAttempts[0]?.attempt !== 1 || admittedMessages[0]?.details?.attempt !== 1) {
  throw new Error(`first wake was not admitted exactly once: ${JSON.stringify({ deliveryAttempts, admittedMessages })}`);
}
if (!deliveryAttempts[0]?.deliveryId) throw new Error("first wake had no delivery identity");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
await waitFor(() => !queuePending(), "first queue drain");

writeFileSync(`${process.env.FM_HOME}/state/.fixture-fire-2`, "fire\n");
await waitFor(() => queuePending(), "second durable queued wake");
await waitFor(() => launchCount() >= 3 && alive(armPid(3)), "successor after second wake");
assertSingleLiveArm(3);
const secondBeacon = readFileSync(`${process.env.FM_HOME}/state/.last-watcher-beat`, "utf8");
if (!secondBeacon.includes("launch=3")) throw new Error(`second successor beacon was not fresh: ${secondBeacon}`);
await waitFor(() => sendAttempts === 2, "second unadmitted delivery attempt");
await sleep(60);
if (sendAttempts !== 2) throw new Error(`second wake retried before Pi settled: ${sendAttempts}`);
idle = true;
await handlers.get("agent_settled")?.({ type: "agent_settled" }, ctx);
await waitFor(() => sendAttempts >= 3 && admissions >= 2 && triggeredTurns >= 2, "settlement retry admitting second wake");
if (sendAttempts !== 3) throw new Error(`second wake flooded delivery attempts: ${sendAttempts}`);
if (
  deliveryAttempts[1]?.attempt !== 1 ||
  deliveryAttempts[2]?.attempt !== 2 ||
  !deliveryAttempts[1]?.deliveryId ||
  deliveryAttempts[1].deliveryId !== deliveryAttempts[2]?.deliveryId ||
  deliveryAttempts[1].deliveryId === deliveryAttempts[0]?.deliveryId
) {
  throw new Error(`second wake did not retain a distinct delivery identity across retry: ${JSON.stringify(deliveryAttempts)}`);
}
if (admittedMessages[1]?.customType !== "firstmate-watcher-wake" || admittedMessages[1]?.details?.attempt !== 2) {
  throw new Error(`second wake was not admitted on retry as custom input: ${JSON.stringify(admittedMessages[1])}`);
}
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
await waitFor(() => !queuePending(), "second queue drain");

writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
await waitFor(() => !alive(armPid(3)), "away-mode arm stop");
const awayLaunchCount = launchCount();
await sleep(80);
if (launchCount() !== awayLaunchCount) throw new Error("away mode restarted the Pi-owned watcher cycle");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await import("node:fs/promises").then(({ unlink }) => unlink(`${process.env.FM_HOME}/state/.afk`));
await tool.execute("arm-after-away", {}, undefined, undefined, ctx);
await waitFor(() => launchCount() === awayLaunchCount + 1 && alive(armPid(4)), "arm after away exit");
assertSingleLiveArm(4);

writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await waitFor(() => !alive(armPid(4)), "session-lock-loss arm stop");
const lockLossCount = launchCount();
await sleep(80);
if (launchCount() !== lockLossCount) throw new Error("lock loss restarted the Pi-owned watcher cycle");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await tool.execute("arm-after-lock", {}, undefined, undefined, ctx);
await waitFor(() => launchCount() === lockLossCount + 1 && alive(armPid(5)), "arm after lock reacquisition");
assertSingleLiveArm(5);

await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
await waitFor(() => !alive(armPid(5)), "session-shutdown arm cleanup");
for (let number = 1; number <= launchCount(); number += 1) {
  if (alive(armPid(number))) throw new Error(`arm child ${number} survived cleanup`);
}
if (branch.length !== 2 || new Set(branch.map((entry) => entry.details?.deliveryId)).size !== 2) {
  throw new Error(`unexpected admitted wake entries: ${JSON.stringify(branch)}`);
}
EOF
)
  status=$?
  [ "$status" -eq 0 ] || printf '%s\n' "$out" >&2
  expect_code 0 "$status" "Pi durable watcher cycle must retry observable delivery and survive consecutive wakes"
  [ -z "$out" ] || fail "Pi durable-cycle test printed output: $out"
  pass "Pi watcher avoids duplicate in-flight admission, retries after settlement, survives two wakes, and stops on ownership changes"
}

test_pi_compaction_preserves_direct_exchange_and_pending_input() {
  local repo home plugin pi_bin pi_package_dir out status
  fm_node_supports_ts_import || { pass "node lacks .ts import support, skipping Pi compaction-continuity check"; return; }
  pi_bin=$(command -v pi 2>/dev/null || true)
  [ -n "$pi_bin" ] || { pass "Pi is unavailable, skipping installed SessionManager compaction-continuity check"; return; }
  pi_package_dir=$(cd "$(dirname "$pi_bin")/../lib/node_modules/@earendil-works/pi-coding-agent" 2>/dev/null && pwd -P) || {
    pass "installed Pi package is unavailable, skipping SessionManager compaction-continuity check"
    return
  }
  repo="$TMP_ROOT/pi-compaction-continuity-root"
  home="$TMP_ROOT/pi-compaction-continuity-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count_file="$FM_HOME/state/.fixture-arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" 1 signal deterministic 'signal: deterministic supervision prompt' >> "$FM_HOME/state/.wake-queue"
  printf 'signal: deterministic supervision prompt\n'
  exit 0
fi
exec sleep 600
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(NODE_OPTIONS=--disable-warning=ExperimentalWarning PLUGIN="$plugin" PI_PACKAGE_DIR="$pi_package_dir" REPO="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { SessionManager } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const { Agent } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/node_modules/@earendil-works/pi-agent-core/dist/index.js`).href);
const { AssistantMessageEventStream } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/node_modules/@earendil-works/pi-ai/dist/index.js`).href);
let sessionManager = SessionManager.inMemory(process.env.REPO);
const handlers = new Map();
let tool = null;
let automatedMessage = null;
let automatedOptions = null;
let pendingMessages = false;

const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  appendEntry(customType, data) {
    sessionManager.appendCustomEntry(customType, data);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage(message, options) {
    automatedMessage = message;
    automatedOptions = options;
  },
};
const ctx = {
  get sessionManager() {
    return sessionManager;
  },
  hasPendingMessages: () => pendingMessages,
};
async function input(text, streamingBehavior, images) {
  await handlers.get("input")(
    { type: "input", text, images, source: "interactive", streamingBehavior },
    ctx,
  );
}
async function finishMessage(message) {
  await handlers.get("message_end")({ type: "message_end", message }, ctx);
  sessionManager.appendMessage(message);
}
async function startAgent() {
  await handlers.get("agent_start")({ type: "agent_start" }, ctx);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const providerContexts = [];
let releaseInitial;
let providerCall = 0;
const usage = {
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const agent = new Agent({
  initialState: {
    systemPrompt: "queue regression",
    model: { id: "fixture", name: "fixture", api: "openai-completions", provider: "fixture", baseUrl: "http://fixture", reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 },
    tools: [],
  },
  convertToLlm: (messages) => messages.map((message) => message.role === "custom"
    ? { role: "user", content: [{ type: "text", text: message.content }], timestamp: message.timestamp }
    : message),
  streamFn: (_model, context) => {
    providerContexts.push(structuredClone(context.messages));
    const call = ++providerCall;
    const stream = new AssistantMessageEventStream();
    const finish = () => {
      const message = { role: "assistant", content: [{ type: "text", text: `provider-${call}` }], api: "openai-completions", provider: "fixture", model: "fixture", usage, stopReason: "stop", timestamp: Date.now() };
      stream.push({ type: "start", partial: { ...message, content: [], stopReason: "pending" } });
      stream.push({ type: "done", reason: "stop", message });
    };
    if (call === 1) releaseInitial = finish;
    else queueMicrotask(finish);
    return stream;
  },
});
const exactImage = { type: "image", data: "QUEUE-ORDER-IMAGE-DATA", mimeType: "image/png" };
const initialRun = agent.prompt("INITIAL-HELD-RESPONSE");
for (let i = 0; i < 100 && !releaseInitial; i += 1) await new Promise((resolve) => setTimeout(resolve, 1));
if (!releaseInitial) throw new Error("controlled provider did not hold the initial response");
agent.followUp({ role: "custom", customType: "firstmate-watcher-wake", content: "OLDER-AUTOMATION-FOLLOWUP", display: true, timestamp: Date.now() });
agent.steer({ role: "user", content: [{ type: "text", text: "LATER-HUMAN-IMAGE-STEER" }, exactImage], timestamp: Date.now() });
releaseInitial();
await initialRun;
await agent.waitForIdle();
if (providerContexts.length !== 3) throw new Error(`expected three provider turns, got ${providerContexts.length}`);
const secondTail = providerContexts[1].at(-1);
const thirdTail = providerContexts[2].at(-1);
if (secondTail?.role !== "user" || JSON.stringify(secondTail.content) !== JSON.stringify([{ type: "text", text: "LATER-HUMAN-IMAGE-STEER" }, exactImage])) {
  throw new Error(`human image steer was reordered or altered: ${JSON.stringify(secondTail)}`);
}
if (thirdTail?.role !== "user" || JSON.stringify(thirdTail.content) !== JSON.stringify([{ type: "text", text: "OLDER-AUTOMATION-FOLLOWUP" }])) {
  throw new Error(`older automation was starved or delivered early: ${JSON.stringify(thirdTail)}`);
}

const question = "DIRECT-CAPTAIN-Q-7: Which harbor token should remain reserved?";
const answer = "DIRECT-CAPTAIN-A-7: amber.";
const followup = "Which question did I ask before the automated supervision turn, and was it answered?";
const queued = "QUEUED-CAPTAIN-Q-8: preserve this pending input too";
const questionContent = [{ type: "text", text: question }];
const answerContent = [{ type: "text", text: answer }];

await input(question);
await startAgent();
await finishMessage({ role: "user", content: questionContent, timestamp: 1700000000100 });
await finishMessage({
  role: "assistant",
  content: answerContent,
  stopReason: "stop",
  timestamp: 1700000000200,
});

await tool.execute("tool-compaction", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !automatedMessage; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!automatedMessage) throw new Error("watcher did not produce an automated prompt");
if (automatedMessage.customType !== "firstmate-watcher-wake") {
  throw new Error(`watcher prompt masqueraded as user input: ${automatedMessage.customType}`);
}
if (automatedOptions?.deliverAs !== "followUp" || automatedOptions?.triggerTurn !== true) {
  throw new Error(`wrong watcher queue behavior: ${JSON.stringify(automatedOptions)}`);
}
const automatedEntryId = sessionManager.appendCustomMessageEntry(
  automatedMessage.customType,
  automatedMessage.content,
  true,
  automatedMessage.details,
);
sessionManager.appendMessage({
  role: "assistant",
  content: [{ type: "text", text: "Automated supervision handled." }],
  stopReason: "stop",
  timestamp: 1700000000300,
});
const compactionId = sessionManager.appendCompaction(
  "Lossy summary without the direct captain exchange.",
  automatedEntryId,
  131874,
  { fixture: "automated-boundary" },
  true,
);
const compaction = sessionManager.getEntry(compactionId);
if (compaction?.type !== "compaction" || compaction.firstKeptEntryId !== automatedEntryId) {
  throw new Error("fixture did not compact at the automated-message boundary");
}

await input(followup);
const followupContent = [{ type: "text", text: followup }];
await finishMessage({ role: "user", content: followupContent, timestamp: 1700000000400 });
const rebuilt = sessionManager.buildSessionContext().messages;
if (rebuilt.some((message) => message.role === "user" && JSON.stringify(message.content) === JSON.stringify(questionContent))) {
  throw new Error("SessionManager fixture unexpectedly retained the pre-boundary captain question");
}
if (!rebuilt.some((message) => message.role === "custom" && message.customType === "firstmate-watcher-wake")) {
  throw new Error("SessionManager fixture lost the retained custom supervision prompt");
}
const result = await handlers.get("context")({ type: "context", messages: rebuilt }, ctx);
const continuity = result?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (!continuity) throw new Error("rebuilt context lacks direct-exchange continuity");
if (continuity.content.includes("Lossy summary without") && !continuity.content.includes(question)) {
  throw new Error("continuity trusted the lossy summary instead of the exact exchange");
}
if (!continuity.content.includes("ANSWERED") || !continuity.content.includes(JSON.stringify(questionContent))) {
  throw new Error(`exact answered question missing: ${continuity.content}`);
}
if (!continuity.content.includes(JSON.stringify(answerContent))) {
  throw new Error(`exact assistant answer missing: ${continuity.content}`);
}
if (!continuity.content.includes("OPEN_REPLY_OBLIGATION") || !continuity.content.includes(JSON.stringify(followupContent))) {
  throw new Error(`follow-up reply obligation missing: ${continuity.content}`);
}
if (!continuity.content.includes("not human-authored input") || !continuity.content.includes("custom messages")) {
  throw new Error("continuity does not distinguish extension prompts from human input");
}
const continuityIndex = result.messages.indexOf(continuity);
const followupIndex = result.messages.findIndex(
  (message) => message.role === "user" && JSON.stringify(message.content) === JSON.stringify(followupContent),
);
if (continuityIndex < 0 || followupIndex < 0 || continuityIndex >= followupIndex) {
  throw new Error("continuity metadata displaced the current human follow-up as the final prompt");
}

pendingMessages = true;
await input(queued, "steer");
const whilePending = await handlers.get("context")({ type: "context", messages: rebuilt }, ctx);
const pendingContinuity = whilePending?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (pendingContinuity?.content.includes(queued)) {
  throw new Error("pending human input bypassed Pi's queue and was injected early");
}
pendingMessages = false;
sessionManager = SessionManager.inMemory(process.env.REPO);
const provisional = "PROVISIONAL-CONSUMED-Q-8B";
pendingMessages = true;
await input(provisional, "steer");
const provisionalResult = await handlers.get("context")({ type: "context", messages: rebuilt }, ctx);
if (provisionalResult?.messages?.some((message) => message.customType === "firstmate-direct-exchange-continuity" && message.content.includes(provisional))) {
  throw new Error("consumed provisional input was admitted by unrelated pending automation");
}
pendingMessages = false;
const afterAutomationDrain = await handlers.get("context")({ type: "context", messages: rebuilt }, ctx);
if (afterAutomationDrain?.messages?.some((message) => message.customType === "firstmate-direct-exchange-continuity" && message.content.includes(provisional))) {
  throw new Error("consumed provisional input became continuity after unrelated automation drained");
}
pendingMessages = true;
await input(provisional, "steer");
await finishMessage({ role: "user", content: [{ type: "text", text: provisional }], timestamp: 1700000000410 });
pendingMessages = false;
const consumedRetryBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: unrelated automation after identical accepted retry",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits the identical accepted retry.",
  consumedRetryBoundaryId,
  131874,
  { fixture: "consumed-identical-retry-boundary" },
  true,
);
const consumedRetryResult = await handlers.get("context")(
  { type: "context", messages: sessionManager.buildSessionContext().messages },
  ctx,
);
const consumedRetryContinuity = consumedRetryResult?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
const consumedRetryObligations = consumedRetryContinuity?.content.match(/OPEN_REPLY_OBLIGATION/g) ?? [];
if (consumedRetryObligations.length !== 1 || !consumedRetryContinuity.content.includes(JSON.stringify([{ type: "text", text: provisional }]))) {
  throw new Error(`consumed input was confused with identical accepted retry: ${consumedRetryContinuity?.content}`);
}
const consumedRetryEntries = sessionManager.getBranch().filter((entry) => entry.type === "custom");
const consumedRetryObservations = consumedRetryEntries.filter(
  (entry) => entry.customType === "firstmate-direct-input-observation" && entry.data?.inputText === provisional,
);
const consumedRetryExchanges = consumedRetryEntries.filter(
  (entry) => entry.customType === "firstmate-direct-exchange" && entry.data?.event === "submitted" && entry.data?.inputText === provisional,
);
if (consumedRetryObservations.length !== 2 || consumedRetryExchanges.length !== 1) {
  throw new Error("input observations were promoted instead of admitting only the delivered identical retry");
}

sessionManager = SessionManager.inMemory(process.env.REPO);
const duplicate = "DUPLICATE-QUEUED-CAPTAIN-Q: preserve both obligations";
const duplicateContent = [{ type: "text", text: duplicate }];
await input(duplicate, "steer");
await input(duplicate, "steer");
await finishMessage({ role: "user", content: duplicateContent, timestamp: 1700000000420 });
await finishMessage({ role: "user", content: duplicateContent, timestamp: 1700000000430 });
const duplicateEvents = sessionManager.getBranch().filter(
  (entry) => entry.type === "custom" && entry.customType === "firstmate-direct-exchange",
);
const duplicateSubmissions = duplicateEvents.filter(
  (entry) => entry.data?.event === "submitted" && entry.data?.inputText === duplicate,
);
const duplicateDeliveries = duplicateEvents.filter(
  (entry) => entry.data?.event === "delivered" && JSON.stringify(entry.data?.content) === JSON.stringify(duplicateContent),
);
if (duplicateSubmissions.length !== 2 || new Set(duplicateSubmissions.map((entry) => entry.data.exchangeId)).size !== 2) {
  throw new Error("duplicate submissions did not retain distinct exchange identities");
}
if (
  duplicateDeliveries.length !== 2 ||
  duplicateDeliveries[0]?.data?.exchangeId !== duplicateSubmissions[0]?.data?.exchangeId ||
  duplicateDeliveries[1]?.data?.exchangeId !== duplicateSubmissions[1]?.data?.exchangeId
) {
  throw new Error("duplicate exact deliveries were not associated in submission order");
}
const duplicateBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: compact duplicate direct inputs",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits both duplicate direct inputs.",
  duplicateBoundaryId,
  131874,
  { fixture: "duplicate-input-boundary" },
  true,
);
const duplicateResult = await handlers.get("context")(
  { type: "context", messages: sessionManager.buildSessionContext().messages },
  ctx,
);
const duplicateContinuity = duplicateResult?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
const duplicateObligations = duplicateContinuity?.content.match(/OPEN_REPLY_OBLIGATION/g) ?? [];
if (duplicateObligations.length !== 2) {
  throw new Error(`compaction did not preserve two duplicate reply obligations: ${duplicateContinuity?.content}`);
}

sessionManager = SessionManager.inMemory(process.env.REPO);
pendingMessages = false;
const imageQueued = "QUEUED-CAPTAIN-IMAGE-Q-9: identify the attached harbor signal";
const image = { type: "image", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB", mimeType: "image/png" };
const imageSubmittedContent = [{ type: "text", text: imageQueued }, image];
pendingMessages = true;
await input(imageQueued, "followUp", [image]);
pendingMessages = false;
const imageBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: compaction before queued image delivery",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits the queued image submission.",
  imageBoundaryId,
  131874,
  { fixture: "image-before-delivery-boundary" },
  true,
);
const imageRebuilt = sessionManager.buildSessionContext().messages;
if (JSON.stringify(imageRebuilt).includes(image.data)) {
  throw new Error("image-before-delivery fixture unexpectedly retained the queued image in Pi context");
}
const imageBeforeDelivery = await handlers.get("context")({ type: "context", messages: imageRebuilt }, ctx);
if (imageBeforeDelivery?.messages?.some((message) => message.customType === "firstmate-direct-exchange-continuity" && message.content.includes(imageQueued))) {
  throw new Error("unadmitted queued image bypassed Pi ownership before delivery");
}
const imageSubmissionEntry = sessionManager.getBranch().find(
  (entry) => entry.type === "custom" && entry.customType === "firstmate-direct-input-observation",
);
if (JSON.stringify(imageSubmissionEntry?.data?.inputContent) !== JSON.stringify(imageSubmittedContent)) {
  throw new Error("provisional session contract did not preserve exact queued image content");
}
await finishMessage({ role: "user", content: imageSubmittedContent, timestamp: 1700000000450 });
const deliveredBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: compaction after exact image delivery",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits the delivered image question.",
  deliveredBoundaryId,
  131874,
  { fixture: "image-after-delivery-boundary" },
  true,
);
const imageAfterDelivery = await handlers.get("context")(
  { type: "context", messages: sessionManager.buildSessionContext().messages },
  ctx,
);
const imageContinuity = imageAfterDelivery?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (!imageContinuity?.content.includes("OPEN_REPLY_OBLIGATION") || !imageContinuity.content.includes(JSON.stringify(imageSubmittedContent))) {
  throw new Error(`compaction lost exact admitted image obligation: ${imageContinuity?.content}`);
}

sessionManager = SessionManager.inMemory(process.env.REPO);
pendingMessages = false;
const unanswered = "UNANSWERED-CAPTAIN-Q-10: Which reply remains due?";
const unansweredContent = [{ type: "text", text: unanswered }];
await input(unanswered);
await finishMessage({ role: "user", content: unansweredContent, timestamp: 1700000000500 });
const openAutomationId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: deterministic open-obligation boundary",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendMessage({
  role: "assistant",
  content: [{ type: "text", text: "Automation handled without answering the captain." }],
  stopReason: "stop",
  timestamp: 1700000000600,
});
sessionManager.appendCompaction(
  "Lossy summary that omits the unanswered direct question.",
  openAutomationId,
  131874,
  { fixture: "open-obligation-boundary" },
  true,
);
const openRebuilt = sessionManager.buildSessionContext().messages;
if (openRebuilt.some((message) => message.role === "user")) {
  throw new Error("open-obligation fixture unexpectedly retained the captain user message");
}
const openResult = await handlers.get("context")({ type: "context", messages: openRebuilt }, ctx);
const openContinuity = openResult?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (!openContinuity?.content.includes("OPEN_REPLY_OBLIGATION") || !openContinuity.content.includes(JSON.stringify(unansweredContent))) {
  throw new Error("compaction lost the exact unanswered captain obligation");
}

sessionManager = SessionManager.inMemory(process.env.REPO);
const abortedQuestion = [{ type: "text", text: "ABORTED-RUN-CAPTAIN-Q: which answer remains due?" }];
const laterQuestion = [{ type: "text", text: "LATER-RUN-CAPTAIN-Q: answer only this question" }];
const joinedQuestion = [{ type: "text", text: "JOINED-RUN-CAPTAIN-Q: preserve joined delivery" }];
const laterAnswer = [{ type: "text", text: "LATER-RUN-CAPTAIN-A: this question only" }];
await startAgent();
await finishMessage({ role: "user", content: abortedQuestion, timestamp: 1700000000700 });
await startAgent();
await finishMessage({ role: "user", content: laterQuestion, timestamp: 1700000000800 });
await finishMessage({ role: "user", content: joinedQuestion, timestamp: 1700000000850 });
await finishMessage({
  role: "assistant",
  content: laterAnswer,
  stopReason: "stop",
  timestamp: 1700000000900,
});
const runExchangeEvents = sessionManager.getBranch().filter(
  (entry) => entry.type === "custom" && entry.customType === "firstmate-direct-exchange",
);
const laterRunAnswers = runExchangeEvents.filter(
  (entry) => entry.data?.event === "answered" && JSON.stringify(entry.data?.content) === JSON.stringify(laterAnswer),
);
if (laterRunAnswers.length !== 2) {
  throw new Error(`same-run deliveries were not both answered: ${JSON.stringify(laterRunAnswers)}`);
}
const runBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: compact run-attribution fixture",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits both run-attribution questions.",
  runBoundaryId,
  131874,
  { fixture: "run-attribution-boundary" },
  true,
);
const runResult = await handlers.get("context")(
  { type: "context", messages: sessionManager.buildSessionContext().messages },
  ctx,
);
const runContinuity = runResult?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (!runContinuity?.content.includes(`OPEN_REPLY_OBLIGATION\nHuman input, exact JSON: ${JSON.stringify(abortedQuestion)}`)) {
  throw new Error(`aborted run obligation was incorrectly closed: ${runContinuity?.content}`);
}
if (!runContinuity.content.includes(`ANSWERED\nHuman input, exact JSON: ${JSON.stringify(joinedQuestion)}`)) {
  throw new Error(`joined delivery in the later run was not answered: ${runContinuity.content}`);
}
if (!runContinuity.content.includes(JSON.stringify(laterAnswer))) {
  throw new Error(`later run answer was not preserved: ${runContinuity.content}`);
}

sessionManager = SessionManager.inMemory(process.env.REPO);
const retryQuestion = [{ type: "text", text: "RETRY-CAPTAIN-Q: close this after retry" }];
const retryAnswer = [{ type: "text", text: "RETRY-CAPTAIN-A: closed after retry" }];
await startAgent();
await finishMessage({ role: "user", content: retryQuestion, timestamp: 1700000001000 });
await startAgent();
await finishMessage({ role: "assistant", content: retryAnswer, stopReason: "stop", timestamp: 1700000001100 });
const retryEvents = sessionManager.getBranch().filter(
  (entry) => entry.type === "custom" && entry.customType === "firstmate-direct-exchange",
);
const retryAnswered = retryEvents.find(
  (entry) => entry.data?.event === "answered" && JSON.stringify(entry.data?.content) === JSON.stringify(retryAnswer),
);
if (!retryAnswered) throw new Error("successful retry did not answer the retained captain exchange");

sessionManager = SessionManager.inMemory(process.env.REPO);
const failedQuestion = [{ type: "text", text: "FAILED-CAPTAIN-Q: leave this open" }];
const replacementQuestion = [{ type: "text", text: "REPLACEMENT-CAPTAIN-Q: answer this instead" }];
const replacementAnswer = [{ type: "text", text: "REPLACEMENT-CAPTAIN-A: answered replacement" }];
await startAgent();
await finishMessage({ role: "user", content: failedQuestion, timestamp: 1700000001200 });
await startAgent();
await finishMessage({ role: "user", content: replacementQuestion, timestamp: 1700000001300 });
await finishMessage({ role: "assistant", content: replacementAnswer, stopReason: "stop", timestamp: 1700000001400 });
const replacementBoundaryId = sessionManager.appendCustomMessageEntry(
  "firstmate-watcher-wake",
  "FIRSTMATE WATCHER WAKE: retry replacement boundary",
  true,
  { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
);
sessionManager.appendCompaction(
  "Lossy summary that omits retry lifecycle exchanges.",
  replacementBoundaryId,
  131874,
  { fixture: "retry-replacement-boundary" },
  true,
);
const replacementResult = await handlers.get("context")(
  { type: "context", messages: sessionManager.buildSessionContext().messages },
  ctx,
);
const replacementContinuity = replacementResult?.messages?.find(
  (message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity",
);
if (!replacementContinuity?.content.includes(`OPEN_REPLY_OBLIGATION\nHuman input, exact JSON: ${JSON.stringify(failedQuestion)}`)) {
  throw new Error(`failed original question was incorrectly closed: ${replacementContinuity?.content}`);
}
if (!replacementContinuity.content.includes(`ANSWERED\nHuman input, exact JSON: ${JSON.stringify(replacementQuestion)}`)) {
  throw new Error(`replacement question was not answered: ${replacementContinuity.content}`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
EOF
)
  status=$?
  [ "$status" -eq 0 ] || printf '%s\n' "$out" >&2
  expect_code 0 "$status" "Pi compaction continuity must preserve exact direct exchange and pending-input state"
  [ -z "$out" ] || fail "Pi compaction-continuity test printed output: $out"
  pass "Pi compaction continuity preserves exact human exchange across automated custom prompts"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$TMP_ROOT/opencode-effective-state-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# Stay beyond the retired one-second log poll so this test proves it awaits the
# plugin coordinator's bounded readiness result.
sleep 2
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const armStatus = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (armStatus !== "external") {
  console.error(`expected external arm status, got ${armStatus}`);
  process.exit(1);
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root: $out"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$TMP_ROOT/opencode-effective-config-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$TMP_ROOT/opencode-lock-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await hooks.event(event);
await new Promise((resolve) => setTimeout(resolve, 120));
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin guard_plugin kind base repo home log guard_log out status
  plugin="$TMP_ROOT/opencode-coordinator-primary.mjs"
  guard_plugin="$TMP_ROOT/opencode-coordinator-guard.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$guard_plugin"
  for kind in crew scout; do
    base="$TMP_ROOT/opencode-coordinator-$kind-base"
    repo="$TMP_ROOT/opencode-coordinator-$kind-wt"
    home="$TMP_ROOT/opencode-coordinator-$kind-home"
    log="$TMP_ROOT/opencode-coordinator-$kind.log"
    guard_log="$TMP_ROOT/opencode-coordinator-$kind-guard.log"
    fm_git_worktree "$base" "$repo" "fm/opencode-coordinator-$kind"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    : > "$repo/AGENTS.md"
    printf 'sm-opencode-parent\n' > "$home/.fm-secondmate-home"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
    cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'child guard requested follow-up\n' >&2
exit 2
SH
    chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
    out=$(PLUGIN="$plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from an unmarked child worktree");
  process.exit(1);
}
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard did not run in the child worktree");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing child guard follow-up: ${promptBody}`);
  process.exit(1);
}
EOF
    )
    status=$?
    expect_code 0 "$status" "OpenCode watch coordinator must stay silent in an unmarked $kind worktree while leaving the turn-end guard active"
    [ -z "$out" ] || fail "OpenCode $kind coordinator-scope test printed output: $out"
  done
  pass "OpenCode watcher stays silent in child crew/scout worktrees without suppressing their turn-end guard"
}

test_opencode_watch_arm_includes_secondmate_own_home() {
  local plugin topology base repo log out status git_dir common_dir
  plugin="$TMP_ROOT/opencode-secondmate-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  for topology in plain linked; do
    repo="$TMP_ROOT/opencode-secondmate-$topology"
    log="$TMP_ROOT/opencode-secondmate-$topology.log"
    if [ "$topology" = linked ]; then
      base="$TMP_ROOT/opencode-secondmate-linked-base"
      fm_git_worktree "$base" "$repo" fm/opencode-secondmate-linked
      git_dir=$(git -C "$repo" rev-parse --git-dir)
      common_dir=$(git -C "$repo" rev-parse --git-common-dir)
      [ "$git_dir" != "$common_dir" ] || fail "linked secondmate fixture is not a linked worktree"
    else
      git init -q "$repo"
    fi
    mkdir -p "$repo/bin" "$repo/state" "$repo/config"
    : > "$repo/AGENTS.md"
    printf 'sm-opencode-%s\n' "$topology" > "$repo/.fm-secondmate-home"
    : > "$repo/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (status !== "armed") {
  console.error(`expected armed, got ${status}`);
  process.exit(1);
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run in the secondmate home");
  process.exit(1);
}
EOF
    )
    status=$?
    expect_code 0 "$status" "OpenCode watcher must arm in a marked $topology secondmate home"
    [ -z "$out" ] || fail "OpenCode $topology secondmate-home test printed output: $out"
  done
  pass "OpenCode watcher arms in a marked secondmate's plain and linked own home"
}

test_opencode_watch_arm_rejects_spoofed_secondmate_markers() {
  local plugin marker_kind base repo marker_target log out status
  plugin="$TMP_ROOT/opencode-spoofed-marker-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  for marker_kind in empty symlink; do
    base="$TMP_ROOT/opencode-spoofed-$marker_kind-base"
    repo="$TMP_ROOT/opencode-spoofed-$marker_kind-wt"
    log="$TMP_ROOT/opencode-spoofed-$marker_kind.log"
    fm_git_worktree "$base" "$repo" "fm/opencode-spoofed-$marker_kind"
    mkdir -p "$repo/bin" "$repo/state" "$repo/config"
    : > "$repo/AGENTS.md"
    : > "$repo/state/task.meta"
    if [ "$marker_kind" = symlink ]; then
      marker_target="$TMP_ROOT/opencode-spoofed-marker-target"
      printf 'sm-opencode-spoof\n' > "$marker_target"
      ln -s "$marker_target" "$repo/.fm-secondmate-home"
    else
      : > "$repo/.fm-secondmate-home"
    fi
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
await new Promise((resolve) => setTimeout(resolve, 120));
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm trusted a spoofed secondmate marker");
  process.exit(1);
}
EOF
    )
    status=$?
    expect_code 0 "$status" "OpenCode watcher must reject a linked worktree's $marker_kind secondmate marker"
    [ -z "$out" ] || fail "OpenCode $marker_kind marker-spoof test printed output: $out"
  done
  pass "OpenCode watcher rejects empty and symlinked secondmate marker spoofs"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log out status
  plugin="$TMP_ROOT/opencode-rearm-primary.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'signal: synthetic wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const waitForPrompts = async (expected) => {
  for (let i = 0; i < 50; i += 1) {
    if (prompts >= expected) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  console.error(`expected ${expected} prompts, saw ${prompts}`);
  process.exit(1);
};
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
await waitForPrompts(1);
await hooks.event(event);
await waitForPrompts(2);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm on the idle after a wake follow-up"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin rearms after a watcher wake"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$TMP_ROOT/opencode-coordinate-primary.mjs"
  guard_plugin="$TMP_ROOT/opencode-coordinate-guard.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$arm_plugin"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$guard_plugin"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$TMP_ROOT/opencode-external-healthy-primary.mjs"
  guard_plugin="$TMP_ROOT/opencode-external-healthy-guard.mjs"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$arm_plugin"
  stage_opencode_module "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$guard_plugin"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

if [ "${FM_PI_EXACT_DELIVERY_PROOF:-0}" = 1 ]; then
  test_pi_compaction_preserves_direct_exchange_and_pending_input
  printf '%s\n' 'PI_EXACT_DELIVERY_ASSOCIATION_PROOF_OK'
  exit 0
fi

if [ "${FM_PI_RETRY_CONTINUITY_PROOF:-0}" = 1 ]; then
  test_pi_compaction_preserves_direct_exchange_and_pending_input
  printf '%s\n' 'PI_RETRY_CONTINUITY_PROOF_OK'
  exit 0
fi

test_pi_extension_runtime_configuration_contract
test_spawn_template_mentions_pi_watch_placeholder
test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_pi_durable_cycle_retries_delivery_and_rearms
test_pi_compaction_preserves_direct_exchange_and_pending_input
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_watch_arm_includes_secondmate_own_home
test_opencode_watch_arm_rejects_spoofed_secondmate_markers
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
printf '%s\n' 'PI_DIRECT_CONTINUITY_PROOF_OK'
