#!/usr/bin/env bash
# Behavioral contract checks for the opt-in local Captain's Inbox producer and reader.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-inbox)
EXT="$ROOT/.pi/extensions/fm-captain-inbox.ts"
CLI="$ROOT/bin/fm-captain-inbox.sh"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node not found for Captain's Inbox contract test"
  exit 0
fi

out=$(EXT="$EXT" CLI="$CLI" OPERATIONAL_INPUT="$OPERATIONAL_INPUT" TMP_ROOT="$TMP_ROOT" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { execFile as execFileCallback, execFileSync } from "node:child_process";
import { chmod, lstat, mkdir, readFile, utimes, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";

const execFile = promisify(execFileCallback);
const extensionPath = process.env.EXT;
const cli = process.env.CLI;
const operationalInput = process.env.OPERATIONAL_INPUT;
const root = process.env.TMP_ROOT;
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function runCli(home, ...args) {
  return execFile(cli, args, {
    env: {
      ...process.env,
      FM_HOME: home,
      FM_STATE_OVERRIDE: `${home}/state`,
      FM_CONFIG_OVERRIDE: `${home}/config`,
    },
  });
}

async function list(home) {
  const { stdout } = await runCli(home, "list");
  return JSON.parse(stdout);
}

async function expectCliFailure(home, args, pattern) {
  try {
    await runCli(home, ...args);
  } catch (error) {
    assert.match(`${error.message}\n${error.stderr ?? ""}`, pattern);
    return;
  }
  throw new Error(`Captain's Inbox command unexpectedly succeeded: ${args.join(" ")}`);
}

async function eventually(check, message) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (await check()) return;
    await delay(10);
  }
  throw new Error(message);
}

async function makeHome(name, { enabled = true, lock = String(process.pid), secondmate = false } = {}) {
  const home = `${root}/${name}`;
  await mkdir(`${home}/config`, { recursive: true });
  await mkdir(`${home}/state`, { recursive: true });
  await writeFile(`${home}/state/.lock`, `${lock}\n`);
  if (enabled) await writeFile(`${home}/config/captain-inbox`, "on\n");
  if (secondmate) await writeFile(`${home}/.fm-secondmate-home`, "inbox-test\n");
  return home;
}

async function loadExtension(home, harness = "pi") {
  process.env.FM_HOME = home;
  process.env.FM_STATE_OVERRIDE = `${home}/state`;
  process.env.FM_CONFIG_OVERRIDE = `${home}/config`;
  process.env.FM_PI_HARNESS = harness;
  const handlers = new Map();
  const pi = {
    on(name, handler) {
      handlers.set(name, handler);
    },
  };
  const extension = await import(`${pathToFileURL(extensionPath).href}?case=${encodeURIComponent(home)}-${Date.now()}-${Math.random()}`);
  extension.default(pi);
  return { handlers, ctx: {
    mode: "tui",
    isIdle: () => true,
    sessionManager: { getSessionId: () => "captain-session" },
  } };
}

function assistant(content, timestamp, stopReason = "stop") {
  return {
    role: "assistant",
    content,
    stopReason,
    timestamp,
  };
}

async function deliver(runtime, {
  source = "interactive",
  text = "Captain request",
  prompt = text,
  message = assistant([{ type: "text", text: "Captain response" }], Date.parse("2026-08-01T00:00:00.000Z")),
} = {}) {
  runtime.handlers.get("input")({ source, text }, runtime.ctx);
  runtime.handlers.get("before_agent_start")({ prompt }, runtime.ctx);
  runtime.handlers.get("message_end")({ message }, runtime.ctx);
  runtime.handlers.get("agent_settled")({}, runtime.ctx);
}

const disabled = await makeHome("disabled", { enabled: false });
const disabledRuntime = await loadExtension(disabled);
await deliver(disabledRuntime);
await delay(50);
assert.equal(existsSync(`${disabled}/state/captain-inbox`), false, "opt-out created Inbox state");
await expectCliFailure(disabled, ["list"], /disabled/);

const home = await makeHome("primary");
const runtime = await loadExtension(home);
const firstTimestamp = Date.parse("2026-08-01T00:00:00.000Z");
const body = "<b>literal response text</b>\nNothing here is HTML.";
const first = assistant([{ type: "thinking", thinking: "private" }, { type: "text", text: body }], firstTimestamp);
await deliver(runtime, { message: first });
await eventually(async () => (await list(home)).messages.length === 1, "primary response was not captured");

