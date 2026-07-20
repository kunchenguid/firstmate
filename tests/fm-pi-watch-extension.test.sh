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
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/typebox" "$repo/bin"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/bin/fm-primary-scope.sh" "$repo/bin/fm-primary-scope.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$repo/bin/fm-primary-scope-lib.sh"
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
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}
lock="$state/.lock"
mkdir -p "$state"
classify() {
  if [ "${FM_LOCK_FIXTURE_MODE:-}" = changed ] && [ -f "$state/.fixture-ownership-changed" ]; then
    printf 'other\n'
    return
  fi
  if [ "${FM_LOCK_FIXTURE_MODE:-}" = failure ] || [ "${FM_LOCK_FIXTURE_MODE:-}" = changed ]; then
    printf 'missing\n'
    return
  fi
  if [ "${FM_LOCK_FIXTURE_MODE:-}" = other ]; then
    printf 'other\n'
    return
  fi
  if [ ! -e "$lock" ]; then printf 'missing\n'; return; fi
  value=$(cat "$lock" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*|1) printf 'malformed\n'; return ;; esac
  if [ "$value" = "$PPID" ]; then printf 'owned\n'; return; fi
  if kill -0 "$value" 2>/dev/null; then printf 'other\n'; else printf 'dead\n'; fi
}
if [ "${1:-}" = "ownership" ]; then classify; exit 0; fi
[ -z "${FM_LOCK_ACQUIRE_LOG:-}" ] || printf 'acquire\n' >> "$FM_LOCK_ACQUIRE_LOG"
if [ "${FM_LOCK_FIXTURE_MODE:-}" = failure ]; then
  printf 'fixture acquisition failed\n' >&2
  exit 1
fi
if [ "${FM_LOCK_FIXTURE_MODE:-}" = changed ]; then
  : > "$state/.fixture-ownership-changed"
  printf 'fixture acquisition lost\n' >&2
  exit 1
fi
state_name=$(classify)
case "$state_name" in
  owned) ;;
  missing|dead) printf '%s\n' "$PPID" > "$lock" ;;
  *) printf 'error: fixture lock refused: %s\n' "$state_name" >&2; exit 1 ;;
esac
printf 'lock acquired: harness pid %s\n' "$PPID"
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-primary-scope.sh"
}

