import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

export const CAPTAIN_INBOX_VERSION = 1;
export const CAPTAIN_INBOX_DEFAULT_MAX_MESSAGES = 100;

const LOCK_TIMEOUT_MS = 5000;
const LOCK_RETRY_MS = 20;
const LOCK_STALE_MS = 5 * 60 * 1000;
const MESSAGE_ID_RE = /^ci_v1_[a-f0-9]{32}$/;

function asResolved(path) {
  return resolve(path);
}

export function resolveCaptainInboxPaths({ home, state, config }) {
  const resolvedHome = asResolved(home);
  const resolvedState = asResolved(state ?? `${resolvedHome}/state`);
  const resolvedConfig = asResolved(config ?? `${resolvedHome}/config`);
  const root = `${resolvedState}/captain-inbox`;
  const directory = `${root}/v${CAPTAIN_INBOX_VERSION}`;
  return {
    home: resolvedHome,
    config: resolvedConfig,
    state: resolvedState,
    root,
    directory,
    lock: `${directory}/.lock`,
    messages: `${directory}/messages.json`,
    readState: `${directory}/read-state.json`,
  };
}

function safelyReadSingleFile(path) {
  try {
    const before = lstatSync(path);
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) return undefined;
    const content = readFileSync(path, "utf8");
    const after = lstatSync(path);
    if (
      !after.isFile() ||
      after.isSymbolicLink() ||
      after.nlink !== 1 ||
      before.dev !== after.dev ||
      before.ino !== after.ino
    ) {
      return undefined;
    }
    return content;
  } catch {
    return undefined;
  }
}

export function captainInboxIsEnabled(paths) {
  return safelyReadSingleFile(`${paths.config}/captain-inbox`) === "on\n";
}

function primaryHome(paths) {
  try {
    // Any secondmate marker, including an unreadable or unsafe one, makes this
    // home ineligible rather than risking a secondmate recording captain data.
    lstatSync(`${paths.home}/.fm-secondmate-home`);
    return false;
  } catch (error) {
    return error && error.code === "ENOENT";
  }
}

function parentPid(pid) {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
}

function lockIsOwnedByCurrentProcess(lockPath) {
  const raw = safelyReadSingleFile(lockPath)?.trim() ?? "";
  if (!/^[0-9]+$/.test(raw) || raw === "1") return false;
  let pid = String(process.pid);
  for (let depth = 0; depth < 8; depth += 1) {
    if (pid === raw) return true;
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return false;
}

export function isPrimaryCaptainInboxSession(paths) {
  return captainInboxIsEnabled(paths) && primaryHome(paths) && lockIsOwnedByCurrentProcess(`${paths.state}/.lock`);
}

function malformed() {
  throw new Error("Captain's Inbox storage is malformed");
}

function validTimestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString() === value;
}

function validMessage(record) {
  return (
    record &&
    typeof record === "object" &&
    MESSAGE_ID_RE.test(record.id) &&
    validTimestamp(record.completed_at) &&
    typeof record.body === "string" &&
    record.source &&
    typeof record.source === "object" &&
    (record.source.harness === "pi" || record.source.harness === "pi-signed") &&
    typeof record.source.session_id === "string" &&
    record.source.session_id.length > 0
  );
}

function validReadState(state) {
  if (!state || typeof state !== "object" || Array.isArray(state)) return false;
  return Object.entries(state).every(([id, value]) =>
    MESSAGE_ID_RE.test(id) &&
    value &&
    typeof value === "object" &&
    typeof value.read === "boolean" &&
    validTimestamp(value.updated_at),
  );
}

function validateMessagesDocument(document) {
  if (
    !document ||
    typeof document !== "object" ||
    document.version !== CAPTAIN_INBOX_VERSION ||
    !Array.isArray(document.messages) ||
    !document.messages.every(validMessage)
  ) {
    malformed();
  }
  const ids = new Set(document.messages.map((message) => message.id));
  if (ids.size !== document.messages.length) malformed();
  return document;
}

function validateReadStateDocument(document) {
  if (
    !document ||
    typeof document !== "object" ||
    document.version !== CAPTAIN_INBOX_VERSION ||
    !validReadState(document.states)
  ) {
    malformed();
  }
  return document;
}

async function ensurePrivateDirectory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const entry = await lstat(path);
  if (!entry.isDirectory() || entry.isSymbolicLink()) {
    throw new Error("Captain's Inbox storage path is unsafe");
  }
  await chmod(path, 0o700);
}

async function ensureExistingPrivateDirectory(path) {
  const entry = await lstat(path);
  if (!entry.isDirectory() || entry.isSymbolicLink()) {
    throw new Error("Captain's Inbox storage path is unsafe");
  }
  await chmod(path, 0o700);
}

async function ensureStoreDirectory(paths) {
  await ensurePrivateDirectory(paths.root);
  await ensurePrivateDirectory(paths.directory);
}

