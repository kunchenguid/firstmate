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

# One owner for the readiness budget every unready-successor test below spends
# on purpose. Both plugins start a successor arm through a login shell and
# SIGTERM it when it stays silent past this budget, so the budget has to outlast
# a cold login-shell start. A successor killed before its first statement never
# appends its arm row and never installs the TERM trap these tests observe, so
# too small a budget reports a lost successor instead of the bounded recovery
# under test. A stock login shell already costs about 200ms on an idle
# workstation, and a loaded CI runner is slower, so keep an order of magnitude
# over that rather than a value that only holds locally. The wait loops in those
# tests are sized against this number.
ARM_READY_TIMEOUT_MS=2000

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
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
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
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
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
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
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance"
  [ -z "$out" ] || fail "Pi redundant-call test printed output: $out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
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
await tool.execute("tool-call-first", {}, undefined, undefined, {});
let redundant = null;
for (let i = 0; i < 100; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
  redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
  if (redundant.content[0]?.text.includes("scheduled continuity retry")) break;
}
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`scheduled retry call spawned ${rows.length} arm children`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry"
  [ -z "$out" ] || fail "Pi scheduled-retry test printed output: $out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
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
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
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
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm=")).length
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
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(armRows[1])) throw new Error(`successor did not receive predecessor identity: ${armRows[1]}`);
if (!rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the follow-up: ${rows.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releaseDelivery();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_branch_offer_owns_actionable_wake() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-branch-offer-root"
  home="$TMP_ROOT/pi-branch-offer-home"
  log="$TMP_ROOT/pi-branch-offer.log"
  stop="$TMP_ROOT/pi-branch-offer.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: branch-offer synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Two independent runs against the SAME dispatcher build: with an accepting
// branch listener the wake must be owned by the branch (no main follow-up);
// with a bus but no acceptor the dispatcher must fall back to main. The
// divergence between the two runs is asserted, so the case cannot go vacuous.
async function runScenario(withAcceptor) {
  writeFileSync(process.env.FM_ARM_LOG, "");
  const offers = [];
  let mainPrompt = "";
  let tool = null;
  const handlers = new Map();
  const bus = {
    on(channel, handler) {
      handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
      return () => {};
    },
    emit(channel, data) {
      for (const handler of handlers.get(channel) ?? []) handler(data);
    },
  };
  if (withAcceptor) {
    bus.on("fm-branch-supervision:dispatch", (offer) => {
      offers.push({ message: offer.message, projects: offer.projects });
      offer.accept();
    });
  }
  const pi = {
    on() {},
    events: bus,
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      mainPrompt = message;
    },
  };
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?scenario=${withAcceptor}`);
  mod.default(pi);
  await tool.execute("tool-call-branch-offer", {}, undefined, undefined, {});
  for (let i = 0; i < 250; i += 1) {
    const settled = withAcceptor ? offers.length > 0 : mainPrompt !== "";
    if (settled) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  return { offers, mainPrompt, rows };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/branch-offer.meta`, "project=/projects/approved\nwindow=fm-branch-offer\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\tbranch-offer.status\tsignal: branch-offer synthetic wake\n");
const accepted = await runScenario(true);
if (accepted.offers.length !== 1) throw new Error(`expected one branch offer, got ${accepted.offers.length}`);
if (!accepted.offers[0].message.includes("signal: branch-offer synthetic wake")) {
  throw new Error(`offer missed the wake reason: ${accepted.offers[0].message}`);
}
if (JSON.stringify(accepted.offers[0].projects) !== JSON.stringify(["/projects/approved"])) {
  throw new Error(`offer did not carry the queued task project: ${JSON.stringify(accepted.offers[0].projects)}`);
}
if (accepted.mainPrompt !== "") throw new Error(`accepted offer still reached main: ${accepted.mainPrompt}`);
if (!accepted.rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the branch handoff: ${accepted.rows.join(" | ")}`);
}
const declined = await runScenario(false);
if (declined.offers.length !== 0) throw new Error("no-acceptor scenario recorded an offer");
if (!declined.mainPrompt.includes("FIRSTMATE WATCHER WAKE")) {
  throw new Error(`unaccepted offer did not fall back to main: ${declined.mainPrompt}`);
}
if (!declined.mainPrompt.includes("signal: branch-offer synthetic wake")) {
  throw new Error(`fallback wake lost the reason line: ${declined.mainPrompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi dispatcher must hand an accepted wake to the branch and fall back to main otherwise"
  [ -z "$out" ] || fail "Pi branch-offer test printed output: $out"
  pass "Pi dispatcher branch offer owns accepted wakes and falls back to main"
}

test_pi_branch_offer_flags_heartbeat() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-branch-heartbeat-root"
  home="$TMP_ROOT/pi-branch-heartbeat-home"
  log="$TMP_ROOT/pi-branch-heartbeat.log"
  stop="$TMP_ROOT/pi-branch-heartbeat.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # A bare heartbeat is the real wake emitted after the cheap bash scan flags
  # a fleet pass as possibly captain-relevant. It has no task-scoped queue row,
  # so branch eligibility must remain independent of project resolution.
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, projects: offer.projects, heartbeat: offer.heartbeat, eligible: offer.eligible });
  offer.accept();
});
let tool = null;
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\theartbeat\theartbeat\theartbeat\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-branch-heartbeat", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1) throw new Error(`expected one branch offer, got ${offers.length}`);
if (offers[0].message !== "heartbeat") {
  throw new Error(`offer changed the bare heartbeat wake reason: ${offers[0].message}`);
}
if (offers[0].heartbeat !== true || offers[0].eligible !== true) throw new Error(`heartbeat offer was not eligible: ${JSON.stringify(offers[0])}`);
if (JSON.stringify(offers[0].projects) !== JSON.stringify([])) {
  throw new Error(`heartbeat offer unexpectedly carried scoped projects: ${JSON.stringify(offers[0].projects)}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi dispatcher must flag a heartbeat offer independent of task scoping"
  [ -z "$out" ] || fail "Pi branch-heartbeat test printed output: $out"
  pass "Pi dispatcher flags a fleet-wide heartbeat offer as branch-eligible"
}

test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_check() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-heartbeat-mixed-queue-root"
  home="$TMP_ROOT/pi-heartbeat-mixed-queue-home"
  log="$TMP_ROOT/pi-heartbeat-mixed-queue.log"
  stop="$TMP_ROOT/pi-heartbeat-mixed-queue.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, heartbeat: offer.heartbeat, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\theartbeat\theartbeat\theartbeat\n2\t2\tcheck\tx-inbox\tcheck: pending x mention\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-mixed-queue", {}, undefined, undefined, {});
// The offer is what this asserts on, so wait for it and then give any
// erroneous main delivery a real chance to land before calling it absent.
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 25 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].heartbeat !== true || offers[0].eligible !== true) {
  throw new Error(`a co-present check row made the heartbeat offer ineligible: ${JSON.stringify(offers)}`);
}
if (prompt) {
  throw new Error(`a co-present check row rode the heartbeat into main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a heartbeat must not ride a co-present check row into main: $out"
  [ -z "$out" ] || fail "Pi mixed heartbeat-queue test printed output: $out"
  pass "a co-present check row neither vetoes nor rides a heartbeat into main"
}

# Every check the main session alone can act on stays on main, even when an
# unrelated task-local row in the same queue is perfectly branch-eligible. The
# no-op checks the branch never sees are suppressed at their source instead
# (bin/fm-procevent-lavish.sh "silent"), so what remains under a `check:`
# trigger is exactly the main-only set, and each named class is driven here
# through the real dispatcher.
test_pi_main_only_check_classes_stay_on_main() {
  local repo home plugin log stop out status reason label
  repo="$TMP_ROOT/pi-main-only-check-root"
  home="$TMP_ROOT/pi-main-only-check-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\n' "${FM_TEST_REASON:?}"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  while IFS='|' read -r label reason; do
    [ -n "$label" ] || continue
    log="$TMP_ROOT/pi-main-only-check-$label.log"
    stop="$TMP_ROOT/pi-main-only-check-$label.stop"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
      FM_TEST_REASON="$reason" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
// A task-local row the branch would happily take sits in the same queue, so
// only the check-kind TRIGGER itself can be what keeps this wake on main.
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tsignal: task-a.status\n2\t2\tcheck\tmain-only\t" + process.env.FM_TEST_REASON + "\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-main-only-check", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a main-only check was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes(`FIRSTMATE WATCHER WAKE: ${process.env.FM_TEST_REASON}`)) {
  throw new Error(`a main-only check did not reach main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
    )
    status=$?
    expect_code 0 "$status" "the $label check class must stay on main: $out"
    [ -z "$out" ] || fail "Pi main-only check test ($label) printed output: $out"
  done <<'CLASSES'
relay-mention|check: x-mention 1234567890
credential-failure|check: gh auth check failed; re-authenticate before dispatch
merge-confirmation|check: task-a.check.sh: PR merged
real-board-answer|check: procevent lavish lavish-abcdef0123456789 1
CLASSES
  pass "every main-only check class still reaches main, never the supervision branch"
}

# A surfaced captain-held signal uses the existing decision-owned payload, so a
# co-present routine row cannot take the signal close away from main.
test_pi_captain_held_signal_stays_on_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-captain-held-whitespace-root"
  home="$TMP_ROOT/pi-captain-held-whitespace-home"
  log="$TMP_ROOT/pi-captain-held-whitespace.log"
  stop="$TMP_ROOT/pi-captain-held-whitespace.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  printf 'captain-held [key=route]: awaiting the captain\n \t \n' > "$home/state/task-a.status"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: task-a.status\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-captain-held-signal", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a captain-held signal trigger was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: signal: task-a.status")) {
  throw new Error(`a captain-held signal trigger did not reach main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a captain-held signal trigger must stay on main: $out"
  [ -z "$out" ] || fail "Pi captain-held signal test printed output: $out"
  pass "a captain-held signal trigger reaches main with routine rows present"
}

# An unread second-mate pending-reply escalation keeps a later stale reminder
# under the same task's window alias on main until the decision row is read.
test_pi_unread_pending_reply_forces_later_stale_alias_to_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-mixed-signal-root"
  home="$TMP_ROOT/pi-mixed-signal-home"
  log="$TMP_ROOT/pi-mixed-signal.log"
  stop="$TMP_ROOT/pi-mixed-signal.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-a\n' "$home" > "$home/state/task-a.meta"
  printf 'blocked [key=pending-reply-0123456789abcdef]: pending-reply-missed: task=task-a pending-reply-id=0123456789abcdef request=finish report\n' \
    > "$home/state/task-a.status"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'stale: fm-a (routine reminder)\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, eligible: offer.eligible, projects: [...offer.projects] });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "2\t2\tstale\tfm-a\tstale: fm-a (routine reminder)\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-later-stale-alias", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a later stale alias bypassed its unread decision: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: stale: fm-a")) {
  throw new Error(`a later stale alias with an unread decision did not wake main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "an unread pending-reply escalation must keep a later stale alias on main: $out"
  [ -z "$out" ] || fail "Pi unread pending-reply alias test printed output: $out"
  pass "an unread pending-reply escalation keeps later stale aliases on main"
}

# The captain's accepted rule names ONE coalesced trigger batch, not only a
# single status file with two rows: when a watcher poll bundles a routine
# signal for one task and a needs-decision signal for a DIFFERENT task into
# one "signal: <files>" close, the whole batch - both files - must reach main
# together, never split so the routine file goes to the branch while only the
# decision file goes to main. A `some`-vs-`every` regression on the file-list
# cross-reference would pass the same-key test above (both entries share one
# key) but must fail here, where the two files are genuinely distinct.
test_pi_distinct_files_mixed_batch_routes_whole_batch_to_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-distinct-mixed-batch-root"
  home="$TMP_ROOT/pi-distinct-mixed-batch-home"
  log="$TMP_ROOT/pi-distinct-mixed-batch.log"
  stop="$TMP_ROOT/pi-distinct-mixed-batch.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-a\n' "$home" > "$home/state/task-a.meta"
  printf 'project=%s/projects/approved\nwindow=fm-b\n' "$home" > "$home/state/task-b.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: task-a.status task-b.status\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, eligible: offer.eligible, projects: [...offer.projects] });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "2\t2\tsignal\ttask-b.status\tsignal: task-b.status\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-distinct-mixed-batch", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a distinct-file mixed batch was split, offering the routine file to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: signal: task-a.status task-b.status")) {
  throw new Error(`the distinct-file mixed batch did not reach main as one whole close: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a distinct-file mixed batch must route wholly to main, not split: $out"
  [ -z "$out" ] || fail "Pi distinct-file mixed-batch test printed output: $out"
  pass "a mixed batch of two distinct files - one routine, one needs-decision - routes wholly to main"
}

# Independent heartbeat handling: a needs-decision row sitting elsewhere in the
# unread queue is excluded and non-vetoing exactly like a check-kind row, so it
# must neither block nor ride along with a co-present, otherwise-eligible
# heartbeat scan (docs/pi-supervision-branch.md "Heartbeat routing").
test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_needs_decision() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-heartbeat-needs-decision-root"
  home="$TMP_ROOT/pi-heartbeat-needs-decision-home"
  log="$TMP_ROOT/pi-heartbeat-needs-decision.log"
  stop="$TMP_ROOT/pi-heartbeat-needs-decision.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, heartbeat: offer.heartbeat, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\theartbeat\theartbeat\theartbeat\n2\t2\tsignal\tdecision-task.status\tneeds-decision: decision-task.status\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-needs-decision", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 25 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].heartbeat !== true || offers[0].eligible !== true) {
  throw new Error(`a co-present needs-decision row made the heartbeat offer ineligible: ${JSON.stringify(offers)}`);
}
if (prompt) {
  throw new Error(`a co-present needs-decision row rode the heartbeat into main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a heartbeat must not ride a co-present needs-decision row into main: $out"
  [ -z "$out" ] || fail "Pi heartbeat/needs-decision test printed output: $out"
  pass "a co-present needs-decision row neither vetoes nor rides a heartbeat into main"
}

test_pi_heartbeat_restoration_failure_stays_on_main() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-heartbeat-restoration-failure-root"
  home="$TMP_ROOT/pi-heartbeat-restoration-failure-home"
  log="$TMP_ROOT/pi-heartbeat-restoration-failure.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'synthetic successor startup failure\n' >&2
exit 1
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let tool = null;
const handlers = new Map();
const bus = {
  on(channel, handler) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of handlers.get(channel) ?? []) handler(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, heartbeat: offer.heartbeat });
  offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-restoration-failure", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 0) {
  throw new Error(`heartbeat restoration failure was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: heartbeat\n\nwatcher: FAILED")) {
  throw new Error(`main wake lost the bare heartbeat reason: ${prompt}`);
}
if (!prompt.includes("watcher: FAILED - Pi extension could not restore watcher continuity after 2 retries")) {
  throw new Error(`main wake lost the restoration failure: ${prompt}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "heartbeat restoration failure must bypass an accepting branch: $out"
  [ -z "$out" ] || fail "Pi heartbeat restoration-failure test printed output: $out"
  pass "heartbeat restoration failure stays on main"
}

test_pi_watcher_failure_never_offered_to_branch() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-watcher-failure-root"
  home="$TMP_ROOT/pi-watcher-failure-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # Only "actionable" closes (signal/stale/check/heartbeat) ever reach
  # offerWakeToBranch; only main can repair the watcher cycle
  # (docs/pi-supervision-branch.md), and default-on eligibility must not
  # change that. A live, always-accepting bus listener proves the negative:
  # even with an acceptor present, a watcher-failure close is never offered.
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let handler = null;
const handlers = new Map();
const bus = {
  on(channel, h) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), h]);
    return () => {};
  },
  emit(channel, data) {
    for (const h of handlers.get(channel) ?? []) h(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, heartbeat: offer.heartbeat });
  offer.accept();
});
const pi = {
  on() {},
  events: bus,
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
await handler("", { ui: { notify() {} } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("external healthy watcher")) {
  throw new Error(`watcher failure did not reach main: ${prompt}`);
}
if (offers.length !== 0) {
  throw new Error(`watcher failure was offered to the branch: ${JSON.stringify(offers)}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "watcher-failure repair must never be offered to the branch: $out"
  [ -z "$out" ] || fail "Pi watcher-failure test printed output: $out"
  pass "watcher-failure repair stays with main even with a live, accepting branch listener"
}

test_pi_handling_delivery_failure_is_typed_once() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-handling-fail-root"
  home="$TMP_ROOT/pi-handling-fail-home"
  log="$TMP_ROOT/pi-handling-fail.log"
  stop="$TMP_ROOT/pi-handling-fail.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 1
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
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
await tool.execute("tool-call-handling-fail", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt.includes("handling delivery confirmation was rejected"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) throw new Error(`missing follow-up: ${prompt}`);
if (!prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`failed handshake was swallowed: ${prompt}`);
}
if ((prompt.match(/FIRSTMATE WATCHER WAKE/g) || []).length !== 1) {
  throw new Error(`failed handshake was not a single typed message: ${prompt}`);
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.filter((row) => row.startsWith("refused ")).length < 1) {
  throw new Error(`handling-delivered was never attempted: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must surface a refused handling handshake as one typed failure"
  [ -z "$out" ] || fail "Pi handling-delivery failure test printed output: $out"
  pass "Pi refused handling handshake is classified and not swallowed"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
// Three unready successors each cost the full readiness budget, so wait well
// past their sum. The wait ends as soon as the wake lands.
for (let i = 0; i < 1500 && !prompt; i += 1) {
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  // Nothing here consumes the follow-up: continuity must not depend on it.
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

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file child_marker_file marker_root arm_log out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  child_marker_file="$TMP_ROOT/pi-session-transition-child.marker"
  marker_root="$TMP_ROOT/pi-session-transition-markers"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$marker_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The marker identifies this exact process lifetime after its PID is recycled.
marker=$(mktemp "${FM_MARKER_ROOT:?}/arm.XXXXXX") || exit 1
cleanup() { rm -f "$marker"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf 'watcher: started pid=%s\n' "$$"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf '%s\n' "$marker" > "${FM_CHILD_MARKER_FILE:?}"
printf 'arm pid=%s marker=%s\n' "$$" "$marker" >> "${FM_ARM_LOG:?}"
while :; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_CHILD_MARKER_FILE="$child_marker_file" FM_MARKER_ROOT="$marker_root" FM_ARM_LOG="$arm_log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
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
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(pred, label, attempts = 250) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

function currentArm() {
  try {
    return {
      pid: readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim(),
      marker: readFileSync(process.env.FM_CHILD_MARKER_FILE, "utf8").trim(),
    };
  } catch {
    return { pid: "", marker: "" };
  }
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+) marker=(\S+)/.exec(line);
      return match ? { pid: match[1], marker: match[2] } : { pid: "", marker: "" };
    })
    .filter((arm) => arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid))
    .map((arm) => arm.pid);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await waitFor(() => {
  const arm = currentArm();
  return arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid);
}, "startup child");
const { pid: startupChild, marker: startupMarker } = currentArm();
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousArm = currentArm();
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (previousArm.marker) {
    await waitFor(() => !existsSync(previousArm.marker), `${reason} previous child exit`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  await waitFor(() => {
    const arm = currentArm();
    return arm.pid && arm.marker && arm.marker !== previousArm.marker && existsSync(arm.marker) && pidAlive(arm.pid) && liveArmPids().includes(arm.pid);
  }, `${reason} replacement child and arm record`);
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  const redundant = await next.getTool().execute(`redundant-${reason}`, {}, undefined, undefined, {});
  if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
    throw new Error(`${reason} replacement lost automatic arm ownership: ${JSON.stringify(redundant.details)}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");
current = await replaceSession(current, "reload");

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceArm = currentArm();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => {
    const arm = currentArm();
    return arm.pid && arm.marker && arm.marker !== sameInstanceArm.marker && existsSync(arm.marker) && pidAlive(arm.pid) && liveArmPids().includes(arm.pid);
}, "same-instance replacement child and arm record");
await waitFor(() => !existsSync(sameInstanceArm.marker), "same-instance previous child exit");
const sameInstanceResult = await current.getTool().execute("same-instance-redundant", {}, undefined, undefined, {});
if (!sameInstanceResult.details?.ok || !String(sameInstanceResult.details.message).includes("unchanged")) {
  throw new Error(`same-instance replacement lost automatic arm ownership: ${JSON.stringify(sameInstanceResult.details)}`);
}
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = currentArm().pid;
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (existsSync(startupMarker)) throw new Error("startup generation child was resurrected");
// Model the old generation PID being recycled for the active child.
// Its retired lifetime marker must keep the historical row from counting live.
writeFileSync(process.env.FM_ARM_LOG, `arm pid=${activeChild} marker=${startupMarker}\n`, { flag: "a" });
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalArm = currentArm();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => !existsSync(finalArm.marker), "terminal shutdown child exit");
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi session transitions must auto-arm through their generation owner (exit $status): $out"
  [ -z "$out" ] || fail "Pi session-transition generation owner test printed output: $out"
  pass "Pi session transitions auto-arm through a generation owner across /new /resume /fork/reload, stale callbacks, and quit"
}

test_pi_session_replacement_carries_inflight_actionable_close() {
  local repo home plugin log marker_root trigger stop out status
  repo="$TMP_ROOT/pi-session-replacement-handoff-root"
  home="$TMP_ROOT/pi-session-replacement-handoff-home"
  log="$TMP_ROOT/pi-session-replacement-handoff.log"
  marker_root="$TMP_ROOT/pi-session-replacement-handoff-markers"
  trigger="$TMP_ROOT/pi-session-replacement-handoff.trigger"
  stop="$TMP_ROOT/pi-session-replacement-handoff.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$marker_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
marker=$(mktemp "${FM_MARKER_ROOT:?}/arm.XXXXXX") || exit 1
cleanup() { rm -f "$marker"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf 'arm pid=%s marker=%s\n' "$$" "$marker" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=replacement-fixture\n' "$$"
while :; do
  if [ -e "$FM_TRIGGER_FILE" ]; then
    outcome=$(cat "$FM_TRIGGER_FILE")
    rm -f "$FM_TRIGGER_FILE"
    printf 'signal: '
    sleep 0.02
    printf '%s\n' "$outcome"
    exit 0
  fi
  [ ! -e "$FM_STOP_FILE" ] || exit 0
  sleep 0.02
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_MARKER_ROOT="$marker_root" FM_TRIGGER_FILE="$trigger" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let releaseOldDelivery = () => {};
const oldDeliveryRelease = new Promise((resolve) => {
  releaseOldDelivery = resolve;
});
let oldDeliveryStarted = false;

function makePi(blockDelivery = false) {
  const handlers = new Map();
  const eventHandlers = new Map();
  let tool = null;
  const prompts = [];
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
    events: {
      on(event, handler) {
        eventHandlers.set(event, [...(eventHandlers.get(event) ?? []), handler]);
      },
      emit(event, data) {
        if (blockDelivery && event === "fm-branch-supervision:dispatch") {
          oldDeliveryStarted = true;
          data.accept(oldDeliveryRelease);
        }
        for (const handler of eventHandlers.get(event) ?? []) handler(data);
      },
    },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function armRows() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter((row) => row.startsWith("arm "))
    .map((row) => {
      const match = /pid=(\d+) marker=(\S+)/.exec(row);
      return match ? { pid: match[1], marker: match[2] } : { pid: "", marker: "" };
    });
}

function liveArms() {
  return armRows().filter((arm) => arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid));
}

async function waitFor(pred, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/replacement-race.meta`, "project=/projects/replacement-race\nwindow=fm-replacement-race\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\treplacement-race.status\tsignal: replacement-race actionable outcome\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const previous = makePi(true);
mod.default(previous.pi);
const initial = await previous.getTool().execute("initial-arm", {}, undefined, undefined, {});
if (!initial.details?.ok || !String(initial.details.message).includes("started Pi extension arm child")) {
  throw new Error(`initial arm failed: ${JSON.stringify(initial.details)}`);
}
await waitFor(() => liveArms().length === 1, "initial live arm");

writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-race actionable outcome\n");
await waitFor(() => oldDeliveryStarted, "old-session accepted branch delivery");
if (previous.prompts.length !== 0) {
  throw new Error(`accepted old-session branch wake reached main: ${previous.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 2, "old-session successor");
writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-successor actionable outcome\n");
await waitFor(() => liveArms().length === 0, "mid-delivery successor actionable close");

await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await waitFor(() => liveArms().length === 0, "retired old-session successor");

const replacement = makePi(false);
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=durable-handoff`);
replacementMod.default(replacement.pi);
const replacementStart = replacement.handlers.get("session_start")?.({
  type: "session_start",
  reason: "new",
  previousSessionFile: "/tmp/previous.jsonl",
}, {});
await new Promise((resolve) => setTimeout(resolve, 50));
await waitFor(() => liveArms().length === 1 && armRows().length >= 3, "replacement arm before old delivery settlement");
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`replacement raced the accepted old-session delivery: ${replacement.prompts.join(" | ")}`);
}
writeFileSync(
  `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`,
  "{malformed handoff\n",
);
releaseOldDelivery();
await replacementStart;
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: replacement-successor actionable outcome")),
  "replacement-session successor actionable delivery",
);
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`settled old-session branch delivery was replayed: ${replacement.prompts.join(" | ")}`);
}
if (replacement.prompts.filter((message) => message.includes("signal: replacement-successor actionable outcome")).length !== 1) {
  throw new Error(`replacement session did not receive exactly one carried successor outcome: ${replacement.prompts.join(" | ")}`);
}
if (!replacement.prompts.some((message) => message.includes("could not clear a delivered replacement-session actionable wake"))) {
  throw new Error(`handoff cleanup failure was not surfaced: ${replacement.prompts.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 700));
if (replacement.prompts.filter((message) => message.includes("could not clear a delivered replacement-session actionable wake")).length !== 1) {
  throw new Error(`persistent handoff cleanup failure repeated alerts: ${replacement.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 3, "replacement live arm");
const redundant = await replacement.getTool().execute("replacement-redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`replacement did not retain automatic arm ownership: ${JSON.stringify(redundant.details)}`);
}

await new Promise((resolve) => setTimeout(resolve, 100));
if (liveArms().length !== 1) {
  throw new Error(`old delivery completion disturbed replacement ownership: ${JSON.stringify(liveArms())}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session replacement must auto-arm and carry an in-flight actionable close"
  [ -z "$out" ] || fail "Pi session-replacement handoff test printed output: $out"
  pass "Pi session replacement auto-arms and carries its in-flight actionable close"
}

# Acceptance is the redelivery bound: a follow-up Pi accepted while main was
# streaming is in the old session's run, so a replacement must never re-send
# it, even though the model never read it before the replacement. A lockless
# replacement must adopt nothing early, and a reclaimed session must stay
# silent too, because the accepted record cleared its handoff.
test_pi_streaming_followup_is_never_redelivered_after_replacement() {
  local repo home plugin trigger out status
  repo="$TMP_ROOT/pi-streaming-followup-replacement-root"
  home="$TMP_ROOT/pi-streaming-followup-replacement-home"
  trigger="$TMP_ROOT/pi-streaming-followup-replacement.trigger"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
printf 'watcher: started pid=%s\n' "$$"
while :; do
  if [ -e "$FM_TRIGGER_FILE" ]; then
    rm -f "$FM_TRIGGER_FILE"
    printf 'signal: streaming queued actionable outcome\n'
    exit 0
  fi
  sleep 0.02
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_TRIGGER_FILE="$trigger" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
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
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts, getTool: () => tool };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const originalMod = await import(pathToFileURL(process.env.PLUGIN).href);
const original = makePi();
originalMod.default(original.pi);
await original.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
original.handlers.get("agent_start")?.({}, {});
writeFileSync(process.env.FM_TRIGGER_FILE, "trigger\n");
await waitFor(
  () => original.prompts.some((message) => message.includes("signal: streaming queued actionable outcome")),
  "old-session queued follow-up",
);
await original.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});

const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=streaming-followup`);
const replacement = makePi();
replacementMod.default(replacement.pi);
await replacement.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 100));
if (replacement.prompts.some((message) => message.includes("signal: streaming queued actionable outcome"))) {
  throw new Error(`replacement re-sent a follow-up Pi had accepted: ${replacement.prompts.join(" | ")}`);
}
const { existsSync, unlinkSync } = await import("node:fs");
const handoffPath = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
for (let i = 0; i < 200 && existsSync(handoffPath); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(handoffPath)) throw new Error("the accepted follow-up kept its persisted handoff record");
await replacement.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});

const finalMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=idle-followup`);
const finalSession = makePi();
finalMod.default(finalSession.pi);
unlinkSync(`${process.env.FM_HOME}/state/.lock`);
await finalSession.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
if (finalSession.prompts.length !== 0) throw new Error("lockless replacement adopted its handoff early");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const reclaimed = await finalSession.getTool().execute("reclaimed-arm", {}, undefined, undefined, {});
if (!reclaimed.details?.ok) throw new Error(`reclaimed arm failed: ${JSON.stringify(reclaimed.details)}`);
await new Promise((resolve) => setTimeout(resolve, 100));
if (finalSession.prompts.some((message) => message.includes("signal: streaming queued actionable outcome"))) {
  throw new Error(`reclaimed session re-sent the accepted follow-up: ${finalSession.prompts.join(" | ")}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement must never re-send a follow-up Pi accepted"
  [ -z "$out" ] || fail "Pi streaming follow-up replacement test printed output: $out"
  pass "Pi replacement never re-sends an accepted streaming follow-up"
}

# The 2026-09-02 incident: a wake delivered while main was mid-turn never raised
# before_agent_start, the extension waited for it, and every later actionable
# close was dropped. Continuity must settle on Pi accepting the follow-up.
# Acceptance is now also the redelivery bound: both streaming-time wakes are
# accepted, so the replacement must replay neither, clear their handoff
# records, and keep the successor chain armed.
test_pi_streaming_time_delivery_keeps_the_successor_chain() {
  local repo home plugin log trigger out status
  repo="$TMP_ROOT/pi-streaming-chain-root"
  home="$TMP_ROOT/pi-streaming-chain-home"
  log="$TMP_ROOT/pi-streaming-chain.log"
  trigger="$TMP_ROOT/pi-streaming-chain.trigger"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed=%s\n' "$2" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=chain-%s\n' "$$" "$count"
trap 'exit 0' TERM INT
while [ ! -e "$FM_TRIGGER_FILE.$count" ]; do sleep 0.02; done
printf 'signal: streaming chain wake %s\n' "$count"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_TRIGGER_FILE="$trigger" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
let streaming = false;
let beforeAgentStarts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  // The real Pi prompt path: a follow-up sent while the agent is streaming is
  // queued for the running run and raises no before_agent_start; only a send
  // to an idle agent starts a run and raises it with the exact text.
  sendUserMessage: async (message) => {
    prompts.push(message);
    if (streaming) return;
    beforeAgentStarts += 1;
    handlers.get("before_agent_start")?.({ prompt: message }, {});
  },
  events: { on() {}, emit() {} },
};
// The running run reaching a queued follow-up: Pi emits the user message.
const consumeQueued = (message) =>
  handlers.get("message_start")?.({ message: { role: "user", content: [{ type: "text", text: message }] } }, {});
const arms = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm=")).length
  : 0;
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}
const wakes = (text) => prompts.filter((message) => message.includes(text)).length;

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await waitFor(() => arms() === 1, "first arm");
streaming = true;
writeFileSync(`${process.env.FM_TRIGGER_FILE}.1`, "close\n");
await waitFor(() => prompts.length === 1, "first wake delivered while main streams");
if (wakes("signal: streaming chain wake 1") !== 1) throw new Error(`wrong first wake: ${prompts.join(" | ")}`);
await waitFor(() => arms() === 2, "successor after the streaming-time delivery");
writeFileSync(`${process.env.FM_TRIGGER_FILE}.2`, "close\n");
await waitFor(() => prompts.length === 2, "second wake delivered while main still streams");
if (wakes("signal: streaming chain wake 2") !== 1) throw new Error(`wrong second wake: ${prompts.join(" | ")}`);
await waitFor(() => arms() === 3, "successor after the second streaming-time delivery");
if (beforeAgentStarts !== 0) throw new Error(`streaming follow-ups raised before_agent_start ${beforeAgentStarts} times`);

// The run reaches the first queued follow-up; the second is still queued when
// the captain replaces the session. Both were accepted, so the handoff may
// carry only a record marked delivered (cleanup raced the shutdown) and the
// replacement must re-send neither.
consumeQueued(prompts[0]);
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
const handoffPath = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
let handoff = null;
try {
  handoff = JSON.parse(readFileSync(handoffPath, "utf8"));
} catch {}
if (handoff) {
  if (handoff.pending.length !== 1 || !handoff.pending[0].delivered || !handoff.pending[0].message.includes("signal: streaming chain wake 2")) {
    throw new Error(`replacement handoff must carry only the accepted wake, marked delivered: ${JSON.stringify(handoff)}`);
  }
}
streaming = false;
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=streaming-chain`);
replacementMod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => arms() === 4, "replacement arm");
if (wakes("signal: streaming chain wake 2") !== 1 || wakes("signal: streaming chain wake 1") !== 1) {
  throw new Error(`replacement re-sent an accepted wake: ${prompts.join(" | ")}`);
}
if (beforeAgentStarts !== 0) throw new Error(`an accepted replay raised before_agent_start ${beforeAgentStarts} times`);
await waitFor(() => !existsSync(handoffPath), "replacement cleared the accepted wake's handoff record");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi streaming-time wake delivery must keep the successor chain and never re-send accepted wakes"
  [ -z "$out" ] || fail "Pi streaming-time delivery chain test printed output: $out"
  pass "Pi streaming-time wake delivery keeps the successor chain and never re-sends accepted wakes"
}

