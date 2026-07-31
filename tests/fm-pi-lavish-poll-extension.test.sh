#!/usr/bin/env bash
# Deterministic public-interface coverage for Pi's completion-aware Lavish relay.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-lavish-poll-extension)
EXT="$ROOT/.pi/extensions/fm-lavish-poll.ts"
FIXTURE="$TMP_ROOT/fixture"
HOME_DIR="$FIXTURE/home"
CONTROL="$FIXTURE/control"
FAKE="$FIXTURE/fake-lavish-axi"
PROJECT="$FIXTURE/project"

mkdir -p \
  "$HOME_DIR/state" \
  "$CONTROL" \
  "$PROJECT/.pi/extensions" \
  "$PROJECT/node_modules/@earendil-works/pi-coding-agent" \
  "$PROJECT/node_modules/@earendil-works/pi-ai" \
  "$PROJECT/node_modules/typebox"
cp "$EXT" "$PROJECT/.pi/extensions/fm-lavish-poll.ts"
printf '<!doctype html><title>one</title>\n' >"$PROJECT/one.html"
printf '<!doctype html><title>two</title>\n' >"$PROJECT/two.html"

cat >"$PROJECT/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
cat >"$PROJECT/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export const unused = true;
JS
cat >"$PROJECT/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
cat >"$PROJECT/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export function StringEnum(values) { return { type: "string", enum: [...values] }; }
JS
cat >"$PROJECT/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
cat >"$PROJECT/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) { return { type: "object", properties, additionalProperties: false }; },
  Optional(schema) { return { ...schema, optional: true }; },
  String(options = {}) { return { type: "string", ...options }; },
};
JS

cat >"$FAKE" <<'SH'
#!/bin/sh
set -u
control=${FM_FAKE_LAVISH_CONTROL:?}
while ! mkdir "$control/counter.lock" 2>/dev/null; do sleep 0.01; done
count=0
[ ! -f "$control/counter" ] || count=$(sed -n '1p' "$control/counter")
count=$((count + 1))
printf '%s\n' "$count" >"$control/counter"
rmdir "$control/counter.lock"
{
  printf '%s\n' "invocation=$count"
  for arg in "$@"; do printf 'arg=<%s>\n' "$arg"; done
} >>"$control/argv.log"
printf '%s\n' "$$" >"$control/pid.$count"
trap 'printf "term=%s\n" "$count" >>"$control/term.log"; exit 143' TERM INT
while [ ! -f "$control/release.$count" ]; do sleep 0.02; done
[ ! -f "$control/stdout.$count" ] || cat "$control/stdout.$count"
[ ! -f "$control/stderr.$count" ] || cat "$control/stderr.$count" >&2
code=0
[ ! -f "$control/code.$count" ] || code=$(sed -n '1p' "$control/code.$count")
exit "$code"
SH
chmod +x "$FAKE"

cat >"$CONTROL/stdout.1" <<'EOF'
session:
  status: feedback
prompts[1]{tag,text}:
  review,"SYNTHETIC_FEEDBACK_ONE"
next_step: continue review
EOF
cat >"$CONTROL/stdout.2" <<'EOF'
session:
  status: feedback
prompts[1]{tag,text}:
  review,"SYNTHETIC_FEEDBACK_TWO"
next_step: continue review
EOF
cat >"$CONTROL/stdout.3" <<'EOF'
error: synthetic poll command failure
code: SERVER_ERROR
EOF
printf '7\n' >"$CONTROL/code.3"
cat >"$CONTROL/stdout.4" <<'EOF'
session:
  status: feedback
prompts[1]{tag,text}:
  review,"MUST_NOT_DELIVER_AFTER_STOP"
EOF
python3 - "$CONTROL/stdout.6" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("session:\n  status: feedback\n")
    f.write('dom_snapshot: "' + ("DOM_SECRET_MUST_NOT_ENTER_CONTEXT" * 30000) + '"\n')
    f.write('prompts[1]{tag,text}:\n  review,"BOUNDED_PROMPT_SURVIVES"\n')
    f.write("next_step: continue review\n")
