#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

if (process.env.FM_CODEX_LIVE_E2E !== "1") {
  console.log("skip: set FM_CODEX_LIVE_E2E=1 to run the isolated Codex app-server regression");
  process.exit(0);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const versionProbe = spawnSync("codex", ["--version"], { encoding: "utf8" });
if (versionProbe.error || versionProbe.status !== 0) {
  throw new Error("codex is required on PATH for FM_CODEX_LIVE_E2E=1");
}

const realCodexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const authCandidates = ["auth.json", ".credentials.json"];
if (!authCandidates.some((name) => fs.existsSync(path.join(realCodexHome, name)))) {
  throw new Error(`Codex auth is missing from ${realCodexHome}; refusing the live E2E`);
}

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fm-codex-turnend-live-"));
const codexHome = path.join(tempRoot, "codex-home");
const fmHome = path.join(tempRoot, "fm-home");
const project = path.join(tempRoot, "project");
let child;

function copyFile(relative) {
  const source = path.join(root, relative);
  const target = path.join(project, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
}

function copyTree(relative) {
  const source = path.join(root, relative);
  const target = path.join(project, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(source, target, { recursive: true });
}

function sessionFiles(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return sessionFiles(entryPath);
    return entry.isFile() && entry.name.endsWith(".jsonl") ? [entryPath] : [];
  });
}

async function stopChild(processHandle) {
  if (!processHandle || processHandle.exitCode !== null) return;
  const closed = new Promise((resolve) => processHandle.once("close", resolve));
  processHandle.kill("SIGTERM");
  const timer = new Promise((resolve) => setTimeout(resolve, 1000));
  await Promise.race([closed, timer]);
  if (processHandle.exitCode === null) processHandle.kill("SIGKILL");
}

try {
  fs.mkdirSync(codexHome, { recursive: true, mode: 0o700 });
  fs.mkdirSync(path.join(fmHome, "state"), { recursive: true });
  fs.mkdirSync(path.join(fmHome, "config"), { recursive: true });
  fs.mkdirSync(project, { recursive: true });
  fs.writeFileSync(path.join(fmHome, "state", "task.meta"), "");

  for (const name of ["auth.json", ".credentials.json", "config.toml", "installation_id", "models_cache.json"]) {
    const source = path.join(realCodexHome, name);
    if (fs.existsSync(source) && fs.statSync(source).isFile()) {
      fs.copyFileSync(source, path.join(codexHome, name));
    }
  }

  for (const relative of [
    "AGENTS.md",
    ".codex/hooks.json",
    "bin/fm-turnend-guard-codex.sh",
    "bin/fm-turnend-guard.sh",
    "bin/fm-wake-lib.sh",
    "bin/fm-supervision-lib.sh",
    "bin/fm-supervision-instructions.sh",
    "bin/fm-harness.sh",
  ]) {
    copyFile(relative);
  }
  copyTree("docs/supervision-protocols");
  for (const name of fs.readdirSync(path.join(project, "bin"))) {
    fs.chmodSync(path.join(project, "bin", name), 0o755);
  }

  const gitInit = spawnSync("git", ["init", "-q", project], { encoding: "utf8" });
  if (gitInit.error || gitInit.status !== 0) {
    throw new Error(`could not initialize the disposable project: ${gitInit.stderr.trim()}`);
  }

  child = spawn("codex", ["app-server", "--stdio"], {
    cwd: project,
    env: { ...process.env, CODEX_HOME: codexHome, FM_HOME: fmHome },
    stdio: ["pipe", "pipe", "pipe"],
  });

  let nextId = 1;
  let stderr = "";
  let activeTurn;
  const pending = new Map();

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-8000);
  });

  function send(message) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  function request(method, params, timeoutMs = 20000) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      send({ jsonrpc: "2.0", id, method, params });
    });
  }

  function waitForTurn() {
    if (activeTurn) throw new Error("only one turn may be active in the live E2E");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        activeTurn = undefined;
        reject(new Error("turn timed out after 40 seconds"));
      }, 40000);
      activeTurn = { resolve, reject, timer };
    });
  }

  function rejectAll(error) {
    for (const waiter of pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    pending.clear();
    if (activeTurn) {
      clearTimeout(activeTurn.timer);
      activeTurn.reject(error);
      activeTurn = undefined;
    }
  }

  const lines = readline.createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (Object.hasOwn(message, "id")) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      clearTimeout(waiter.timer);
      if (message.error) waiter.reject(new Error(message.error.message || JSON.stringify(message.error)));
      else waiter.resolve(message.result);
      return;
    }
    if (!activeTurn) return;
    if (message.method === "turn/completed") {
      const waiter = activeTurn;
      activeTurn = undefined;
      clearTimeout(waiter.timer);
      waiter.resolve(message.params);
    } else if (message.method === "error") {
      const waiter = activeTurn;
      activeTurn = undefined;
      clearTimeout(waiter.timer);
      waiter.reject(new Error(message.params?.error?.message || message.params?.message || "Codex turn failed"));
    }
  });

  child.once("error", (error) => rejectAll(error));
  child.once("exit", (code, signal) => {
    rejectAll(new Error(`codex app-server exited early (${code ?? signal})${stderr ? `: ${stderr.trim()}` : ""}`));
  });

  await request("initialize", {
    clientInfo: { name: "firstmate-stop-e2e", version: "1.0.0" },
    capabilities: { experimentalApi: true },
  });
  send({ jsonrpc: "2.0", method: "initialized" });

  const started = await request("thread/start", {
    cwd: project,
    config: { bypass_hook_trust: true, features: { item_ids: true } },
    developerInstructions: "Reply with OK only. Do not use tools.",
  });
  const threadId = started?.thread?.id;
  if (!threadId) throw new Error("thread/start returned no thread id");

  async function runTurn(clientUserMessageId) {
    const completed = waitForTurn();
    await request("turn/start", {
      threadId,
      clientUserMessageId,
      input: [{ type: "text", text: "Reply with OK only. Do not use tools." }],
      effort: "low",
    });
    await completed;
  }

  await runTurn("msg_e2e_first");
  console.log("FIRST_TURN_COMPLETED");

  const persisted = sessionFiles(path.join(codexHome, "sessions"))
    .map((file) => fs.readFileSync(file, "utf8"))
    .join("\n");
  if (persisted.includes("<hook_prompt>")) {
    throw new Error("blocking <hook_prompt> persisted in the isolated Codex session");
  }
  console.log("NO_HOOK_PROMPT_PERSISTED");

  const wakeQueue = path.join(fmHome, "state", ".wake-queue");
  if (!fs.existsSync(wakeQueue) || !fs.readFileSync(wakeQueue, "utf8").includes("codex-turnend-guard")) {
    throw new Error("Codex adapter did not queue its durable supervision wake");
  }
  console.log("DURABLE_WAKE_QUEUED");

  await runTurn("msg_e2e_second");
  console.log("SECOND_DESKTOP_STYLE_FOLLOWUP_COMPLETED");
} finally {
  await stopChild(child);
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
