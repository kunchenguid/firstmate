#!/usr/bin/env bash
# Tests for the tracked omp primary watcher and turn-end guard extensions,
# plus omp secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-watch-extension)
WATCH_EXT="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"
GUARD_EXT="$ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .omp/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

install_omp_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.omp/extensions/lib" "$repo/bin"
  cp "$WATCH_EXT" "$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cp "$GUARD_EXT" "$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.omp/extensions/lib/fm-operational-input.ts" "$repo/.omp/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
}

test_tracked_extensions_present_and_self_hashing() {
  local text expected_config_source
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$WATCH_EXT" "tracked omp primary watcher extension is missing"
  assert_present "$GUARD_EXT" "tracked omp primary turn-end guard extension is missing"
  text=$(cat "$WATCH_EXT")
  assert_contains "$text" "fm_watch_arm_omp" "tracked watcher extension missing tool name"
  assert_contains "$text" "fm-watch-arm-omp" "tracked watcher extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked watcher extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "tracked watcher extension missing omp wake API"
  assert_contains "$text" 'encodeFirstmateOperationalInput(' "tracked watcher extension does not use the canonical operational-input encoder"
  assert_contains "$text" 'deliverAs: "followUp"' "tracked watcher extension missing followUp delivery"
  assert_contains "$text" 'FM_WATCH_REARM_RETRY_LIMIT' "tracked watcher extension missing bounded failure-path restarts"
  assert_contains "$text" 'FM_OMP_WATCH_STABLE_MS' "tracked watcher extension missing genuine-stability retry reset"
  assert_contains "$text" 'process.hrtime.bigint()' "tracked watcher extension missing monotonic readiness stability timing"
  assert_contains "$text" ".omp-watch-delivery-failed" "tracked watcher extension missing durable delivery-failure marker"
  assert_contains "$text" ".omp-watch-extension-loaded" "tracked watcher extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "watcher extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "watcher extension does not self-locate via import.meta.url"
  assert_contains "$text" 'if (lockOwnership() === "other") return' "watcher extension overwrites another live session marker"
  assert_contains "$text" 'if (ownership === "other") return { ok: false' "watcher extension arm does not preserve the live-other read-only refusal"
  assert_contains "$text" "no live session holds the lock" "watcher extension arm missing stale-lock recovery guidance"
  assert_contains "$text" "call fm_watch_arm_omp to re-arm" "watcher extension arm does not direct supervision re-arm"
  assert_contains "$text" "$expected_config_source" "watcher extension does not source the effective x-mode config"
  assert_contains "$text" "exec \\\"\$FM_WATCH_ARM_SCRIPT\\\" --restart" "watcher extension does not restart into an omp-owned watcher child"
  assert_contains "$text" 'label: "Arm firstmate watcher"' "watcher extension tool is missing its human-readable label"
  assert_contains "$text" "pi.zod.object({})" "watcher extension tool is not using omp's canonical zod schema"
  assert_contains "$text" 'content: [{ type: "text", text: result.message }]' "watcher extension tool is missing text content"
  assert_contains "$text" 'details: result' "watcher extension tool is missing structured result details"
  assert_contains "$text" 'process.once("exit", cleanupOnProcessExit)' "watcher extension lacks clean-process-exit cleanup"
  text=$(cat "$GUARD_EXT")
  assert_contains "$text" "session_stop" "guard extension does not listen for omp's blockable session_stop"
  assert_contains "$text" "continue: true" "guard extension does not force a continuation when the guard blocks"
  assert_contains "$text" "TURN WOULD END BLIND" "guard extension continuation missing the blind-turn reason"
  assert_contains "$text" "guardContinueActive" "guard extension lacks the one-continuation loop-guard latch"
  assert_contains "$text" ".omp-turnend-extension-loaded" "guard extension missing loaded marker"
  assert_contains "$text" "fm-turnend-guard.sh" "guard extension does not run the shared guard predicate"
  assert_contains "$text" '["--omp"]' "guard extension does not request total-supervision Omp mode"
  assert_contains "$text" "fm-arm-pretool-check.sh" "guard extension does not run the watcher-arm PreToolUse seatbelt"
  assert_contains "$text" "fm-cd-pretool-check.sh" "guard extension does not run the cd-guard PreToolUse seatbelt"
  assert_contains "$text" "fm-subagent-pretool-check.sh" "guard extension does not route non-bash tools through the delegation guard"
  assert_contains "$text" "block: true" "guard extension does not block tool calls on a seatbelt deny"
  assert_contains "$text" "fm-sessionstart-nudge.sh" "guard extension does not run the session-start nudge wrapper"
  assert_contains "$text" "firstmate-sessionstart-nudge" "guard extension missing the nudge custom message type"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "guard extension does not self-hash its own content for extensionVersion"
  pass "omp primary extensions are tracked, self-hashing, and self-locating"
}