# The watch-extension fixture plus the replay gate and its source deps, so the
# replay-gating tests below exercise the real durable-state verdicts.
install_pi_replay_gate_fixture() {
  local repo=$1
  install_pi_watch_extension_fixture "$repo"
  cp "$ROOT/bin/fm-watch-replay-gate.sh" "$repo/bin/fm-watch-replay-gate.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$repo/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-backend.sh" "$repo/bin/fm-backend.sh"
  chmod +x "$repo/bin/fm-watch-replay-gate.sh"
}

# The observed incident, replayed mechanically: a task was torn down, its stale
# wake was presented, handled, and acknowledged (empty queue, acked recovery
# episode, no task meta), yet the persisted replacement handoff record kept
# re-presenting the identical wake at consecutive turn boundaries. The
# replacement session must drop that record instead of re-presenting it, clear
# it from the handoff, and keep its own watcher cycle armed.
test_pi_replayed_acked_wake_of_torn_down_task_is_dropped() {
  local repo home plugin stop out status handoff
  repo="$TMP_ROOT/pi-replay-acked-drop-root"
  home="$TMP_ROOT/pi-replay-acked-drop-home"
  stop="$TMP_ROOT/pi-replay-acked-drop.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_replay_gate_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=incident-fixture\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "acked:handling:130247.1788720192.pbH0L2\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
const handoff = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff.slice(0, handoff.lastIndexOf("/")), { recursive: true });
writeFileSync(handoff, `${JSON.stringify({
  version: 2,
  pending: [{
    version: 1,
    token: "130247-1788720192-1",
    message: "stale: default:wMA:p2",
    predecessorArmPid: "",
  }],
})}\n`);

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
  events: { on() {}, emit() {} },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 300));