async function readPrivateJson(path, fallback, validate) {
  let before;
  try {
    before = await lstat(path);
  } catch (error) {
    if (error && error.code === "ENOENT") return fallback;
    throw error;
  }
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) {
    throw new Error("Captain's Inbox storage path is unsafe");
  }
  await chmod(path, 0o600);
  const raw = await readFile(path, "utf8");
  const after = await lstat(path);
  if (
    !after.isFile() ||
    after.isSymbolicLink() ||
    after.nlink !== 1 ||
    before.dev !== after.dev ||
    before.ino !== after.ino
  ) {
    throw new Error("Captain's Inbox storage changed while it was read");
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    malformed();
  }
  return validate(parsed);
}

async function writePrivateJson(path, value) {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  const content = `${JSON.stringify(value)}\n`;
  try {
    await writeFile(temporary, content, { encoding: "utf8", flag: "wx", mode: 0o600 });
    await chmod(temporary, 0o600);
    await rename(temporary, path);
    await chmod(path, 0o600);
  } finally {
    await rm(temporary, { force: true });
  }
}

function sleep(milliseconds) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

function parseOwnerRecord(raw) {
  const [token, pidText] = raw.split("\n");
  if (!token || !pidText || !/^[0-9]+$/.test(pidText)) return undefined;
  return { token, pid: Number(pidText) };
}

function ownerProcessIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // ESRCH means no process with this PID exists, so the holder is dead.
    // Any other outcome (EPERM, etc.) is treated as alive: unverifiable
    // liveness must never be used to justify reclaiming the lock.
    return !(error && error.code === "ESRCH");
  }
}

async function reclaimLockIfStale(lockPath) {
  let entry;
  try {
    entry = await lstat(lockPath);
  } catch {
    return;
  }
  if (!entry.isDirectory() || entry.isSymbolicLink()) return;
  if (Date.now() - entry.mtimeMs < LOCK_STALE_MS) return;

  let raw;
  try {
    raw = await readFile(`${lockPath}/owner`, "utf8");
  } catch {
    return;
  }
  const record = parseOwnerRecord(raw);
  // A malformed or missing owner record can't be verified dead, so it is
  // never reclaimed by age alone.
  if (!record || ownerProcessIsAlive(record.pid)) return;

  await rm(lockPath, { recursive: true, force: true }).catch(() => {});
}

