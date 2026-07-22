#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
ACTIONABLE="$ROOT/bin/fm-wake-actionable.sh"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-wake-actionable.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture) printf '1:1:1\n' ;;
  validate) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$repo/bin/fm-wake-actionable.sh"
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

install_pi_real_actionability_fixture() {
  local repo=$1
  cp "$ACTIONABLE" "$repo/bin/fm-wake-actionable.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$repo/bin/fm-wake-lib.sh"
}

test_tracked_extension_present_and_self_hashing() {
  local text expected_config_source
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$EXT" "tracked Pi primary watcher extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_pi" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "tracked extension missing Pi wake API"
  assert_not_contains "$text" "deliverAs: \"followUp\"" "tracked extension still queues an irrevocable Pi follow-up before final validation"
  assert_contains "$text" 'pi.on?.("agent_settled"' "tracked extension does not defer busy-turn delivery to Pi's idle boundary"
  assert_contains "$text" "fm-wake-actionable.sh" "tracked extension does not use the repository actionability owner"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension does not read the effective session lock"
  assert_contains "$text" 'return pidAlive(lockPid) ? "other" : "missing"' "tracked extension does not allow a pre-lock load marker"
  assert_contains "$text" 'if (lockOwnership() === "other") return' "tracked extension overwrites another live session marker"
  assert_contains "$text" 'const ownership = lockOwnership()' "tracked extension arm does not inspect the distinct lock ownership state"
  assert_contains "$text" 'if (ownership === "other") return { ok: false' "tracked extension arm does not preserve the live-other read-only refusal"
  assert_contains "$text" 'if (ownership === "missing")' "tracked extension arm collapses a stale or absent lock into the live-other refusal"
  assert_contains "$text" "no live session holds the lock" "tracked extension arm missing stale-lock recovery guidance"
  assert_contains "$text" "run bin/fm-session-start.sh to reclaim it" "tracked extension arm does not direct stale-lock reclamation"
  assert_contains "$text" "call fm_watch_arm_pi to re-arm" "tracked extension arm does not direct supervision re-arm"
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
  assert_not_contains "$text" "[ -f config/x-mode.env ]" "tracked extension kept a repo-relative x-mode config path"
  pass "Pi primary watcher extension is tracked, self-hashing, and self-locating"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
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
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
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
  sendUserMessage: async () => {},
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

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`single-flight violation launched ${stableRows.length} arms`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
releaseDelivery();
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "Pi hung-successor test printed output: $out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  release="$TMP_ROOT/pi-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "Pi unretired-successor test printed output: $out"
  pass "Pi unretired successor falls back without an overlapping retry"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log ready retired release stop out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    retired="$TMP_ROOT/pi-late-$kind.retired"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "Pi late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "Pi late-$kind test printed output: $out"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "Pi empty-close retry test printed output: $out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "Pi established-empty-close retry test printed output: $out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "Pi close lock test printed output: $out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
const assertMissingLock = (result, label) => {
  if (result.details?.ok !== false) throw new Error(`${label} unexpectedly armed: ${JSON.stringify(result.details)}`);
  if (!result.details.message.includes("no live session holds the lock")) {
    throw new Error(`${label} missing no-live-session guidance: ${result.details.message}`);
  }
  if (!result.details.message.includes("bin/fm-session-start.sh") || !result.details.message.includes("re-arm")) {
    throw new Error(`${label} missing reclaim and re-arm guidance: ${result.details.message}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
assertMissingLock(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
assertMissingLock(await callArm(), "dead lock holder");

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - session lock is held by another firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watcher arm ran without lock ownership");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true || !owned.details.message.includes("started Pi extension arm child")) {
  throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
}
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("owned lock did not run the watcher arm");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm must distinguish owned, live-other, and missing or dead session locks"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm distinguishes all session lock ownership states"
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
  sendUserMessage: async () => {},
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
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
  while [ "$i" -lt 250 ] && [ ! -f "$cleanup_log" ]; do
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

test_pi_cleanup_during_successor_restore_suppresses_stale_wakes() {
  local repo home plugin log successor_ready release stop out status
  repo="$TMP_ROOT/pi-cleanup-during-restore-root"
  home="$TMP_ROOT/pi-cleanup-during-restore-home"
  log="$TMP_ROOT/pi-cleanup-during-restore.log"
  successor_ready="$TMP_ROOT/pi-cleanup-during-restore.ready"
  release="$TMP_ROOT/pi-cleanup-during-restore.release"
  stop="$TMP_ROOT/pi-cleanup-during-restore.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  install_pi_real_actionability_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf '%s\t1\tstale\tdefault:w1:p1B\tstale: default:w1:p1B\n' "$(date +%s)" > "$FM_HOME/state/.wake-queue"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'stale: default:w1:p1B\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  : > "$FM_SUCCESSOR_READY_FILE"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\t2\tstale\tdefault:w1:p1C\tstale: default:w1:p1C\n' "$(date +%s)" >> "$FM_HOME/state/.wake-queue"
  printf 'stale: default:w1:p1C\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cat > "$home/state/task-cleaned.meta" <<'EOF'
window=default:w1:p1B
kind=ship
EOF
  printf 'done: handled and ready for cleanup\n' > "$home/state/task-cleaned.status"
  cat > "$home/state/task-also-cleaned.meta" <<'EOF'
window=default:w1:p1C
kind=ship
EOF
  printf 'done: also handled and ready for cleanup\n' > "$home/state/task-also-cleaned.status"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_SUCCESSOR_READY_FILE="$successor_ready" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const handlers = new Map();
let idle = false;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage(message) {
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const context = { isIdle: () => idle };
await handlers.get("session_start")?.({}, context);
await tool.execute("tool-call-cleanup-race", {}, undefined, undefined, context);
for (let i = 0; i < 250 && !existsSync(process.env.FM_SUCCESSOR_READY_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_SUCCESSOR_READY_FILE)) throw new Error("successor restoration did not enter the test seam");
rmSync(`${process.env.FM_HOME}/state/task-cleaned.meta`);
rmSync(`${process.env.FM_HOME}/state/task-cleaned.status`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 250; i += 1) {
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length >= 3) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
rmSync(`${process.env.FM_HOME}/state/task-also-cleaned.meta`);
rmSync(`${process.env.FM_HOME}/state/task-also-cleaned.status`);
idle = true;
await handlers.get("agent_settled")?.({}, context);
await new Promise((resolve) => setTimeout(resolve, 150));
if (prompts.length !== 0) throw new Error(`obsolete stale wakes were injected: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must suppress repeated stale wakes whose tasks are cleaned during successor restoration and before idle delivery"
  [ -z "$out" ] || fail "Pi cleanup-during-restore test printed output: $out"
  pass "Pi suppresses multiple stale wakes invalidated during successor restoration and before idle delivery"
}

test_wake_actionability_helper_source_and_queue_matrix() {
  local home state reason receipt before after check xcheck rejected unrelated status
  home="$TMP_ROOT/wake-actionability-home"
  state="$home/state"
  mkdir -p "$state"

  printf 'window=default:w1:p-signal\n' > "$state/task-signal.meta"
  printf 'done: signal remains current\n' > "$state/task-signal.status"
  reason="signal: $state/task-signal.status"
  printf '%s\t1\tsignal\ttask-signal.status\t%s\n' "$(date +%s)" "$reason" > "$state/.wake-queue"
  before=$(cat "$state/.wake-queue")
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "current signal did not produce an actionability receipt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "current signal receipt did not validate"
  after=$(cat "$state/.wake-queue")
  [ "$after" = "$before" ] || fail "actionability validation mutated the durable queue"
  rm -f "$state/task-signal.status"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "signal receipt survived removal of its source record"
  fi

  printf 'window=default:w1:p-batch-a\n' > "$state/task-batch-a.meta"
  printf 'done: first batched signal\n' > "$state/task-batch-a.status"
  printf 'window=default:w1:p-batch-b\n' > "$state/task-batch-b.meta"
  printf 'done: second batched signal\n' > "$state/task-batch-b.status"
  reason="signal: $state/task-batch-a.status $state/task-batch-b.status"
  {
    printf '%s\t2\tsignal\ttask-batch-a.status\t%s\n' "$(date +%s)" "$reason"
    printf '%s\t3\tsignal\ttask-batch-b.status\t%s\n' "$(date +%s)" "$reason"
  } > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "batched signal did not produce a composite actionability receipt"
  rm -f "$state/task-batch-b.meta" "$state/task-batch-b.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "batched signal lost a still-current task when one coalesced source was cleaned"
  rm -f "$state/task-batch-a.meta" "$state/task-batch-a.status"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "batched signal receipt survived cleanup of every bound source"
  fi

  printf 'window=default:w1:p-stale\n' > "$state/task-stale.meta"
  printf 'working: active stale counterexample\n' > "$state/task-stale.status"
  reason='stale: default:w1:p-stale'
  printf '%s\t2\tstale\tdefault:w1:p-stale\t%s\n' "$(date +%s)" "$reason" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "active stale worker did not produce an actionability receipt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "active stale worker receipt did not validate"
  rm -f "$state/task-stale.meta"
  printf 'window=default:w1:p-stale\n' > "$state/reused-endpoint.meta"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "stale receipt followed an endpoint reused by a different task"
  fi

  check="$state/task-check.check.sh"
  printf '#!/usr/bin/env bash\nprintf current-check\\n\n' > "$check"
  chmod 0700 "$check"
  reason="check: $check: current-check"
  printf '%s\t3\tcheck\t%s\t%s\n' "$(date +%s)" "$check" "$reason" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "current check did not produce an actionability receipt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "current check receipt did not validate"
  rm -f "$check"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "check receipt survived removal of its source record"
  fi

  xcheck="$state/x-watch.check.sh"
  printf '#!/usr/bin/env bash\nprintf x-event\\n\n' > "$xcheck"
  chmod 0700 "$xcheck"
  reason="check: $xcheck: x-event"
  printf '%s\t4\tcheck\t%s\t%s\n' "$(date +%s)" "$xcheck" "$reason" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "current X check did not produce an actionability receipt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "current X check receipt did not validate"

  rejected="$state/rejected.check.sh"
  unrelated="$state/unrelated.check.sh"
  ln -s "$state/missing-check-target" "$rejected"
  reason="check: rejected unauthenticated state checks: $rejected"
  printf '%s\t5\tcheck\tunauthenticated-state-checks:rejected.check.sh\t%s\n' "$(date +%s)" "$reason" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "rejected check did not produce an actionability receipt"
  printf '#!/usr/bin/env bash\n' > "$unrelated"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "unrelated check creation invalidated a rejected-check receipt"
  rm -f "$rejected"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "rejected-check receipt survived removal of its bound source"
  fi

  printf 'window=default:w1:p-heartbeat\n' > "$state/task-heartbeat.meta"
  printf 'done: heartbeat source remains current\n' > "$state/task-heartbeat.status"
  reason=heartbeat
  printf '%s\t6\theartbeat\theartbeat:task-heartbeat.status\theartbeat\n' "$(date +%s)" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "current heartbeat did not produce an actionability receipt"
  printf 'window=default:w1:p-unrelated\n' > "$state/unrelated.meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "unrelated task creation invalidated a heartbeat receipt"
  printf 'working: heartbeat source is no longer actionable\n' >> "$state/task-heartbeat.status"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "heartbeat receipt survived a change to its bound status"
  fi

  printf 'window=default:w1:p-heartbeat-a\n' > "$state/task-heartbeat-a.meta"
  printf 'done: heartbeat source A\n' > "$state/task-heartbeat-a.status"
  printf 'window=default:w1:p-heartbeat-b\n' > "$state/task-heartbeat-b.meta"
  printf 'done: heartbeat source B\n' > "$state/task-heartbeat-b.status"
  {
    printf '%s\t7\theartbeat\theartbeat:task-heartbeat-a.status\theartbeat\n' "$(date +%s)"
    printf '%s\t8\theartbeat\theartbeat:task-heartbeat-b.status\theartbeat\n' "$(date +%s)"
  } > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture "$reason") \
    || fail "coalesced heartbeat did not produce a composite receipt"
  rm -f "$state/task-heartbeat-b.meta" "$state/task-heartbeat-b.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt" \
    || fail "coalesced heartbeat lost a still-current source"
  rm -f "$state/task-heartbeat-a.meta" "$state/task-heartbeat-a.status"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" validate "$receipt"; then
    fail "coalesced heartbeat survived cleanup of every bound source"
  fi

  printf 'window=default:w1:p-error\n' > "$state/task-error.meta"
  printf 'done: validation error remains visible\n' > "$state/task-error.status"
  printf '%s\t9\tsignal\ttask-error.status\tsignal-error\n' "$(date +%s)" > "$state/.wake-queue"
  receipt=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ACTIONABLE" capture signal-error) \
    || fail "validation-error fixture did not produce a receipt"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WAKE_QUEUE="$state/missing/.wake-queue" \
    "$ACTIONABLE" validate "$receipt" 2>/dev/null; then
    fail "unreadable queue validated as current"
  else
    status=$?
  fi
  [ "$status" -eq 2 ] || fail "unreadable queue collapsed to obsolete status $status"
  pass "wake actionability receipts bind queue rows and home-local signal, stale, check, X, and heartbeat sources"
}

test_pi_current_wake_kinds_deliver_once_at_idle() {
  local kind repo home plugin log stop key reason queue_kind out status
  for kind in stale signal check x heartbeat; do
    repo="$TMP_ROOT/pi-current-$kind-root"
    home="$TMP_ROOT/pi-current-$kind-home"
    log="$TMP_ROOT/pi-current-$kind.log"
    stop="$TMP_ROOT/pi-current-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    install_pi_real_actionability_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    case "$kind" in
      stale)
        key='default:w1:p15'
        reason="stale: $key"
        printf 'window=%s\n' "$key" > "$home/state/task-current.meta"
        ;;
      signal)
        key='task-current.status'
        reason="signal: $home/state/$key"
        printf 'window=default:w1:p-signal\n' > "$home/state/task-current.meta"
        printf 'done: current signal\n' > "$home/state/$key"
        ;;
      check)
        key="$home/state/task-current.check.sh"
        reason="check: $key: current check"
        printf '#!/usr/bin/env bash\n' > "$key"
        chmod 0700 "$key"
        ;;
      x)
        key="$home/state/x-watch.check.sh"
        reason="check: $key: x event"
        printf '#!/usr/bin/env bash\n' > "$key"
        chmod 0700 "$key"
        ;;
      heartbeat)
        key=heartbeat
        reason=heartbeat
        printf 'window=default:w1:p-heartbeat\n' > "$home/state/task-current.meta"
        ;;
    esac
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf '%s\t1\t%s\t%s\t%s\n' "$(date +%s)" "$FM_QUEUE_KIND" "$FM_QUEUE_KEY" "$FM_QUEUE_REASON" > "$FM_HOME/state/.wake-queue"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\n' "$FM_QUEUE_REASON"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    queue_kind=$kind
    [ "$queue_kind" = x ] && queue_kind=check
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_QUEUE_KIND="$queue_kind" FM_QUEUE_KEY="$key" FM_QUEUE_REASON="$reason" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let idle = false;
const prompts = [];
const options = [];
const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage(message, deliveryOptions) {
    prompts.push(message);
    options.push(deliveryOptions);
  },
};
const context = { isIdle: () => idle };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({}, context);
await tool.execute("tool-call-current-kind", {}, undefined, undefined, context);
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (prompts.length !== 0) throw new Error(`busy Pi received a premature wake: ${prompts.join(" | ")}`);
const queueBefore = readFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "utf8");
idle = true;
await handlers.get("agent_settled")?.({}, context);
for (let i = 0; i < 250 && prompts.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await handlers.get("agent_settled")?.({}, context);
if (prompts.length !== 1) throw new Error(`expected one idle-boundary wake, got ${prompts.length}: ${prompts.join(" | ")}`);
if (!prompts[0].includes(process.env.FM_QUEUE_REASON)) throw new Error(`wake lost its current reason: ${prompts[0]}`);
if (options[0] !== undefined) throw new Error(`wake used queued delivery instead of immediate idle delivery: ${JSON.stringify(options[0])}`);
const queueAfter = readFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "utf8");
if (queueAfter !== queueBefore) throw new Error("Pi validation mutated the durable queue");
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
    status=$?
    expect_code 0 "$status" "Pi must deliver one still-current $kind wake at the idle boundary"
    [ -z "$out" ] || fail "Pi current-$kind test printed output: $out"
  done
  pass "Pi delivers current stale, signal, check, heartbeat, and X wakes exactly once at the idle boundary"
}

