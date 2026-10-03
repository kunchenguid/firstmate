#!/usr/bin/env node
// Minimal process-event-adapter/1 example.
//
// A source configuration reference has the form file:/absolute/path.
// source.poll waits until that regular file exists, then returns its bounded
// UTF-8 contents as external evidence.
// The result is terminal and classifies as file-signal.

import { readFile, stat } from "node:fs/promises";
import path from "node:path";

const MAX_INPUT_BYTES = 65536;
const MAX_RESULT_BYTES = 16384;

async function readRequest() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw new Error("request is oversized");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function reply(requestId, result) {
  process.stdout.write(`${JSON.stringify({
    schema: "firstmate.extension-response.v1",
    request_id: requestId,
    ok: true,
    result,
    error: null,
  })}\n`);
}

function handshake(request) {
  process.stdout.write(`${JSON.stringify({
    schema: "firstmate.extension-handshake-response.v1",
    request_id: request.request_id,
    extension_id: "org.firstmate.example.file-signal",
    extension_version: "1.0.0",
    host_protocol: 1,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter_names: request.capability.adapter_names,
  })}\n`);
}

async function waitForFile(reference) {
  if (typeof reference !== "string" || !reference.startsWith("file:")) {
    throw new Error("config_ref must have the form file:/absolute/path");
  }
  const file = reference.slice("file:".length);
  if (!path.isAbsolute(file) || path.normalize(file) !== file) {
    throw new Error("config_ref file path must be normalized and absolute");
  }
  const deadline = Date.now() + 55000;
  while (Date.now() < deadline) {
    try {
      const info = await stat(file);
      if (!info.isFile()) throw new Error("configured path is not a regular file");
      const bytes = await readFile(file);
      if (bytes.length === 0 || bytes.length > MAX_RESULT_BYTES) {
        throw new Error(`configured result must contain 1-${MAX_RESULT_BYTES} bytes`);
      }
      const output = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      return output;
    } catch (error) {
      if (error && error.code === "ENOENT") {
        await new Promise((resolve) => setTimeout(resolve, 100));
        continue;
      }
      throw error;
    }
  }
  return null;
}

const verb = process.argv[2] || "";
const request = await readRequest();
if (verb === "handshake") {
  handshake(request);
} else if (verb === "invoke" && request.operation === "source.poll") {
  const output = await waitForFile(request.input.config_ref);
  reply(request.request_id, output === null
    ? { status: "no-result", output: "" }
    : { status: "result", output });
} else if (verb === "invoke" && request.operation === "result.classify") {
  reply(request.request_id, { classification: "file-signal" });
} else if (verb === "invoke" && request.operation === "result.terminal") {
  reply(request.request_id, { value: true });
} else if (verb === "invoke" && request.operation === "result.silent") {
  reply(request.request_id, { value: false });
} else {
  throw new Error("unsupported extension verb or operation");
}