install_real_lock_owner() {
  local repo=$1
  cp "$ROOT/bin/fm-lock.sh" "$repo/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$repo/bin/fm-wake-lib.sh"
  chmod +x "$repo/bin/fm-lock.sh"
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
  assert_contains "$text" "deliverAs: \"followUp\"" "tracked extension missing followUp delivery"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" "const lockScript = \`\${fmRoot}/bin/fm-lock.sh\`" "tracked extension does not resolve the production lock owner"
  assert_contains "$text" "const scopeScript = \`\${fmRoot}/bin/fm-primary-scope.sh\`" "tracked extension does not resolve the shared primary scope owner"
  assert_contains "$text" 'FM_ROOT_OVERRIDE: root' "tracked extension does not scope the extension checkout independently of inherited supervisor paths"
  assert_contains "$text" 'if (!primaryHome)' "tracked extension does not fail closed outside a primary home"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "dead" | "other" | "malformed" | "unknown"' "tracked extension does not preserve the lock owner states"
  assert_contains "$text" 'type SessionLockPolicy = "defer" | "recover" | "owned-only"' "tracked extension does not define explicit session lock policies"
  assert_contains "$text" 'spawnSync(lockScript, ["ownership"]' "tracked extension does not use the lock owner's read-only API"
  assert_contains "$text" 'if (ownership === "missing" || ownership === "dead")' "tracked extension does not restrict acquisition to reclaimable states"
  assert_contains "$text" 'case "fork":' "tracked extension does not classify Pi fork lifecycle events"
  assert_contains "$text" 'case "reload":' "tracked extension does not classify Pi reload lifecycle events"
  assert_contains "$text" 'startArm(activeSessionLockPolicy)' "tracked extension does not carry session lock policy into every arm"
  assert_contains "$text" 'launchArm(activeSessionLockPolicy, predecessorArmPid)' "tracked extension does not carry session lock policy into successor arms"
  assert_not_contains "$text" 'lockPolicy: SessionLockPolicy = "recover"' "tracked extension still has an implicit recover policy"
  assert_contains "$text" 'if (ready && lockPolicy === "defer" && activeSessionLockPolicy === "defer")' "tracked extension does not promote startup deferral from shared verified readiness"
  assert_contains "$text" 'const acquisition = spawnSync(lockScript, []' "tracked extension does not route acquisition through the production owner"
  assert_contains "$text" 'if (ownership !== "owned")' "tracked extension arms without re-reading owned state"
  assert_contains "$text" 'lock ownership changed during resume' "tracked extension does not distinguish a lost acquisition race"
  assert_contains "$text" 'a verified live firstmate session owns this home' "tracked extension does not distinguish a verified competitor"
  assert_contains "$text" 'lock acquisition failed' "tracked extension does not distinguish acquisition failure"
  assert_contains "$text" 'const verified = await waitForStartResult(armChild);' "tracked extension does not await verified arm readiness"
  assert_contains "$text" 'awayMonitor = setInterval(awayMonitorListener, 50)' "tracked extension does not poll the away flag directly"
  assert_contains "$text" 'handleAwayMonitorFailure(error);' "tracked extension does not fail closed on away-monitor errors"
  assert_contains "$text" 'scheduleAwayMonitorRetry();' "tracked extension does not retry away-monitor setup failures"
  assert_contains "$text" 'awayMonitorRetryDelayMs = Math.min(awayMonitorRetryDelayMs * 2, 30000)' "tracked extension does not cap exponential monitor retry backoff"
  assert_contains "$text" 'const primaryHome = isPrimaryHome();' "tracked extension does not cache invariant primary scope"
  assert_contains "$text" 'if (!awayMonitor)' "tracked extension can arm before away-mode monitoring is active"
  assert_contains "$text" 'if (!awayMonitor || existsSync(awayFlag)) return;' "tracked extension can still route a wake without confirmed normal-mode ownership"
  assert_contains "$text" 'await sendWakeSafely' "tracked extension does not contain rejected Pi wake delivery"
  assert_contains "$text" 'sub-supervisor owns supervision' "tracked extension does not report away-mode ownership"
  assert_not_contains "$text" 'function parentPid' "tracked extension kept a duplicate ancestry classifier"
  assert_not_contains "$text" 'function pidAlive' "tracked extension kept a duplicate holder-liveness classifier"
  assert_not_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension still classifies lock bytes itself"
  assert_contains "$text" 'FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid' "tracked extension does not link successor watcher cycles"
  assert_contains "$text" 'restoreAfterActionableClose' "tracked extension does not restore continuity before delivering actionable wakes"
  assert_contains "$text" 'scheduleRetry' "tracked extension does not retry unexpected watcher exits"
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
if (!notification.includes("external healthy watcher")) {
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
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
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

test_pi_tool_waits_for_verified_readiness() {
  local repo home plugin started release out status
  repo="$TMP_ROOT/pi-tool-readiness-root"
  home="$TMP_ROOT/pi-tool-readiness-home"
  started="$TMP_ROOT/pi-tool-readiness-started"
  release="$TMP_ROOT/pi-tool-readiness-release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_READINESS_STARTED:?}"
while [ ! -f "${FM_READINESS_RELEASE:?}" ]; do sleep 0.01; done
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_READINESS_STARTED="$started" FM_READINESS_RELEASE="$release" node --input-type=module 2>&1 <<'EOF'
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
let resolved = false;
const pending = tool.execute("tool-readiness", {}, undefined, undefined, {}).then((result) => {
  resolved = true;
  return result;
});
for (let i = 0; i < 100 && !existsSync(process.env.FM_READINESS_STARTED); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_READINESS_STARTED)) throw new Error("arm child did not reach the readiness boundary");
await new Promise((resolve) => setTimeout(resolve, 50));
if (resolved) throw new Error("Pi tool returned before watcher readiness was verified");
writeFileSync(process.env.FM_READINESS_RELEASE, "ready\n");
const result = await pending;
if (result.details?.ok !== true || !result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected readiness result: ${JSON.stringify(result)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must wait for verified watcher readiness"
  [ -z "$out" ] || fail "Pi tool-readiness test printed output: $out"
  pass "Pi custom tool waits for verified watcher readiness"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS=1000 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
const initial = await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
if (initial.details?.ok !== true) throw new Error(`initial arm failed: ${initial.details?.message}`);
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
  [ "$status" -eq 0 ] || fail "Pi must deliver the actionable wake after bounded hung-successor recovery: $out"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS=1000 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
const initial = await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
if (initial.details?.ok !== true) throw new Error(`initial arm failed: ${initial.details?.message}`);
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
  [ "$status" -eq 0 ] || fail "Pi must fall back without overlapping an unretired successor: $out"
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
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS=1000 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
    [ "$status" -eq 0 ] || fail "Pi late $kind close must remain supervised after fallback: $out"
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
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
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
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
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

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - a verified live firstmate session owns this home") {
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
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi watcher arm must distinguish owned and live-other session locks: $out"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm preserves the owned and live-other distinction"
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
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
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

test_pi_extension_transfers_active_arm_on_away_entry() {
  local repo home plugin arm_log stop_log out status
  repo="$TMP_ROOT/pi-away-transfer-root"
  home="$TMP_ROOT/pi-away-transfer-home"
  arm_log="$TMP_ROOT/pi-away-transfer-arm.log"
  stop_log="$TMP_ROOT/pi-away-transfer-stop.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
trap 'printf "stopped\n" >> "$FM_STOP_LOG"; exit 0' TERM INT
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_STOP_LOG="$stop_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
let tool = null;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, { ui: { notify() {} } });
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial Pi session did not arm supervision");
const pending = `${process.env.FM_HOME}/state/.afk.pending`;
writeFileSync(pending, "away\n");
renameSync(pending, `${process.env.FM_HOME}/state/.afk`);
for (let i = 0; i < 100 && !existsSync(process.env.FM_STOP_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_STOP_LOG)) throw new Error("away entry did not stop the extension-owned arm child");
await new Promise((resolve) => setTimeout(resolve, 50));
if (prompts.length > 0) throw new Error(`away transfer routed a wake directly into Pi: ${prompts.join(" | ")}`);
const away = await tool.execute("away-transfer-idempotence", {}, undefined, undefined, {});
if (away.details?.ok !== true || !away.content[0].text.includes("sub-supervisor owns supervision")) {
  throw new Error(`away ownership was not preserved: ${JSON.stringify(away)}`);
}
const armCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (armCount !== 1) throw new Error(`away entry started ${armCount} arm children`);
unlinkSync(`${process.env.FM_HOME}/state/.afk`);
for (let i = 0; i < 100; i += 1) {
  const count = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
  if (count === 2) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const restoredCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (restoredCount !== 2) throw new Error(`away rollback left ${restoredCount} arm children instead of restoring one`);
if (prompts.length > 0) throw new Error(`away rollback emitted an unexpected Pi wake: ${prompts.join(" | ")}`);
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher must transfer an active arm to away-mode supervision"
  [ -z "$out" ] || fail "Pi away-transfer test printed output: $out"
  pass "Pi watcher transfers its active arm and restores rollback supervision"
}

test_pi_extension_fails_closed_and_retries_away_monitor() {
  local scenario repo home plugin arm_log stop_log fail_flag scope_log attempts_log fail_second out status
  for scenario in failure retry runtime delivery; do
    repo="$TMP_ROOT/pi-away-monitor-$scenario-root"
    home="$TMP_ROOT/pi-away-monitor-$scenario-home"
    arm_log="$TMP_ROOT/pi-away-monitor-$scenario-arm.log"
    stop_log="$TMP_ROOT/pi-away-monitor-$scenario-stop.log"
    fail_flag="$TMP_ROOT/pi-away-monitor-$scenario-fail"
    scope_log="$TMP_ROOT/pi-away-monitor-$scenario-scope.log"
    attempts_log="$TMP_ROOT/pi-away-monitor-$scenario-attempts.log"
    fail_second=0
    [ "$scenario" = delivery ] && fail_second=1
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    mv "$repo/bin/fm-primary-scope.sh" "$repo/bin/fm-primary-scope-real.sh"
    cat > "$repo/bin/fm-primary-scope.sh" <<'SH'
#!/usr/bin/env bash
printf 'scope\n' >> "${FM_SCOPE_LOG:?}"
exec "$(dirname "$0")/fm-primary-scope-real.sh"
SH
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d ' ')
if [ "${FM_FAIL_SECOND_ARM:-0}" = 1 ] && [ "$count" -gt 1 ]; then exit 9; fi
trap 'printf "stopped\n" >> "$FM_STOP_LOG"; exit 0' TERM INT
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while :; do sleep 1; done
SH
    chmod +x "$repo/bin/fm-primary-scope.sh" "$repo/bin/fm-watch-arm.sh"
    out=$(CASE="$scenario" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_STOP_LOG="$stop_log" FM_MONITOR_FAIL="$fail_flag" FM_SCOPE_LOG="$scope_log" FM_MONITOR_ATTEMPTS="$attempts_log" FM_FAIL_SECOND_ARM="$fail_second" node --input-type=module 2>&1 <<'EOF'
import fs, { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

const originalStatSync = fs.statSync;
let attempts = 0;
fs.statSync = (...args) => {
  attempts += 1;
  writeFileSync(process.env.FM_MONITOR_ATTEMPTS, `${Date.now()}\n`, { flag: "a" });
  if (process.env.CASE === "failure" || (process.env.CASE === "retry" && attempts === 1)) {
    throw Object.assign(new Error("fixture monitor failure"), { code: "EIO" });
  }
  if (["runtime", "delivery"].includes(process.env.CASE) && existsSync(process.env.FM_MONITOR_FAIL)) {
    throw Object.assign(new Error("fixture runtime monitor failure"), { code: "EIO" });
  }
  return originalStatSync(...args);
};
syncBuiltinESMExports();

const handlers = new Map();
const notifications = [];
const prompts = [];
const unhandled = [];
process.on("unhandledRejection", (error) => {
  unhandled.push(error);
});
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async (message) => {
    if (process.env.CASE === "delivery") throw new Error("fixture delivery rejection");
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
if (!["runtime", "delivery"].includes(process.env.CASE) && existsSync(marker)) {
  throw new Error("extension advertised loaded before away monitoring was active");
}
if (["runtime", "delivery"].includes(process.env.CASE) && !existsSync(marker)) {
  throw new Error("runtime monitor fixture did not start healthy");
}
if (process.env.CASE === "retry") {
  for (let i = 0; i < 100 && !existsSync(marker); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(marker)) throw new Error("away monitor setup was not retried");
}
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
if (process.env.CASE === "failure") {
  await new Promise((resolve) => setTimeout(resolve, 900));
  if (existsSync(marker) || existsSync(process.env.FM_ARM_LOG)) {
    throw new Error("monitor failure advertised or armed the Pi watcher");
  }
  if (!notifications.some((message) => message.includes("away-mode state monitor unavailable"))) {
    throw new Error(`monitor failure was not reported: ${notifications.join(" | ")}`);
  }
  const monitorAttempts = readFileSync(process.env.FM_MONITOR_ATTEMPTS, "utf8").trim().split(/\n/).length;
  if (monitorAttempts > 4) throw new Error(`persistent monitor failure retried ${monitorAttempts} times without backoff`);
} else if (process.env.CASE === "retry") {
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("recovered away monitor did not permit watcher arming");
  if (notifications.length > 0) throw new Error(`monitor retry notified unexpectedly: ${notifications.join(" | ")}`);
} else if (process.env.CASE === "runtime") {
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("runtime monitor fixture did not arm supervision");
  writeFileSync(process.env.FM_MONITOR_FAIL, "fail\n");
  writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
  for (let i = 0; i < 100 && !existsSync(process.env.FM_STOP_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_STOP_LOG)) throw new Error("runtime monitor failure did not stop the active arm");
  if (prompts.length > 0) throw new Error(`runtime monitor failure routed a wake into Pi: ${prompts.join(" | ")}`);
} else {
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("delivery fixture did not arm supervision");
  writeFileSync(process.env.FM_MONITOR_FAIL, "fail\n");
  for (let i = 0; i < 100 && !existsSync(process.env.FM_STOP_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_STOP_LOG)) throw new Error("delivery fixture did not enter monitor recovery");
  unlinkSync(process.env.FM_MONITOR_FAIL);
  for (let i = 0; i < 100; i += 1) {
    const count = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
    if (count === 2) break;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const deliveryArmCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
  if (deliveryArmCount !== 2) throw new Error(`delivery recovery made ${deliveryArmCount} arm attempts`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  if (unhandled.length > 0) throw new Error(`monitor recovery leaked an unhandled rejection: ${unhandled.join(" | ")}`);
}
const scopeCount = readFileSync(process.env.FM_SCOPE_LOG, "utf8").trim().split(/\n/).length;
if (scopeCount !== 1) throw new Error(`away-monitor recovery rechecked primary scope ${scopeCount} times`);
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
    )
    status=$?
    expect_code 0 "$status" "Pi watcher must handle away-monitor $scenario fail closed"
    [ -z "$out" ] || fail "Pi away-monitor $scenario test printed output: $out"
  done
  pass "Pi watcher contains delivery rejection and backs off monitor failures"
}

test_pi_resume_session_recovers_only_reclaimable_locks() {
  local scenario repo home plugin fakebin arm_log other_pid out status
  for scenario in missing dead other owned away; do
    repo="$TMP_ROOT/pi-resume-$scenario-root"
    home="$TMP_ROOT/pi-resume-$scenario-home"
    fakebin="$TMP_ROOT/pi-resume-$scenario-fakebin"
    arm_log="$TMP_ROOT/pi-resume-$scenario-arm.log"
    mkdir -p "$home/state" "$home/config" "$fakebin"
    install_pi_watch_extension_fixture "$repo"
    install_real_lock_owner "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then pid=$argument; break; fi
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_FAKE_PI_PID:-}" ] || [ "$pid" = "${FM_FAKE_OTHER_PID:-}" ]; then
      printf '/opt/homebrew/bin/pi\n'
    else
      printf '/bin/bash\n'
    fi
    ;;
  *"args="*)
    if [ "$pid" = "${FM_FAKE_PI_PID:-}" ] || [ "$pid" = "${FM_FAKE_OTHER_PID:-}" ]; then
      printf 'pi\n'
    else
      printf 'bash fm-lock.sh\n'
    fi
    ;;
  *"ppid="*)
    if [ "$pid" = "${FM_FAKE_PI_PID:-}" ] || [ "$pid" = "${FM_FAKE_OTHER_PID:-}" ]; then
      printf '1\n'
    else
      printf '%s\n' "${FM_FAKE_PI_PID:-1}"
    fi
    ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$fakebin/ps"

    other_pid=
    if [ "$scenario" = other ]; then
      sleep 300 &
      other_pid=$!
    fi
    status=0
    out=$(CASE="$scenario" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_FAKE_OTHER_PID="$other_pid" PATH="$fakebin:$PATH" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.env.FM_FAKE_PI_PID = String(process.pid);
const lock = `${process.env.FM_HOME}/state/.lock`;
if (process.env.CASE === "dead") writeFileSync(lock, "999999\n");
if (process.env.CASE === "away") {
  writeFileSync(lock, "999999\n");
  writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
}
if (process.env.CASE === "other") writeFileSync(lock, `${process.env.FM_FAKE_OTHER_PID}\n`);
if (process.env.CASE === "owned") writeFileSync(lock, `${process.pid}\n`);
const before = existsSync(lock) ? readFileSync(lock) : null;

const handlers = new Map();
let tool = null;
const notifications = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const sessionStart = handlers.get("session_start");
if (!sessionStart) throw new Error("session_start handler was not registered");
await sessionStart({ type: "session_start", reason: "resume" }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
for (let i = 0; i < 100; i += 1) {
  const observable = process.env.CASE === "other"
    ? notifications.length > 0
    : process.env.CASE === "away"
      ? readFileSync(lock, "utf8").trim() === String(process.pid)
      : existsSync(process.env.FM_ARM_LOG);
  if (observable) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}

if (process.env.CASE === "other") {
  const after = readFileSync(lock);
  if (!before?.equals(after)) throw new Error("live-other lock bytes changed");
  if (existsSync(process.env.FM_ARM_LOG)) throw new Error("live-other session armed the watcher");
  if (!notifications.some((message) => message.includes("verified live"))) {
    throw new Error(`live-other refusal was not explicit: ${notifications.join(" | ")}`);
  }
} else if (process.env.CASE === "away") {
  const acquired = readFileSync(lock, "utf8").trim();
  if (acquired !== String(process.pid)) throw new Error(`away resume lock owner is ${acquired}, expected ${process.pid}`);
  if (existsSync(process.env.FM_ARM_LOG)) throw new Error("away resume restarted the watcher");
  if (notifications.length > 0) throw new Error(`away resume notified unexpectedly: ${notifications.join(" | ")}`);
} else {
  const acquired = readFileSync(lock, "utf8").trim();
  if (acquired !== String(process.pid)) throw new Error(`resume lock owner is ${acquired}, expected ${process.pid}`);
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.CASE} resume did not arm the watcher`);
  if (process.env.CASE === "owned") {
    const result = await tool.execute("owned-idempotence", {}, undefined, undefined, {});
    if (!result.content[0].text.includes("already has an arm child")) {
      throw new Error(`owned re-arm was not idempotent: ${result.content[0].text}`);
    }
    const armCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
    if (armCount !== 1) throw new Error(`owned session started ${armCount} arm children`);
  }
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
    ) || status=$?
    if [ -n "$other_pid" ]; then
      kill "$other_pid" 2>/dev/null || true
      wait "$other_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
      fail "Pi resume integration failed for the $scenario lock state: $out"
    fi
    [ -z "$out" ] || fail "Pi resume $scenario integration printed output: $out"
  done
  pass "Pi session_start reclaims safe locks, preserves away ownership, refuses live other, and idempotently arms"
}