if (prompts.some((message) => message.includes("stale: default:wMA:p2"))) {
  throw new Error(`an acked replay of a torn-down task's wake was re-presented: ${prompts.join(" | ")}`);
}
if (existsSync(handoff)) throw new Error("the dropped replay kept its persisted handoff record");
if (!tool) throw new Error("Pi watch tool was not registered");
const redundant = await tool.execute("post-drop-arm", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`dropping the replay disturbed arm ownership: ${JSON.stringify(redundant.details)}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "an acked replay whose task is gone must be dropped, never re-presented"
  [ -z "$out" ] || fail "Pi replay-acked-drop test printed output: $out"
  pass "an acked replay for a torn-down task is dropped and its handoff record cleared"
}

# The same incident shape with a signal reason: the extension's own signal
# routing parses <task>.status keys, so the gate must apply the torn-down
# rule to them too. An unrelated queued row keeps the global empty-queue
# rule out of the way, so only the signal rule can produce this drop.
test_pi_replayed_signal_wake_of_torn_down_task_is_dropped() {
  local repo home plugin stop out status handoff
  repo="$TMP_ROOT/pi-replay-signal-drop-root"
  home="$TMP_ROOT/pi-replay-signal-drop-home"
  stop="$TMP_ROOT/pi-replay-signal-drop.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_replay_gate_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=signal-fixture\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "acked:handling:130247.1788720192.pbH0L2\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tstale\tother:win\tstale: other:win\n");
const handoff = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff.slice(0, handoff.lastIndexOf("/")), { recursive: true });
writeFileSync(handoff, `${JSON.stringify({
  version: 2,
  pending: [{
    version: 1,
    token: "130247-1788720192-2",
    message: "signal: gone.status gone.turn-ended",
    predecessorArmPid: "",
  }],
})}\n`);

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
  events: { on() {}, emit() {} },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 300));
if (prompts.some((message) => message.includes("signal: gone.status"))) {
  throw new Error(`a signal replay for a torn-down task was re-presented: ${prompts.join(" | ")}`);
}
if (existsSync(handoff)) throw new Error("the dropped signal replay kept its persisted handoff record");
if (!tool) throw new Error("Pi watch tool was not registered");
const redundant = await tool.execute("post-drop-arm", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`dropping the signal replay disturbed arm ownership: ${JSON.stringify(redundant.details)}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "a signal replay whose task is gone must be dropped, never re-presented"
  [ -z "$out" ] || fail "Pi replay-signal-drop test printed output: $out"
  pass "a signal replay for a torn-down task is dropped and its handoff record cleared"
}

