#!/usr/bin/env node
// fm-codex-appserver-client.mjs - the owning Codex app-server client.
//
// This process stays in the supervised pane and owns one foreground app-server
// child per turn. The child runs in its own process group with protocol stdin
// and stdout pipes. Its stderr is consumed into a bounded per-task log.
//
// A turn reaches idle only after the same turn emitted turn/started,
// thread/status/changed active, and turn/completed(completed), then the owning
// client closed the protocol pipe and observed a clean child exit. Every other
// terminal, protocol loss, child failure, or deadline expiry publishes unknown
// through bin/fm-busy-event.sh. The absolute deadline is the only hang detector.
// Timeout escalation targets only the process group whose leader is the child
// PID created here: turn/interrupt, TERM, then KILL.
//
// The pane interface deliberately uses Codex's established `›` composer glyph
// so every backend keeps routing submit confirmation through the existing shared
// composer classifier. Enter starts an idle turn or steers the active turn.
// Escape interrupts the active turn. /quit exits after any active turn settles.

import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  closeSync,
  mkdirSync,
  openSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
const BUSY_EVENT = path.join(SELF_DIR, "fm-busy-event.sh");
const TOKEN_RE = /^[A-Za-z0-9._-]+$/;
const TERMINAL_STATUSES = new Set(["completed", "interrupted", "failed"]);
const EFFORTS = new Set(["low", "medium", "high", "xhigh"]);

function usage(message = "") {
  if (message) process.stderr.write(`fm-codex-appserver-client: ${message}\n`);
  process.stderr.write(
    "usage: fm-codex-appserver-client.mjs --state-dir DIR --task-id ID " +
      "--generation GEN --cwd DIR --task-tmp DIR --turn-ended FILE " +
      "--deadline-secs N [--model MODEL] [-c model_reasoning_effort=\"LEVEL\"] " +
      "[--prompt TEXT] [--one-shot]\n",
  );
  process.exitCode = 2;
}

function positiveInteger(value, name) {
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${name} must be a positive integer`);
  return Number(value);
}

function positiveEnvMilliseconds(name, fallback) {
  const value = process.env[name];
  if (value === undefined || value === "") return fallback;
  return positiveInteger(value, name);
}

function parseConfig(value, options) {
  const match = /^model_reasoning_effort="(low|medium|high|xhigh)"$/.exec(value);
  if (!match) throw new Error(`unsupported -c value: ${value}`);
  options.effort = match[1];
}

function parseArguments(argv) {
  const options = {
    stateDir: "",
    taskId: "",
    generation: "",
    cwd: "",
    taskTmp: "",
    turnEnded: "",
    deadlineSecs: 0,
    model: "",
    effort: "",
    prompt: "",
    promptSet: false,
    oneShot: false,
  };
  const valued = new Map([
    ["--state-dir", "stateDir"],
    ["--task-id", "taskId"],
    ["--generation", "generation"],
    ["--cwd", "cwd"],
    ["--task-tmp", "taskTmp"],
    ["--turn-ended", "turnEnded"],
    ["--model", "model"],
    ["--prompt", "prompt"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--one-shot") {
      options.oneShot = true;
      continue;
    }
    if (argument === "--deadline-secs") {
      if (index + 1 >= argv.length) throw new Error("--deadline-secs requires a value");
      options.deadlineSecs = positiveInteger(argv[++index], "--deadline-secs");
      continue;
    }
    if (argument === "-c") {
      if (index + 1 >= argv.length) throw new Error("-c requires a value");
      parseConfig(argv[++index], options);
      continue;
    }
    const field = valued.get(argument);
    if (field) {
      if (index + 1 >= argv.length) throw new Error(`${argument} requires a value`);
      options[field] = argv[++index];
      if (argument === "--prompt") options.promptSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${argument}`);
  }
  for (const [field, flag] of [
    ["stateDir", "--state-dir"],
    ["taskId", "--task-id"],
    ["generation", "--generation"],
    ["cwd", "--cwd"],
    ["taskTmp", "--task-tmp"],
    ["turnEnded", "--turn-ended"],
  ]) {
    if (!options[field]) throw new Error(`${flag} is required`);
  }
  if (!options.deadlineSecs) throw new Error("--deadline-secs is required");
  if (!TOKEN_RE.test(options.taskId)) throw new Error("--task-id is not a valid token");
  if (!TOKEN_RE.test(options.generation)) throw new Error("--generation is not a valid token");
  if (options.model && !TOKEN_RE.test(options.model)) throw new Error("--model is not a valid token");
  if (options.effort && !EFFORTS.has(options.effort)) throw new Error("unsupported effort");
  if (process.platform === "win32") {
    throw new Error("an owned Unix process group is required; native win32 is unsupported");
  }
  options.stateDir = realpathSync(options.stateDir);
  options.cwd = realpathSync(options.cwd);
  options.taskTmp = path.resolve(options.taskTmp);
  options.turnEnded = path.resolve(options.turnEnded);
  if (!path.isAbsolute(options.stateDir) || !statSync(options.stateDir).isDirectory()) {
    throw new Error("--state-dir must resolve to a directory");
  }
  if (!path.isAbsolute(options.cwd) || !statSync(options.cwd).isDirectory()) {
    throw new Error("--cwd must resolve to a directory");
  }
  const expectedTaskTmp = `/tmp/fm-${options.taskId}`;
  if (options.taskTmp !== expectedTaskTmp) {
    throw new Error(`--task-tmp must be the short per-task path ${expectedTaskTmp}`);
  }
  if (realpathSync(path.dirname(options.turnEnded)) !== options.stateDir) {
    throw new Error("--turn-ended must live directly under --state-dir");
  }
  options.turnEnded = path.join(options.stateDir, path.basename(options.turnEnded));
  return options;
}