test_pi_session_start_load_order_preserves_initial_nudge() {
  local reason order repo home watch_plugin turnend_plugin arm_log out status
  for reason in startup new resume; do
    for order in watch-first nudge-first; do
      repo="$TMP_ROOT/pi-session-order-$reason-$order-root"
      home="$TMP_ROOT/pi-session-order-$reason-$order-home"
      arm_log="$TMP_ROOT/pi-session-order-$reason-$order-arm.log"
      mkdir -p "$home/state" "$home/config"
      install_pi_watch_extension_fixture "$repo"
      watch_plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      turnend_plugin="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
      cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$turnend_plugin"
      cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$repo/bin/fm-sessionstart-nudge.sh"
      cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$repo/bin/fm-gate-refuse-lib.sh"
      chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
      cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
      chmod +x "$repo/bin/fm-watch-arm.sh"
      status=0
      out=$(REASON="$reason" ORDER="$order" WATCH_PLUGIN="$watch_plugin" TURNEND_PLUGIN="$turnend_plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const messages = [];
const notifications = [];
const pi = {
  on(event, handler) {
    const eventHandlers = handlers.get(event) || [];
    eventHandlers.push(handler);
    handlers.set(event, eventHandlers);
  },
  registerCommand() {},
  registerTool() {},
  sendMessage(message) {
    messages.push(message);
  },
  sendUserMessage: async () => {},
};
const plugins = process.env.ORDER === "watch-first"
  ? [process.env.WATCH_PLUGIN, process.env.TURNEND_PLUGIN]
  : [process.env.TURNEND_PLUGIN, process.env.WATCH_PLUGIN];
for (const plugin of plugins) {
  const mod = await import(pathToFileURL(plugin).href);
  mod.default(pi);
}
for (const handler of handlers.get("session_start") || []) {
  await handler({ type: "session_start", reason: process.env.REASON }, {
    ui: {
      notify(message) {
        notifications.push(message);
      },
    },
  });
}

const lock = `${process.env.FM_HOME}/state/.lock`;
if (["startup", "new"].includes(process.env.REASON)) {
  if (messages.length !== 1 || !messages[0]?.content?.includes("bin/fm-session-start.sh")) {
    throw new Error(`${process.env.REASON}/${process.env.ORDER} lost the session-start nudge: ${JSON.stringify(messages)}`);
  }
  if (existsSync(lock)) throw new Error(`${process.env.REASON}/${process.env.ORDER} acquired the lock before session start`);
  if (existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.REASON}/${process.env.ORDER} armed before session start`);
  if (notifications.length > 0) throw new Error(`${process.env.REASON}/${process.env.ORDER} notified unexpectedly: ${notifications.join(" | ")}`);
} else {
  for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (readFileSync(lock, "utf8").trim() !== String(process.pid)) {
    throw new Error(`${process.env.ORDER} resume did not recover owned lock state`);
  }
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.ORDER} resume did not arm supervision`);
  if (messages.some((message) => !message?.content?.includes("bin/fm-session-start.sh"))) {
    throw new Error(`${process.env.ORDER} resume injected an unexpected message: ${JSON.stringify(messages)}`);
  }
  if (notifications.length > 0) throw new Error(`${process.env.ORDER} resume notified unexpectedly: ${notifications.join(" | ")}`);
}
for (const handler of handlers.get("session_shutdown") || []) {
  await handler({ type: "session_shutdown" }, {});
}
EOF
      ) || status=$?
      expect_code 0 "$status" "Pi $reason session_start must respect $order extension ordering"
      [ -z "$out" ] || fail "Pi $reason/$order load-order test printed output: $out"
    done
  done
  pass "Pi startup and new preserve the nudge while resume recovers in either extension order"
}