# A gate drop whose handoff cleanup fails must not re-select the record: the
# record is marked delivered before finishing, so the bounded cleanup pass
# owns the retry and the gate is consulted exactly once per dropped record.
test_pi_gate_drop_survives_handoff_cleanup_failure_without_spinning() {
  local repo home plugin stop gate_log out status handoff
  repo="$TMP_ROOT/pi-replay-spin-root"
  home="$TMP_ROOT/pi-replay-spin-home"
  stop="$TMP_ROOT/pi-replay-spin.stop"
  gate_log="$TMP_ROOT/pi-replay-spin.gate.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_replay_gate_fixture "$repo"
  mv "$repo/bin/fm-watch-replay-gate.sh" "$repo/bin/fm-watch-replay-gate-real.sh"
  cat > "$repo/bin/fm-watch-replay-gate.sh" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$gate_log"
exec bash "$repo/bin/fm-watch-replay-gate-real.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-replay-gate.sh"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=spin-fixture\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  mkdir -p "$home/state/extensions/pi-primary-watch"
  handoff="$home/state/extensions/pi-primary-watch/session-replacement-actionable.json"
  cat > "$handoff" <<'JSON'
{"version":2,"pending":[{"version":1,"token":"130247-1788720192-1","message":"stale: default:wMA:p2","predecessorArmPid":""},{"version":1,"token":"130247-1788720192-2","message":"stale: default:wMA:p2","predecessorArmPid":""}]}
JSON
  # An unwritable handoff directory makes clearing a dropped record's entry
  # fail the same way a corrupted or unwritable handoff file fails in
  # production, while loading and parsing the seeded records still works.
  chmod 555 "$home/state/extensions/pi-primary-watch"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STOP_FILE="$stop" FM_GATE_LOG="$gate_log" timeout 60 node --input-type=module 2>&1 <<'EOF'
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "acked:handling:130247.1788720192.pbH0L2\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
const handoff = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
  events: { on() {}, emit() {} },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 700));