PY
cat >"$CONTROL/stdout.7" <<'EOF'
session:
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{tag,text}:
  review,"FINAL_SYNTHETIC_FEEDBACK"
next_step: stop polling
EOF
cat >"$CONTROL/stdout.10" <<'EOF'
error: synthetic replacement-generation failure
code: SERVER_ERROR
EOF
printf '9\n' >"$CONTROL/code.10"

out=$(cd "$PROJECT" && \
  PLUGIN="$PROJECT/.pi/extensions/fm-lavish-poll.ts" \
  FM_HOME="$HOME_DIR" \
  FM_LAVISH_AXI_BIN="$FAKE" \
  FM_FAKE_LAVISH_CONTROL="$CONTROL" \
  node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, readdirSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool;
const messages = [];
const statuses = [];
let userMessages = 0;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerTool(candidate) { if (candidate.name === "fm_lavish_poll") tool = candidate; },
  sendMessage(message, options) { messages.push({ message, options }); },
  sendUserMessage() { userMessages += 1; },
};
const ui = {
  setStatus(key, value) { statuses.push({ key, value }); },
};
const ctx = {
  cwd: process.cwd(),
  ui,
  sessionManager: { getSessionId() { return "session-generation-one"; } },
};

async function waitFor(predicate, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}
function control(name) { return resolve(process.env.FM_FAKE_LAVISH_CONTROL, name); }
function artifact(name) { return resolve(process.cwd(), name); }
function release(n) { writeFileSync(control(`release.${n}`), "release\n"); }
function pidAlive(pid) {
  try { process.kill(Number(pid), 0); return true; } catch { return false; }
}
async function invoke(params) {
  return tool.execute(`call-${Date.now()}-${Math.random()}`, params, undefined, undefined, ctx);
}
function assertMessage(index, kind, needle) {
  const row = messages[index];
  if (!row) throw new Error(`missing relay message ${index}`);
  if (row.message.customType !== "firstmate-lavish-feedback") throw new Error(`untyped relay message: ${row.message.customType}`);
  if (!row.message.content.startsWith(`LAVISH_RELAY_RESULT v1 kind=${kind}`)) throw new Error(`wrong relay kind: ${row.message.content}`);
  if (!row.message.content.includes(needle)) throw new Error(`relay message omitted ${needle}: ${row.message.content}`);
  if (row.options?.triggerTurn !== true || row.options?.deliverAs !== "followUp") throw new Error(`wrong delivery options: ${JSON.stringify(row.options)}`);
}

const listenersBeforeImport = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("fm_lavish_poll tool was not registered");
if (process.listenerCount("exit") !== listenersBeforeImport) throw new Error("extension factory started a process-exit resource");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (!metadata.includes("instead of foreground bash polling") || !metadata.includes("never run `lavish-axi poll` through foreground bash")) {
  throw new Error(`tool guidance does not replace foreground polling: ${metadata}`);
}
if (!metadata.includes("fleet watcher supervision remains separate")) throw new Error("tool guidance conflated Lavish with watcher supervision");
if (tool.parameters?.properties?.action?.enum?.join(",") !== "start,status,stop") throw new Error("tool action schema is not a strict string enum");
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
if (!existsSync(resolve(process.env.FM_HOME, "state/.pi-lavish-extension-loaded"))) throw new Error("loaded marker missing");