test_pi_fork_reload_rebuilds_only_owned_supervision() {
  local reason scenario repo home plugin arm_log acquire_log other_pid out status
  for reason in fork reload; do
    for scenario in owned missing dead other malformed; do
      repo="$TMP_ROOT/pi-$reason-$scenario-root"
      home="$TMP_ROOT/pi-$reason-$scenario-home"
      arm_log="$TMP_ROOT/pi-$reason-$scenario-arm.log"
      acquire_log="$TMP_ROOT/pi-$reason-$scenario-acquire.log"
      mkdir -p "$home/state" "$home/config"
      install_pi_watch_extension_fixture "$repo"
      plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
      chmod +x "$repo/bin/fm-watch-arm.sh"
      other_pid=
      if [ "$scenario" = other ]; then
        sleep 300 &
        other_pid=$!
      fi
      status=0
      out=$(REASON="$reason" CASE="$scenario" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_LOCK_ACQUIRE_LOG="$acquire_log" FM_OTHER_PID="$other_pid" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const lock = `${process.env.FM_HOME}/state/.lock`;
if (process.env.CASE === "owned") writeFileSync(lock, `${process.pid}\n`);
if (process.env.CASE === "dead") writeFileSync(lock, "999999\n");
if (process.env.CASE === "other") writeFileSync(lock, `${process.env.FM_OTHER_PID}\n`);
if (process.env.CASE === "malformed") writeFileSync(lock, "not-a-pid\n");
const before = existsSync(lock) ? readFileSync(lock) : null;
const handlers = new Map();
const notifications = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: process.env.REASON }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});

