import { readFileSync } from "node:fs";
import { connect } from "node:net";

import {
  PROTOCOL,
  conciseError,
  normalizeOperation,
  requireHome,
  socketPath,
} from "./common.mjs";

export async function runClient(argv) {
  const parsed = parseClientArgs(argv);
  const home = requireHome();
  const sock = parsed.socket || socketPath(home);
  const request = {
    protocol: PROTOCOL,
    taskId: parsed.taskId,
    handle: parsed.handle,
    operation: parsed.operation,
    args: parsed.args,
  };
  if (request.operation === "attach-existing") {
    await runAttachClient(sock, request);
    return;
  }
  const response = await requestOnce(sock, request);
  if (!response.ok) {
    process.stderr.write(`${response.error}: ${response.message || "broker denied request"}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(`${JSON.stringify(response.result, null, 2)}\n`);
}

function parseClientArgs(argv) {
  const command = normalizeOperation(argv[0] || "");
  const args = argv.slice(1);
  let taskId = process.env.FM_LNDEV_CAPTAIN_TASK_ID || process.env.FM_TASK_ID || "";
  let handle = process.env.FM_LNDEV_CAPTAIN_HANDLE || "";
  let handleFile = process.env.FM_LNDEV_CAPTAIN_HANDLE_FILE || "";
  let socket = "";
  let sessionId = "";
  const rest = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--task") taskId = requiredValue(args, ++i, arg);
    else if (arg === "--handle") handle = requiredValue(args, ++i, arg);
    else if (arg === "--handle-file") handleFile = requiredValue(args, ++i, arg);
    else if (arg === "--socket") socket = requiredValue(args, ++i, arg);
    else if (arg === "--session") sessionId = requiredValue(args, ++i, arg);
    else rest.push(arg);
  }
  if (!handle && handleFile) handle = readFileSync(handleFile, "utf8").trim();
  if (!taskId) taskId = "";
  const normalizedArgs = {};
  if (sessionId) normalizedArgs.sessionId = sessionId;
  if (rest.length > 0) normalizedArgs.extra = rest;
  return { operation: command, taskId, handle, socket, args: normalizedArgs };
}

async function requestOnce(sock, request) {
  return await new Promise((resolve, reject) => {
    const socket = connect(sock);
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const idx = buffer.indexOf("\n");
      if (idx !== -1) {
        socket.end();
        try {
          resolve(JSON.parse(buffer.slice(0, idx)));
        } catch (error) {
          reject(error);
        }
      }
    });
    socket.on("error", reject);
  });
}

async function runAttachClient(sock, request) {
  await new Promise((resolve, reject) => {
    const socket = connect(sock);
    let buffer = "";
    let finalOk = false;
    let gotFinal = false;
    socket.setEncoding("utf8");
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`);
      process.stdin.on("data", (chunk) => {
        socket.write(`${JSON.stringify({ kind: "stdin", data: Buffer.from(chunk).toString("base64") })}\n`);
      });
      process.stdin.on("end", () => {
        socket.write(`${JSON.stringify({ kind: "stdin-end" })}\n`);
      });
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      let idx;
      while ((idx = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        let frame;
        try {
          frame = JSON.parse(line);
        } catch (error) {
          reject(error);
          return;
        }
        if (frame.event === "attach-data") {
          const bytes = Buffer.from(frame.data || "", "base64");
          if (frame.stream === "stderr") process.stderr.write(bytes);
          else process.stdout.write(bytes);
          continue;
        }
        if (frame.event === "attach-start") continue;
        if (frame.event === "attach-end") {
          gotFinal = true;
          finalOk = Boolean(frame.ok);
          if (!finalOk) process.stderr.write(`${frame.error}: ${frame.message || "attach failed"}\n`);
          continue;
        }
        if (frame.ok === false) {
          gotFinal = true;
          finalOk = false;
          process.stderr.write(`${frame.error}: ${frame.message || "broker denied request"}\n`);
          continue;
        }
      }
    });
    socket.on("end", () => {
      if (!gotFinal) {
        process.exitCode = 1;
        resolve();
        return;
      }
      process.exitCode = finalOk ? 0 : 1;
      resolve();
    });
    socket.on("error", (error) => {
      process.stderr.write(`${conciseError(error)}\n`);
      process.exitCode = 1;
      resolve();
    });
  });
}

function requiredValue(args, index, flag) {
  if (index >= args.length || !args[index]) throw new Error(`${flag} requires a value`);
  return args[index];
}