const startAt = Date.now();
const first = await invoke({ action: "start", artifact: "one.html" });
if (!first.details?.ok || !first.content[0]?.text.includes("conversation remains available")) throw new Error(`start failed: ${JSON.stringify(first)}`);
if (Date.now() - startAt > 500) throw new Error("start waited for the poll instead of returning immediately");
await waitFor(() => existsSync(control("pid.1")), "first fake poll");
if (process.listenerCount("exit") !== listenersBeforeImport + 1) throw new Error("active poll did not install exactly one exit fallback");
const responsive = await invoke({ action: "status", artifact: "one.html" });
if (!responsive.content[0]?.text.includes("waiting for")) throw new Error(`status unavailable while poll waited: ${responsive.content[0]?.text}`);
const duplicate = await invoke({ action: "start", artifact: "./one.html" });
if (duplicate.details?.ok !== false || !duplicate.content[0]?.text.includes("already waiting")) throw new Error(`duplicate was not refused: ${JSON.stringify(duplicate)}`);
if (readFileSync(control("counter"), "utf8").trim() !== "1") throw new Error("duplicate start launched a second child");
release(1);
await waitFor(() => messages.length === 1, "first feedback wake");
assertMessage(0, "feedback", "SYNTHETIC_FEEDBACK_ONE");
if (userMessages !== 0) throw new Error("relay impersonated the user");
if (process.listenerCount("exit") !== listenersBeforeImport) throw new Error("completed poll left its exit listener installed");

const maliciousReply = `Applied feedback; literal $(touch ${control("pwned")})`;
const second = await invoke({ action: "start", artifact: "one.html", agent_reply: maliciousReply });
if (!second.details?.ok) throw new Error(`agent reply start failed: ${JSON.stringify(second)}`);
await waitFor(() => existsSync(control("pid.2")), "second fake poll");
const argv = readFileSync(control("argv.log"), "utf8");
if (!argv.includes("arg=<--agent-reply>") || !argv.includes(`arg=<${maliciousReply}>`)) throw new Error(`agent reply did not stay one literal argv value: ${argv}`);
if (existsSync(control("pwned"))) throw new Error("agent reply was interpreted by a shell");
release(2);
await waitFor(() => messages.length === 2, "second feedback wake");
assertMessage(1, "feedback", "SYNTHETIC_FEEDBACK_TWO");

const fatal = await invoke({ action: "start", artifact: "one.html" });
if (!fatal.details?.ok) throw new Error("fatal fixture did not start");
await waitFor(() => existsSync(control("pid.3")), "fatal fake poll");
release(3);
await waitFor(() => messages.length === 3, "fatal wake");
assertMessage(2, "fatal", "synthetic poll command failure");
const fatalDiagnostic = messages[2].message.details?.diagnosticPath;
if (!fatalDiagnostic || !existsSync(fatalDiagnostic)) throw new Error("fatal result did not retain a private diagnostic pointer");
if ((statSync(fatalDiagnostic).mode & 0o777) !== 0o600) throw new Error("private diagnostic is not mode 0600");
const completedStop = await invoke({ action: "stop" });
if (!completedStop.details?.ok || !completedStop.content[0]?.text.includes("already idle")) throw new Error("stop-all did not accept a completed result");
if (existsSync(fatalDiagnostic)) throw new Error("explicit stop-all did not retire completed private diagnostics");

const stopped = await invoke({ action: "start", artifact: "one.html" });
if (!stopped.details?.ok) throw new Error("stop fixture did not start");
await waitFor(() => existsSync(control("pid.4")), "stoppable fake poll");
const stop = await invoke({ action: "stop", artifact: "one.html" });
if (!stop.details?.ok || !stop.content[0]?.text.includes("stopped for")) throw new Error(`explicit stop failed: ${JSON.stringify(stop)}`);
await waitFor(() => readFileSync(control("term.log"), "utf8").includes("term=4"), "TERM delivery");
const stoppedPid = readFileSync(control("pid.4"), "utf8").trim();
await waitFor(() => !pidAlive(stoppedPid), "stopped child exit");
await new Promise((resolvePromise) => setTimeout(resolvePromise, 80));
if (messages.length !== 3) throw new Error("explicit stop delivered a late feedback message");