const after = existsSync(lock) ? readFileSync(lock) : null;
if (before === null ? after !== null : after === null || !before.equals(after)) {
  throw new Error(`${process.env.REASON}/${process.env.CASE} changed lock bytes`);
}
if (process.env.CASE === "owned") {
  for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.REASON} did not rebuild owned supervision`);
  if (notifications.length > 0) throw new Error(`${process.env.REASON} owned rebuild notified unexpectedly: ${notifications.join(" | ")}`);
} else {
  if (existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.REASON}/${process.env.CASE} armed without ownership`);
  const expected = ["missing", "dead"].includes(process.env.CASE)
    ? `existing session-lock ownership required (state: ${process.env.CASE})`
    : process.env.CASE === "other"
      ? "verified live firstmate session owns this home"
      : "session lock is malformed";
  if (!notifications.some((message) => message.includes(expected))) {
    throw new Error(`${process.env.REASON}/${process.env.CASE} did not fail closed: ${notifications.join(" | ")}`);
  }
}
if (existsSync(process.env.FM_LOCK_ACQUIRE_LOG)) {
  throw new Error(`${process.env.REASON}/${process.env.CASE} invoked lock acquisition`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
      ) || status=$?
      if [ -n "$other_pid" ]; then
        kill "$other_pid" 2>/dev/null || true
        wait "$other_pid" 2>/dev/null || true
      fi
      expect_code 0 "$status" "Pi $reason must rebuild only an owned $scenario lock state"
      [ -z "$out" ] || fail "Pi $reason/$scenario owned-only test printed output: $out"
    done
  done
  pass "Pi fork and reload rebuild only with existing lock ownership"
}

