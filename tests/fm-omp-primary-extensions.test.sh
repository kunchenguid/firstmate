#!/usr/bin/env bash
# Behavioral contract for OMP's project-local watcher and turn-end extensions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-primary-extensions)
FIXTURE="$TMP_ROOT/fixture"
STATE="$TMP_ROOT/state"
mkdir -p "$FIXTURE/.omp/extensions" "$FIXTURE/bin" "$STATE"
cp "$ROOT/.omp/extensions/fm-primary-watch.ts" "$FIXTURE/.omp/extensions/"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$FIXTURE/.omp/extensions/"

cat > "$FIXTURE/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = encode ] || exit 2
cat
SH
cat > "$FIXTURE/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:?}
source=${2:-missing}
printf '%s\n' "$source" >> "$state/sessionstart-sources"
if [ -f "$state/block-next-sessionstart" ]; then
  rm -f "$state/block-next-sessionstart"
  count=0
  [ ! -f "$state/sessionstart-block-count" ] || count=$(cat "$state/sessionstart-block-count")
  count=$((count + 1))
  printf '%s\n' "$count" > "$state/sessionstart-block-count"
  (
    trap 'printf "sessionstart-descendant-term %s\n" "$$" >> "$state/sessionstart-cleanup.log"; exit 0' TERM INT
    while :; do sleep 0.05; done
  ) &
  descendant_pid=$!
  printf '%s\n' "$descendant_pid" >> "$state/sessionstart-descendant-pids"
  cleanup() {
    printf 'sessionstart-runner-term %s\n' "$count" >> "$state/sessionstart-cleanup.log"
    kill -TERM "$descendant_pid" 2>/dev/null || true
    wait "$descendant_pid" 2>/dev/null || true
    printf 'sessionstart-runner-reaped %s\n' "$count" >> "$state/sessionstart-cleanup.log"
    exit 0
  }
  trap cleanup TERM INT
  wait "$descendant_pid"