symlinkSync(artifact("two.html"), artifact("alias.html"));
const deletedAliasStart = await invoke({ action: "start", artifact: "alias.html" });
if (!deletedAliasStart.details?.ok) throw new Error("deleted-alias fixture did not start");
await waitFor(() => existsSync(control("pid.5")), "deleted-alias fake poll");
unlinkSync(artifact("alias.html"));
const deletedAliasStatus = await invoke({ action: "status", artifact: "alias.html" });
if (!deletedAliasStatus.content[0]?.text.includes("waiting for")) throw new Error(`deleted-alias status missed active poll: ${deletedAliasStatus.content[0]?.text}`);
const deletedAliasStop = await invoke({ action: "stop", artifact: "alias.html" });
if (!deletedAliasStop.details?.ok || !deletedAliasStop.content[0]?.text.includes("stopped for")) throw new Error(`deleted-alias stop failed: ${JSON.stringify(deletedAliasStop)}`);
await waitFor(() => readFileSync(control("term.log"), "utf8").includes("term=5"), "deleted-alias TERM delivery");
const deletedAliasPid = readFileSync(control("pid.5"), "utf8").trim();
await waitFor(() => !pidAlive(deletedAliasPid), "deleted-alias stopped child exit");
await new Promise((resolvePromise) => setTimeout(resolvePromise, 80));
if (messages.length !== 3) throw new Error("deleted-alias stop delivered a late feedback message");

const boundedStart = await invoke({ action: "start", artifact: "one.html" });
if (!boundedStart.details?.ok) throw new Error("bounded fixture did not start");
await waitFor(() => existsSync(control("pid.6")), "bounded fake poll");
release(6);
await waitFor(() => messages.length === 4, "bounded feedback wake");
assertMessage(3, "feedback", "BOUNDED_PROMPT_SURVIVES");
const boundedContent = messages[3].message.content;
if (Buffer.byteLength(boundedContent, "utf8") > 26000) throw new Error(`injected output was not bounded: ${Buffer.byteLength(boundedContent, "utf8")} bytes`);
if (boundedContent.includes("DOM_SECRET_MUST_NOT_ENTER_CONTEXT")) throw new Error("DOM snapshot leaked into model context");
const boundedDiagnostic = messages[3].message.details?.diagnosticPath;
if (!boundedDiagnostic || !existsSync(boundedDiagnostic)) throw new Error("bounded output omitted its private diagnostic pointer");

const finalStart = await invoke({ action: "start", artifact: "one.html", agent_reply: "Applied bounded feedback" });
if (!finalStart.details?.ok) throw new Error("terminal fixture did not start");
await waitFor(() => existsSync(control("pid.7")), "terminal fake poll");
if (existsSync(boundedDiagnostic)) throw new Error("re-arm did not retire bounded private diagnostics");
release(7);
await waitFor(() => messages.length === 5, "terminal wake");
assertMessage(4, "terminal", "FINAL_SYNTHETIC_FEEDBACK");
const relayDirectory = resolve(process.env.FM_HOME, "state/.pi-lavish-relay");
if (existsSync(relayDirectory) && readdirSync(relayDirectory).length !== 0) throw new Error("review end left private relay records");
const idle = await invoke({ action: "status" });
if (!idle.content[0]?.text.includes("no active polls")) throw new Error(`terminal result left active ownership: ${idle.content[0]?.text}`);

const shutdownOne = await invoke({ action: "start", artifact: "one.html" });
const shutdownTwo = await invoke({ action: "start", artifact: "two.html" });
if (!shutdownOne.details?.ok || !shutdownTwo.details?.ok) throw new Error("shutdown fixtures did not start");
await waitFor(() => existsSync(control("pid.8")) && existsSync(control("pid.9")), "shutdown fake polls");
const beforeShutdownMessages = messages.length;
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, ctx);
for (const n of [8, 9]) {
  const pid = readFileSync(control(`pid.${n}`), "utf8").trim();
  await waitFor(() => !pidAlive(pid), `shutdown child ${n}`);
}
if (messages.length !== beforeShutdownMessages) throw new Error("session shutdown delivered a late relay message");
if (process.listenerCount("exit") !== listenersBeforeImport) throw new Error("session shutdown left the exit listener installed");
if (existsSync(relayDirectory) && readdirSync(relayDirectory).length !== 0) throw new Error("session shutdown left private records");
if (statuses.at(-1)?.value !== undefined) throw new Error("session shutdown left the status row visible");

