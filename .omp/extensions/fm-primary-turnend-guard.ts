import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "../../.pi/extensions/lib/fm-operational-input.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || fmHome + "/state";
const marker = state + "/.omp-turnend-extension-loaded";
const extensionVersion = "sha256:" + createHash("sha256").update(readFileSync(extensionFile)).digest("hex");

type LockOwnership = "owned" | "missing" | "other";

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(state + "/.lock", "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 16; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, extensionVersion + "\n" + process.pid + "\n");
}

const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nOMP SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(root + "/bin/fm-sessionstart-run.sh", ["--source", source], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    let retainedBytes = 0;
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => {
      if (code !== 0) {
        resolveResult("");
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      resolveResult(truncated ? raw + sessionstartTruncatedMarker : raw);
    });
  });
}

async function injectSessionstart(api: ExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    api.sendMessage(
      {
        customType: "firstmate-sessionstart-nudge",
        content,
        display: false,
        details: { kind: "session-start", source },
      },
      { deliverAs: "nextTurn" },
    );
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(root + "/bin/fm-turnend-guard.sh", {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

// Both PreToolUse seatbelts share this extension with the native turn-end guard.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(root + "/bin/" + script, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

export default function (api: ExtensionAPI) {
  api.on("session_start", async () => {
    markLoaded();
    await injectSessionstart(api, "startup");
  });

  // OMP's session_start payload is {type:"session_start"} with no reason field.
  // Session replacement reasons arrive on session_switch instead.
  api.on("session_switch", async (event) => {
    markLoaded();
    const source = { new: "clear", resume: "resume", fork: "fork" }[event.reason];
    if (source) await injectSessionstart(api, source);
  });

  api.on("session_compact", async () => {
    await injectSessionstart(api, "compact");
  });

  api.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runChecker("fm-arm-pretool-check.sh", command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm seatbelt" };
  });

  api.on("session_stop", async () => {
    const result = await runGuard();
    if (result.code !== 2) return {};
    return {
      continue: true,
      additionalContext: encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      ),
    };
  });

  markLoaded();
}
