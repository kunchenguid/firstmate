import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

let guardContinueActive = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
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

type ScriptResult = { code: number; stderr: string };

function runGuard(): Promise<ScriptResult> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<ScriptResult>();
  const child = spawn(`${root}/bin/fm-turnend-guard.sh`, ["--omp"], {
    stdio: ["pipe", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.on("error", () => resolveResult({ code: 0, stderr: "" }));
  child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  child.stdin.end('{"stop_hook_active":false}');
  return promise;
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra omp -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-26 against omp 17.1.3:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, flag: string, value: string): Promise<ScriptResult> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<ScriptResult>();
  const child = spawn(`${root}/bin/${script}`, [flag, value], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.on("error", () => resolveResult({ code: 0, stderr: "" }));
  child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  return promise;
}

function bashCommandOf(input: unknown): string {
  if (input && typeof input === "object" && "command" in input) {
    return String(input.command ?? "");
  }
  return "";
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", (event) => {
    // omp's session_start carries no reason in print mode (verified 2026-07-26
    // on 17.1.3); an absent reason is treated as nudge-worthy because the
    // wrapper itself stays silent unless this is a primary checkout that has
    // not run session start yet.
    const reason =
      event && typeof event === "object" && "reason" in event ? String(event.reason ?? "") : "";
    const nudge = ["", "startup", "new", "resume"].includes(reason) ? runSessionstartNudge() : "";
    markLoaded();
    if (!nudge) return;
    try {
      pi.sendMessage({ customType: "firstmate-sessionstart-nudge", content: nudge, display: false });
    } catch {
    }
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call") return {};
    if (event.toolName !== "bash") {
      // Delegation guard (bin/fm-subagent-pretool-check.sh, docs/subagent-guard.md):
      // every non-bash tool name routes through the shape classifier, so an omp
      // primary cannot launch untracked work through the built-in task tool.
      // The checker owns primary scope, fail-open, and the FM_ALLOW_SUBAGENT
      // escape hatch; this extension is only the transport.
      const name = String(event.toolName ?? "");
      if (!name) return {};
      const sub = await runChecker("fm-subagent-pretool-check.sh", "--tool", name);
      if (sub.code !== 2) return {};
      return { block: true, reason: sub.stderr.trim() || "denied by the delegation PreToolUse guard" };
    }
    const command = bashCommandOf(event.input);
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", "--command", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runChecker("fm-arm-pretool-check.sh", "--command", command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  // omp's session_stop is a blockable main-session stop hook: returning
  // { continue: true, additionalContext } forces one continuation turn with
  // the reason fed back to the model (verified 2026-07-26 on omp 17.1.3).
  // The latch mirrors the claude stop_hook_active contract: the forced
  // continuation's own stop is allowed exactly once, so a model that still
  // has not re-armed supervision is not trapped in a continue loop (omp also
  // caps consecutive continuations at 8).
  pi.on("session_stop", async () => {
    if (guardContinueActive) {
      guardContinueActive = false;
      return {};
    }

    const result = await runGuard();
    if (result.code !== 2) return {};

    guardContinueActive = true;
    return {
      continue: true,
      additionalContext:
        "TURN WOULD END BLIND - supervision is off. " +
        "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
        result.stderr,
    };
  });

  markLoaded();
}