test_omp_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-tool-result-root"
  home="$TMP_ROOT/omp-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
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
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {},
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("omp watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not an object schema");
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started omp extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "omp custom tool must return the agent tool result shape"
  [ -z "$out" ] || fail "omp tool-result test printed output: $out"
  pass "omp custom tool returns text content and structured details"
}

test_omp_wake_uses_canonical_watcher_input() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-wake-root"
  home="$TMP_ROOT/omp-wake-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  log="$home/arm.log"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')" -eq 1 ]; then
  printf 'signal: /tmp/omp-wake.status\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let sent = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async (content, options) => {
    sent = { content, options };
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-1", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !sent; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const expected =
  "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /tmp/omp-wake.status\n\n" +
  "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
if (sent?.content !== expected) {
  throw new Error(`unexpected watcher input: ${JSON.stringify(sent?.content)}`);
}
if (sent?.options?.deliverAs !== "followUp") {
  throw new Error(`unexpected delivery: ${JSON.stringify(sent?.options)}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watcher wake must use the canonical watcher operational input"
  [ -z "$out" ] || fail "omp watcher encoding test printed output: $out"
  pass "omp watcher wake uses canonical watcher operational input"
}

test_omp_delivery_rejection_keeps_successor_and_status() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-delivery-rejection-root"
  home="$TMP_ROOT/omp-delivery-rejection-home"
  log="$home/arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')" -eq 1 ]; then
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {
    throw new Error("synthetic send rejection");
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-rejection", {}, undefined, undefined, {});
const statusPath = `${process.env.FM_HOME}/state/.omp-watch-delivery-failed`;
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && existsSync(statusPath)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor lacks predecessor identity: ${rows[1]}`);
const failure = readFileSync(statusPath, "utf8");
if (!failure.includes("synthetic send rejection")) throw new Error(`missing durable rejection detail: ${failure}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery rejection duplicated arms: ${stableRows.length}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp delivery rejection must preserve successor supervision and durable failure state"
  [ -z "$out" ] || fail "omp delivery-rejection test printed output: $out"
  out=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1/bin/fm-watch.sh"; scan_signals' _ "$ROOT")
  [ -z "$out" ] || fail "omp delivery-failure marker retriggered the watcher signal scan: $out"
  pass "omp delivery rejection preserves successor supervision and durable failure state"
}

test_omp_typed_failure_starts_successor_before_rejected_delivery() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-typed-failure-root"
  home="$TMP_ROOT/omp-typed-failure-home"
  log="$home/arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')" -eq 1 ]; then
  printf 'watcher: FAILED - synthetic typed arm failure\n'
  exit 7
fi
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {
    throw new Error("synthetic typed-failure delivery rejection");
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-typed-failure", {}, undefined, undefined, {});
const markerPath = `${process.env.FM_HOME}/state/.omp-watch-delivery-failed`;
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && existsSync(markerPath)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`typed arm failure did not start exactly one successor: ${rows.length}`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`typed-failure successor lacks predecessor identity: ${rows[1]}`);
const marker = readFileSync(markerPath, "utf8");
if (!marker.includes("synthetic typed arm failure")) throw new Error(`marker lost typed arm failure: ${marker}`);
if (!marker.includes("synthetic typed-failure delivery rejection")) throw new Error(`marker lost delivery rejection: ${marker}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`typed failure duplicated successor arms: ${stableRows.length}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp typed arm failures must start a successor before rejected delivery"
  [ -z "$out" ] || fail "omp typed-failure successor test printed output: $out"
  pass "omp typed arm failures preserve successor supervision before delivery"
}

test_omp_established_failures_stay_within_retry_cap() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-established-failure-root"
  home="$TMP_ROOT/omp-established-failure-home"
  log="$home/arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
printf 'watcher: started synthetic established cycle\n'
sleep 0.02
printf 'watcher: FAILED - synthetic established arm failure\n'
exit 7
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=2 FM_OMP_WATCH_STABLE_MS=1000 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveries = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {
    deliveries += 1;
    throw new Error("synthetic established-failure delivery rejection");
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-failure", {}, undefined, undefined, {});
const markerPath = `${process.env.FM_HOME}/state/.omp-watch-delivery-failed`;
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 3 && deliveries >= 3 && existsSync(markerPath)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 150));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 3) throw new Error(`established failures bypassed the two-retry cap: ${rows.length}`);
if (deliveries !== 3) throw new Error(`established failure deliveries bypassed the cap: ${deliveries}`);
const marker = readFileSync(markerPath, "utf8");
if (!marker.includes("could not restore watcher continuity after 2 retries")) {
  throw new Error(`established failure marker lost the cap detail: ${marker}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp established failures must preserve the retry attempt count; output: $out"
  [ -z "$out" ] || fail "omp established-failure cap test printed output: $out"
  pass "omp established failures stay within the restart cap"
}

test_omp_delayed_readiness_does_not_reset_retry_budget() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-delayed-readiness-root"
  home="$TMP_ROOT/omp-delayed-readiness-home"
  log="$home/arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
sleep 0.08
printf 'watcher: started synthetic delayed-readiness cycle\n'
printf 'watcher: FAILED - synthetic immediate post-readiness failure\n'
exit 7
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=2 FM_OMP_WATCH_STABLE_MS=50 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveries = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {
    deliveries += 1;
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-delayed-readiness", {}, undefined, undefined, {});
for (let i = 0; i < 500; i += 1) {
  if (deliveries >= 3) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 50));
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`delayed readiness bypassed the two-retry cap: ${rows.length}`);
if (deliveries !== 3) throw new Error(`delayed-readiness deliveries bypassed the cap: ${deliveries}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp delayed readiness must not count pre-ready startup as stability; output: $out"
  [ -z "$out" ] || fail "omp delayed-readiness retry-cap test printed output: $out"
  pass "omp delayed readiness preserves the restart cap"
}

test_omp_stable_cycle_resets_retry_budget() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-stable-cycle-root"
  home="$TMP_ROOT/omp-stable-cycle-home"
  log="$home/arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
arm_count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
case "$arm_count" in
  1)
    printf 'watcher: FAILED - synthetic initial arm failure\n'
    exit 7
    ;;
  2)
    printf 'watcher: started synthetic stable cycle\n'
    : > "${FM_READY_MARKER:?}"
    while [ ! -f "${FM_RELEASE_MARKER:?}" ]; do sleep 0.01; done
    printf 'watcher: FAILED - synthetic post-stability failure\n'
    exit 7
    ;;
  3)
    printf 'watcher: FAILED - synthetic retry after stable cycle\n'
    exit 7
    ;;
esac
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_READY_MARKER="$home/ready" FM_RELEASE_MARKER="$home/release" FM_WATCH_REARM_RETRY_LIMIT=2 FM_OMP_WATCH_STABLE_MS=50 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {},
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-stable-cycle", {}, undefined, undefined, {});
for (let i = 0; i < 500; i += 1) {
  if (existsSync(process.env.FM_READY_MARKER)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_READY_MARKER)) throw new Error("stable watcher never reported readiness");
await new Promise((resolve) => setTimeout(resolve, 80));
writeFileSync(process.env.FM_RELEASE_MARKER, "\n");
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 4) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 4) throw new Error(`stable watcher cycle did not reset the retry budget: ${rows.length}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`stable-cycle reset duplicated arms: ${stableRows.length}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp genuinely stable cycles must reset the retry budget; output: $out"
  [ -z "$out" ] || fail "omp stable-cycle retry-reset test printed output: $out"
  pass "omp stable cycles reset the restart budget"
}

test_omp_spawn_errors_retry_with_cap() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-spawn-error-root"
  home="$TMP_ROOT/omp-spawn-error-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { EventEmitter } from "node:events";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { PassThrough } from "node:stream";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveries = 0;
let spawns = 0;
const require = createRequire(import.meta.url);
const childProcessModule = require("node:child_process");
const realSpawn = childProcessModule.spawn;
childProcessModule.spawn = () => {
  spawns += 1;
  const child = new EventEmitter();
  child.pid = 1000 + spawns;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => true;
  process.nextTick(() => child.emit("error", new Error("synthetic spawn failure")));
  return child;
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {
    deliveries += 1;
    throw new Error("synthetic spawn-error delivery rejection");
  },
  zod: { object: (properties) => ({ type: "object", properties }) },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const armResult = await tool.execute("tool-call-spawn-error", {}, undefined, undefined, {});
const markerPath = `${process.env.FM_HOME}/state/.omp-watch-delivery-failed`;
for (let i = 0; i < 500 && (spawns < 3 || deliveries < 3 || !existsSync(markerPath)); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
childProcessModule.spawn = realSpawn;
syncBuiltinESMExports();
if (spawns !== 3) throw new Error(`spawn-error restarts were not capped at two: ${spawns}; arm=${JSON.stringify(armResult)}`);
if (deliveries !== 3) throw new Error(`spawn-error restarts were not capped at two: ${deliveries}; arm=${JSON.stringify(armResult)}`);
const marker = readFileSync(markerPath, "utf8");
if (!marker.includes("failed: synthetic spawn failure")) throw new Error(`marker lost spawn error: ${marker}`);
if (!marker.includes("synthetic spawn-error delivery rejection")) throw new Error(`marker lost spawn delivery rejection: ${marker}`);
await new Promise((resolve) => setTimeout(resolve, 100));
if (deliveries !== 3) throw new Error(`spawn-error delivery loop exceeded cap: ${deliveries}`);
EOF
)
  status=$?
  expect_code 0 "$status" "omp spawn errors must retry with a bounded successor cap; output: $out"
  [ -z "$out" ] || fail "omp spawn-error cap test printed output: $out"
  pass "omp spawn errors preserve bounded successor retries"
}

test_omp_arm_distinguishes_session_lock_ownership() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-lock-root"
  home="$TMP_ROOT/omp-lock-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendUserMessage: async () => {},
  zod: { object: (properties) => ({ type: "object", properties }) },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

// Lock held by another live session (pid 1 is never in this process's ancestry).
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "1\n");
mod.default(pi);
const refused = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (refused.details?.ok !== false || !refused.content[0].text.includes("read-only")) {
  throw new Error(`expected live-other refusal: ${refused.content[0].text}`);
}

// Lock held by THIS session: the arm starts and the marker records the pid.
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const started = await tool.execute("tool-call-2", {}, undefined, undefined, {});
if (started.details?.ok !== true || !started.content[0].text.includes("started omp extension arm child")) {
  throw new Error(`expected arm start: ${started.content[0].text}`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8");
if (!marker.includes(String(process.pid))) {
  throw new Error(`marker missing owning pid: ${marker}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "omp arm must distinguish live-other from owned session locks"
  [ -z "$out" ] || fail "omp lock-ownership test printed output: $out"
  pass "omp arm distinguishes session lock ownership"
}