const gateCalls = () => readFileSync(process.env.FM_GATE_LOG, "utf8").split("\n").filter((row) => row !== "").length;
if (gateCalls() !== 2) {
  throw new Error(`the gate must answer exactly once per dropped record, saw ${gateCalls()} calls`);
}
if (prompts.some((message) => message.includes("FIRSTMATE WATCHER WAKE: stale: default:wMA:p2"))) {
  throw new Error(`a dropped replay was re-presented: ${prompts.join(" | ")}`);
}
// Cleanup is now possible again; the bounded retry timer must retire both
// dropped records without consulting the gate a third time.
chmodSync(`${process.env.FM_HOME}/state/extensions/pi-primary-watch`, 0o755);
for (let i = 0; i < 100 && existsSync(handoff); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (existsSync(handoff)) throw new Error("the dropped records were never retired after cleanup became possible");
if (gateCalls() !== 2) {
  throw new Error(`cleanup retries re-consulted the gate: ${gateCalls()} calls`);
}
process.exit(0);
EOF
)
  status=$?
  chmod -R u+w "$home" 2>/dev/null
  expect_code 0 "$status" "a failed handoff cleanup after a gate drop must stay bounded (no re-gating spin)"
  [ -z "$out" ] || fail "Pi replay-spin test printed output: $out"
  pass "a gate drop with a failing handoff cleanup marks the record delivered and stays bounded"
}