function token(value, fallback = "none") {
  if (value === null || value === undefined || value === "") return fallback;
  const normalized = String(value).replace(/[^A-Za-z0-9._-]/g, "-").slice(0, 160);
  return normalized || fallback;
}

class BoundedLog {
  constructor(file, limit) {
    this.file = file;
    this.limit = limit;
    this.buffer = Buffer.alloc(0);
    writeFileSync(this.file, this.buffer, { mode: 0o600 });
    chmodSync(this.file, 0o600);
  }

  append(chunk) {
    const incoming = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (incoming.length >= this.limit) {
      this.buffer = incoming.subarray(incoming.length - this.limit);
    } else {
      const combined = Buffer.concat([this.buffer, incoming]);
      this.buffer = combined.length > this.limit
        ? combined.subarray(combined.length - this.limit)
        : combined;
    }
    writeFileSync(this.file, this.buffer, { mode: 0o600 });
  }
}

class AppServerRun {
  constructor(owner, prompt, priorThreadId) {
    this.owner = owner;
    this.options = owner.options;
    this.prompt = prompt;
    this.priorThreadId = priorThreadId;
    this.threadId = priorThreadId;
    this.turnId = "";
    this.turnResponseId = "";
    this.turnStarted = false;
    this.activeSeen = false;
    this.busyPublished = false;
    this.terminalStatus = "";
    this.terminalError = "";
    this.forcedOutcome = "";
    this.shutdownForced = false;
    this.nextRequestId = 1;
    this.requests = new Map();
    this.child = null;
    this.childClosed = false;
    this.childCode = null;
    this.childSignal = "";
    this.startedAt = Math.floor(Date.now() / 1000);
    this.deadlineAt = 0;
    this.startupTimer = null;
    this.turnTimer = null;
    this.termTimer = null;
    this.killTimer = null;
    this.finishResolve = null;
    this.finishPromise = new Promise((resolve) => {
      this.finishResolve = resolve;
    });
    this.agentDeltaItems = new Set();
  }