test_opencode_primary_watch_plugin_static_wiring() {
  local plugin module_boundary text
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  module_boundary="$ROOT/.opencode/plugins/package.json"
  assert_present "$plugin" "OpenCode primary watch plugin missing"
  assert_present "$module_boundary" "OpenCode plugin ESM package boundary missing"
  assert_contains "$(cat "$module_boundary")" '"type": "module"' "OpenCode plugin package boundary is not explicitly ESM"
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

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must import beneath an explicit ESM package boundary"
  [ -z "$out" ] || fail "OpenCode ESM boundary import printed output: $out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
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
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
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
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
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
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
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
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let rowsAtPrompt = 0;
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const client = {
  session: {
    promptAsync: async () => {
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      prompts += 1;
      await promptBlocked;
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
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts >= 1) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`single-flight violation launched ${stableRows.length} arms`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
releasePrompt();
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must start one successor before wake prompt delivery settles: $out"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts.some((message) => message.includes("original wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`pre-ready successor was replaced before its close: ${rows.join(" | ")}`);
if (!prompts.some((message) => message.includes("original wake"))) throw new Error(`original actionable wake was not delivered: ${prompts.join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, 150));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  const successorRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (successorRows.length >= 3 && prompts.some((message) => message.includes("pre-ready successor wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 3) throw new Error(`pre-ready close did not create exactly one successor: ${stableRows.join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retire the pre-ready arm, not its actionable successor"
  [ -z "$out" ] || fail "OpenCode pre-ready actionable test printed output: $out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "OpenCode hung-successor test printed output: $out"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "OpenCode unretired-successor test printed output: $out"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log ready retired release stop out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    retired="$TMP_ROOT/opencode-late-$kind.retired"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "OpenCode late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "OpenCode late-$kind test printed output: $out"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
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
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OpenCode empty-close retry test printed output: $out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "OpenCode established-empty-close retry test printed output: $out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode close handler must verify session-lock ownership before successor launch"
  [ -z "$out" ] || fail "OpenCode close lock test printed output: $out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
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
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
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
for (let i = 0; i < 250 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
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
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_pi_cleanup_during_successor_restore_suppresses_stale_wakes
test_wake_actionability_helper_source_and_queue_matrix
test_pi_current_wake_kinds_deliver_once_at_idle
test_opencode_primary_watch_plugin_static_wiring
test_opencode_plugin_package_boundary_is_explicit_esm
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_pre_ready_actionable_close_preserves_its_successor
test_opencode_hung_successor_falls_back_to_typed_wake
test_opencode_unretired_successor_falls_back_without_retry
test_opencode_late_unretired_close_resumes_supervision
test_opencode_empty_close_retries_instead_of_disappearing
test_opencode_established_empty_close_honors_retry_limit
test_opencode_actionable_close_rechecks_session_lock
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