let inbox = await list(home);
assert.equal(inbox.version, 1, "list did not expose the versioned consumer contract");
assert.equal(inbox.messages[0].body, body, "capture changed the plain response body");
assert.deepEqual(inbox.messages[0].source, { harness: "pi", session_id: "captain-session" }, "capture leaked or omitted source metadata");
assert.equal(inbox.messages[0].read, false, "new message was not unread");
assert.match(inbox.messages[0].id, /^ci_v1_[a-f0-9]{32}$/, "message ID was not stable contract syntax");
const firstId = inbox.messages[0].id;

await deliver(runtime, { message: first });
await delay(50);
assert.equal((await list(home)).messages.length, 1, "duplicate completed event created another message");

const ignoredCases = [
  {
    message: { role: "user", content: "Captain prompt", timestamp: firstTimestamp + 1 },
  },
  {
    message: assistant([{ type: "thinking", thinking: "private only" }], firstTimestamp + 2),
  },
  {
    message: assistant([{ type: "text", text: "intermediate" }, { type: "toolCall", id: "tool", name: "read", arguments: {} }], firstTimestamp + 3, "toolUse"),
  },
  {
    source: "extension",
    text: "routine internal notification",
    message: assistant([{ type: "text", text: "routine internal response" }], firstTimestamp + 4),
  },
];
for (const ignored of ignoredCases) await deliver(runtime, ignored);
const encodedOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "internal watcher notification",
}).trimEnd();
await deliver(runtime, {
  text: encodedOperational,
  prompt: encodedOperational,
  message: assistant([{ type: "text", text: "operational response" }], firstTimestamp + 5),
});
await delay(50);
assert.equal((await list(home)).messages.length, 1, "filter captured a prompt, tool path, or operational response");

await runCli(home, "mark", firstId, "read");
inbox = await list(home);
assert.equal(inbox.messages[0].read, true, "mark read did not persist independently");
await runCli(home, "mark", firstId, "unread");
assert.equal((await list(home)).messages[0].read, false, "mark unread did not persist independently");
await expectCliFailure(home, ["list", "/tmp/unrelated"], /invalid/);

if (process.platform !== "win32") {
  for (const [path, expected] of [
    [`${home}/state/captain-inbox`, 0o700],
    [`${home}/state/captain-inbox/v1`, 0o700],
    [`${home}/state/captain-inbox/v1/messages.json`, 0o600],
    [`${home}/state/captain-inbox/v1/read-state.json`, 0o600],
  ]) {
    assert.equal((await lstat(path)).mode & 0o777, expected, `unexpected private mode for ${path}`);
  }
}

for (let index = 0; index < 100; index += 1) {
  const timestamp = firstTimestamp + 10_000 + index;
  const retainedBody = `retained-message-${index}`;
  await deliver(runtime, {
    text: `Captain request ${index}`,
    message: assistant([{ type: "text", text: retainedBody }], timestamp),
  });
  await eventually(
    async () => (await list(home)).messages.some((message) => message.body === retainedBody),
    `retention fixture ${index} was not captured`,
  );
}
inbox = await list(home);
assert.equal(inbox.messages.length, 100, "retention did not keep the conservative bounded default");
assert.equal(inbox.messages.some((message) => message.id === firstId), false, "retention kept the oldest record");
assert.equal(inbox.messages.some((message) => message.body === body), false, "retention retained a pruned response body");

const staleLock = await makeHome("stale-lock");
const staleLockDirectory = `${staleLock}/state/captain-inbox/v1`;
await mkdir(staleLockDirectory, { recursive: true, mode: 0o700 });
await chmod(`${staleLock}/state/captain-inbox`, 0o700);
await chmod(staleLockDirectory, 0o700);
await writeFile(`${staleLockDirectory}/messages.json`, '{"version":1,"messages":[]}\n', { mode: 0o600 });
await writeFile(`${staleLockDirectory}/read-state.json`, '{"version":1,"states":{}}\n', { mode: 0o600 });
await mkdir(`${staleLockDirectory}/.lock`, { mode: 0o700 });
await writeFile(`${staleLockDirectory}/.lock/owner`, "stale-owner-token", { mode: 0o600 });
const staleTimestamp = new Date(Date.now() - 10 * 60 * 1000);
await utimes(`${staleLockDirectory}/.lock`, staleTimestamp, staleTimestamp);