fi
printf 'session-start context from OMP fixture (%s)\n' "$source"
SH
cat > "$FIXTURE/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "${FM_STATE_OVERRIDE:?}/guard-inputs"
printf 'repair watcher through fm_watch_arm_omp\n' >&2
exit 2
SH
cat > "$FIXTURE/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *unsafe-cd*) printf 'blocked unsafe cd\n' >&2; exit 2 ;; esac
exit 0
SH
cat > "$FIXTURE/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *unsafe-arm*) printf 'blocked unsafe arm\n' >&2; exit 2 ;; esac
exit 0
SH
cat > "$FIXTURE/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:?}
log="$state/watcher.log"
case "${1:-}" in
  --handling-delivered)
    printf 'confirm %s %s\n' "${2:-}" "${4:-}" >> "$log"
    exit 0
    ;;
  --restart)
    count=0
    [ ! -f "$state/arm-count" ] || count=$(cat "$state/arm-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$state/arm-count"
    printf 'start %s pid=%s\n' "$count" "$$" >> "$log"
    printf 'watcher: started pid=%s generation=%s recovery-generation=g%s\n' "$$" "$count" "$count"
    if [ "$count" -eq 1 ]; then
      printf 'signal: fixture task completed\n'
      exit 0
    fi
    if [ "$count" -eq 2 ]; then
      sleep 0.05
      printf 'signal: successor task completed\n'
      exit 0
    fi
    (
      trap 'printf "watch-child-term %s\n" "$$" >> "$log"; exit 0' TERM INT
      while :; do sleep 0.05; done
    ) &
    watcher_pid=$!
    printf '%s\n' "$watcher_pid" > "$state/watcher-child-pid"
    cleanup() {
      printf 'arm-term %s\n' "$count" >> "$log"
      kill -TERM "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
      printf 'arm-reaped %s\n' "$count" >> "$log"
      exit 0
    }
    trap cleanup TERM INT
    wait "$watcher_pid"
    ;;
esac
exit 2
SH
chmod +x "$FIXTURE/bin/"*.sh

cat > "$TMP_ROOT/watch-driver.mjs" <<'JS'
import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFileSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = process.env.FM_STATE_OVERRIDE;
rmSync(`${state}/.lock`, { force: true });
const handlers = new Map();
let tool;
const session = { file: "session-a.jsonl" };
let deliveries = 0;
const context = {
  sessionManager: { getSessionFile: () => session.file },
  ui: { notify: () => {} },
};
const api = {
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: async (content) => {
    deliveries += 1;
    const delivery = deliveries;
    appendFileSync(`${state}/watcher.log`, `deliver-start ${delivery}\n`);
    await new Promise((resolve) => setTimeout(resolve, 100));
    appendFileSync(`${state}/watcher.log`, `deliver ${delivery}\n`);
    writeFileSync(`${state}/delivery-${delivery}`, content);
  },
  registerCommand: () => {},
  registerTool: (definition) => { tool = definition; },
  zod: { object: () => ({}) },
};
const extension = await import(pathToFileURL(process.env.WATCH_EXTENSION).href);
extension.default(api);
const coldMarker = readFileSync(`${state}/.omp-watch-extension-loaded`, "utf8").trim().split(/\n/);
if (coldMarker[1] !== String(process.pid)) {
  throw new Error(`watcher cold-start marker owner was ${coldMarker[1] ?? "missing"}`);
}
rmSync(`${state}/.omp-watch-extension-loaded`);
const foreignOwner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
writeFileSync(`${state}/.lock`, `${foreignOwner.pid}\n`);
await handlers.get("session_start")?.({ type: "session_start" }, {});
const foreignMarkerPublished = existsSync(`${state}/.omp-watch-extension-loaded`);
const foreignClosed = once(foreignOwner, "close");
foreignOwner.kill("SIGTERM");
await foreignClosed;
if (foreignMarkerPublished) {
  throw new Error("watcher extension replaced a different live lock owner's marker");
}
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
await handlers.get("session_start")?.({ type: "session_start" }, context);
const foreignContext = {
  sessionManager: { getSessionFile: () => "session-b.jsonl" },
  ui: { notify: () => {} },
};
const foreign = await tool.execute("call-foreign", {}, undefined, undefined, foreignContext);
if (foreign.details.ok) throw new Error("foreign session generation armed the watcher");
const result = await tool.execute("call-1", {}, undefined, undefined, context);
if (!result.details.ok) throw new Error(`arm tool failed: ${result.details.message}`);
const deadline = Date.now() + 5000;
while (!existsSync(`${state}/delivery-2`) && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(`${state}/delivery-2`)) throw new Error("successor watcher wake was not delivered");
let log = readFileSync(`${state}/watcher.log`, "utf8").trim().split(/\n/);
const start1 = log.findIndex((line) => line.startsWith("start 1 "));
const start2 = log.findIndex((line) => line.startsWith("start 2 "));
const start3 = log.findIndex((line) => line.startsWith("start 3 "));
const confirm2 = log.findIndex((line) => line.startsWith("confirm g2 "));
const deliver1 = log.indexOf("deliver 1");
const confirm3 = log.findIndex((line) => line.startsWith("confirm g3 "));
const deliver2 = log.indexOf("deliver 2");
if (!(start1 >= 0 && start2 > start1 && confirm2 > start2 && deliver1 > confirm2
  && start3 > deliver1 && confirm3 > start3 && deliver2 > confirm3)) {
  throw new Error(`successor closure restoration order was ${log.join(" | ")}`);
}
const firstMessage = readFileSync(`${state}/delivery-1`, "utf8");
const secondMessage = readFileSync(`${state}/delivery-2`, "utf8");
if (!firstMessage.includes("signal: fixture task completed")) throw new Error("initial actionable wake was lost");
if (!secondMessage.includes("signal: successor task completed")) throw new Error("successor actionable wake was lost");
if (!existsSync(`${state}/.omp-watch-extension-loaded`)) throw new Error("watcher health marker missing after lock acquisition");
if (handlers.has("session_stop")) throw new Error("ordinary session_stop must not terminate watcher supervision");
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, context);
log = readFileSync(`${state}/watcher.log`, "utf8").trim().split(/\n/);
for (const expected of ["arm-term 3", "arm-reaped 3"]) {
  if (!log.includes(expected)) throw new Error(`session_shutdown bypassed watcher cleanup: ${log.join(" | ")}`);
}
if (!log.some((line) => line.startsWith("watch-child-term "))) {
  throw new Error(`session_shutdown did not terminate the watcher child: ${log.join(" | ")}`);
}
const watcherChildPid = Number(readFileSync(`${state}/watcher-child-pid`, "utf8").trim());
try {
  process.kill(watcherChildPid, 0);
  throw new Error(`session_shutdown left watcher child ${watcherChildPid} alive`);
} catch (error) {
  if (error instanceof Error && error.message.includes("left watcher child")) throw error;
}
JS