test_pi_fork_reload_policy_survives_every_rearm_path() {
  local reason entrypoint repo home plugin arm_log acquire_log release closed out status
  for reason in fork reload; do
    for entrypoint in actionable retry command tool; do
      repo="$TMP_ROOT/pi-$reason-$entrypoint-policy-root"
      home="$TMP_ROOT/pi-$reason-$entrypoint-policy-home"
      arm_log="$TMP_ROOT/pi-$reason-$entrypoint-policy-arm.log"
      acquire_log="$TMP_ROOT/pi-$reason-$entrypoint-policy-acquire.log"
      release="$TMP_ROOT/pi-$reason-$entrypoint-policy-release"
      closed="$TMP_ROOT/pi-$reason-$entrypoint-policy-closed"
      mkdir -p "$home/state" "$home/config"
      install_pi_watch_extension_fixture "$repo"
      plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
case "${FM_REARM_ENTRYPOINT:?}" in
  actionable)
    while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.01; done
    printf 'signal: policy loss\n'
    ;;
  retry)
    while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.01; done
    printf 'closed\n' > "$FM_CLOSED_FILE"
    exit 9
    ;;
  command|tool)
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
esac
SH
      chmod +x "$repo/bin/fm-watch-arm.sh"
      status=0
      out=$(REASON="$reason" ENTRYPOINT="$entrypoint" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_LOCK_ACQUIRE_LOG="$acquire_log" FM_RELEASE_FILE="$release" FM_CLOSED_FILE="$closed" FM_REARM_ENTRYPOINT="$entrypoint" FM_WATCH_REARM_RETRY_BASE_MS=1000 FM_WATCH_REARM_RETRY_MAX_MS=1000 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const handlers = new Map();
const notifications = [];
const prompts = [];
let command = null;
let tool = null;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") command = options;
  },
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: process.env.REASON }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
if (!command || !tool) throw new Error("public arm entrypoints were not registered");
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.REASON} initial owned arm did not start`);

const loss = ["actionable", "command"].includes(process.env.ENTRYPOINT) ? "missing" : "dead";
if (process.env.ENTRYPOINT === "retry") {
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  for (let i = 0; i < 100 && !existsSync(process.env.FM_CLOSED_FILE); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_CLOSED_FILE)) throw new Error("retry arm did not close");
  await new Promise((resolve) => setTimeout(resolve, 300));
}
if (loss === "missing") unlinkSync(lock); else writeFileSync(lock, "999999\n");

let toolResult = null;
if (process.env.ENTRYPOINT === "actionable") writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
if (process.env.ENTRYPOINT === "command") {
  await command.handler("", {
    ui: {
      notify(message) {
        notifications.push(message);
      },
    },
  });
}
if (process.env.ENTRYPOINT === "tool") {
  toolResult = await tool.execute("policy-loss", {}, undefined, undefined, {});
}

for (let i = 0; i < 150; i += 1) {
  const surfaced = process.env.ENTRYPOINT === "tool"
    ? toolResult?.details?.ok === false
    : process.env.ENTRYPOINT === "command"
      ? notifications.some((message) => message.includes(`state: ${loss}`))
      : prompts.some((message) => message.includes(`state: ${loss}`));
  if (surfaced) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const surfaced = process.env.ENTRYPOINT === "tool"
  ? toolResult?.content?.[0]?.text || ""
  : process.env.ENTRYPOINT === "command"
    ? notifications.join(" | ")
    : prompts.join(" | ");
if (!surfaced.includes(`existing session-lock ownership required (state: ${loss})`)) {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} did not preserve owned-only policy: ${surfaced}`);
}
const armCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (armCount !== 1) throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} launched ${armCount} arms`);
if (existsSync(process.env.FM_LOCK_ACQUIRE_LOG)) {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} invoked lock acquisition`);
}
if (loss === "missing") {
  if (existsSync(lock)) throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} recreated a missing lock`);
} else if (readFileSync(lock, "utf8").trim() !== "999999") {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} replaced a dead lock`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
      ) || status=$?
      expect_code 0 "$status" "Pi $reason must retain owned-only policy through $entrypoint"
      [ -z "$out" ] || fail "Pi $reason/$entrypoint policy-path test printed output: $out"
    done
  done
  pass "Pi fork and reload retain owned-only policy across every re-arm path"
}

test_pi_startup_policy_promotes_after_first_arm() {
  local reason entrypoint repo home plugin arm_log acquire_log release closed stop_log monitor_fail out status
  for reason in startup new; do
    for entrypoint in retry away monitor command tool; do
      repo="$TMP_ROOT/pi-$reason-$entrypoint-promote-root"
      home="$TMP_ROOT/pi-$reason-$entrypoint-promote-home"
      arm_log="$TMP_ROOT/pi-$reason-$entrypoint-promote-arm.log"
      acquire_log="$TMP_ROOT/pi-$reason-$entrypoint-promote-acquire.log"
      release="$TMP_ROOT/pi-$reason-$entrypoint-promote-release"
      closed="$TMP_ROOT/pi-$reason-$entrypoint-promote-closed"
      stop_log="$TMP_ROOT/pi-$reason-$entrypoint-promote-stop.log"
      monitor_fail="$TMP_ROOT/pi-$reason-$entrypoint-promote-monitor-fail"
      mkdir -p "$home/state" "$home/config"
      install_pi_watch_extension_fixture "$repo"
      plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "${FM_REARM_ENTRYPOINT:?}" = retry ]; then
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.01; done
  printf 'closed\n' > "$FM_CLOSED_FILE"
  exit 9
