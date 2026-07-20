import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { BrokerDenied, assertNotSandboxCaller } from "./common.mjs";

export async function inspectPeer(socket) {
  const fd = socket?._handle?.fd;
  if (!Number.isInteger(fd)) {
    throw new BrokerDenied("peer-inspect-failed", "accepted socket fd was unavailable");
  }
  const runner = fileURLToPath(new URL("./peer_inspect.py", import.meta.url));
  const python = process.env.FM_LNDEV_PYTHON || "python3";
  const result = await runPeerInspector(python, runner, fd);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout || "{}");
  } catch {
    throw new BrokerDenied("peer-inspect-failed", "peer inspector returned non-JSON output");
  }
  if (result.status !== 0 || !parsed.ok) {
    throw new BrokerDenied("peer-inspect-failed", parsed.error || result.stderr || "peer inspection failed");
  }
  const peer = parsed.peer;
  if (!peer?.envReadable || !peer?.cwdReadable) {
    throw new BrokerDenied("peer-inspect-failed", "peer env/cwd could not be read server-side");
  }
  assertNotSandboxCaller(peer);
  return peer;
}

async function runPeerInspector(python, runner, fd) {
  const timeoutMs = Number(process.env.FM_LNDEV_PEER_INSPECT_TIMEOUT_MS || 5000);
  return await new Promise((resolve, reject) => {
    const child = spawn(python, [runner], {
      stdio: ["ignore", "pipe", "pipe", fd],
    });
    let settled = false;
    let stdout = "";
    let stderr = "";
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(reject, new BrokerDenied("peer-inspect-failed", "peer inspection timed out"));
    }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish(reject, new BrokerDenied("peer-inspect-failed", error.message));
    });
    child.on("close", (status, signal) => {
      finish(resolve, { status, signal, stdout, stderr });
    });
  });
}