const replacementCtx = {
  ...ctx,
  sessionManager: { getSessionId() { return "session-generation-two"; } },
};
await handlers.get("session_start")?.({ type: "session_start", reason: "reload" }, replacementCtx);
const replacementStatus = await tool.execute("replacement-status", { action: "status" }, undefined, undefined, replacementCtx);
if (!replacementStatus.content[0]?.text.includes("no active polls")) throw new Error("reload did not establish a clean generation");
const replacementFailure = await tool.execute(
  "replacement-failure",
  { action: "start", artifact: "one.html" },
  undefined,
  undefined,
  replacementCtx,
);
if (!replacementFailure.details?.ok) throw new Error("replacement-generation failure fixture did not start");
await waitFor(() => existsSync(control("pid.10")), "replacement-generation fake poll");
release(10);
await waitFor(() => messages.length === beforeShutdownMessages + 1, "replacement-generation fatal wake");
const replacementDiagnostic = messages.at(-1)?.message.details?.diagnosticPath;
if (!replacementDiagnostic || !existsSync(replacementDiagnostic)) throw new Error("replacement generation did not retain its fatal diagnostic");
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, replacementCtx);
if (existsSync(replacementDiagnostic)) throw new Error("session shutdown did not remove a completed private diagnostic");
if (userMessages !== 0) throw new Error("relay used sendUserMessage at least once");
JS
)
status=$?
expect_code 0 "$status" "Pi Lavish relay must preserve completion, responsiveness, ownership, bounds, and cleanup"
[ -z "$out" ] || fail "Pi Lavish relay deterministic test printed output: $out"
pass "Pi Lavish relay is completion-aware, argv-safe, bounded, exactly-once, and generation-owned"

