import { spawn } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { appendAudit } from "./audit.mjs";
import { validateCapability } from "./capabilities.mjs";
import {
  BrokerDenied,
  PROTOCOL,
  StreamingRedactor,
  allowedOperation,
  conciseError,
  ensureHomeDirs,
  normalizeOperation,
  readTaskMeta,
  redactText,
  sha256,
  socketPath,
  supportedLndevVersions,
  transcriptDir,
} from "./common.mjs";
import {
  assertSupportedLndevVersion,
  collectIdentityMetadata,
  safeLndevEnv,
  shellList,
  validateAttachTranscript,
} from "./lndev.mjs";
import { inspectPeer } from "./peer.mjs";

const REQUEST_LINE_MAX = 64 * 1024;
const FRAME_LINE_MAX = 256 * 1024;
const DECODED_STDIN_FRAME_MAX = 64 * 1024;
const STDIN_BUFFERED_MAX = 256 * 1024;

export async function serveBroker(home) {
  ensureHomeDirs(home);
  const sock = socketPath(home);
  let startGate = { ok: true, version: null, reason: null };
  try {
    startGate.version = await assertSupportedLndevVersion();
  } catch (error) {
    startGate = { ok: false, version: error.details?.version || null, reason: conciseError(error) };
  }
  await appendAudit(home, {
    event: "broker_start",
    operation: "broker_start",
    result: startGate.ok ? "allowed" : "denied",
    reason: startGate.reason,
    lndev: { version: startGate.version, supported: supportedLndevVersions() },
  });

  if (existsSync(sock)) unlinkSync(sock);
  const server = createServer((socket) => {
    void handleConnection(home, socket);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(sock, () => {
      server.off("error", reject);
      chmodSync(sock, 0o600);
      resolve();
    });
  });
  process.stdout.write(`lndev captain broker listening on ${sock}\n`);
  await new Promise(() => {});
}

async function handleConnection(home, socket) {
  socket.setEncoding("utf8");
  socket.pause();
  socket.on("error", () => {});
  let buffer = "";
  let sawRequest = false;
  let frameHandler = null;
  let closed = false;
  let peer = null;
  let pendingFrameBytes = 0;
  try {
    peer = await inspectPeer(socket);
  } catch (error) {
    void appendAudit(home, {
      event: "request",
      caller: null,
      operation: "unknown",
      result: "denied",
      reason: conciseError(error),
    });
    writeJsonLine(socket, {
      ok: false,
      error: error instanceof BrokerDenied ? error.reason : "peer-inspect-failed",
      message: conciseError(error),
    });
    socket.end();
    return;
  }
  if (socket.destroyed) return;
  const pendingFrames = [];
  const setFrameHandler = (handler) => {
    frameHandler = handler;
    while (pendingFrames.length > 0) {
      const frame = pendingFrames.shift();
      pendingFrameBytes -= frame.length;
      frameHandler(frame);
    }
  };

  socket.on("data", (chunk) => {
    if (closed) return;
    buffer += chunk;
    const limit = sawRequest ? FRAME_LINE_MAX : REQUEST_LINE_MAX;
    if (buffer.length > limit) {
      closed = true;
      void appendAudit(home, {
        event: "request",
        caller: peer,
        operation: "unknown",
        result: "denied",
        reason: sawRequest ? "frame-too-large" : "request-too-large",
      });
      writeJsonLine(socket, {
        ok: false,
        error: sawRequest ? "frame-too-large" : "request-too-large",
        message: "broker request buffer limit exceeded",
      });
      socket.end();
      return;
    }
    let idx;
    while ((idx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 1);
      if (!sawRequest) {
        sawRequest = true;
        void handleRequest(home, socket, line, peer, setFrameHandler);
      } else if (frameHandler) {
        frameHandler(line);
      } else {
        pendingFrameBytes += line.length;
        if (pendingFrameBytes > FRAME_LINE_MAX) {
          closed = true;
          void appendAudit(home, {
            event: "request",
            caller: peer,
            operation: "unknown",
            result: "denied",
            reason: "frame-too-large",
          });
          writeJsonLine(socket, {
            ok: false,
            error: "frame-too-large",
            message: "broker frame buffer limit exceeded",
          });
          socket.end();
          return;
        }
        pendingFrames.push(line);
      }
    }
  });
  socket.resume();
}