fi
trap 'printf "stopped\n" >> "$FM_STOP_LOG"; exit 0' TERM INT
while :; do sleep 1; done
SH
      chmod +x "$repo/bin/fm-watch-arm.sh"
      status=0
      out=$(REASON="$reason" ENTRYPOINT="$entrypoint" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_LOCK_ACQUIRE_LOG="$acquire_log" FM_RELEASE_FILE="$release" FM_CLOSED_FILE="$closed" FM_STOP_LOG="$stop_log" FM_MONITOR_FAIL="$monitor_fail" FM_REARM_ENTRYPOINT="$entrypoint" FM_WATCH_REARM_RETRY_BASE_MS=1000 FM_WATCH_REARM_RETRY_MAX_MS=1000 node --input-type=module 2>&1 <<'EOF'
import fs, { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

const originalStatSync = fs.statSync;
fs.statSync = (...args) => {
  if (process.env.ENTRYPOINT === "monitor" && existsSync(process.env.FM_MONITOR_FAIL)) {
    throw Object.assign(new Error("fixture monitor failure"), { code: "EIO" });
  }
  return originalStatSync(...args);
};
syncBuiltinESMExports();

const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const handlers = new Map();
const notifications = [];
const prompts = [];
let command = null;
let tool = null;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") command = options;
  },
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: process.env.REASON }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
if (!command || !tool) throw new Error("public arm entrypoints were not registered");
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error(`${process.env.REASON} initial owned arm did not start`);

const loss = ["retry", "away", "command"].includes(process.env.ENTRYPOINT) ? "missing" : "dead";
if (process.env.ENTRYPOINT === "retry") {
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  for (let i = 0; i < 100 && !existsSync(process.env.FM_CLOSED_FILE); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_CLOSED_FILE)) throw new Error("retry arm did not close");
  await new Promise((resolve) => setTimeout(resolve, 300));
}
if (process.env.ENTRYPOINT === "away") {
  writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
}
if (process.env.ENTRYPOINT === "monitor") {
  writeFileSync(process.env.FM_MONITOR_FAIL, "fail\n");
}
if (["away", "monitor"].includes(process.env.ENTRYPOINT)) {
  for (let i = 0; i < 100 && !existsSync(process.env.FM_STOP_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_STOP_LOG)) throw new Error(`${process.env.ENTRYPOINT} did not stop the established arm`);
}
if (loss === "missing") unlinkSync(lock); else writeFileSync(lock, "999999\n");
if (process.env.ENTRYPOINT === "away") unlinkSync(`${process.env.FM_HOME}/state/.afk`);
if (process.env.ENTRYPOINT === "monitor") unlinkSync(process.env.FM_MONITOR_FAIL);

let toolResult = null;
if (process.env.ENTRYPOINT === "command") {
  await command.handler("", {
    ui: {
      notify(message) {
        notifications.push(message);
      },
    },
  });
}
if (process.env.ENTRYPOINT === "tool") {
  toolResult = await tool.execute("policy-loss", {}, undefined, undefined, {});
}

for (let i = 0; i < 150; i += 1) {
  const surfaced = process.env.ENTRYPOINT === "tool"
    ? toolResult?.details?.ok === false
    : process.env.ENTRYPOINT === "command"
      ? notifications.some((message) => message.includes(`state: ${loss}`))
      : prompts.some((message) => message.includes(`state: ${loss}`));
  if (surfaced) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const surfaced = process.env.ENTRYPOINT === "tool"
  ? toolResult?.content?.[0]?.text || ""
  : process.env.ENTRYPOINT === "command"
    ? notifications.join(" | ")
    : prompts.join(" | ");
if (!surfaced.includes(`existing session-lock ownership required (state: ${loss})`)) {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} did not promote to owned-only: ${surfaced}`);
}
const armCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (armCount !== 1) throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} launched ${armCount} arms`);
if (existsSync(process.env.FM_LOCK_ACQUIRE_LOG)) {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} invoked lock acquisition`);
}
if (loss === "missing") {
  if (existsSync(lock)) throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} recreated a missing lock`);
} else if (readFileSync(lock, "utf8").trim() !== "999999") {
  throw new Error(`${process.env.REASON}/${process.env.ENTRYPOINT} replaced a dead lock`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
      ) || status=$?
      expect_code 0 "$status" "Pi $reason must promote defer before $entrypoint lock loss"
      [ -z "$out" ] || fail "Pi $reason/$entrypoint policy-promotion test printed output: $out"
    done
  done
  pass "Pi startup and new promote defer after the first verified arm"
}

test_pi_startup_auto_successor_promotes_defer() {
  local reason recovery repo home plugin arm_log acquire_log ready out status
  for reason in startup new; do
    for recovery in actionable retry; do
      repo="$TMP_ROOT/pi-$reason-$recovery-auto-promote-root"
      home="$TMP_ROOT/pi-$reason-$recovery-auto-promote-home"
      arm_log="$TMP_ROOT/pi-$reason-$recovery-auto-promote-arm.log"
      acquire_log="$TMP_ROOT/pi-$reason-$recovery-auto-promote-acquire.log"
      ready="$TMP_ROOT/pi-$reason-$recovery-auto-promote-ready"
      mkdir -p "$home/state" "$home/config"
      install_pi_watch_extension_fixture "$repo"
      plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d ' ')
if [ "$count" = 1 ]; then
  if [ "${FM_INITIAL_RECOVERY:?}" = actionable ]; then
    printf 'signal: initial pre-ready wake\n'
    exit 0
  fi
  exit 9
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 0.1
: > "$FM_SUCCESSOR_READY"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
      chmod +x "$repo/bin/fm-watch-arm.sh"
      status=0
      out=$(REASON="$reason" RECOVERY="$recovery" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" FM_LOCK_ACQUIRE_LOG="$acquire_log" FM_INITIAL_RECOVERY="$recovery" FM_SUCCESSOR_READY="$ready" FM_WATCH_REARM_RETRY_BASE_MS=20 FM_WATCH_REARM_RETRY_MAX_MS=20 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const handlers = new Map();
const notifications = [];
let tool = null;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: process.env.REASON }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
if (!tool) throw new Error("watcher tool was not registered");
for (let i = 0; i < 150 && !existsSync(process.env.FM_SUCCESSOR_READY); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_SUCCESSOR_READY)) {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} did not establish an automatic successor`);
}
const initialArmCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (initialArmCount !== 2) {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} launched ${initialArmCount} arms before lock loss`);
}