  send(message) {
    if (!this.child || !this.child.stdin.writable) throw new Error("protocol stdin is unavailable");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  notify(method, params) {
    this.send({ method, params });
  }

  request(method, params = {}) {
    const id = this.nextRequestId++;
    return new Promise((resolve, reject) => {
      this.requests.set(id, { method, resolve, reject });
      try {
        this.send({ method, id, params });
      } catch (error) {
        this.requests.delete(id);
        reject(error);
      }
    });
  }

  rejectRequests(reason) {
    for (const pending of this.requests.values()) pending.reject(new Error(reason));
    this.requests.clear();
  }

  handleResponse(message) {
    const pending = this.requests.get(message.id);
    if (!pending) {
      this.protocolFailure("unexpected-response");
      return;
    }
    this.requests.delete(message.id);
    if (message.error) {
      const detail = token(message.error.message || message.error.code || "request-error");
      pending.reject(new Error(`${pending.method}-${detail}`));
      return;
    }
    pending.resolve(message.result);
  }

  handleNotification(message) {
    const params = message.params || {};
    if (message.method === "thread/status/changed") {
      if (params.threadId === this.threadId && params.status?.type === "active") {
        this.activeSeen = true;
        this.maybePublishBusy();
      }
      return;
    }
    if (message.method === "turn/started") {
      const id = params.turn?.id || "";
      if (!TOKEN_RE.test(id)) {
        this.protocolFailure("turn-started-id-invalid");
        return;
      }
      if (this.turnId && this.turnId !== id) {
        this.protocolFailure("turn-started-id-mismatch");
        return;
      }
      this.turnId = id;
      this.turnStarted = true;
      this.maybePublishBusy();
      return;
    }
    if (message.method === "turn/completed") {
      const turn = params.turn || {};
      if (!TOKEN_RE.test(turn.id || "") || (this.turnId && turn.id !== this.turnId)) {
        this.protocolFailure("turn-completed-id-mismatch");
        return;
      }
      if (!TERMINAL_STATUSES.has(turn.status)) {
        this.protocolFailure("turn-completed-status-invalid");
        return;
      }
      if (this.terminalStatus) {
        this.protocolFailure("turn-completed-duplicate");
        return;
      }
      this.turnId = turn.id;
      this.terminalStatus = turn.status;
      this.terminalError = token(turn.error?.message || "none");
      this.beginProtocolClose();
      return;
    }
    if (message.method === "item/agentMessage/delta") {
      if (typeof params.delta === "string") {
        if (params.itemId) this.agentDeltaItems.add(params.itemId);
        this.owner.writeAgent(params.delta);
      }
      return;
    }
    if (message.method === "item/completed") {
      const item = params.item;
      if (item?.type === "agentMessage" && typeof item.text === "string"
          && !this.agentDeltaItems.has(item.id)) {
        this.owner.writeAgent(item.text);
      }
    }
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.protocolFailure("invalid-json");
      return;
    }
    if (!message || typeof message !== "object") {
      this.protocolFailure("invalid-message");
      return;
    }
    if (Object.hasOwn(message, "id") && !Object.hasOwn(message, "method")) {
      this.handleResponse(message);
      return;
    }
    if (Object.hasOwn(message, "id") && Object.hasOwn(message, "method")) {
      try {
        this.send({
          id: message.id,
          error: { code: -32601, message: "Firstmate client does not support server requests" },
        });
      } catch {
        // The protocol failure below owns the terminal result.
      }
      this.protocolFailure(`unsupported-server-request-${token(message.method)}`);
      return;
    }
    if (typeof message.method === "string") {
      this.handleNotification(message);
      return;
    }
    this.protocolFailure("unclassified-message");
  }

  maybePublishBusy() {
    if (this.busyPublished || !this.turnStarted || !this.activeSeen) return;
    try {
      this.owner.applyBusy(this.deadlineAt);
      this.busyPublished = true;
    } catch (error) {
      this.protocolFailure(`busy-publish-${token(error.message)}`);
    }
  }

