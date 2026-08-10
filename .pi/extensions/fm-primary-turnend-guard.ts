import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "./lib/fm-operational-input.ts";

let guardFollowupGeneration: number | undefined;
let sessionGeneration = 0;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
type PrimaryHarness = "pi" | "omp";
let primaryHarness: PrimaryHarness = "pi";
let marker = `${state}/.pi-turnend-extension-loaded`;
let extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function manifestFiles(manifest: string): string[] {
  const entries = readFileSync(manifest, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (entries.some((entry) => entry.startsWith("/") || entry.split("/").includes(".."))) {
    throw new Error(`invalid extension dependency manifest ${manifest}`);
  }
  return [manifest, ...entries.map((entry) => resolve(root, entry))];
}

function selectPrimaryHarness(harness: PrimaryHarness): void {
  primaryHarness = harness;
  marker = `${state}/.${harness}-turnend-extension-loaded`;
  // The OMP manifest owns the local load chain, in the same order
  // bin/fm-session-start.sh hashes it, so a stale in-memory guard cannot keep
  // reporting itself current.
  const identityFiles = harness === "omp"
    ? manifestFiles(`${root}/.omp/extensions/fm-primary-turnend-guard.manifest`)
    : [extensionFile];
  const digest = createHash("sha256");
  for (const file of identityFiles) digest.update(readFileSync(file));
  extensionVersion = `sha256:${digest.digest("hex")}`;
}

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

// Pi's session_start reasons are startup | reload | new | resume | fork, and
// OMP's session_switch reasons map onto the same wrapper sources. A separate
// session_compact event fires after a compaction. "new" is Pi's /clear while
// reload, resume, and fork all keep prior context.
const sessionstartDeliveryBytes = 512 * 1024;

type SessionStartContext = {
  sessionManager?: {
    getHeader?: () => { timestamp?: unknown } | null | undefined;
  };
};

function restoredSessionEvidence(ctx: SessionStartContext): boolean {
  try {
    const timestamp = ctx.sessionManager?.getHeader?.()?.timestamp;
    const createdAt = typeof timestamp === "string" ? Date.parse(timestamp) : Number.NaN;
    return Number.isFinite(createdAt) && createdAt < performance.timeOrigin;
  } catch {
    return false;
  }
}

function startupRebuildSource(ctx: SessionStartContext): "resume" | "fork" | undefined {
  const args = process.argv.slice(2);
  const restored = restoredSessionEvidence(ctx);
  for (const arg of args) {
    if (arg === "--fork" || arg.startsWith("--fork=")) return "fork";
    if (
      restored && (
        arg === "-c" || arg === "--continue" ||
        arg === "-r" || arg === "--resume" ||
        arg === "--session" || arg.startsWith("--session=") ||
        arg === "--session-id" || arg.startsWith("--session-id=")
      )
    ) return "resume";
  }
  return undefined;
}
function sessionstartTruncatedMarker(): string {
  return `\n\n${primaryHarness === "omp" ? "OMP" : "PI"} SESSION-START DELIVERY TRUNCATED - ` +
    "the digest exceeded 512 KiB. " +
    "Treat omitted context as unread and inspect the named files directly before acting on it.";
}

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
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
      resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker()}` : raw);
    });
  });
}

async function injectSessionstart(pi: ExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // Pi is the only adapter that injects a MESSAGE rather than hook stdout, so
    // whatever it injects must carry operational provenance or the Ahoy skill
    // would have to guess whether it was captain-authored. The wrapper already
    // returns an encoded nudge on a context-preserving open, so only an
    // unencoded digest needs the marker added here.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    pi.sendMessage({
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
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

function sessionReason(event: unknown): string {
  if (!event || typeof event !== "object" || !("reason" in event)) return "";
  return typeof event.reason === "string" ? event.reason : "";
}

function sessionSource(reason: string): string | undefined {
  switch (reason) {
    case "startup": return "startup";
    case "new": return "clear";
    case "resume":
    case "handoff": return "resume";
    case "fork": return "fork";
    default: return undefined;
  }
}

function advanceSessionGeneration(): void {
  sessionGeneration += 1;
  guardFollowupGeneration = undefined;
}

type CrossHarnessEvent = "session_switch" | "agent_end";
type CrossHarnessOn = (event: CrossHarnessEvent, handler: (event: unknown) => unknown) => void;

function registerPrimaryTurnendGuard(pi: ExtensionAPI): void {
  pi.on?.("session_start", async (event, ctx) => {
    advanceSessionGeneration();
    const reason = sessionReason(event);
    const source = primaryHarness === "omp"
      ? "startup"
      : reason === "startup"
        ? startupRebuildSource(ctx as SessionStartContext) ?? "startup"
        : sessionSource(reason);
    markLoaded();
    if (!source) return;
    await injectSessionstart(pi, source);
  });
  pi.on?.("session_shutdown", advanceSessionGeneration);

  if (primaryHarness === "omp") {
    // OMP's API is a strict event superset of the legacy Pi ExtensionAPI type.
    const onCrossHarnessEvent = pi.on as unknown as CrossHarnessOn;
    onCrossHarnessEvent.call(pi, "session_switch", async (event) => {
      advanceSessionGeneration();
      const source = sessionSource(sessionReason(event));
      markLoaded();
      if (source) await injectSessionstart(pi, source);
    });
  }

  // Pi and OMP share session_compact as the post-compaction notification.
  pi.on?.("session_compact", async () => {
    await injectSessionstart(pi, "compact");
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

  const runSettledGuard = async () => {
    const generation = sessionGeneration;
    if (guardFollowupGeneration === generation) {
      guardFollowupGeneration = undefined;
      return;
    }
    guardFollowupGeneration = undefined;

    const result = await runGuard();
    if (generation !== sessionGeneration || result.code !== 2) return;

    guardFollowupGeneration = generation;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      if (guardFollowupGeneration === generation) guardFollowupGeneration = undefined;
    }
  };

  if (primaryHarness === "omp") {
    // OMP settles the main loop with agent_end; Pi uses agent_settled.
    const onCrossHarnessEvent = pi.on as unknown as CrossHarnessOn;
    onCrossHarnessEvent.call(pi, "agent_end", runSettledGuard);
  } else {
    pi.on("agent_settled", runSettledGuard);
  }

  markLoaded();
}


// The LOADED ENTRYPOINT selects the protocol, never an environment marker: a
// marker is inheritable, so a Pi primary started under a retained OMPCODE would
// otherwise bind the guard to agent_end, which Pi never emits, and every turn
// would end blind. Pi auto-loads this file and gets Pi; only .omp/extensions/
// passes "omp".
export default function registerPiFamilyPrimaryTurnendGuard(
  pi: ExtensionAPI,
  harness: PrimaryHarness = "pi",
): void {
  selectPrimaryHarness(harness);
  registerPrimaryTurnendGuard(pi);
}