cat > "$TMP_ROOT/watch-exit-driver.mjs" <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = process.env.FM_STATE_OVERRIDE;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map();
let tool;
const context = { sessionManager: { getSessionFile: () => "exit-session.jsonl" } };
const api = {
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: async () => {},
  registerCommand: () => {},
  registerTool: (definition) => { tool = definition; },
  zod: { object: () => ({}) },
};
const extension = await import(pathToFileURL(process.env.WATCH_EXTENSION).href);
extension.default(api);
await handlers.get("session_start")?.({ type: "session_start" }, context);
const result = await tool.execute("exit-arm", {}, undefined, undefined, context);
if (!result.details.ok) throw new Error(`exit arm failed: ${result.details.message}`);
const deadline = Date.now() + 3000;
while (!existsSync(`${state}/watcher-child-pid`) && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(`${state}/watcher-child-pid`)) throw new Error("exit arm did not start its watcher child");
process.exit(0);
JS

cat > "$TMP_ROOT/watch-exit-assert.mjs" <<'JS'
import { existsSync, readFileSync } from "node:fs";

const state = process.env.FM_STATE_OVERRIDE;
const deadline = Date.now() + 3000;
let log = "";
while (Date.now() < deadline) {
  log = existsSync(`${state}/watcher.log`) ? readFileSync(`${state}/watcher.log`, "utf8") : "";
  if (log.includes("arm-reaped 3") && log.includes("watch-child-term ")) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!log.includes("arm-term 3") || !log.includes("arm-reaped 3") || !log.includes("watch-child-term ")) {
  throw new Error(`process exit bypassed the watcher arm cleanup trap: ${log}`);
}
const watcherPid = Number(readFileSync(`${state}/watcher-child-pid`, "utf8").trim());
try {
  process.kill(watcherPid, 0);
  throw new Error(`process exit left watcher child ${watcherPid} alive`);
} catch (error) {
  if (error instanceof Error && error.message.includes("left watcher child")) throw error;
}
JS

cat > "$TMP_ROOT/guard-driver.mjs" <<'JS'
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = process.env.FM_STATE_OVERRIDE;
rmSync(`${state}/.lock`, { force: true });
const handlers = new Map();
const api = { on: (event, handler) => handlers.set(event, handler) };
const contextA = { sessionManager: { getSessionFile: () => "session-a.jsonl" } };
const contextB = { sessionManager: { getSessionFile: () => "session-b.jsonl" } };
const contextC = { sessionManager: { getSessionFile: () => "session-c.jsonl" } };
const contextD = { sessionManager: { getSessionFile: () => "session-d.jsonl" } };
const extension = await import(pathToFileURL(process.env.GUARD_EXTENSION).href);
extension.default(api);
if (!existsSync(`${state}/.omp-turnend-extension-loaded`)) {
  throw new Error("turn-end extension did not publish its cold-start marker");
}
const coldMarker = readFileSync(`${state}/.omp-turnend-extension-loaded`, "utf8").trim().split(/\n/);
if (coldMarker[1] !== String(process.pid)) {
  throw new Error(`turn-end cold-start marker owner was ${coldMarker[1] ?? "missing"}`);
}
rmSync(`${state}/.omp-turnend-extension-loaded`);
const foreignOwner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
writeFileSync(`${state}/.lock`, `${foreignOwner.pid}\n`);
handlers.get("session_start")?.({ type: "session_start" }, {});
const foreignMarkerPublished = existsSync(`${state}/.omp-turnend-extension-loaded`);
const foreignClosed = once(foreignOwner, "close");
foreignOwner.kill("SIGTERM");
await foreignClosed;
if (foreignMarkerPublished) {
  throw new Error("turn-end extension replaced a different live lock owner's marker");
}
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
handlers.get("session_start")?.({ type: "session_start" }, contextA);
const initial = await handlers.get("before_agent_start")?.({}, contextA);
if (!initial?.message?.content?.includes("(startup)")) throw new Error("startup context was not delivered through OMP");
if (await handlers.get("before_agent_start")?.({}, contextA)) throw new Error("startup context was delivered twice");