async function createLock(paths) {
  await mkdir(paths.lock, { mode: 0o700 });
  await chmod(paths.lock, 0o700);
  const token = randomUUID();
  try {
    await writeFile(`${paths.lock}/owner`, `${token}\n${process.pid}`, { encoding: "utf8", flag: "wx", mode: 0o600 });
  } catch (error) {
    await rm(paths.lock, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
  return token;
}

async function acquireLock(paths, create) {
  if (create) {
    await ensureStoreDirectory(paths);
  } else {
    if (!existsSync(paths.directory)) throw new Error("Captain's Inbox storage does not exist");
    await ensureExistingPrivateDirectory(paths.root);
    await ensureExistingPrivateDirectory(paths.directory);
  }

  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  while (true) {
    try {
      return await createLock(paths);
    } catch (error) {
      if (!error || error.code !== "EEXIST") throw error;
      await reclaimLockIfStale(paths.lock);
      if (Date.now() >= deadline) {
        throw new Error("Captain's Inbox is busy; retry the request");
      }
      await sleep(LOCK_RETRY_MS);
    }
  }
}

async function releaseLock(lockPath, token) {
  let raw;
  try {
    raw = await readFile(`${lockPath}/owner`, "utf8");
  } catch {
    return;
  }
  // Only the process whose token still matches the on-disk owner may remove
  // the lock: a reclaimed-as-stale lock may already belong to a new holder.
  const record = parseOwnerRecord(raw);
  if (!record || record.token !== token) return;
  await rm(lockPath, { recursive: true, force: true }).catch(() => {});
}

async function withStoreLock(paths, { create }, operation) {
  const token = await acquireLock(paths, create);
  try {
    return await operation();
  } finally {
    await releaseLock(paths.lock, token);
  }
}

async function readDocuments(paths) {
  const messages = await readPrivateJson(
    paths.messages,
    { version: CAPTAIN_INBOX_VERSION, messages: [] },
    validateMessagesDocument,
  );
  const readState = await readPrivateJson(
    paths.readState,
    { version: CAPTAIN_INBOX_VERSION, states: {} },
    validateReadStateDocument,
  );
  return { messages, readState };
}

function timestampOrder(left, right) {
  const delta = Date.parse(left.completed_at) - Date.parse(right.completed_at);
  return delta !== 0 ? delta : left.id.localeCompare(right.id);
}

function nextReadState(messages, states) {
  const next = {};
  for (const message of messages) {
    next[message.id] = states[message.id] ?? {
      read: false,
      updated_at: message.completed_at,
    };
  }
  return next;
}

function messageId({ harness, sessionId, completedAt, body }) {
  const digest = createHash("sha256")
    .update(`firstmate-captain-inbox/v1\u0000${harness}\u0000${sessionId}\u0000${completedAt}\u0000${body}`)
    .digest("hex")
    .slice(0, 32);
  return `ci_v1_${digest}`;
}

export async function captureCaptainResponse(paths, { harness, sessionId, completedAt, body }) {
  if (!isPrimaryCaptainInboxSession(paths)) return { captured: false, reason: "not-primary-or-disabled" };
  if ((harness !== "pi" && harness !== "pi-signed") || typeof sessionId !== "string" || !sessionId) {
    return { captured: false, reason: "invalid-source" };
  }
  if (!validTimestamp(completedAt) || typeof body !== "string" || !body.trim()) {
    return { captured: false, reason: "not-captain-facing" };
  }

  const record = {
    id: messageId({ harness, sessionId, completedAt, body }),
    completed_at: completedAt,
    body,
    source: { harness, session_id: sessionId },
  };

  return withStoreLock(paths, { create: true }, async () => {
    const { messages, readState } = await readDocuments(paths);
    if (messages.messages.some((message) => message.id === record.id)) {
      return { captured: false, reason: "duplicate", id: record.id };
    }

    const retained = [...messages.messages, record]
      .sort(timestampOrder)
      .slice(-CAPTAIN_INBOX_DEFAULT_MAX_MESSAGES);
    const states = nextReadState(retained, {
      ...readState.states,
      [record.id]: { read: false, updated_at: completedAt },
    });

    await writePrivateJson(paths.messages, {
      version: CAPTAIN_INBOX_VERSION,
      messages: retained,
    });
    await writePrivateJson(paths.readState, {
      version: CAPTAIN_INBOX_VERSION,
      states,
    });
    return { captured: true, id: record.id };
  });
}

function listedMessages(messages, states) {
  return [...messages]
    .sort((left, right) => timestampOrder(right, left))
    .map((message) => ({
      ...message,
      read: states[message.id]?.read === true,
    }));
}

export async function listCaptainInbox(paths) {
  if (!existsSync(paths.directory)) {
    return { version: CAPTAIN_INBOX_VERSION, messages: [] };
  }
  return withStoreLock(paths, { create: false }, async () => {
    const { messages, readState } = await readDocuments(paths);
    return {
      version: CAPTAIN_INBOX_VERSION,
      messages: listedMessages(messages.messages, readState.states),
    };
  });
}

export async function markCaptainInboxMessage(paths, id, read) {
  if (!MESSAGE_ID_RE.test(id) || typeof read !== "boolean") {
    throw new Error("invalid Captain's Inbox mark request");
  }
  return withStoreLock(paths, { create: false }, async () => {
    const { messages, readState } = await readDocuments(paths);
    if (!messages.messages.some((message) => message.id === id)) {
      throw new Error("Captain's Inbox message was not found");
    }
    const next = {
      ...readState.states,
      [id]: { read, updated_at: new Date().toISOString() },
    };
    await writePrivateJson(paths.readState, {
      version: CAPTAIN_INBOX_VERSION,
      states: nextReadState(messages.messages, next),
    });
    return { version: CAPTAIN_INBOX_VERSION, id, read };
  });
}

async function deleteCaptainInboxMessages(paths, select, result) {
  return withStoreLock(paths, { create: false }, async () => {
    const { messages, readState } = await readDocuments(paths);
    const deleted = messages.messages.filter((message) => select(message, readState.states[message.id]?.read === true));
    if (deleted.length === 0) return result(0);

    const deletedIds = new Set(deleted.map((message) => message.id));
    const remaining = messages.messages.filter((message) => !deletedIds.has(message.id));
    const states = nextReadState(remaining, readState.states);

    // Keep both document replacements under the private store lock.
    // Each replacement remains crash-safe through writePrivateJson's atomic rename.
    await writePrivateJson(paths.messages, {
      version: CAPTAIN_INBOX_VERSION,
      messages: remaining,
    });
    await writePrivateJson(paths.readState, {
      version: CAPTAIN_INBOX_VERSION,
      states,
    });
    return result(deleted.length);
  });
}

export async function deleteCaptainInboxMessage(paths, id) {
  if (!MESSAGE_ID_RE.test(id)) {
    throw new Error("invalid Captain's Inbox delete request");
  }
  return deleteCaptainInboxMessages(
    paths,
    (message, read) => message.id === id && read,
    (deleted) => {
      if (deleted === 0) {
        throw new Error("Captain's Inbox message was not found or is not read");
      }
      return { version: CAPTAIN_INBOX_VERSION, id, deleted: true };
    },
  );
}

export async function deleteCaptainInboxMessagesByReadState(paths, read) {
  if (typeof read !== "boolean") {
    throw new Error("invalid Captain's Inbox delete request");
  }
  return deleteCaptainInboxMessages(
    paths,
    (_message, messageRead) => messageRead === read,
    (deleted) => ({ version: CAPTAIN_INBOX_VERSION, read, deleted }),
  );
}