  signalGroup(signal) {
    if (!this.child?.pid) return;
    try {
      process.kill(-this.child.pid, signal);
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }

  scheduleEscalation() {
    if (this.childClosed || this.termTimer || this.killTimer) return;
    const interruptGrace = this.owner.interruptGraceMs;
    const termGrace = this.owner.termGraceMs;
    this.termTimer = setTimeout(() => {
      if (this.childClosed) return;
      this.shutdownForced = true;
      try {
        this.signalGroup("SIGTERM");
      } catch (error) {
        this.forcedOutcome ||= `signal-error-${token(error.message)}`;
      }
      this.killTimer = setTimeout(() => {
        if (this.childClosed) return;
        this.shutdownForced = true;
        try {
          this.signalGroup("SIGKILL");
        } catch (error) {
          this.forcedOutcome ||= `signal-error-${token(error.message)}`;
        }
      }, termGrace);
    }, interruptGrace);
  }

  beginProtocolClose() {
    if (this.turnTimer) clearTimeout(this.turnTimer);
    this.turnTimer = null;
    try {
      this.child?.stdin.end();
    } catch {
      this.shutdownForced = true;
    }
    this.scheduleEscalation();
  }

  protocolFailure(reason) {
    if (!this.forcedOutcome) this.forcedOutcome = `protocol-${token(reason)}`;
    try {
      this.child?.stdin.end();
    } catch {
      // Escalation below still owns the child.
    }
    this.scheduleEscalation();
  }

  timeout() {
    if (this.childClosed || this.terminalStatus) return;
    if (!this.forcedOutcome.startsWith("protocol-")) this.forcedOutcome = "timeout";
    if (this.threadId && this.turnId) {
      this.request("turn/interrupt", { threadId: this.threadId, turnId: this.turnId })
        .catch(() => {});
    }
    this.scheduleEscalation();
  }

  interrupt() {
    if (this.childClosed || this.terminalStatus || !this.threadId || !this.turnId) return false;
    if (!this.forcedOutcome) this.forcedOutcome = "manual-interrupt";
    this.request("turn/interrupt", { threadId: this.threadId, turnId: this.turnId })
      .catch(() => this.protocolFailure("interrupt-request-failed"));
    this.scheduleEscalation();
    return true;
  }

  async steer(text) {
    if (!this.threadId || !this.turnId || this.terminalStatus || this.childClosed) return false;
    try {
      await this.request("turn/steer", {
        threadId: this.threadId,
        expectedTurnId: this.turnId,
        input: [{ type: "text", text }],
      });
      return true;
    } catch (error) {
      this.protocolFailure(`steer-${token(error.message)}`);
      return false;
    }
  }

  handleClose(code, signal) {
    if (this.childClosed) return;
    this.childClosed = true;
    this.childCode = code;
    this.childSignal = signal || "";
    for (const timer of [this.startupTimer, this.turnTimer, this.termTimer, this.killTimer]) {
      if (timer) clearTimeout(timer);
    }
    this.rejectRequests("app-server closed");
    this.finishResolve(this.result());
  }

  result() {
    let outcome;
    let event;
    if (this.forcedOutcome === "timeout") {
      outcome = "timeout";
      event = "timeout";
    } else if (!this.terminalStatus) {
      outcome = "failure";
      if (this.forcedOutcome?.startsWith("protocol-")) event = "protocol-error";
      else if (this.forcedOutcome?.startsWith("stderr-log-")) event = "stderr-log-error";
      else if (this.forcedOutcome === "startup-timeout") event = "startup-timeout";
      else if (this.forcedOutcome?.startsWith("spawn-") || this.forcedOutcome?.startsWith("child-")) {
        event = "process-error";
      } else event = "terminal-missing";
    } else if (this.forcedOutcome && this.forcedOutcome !== "manual-interrupt") {
      outcome = "failure";
      event = this.forcedOutcome.startsWith("protocol-") ? "protocol-error" : "process-error";
    } else if (this.shutdownForced || this.childCode !== 0 || this.childSignal) {
      outcome = "failure";
      event = "process-error";
    } else if (this.terminalStatus === "completed") {
      if (!this.turnStarted || !this.activeSeen || !this.busyPublished) {
        outcome = "failure";
        event = "protocol-incomplete";
      } else {
        outcome = "success";
        event = "turn-completed";
      }
    } else if (this.terminalStatus === "interrupted") {
      outcome = "interrupted";
      event = "turn-interrupted";
    } else {
      outcome = "failure";
      event = "turn-failed";
    }
    return {
      outcome,
      event,
      threadId: this.threadId,
      turnId: this.turnId,
      terminalStatus: this.terminalStatus || "missing",
      terminalError: this.terminalError,
      childPid: this.child?.pid || 0,
      childCode: this.childCode,
      childSignal: this.childSignal,
      deadlineAt: this.deadlineAt,
      startedAt: this.startedAt,
      endedAt: Math.floor(Date.now() / 1000),
      preserveThread: event !== "timeout" && !event.startsWith("protocol-") && event !== "terminal-missing",
    };
  }

  async handshake() {
    const initialize = await this.request("initialize", {
      clientInfo: {
        name: "firstmate",
        title: "Firstmate Codex worker",
        version: "1.0.0",
      },
    });
    if (!initialize || typeof initialize !== "object") throw new Error("initialize-response-invalid");
    this.notify("initialized", {});
    let thread;
    if (this.priorThreadId) {
      const resumed = await this.request("thread/resume", { threadId: this.priorThreadId });
      thread = resumed?.thread;
    } else {
      const params = {
        cwd: this.options.cwd,
        approvalPolicy: "never",
        sandbox: "danger-full-access",
      };
      if (this.options.model) params.model = this.options.model;
      const started = await this.request("thread/start", params);
      thread = started?.thread;
    }
    if (!TOKEN_RE.test(thread?.id || "")) throw new Error("thread-response-invalid");
    this.threadId = thread.id;
    this.deadlineAt = Math.floor(Date.now() / 1000) + this.options.deadlineSecs;
    this.turnTimer = setTimeout(() => this.timeout(), this.options.deadlineSecs * 1000);
    const turnParams = {
      threadId: this.threadId,
      input: [{ type: "text", text: this.prompt }],
    };
    if (this.options.model) turnParams.model = this.options.model;
    if (this.options.effort) turnParams.effort = this.options.effort;
    const response = await this.request("turn/start", turnParams);
    const responseId = response?.turn?.id || "";
    if (!TOKEN_RE.test(responseId)) throw new Error("turn-response-invalid");
    this.turnResponseId = responseId;
    if (this.turnId && this.turnId !== responseId) throw new Error("turn-response-id-mismatch");
    this.turnId = responseId;
  }

  async execute() {
    let stderrLog;
    try {
      mkdirSync(this.options.taskTmp, { recursive: true, mode: 0o700 });
      chmodSync(this.options.taskTmp, 0o700);
      const stderrPath = path.join(this.options.taskTmp, "codex-appserver.stderr.log");
      stderrLog = new BoundedLog(stderrPath, this.owner.stderrLimit);
    } catch (error) {
      this.forcedOutcome = `stderr-log-${token(error.message)}`;
      this.childClosed = true;
      return this.result();
    }
    const codex = process.env.FM_CODEX_BIN || "codex";
    try {
      this.child = spawn(codex, ["app-server", "--listen", "stdio://"], {
        cwd: this.options.cwd,
        detached: true,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.forcedOutcome = `spawn-${token(error.message)}`;
      this.childClosed = true;
      return this.result();
    }
    const streamFailure = (name, error) => {
      this.protocolFailure(`${name}-${token(error?.message || "error")}`);
    };
    this.child.stdin.on("error", (error) => streamFailure("stdin", error));
    this.child.stdout.on("error", (error) => streamFailure("stdout", error));
    this.child.stderr.on("error", (error) => streamFailure("stderr", error));
    this.child.stderr.on("data", (chunk) => {
      try {
        stderrLog.append(chunk);
      } catch (error) {
        streamFailure("stderr-log", error);
      }
    });
    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on("line", (line) => this.handleLine(line));
    lines.on("error", (error) => streamFailure("stdout-lines", error));
    this.child.on("error", (error) => this.protocolFailure(`child-${token(error.message)}`));
    this.child.on("close", (code, signal) => this.handleClose(code, signal));
    this.startupTimer = setTimeout(() => {
      if (!this.turnId && !this.terminalStatus && !this.childClosed) {
        this.forcedOutcome = "startup-timeout";
        this.scheduleEscalation();
      }
    }, this.owner.startupTimeoutMs);
    this.handshake().catch((error) => this.protocolFailure(token(error.message)));
    return this.finishPromise;
  }
}

class OwningClient {
  constructor(options) {
    this.options = options;
    this.threadId = "";
    this.currentRun = null;
    this.queuedTurns = [];
    this.inputBuffer = "";
    this.promptVisible = false;
    this.exitRequested = false;
    this.finished = false;
    this.lastWasCarriageReturn = false;
    this.stderrLimit = positiveEnvMilliseconds("FM_CODEX_APPSERVER_STDERR_MAX_BYTES", 262144);
    this.startupTimeoutMs = positiveEnvMilliseconds("FM_CODEX_APPSERVER_STARTUP_TIMEOUT_MS", 30000);
    this.interruptGraceMs = positiveEnvMilliseconds("FM_CODEX_APPSERVER_INTERRUPT_GRACE_MS", 2000);
    this.termGraceMs = positiveEnvMilliseconds("FM_CODEX_APPSERVER_TERM_GRACE_MS", 2000);
    this.receiptPath = path.join(options.stateDir, `${options.taskId}.codex-appserver-result`);
  }

  clearPrompt() {
    if (!this.promptVisible) return;
    process.stdout.write("\r\u001b[2K");
    this.promptVisible = false;
  }

  renderPrompt() {
    if (this.finished) return;
    if (this.currentRun && !this.inputBuffer) {
      this.promptVisible = false;
      return;
    }
    process.stdout.write(`\r\u001b[2K› ${this.inputBuffer}`);
    this.promptVisible = true;
  }

  writeAgent(text) {
    this.clearPrompt();
    process.stdout.write(text);
    this.renderPrompt();
  }

  apply(state, event, deadlineAt = 0) {
    const args = [
      BUSY_EVENT,
      "apply",
      this.options.stateDir,
      this.options.taskId,
      state,
      "--gen",
      this.options.generation,
      "--source",
      "codex-appserver",
      "--event",
      event,
    ];
    if (deadlineAt) args.push("--deadline-at", String(deadlineAt));
    const result = spawnSync(args[0], args.slice(1), { encoding: "utf8" });
    if (result.status !== 0) {
      throw new Error((result.stderr || result.stdout || "busy event failed").trim());
    }
  }

  applyBusy(deadlineAt) {
    this.apply("busy", "turn-started", deadlineAt);
  }

  writeReceipt(result) {
    const line = [
      "v1",
      `gen=${this.options.generation}`,
      `outcome=${token(result.outcome)}`,
      `event=${token(result.event)}`,
      `thread=${token(result.threadId)}`,
      `turn=${token(result.turnId)}`,
      `terminal=${token(result.terminalStatus)}`,
      `terminal_error=${token(result.terminalError)}`,
      `child_pid=${result.childPid || 0}`,
      `child_exit=${result.childCode === null ? "none" : result.childCode}`,
      `child_signal=${token(result.childSignal)}`,
      `started=${result.startedAt}`,
      `ended=${result.endedAt}`,
      `deadline=${result.deadlineAt || "none"}`,
      "stderr_log=codex-appserver.stderr.log",
    ].join(" ");
    const temporary = `${this.receiptPath}.tmp.${process.pid}`;
    writeFileSync(temporary, `${line}\n`, { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.receiptPath);
  }

  publish(result) {
    this.writeReceipt(result);
    if (result.outcome === "success") {
      this.apply("idle", "turn-completed");
    } else {
      this.apply("unknown", result.event);
    }
    closeSync(openSync(this.options.turnEnded, "a", 0o600));
  }

  async startTurn(prompt) {
    if (this.currentRun || this.finished) {
      this.queuedTurns.push(prompt);
      return;
    }
    const run = new AppServerRun(this, prompt, this.threadId);
    this.currentRun = run;
    const result = await run.execute();
    try {
      this.publish(result);
    } catch (error) {
      this.clearPrompt();
      process.stderr.write(`fm-codex-appserver-client: failed to publish terminal result: ${error.message}\n`);
      this.finished = true;
      process.exitCode = 1;
      return;
    }
    if (result.preserveThread) this.threadId = result.threadId;
    else this.threadId = "";
    this.currentRun = null;
    this.clearPrompt();
    process.stdout.write(`\n[Codex turn ${result.outcome}: ${result.event}]\n`);
    if (this.options.oneShot || this.exitRequested) {
      this.finish(this.options.oneShot && result.outcome !== "success" ? 1 : 0);
      return;
    }
    this.renderPrompt();
    const next = this.queuedTurns.shift();
    if (next !== undefined) this.startTurn(next);
  }

  submitLine(line) {
    const text = line.trim();
    if (!text) return;
    if (text === "/quit" || text === "/exit") {
      this.exitRequested = true;
      if (this.currentRun) this.currentRun.interrupt();
      else this.finish(0);
      return;
    }
    if (this.currentRun) {
      this.currentRun.steer(text).then((accepted) => {
        if (!accepted && !this.finished) this.queuedTurns.push(text);
      });
      return;
    }
    this.startTurn(text);
  }

  interrupt() {
    if (this.currentRun) this.currentRun.interrupt();
  }

  handleInput(data) {
    for (const character of data) {
      if (character === "\u001b") {
        this.interrupt();
        continue;
      }
      if (character === "\u0003") {
        this.exitRequested = true;
        if (this.currentRun) this.currentRun.interrupt();
        else this.finish(130);
        continue;
      }
      if (character === "\u0015") {
        this.inputBuffer = "";
        this.renderPrompt();
        continue;
      }
      if (character === "\u007f" || character === "\b") {
        this.inputBuffer = this.inputBuffer.slice(0, -1);
        this.renderPrompt();
        continue;
      }
      if (character === "\r" || character === "\n") {
        if (character === "\n" && this.lastWasCarriageReturn) {
          this.lastWasCarriageReturn = false;
          continue;
        }
        this.lastWasCarriageReturn = character === "\r";
        const line = this.inputBuffer;
        this.inputBuffer = "";
        this.clearPrompt();
        process.stdout.write("\n");
        this.submitLine(line);
        this.renderPrompt();
        continue;
      }
      this.lastWasCarriageReturn = false;
      if (character >= " " && character !== "\u007f") {
        this.inputBuffer += character;
        this.renderPrompt();
      }
    }
  }

  finish(code) {
    if (this.finished) return;
    this.finished = true;
    this.clearPrompt();
    if (this.threadId) process.stdout.write(`\nCodex thread: ${this.threadId}\n`);
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode(false);
    }
    process.exitCode = code;
    process.stdin.pause();
  }

  start() {
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode(true);
    }
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (data) => this.handleInput(data));
    process.stdin.resume();
    process.on("SIGTERM", () => {
      this.exitRequested = true;
      if (this.currentRun) {
        this.currentRun.forcedOutcome ||= "supervisor-sigterm";
        this.currentRun.scheduleEscalation();
      } else {
        this.finish(143);
      }
    });
    process.on("SIGHUP", () => {
      this.exitRequested = true;
      if (this.currentRun) {
        this.currentRun.forcedOutcome ||= "supervisor-sighup";
        this.currentRun.scheduleEscalation();
      } else {
        this.finish(129);
      }
    });
    this.renderPrompt();
    if (this.options.promptSet) this.startTurn(this.options.prompt);
  }
}

let options;
try {
  options = parseArguments(process.argv.slice(2));
} catch (error) {
  usage(error.message);
}

if (options) {
  try {
    const client = new OwningClient(options);
    client.start();
  } catch (error) {
    process.stderr.write(`fm-codex-appserver-client: ${error.message}\n`);
    process.exitCode = 1;
  }
}
