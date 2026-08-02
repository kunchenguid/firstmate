#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import { createConnection } from "node:net";

const [, , socketPath, command, ...args] = process.argv;
const websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function die(message) {
  console.error(`error: ${message}`);
  process.exitCode = 1;
}

if (!socketPath?.startsWith("/") || !command) {
  die("usage: codex-app-client.mjs <absolute-socket> <ping|create|send|capture|state|interrupt|archive> [args]");
  process.exit();
}

function validThreadId(value) {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(value);
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => resolve(input));
    process.stdin.on("error", reject);
  });
}

function websocketFrame(opcode, payload = Buffer.alloc(0)) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const mask = randomBytes(4);
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | body.length]);
  } else if (body.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  const masked = Buffer.allocUnsafe(body.length);
  for (let i = 0; i < body.length; i += 1) masked[i] = body[i] ^ mask[i % 4];
  return Buffer.concat([header, mask, masked]);
}

async function connectWebSocket(path) {
  const socket = createConnection(path);
  const key = randomBytes(16).toString("base64");
  const expectedAccept = createHash("sha1").update(key + websocketGuid).digest("base64");
  let buffer = Buffer.alloc(0);
  let handshakeDone = false;
  let fragmentOpcode = null;
  let fragments = [];
  const messageListeners = new Set();

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WebSocket handshake timed out")), 10000);
    socket.once("error", reject);
    socket.once("connect", () => {
      socket.write([
        "GET / HTTP/1.1",
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n"));
    });
    const onHandshakeData = (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const headers = buffer.subarray(0, end).toString("utf8");
      buffer = buffer.subarray(end + 4);
      if (!/^HTTP\/1\.1 101\b/m.test(headers)) {
        reject(new Error(`WebSocket upgrade refused: ${headers.split("\r\n")[0] || "empty response"}`));
        return;
      }
      const accept = headers.match(/^Sec-WebSocket-Accept:\s*(.+)$/im)?.[1]?.trim();
      if (accept !== expectedAccept) {
        reject(new Error("WebSocket upgrade returned an invalid accept token"));
        return;
      }
      clearTimeout(timer);
      handshakeDone = true;
      socket.off("data", onHandshakeData);
      resolve();
    };
    socket.on("data", onHandshakeData);
  });

  function emitMessage(text) {
    for (const listener of messageListeners) listener(text);
  }

  function parseFrames() {
    while (buffer.length >= 2) {
      const first = buffer[0];
      const second = buffer[1];
      const fin = (first & 0x80) !== 0;
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        const wide = buffer.readBigUInt64BE(2);
        if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("WebSocket frame is too large");
        length = Number(wide);
        offset = 10;
      }
      const maskBytes = masked ? 4 : 0;
      if (buffer.length < offset + maskBytes + length) return;
      const mask = masked ? buffer.subarray(offset, offset + 4) : null;
      offset += maskBytes;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      buffer = buffer.subarray(offset + length);
      if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];

      if (opcode === 0x8) {
        if (!socket.destroyed) socket.end(websocketFrame(0x8, payload));
        return;
      }
      if (opcode === 0x9) {
        socket.write(websocketFrame(0xA, payload));
        continue;
      }
      if (opcode === 0xA) continue;
      if (opcode === 0x1 || opcode === 0x2) {
        fragmentOpcode = opcode;
        fragments = [payload];
      } else if (opcode === 0x0 && fragmentOpcode !== null) {
        fragments.push(payload);
      } else {
        continue;
      }
      if (fin) {
        const complete = Buffer.concat(fragments);
        const completedOpcode = fragmentOpcode;
        fragmentOpcode = null;
        fragments = [];
        if (completedOpcode === 0x1) emitMessage(complete.toString("utf8"));
      }
    }
  }

  socket.on("data", (chunk) => {
    if (!handshakeDone) return;
    buffer = Buffer.concat([buffer, chunk]);
    parseFrames();
  });
  if (buffer.length) parseFrames();

  return {
    socket,
    sendText(text) { socket.write(websocketFrame(0x1, text)); },
    onMessage(listener) { messageListeners.add(listener); },
    close() {
      if (!socket.destroyed) {
        const code = Buffer.alloc(2);
        code.writeUInt16BE(1000);
        socket.end(websocketFrame(0x8, code));
      }
    },
  };
}

let connection;
try {
  connection = await connectWebSocket(socketPath);
} catch (error) {
  die(error.message);
  process.exit();
}
let nextId = 1;
const pending = new Map();

function send(message) {
  connection.sendText(JSON.stringify(message));
}

