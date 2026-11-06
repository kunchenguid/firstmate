#!/usr/bin/env node
// Static core-owned launch barrier for one trusted extension invocation.
//
// The host starts this file directly with shell=false in a new process group.
// The barrier publishes that exact group identity before it accepts a one-shot
// host release, then starts the already-validated package executable in the
// same group with inherited bounded protocol pipes. It never evaluates source
// text and never discovers package code or authority on its own.

import { spawn } from "node:child_process";
import { open, readFile, rename } from "node:fs/promises";
import path from "node:path";

const READY_SCHEMA = "firstmate.extension-invocation-ready.v1";
const OWNER_SCHEMA = "firstmate.extension-invocation-owner.v1";
const RELEASE_SCHEMA = "firstmate.extension-invocation-release.v1";
const STARTUP_WAIT_MS = 5000;
const MAX_CONTROL_BYTES = 16384;
const POLL_MS = 20;

function die(message) {
  process.stderr.write(`extension launch barrier: ${message}\n`);
  process.exit(125);
}

function exactKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
}

async function readControl(file) {
  const bytes = await readFile(file);
  if (bytes.length === 0 || bytes.length > MAX_CONTROL_BYTES) die("control record size is invalid");
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    die("control record is invalid JSON");
  }
  return value;
}

async function writeExclusive(file, value) {
  const temporary = `${file}.tmp`;
  const handle = await open(temporary, "wx", 0o600).catch(() => die("cannot publish launch readiness"));
  try {
    await handle.writeFile(`${JSON.stringify(value)}\n`, "utf8");
  } finally {
    await handle.close();
  }
  await rename(temporary, file).catch(() => die("cannot publish launch readiness"));
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function main() {
  const [token, ownerFile, readyFile, releaseFile, hostPidRaw, entrypoint, cwd, verb, ...extra] = process.argv.slice(2);
  if (extra.length || !ownerFile || !readyFile || !releaseFile || !token || !hostPidRaw || !entrypoint || !cwd || !verb) {
    die("invalid launch arguments");
  }
  if (![ownerFile, readyFile, releaseFile, entrypoint, cwd].every(path.isAbsolute)) die("launch paths must be absolute");
  if (!/^[0-9]+$/u.test(hostPidRaw)) die("host pid is invalid");
  const hostPid = Number(hostPidRaw);
  if (!Number.isSafeInteger(hostPid) || hostPid <= 1) die("host pid is invalid");
  // The host creates this tracked child with detached=true, making its PID the
  // invocation PGID before this static file runs. The unguessable token also
  // remains in the barrier's exact argv so recovery can reject PID reuse.
  const identity = `barrier-token:${token}`;
  await writeExclusive(readyFile, {
    schema: READY_SCHEMA,
    token,
    group_pid: process.pid,
    group_identity: identity,
  });

  const deadline = Date.now() + STARTUP_WAIT_MS;
  let release;
  while (Date.now() < deadline) {
    if (!pidAlive(hostPid)) process.exit(125);
    try {
      release = await readControl(releaseFile);
      break;
    } catch (error) {
      if (error && error.code !== "ENOENT") throw error;
    }
    await sleep(POLL_MS);
  }
  if (!release) die("host did not release the launch barrier");
  if (!exactKeys(release, ["schema", "token"]) || release.schema !== RELEASE_SCHEMA || release.token !== token) {
    die("launch release identity is invalid");
  }
  const owner = await readControl(ownerFile);
  if (!exactKeys(owner, [
    "schema", "token", "phase", "host_pid", "host_identity", "group_pid", "group_identity",
    "extension_id", "binding_digest", "request_id", "source_id", "operation",
  ]) || owner.schema !== OWNER_SCHEMA || owner.token !== token || owner.phase !== "group"
      || owner.host_pid !== hostPid || owner.group_pid !== process.pid || owner.group_identity !== identity) {
    die("launch ownership was not published before release");
  }

  const child = spawn(entrypoint, [verb], {
    cwd,
    env: process.env,
    shell: false,
    detached: false,
    stdio: ["inherit", "inherit", "inherit"],
  });
  const outcome = await new Promise((resolve) => {
    child.once("error", () => resolve({ code: 125, signal: null }));
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  if (outcome.signal) process.exit(128);
  process.exit(outcome.code ?? 125);
}

main().catch((error) => die(error instanceof Error ? error.message : "unexpected launch failure"));