# A replayed record whose referenced wake is still unhandled delivers exactly
# once; Pi's acceptance then retires the record, so a further replacement is
# silent. Redelivery is bounded at one presentation per acceptance.
test_pi_replayed_unhandled_wake_delivers_once_then_stops() {
  local repo home plugin stop out status handoff
  repo="$TMP_ROOT/pi-replay-queued-once-root"
  home="$TMP_ROOT/pi-replay-queued-once-home"
  stop="$TMP_ROOT/pi-replay-queued-once.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_replay_gate_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=replay-fixture\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/fm-live.meta`, "window=fm-live\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tstale\tfm-live\tstale: fm-live\n");
const handoff = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff.slice(0, handoff.lastIndexOf("/")), { recursive: true });
writeFileSync(handoff, `${JSON.stringify({
  version: 2,
  pending: [{
    version: 1,
    token: "42-2-3",
    message: "stale: fm-live",
    predecessorArmPid: "",
  }],
})}\n`);

function makePi() {
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
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts, getTool: () => tool };
}

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const first = makePi();
mod.default(first.pi);
await first.handlers.get("session_start")?.({ type: "session_start", reason: "resume" }, {});
for (let i = 0; i < 250 && first.prompts.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (first.prompts.filter((message) => message.includes("stale: fm-live")).length !== 1) {
  throw new Error(`an unhandled replay must present exactly once: ${first.prompts.join(" | ")}`);
}
for (let i = 0; i < 250 && existsSync(handoff); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(handoff)) throw new Error("the accepted replay kept its persisted handoff record");
await first.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});