async function handleRequest(home, socket, line, peer, setFrameHandler) {
  const start = Date.now();
  let req = null;
  let taskMeta = null;
  let identity = null;
  let cap = null;
  let operation = "unknown";
  try {
    req = parseRequest(line);
    operation = req.operation;
    taskMeta = readTaskMeta(home, req.taskId);
    if (!allowedOperation(operation)) {
      throw new BrokerDenied("operation-not-allowed", `operation ${operation} is denied by v1 allowlist`);
    }
    cap = await validateCapability(home, req, taskMeta);
    identity = await collectIdentityMetadata();
    if (operation === "status") {
      const result = {
        broker: { protocol: PROTOCOL, supportedLndevVersions: supportedLndevVersions() },
        lndev: identity,
      };
      await auditRequest(home, req, taskMeta, identity, cap, peer, "allowed", null, Date.now() - start);
      writeJsonLine(socket, { ok: true, result });
      socket.end();
      return;
    }
    if (operation === "shell-list") {
      const result = await shellList();
      await auditRequest(home, req, taskMeta, identity, cap, peer, "allowed", null, Date.now() - start);
      writeJsonLine(socket, { ok: true, result });
      socket.end();
      return;
    }
    await auditRequest(home, req, taskMeta, identity, cap, peer, "allowed", null, Date.now() - start);
    await runAttach(home, socket, req, taskMeta, identity, cap, peer, setFrameHandler);
  } catch (error) {
    const reason = error instanceof BrokerDenied ? error.reason : "error";
    await auditRequest(home, req, taskMeta, identity, cap, peer, reason === "error" ? "error" : "denied", conciseError(error), Date.now() - start);
    if (operation === "attach-existing") appendTaskStatus(home, req?.taskId, `blocked: lndev attach denied ${reason}`);
    writeJsonLine(socket, { ok: false, error: reason, message: conciseError(error) });
    socket.end();
  }
}

function parseRequest(line) {
  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new BrokerDenied("bad-request", "request was not JSON");
  }
  if (parsed.protocol !== PROTOCOL) throw new BrokerDenied("bad-protocol", "unsupported protocol");
  const operation = normalizeOperation(parsed.operation);
  return {
    protocol: parsed.protocol,
    taskId: parsed.taskId,
    handle: parsed.handle,
    operation,
    args: parsed.args || {},
  };
}

async function runAttach(home, socket, req, taskMeta, identity, cap, peer, setFrameHandler) {
  const sessionId = req.args.sessionId;
  const attachmentId = `attach_${Date.now().toString(36)}_${Math.random().toString(16).slice(2, 10)}`;
  const transcriptCapture = newTranscriptCapture();
  appendTaskStatus(home, req.taskId, `working: lndev attach start session ${sessionId}`);
  await appendAudit(home, {
    event: "attach_start",
    task: { id: req.taskId, meta: taskMeta },
    caller: peer,
    operation: req.operation,
    normalized_args: { sessionId },
    session_id: sessionId,
    capability_id: cap.id,
    lndev: identity,
    attach: {
      session_id: sessionId,
      broker_attachment_id: attachmentId,
      start: new Date().toISOString(),
      transcript_policy: cap.transcriptPolicy,
    },
    result: "allowed",
  });
  writeJsonLine(socket, { ok: true, event: "attach-start", attachmentId, sessionId });
  const started = Date.now();
  try {
    const attach = await spawnAttach(sessionId, socket, setFrameHandler, transcriptCapture);
    const markers = validateAttachTranscript(attach.transcript, sessionId);
    const transcript = writeAttachTranscript(home, attachmentId, cap, transcriptCapture, "allowed", null);
    const metadata = {
      session_id: sessionId,
      broker_attachment_id: attachmentId,
      start: new Date(started).toISOString(),
      end: new Date().toISOString(),
      heartbeat_count: 0,
      detach_result: "confirmed",
      stdout_bytes: attach.stdoutBytes,
      stderr_bytes: attach.stderrBytes,
      transcript_policy: cap.transcriptPolicy,
      transcript_path: transcript.path,
      transcript_digest: transcript.digest,
      transcript_bytes: transcript.bytes,
      transcript_hash_alg: transcript.hashAlg,
      attach_output_digest: markers.transcriptDigest,
    };
    await appendAudit(home, {
      event: "attach_stop",
      task: { id: req.taskId, meta: taskMeta },
      caller: peer,
      operation: req.operation,
      normalized_args: { sessionId },
      session_id: sessionId,
      capability_id: cap.id,
      lndev: identity,
      attach: metadata,
      result: "allowed",
      duration_ms: Date.now() - started,
    });
    appendTaskStatus(home, req.taskId, `done: lndev attach stop session ${sessionId}`);
    writeJsonLine(socket, { ok: true, event: "attach-end", result: "allowed", attach: metadata });
    socket.end();
  } catch (error) {
    const transcript = writeAttachTranscript(home, attachmentId, cap, transcriptCapture, "error", conciseError(error));
    await appendAudit(home, {
      event: "attach_stop",
      task: { id: req.taskId, meta: taskMeta },
      caller: peer,
      operation: req.operation,
      normalized_args: { sessionId },
      session_id: sessionId,
      capability_id: cap.id,
      lndev: identity,
      attach: {
        session_id: sessionId,
        broker_attachment_id: attachmentId,
        start: new Date(started).toISOString(),
        end: new Date().toISOString(),
        heartbeat_count: 0,
        detach_result: "unconfirmed",
        transcript_policy: cap.transcriptPolicy,
        transcript_path: transcript.path,
        transcript_digest: transcript.digest,
        transcript_bytes: transcript.bytes,
        transcript_hash_alg: transcript.hashAlg,
      },
      result: "error",
      reason: conciseError(error),
      duration_ms: Date.now() - started,
    });
    appendTaskStatus(home, req.taskId, `failed: lndev attach stop session ${sessionId}: ${error.reason || "error"}`);
    writeJsonLine(socket, { ok: false, event: "attach-end", error: error.reason || "error", message: conciseError(error) });
    socket.end();
  }
}

