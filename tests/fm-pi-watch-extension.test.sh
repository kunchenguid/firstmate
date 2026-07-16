#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/typebox"
  : > "$repo/.fm-secondmate-home"
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

test_tracked_extension_present_and_self_hashing() {
  local text expected_config_source
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$EXT" "tracked Pi primary watcher extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_pi" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "pi.sendMessage" "tracked extension missing Pi custom wake API"
  assert_contains "$text" 'customType: "firstmate-watcher-wake"' "tracked extension missing stable custom wake type"
  assert_contains "$text" "deliverAs: \"followUp\"" "tracked extension missing followUp delivery"
  assert_contains "$text" "triggerTurn: true" "tracked extension missing idle turn trigger"
  assert_contains "$text" 'type WatcherStatus = "offline" | "watching" | "handling wake" | "attention"' "tracked extension missing watcher status contract"
  assert_contains "$text" 'FIRSTMATE_PI_WATCHER_STATUS_KEY = "firstmate-pi-watcher"' "tracked extension missing stable status key"
  assert_contains "$text" "__firstmatePiWatchCoordinators" "tracked extension missing one-coordinator-per-home fencing"
  assert_contains "$text" "detached: true" "tracked extension does not own an arm process group"
  assert_contains "$text" "MAX_CAPTURE_BYTES" "tracked extension does not bound watcher output"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension does not read the effective session lock"
  assert_contains "$text" 'return pidAlive(lockPid) ? "other" : "missing"' "tracked extension does not allow a pre-lock load marker"
  assert_contains "$text" 'if (lockOwnership() === "other" && !canonicalLockIsStale()) return' "tracked extension overwrites another live session marker"
  assert_contains "$text" 'if (lockOwnership() !== "owned")' "tracked extension arms without the session lock"
  assert_contains "$text" "writeFileSync(marker, \`\${extensionVersion}\\n\${process.pid}\\n\`)" "tracked extension does not write the content version and process marker"
  assert_contains "$text" "const config = process.env.FM_CONFIG_OVERRIDE" "tracked extension missing effective config resolution"
  assert_contains "$text" "FM_CONFIG_OVERRIDE: config" "tracked extension does not pass the effective config to the watcher arm"
  assert_contains "$text" "FM_WATCH_ARM_SCRIPT: armScript" "tracked extension does not pass the effective watcher arm script"
  assert_contains "$text" "$expected_config_source" "tracked extension does not source the effective x-mode config"
  assert_contains "$text" "exec \\\"\$FM_WATCH_ARM_SCRIPT\\\" --restart" "tracked extension does not restart into a Pi-owned watcher child"
  assert_contains "$text" 'label: "Arm firstmate watcher"' "tracked extension tool is missing its human-readable label"
  assert_contains "$text" 'parameters: Type.Object({})' "tracked extension tool is not using Pi's canonical TypeBox schema"
  assert_contains "$text" 'content: [{ type: "text", text: result.message }]' "tracked extension tool is missing Pi text content"
  assert_contains "$text" 'details: result' "tracked extension tool is missing structured result details"
  assert_contains "$text" 'ctx.ui.notify' "tracked extension command does not notify through Pi's UI"
  assert_contains "$text" 'process.once("exit", cleanupOnProcessExit)' "tracked extension lacks clean-process-exit cleanup"
  assert_contains "$text" 'pi.on?.("session_shutdown"' "tracked extension lacks awaited session shutdown cleanup"
  assert_not_contains "$text" 'agent_settled' "tracked watcher-only extension still listens for turn-end events"
  assert_not_contains "$text" 'sendUserMessage' "tracked watcher-only extension still injects fake human input"
  assert_not_contains "$text" 'runTurnendGuard' "tracked watcher-only extension still runs the turn-end guard"
  assert_not_contains "$text" "[ -f config/x-mode.env ]" "tracked extension kept a repo-relative x-mode config path"
  pass "Pi primary watcher extension is tracked, self-hashing, and self-locating"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "--approve -e __PIWATCH__" "Pi secondmate launch template does not use the watcher-only approved launch"
  assert_contains "$text" "\$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts" "fm-spawn does not point the Pi secondmate watch placeholder at the tracked extension"
  assert_not_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn should no longer generate the Pi watch extension before launch"
  assert_not_contains "$text" "__PITURNEND__" "fm-spawn still carries the removed Pi turn-end extension placeholder"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes only the tracked watcher extension"
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let wake = null;
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendMessage(message, options) {
    wake = { message, options };
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
for (let i = 0; i < 50 && !wake; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (wake?.message?.customType !== "firstmate-watcher-wake" || wake?.options?.triggerTurn !== true) {
  console.error(`missing structured follow-up wake: ${JSON.stringify(wake)}`);
  process.exit(1);
}
if (!wake.message.content.includes("external healthy watcher")) {
  console.error(wake.message.content);
  process.exit(1);
}
if (!wake.message.content.includes("watcher: healthy pid=1")) {
  console.error(wake.message.content);
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
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
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
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
  local repo home plugin pid_file out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
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
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_pi_watcher_lifecycle_and_status_contract() {
  local repo home plugin starts cleaned wake out status
  repo="$TMP_ROOT/pi-lifecycle-root"
  home="$TMP_ROOT/pi-lifecycle-home"
  starts="$TMP_ROOT/pi-lifecycle-starts"
  cleaned="$TMP_ROOT/pi-lifecycle-cleaned"
  wake="$TMP_ROOT/pi-lifecycle-wake"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'printf "clean\n" >> "$FM_CLEAN_LOG"; exit 0' TERM INT
while [ ! -e "$FM_WAKE_FILE" ]; do sleep 0.02; done
rm -f "$FM_WAKE_FILE"
printf 'signal: compact lifecycle wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_CLEAN_LOG="$cleaned" FM_WAKE_FILE="$wake" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const statuses = [];
const wakes = [];
let tool;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message, options) { wakes.push({ message, options }); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, {
  ui: { setStatus(_key, text) { statuses.push(text); } },
});
if (statuses.at(-1) !== "watching") throw new Error(`automatic initial arm: ${statuses}`);
for (let i = 0; i < 50 && !existsSync(process.env.FM_START_LOG); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (!existsSync(process.env.FM_START_LOG)) throw new Error("arm child did not start");
const duplicate = await tool.execute("duplicate", {}, undefined, undefined, {});
if (!duplicate.content[0].text.includes("already has an arm child")) throw new Error(`duplicate arm: ${JSON.stringify(duplicate)}`);
if (readFileSync(process.env.FM_START_LOG, "utf8").trim().split("\n").length !== 1) throw new Error("duplicate arm spawned a child");

writeFileSync(process.env.FM_WAKE_FILE, "wake\n");
for (let i = 0; i < 100 && wakes.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
if (wakes.length !== 1) throw new Error(`wake count: ${wakes.length}`);
const wake = wakes[0];
if (wake.message.customType !== "firstmate-watcher-wake" || wake.message.details?.kind !== "actionable") {
  throw new Error(`wake payload: ${JSON.stringify(wake)}`);
}
if (wake.options?.deliverAs !== "followUp" || wake.options?.triggerTurn !== true) throw new Error(`wake options: ${JSON.stringify(wake.options)}`);
for (let i = 0; i < 50 && readFileSync(process.env.FM_START_LOG, "utf8").trim().split("\n").length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (readFileSync(process.env.FM_START_LOG, "utf8").trim().split("\n").length !== 2) throw new Error("accepted wake did not start one replacement");
if (statuses.at(-1) !== "watching" || !statuses.includes("handling wake")) throw new Error(`automatic rearm status: ${statuses}`);
await handlers.get("session_shutdown")?.({ reason: "test-shutdown" }, {});
if (statuses.at(-1) !== undefined) throw new Error(`shutdown status: ${statuses}`);
for (let i = 0; i < 100 && !existsSync(process.env.FM_CLEAN_LOG); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (!existsSync(process.env.FM_CLEAN_LOG)) throw new Error("shutdown did not stop the arm process group");
if (wakes.length !== 1) throw new Error("intentional shutdown emitted a false wake");
EOF
)
  status=$?
  [ -z "$out" ] || fail "Pi lifecycle test printed output: $out"
  expect_code 0 "$status" "Pi watcher lifecycle must auto-arm, deliver one structured wake, re-arm, and clean up"
  pass "Pi watcher lifecycle auto-arms, delivers one structured wake, re-arms, and cleans up"
}

test_pi_watcher_yields_to_away_mode_lifecycle() {
  local repo home plugin starts cleaned out status
  repo="$TMP_ROOT/pi-away-mode-root"
  home="$TMP_ROOT/pi-away-mode-home"
  starts="$TMP_ROOT/pi-away-mode-starts"
  cleaned="$TMP_ROOT/pi-away-mode-cleaned"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'printf "clean\n" >> "$FM_CLEAN_LOG"; exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_CLEAN_LOG="$cleaned" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const statuses = [];
const wakes = [];
let tool;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message, options) { wakes.push({ message, options }); },
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, {
  ui: { setStatus(_key, text) { statuses.push(text); } },
});
await new Promise((resolve) => setTimeout(resolve, 50));
if (lines(process.env.FM_START_LOG).length !== 0) throw new Error("watcher armed while away mode was already active");
if (statuses.at(-1) !== "offline") throw new Error(`initial away-mode status: ${statuses}`);

rmSync(`${process.env.FM_HOME}/state/.afk`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "watcher did not resume after away mode exited");
if (statuses.at(-1) !== "watching") throw new Error(`resumed status: ${statuses}`);

writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => lines(process.env.FM_CLEAN_LOG).length === 1, "away-mode entry did not stop the extension-owned arm");
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("away-mode entry replaced the watcher arm");
if (statuses.at(-1) !== "offline") throw new Error(`away-mode entry status: ${statuses}`);
const suspended = await tool.execute("while-away", {}, undefined, undefined, {});
if (!suspended.content[0].text.includes("away mode owns supervision")) {
  throw new Error(`manual arm ignored away mode: ${JSON.stringify(suspended)}`);
}
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("manual arm started a watcher during away mode");

rmSync(`${process.env.FM_HOME}/state/.afk`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "watcher did not reconcile after away-mode exit");
if (wakes.length !== 0) throw new Error(`intentional away-mode stop emitted a wake: ${JSON.stringify(wakes)}`);
if (statuses.at(-1) !== "watching") throw new Error(`second resumed status: ${statuses}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher lifecycle must yield to away mode and resume after exit"
  [ -z "$out" ] || fail "Pi away-mode lifecycle test printed output: $out"
  pass "Pi watcher lifecycle yields to away mode and resumes after exit"
}

test_pi_watcher_defers_settled_wake_during_away_mode() {
  local repo home plugin starts wake out status
  repo="$TMP_ROOT/pi-away-settle-root"
  home="$TMP_ROOT/pi-away-settle-home"
  starts="$TMP_ROOT/pi-away-settle-starts"
  wake="$TMP_ROOT/pi-away-settle-wake"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'exit 0' TERM
while [ ! -e "$FM_WAKE_FILE" ]; do sleep 0.02; done
rm -f "$FM_WAKE_FILE"
printf 'signal: wake settled during away mode\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_WAKE_FILE="$wake" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const wakes = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message, options) { wakes.push({ message, options }); },
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "initial arm did not start");

writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
writeFileSync(process.env.FM_WAKE_FILE, "wake\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (wakes.length !== 0) throw new Error(`settled wake bypassed away mode: ${JSON.stringify(wakes)}`);
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("settled wake rearmed during away mode");

rmSync(`${process.env.FM_HOME}/state/.afk`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => wakes.length === 1, "post-away reconciliation did not deliver the settled wake");
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "post-away reconciliation did not start a replacement arm");
if (!wakes[0].message.content.includes("wake settled during away mode")) throw new Error("wrong deferred settled wake");
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi arm settlement must defer actionable wakes during away mode"
  [ -z "$out" ] || fail "Pi away-mode settlement test printed output: $out"
  pass "Pi arm settlement defers actionable wakes during away mode"
}

test_pi_watcher_defers_settled_failure_during_away_mode() {
  local repo home plugin starts wake out status
  repo="$TMP_ROOT/pi-away-failure-root"
  home="$TMP_ROOT/pi-away-failure-home"
  starts="$TMP_ROOT/pi-away-failure-starts"
  wake="$TMP_ROOT/pi-away-failure-wake"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'exit 0' TERM
while [ ! -e "$FM_WAKE_FILE" ]; do sleep 0.02; done
rm -f "$FM_WAKE_FILE"
printf 'arm failed during away mode\n' >&2
exit 23
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_WAKE_FILE="$wake" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const wakes = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message, options) { wakes.push({ message, options }); },
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "initial arm did not start");

writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
writeFileSync(process.env.FM_WAKE_FILE, "wake\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (wakes.length !== 0) throw new Error(`settled failure bypassed away mode: ${JSON.stringify(wakes)}`);
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("settled failure rearmed during away mode");

rmSync(`${process.env.FM_HOME}/state/.afk`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => wakes.length === 1, "post-away reconciliation did not deliver the settled failure");
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "post-away reconciliation did not start a replacement arm");
if (!wakes[0].message.content.includes("exited 23")) throw new Error("wrong deferred settled failure");
if (wakes[0].message.details?.kind !== "failure") throw new Error(`wrong deferred wake kind: ${JSON.stringify(wakes[0])}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi arm settlement must defer failures during away mode"
  [ -z "$out" ] || fail "Pi away-mode failure settlement test printed output: $out"
  pass "Pi arm settlement defers failures during away mode"
}

test_pi_watcher_restarts_only_for_effective_cadence_changes() {
  local repo home plugin starts cleaned out status
  repo="$TMP_ROOT/pi-cadence-root"
  home="$TMP_ROOT/pi-cadence-home"
  starts="$TMP_ROOT/pi-cadence-starts"
  cleaned="$TMP_ROOT/pi-cadence-cleaned"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'interval=%s\n' "${FM_CHECK_INTERVAL:-300}" >> "$FM_START_LOG"
trap 'printf "clean\n" >> "$FM_CLEAN_LOG"; exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_CLEAN_LOG="$cleaned" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitForCount = async (expected) => {
  for (let i = 0; i < 150 && lines(process.env.FM_START_LOG).length < expected; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (lines(process.env.FM_START_LOG).length !== expected) throw new Error(`expected ${expected} starts, got ${lines(process.env.FM_START_LOG)}`);
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/config/x-mode.env`, "# stale bootstrap output\nexport FM_CHECK_INTERVAL=60\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitForCount(1);
if (lines(process.env.FM_START_LOG)[0] !== "interval=60") throw new Error(`stale cadence not applied initially: ${lines(process.env.FM_START_LOG)}`);

await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "read" }, {});
await new Promise((resolve) => setTimeout(resolve, 50));
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("unchanged cadence restarted watcher");

writeFileSync(`${process.env.FM_HOME}/config/x-mode.env`, "export FM_CHECK_INTERVAL=30\n");
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitForCount(2);
if (lines(process.env.FM_START_LOG)[1] !== "interval=30") throw new Error(`changed cadence not applied: ${lines(process.env.FM_START_LOG)}`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await new Promise((resolve) => setTimeout(resolve, 50));
if (lines(process.env.FM_START_LOG).length !== 2) throw new Error("same x-mode config restarted watcher twice");
writeFileSync(`${process.env.FM_HOME}/config/x-mode.env`, "# regenerated\nexport FM_CHECK_INTERVAL=30\n");
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "write" }, {});
await new Promise((resolve) => setTimeout(resolve, 50));
if (lines(process.env.FM_START_LOG).length !== 2) throw new Error("non-effective x-mode rewrite restarted watcher");

rmSync(`${process.env.FM_HOME}/config/x-mode.env`);
await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitForCount(3);
if (lines(process.env.FM_START_LOG)[2] !== "interval=300") throw new Error(`default cadence not restored: ${lines(process.env.FM_START_LOG)}`);
if (lines(process.env.FM_CLEAN_LOG).length !== 2) throw new Error(`cadence cleanup count: ${lines(process.env.FM_CLEAN_LOG)}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher must restart exactly once per effective x-mode cadence change"
  [ -z "$out" ] || fail "Pi cadence reconciliation test printed output: $out"
  pass "Pi watcher reconciles only effective cadence changes"
}

test_pi_shutdown_cancels_cadence_restart_during_cleanup() {
  local repo home plugin starts stops out status
  repo="$TMP_ROOT/pi-shutdown-cadence-root"
  home="$TMP_ROOT/pi-shutdown-cadence-home"
  starts="$TMP_ROOT/pi-shutdown-cadence-starts"
  stops="$TMP_ROOT/pi-shutdown-cadence-stops"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s interval=%s\n' "$$" "${FM_CHECK_INTERVAL:-300}" >> "$FM_START_LOG"
trap 'printf "stopping\n" >> "$FM_STOP_LOG"; sleep 0.2; printf "stopped\n" >> "$FM_STOP_LOG"; exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_STOP_LOG="$stops" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};
const stopChildren = () => {
  for (const line of lines(process.env.FM_START_LOG)) {
    const pid = Number(line.match(/^pid=([0-9]+)/)?.[1]);
    if (!pid) continue;
    try { process.kill(-pid, "SIGKILL"); } catch {}
  }
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "initial arm did not start");

writeFileSync(`${process.env.FM_HOME}/config/x-mode.env`, "export FM_CHECK_INTERVAL=30\n");
const cadenceRestart = handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
await waitFor(() => lines(process.env.FM_STOP_LOG).includes("stopping"), "cadence cleanup did not begin");
const shutdown = handlers.get("session_shutdown")?.({ reason: "test-shutdown" }, {});
await Promise.all([cadenceRestart, shutdown]);
await new Promise((resolve) => setTimeout(resolve, 50));

const startsAfterShutdown = lines(process.env.FM_START_LOG);
if (startsAfterShutdown.length !== 1) {
  stopChildren();
  throw new Error(`shutdown allowed cadence restart: ${startsAfterShutdown}`);
}
if (lines(process.env.FM_STOP_LOG).filter((line) => line === "stopped").length !== 1) {
  stopChildren();
  throw new Error(`shutdown did not finish cleanup: ${lines(process.env.FM_STOP_LOG)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi shutdown must cancel a cadence restart while cleanup is in progress"
  [ -z "$out" ] || fail "Pi shutdown/cadence race test printed output: $out"
  pass "Pi shutdown cancels cadence restart during cleanup"
}

test_pi_spawned_restart_yields_to_away_mode() {
  local repo home plugin arm_log bash_env out status
  repo="$TMP_ROOT/pi-spawn-away-root"
  home="$TMP_ROOT/pi-spawn-away-home"
  arm_log="$TMP_ROOT/pi-spawn-away-arm"
  bash_env="$TMP_ROOT/pi-spawn-away-env"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$FM_ARM_LOG"
trap 'exit 0' TERM
while :; do sleep 1; done
SH
  cat > "$bash_env" <<'SH'
#!/usr/bin/env bash
printf 'away\n' > "$FM_HOME/state/.afk"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" \
    BASH_ENV="$bash_env" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const statuses = [];
const wakes = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message, options) { wakes.push({ message, options }); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus(_key, text) { statuses.push(text); } } });
for (let i = 0; i < 100 && !existsSync(`${process.env.FM_HOME}/state/.afk`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 100));
if (!existsSync(`${process.env.FM_HOME}/state/.afk`)) throw new Error("spawned launcher did not enter away mode");
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("spawned launcher started a Pi-owned watcher during away mode");
if (wakes.length !== 0) throw new Error(`intentional away suspension emitted a wake: ${JSON.stringify(wakes)}`);
if (statuses.at(-1) !== "offline") throw new Error(`away suspension status: ${statuses}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi spawned restart must yield to away-mode ownership"
  [ -z "$out" ] || fail "Pi spawned away-mode restart test printed output: $out"
  pass "Pi spawned restart yields to away-mode ownership"
}

test_pi_cleanup_failure_does_not_reuse_settled_arm() {
  local repo home plugin starts out status
  repo="$TMP_ROOT/pi-cleanup-failure-root"
  home="$TMP_ROOT/pi-cleanup-failure-home"
  starts="$TMP_ROOT/pi-cleanup-failure-starts"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_PI_WATCH_STOP_GRACE_MS=0 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function client(statuses) {
  const handlers = new Map();
  return {
    handlers,
    pi: {
      on(event, handler) { handlers.set(event, handler); },
      registerCommand() {},
      registerTool() {},
      sendMessage() {},
    },
    context: { ui: { setStatus(_key, text) { statuses.push(text); } } },
  };
}
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldStatuses = [];
const oldClient = client(oldStatuses);
(await import(`${url}?cleanup-old`)).default(oldClient.pi);
await oldClient.handlers.get("session_start")?.({}, oldClient.context);
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "initial arm did not start");

const originalKill = process.kill;
process.kill = function (pid, signal) {
  if (typeof pid === "number" && pid < 0 && signal === 0) return true;
  return originalKill.call(process, pid, signal);
};
let cleanupError = "";
try {
  await oldClient.handlers.get("session_shutdown")?.({ reason: "reload" }, {});
} catch (error) {
  cleanupError = error instanceof Error ? error.message : String(error);
} finally {
  process.kill = originalKill;
}
if (!cleanupError.includes("survived SIGKILL")) throw new Error(`cleanup failure was not exercised: ${cleanupError}`);

const newStatuses = [];
const newClient = client(newStatuses);
(await import(`${url}?cleanup-new`)).default(newClient.pi);
await newClient.handlers.get("session_start")?.({}, newClient.context);
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "cleanup-failed record was treated as a healthy arm");
if (newStatuses.at(-1) !== "watching") throw new Error(`replacement status: ${newStatuses}`);
await newClient.handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup failure must not leave a settled arm eligible for reuse"
  [ -z "$out" ] || fail "Pi cleanup-failure test printed output: $out"
  pass "Pi cleanup failure quarantines the settled arm"
}

test_pi_extension_loads_for_fresh_home_in_primary_checkout() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-fresh-home-root"
  home="$TMP_ROOT/pi-fresh-home"
  mkdir -p "$repo/bin" "$repo/.pi/extensions" "$repo/node_modules/typebox"
  install_pi_watch_extension_fixture "$repo"
  rm -f "$repo/.fm-secondmate-home"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  rm -rf "$home"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage() {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("fresh FM_HOME disabled the primary watcher extension");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must load for a fresh FM_HOME in the primary checkout"
  [ -z "$out" ] || fail "Pi fresh-home test printed output: $out"
  pass "Pi extension loads for a fresh FM_HOME in the primary checkout"
}

test_pi_reload_preserves_captured_actionable_wake() {
  local repo home plugin ready out status
  repo="$TMP_ROOT/pi-reload-wake-root"
  home="$TMP_ROOT/pi-reload-wake-home"
  ready="$TMP_ROOT/pi-reload-wake-ready"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf 'signal: wake captured before reload\n'
: > "$FM_READY_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_READY_FILE="$ready" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function client(wakes, initiallyBound = true) {
  const handlers = new Map();
  let tool;
  let bound = initiallyBound;
  let attempts = 0;
  return {
    handlers,
    get tool() { return tool; },
    get attempts() { return attempts; },
    bind() { bound = true; },
    pi: {
      on(event, handler) { handlers.set(event, handler); },
      registerCommand() {},
      registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
      sendMessage(message, options) {
        attempts += 1;
        if (!bound) throw new Error("sendMessage called before bindCore");
        wakes.push({ message, options });
      },
    },
  };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldWakes = [];
const oldClient = client(oldWakes);
(await import(`${url}?old`)).default(oldClient.pi);
await oldClient.tool.execute("arm", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !existsSync(process.env.FM_READY_FILE); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (!existsSync(process.env.FM_READY_FILE)) throw new Error("arm did not capture actionable output");
await new Promise((resolve) => setTimeout(resolve, 50));
await oldClient.handlers.get("session_shutdown")?.({ reason: "reload" }, {});

const newWakes = [];
const newClient = client(newWakes, false);
(await import(`${url}?new`)).default(newClient.pi);
if (newClient.attempts !== 0) throw new Error("replacement delivered pending wake before bindCore");
newClient.bind();
await newClient.handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
for (let i = 0; i < 100 && newWakes.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (newWakes.length !== 1 || newWakes[0].message.details?.kind !== "actionable") {
  throw new Error(`reload lost captured wake: ${JSON.stringify(newWakes)}`);
}
if (!newWakes[0].message.content.includes("wake captured before reload")) throw new Error("wrong preserved wake");
if (newClient.attempts !== 1) throw new Error(`pending wake attempts: ${newClient.attempts}`);
await newClient.handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi reload must preserve an already-captured actionable wake"
  [ -z "$out" ] || fail "Pi reload-wake test printed output: $out"
  pass "Pi reload preserves an already-captured actionable wake"
}

test_pi_pending_wake_delivery_failure_retries() {
  local repo home plugin starts out status
  repo="$TMP_ROOT/pi-pending-retry-root"
  home="$TMP_ROOT/pi-pending-retry-home"
  starts="$TMP_ROOT/pi-pending-retry-starts"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
trap 'exit 0' TERM
printf 'signal: pending wake for retry\n'
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function client(wakes, failures = 0) {
  const handlers = new Map();
  const statuses = [];
  let attempts = 0;
  let tool;
  return {
    handlers,
    statuses,
    get attempts() { return attempts; },
    get tool() { return tool; },
    context: { ui: { setStatus(_key, text) { statuses.push(text); } } },
    pi: {
      on(event, handler) { handlers.set(event, handler); },
      registerCommand() {},
      registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
      sendMessage(message, options) {
        attempts += 1;
        if (attempts <= failures) throw new Error("transient pending-wake delivery failure");
        wakes.push({ message, options });
      },
    },
  };
}
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 100 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldClient = client([]);
(await import(`${url}?retry-old`)).default(oldClient.pi);
await oldClient.tool.execute("arm", {}, undefined, undefined, {});
await waitFor(() => lines(process.env.FM_START_LOG).length === 1, "initial arm did not start");
await new Promise((resolve) => setTimeout(resolve, 50));
await oldClient.handlers.get("session_shutdown")?.({ reason: "reload" }, {});

const newWakes = [];
const newClient = client(newWakes, 2);
(await import(`${url}?retry-new`)).default(newClient.pi);
await newClient.handlers.get("session_start")?.({}, newClient.context);
if (newClient.attempts !== 1) throw new Error(`initial pending delivery attempts: ${newClient.attempts}`);
if (newWakes.length !== 0) throw new Error(`failed delivery cleared the pending wake: ${JSON.stringify(newWakes)}`);
if (newClient.statuses.at(-1) !== "attention") throw new Error(`failed delivery status: ${newClient.statuses}`);
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("failed delivery started a replacement arm");

const failedRetry = await newClient.tool.execute("retry-fail", {}, undefined, undefined, {});
if (failedRetry.details?.ok !== false || !failedRetry.details?.message.includes("pending wake delivery failed")) {
  throw new Error(`failed retry result: ${JSON.stringify(failedRetry)}`);
}
if (newClient.attempts !== 2 || newWakes.length !== 0) throw new Error("failed retry did not preserve the pending wake");
if (newClient.statuses.at(-1) !== "attention") throw new Error(`failed retry status: ${newClient.statuses}`);
if (lines(process.env.FM_START_LOG).length !== 1) throw new Error("failed retry started a replacement arm");

const retry = await newClient.tool.execute("retry", {}, undefined, undefined, {});
if (retry.details?.ok !== true) throw new Error(`retry result: ${JSON.stringify(retry)}`);
await waitFor(() => newWakes.length === 1, "lifecycle retry did not deliver the pending wake");
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "lifecycle retry did not start a replacement arm");
if (newClient.attempts !== 3) throw new Error(`retry pending delivery attempts: ${newClient.attempts}`);
if (!newWakes[0].message.content.includes("pending wake for retry")) throw new Error("wrong retried wake");
await newClient.handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi pending-wake delivery failure must remain retryable"
  [ -z "$out" ] || fail "Pi pending-wake retry test printed output: $out"
  pass "Pi pending-wake delivery failure remains retryable"
}

test_pi_settled_wake_delivery_failure_retries_automatically() {
  local repo home plugin starts first_exit out status
  repo="$TMP_ROOT/pi-settled-retry-root"
  home="$TMP_ROOT/pi-settled-retry-home"
  starts="$TMP_ROOT/pi-settled-retry-starts"
  first_exit="$TMP_ROOT/pi-settled-retry-first-exit"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
if [ ! -e "$FM_FIRST_EXIT_FILE" ]; then
  : > "$FM_FIRST_EXIT_FILE"
  printf 'signal: settled wake for automatic retry\n'
  exit 0
fi
trap 'exit 0' TERM
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_FIRST_EXIT_FILE="$first_exit" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const statuses = [];
const wakes = [];
let attempts = 0;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message, options) {
    attempts += 1;
    if (attempts === 1) throw new Error("transient settled-wake delivery failure");
    wakes.push({ message, options });
  },
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, { ui: { setStatus(_key, text) { statuses.push(text); } } });
await waitFor(() => attempts === 2, `settled wake was not retried automatically: ${attempts}`);
await waitFor(() => wakes.length === 1, "settled wake retry was not delivered");
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "settled wake retry did not start a replacement arm");
if (!statuses.includes("attention")) throw new Error(`delivery failure did not publish attention: ${statuses}`);
if (statuses.at(-1) !== "watching") throw new Error(`replacement arm status: ${statuses}`);
if (!wakes[0].message.content.includes("settled wake for automatic retry")) throw new Error("wrong retried settled wake");
if (wakes[0].message.details?.kind !== "actionable") throw new Error(`wrong retried wake kind: ${JSON.stringify(wakes[0])}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi settled-wake delivery failure must retry automatically"
  [ -z "$out" ] || fail "Pi settled-wake automatic retry test printed output: $out"
  pass "Pi settled-wake delivery failure retries automatically"
}

test_pi_settled_failure_delivery_survives_reload() {
  local repo home plugin starts first_exit out status
  repo="$TMP_ROOT/pi-failure-reload-root"
  home="$TMP_ROOT/pi-failure-reload-home"
  starts="$TMP_ROOT/pi-failure-reload-starts"
  first_exit="$TMP_ROOT/pi-failure-reload-first-exit"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
if [ ! -e "$FM_FIRST_EXIT_FILE" ]; then
  : > "$FM_FIRST_EXIT_FILE"
  exit 23
fi
trap 'exit 0' TERM
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_FIRST_EXIT_FILE="$first_exit" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function client(wakes, rejectDelivery = false) {
  const handlers = new Map();
  let attempts = 0;
  return {
    handlers,
    get attempts() { return attempts; },
    pi: {
      on(event, handler) { handlers.set(event, handler); },
      registerCommand() {},
      registerTool() {},
      sendMessage(message, options) {
        attempts += 1;
        if (rejectDelivery) throw new Error("synthetic failure-wake delivery rejection");
        wakes.push({ message, options });
      },
    },
  };
}
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldClient = client([], true);
(await import(`${url}?failure-old`)).default(oldClient.pi);
await oldClient.handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitFor(() => oldClient.attempts === 1, "settled failure delivery was not attempted");
await oldClient.handlers.get("session_shutdown")?.({ reason: "reload" }, {});

const wakes = [];
const newClient = client(wakes);
(await import(`${url}?failure-new`)).default(newClient.pi);
await newClient.handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await waitFor(() => wakes.length === 1, "reload lost the rejected failure wake");
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "reload did not start a replacement arm");
if (wakes[0].message.details?.kind !== "failure") throw new Error(`wrong retained wake kind: ${JSON.stringify(wakes[0])}`);
if (!wakes[0].message.content.includes("exited 23")) throw new Error("wrong retained failure wake");
await newClient.handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi rejected failure wake must survive extension reload"
  [ -z "$out" ] || fail "Pi failure-wake reload test printed output: $out"
  pass "Pi rejected failure wake survives extension reload"
}

test_pi_rearm_failure_does_not_redeliver_wake() {
  local repo home plugin starts first_exit out status
  repo="$TMP_ROOT/pi-rearm-failure-root"
  home="$TMP_ROOT/pi-rearm-failure-home"
  starts="$TMP_ROOT/pi-rearm-failure-starts"
  first_exit="$TMP_ROOT/pi-rearm-failure-first-exit"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start\n' >> "$FM_START_LOG"
if [ ! -e "$FM_FIRST_EXIT_FILE" ]; then
  : > "$FM_FIRST_EXIT_FILE"
  printf 'signal: delivered before rearm failure\n'
  exit 0
fi
trap 'exit 0' TERM
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_START_LOG="$starts" \
    FM_FIRST_EXIT_FILE="$first_exit" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const statuses = [];
const wakes = [];
let tool;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message, options) { wakes.push({ message, options }); },
};
const lines = (path) => existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").filter(Boolean) : [];
const waitFor = async (predicate, message) => {
  for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!predicate()) throw new Error(message);
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const client = [...coordinator.clients.values()][0];
const originalRearm = client.rearm;
let rearmAttempts = 0;
client.rearm = async () => {
  rearmAttempts += 1;
  throw new Error("synthetic rearm rejection");
};
await handlers.get("session_start")?.({}, { ui: { setStatus(_key, text) { statuses.push(text); } } });
await waitFor(() => wakes.length === 1, "actionable wake was not delivered");
await waitFor(() => rearmAttempts === 1, `rearm rejection was not observed: ${rearmAttempts}`);
await new Promise((resolve) => setTimeout(resolve, 50));
if (rearmAttempts !== 1) throw new Error(`rearm rejection triggered another rearm: ${rearmAttempts}`);
if (statuses.at(-1) !== "attention") throw new Error(`rearm rejection status: ${statuses}`);

client.rearm = originalRearm;
const result = await tool.execute("recover", {}, undefined, undefined, {});
if (result.details?.ok !== true) throw new Error(`manual recovery failed: ${JSON.stringify(result)}`);
await waitFor(() => lines(process.env.FM_START_LOG).length === 2, "manual recovery did not start a replacement arm");
if (wakes.length !== 1) throw new Error(`already-delivered wake was queued again: ${JSON.stringify(wakes)}`);
await handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi rearm rejection must not requeue an already-delivered wake"
  [ -z "$out" ] || fail "Pi rearm rejection test printed output: $out"
  pass "Pi rearm rejection does not redeliver a wake"
}

test_pi_reload_defers_pending_wake_during_away_mode() {
  local repo home plugin ready out status
  repo="$TMP_ROOT/pi-reload-away-root"
  home="$TMP_ROOT/pi-reload-away-home"
  ready="$TMP_ROOT/pi-reload-away-ready"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf 'signal: wake captured before away-mode reload\n'
: > "$FM_READY_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_READY_FILE="$ready" node --input-type=module 2>&1 <<'EOF'
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function client(wakes, initiallyBound = true) {
  const handlers = new Map();
  let tool;
  let bound = initiallyBound;
  return {
    handlers,
    get tool() { return tool; },
    bind() { bound = true; },
    pi: {
      on(event, handler) { handlers.set(event, handler); },
      registerCommand() {},
      registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
      sendMessage(message, options) {
        if (!bound) throw new Error("sendMessage called before bindCore");
        wakes.push({ message, options });
      },
    },
  };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldClient = client([]);
(await import(`${url}?away-old`)).default(oldClient.pi);
await oldClient.tool.execute("arm", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !existsSync(process.env.FM_READY_FILE); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (!existsSync(process.env.FM_READY_FILE)) throw new Error("arm did not capture actionable output");
await new Promise((resolve) => setTimeout(resolve, 50));
writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
await oldClient.handlers.get("session_shutdown")?.({ reason: "reload" }, {});

const newWakes = [];
const newClient = client(newWakes, false);
(await import(`${url}?away-new`)).default(newClient.pi);
newClient.bind();
await newClient.handlers.get("session_start")?.({}, { ui: { setStatus() {} } });
await new Promise((resolve) => setTimeout(resolve, 50));
if (newWakes.length !== 0) throw new Error(`away-mode reload delivered pending wake: ${JSON.stringify(newWakes)}`);

rmSync(`${process.env.FM_HOME}/state/.afk`);
await newClient.handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolName: "bash" }, {});
for (let i = 0; i < 100 && newWakes.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (newWakes.length !== 1 || newWakes[0].message.details?.kind !== "actionable") {
  throw new Error(`away-mode exit lost pending wake: ${JSON.stringify(newWakes)}`);
}
if (!newWakes[0].message.content.includes("wake captured before away-mode reload")) throw new Error("wrong deferred wake");
await newClient.handlers.get("session_shutdown")?.({ reason: "done" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi reload must defer a pending wake until away mode exits"
  [ -z "$out" ] || fail "Pi away-mode reload test printed output: $out"
  pass "Pi reload defers pending wakes during away mode"
}

test_pi_live_process_scan_does_not_match_itself() {
  local out status
  out=$("$ROOT/tests/fm-pi-primary-live-e2e.test.sh" --process-scan-self-test 2>&1)
  status=$?
  expect_code 0 "$status" "Pi live process scanner must find only the lab-owned probe"
  assert_contains "$out" "ok - Pi live cleanup isolates and terminates lab-owned processes" "Pi live cleanup self-test did not pass"
  pass "Pi live cleanup isolates and terminates lab-owned processes"
}

test_opencode_primary_watch_plugin_static_wiring() {
  local plugin text
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  assert_present "$plugin" "OpenCode primary watch plugin missing"
  text=$(cat "$plugin")
  assert_contains "$text" "session.idle" "OpenCode plugin does not listen for session.idle"
  assert_contains "$text" "fm-watch-arm.sh" "OpenCode plugin does not spawn the watcher arm"
  assert_contains "$text" "promptAsync" "OpenCode plugin does not wake with promptAsync"
  assert_contains "$text" ".fm-secondmate-home" "OpenCode plugin does not scope out secondmate homes"
  assert_contains "$text" "rev-parse\", \"--git-dir" "OpenCode plugin does not check linked worktree scope"
  assert_contains "$text" "sessionOwnsLock" "OpenCode plugin does not gate arm attempts on the session lock"
  assert_contains "$text" 'fm-watch-arm.sh" --restart' "OpenCode plugin does not restart into its own watcher child"
  assert_contains "$text" 'setArmStatus("external")' "OpenCode plugin still treats an external healthy watcher as armed"
  pass "OpenCode primary watcher plugin has the verified TUI wake wiring"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
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
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
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
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
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
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
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
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
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
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
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
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
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
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
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
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
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
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
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
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
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
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
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

test_tracked_extension_present_and_self_hashing
test_spawn_template_mentions_pi_watch_placeholder
test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_pi_watcher_lifecycle_and_status_contract
test_pi_cleanup_failure_does_not_reuse_settled_arm
test_pi_watcher_yields_to_away_mode_lifecycle
test_pi_watcher_defers_settled_wake_during_away_mode
test_pi_watcher_defers_settled_failure_during_away_mode
test_pi_watcher_restarts_only_for_effective_cadence_changes
test_pi_shutdown_cancels_cadence_restart_during_cleanup
test_pi_spawned_restart_yields_to_away_mode
test_pi_extension_loads_for_fresh_home_in_primary_checkout
test_pi_reload_preserves_captured_actionable_wake
test_pi_pending_wake_delivery_failure_retries
test_pi_settled_wake_delivery_failure_retries_automatically
test_pi_settled_failure_delivery_survives_reload
test_pi_rearm_failure_does_not_redeliver_wake
test_pi_reload_defers_pending_wake_during_away_mode
test_pi_live_process_scan_does_not_match_itself
test_opencode_primary_watch_plugin_static_wiring
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