handlers.get("session_switch")?.({ type: "session_switch", reason: "new" }, contextB);
if (await handlers.get("before_agent_start")?.({}, contextA)) throw new Error("stale session received replacement context");
const switched = await handlers.get("before_agent_start")?.({}, contextB);
if (!switched?.message?.content?.includes("(clear)")) throw new Error("/new did not receive clear session-start context");
handlers.get("session_switch")?.({ type: "session_switch", reason: "resume" }, contextC);
const resumed = await handlers.get("before_agent_start")?.({}, contextC);
if (!resumed?.message?.content?.includes("(resume)")) throw new Error("/resume did not receive resume session-start context");
handlers.get("session_switch")?.({ type: "session_switch", reason: "fork" }, contextD);
const forked = await handlers.get("before_agent_start")?.({}, contextD);
if (!forked?.message?.content?.includes("(fork)")) throw new Error("/fork did not receive fork session-start context");
handlers.get("session_compact")?.({ type: "session_compact" }, contextD);
const compacted = await handlers.get("before_agent_start")?.({}, contextD);
if (!compacted?.message?.content?.includes("(compact)")) throw new Error("compaction did not receive refreshed session-start context");

const staleTool = await handlers.get("tool_call")?.(
  { type: "tool_call", toolName: "bash", input: { command: "true" } },
  contextA,
);
if (!staleTool?.block || !staleTool.reason.includes("active session generation")) {
  throw new Error("foreign session tool event was not rejected");
}
const cd = await handlers.get("tool_call")?.({ type: "tool_call", toolName: "bash", input: { command: "unsafe-cd" } }, contextD);
if (!cd?.block || !cd.reason.includes("unsafe cd")) throw new Error("cd pre-tool guard did not block");
const arm = await handlers.get("tool_call")?.({ type: "tool_call", toolName: "bash", input: { command: "unsafe-arm" } }, contextD);
if (!arm?.block || !arm.reason.includes("unsafe arm")) throw new Error("arm pre-tool guard did not block");
const stop = await handlers.get("session_stop")?.({ type: "session_stop", stop_hook_active: true }, contextD);
if (stop?.decision !== "block" || !stop.reason.includes("fm_watch_arm_omp")) {
  throw new Error("session_stop did not return OMP's native block result");
}
const guardInputs = readFileSync(`${state}/guard-inputs`, "utf8").trim().split(/\n/);
if (guardInputs.at(-1) !== '{"stop_hook_active":true}') throw new Error(`stop-hook marker was lost: ${guardInputs.join(" | ")}`);
const staleStop = await handlers.get("session_stop")?.({ type: "session_stop" }, contextA);
if (staleStop?.decision !== "block" || !staleStop.reason.includes("active session generation")) {
  throw new Error("foreign session stop event was not rejected");
}
if (!existsSync(`${state}/.omp-turnend-extension-loaded`)) throw new Error("turn-end health marker missing after lock acquisition");
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, contextD);
const sources = readFileSync(`${state}/sessionstart-sources`, "utf8").trim().split(/\n/);
if (sources.join(",") !== "startup,clear,resume,fork,compact") throw new Error(`session lifecycle sources were ${sources.join(",")}`);
JS

cat > "$TMP_ROOT/guard-cleanup-driver.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = process.env.FM_STATE_OVERRIDE;
const handlers = new Map();
const api = { on: (event, handler) => handlers.set(event, handler) };
const contextA = { sessionManager: { getSessionFile: () => "cleanup-a.jsonl" } };
const contextB = { sessionManager: { getSessionFile: () => "cleanup-b.jsonl" } };