async function spawnAttach(sessionId, socket, setFrameHandler, transcriptCapture) {
  const command = attachCommand(sessionId);
  let transcript = "";
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let streamError = null;
  const stdoutRedactor = new StreamingRedactor();
  const stderrRedactor = new StreamingRedactor();
  const stdinQueue = [];
  let stdinQueuedBytes = 0;
  let stdinBlocked = false;
  let stdinEndRequested = false;
  const child = spawn(command.cmd, command.args, {
    env: safeLndevEnv(),
    cwd: process.env.HOME || "/",
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.on("error", (error) => {
    streamError = error;
    child.kill("SIGTERM");
  });
  setFrameHandler((line) => {
    if (!line) return;
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      return;
    }
    if (frame.kind === "stdin" && typeof frame.data === "string") {
      const decoded = Buffer.from(frame.data, "base64");
      if (decoded.length > DECODED_STDIN_FRAME_MAX) {
        streamError = new BrokerDenied("stdin-frame-too-large", "decoded stdin frame exceeded broker limit");
        child.kill("SIGTERM");
        return;
      }
      if (stdinBufferedBytes(child, stdinQueuedBytes) + decoded.length > STDIN_BUFFERED_MAX) {
        streamError = new BrokerDenied("stdin-buffer-too-large", "queued stdin exceeded broker limit");
        child.kill("SIGTERM");
        return;
      }
      transcriptCapture.stdin += decoded.toString("utf8");
      stdinQueue.push(decoded);
      stdinQueuedBytes += decoded.length;
      pumpStdin();
    }
    if (frame.kind === "stdin-end") {
      stdinEndRequested = true;
      pumpStdin();
    }
  });
  function pumpStdin() {
    if (stdinBlocked || streamError || child.stdin.destroyed) return;
    while (stdinQueue.length > 0) {
      const decoded = stdinQueue.shift();
      stdinQueuedBytes -= decoded.length;
      let ok = false;
      try {
        ok = child.stdin.write(decoded);
      } catch (error) {
        streamError = error;
        child.kill("SIGTERM");
        return;
      }
      if (!ok) {
        stdinBlocked = true;
        socket.pause();
        child.stdin.once("drain", () => {
          stdinBlocked = false;
          if (!socket.destroyed) socket.resume();
          pumpStdin();
        });
        return;
      }
    }
    if (stdinEndRequested && !child.stdin.destroyed) child.stdin.end();
  }
  socket.on("close", () => {
    if (!child.killed) child.kill("SIGTERM");
  });
  child.stdout.on("data", (chunk) => {
    const raw = chunk.toString("utf8");
    transcript += raw;
    transcriptCapture.stdout += raw;
    let redacted = "";
    try {
      redacted = cleanPtyChunk(stdoutRedactor.push(raw));
    } catch (error) {
      streamError = error;
      child.kill("SIGTERM");
      return;
    }
    stdoutBytes += Buffer.byteLength(redacted);
    if (redacted) {
      writeJsonLine(socket, { event: "attach-data", stream: "stdout", data: Buffer.from(redacted).toString("base64") });
    }
  });
  child.stderr.on("data", (chunk) => {
    const raw = chunk.toString("utf8");
    transcript += raw;
    transcriptCapture.stderr += raw;
    let redacted = "";
    try {
      redacted = cleanPtyChunk(stderrRedactor.push(raw));
    } catch (error) {
      streamError = error;
      child.kill("SIGTERM");
      return;
    }
    stderrBytes += Buffer.byteLength(redacted);
    if (redacted) {
      writeJsonLine(socket, { event: "attach-data", stream: "stderr", data: Buffer.from(redacted).toString("base64") });
    }
  });
  const timeoutMs = Number(process.env.FM_LNDEV_ATTACH_TIMEOUT_MS || 0);
  return await new Promise((resolve, reject) => {
    let timer = null;
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        child.kill("SIGTERM");
        reject(new BrokerDenied("attach-timeout", "lndev attach timed out"));
      }, timeoutMs);
    }
    child.on("error", (error) => {
      if (timer) clearTimeout(timer);
      reject(error);
    });
    child.on("close", (status, signal) => {
      if (timer) clearTimeout(timer);
      let flushedStdout = "";
      let flushedStderr = "";
      try {
        flushedStdout = cleanPtyChunk(stdoutRedactor.finish());
        flushedStderr = cleanPtyChunk(stderrRedactor.finish());
      } catch (error) {
        streamError = error;
      }
      stdoutBytes += Buffer.byteLength(flushedStdout);
      stderrBytes += Buffer.byteLength(flushedStderr);
      if (flushedStdout) {
        writeJsonLine(socket, { event: "attach-data", stream: "stdout", data: Buffer.from(flushedStdout).toString("base64") });
      }
      if (flushedStderr) {
        writeJsonLine(socket, { event: "attach-data", stream: "stderr", data: Buffer.from(flushedStderr).toString("base64") });
      }
      if (streamError) {
        reject(streamError);
        return;
      }
      if (stdoutRedactor.sawSecret || stderrRedactor.sawSecret) {
        reject(new BrokerDenied("secret-output", "lndev attach emitted credential-shaped output"));
        return;
      }
      if (status !== 0 || signal) {
        reject(new BrokerDenied("attach-exit", `lndev attach exited ${status ?? signal}`));
        return;
      }
      resolve({ transcript, stdoutBytes, stderrBytes });
    });
  });
}