const loss = process.env.RECOVERY === "actionable" ? "missing" : "dead";
if (loss === "missing") unlinkSync(lock); else writeFileSync(lock, "999999\n");
const result = await tool.execute("post-successor-loss", {}, undefined, undefined, {});
if (result.details?.ok !== false || !result.content?.[0]?.text.includes(`existing session-lock ownership required (state: ${loss})`)) {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} retained defer after successor readiness: ${JSON.stringify(result)}`);
}
const finalArmCount = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).length;
if (finalArmCount !== 2) {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} launched ${finalArmCount} arms after lock loss`);
}
if (existsSync(process.env.FM_LOCK_ACQUIRE_LOG)) {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} invoked lock acquisition`);
}
if (loss === "missing") {
  if (existsSync(lock)) throw new Error(`${process.env.REASON}/${process.env.RECOVERY} recreated a missing lock`);
} else if (readFileSync(lock, "utf8").trim() !== "999999") {
  throw new Error(`${process.env.REASON}/${process.env.RECOVERY} replaced a dead lock`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
      ) || status=$?
      expect_code 0 "$status" "Pi $reason must promote defer after a $recovery successor"
      [ -z "$out" ] || fail "Pi $reason/$recovery auto-successor promotion test printed output: $out"
    done
  done
  pass "Pi automatic successors promote startup and new to owned-only"
}

test_pi_extension_respects_primary_scope() {
  local scenario base repo home plugin arm_log out status
  for scenario in linked secondmate; do
    base="$TMP_ROOT/pi-scope-$scenario-base"
    repo="$TMP_ROOT/pi-scope-$scenario-root"
    home="$TMP_ROOT/pi-scope-$scenario-home"
    arm_log="$TMP_ROOT/pi-scope-$scenario-arm.log"
    fm_git_worktree "$base" "$repo" "fm/pi-scope-$scenario"
    mkdir -p "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    if [ "$scenario" = secondmate ]; then
      printf 'scope-sm\n' > "$repo/.fm-secondmate-home"
    fi
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    status=0
    out=$(CASE="$scenario" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const notifications = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "resume" }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
for (let i = 0; i < 100 && process.env.CASE === "secondmate" && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const lock = `${process.env.FM_HOME}/state/.lock`;
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
if (process.env.CASE === "linked") {
  if (existsSync(lock) || existsSync(marker) || existsSync(process.env.FM_ARM_LOG)) {
    throw new Error("linked task worktree mutated inherited supervisor state");
  }
  if (notifications.length > 0) throw new Error(`linked task worktree notified unexpectedly: ${notifications.join(" | ")}`);
} else {
  if (readFileSync(lock, "utf8").trim() !== String(process.pid)) throw new Error("valid secondmate did not acquire its lock");
  if (!existsSync(marker)) throw new Error("valid secondmate did not mark the extension loaded");
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("valid secondmate did not arm supervision");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
    ) || status=$?
    expect_code 0 "$status" "Pi watcher must enforce primary scope for $scenario"
    [ -z "$out" ] || fail "Pi primary-scope $scenario test printed output: $out"
  done
  pass "Pi watcher stays inert in linked task worktrees and arms valid secondmate homes"
}

test_pi_extension_distinguishes_lock_refusal_states() {
  local mode event_expected tool_expected repo home plugin out status
  for mode in other failure changed; do
    repo="$TMP_ROOT/pi-lock-message-$mode-root"
    home="$TMP_ROOT/pi-lock-message-$mode-home"
    mkdir -p "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'unexpected arm\n' >&2
exit 9
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    case "$mode" in
      other)
        event_expected="read-only - a verified live firstmate session owns this home"
        tool_expected="$event_expected"
        ;;
      failure)
        event_expected="lock acquisition failed - session lock is missing"
        tool_expected="$event_expected"
        ;;
      changed)
        event_expected="lock ownership changed during resume - a verified live firstmate session now owns this home"
        tool_expected="read-only - a verified live firstmate session owns this home"
        ;;
    esac
    status=0
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_LOCK_FIXTURE_MODE="$mode" EVENT_EXPECTED="$event_expected" TOOL_EXPECTED="$tool_expected" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const notifications = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "resume" }, {
  ui: {
    notify(message) {
      notifications.push(message);
    },
  },
});
if (!notifications.some((message) => message.includes(process.env.EVENT_EXPECTED))) {
  throw new Error(`expected session refusal '${process.env.EVENT_EXPECTED}', got '${notifications.join(" | ")}'`);
}
const result = await tool.execute("lock-message", {}, undefined, undefined, {});
if (result.details?.ok !== false) throw new Error(`refusal unexpectedly succeeded: ${JSON.stringify(result)}`);
if (!result.content[0].text.includes(process.env.TOOL_EXPECTED)) {
  throw new Error(`expected tool refusal '${process.env.TOOL_EXPECTED}', got '${result.content[0].text}'`);
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
EOF
    ) || status=$?
    expect_code 0 "$status" "Pi watcher must distinguish the $mode lock refusal"
    [ -z "$out" ] || fail "Pi lock-message $mode test printed output: $out"
  done
  pass "Pi watcher distinguishes verified competitor, acquisition failure, and changed ownership"
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
test_pi_tool_waits_for_verified_readiness
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
test_pi_extension_transfers_active_arm_on_away_entry
test_pi_extension_fails_closed_and_retries_away_monitor
test_pi_resume_session_recovers_only_reclaimable_locks
test_pi_session_start_load_order_preserves_initial_nudge
test_pi_fork_reload_rebuilds_only_owned_supervision
test_pi_fork_reload_policy_survives_every_rearm_path
test_pi_startup_policy_promotes_after_first_arm
test_pi_startup_auto_successor_promotes_defer
test_pi_extension_respects_primary_scope
test_pi_extension_distinguishes_lock_refusal_states
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
