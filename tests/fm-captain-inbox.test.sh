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
import { execFile as execFileCallback, execFileSync, spawn } from "node:child_process";
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

function emit(runtime, event, payload) {
  runtime.handlers.get(event)?.(payload, runtime.ctx);
}

async function deliver(runtime, {
  source = "interactive",
  text = "Captain request",
  prompt = text,
  beforeAgentStart = true,
  message = assistant([{ type: "text", text: "Captain response" }], Date.parse("2026-08-01T00:00:00.000Z")),
} = {}) {
  emit(runtime, "input", { source, text });
  if (beforeAgentStart) emit(runtime, "before_agent_start", { prompt });
  emit(runtime, "message_end", { message });
  emit(runtime, "agent_settled", {});
}

function queueOperationalFollowUp(runtime, text) {
  // Pi emits input when sendUserMessage queues a follow-up while the agent is
  // streaming, but that queued continuation has no matching before_agent_start.
  emit(runtime, "input", { source: "extension", text });
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

const queuedOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "a watcher notification queued while Pi is streaming",
}).trimEnd();
const knowledgebaseOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "Project Knowledgebase MVP ready",
}).trimEnd();
const dashboardOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "dashboard update ready",
}).trimEnd();
const knowledgebaseResponse = "Captain, the Project Knowledgebase MVP is ready.";
const dashboardResponse = "Captain, the dashboard update is ready.";
const logResponse = "Captain, Captain’s Log test received after the dashboard update.";

// This is the exact poisoning sequence from the Pi extension API.
// An operational follow-up emits input while streaming and has no matching
// before_agent_start, so the old FIFO left a false eligibility entry behind.
// The later idle operational runs and fresh direct input each shifted that stale
// false entry and their finalized visible assistant messages were dropped.
queueOperationalFollowUp(runtime, queuedOperational);
await deliver(runtime, {
  source: "extension",
  text: knowledgebaseOperational,
  prompt: knowledgebaseOperational,
  message: assistant([{ type: "text", text: knowledgebaseResponse }], firstTimestamp + 5),
});
await deliver(runtime, {
  source: "extension",
  text: dashboardOperational,
  prompt: dashboardOperational,
  message: assistant([{ type: "text", text: dashboardResponse }], firstTimestamp + 6),
});
await deliver(runtime, {
  text: "captains log test",
  message: assistant([{ type: "text", text: logResponse }], firstTimestamp + 7),
});
await eventually(async () => (await list(home)).messages.length === 4, "operational or post-operational direct responses were not captured");
inbox = await list(home);
assert.deepEqual(
  inbox.messages.map((message) => message.body).sort(),
  [body, knowledgebaseResponse, dashboardResponse, logResponse].sort(),
  "the direct and operational finalized assistant responses did not reach the dashboard",
);

const ignoredCases = [
  {
    message: { role: "user", content: "Captain prompt", timestamp: firstTimestamp + 8 },
  },
  {
    message: assistant([{ type: "thinking", thinking: "private only" }], firstTimestamp + 9),
  },
  {
    message: assistant([{ type: "text", text: "intermediate" }, { type: "toolCall", id: "tool", name: "read", arguments: {} }], firstTimestamp + 10, "toolUse"),
  },
  {
    source: "extension",
    text: "extension-only notification",
    message: { role: "custom", content: "extension-only notification", timestamp: firstTimestamp + 11 },
  },
  {
    source: "extension",
    text: queuedOperational,
    prompt: queuedOperational,
    message: assistant([{ type: "text", text: "Captain, shipshape." }], firstTimestamp + 12),
  },
  {
    message: assistant([{ type: "text", text: "Captain, shipshape." }], firstTimestamp + 13),
  },
];
for (const ignored of ignoredCases) await deliver(runtime, ignored);
await delay(50);
assert.equal((await list(home)).messages.length, 4, "filter captured a prompt, tool path, extension entry, or routine acknowledgement");

await runCli(home, "mark", firstId, "read");
inbox = await list(home);
assert.equal(inbox.messages.find((message) => message.id === firstId)?.read, true, "mark read did not persist independently");
await runCli(home, "mark", firstId, "unread");
assert.equal((await list(home)).messages.find((message) => message.id === firstId)?.read, false, "mark unread did not persist independently");
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

async function makeLockedInboxHome(name, { ownerContent, ageMs } = {}) {
  const home = await makeHome(name);
  const directory = `${home}/state/captain-inbox/v1`;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(`${home}/state/captain-inbox`, 0o700);
  await chmod(directory, 0o700);
  await writeFile(`${directory}/messages.json`, '{"version":1,"messages":[]}\n', { mode: 0o600 });
  await writeFile(`${directory}/read-state.json`, '{"version":1,"states":{}}\n', { mode: 0o600 });
  const lockDirectory = `${directory}/.lock`;
  await mkdir(lockDirectory, { mode: 0o700 });
  if (ownerContent !== undefined) {
    await writeFile(`${lockDirectory}/owner`, ownerContent, { mode: 0o600 });
  }
  if (ageMs !== undefined) {
    const backdated = new Date(Date.now() - ageMs);
    await utimes(lockDirectory, backdated, backdated);
  }
  return { home, lockDirectory };
}

async function exitedPid() {
  const child = spawn(process.execPath, ["-e", "process.exit(0)"]);
  return new Promise((resolveExit, reject) => {
    child.on("exit", () => resolveExit(child.pid));
    child.on("error", reject);
  });
}

const staleAgeMs = 10 * 60 * 1000;
const deadOwnerPid = await exitedPid();

const staleDead = await makeLockedInboxHome("stale-lock-dead-owner", {
  ownerContent: `dead-owner-token\n${deadOwnerPid}`,
  ageMs: staleAgeMs,
});
const staleListStart = Date.now();
const staleInbox = await list(staleDead.home);
const staleListElapsed = Date.now() - staleListStart;
assert.equal(staleInbox.messages.length, 0, "stale-lock reclaim returned unexpected messages");
assert.ok(staleListElapsed < 2000, `stale lock with a dead owner was not reclaimed promptly (took ${staleListElapsed}ms)`);
assert.equal(existsSync(staleDead.lockDirectory), false, "stale lock directory with a dead owner was left behind after reclaim");

const staleAliveOwnerContent = `alive-owner-token\n${process.pid}`;
const staleAlive = await makeLockedInboxHome("stale-lock-alive-owner", {
  ownerContent: staleAliveOwnerContent,
  ageMs: staleAgeMs,
});
await expectCliFailure(staleAlive.home, ["list"], /busy/);
assert.equal(await readFile(`${staleAlive.lockDirectory}/owner`, "utf8"), staleAliveOwnerContent, "a stale lock whose owner process is still alive was reclaimed");

const staleUnverifiable = await makeLockedInboxHome("stale-lock-no-owner-record", { ageMs: staleAgeMs });
await expectCliFailure(staleUnverifiable.home, ["list"], /busy/);
assert.equal(existsSync(staleUnverifiable.lockDirectory), true, "a stale lock with no verifiable owner record was reclaimed");

const liveLockOwnerContent = "a-live-holder-token\n1";
const liveLock = await makeLockedInboxHome("live-lock", { ownerContent: liveLockOwnerContent });
await expectCliFailure(liveLock.home, ["list"], /busy/);
assert.equal(await readFile(`${liveLock.lockDirectory}/owner`, "utf8"), liveLockOwnerContent, "a fresh (non-stale) lock was reclaimed or its ownership token was disturbed");

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