const second = makePi();
mod.default(second.pi);
await second.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 200));
if (second.prompts.some((message) => message.includes("stale: fm-live"))) {
  throw new Error(`a replay accepted once was presented again: ${second.prompts.join(" | ")}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "an unhandled replay must present once and then stop"
  [ -z "$out" ] || fail "Pi replay-queued-once test printed output: $out"
  pass "an unhandled replay presents once; acceptance retires it for later replacements"
}

# A verified successor can die while the wake it was started for is still
# being delivered (a branch turn can take minutes). Its failure close arrives
# while the pipeline is busy, so the ordinary retry path must be deferred to
# the end of that delivery rather than skipped, or the live generation is left
# with no watcher and no retry.
test_pi_successor_failure_during_delivery_is_retried_after_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-successor-dies-mid-delivery-root"
  home="$TMP_ROOT/pi-successor-dies-mid-delivery-home"
  log="$TMP_ROOT/pi-successor-dies-mid-delivery.log"
  stop="$TMP_ROOT/pi-successor-dies-mid-delivery.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: wake before the successor dies\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  sleep 0.1
  printf 'watcher: FAILED - successor lost its beacon\n'
  exit 3
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let releaseBranch = () => {};
const branchSettlement = new Promise((resolve) => {
  releaseBranch = resolve;
});
let branchAccepted = false;
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
  events: {
    on() {},
    emit(event, data) {
      if (event !== "fm-branch-supervision:dispatch") return;
      branchAccepted = true;
      data.accept(branchSettlement);
    },
  },
};
const arms = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm=")).length
  : 0;
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/mid-delivery.meta`, "project=/projects/mid-delivery\nwindow=fm-mid-delivery\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\tmid-delivery.status\tsignal: wake before the successor dies\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("initial-arm", {}, undefined, undefined, {});
await waitFor(() => branchAccepted, "branch accepted the wake behind a verified successor");
if (arms() !== 2) throw new Error(`expected the verified successor before delivery, got ${arms()} arms`);
// The successor dies while the branch still holds the delivery.
await new Promise((resolve) => setTimeout(resolve, 300));
if (arms() !== 2) throw new Error(`a retry launched while the delivery was still in flight: ${arms()} arms`);
releaseBranch();
await waitFor(() => arms() === 3, "a retry watcher after the delivery settled");
await new Promise((resolve) => setTimeout(resolve, 150));
if (arms() !== 3) throw new Error(`the deferred retry was not single-flight: ${arms()} arms`);
if (prompts.length !== 0) throw new Error(`a bounded retry surfaced a failure prompt: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must retry a verified successor that failed during wake delivery"
  [ -z "$out" ] || fail "Pi successor-dies-mid-delivery test printed output: $out"
  pass "Pi retries a verified successor that failed during wake delivery once that delivery settles"
}

test_pi_late_retiring_actionable_reaches_replacement() {
  local repo home plugin count out status
  repo="$TMP_ROOT/pi-late-retiring-actionable-root"
  home="$TMP_ROOT/pi-late-retiring-actionable-home"
  count="$TMP_ROOT/pi-late-retiring-actionable.count"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
late_close() {
  sleep 0.15
  printf 'signal: late retiring actionable outcome\n'
  exit 0
}
trap late_close TERM INT
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const prompts = [];
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
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const originalMod = await import(pathToFileURL(process.env.PLUGIN).href);
const original = makePi();
originalMod.default(original.pi);
const armed = await original.getTool().execute("initial-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`initial arm failed: ${JSON.stringify(armed.details)}`);
await waitFor(() => existsSync(process.env.FM_ARM_COUNT) && readFileSync(process.env.FM_ARM_COUNT, "utf8").trim() === "1", "original arm");
await original.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
writeFileSync(`${process.env.FM_HOME}/state/extensions`, "block late handoff publication\n");
const foreignState = `${process.env.FM_HOME}/foreign-state`;
const { mkdirSync } = await import("node:fs");
mkdirSync(foreignState, { recursive: true });
writeFileSync(`${foreignState}/.lock`, `${process.pid}\n`);
process.env.FM_STATE_OVERRIDE = foreignState;
const foreignMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=foreign-state`);
const foreign = makePi();
foreignMod.default(foreign.pi);
await foreign.handlers.get("session_start")?.({ type: "session_start", reason: "resume" }, {});
await new Promise((resolve) => setTimeout(resolve, 250));
if (foreign.prompts.some((message) => message.includes("signal: late retiring actionable outcome"))) {
  throw new Error(`late old-state outcome crossed into foreign state: ${foreign.prompts.join(" | ")}`);
}
await foreign.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
delete process.env.FM_STATE_OVERRIDE;

const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=late-retiring-close`);
const replacement = makePi();
replacementMod.default(replacement.pi);
await replacement.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: late retiring actionable outcome")),
  "late actionable delivery to replacement",
);
const latePrompts = replacement.prompts.filter((message) => message.includes("signal: late retiring actionable outcome"));
if (latePrompts.length !== 1) {
  throw new Error(`replacement did not receive exactly one late outcome: ${replacement.prompts.join(" | ")}`);
}
if (!latePrompts[0].includes("watcher: FAILED - Pi extension could not persist a late replacement-session actionable wake")) {
  throw new Error(`late handoff publication failure was not surfaced: ${latePrompts[0]}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement must receive an actionable close after retirement timeout"
  [ -z "$out" ] || fail "Pi late retiring actionable test printed output: $out"
  pass "Pi replacement receives actionable closes after retirement timeout"
}

test_pi_replacement_tokens_are_process_unique() {
  local repo home plugin count out status
  repo="$TMP_ROOT/pi-replacement-token-uniqueness-root"
  home="$TMP_ROOT/pi-replacement-token-uniqueness-home"
  count="$TMP_ROOT/pi-replacement-token-uniqueness.count"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
late_close() {
  sleep 0.08
  printf 'signal: module-%s late actionable outcome\n' "$count"
  exit 0
}
trap late_close TERM INT
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=10 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

Date.now = () => 1700000000000;

function makePi() {
  const handlers = new Map();
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
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
for (let moduleIndex = 1; moduleIndex <= 2; moduleIndex += 1) {
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?token-module=${moduleIndex}`);
  const instance = makePi();
  mod.default(instance.pi);
  const armed = await instance.getTool().execute(`arm-${moduleIndex}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) throw new Error(`module ${moduleIndex} arm failed: ${JSON.stringify(armed.details)}`);
  await waitFor(
    () => existsSync(process.env.FM_ARM_COUNT) && Number(readFileSync(process.env.FM_ARM_COUNT, "utf8").trim()) >= moduleIndex,
    `module ${moduleIndex} arm`,
  );
  await instance.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
}
const handoffPath = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
await waitFor(() => existsSync(handoffPath), "replacement handoff");
await waitFor(() => JSON.parse(readFileSync(handoffPath, "utf8")).pending.length === 2, "two distinct handoff outcomes");
const handoff = JSON.parse(readFileSync(handoffPath, "utf8"));
if (new Set(handoff.pending.map((item) => item.token)).size !== 2) {
  throw new Error(`fresh modules reused a replacement token: ${JSON.stringify(handoff)}`);
}
for (const moduleIndex of [1, 2]) {
  if (!handoff.pending.some((item) => item.message.includes(`signal: module-${moduleIndex} late actionable outcome`))) {
    throw new Error(`module ${moduleIndex} outcome was dropped: ${JSON.stringify(handoff)}`);
  }
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement handoff tokens must stay unique across fresh modules"
  [ -z "$out" ] || fail "Pi replacement token uniqueness test printed output: $out"
  pass "Pi replacement handoff tokens stay unique across fresh modules"
}

test_pi_replacement_persistence_failure_stops_arm_child() {
  local repo home plugin count marker out status
  repo="$TMP_ROOT/pi-replacement-persistence-failure-root"
  home="$TMP_ROOT/pi-replacement-persistence-failure-home"
  count="$TMP_ROOT/pi-replacement-persistence-failure.count"
  marker="$TMP_ROOT/pi-replacement-persistence-failure.marker"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s\n' "$$"
  printf 'signal: persistence failure actionable outcome\n'
  exit 0
fi
cleanup() { rm -f "$FM_CHILD_MARKER"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf '%s\n' "$$" > "$FM_CHILD_MARKER"
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_CHILD_MARKER="$marker" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const eventHandlers = new Map();
let tool = null;
let branchAccepted = false;
let releaseDelivery = () => {};
const blockedDelivery = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const prompts = [];
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
  events: {
    on(event, handler) {
      eventHandlers.set(event, [...(eventHandlers.get(event) ?? []), handler]);
    },
    emit(event, data) {
      // Only the FIRST dispatch is claimed by the open branch settlement; the
      // replacement's own delivery must fall back to main.
      if (event === "fm-branch-supervision:dispatch" && !branchAccepted) {
        branchAccepted = true;
        data.accept(blockedDelivery);
      }
      for (const handler of eventHandlers.get(event) ?? []) handler(data);
    },
  },
};

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const armed = await tool.execute("initial-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`initial arm failed: ${JSON.stringify(armed.details)}`);
// The wake is claimed by an accepting branch whose settlement stays open, so
// the record is still undelivered when the session is replaced - the one shape
// that still rides the replacement handoff.
await waitFor(() => branchAccepted && existsSync(process.env.FM_CHILD_MARKER), "blocked delivery and successor child");
writeFileSync(`${process.env.FM_HOME}/state/extensions`, "block handoff directory\n");
let shutdownError = null;
try {
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
} catch (error) {
  shutdownError = error;
}
if (!shutdownError) throw new Error("replacement shutdown hid the handoff persistence failure");
await waitFor(() => !existsSync(process.env.FM_CHILD_MARKER), "successor cleanup after persistence failure");
const { unlinkSync } = await import("node:fs");
unlinkSync(`${process.env.FM_HOME}/state/extensions`);
// Settle the open branch claim so the replacement's delivery can proceed.
releaseDelivery();
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=persistence-failure`);
replacementMod.default(pi);
const replacementStart = handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await replacementStart;
await waitFor(() => prompts.length >= 1, "in-process handoff after persistence failure");
if (!prompts[0].includes("signal: persistence failure actionable outcome")) {
  throw new Error(`replacement lost the in-process actionable outcome: ${prompts.join(" | ")}`);
}
if (!prompts[0].includes("could not persist a replacement-session actionable wake")) {
  throw new Error(`replacement did not surface the persistence failure: ${prompts[0]}`);
}
handlers.get("before_agent_start")?.({ prompt: prompts[0] }, {});
releaseDelivery();
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement shutdown must stop its arm after handoff persistence fails"
  [ -z "$out" ] || fail "Pi replacement persistence-failure cleanup test printed output: $out"
  pass "Pi replacement persistence failure still stops its arm child"
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
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must remain singular across session replacement"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
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
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
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
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
const firstChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const currentChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  if (currentChild !== firstChild) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim() === firstChild) {
  throw new Error("replacement arm child did not start");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 250 ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
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
// The hook starts its attempt without awaiting it, and the plugin answers a
// second attempt from the one already in flight. Join that attempt through the
// coordinator rather than waiting a fixed span: refusing an unowned lock walks
// git and ps probes that can outlast any such span, and the owned-lock event
// below would then be answered from the refusal instead of arming.
const refusal = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (refusal !== "read-only") {
  console.error(`expected a read-only refusal without the session lock, got ${refusal}`);
  process.exit(1);
}
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
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
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
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm=")).length
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
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(armRows[1])) throw new Error(`successor did not receive predecessor identity: ${armRows[1]}`);
if (!rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the follow-up: ${rows.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releasePrompt();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
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
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
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
// Three unready successors each cost the full readiness budget, so wait well
// past their sum. The wait ends as soon as the wake lands.
for (let i = 0; i < 1500 && !prompt; i += 1) {
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
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
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
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
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

test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_redundant_tool_call_is_owned_noop
test_pi_scheduled_retry_call_is_owned_noop
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_branch_offer_owns_actionable_wake
test_pi_branch_offer_flags_heartbeat
test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_check
test_pi_main_only_check_classes_stay_on_main
test_pi_captain_held_signal_stays_on_main
test_pi_unread_pending_reply_forces_later_stale_alias_to_main
test_pi_distinct_files_mixed_batch_routes_whole_batch_to_main
test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_needs_decision
test_pi_heartbeat_restoration_failure_stays_on_main
test_pi_watcher_failure_never_offered_to_branch
test_pi_handling_delivery_failure_is_typed_once
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_session_transition_generation_owner
test_pi_session_replacement_carries_inflight_actionable_close
test_pi_streaming_followup_is_never_redelivered_after_replacement
test_pi_replayed_acked_wake_of_torn_down_task_is_dropped
test_pi_replayed_signal_wake_of_torn_down_task_is_dropped
test_pi_gate_drop_survives_handoff_cleanup_failure_without_spinning
test_pi_replayed_unhandled_wake_delivers_once_then_stops
test_pi_streaming_time_delivery_keeps_the_successor_chain
test_pi_successor_failure_during_delivery_is_retried_after_delivery
test_pi_late_retiring_actionable_reaches_replacement
test_pi_replacement_tokens_are_process_unique
test_pi_replacement_persistence_failure_stops_arm_child
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
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