test_omp_guard_session_stop_continue_and_latch() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-guard-root"
  home="$TMP_ROOT/omp-guard-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'GUARD-REASON: no live watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
const pi = {
  on(event, handler) { handlers[event] = handler; },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers.session_stop !== "function") throw new Error("session_stop handler not registered");

const first = await handlers.session_stop();
if (first?.continue !== true) throw new Error(`first stop must continue: ${JSON.stringify(first)}`);
if (!String(first.additionalContext).includes("TURN WOULD END BLIND")) {
  throw new Error(`missing blind-turn reason: ${first.additionalContext}`);
}
if (!String(first.additionalContext).includes("GUARD-REASON")) {
  throw new Error(`missing guard stderr: ${first.additionalContext}`);
}

const second = await handlers.session_stop();
if (second?.continue) throw new Error("the forced continuation's own stop must be allowed (latch)");

const third = await handlers.session_stop();
if (third?.continue !== true) throw new Error("guard must block again after the latch clears");
EOF
)
  status=$?
  expect_code 0 "$status" "omp guard must continue once on a blocking guard, then latch"
  [ -z "$out" ] || fail "omp guard session_stop test printed output: $out"
  pass "omp guard session_stop continues once and latches"
}

test_omp_guard_session_stop_blocks_x_mode_only() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-guard-x-root"
  home="$TMP_ROOT/omp-guard-x-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  : > "$home/state/x-watch.check.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --omp ] || exit 0