function descendantPids() {
  if (!existsSync(`${state}/sessionstart-descendant-pids`)) return [];
  return readFileSync(`${state}/sessionstart-descendant-pids`, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map(Number);
}

async function waitFor(predicate, description) {
  const deadline = Date.now() + 3000;
  while (!predicate() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!predicate()) throw new Error(`timed out waiting for ${description}`);
}

function assertDead(pid, description) {
  try {
    process.kill(pid, 0);
    throw new Error(`${description} ${pid} is still alive`);
  } catch (error) {
    if (error instanceof Error && error.message.includes("is still alive")) throw error;
  }
}

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
writeFileSync(`${state}/block-next-sessionstart`, "");
const extension = await import(pathToFileURL(process.env.GUARD_EXTENSION).href);
extension.default(api);
handlers.get("session_start")?.({ type: "session_start" }, contextA);
await waitFor(() => descendantPids().length === 1, "the first session-start descendant");

writeFileSync(`${state}/block-next-sessionstart`, "");
handlers.get("session_switch")?.({ type: "session_switch", reason: "new" }, contextB);
await waitFor(() => descendantPids().length === 2, "replacement after reaping the first process group");
let pids = descendantPids();
assertDead(pids[0], "session change leaked descendant");
let cleanupLog = readFileSync(`${state}/sessionstart-cleanup.log`, "utf8");
for (const expected of ["sessionstart-runner-term 1", "sessionstart-runner-reaped 1"]) {
  if (!cleanupLog.includes(expected)) throw new Error(`session change skipped ${expected}: ${cleanupLog}`);
}

await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, contextB);
pids = descendantPids();
for (const pid of pids) assertDead(pid, "session shutdown leaked descendant");
cleanupLog = readFileSync(`${state}/sessionstart-cleanup.log`, "utf8");
for (const expected of [
  "sessionstart-descendant-term",
  "sessionstart-runner-term 2",
  "sessionstart-runner-reaped 2",
]) {
  if (!cleanupLog.includes(expected)) throw new Error(`session shutdown skipped ${expected}: ${cleanupLog}`);
}
JS

FM_HOME="$FIXTURE" FM_ROOT_OVERRIDE="$FIXTURE" FM_STATE_OVERRIDE="$STATE" \
  WATCH_EXTENSION="$FIXTURE/.omp/extensions/fm-primary-watch.ts" \
  FM_WATCH_REARM_RETRY_BASE_MS=10 FM_WATCH_REARM_RETRY_MAX_MS=20 FM_OMP_ARM_READY_TIMEOUT_MS=1000 \
  node --experimental-strip-types "$TMP_ROOT/watch-driver.mjs" \
  || fail "OMP watcher did not load, preserve marker ownership, restore continuity, and reap its watcher child"
pass "OMP watcher loads, publishes only valid markers, restores continuity, and reaps its child"

rm -f \
  "$STATE/arm-count" \
  "$STATE/delivery" \
  "$STATE/watcher-child-pid" \
  "$STATE/watcher.log"
FM_HOME="$FIXTURE" FM_ROOT_OVERRIDE="$FIXTURE" FM_STATE_OVERRIDE="$STATE" \
  WATCH_EXTENSION="$FIXTURE/.omp/extensions/fm-primary-watch.ts" \
  FM_WATCH_REARM_RETRY_BASE_MS=10 FM_WATCH_REARM_RETRY_MAX_MS=20 FM_OMP_ARM_READY_TIMEOUT_MS=1000 \
  node --experimental-strip-types "$TMP_ROOT/watch-exit-driver.mjs" \
  || fail "OMP process-exit cleanup driver failed"
FM_STATE_OVERRIDE="$STATE" node "$TMP_ROOT/watch-exit-assert.mjs" \
  || fail "OMP process exit did not reap the watcher descendant"
pass "OMP process exit runs the watcher arm cleanup trap and reaps its child"

rm -f "$STATE/.lock"
FM_HOME="$FIXTURE" FM_ROOT_OVERRIDE="$FIXTURE" FM_STATE_OVERRIDE="$STATE" \
  GUARD_EXTENSION="$FIXTURE/.omp/extensions/fm-primary-turnend-guard.ts" \
  node --experimental-strip-types "$TMP_ROOT/guard-driver.mjs" \
  || fail "OMP primary guard did not preserve marker ownership, session-start, pre-tool, and turn-end behavior"
pass "OMP primary guard publishes only valid markers and preserves native lifecycle behavior"

rm -f \
  "$STATE/sessionstart-block-count" \
  "$STATE/sessionstart-cleanup.log" \
  "$STATE/sessionstart-descendant-pids"
FM_HOME="$FIXTURE" FM_ROOT_OVERRIDE="$FIXTURE" FM_STATE_OVERRIDE="$STATE" \
  GUARD_EXTENSION="$FIXTURE/.omp/extensions/fm-primary-turnend-guard.ts" \
  node --experimental-strip-types "$TMP_ROOT/guard-cleanup-driver.mjs" \
  || fail "OMP session-start process groups were not fully retired"
pass "OMP session changes and shutdown reap session-start descendants"

echo "# all fm-omp-primary-extensions tests passed"
