import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;
let triggerText = "";
let replyText = "";
let replyID = "";

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

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
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function runSessionstartNudge(): string {
  const result = spawnSync(`${root}/bin/fm-sessionstart-nudge.sh`, [], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function runGuard(payload: Record<string, unknown>): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolveResult) => {
    const harness = process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi";
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, ["--stow-harness", harness], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(JSON.stringify({ stop_hook_active: false, ...payload }));
  });
}

function assistantText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } =>
      part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("");
}

function sessionIDFromContext(ctx: unknown): string {
  const manager = (ctx as { sessionManager?: { getSessionId?: () => unknown } } | undefined)?.sessionManager;
  const sessionID = manager?.getSessionId?.();
  return typeof sessionID === "string" && sessionID ? sessionID : "unknown";
}

function guardPayload(sessionID: string): Record<string, unknown> {
  if (!replyText || !replyID) return {};
  return {
    fm_reply_text: replyText,
    fm_reply_id: replyID,
    fm_trigger_text: triggerText,
    session_id: sessionID,
  };
}

// The guard declares the envelope kind, so routing never depends on the
// message's wording. An envelope without the discriminator is an ordinary
// turn-end notice.
function deliverSystemMessages(pi: ExtensionAPI, ctx: unknown, stdout: string): void {
  if (!stdout) return;
  for (const line of stdout.split("\n")) {
    if (!line.trim()) continue;
    try {
      const parsed = JSON.parse(line) as { systemMessage?: unknown; kind?: unknown };
      if (typeof parsed.systemMessage !== "string" || !parsed.systemMessage) continue;
      const isCaptainWarning = parsed.kind === "captain-comms-warning";
      if (isCaptainWarning) {
        const notify = (ctx as { ui?: { notify?: (message: string, type: string) => void } } | undefined)?.ui?.notify;
        if (typeof notify === "function") notify(parsed.systemMessage, "warning");
        continue;
      }
      pi.sendMessage({
        customType: "firstmate-turnend-guard-notice",
        content: parsed.systemMessage,
        display: true,
        details: { kind: "turn-end-guard" },
      });
    } catch {
    }
  }
}

// Only the supervision banner belongs in a forced continuation; the guard's
// advisory diagnostics reach their audience on their own channel.
function bannerOnly(stderr: string): string {
  return (stderr ?? "")
    .split("\n")
    .filter((line) => line.startsWith("\u25cf"))
    .join("\n");
}

function recordStowCadenceActivity(activity: "busy" | "idle", invocation?: string): void {
  const harness = process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi";
  const args = ["activity", activity, "--harness", harness];
  if (invocation !== undefined) args.push("--invocation-stdin");
  spawnSync(`${root}/bin/fm-stow-cadence-lab.sh`, args, {
    input: invocation,
    stdio: ["pipe", "ignore", "ignore"],
  });
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
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

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", (event) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const nudge = ["startup", "new", "resume"].includes(reason) ? runSessionstartNudge() : "";
    markLoaded();
    if (!nudge) return;
    try {
      pi.sendMessage({
        customType: "firstmate-sessionstart-nudge",
        content: nudge,
        display: false,
        details: { kind: "session-start" },
      });
    } catch {
    }
  });

  pi.on("input", (event) => {
    triggerText = String((event as { text?: unknown }).text ?? "");
    replyText = "";
    replyID = "";
  });

  pi.on("turn_end", (event, ctx) => {
    const message = (event as { message?: unknown }).message;
    const text = assistantText(message);
    if (!text) return;
    const timestamp = (message as { timestamp?: unknown } | undefined)?.timestamp;
    const turnIndex = (event as { turnIndex?: unknown }).turnIndex;
    const suffix = typeof timestamp === "number" || typeof timestamp === "string"
      ? String(timestamp)
      : String(turnIndex ?? "unknown");
    replyText = text;
    replyID = `${sessionIDFromContext(ctx)}:${suffix}`;
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("before_agent_start", (event) => {
    recordStowCadenceActivity("busy", event.prompt);
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      recordStowCadenceActivity("idle");
      return;
    }

    const result = await runGuard(guardPayload(sessionIDFromContext(ctx)));
    deliverSystemMessages(pi, ctx, result.stdout);
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          bannerOnly(result.stderr),
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
      recordStowCadenceActivity("idle");
    }
  });

  markLoaded();
}