const staleListStart = Date.now();
const staleInbox = await list(staleLock);
const staleListElapsed = Date.now() - staleListStart;
assert.equal(staleInbox.messages.length, 0, "stale-lock reclaim returned unexpected messages");
assert.ok(staleListElapsed < 2000, `stale lock was not reclaimed promptly (took ${staleListElapsed}ms)`);
assert.equal(existsSync(`${staleLockDirectory}/.lock`), false, "stale lock directory was left behind after reclaim");

const liveLock = await makeHome("live-lock");
const liveLockDirectory = `${liveLock}/state/captain-inbox/v1`;
await mkdir(liveLockDirectory, { recursive: true, mode: 0o700 });
await chmod(`${liveLock}/state/captain-inbox`, 0o700);
await chmod(liveLockDirectory, 0o700);
await writeFile(`${liveLockDirectory}/messages.json`, '{"version":1,"messages":[]}\n', { mode: 0o600 });
await writeFile(`${liveLockDirectory}/read-state.json`, '{"version":1,"states":{}}\n', { mode: 0o600 });
await mkdir(`${liveLockDirectory}/.lock`, { mode: 0o700 });
await writeFile(`${liveLockDirectory}/.lock/owner`, "a-live-holder-token", { mode: 0o600 });
await expectCliFailure(liveLock, ["list"], /busy/);
assert.equal(await readFile(`${liveLockDirectory}/.lock/owner`, "utf8"), "a-live-holder-token", "a fresh (non-stale) lock was reclaimed or its ownership token was disturbed");

const malformed = await makeHome("malformed");
await mkdir(`${malformed}/state/captain-inbox/v1`, { recursive: true });
await chmod(`${malformed}/state/captain-inbox`, 0o700);
await chmod(`${malformed}/state/captain-inbox/v1`, 0o700);
const malformedContent = '{"version":1,"messages":[{}]}\n';
await writeFile(`${malformed}/state/captain-inbox/v1/messages.json`, malformedContent, { mode: 0o600 });
const malformedRuntime = await loadExtension(malformed);
await deliver(malformedRuntime, { message: assistant([{ type: "text", text: "must not overwrite malformed state" }], firstTimestamp) });
await delay(50);
await expectCliFailure(malformed, ["list"], /malformed/);
assert.equal(await readFile(`${malformed}/state/captain-inbox/v1/messages.json`, "utf8"), malformedContent, "malformed storage was overwritten");

const concurrent = await makeHome("concurrent");
const concurrentRuntime = await loadExtension(concurrent, "pi-signed");
for (const [index, text] of ["one", "two"].entries()) {
  await deliver(concurrentRuntime, {
    message: assistant([{ type: "text", text }], firstTimestamp + 20_000 + index),
  });
  await eventually(async () => (await list(concurrent)).messages.some((message) => message.body === text), "concurrent fixture was not captured");
}
const concurrentMessages = await list(concurrent);
const concurrentResults = await Promise.all([
  ...concurrentMessages.messages.map((message) => runCli(concurrent, "mark", message.id, "read")),
  ...Array.from({ length: 4 }, () => list(concurrent)),
]);
for (const snapshot of concurrentResults.slice(concurrentMessages.messages.length)) {
  assert.equal(snapshot.version, 1, "concurrent reader received an invalid snapshot");
  assert.equal(snapshot.messages.length, 2, "concurrent reader observed incomplete message membership");
}
const afterConcurrentMarks = await list(concurrent);
assert.equal(afterConcurrentMarks.messages.length, 2, "concurrent update changed message membership");
assert.equal(afterConcurrentMarks.messages.every((message) => message.read), true, "concurrent updates lost a read state");
assert.equal(afterConcurrentMarks.messages.every((message) => message.source.harness === "pi-signed"), true, "pi-signed source identity was not retained");

const worker = await makeHome("worker", { lock: "1" });
const workerRuntime = await loadExtension(worker);
await deliver(workerRuntime);
await delay(50);
assert.equal(existsSync(`${worker}/state/captain-inbox`), false, "non-primary session captured worker output");

const secondmate = await makeHome("secondmate", { secondmate: true });
const secondmateRuntime = await loadExtension(secondmate);
await deliver(secondmateRuntime);
await delay(50);
assert.equal(existsSync(`${secondmate}/state/captain-inbox`), false, "secondmate session captured output");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "Captain's Inbox contract failed: $out"
[ -z "$out" ] || fail "Captain's Inbox contract printed output: $out"
pass "Captain's Inbox is opt-in, filters only completed primary Pi responses, preserves private atomic consumer records, and supports bounded concurrent read-state updates"