FAIL_HOME="$TMP_ROOT/failed-start-home"
FAIL_PROJECT="$TMP_ROOT/failed-start-project"
mkdir -p "$FAIL_HOME/state" "$FAIL_PROJECT/.pi/extensions" "$FAIL_PROJECT/node_modules/@earendil-works"
cp "$EXT" "$FAIL_PROJECT/.pi/extensions/fm-lavish-poll.ts"
ln -s "$PROJECT/node_modules/@earendil-works/pi-coding-agent" "$FAIL_PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PROJECT/node_modules/@earendil-works/pi-ai" "$FAIL_PROJECT/node_modules/@earendil-works/pi-ai"
ln -s "$PROJECT/node_modules/typebox" "$FAIL_PROJECT/node_modules/typebox"
printf '<!doctype html><title>failure</title>\n' >"$FAIL_PROJECT/failure.html"
out=$(cd "$FAIL_PROJECT" && \
  PLUGIN="$FAIL_PROJECT/.pi/extensions/fm-lavish-poll.ts" \
  FM_HOME="$FAIL_HOME" \
  FM_LAVISH_AXI_BIN="$FAIL_PROJECT/does-not-exist" \
  node --input-type=module 2>&1 <<'JS'
import { existsSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const messages = [];
const statuses = [];
let tool;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerTool(candidate) { tool = candidate; },
  sendMessage(message, options) { messages.push({ message, options }); },
};
const ctx = {
  cwd: process.cwd(),
  ui: { setStatus(key, value) { statuses.push({ key, value }); } },
  sessionManager: { getSessionId() { return "failed-start-generation"; } },
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
const result = await tool.execute("missing-command", { action: "start", artifact: "failure.html" }, undefined, undefined, ctx);
if (!result.details?.ok) throw new Error(`spawn should return promptly before async ENOENT: ${JSON.stringify(result)}`);
for (let i = 0; i < 300 && messages.length === 0; i += 1) await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
if (messages.length !== 1) throw new Error(`failed start delivered ${messages.length} messages instead of one`);
if (messages[0].message.customType !== "firstmate-lavish-feedback" || !messages[0].message.content.startsWith("LAVISH_RELAY_RESULT v1 kind=fatal")) {
  throw new Error(`failed start did not produce a typed fatal message: ${JSON.stringify(messages[0])}`);
}
if (!messages[0].message.content.includes("ENOENT")) throw new Error(`failed start omitted the command error: ${messages[0].message.content}`);
if (messages[0].message.details?.recordPath || messages[0].message.details?.diagnosticPath) throw new Error("failed start retained a private record");
const relayDirectory = resolve(process.env.FM_HOME, "state/.pi-lavish-relay");
if (existsSync(relayDirectory) && readdirSync(relayDirectory).length !== 0) throw new Error("failed start left private files");
if (process.listenerCount("exit") !== before) throw new Error("failed start left an exit listener");
if (statuses.at(-1)?.value !== undefined) throw new Error("failed start left a waiting status");
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
JS
)
status=$?
expect_code 0 "$status" "Pi Lavish relay must surface a missing executable once and clean failed-start resources"
[ -z "$out" ] || fail "Pi Lavish relay failed-start test printed output: $out"
pass "Pi Lavish relay reports fatal command failure exactly once without residue"

NOOWNER_HOME="$TMP_ROOT/non-owner-home"
NOOWNER_CONTROL="$TMP_ROOT/non-owner-control"
mkdir -p "$NOOWNER_HOME/state" "$NOOWNER_CONTROL"
out=$(cd "$PROJECT" && \
  PLUGIN="$PROJECT/.pi/extensions/fm-lavish-poll.ts" \
  FM_HOME="$NOOWNER_HOME" \
  FM_LAVISH_AXI_BIN="$FAKE" \
  FM_FAKE_LAVISH_CONTROL="$NOOWNER_CONTROL" \
  node --input-type=module 2>&1 <<'JS'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const lockHolder = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
const lockPid = String(lockHolder.pid ?? "");
if (!lockPid) throw new Error("failed to create live lock holder");
try {
  const handlers = new Map();
  let tool;
  const statuses = [];
  const pi = {
    on(name, handler) { handlers.set(name, handler); },
    registerTool(candidate) { tool = candidate; },
    sendMessage() { throw new Error("non-owner session delivered a message"); },
  };
  const ctx = {
    cwd: process.cwd(),
    ui: { setStatus(key, value) { statuses.push({ key, value }); } },
    sessionManager: { getSessionId() { return "non-owner-generation"; } },
  };
  const marker = resolve(process.env.FM_HOME, "state/.pi-lavish-extension-loaded");
  writeFileSync(resolve(process.env.FM_HOME, "state/.lock"), `${lockPid}\n`);
  writeFileSync(marker, "owner-version\n4242\n");
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?non-owner=${Date.now()}`);
  mod.default(pi);
  await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
  if (readFileSync(marker, "utf8") !== "owner-version\n4242\n") throw new Error("non-owner session overwrote the loaded marker");
  const result = await tool.execute("non-owner-start", { action: "start", artifact: "one.html" }, undefined, undefined, ctx);
  if (result.details?.ok !== false || !result.content[0]?.text.includes("another live Firstmate session owns this home")) {
    throw new Error(`non-owner start was not refused: ${JSON.stringify(result)}`);
  }
  if (existsSync(resolve(process.env.FM_FAKE_LAVISH_CONTROL, "counter"))) throw new Error("non-owner start launched a poll child");
  if (statuses.some((entry) => typeof entry.value === "string" && entry.value.includes("waiting"))) {
    throw new Error(`non-owner session showed waiting status: ${JSON.stringify(statuses)}`);
  }
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
} finally {
  lockHolder.kill("SIGTERM");
}
JS
)
status=$?
expect_code 0 "$status" "Pi Lavish relay must reject a non-owner loaded session"
[ -z "$out" ] || fail "Pi Lavish relay non-owner test printed output: $out"
pass "Pi Lavish relay preserves lock-owned markers and refuses non-owner starts"

LOSS_HOME="$TMP_ROOT/ownership-loss-home"
LOSS_CONTROL="$TMP_ROOT/ownership-loss-control"
mkdir -p "$LOSS_HOME/state" "$LOSS_CONTROL"
cat >"$LOSS_CONTROL/stdout.1" <<'EOF'
session:
  status: feedback
prompts[1]{tag,text}:
  review,"MUST_NOT_DELIVER_AFTER_OWNERSHIP_LOSS"
next_step: continue review
EOF
out=$(cd "$PROJECT" && \
  PLUGIN="$PROJECT/.pi/extensions/fm-lavish-poll.ts" \
  FM_HOME="$LOSS_HOME" \
  FM_LAVISH_AXI_BIN="$FAKE" \
  FM_FAKE_LAVISH_CONTROL="$LOSS_CONTROL" \
  node --input-type=module 2>&1 <<'JS'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const messages = [];
let tool;
const statuses = [];
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerTool(candidate) { tool = candidate; },
  sendMessage(message, options) { messages.push({ message, options }); },
};
const ctx = {
  cwd: process.cwd(),
  ui: { setStatus(key, value) { statuses.push({ key, value }); } },
  sessionManager: { getSessionId() { return "ownership-loss-generation"; } },
};
async function waitFor(predicate, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}
function control(name) { return resolve(process.env.FM_FAKE_LAVISH_CONTROL, name); }
const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?ownership-loss=${Date.now()}`);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
const marker = resolve(process.env.FM_HOME, "state/.pi-lavish-extension-loaded");
if (!existsSync(marker)) throw new Error("missing-lock first session did not publish the loaded marker");
const started = await tool.execute("loss-start", { action: "start", artifact: "one.html" }, undefined, undefined, ctx);
if (!started.details?.ok) throw new Error(`missing-lock start was not preserved: ${JSON.stringify(started)}`);
await waitFor(() => existsSync(control("pid.1")), "ownership-loss fake poll");
const lockHolder = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
const lockPid = String(lockHolder.pid ?? "");
if (!lockPid) throw new Error("failed to create replacement lock holder");
try {
  writeFileSync(resolve(process.env.FM_HOME, "state/.lock"), `${lockPid}\n`);
  writeFileSync(control("release.1"), "release\n");
  await waitFor(() => existsSync(control("counter")) && readFileSync(control("counter"), "utf8").trim() === "1", "released poll");
  if (messages.length !== 0) throw new Error(`ownership-lost poll delivered ${messages.length} message(s)`);
  let status;
  for (let i = 0; i < 500; i += 1) {
    status = await tool.execute("loss-status", { action: "status", artifact: "one.html" }, undefined, undefined, ctx);
    if (status.content[0]?.text.includes("no active poll")) break;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  if (!status.content[0]?.text.includes("no active poll")) throw new Error(`ownership-lost poll stayed active: ${status.content[0]?.text}`);
  const second = await tool.execute("loss-second-start", { action: "start", artifact: "one.html" }, undefined, undefined, ctx);
  if (second.details?.ok !== false || !second.content[0]?.text.includes("another live Firstmate session owns this home")) {
    throw new Error(`ownership-lost generation accepted a new start: ${JSON.stringify(second)}`);
  }
} finally {
  lockHolder.kill("SIGTERM");
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, ctx);
}
JS
)
status=$?
expect_code 0 "$status" "Pi Lavish relay must suppress delivery after ownership loss"
[ -z "$out" ] || fail "Pi Lavish relay ownership-loss test printed output: $out"
pass "Pi Lavish relay suppresses delivery and starts after ownership loss"