[ -f "$FM_STATE_OVERRIDE/x-watch.check.sh" ] || exit 0
printf 'GUARD-REASON: X-mode needs supervision\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
const pi = {
  on(event, handler) { handlers[event] = handler; },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await handlers.session_stop();
if (result?.continue !== true) throw new Error(`X-mode-only stop must continue: ${JSON.stringify(result)}`);
if (!String(result.additionalContext).includes("X-mode needs supervision")) {
  throw new Error(`missing X-mode reason: ${result.additionalContext}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "omp session_stop must request total-supervision guard mode for X-mode-only homes"
  [ -z "$out" ] || fail "omp X-mode session_stop test printed output: $out"
  pass "omp session_stop blocks X-mode-only blind turns"
}

test_omp_guard_tool_call_blocks_on_seatbelt_deny() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-seatbelt-root"
  home="$TMP_ROOT/omp-seatbelt-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'DENY-ARM: [watcher-background] nope\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo"/bin/*.sh
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
const pi = {
  on(event, handler) { handlers[event] = handler; },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers.tool_call !== "function") throw new Error("tool_call handler not registered");

const blocked = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } });
if (blocked?.block !== true) throw new Error(`expected block: ${JSON.stringify(blocked)}`);
if (!String(blocked.reason).includes("DENY-ARM")) throw new Error(`missing deny reason: ${blocked.reason}`);

const allowed = await handlers.tool_call({ type: "tool_call", toolName: "read", input: { path: "x" } });
if (allowed?.block) throw new Error("non-bash tools must not be blocked");

const noCommand = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: {} });
if (noCommand?.block) throw new Error("empty bash command must not be blocked");
EOF
)
  status=$?
  expect_code 0 "$status" "omp guard must block bash tool calls on a seatbelt exit 2"
  [ -z "$out" ] || fail "omp seatbelt test printed output: $out"
  pass "omp guard blocks bash tool calls on a seatbelt deny"
}

test_omp_guard_tool_call_routes_nonbash_through_subagent_checker() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-subagent-root"
  home="$TMP_ROOT/omp-subagent-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SUBAGENT_LOG"
if [ "${2:-}" = task ]; then
  printf 'DENY-SUBAGENT: [subagent-dispatch] nope\n' >&2
  exit 2
fi
exit 0
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo"/bin/*.sh
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_SUBAGENT_LOG="$home/subagent.log" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
const pi = {
  on(event, handler) { handlers[event] = handler; },
  registerCommand() {},
  registerTool() {},
  sendMessage() {},
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers.tool_call !== "function") throw new Error("tool_call handler not registered");

const blocked = await handlers.tool_call({ type: "tool_call", toolName: "task", input: { prompt: "do work" } });
if (blocked?.block !== true) throw new Error(`expected block: ${JSON.stringify(blocked)}`);
if (!String(blocked.reason).includes("DENY-SUBAGENT")) throw new Error(`missing deny reason: ${blocked.reason}`);

const allowed = await handlers.tool_call({ type: "tool_call", toolName: "read", input: { path: "x" } });
if (allowed?.block) throw new Error("ordinary non-bash tools must not be blocked");

await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "echo hi" } });
EOF
)
  status=$?
  expect_code 0 "$status" "omp guard must route non-bash tools through the delegation guard"
  [ -z "$out" ] || fail "omp subagent test printed output: $out"
  assert_grep '--tool task' "$home/subagent.log" "subagent checker did not receive the task tool name"
  assert_grep '--tool read' "$home/subagent.log" "subagent checker did not receive the read tool name"
  ! grep -F 'bash' "$home/subagent.log" >/dev/null || fail "subagent checker saw a bash tool call"
  pass "omp guard routes non-bash tools through the delegation guard"
}

test_omp_guard_sessionstart_nudge_uses_sendMessage() {
  local repo home plugin out status
  repo="$TMP_ROOT/omp-nudge-root"
  home="$TMP_ROOT/omp-nudge-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cat > "$repo/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'NUDGE-LINE: run bin/fm-session-start.sh\n'
exit 0
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo"/bin/*.sh
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
let sent = null;
const pi = {
  on(event, handler) { handlers[event] = handler; },
  registerCommand() {},
  registerTool() {},
  sendMessage(message) { sent = message; },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers.session_start !== "function") throw new Error("session_start handler not registered");
handlers.session_start({ type: "session_start" });
if (!sent) throw new Error("nudge was not sent");
if (sent.customType !== "firstmate-sessionstart-nudge") throw new Error(`wrong customType: ${sent.customType}`);
if (!String(sent.content).includes("NUDGE-LINE")) throw new Error(`wrong content: ${sent.content}`);
if (sent.display !== false) throw new Error("nudge must not render in the transcript");
EOF
)
  status=$?
  expect_code 0 "$status" "omp guard must inject the session-start nudge as a hidden custom message"
  [ -z "$out" ] || fail "omp nudge test printed output: $out"
  pass "omp guard injects the session-start nudge via sendMessage"
}

test_tracked_extensions_present_and_self_hashing
test_omp_tool_returns_agent_tool_result
test_omp_wake_uses_canonical_watcher_input
test_omp_delivery_rejection_keeps_successor_and_status
test_omp_typed_failure_starts_successor_before_rejected_delivery
test_omp_established_failures_stay_within_retry_cap
test_omp_delayed_readiness_does_not_reset_retry_budget
test_omp_stable_cycle_resets_retry_budget
test_omp_spawn_errors_retry_with_cap
test_omp_arm_distinguishes_session_lock_ownership
test_omp_guard_session_stop_continue_and_latch
test_omp_guard_session_stop_blocks_x_mode_only
test_omp_guard_tool_call_blocks_on_seatbelt_deny
test_omp_guard_tool_call_routes_nonbash_through_subagent_checker
test_omp_guard_sessionstart_nudge_uses_sendMessage