function request(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out`));
    }, 20000);
    pending.set(id, { resolve, reject, timer, method });
    send({ id, method, params });
  });
}

connection.onMessage((line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.id !== undefined && pending.has(message.id)) {
    const waiter = pending.get(message.id);
    clearTimeout(waiter.timer);
    pending.delete(message.id);
    if (message.error) {
      waiter.reject(new Error(`${waiter.method}: ${message.error.message || "request failed"}`));
    } else {
      waiter.resolve(message.result);
    }
    return;
  }
  if (message.id !== undefined && message.method) {
    send({ id: message.id, error: { code: -32601, message: "Firstmate client does not handle this server request" } });
  }
});

connection.socket.on("error", (error) => {
  for (const waiter of pending.values()) {
    clearTimeout(waiter.timer);
    waiter.reject(error);
  }
  pending.clear();
});

connection.socket.on("close", () => {
  for (const waiter of pending.values()) {
    clearTimeout(waiter.timer);
    waiter.reject(new Error("app-server WebSocket closed"));
  }
  pending.clear();
});

async function initialize() {
  await request("initialize", {
    clientInfo: { name: "firstmate", title: "Firstmate", version: "1" },
    capabilities: {
      requestAttestation: false,
      optOutNotificationMethods: [
        "command/exec/outputDelta",
        "item/agentMessage/delta",
        "item/fileChange/outputDelta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
      ],
    },
  });
  send({ method: "initialized", params: {} });
}

async function readThread(threadId, includeTurns = false) {
  if (!validThreadId(threadId)) throw new Error("invalid Codex App thread id");
  const result = await request("thread/read", { threadId, includeTurns });
  if (!result?.thread?.id) throw new Error("thread/read returned no thread");
  return result.thread;
}

function activeTurn(thread) {
  const turns = Array.isArray(thread.turns) ? thread.turns : [];
  return [...turns].reverse().find((turn) => turn?.status === "inProgress") || null;
}

async function waitUntilIdle(threadId) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const thread = await readThread(threadId, true);
    if (thread.status?.type !== "active") return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Codex App thread did not become idle after interrupt");
}

function itemText(item) {
  if (!item || typeof item !== "object") return "";
  if (item.type === "agentMessage" && typeof item.text === "string") return `[assistant] ${item.text}`;
  if (item.type === "userMessage" && Array.isArray(item.content)) {
    const text = item.content
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("\n");
    return text ? `[user] ${text}` : "";
  }
  if (item.type === "commandExecution") {
    const commandText = typeof item.command === "string" ? `$ ${item.command}` : "$ <command>";
    const output = typeof item.aggregatedOutput === "string" ? item.aggregatedOutput : "";
    return output ? `${commandText}\n${output}` : commandText;
  }
  return "";
}

async function main() {
  await initialize();
  switch (command) {
    case "ping":
      process.stdout.write("ok");
      return;
    case "create": {
      const [title, cwd, model = "default", effort = "default"] = args;
      if (!title || !cwd?.startsWith("/")) throw new Error("create requires title and absolute cwd");
      const params = { cwd, approvalPolicy: "never", sandbox: "danger-full-access", threadSource: "firstmate" };
      if (model && model !== "default") params.model = model;
      if (effort && effort !== "default") params.config = { model_reasoning_effort: effort };
      const result = await request("thread/start", params);
      const threadId = result?.thread?.id;
      if (!validThreadId(threadId)) throw new Error("thread/start returned an invalid thread id");
      await request("thread/name/set", { threadId, name: title });
      process.stdout.write(threadId);
      return;
    }
    case "send": {
      const [threadId] = args;
      const text = await readStdin();
      if (!text.trim()) throw new Error("refusing empty Codex App message");
      const thread = await readThread(threadId, true);
      if (thread.status?.type === "active") {
        const turn = activeTurn(thread);
        if (!turn?.id) throw new Error("active Codex App thread has no active turn id");
        await request("turn/steer", { threadId, expectedTurnId: turn.id, input: [{ type: "text", text }] });
      } else {
        await request("thread/resume", { threadId });
        await request("turn/start", { threadId, input: [{ type: "text", text }] });
      }
      process.stdout.write("empty");
      return;
    }
    case "capture": {
      const [threadId, rawLines = "40"] = args;
      const count = Number.parseInt(rawLines, 10);
      if (!Number.isInteger(count) || count < 1 || count > 1000) throw new Error("capture lines must be 1..1000");
      const thread = await readThread(threadId, true);
      const text = (thread.turns || []).flatMap((turn) => turn.items || []).map(itemText).filter(Boolean).join("\n");
      process.stdout.write(text.split("\n").slice(-count).join("\n"));
      return;
    }
    case "state": {
      const thread = await readThread(args[0], false);
      const type = thread.status?.type;
      if (type === "active") process.stdout.write("busy");
      else if (type === "idle" || type === "notLoaded") process.stdout.write("idle");
      else process.stdout.write("unknown");
      return;
    }
    case "interrupt": {
      const thread = await readThread(args[0], true);
      const turn = activeTurn(thread);
      if (turn?.id) {
        await request("turn/interrupt", { threadId: thread.id, turnId: turn.id });
        await waitUntilIdle(thread.id);
      }
      return;
    }
    case "archive": {
      const thread = await readThread(args[0], true);
      const turn = activeTurn(thread);
      if (turn?.id) {
        await request("turn/interrupt", { threadId: thread.id, turnId: turn.id });
        await waitUntilIdle(thread.id);
      }
      await request("thread/archive", { threadId: thread.id });
      return;
    }
    default:
      throw new Error(`unknown Codex App client command '${command}'`);
  }
}

try {
  await main();
  connection.close();
} catch (error) {
  connection.close();
  die(error.message);
}