function newTranscriptCapture() {
  return { stdin: "", stdout: "", stderr: "" };
}

function writeAttachTranscript(home, attachmentId, cap, capture, result, reason) {
  if (cap.transcriptPolicy === "metadata-only") {
    return { path: null, digest: null, bytes: 0, hashAlg: "sha256" };
  }
  const timestamp = new Date().toISOString();
  const day = timestamp.slice(0, 10);
  const dir = join(transcriptDir(home), day);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, `${attachmentId}.jsonl`);
  const records = [
    { timestamp, event: "transcript_start", attachment_id: attachmentId, policy: cap.transcriptPolicy },
    { timestamp, stream: "stdin", data: cleanPtyChunk(redactText(capture.stdin)) },
    { timestamp, stream: "stdout", data: cleanPtyChunk(redactText(capture.stdout)) },
    { timestamp, stream: "stderr", data: cleanPtyChunk(redactText(capture.stderr)) },
    { timestamp: new Date().toISOString(), event: "transcript_end", result, reason },
  ];
  const content = `${records.map((record) => JSON.stringify(record)).join("\n")}\n`;
  writeFileSync(path, content, { mode: 0o600 });
  chmodSync(path, 0o600);
  return {
    path,
    digest: sha256(content),
    bytes: Buffer.byteLength(content),
    hashAlg: "sha256",
  };
}

function attachCommand(sessionId) {
  const lndev = process.env.FM_LNDEV_BINARY || "lndev";
  const runner = fileURLToPath(new URL("./pty_runner.py", import.meta.url));
  const python = process.env.FM_LNDEV_PYTHON || "python3";
  return {
    cmd: python,
    args: [runner, "--", lndev, "shell", "attach", sessionId],
  };
}

function cleanPtyChunk(chunk) {
  return String(chunk).replace(/[\u0004\b]/g, "");
}

function stdinBufferedBytes(child, queuedBytes) {
  return queuedBytes + (child.stdin?.writableLength || 0);
}

async function auditRequest(home, req, taskMeta, identity, cap, peer, result, reason, durationMs) {
  await appendAudit(home, {
    event: "request",
    task: req ? { id: req.taskId, meta: taskMeta } : null,
    caller: peer || null,
    operation: req?.operation || "unknown",
    normalized_args: req?.args || {},
    session_id: req?.args?.sessionId || null,
    capability_id: cap?.id || null,
    lndev: identity,
    result,
    reason,
    duration_ms: durationMs,
  });
}

function appendTaskStatus(home, taskId, line) {
  if (!taskId || !/^[A-Za-z0-9._-]+$/.test(taskId)) return;
  const path = join(home, "state", `${taskId}.status`);
  appendFileSync(path, `${line}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}

function writeJsonLine(socket, value) {
  socket.write(`${JSON.stringify(value)}\n`);
}
