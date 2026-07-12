// Firstmate primary turn-end guard + PreToolUse seatbelt for OMP (Oh My Pi).
//
// The .omp/extensions/ twin of .pi/extensions/fm-primary-turnend-guard.ts (kept in
// lockstep with the Pi guard). OMP is a Pi fork with a Pi-compatible extension API;
// two things are adapted:
//   - OMP has no `agent_settled` event (Pi 0.80.5-only), so the guard listens for
//     `turn_end` - OMP's turn-boundary event, and the pre-#397 Pi guard event. The
//     guardFollowupActive one-shot skip gives the same "guard once per run" behavior.
//   - Reads event.input by narrowing (not an inline cast) and uses
//     Promise.withResolvers, per this repo's TS lint.
// OMP auto-loads `.omp/extensions/`, never `.pi/`, so this is a separate copy.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

let guardFollowupActive = false;

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
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<{ code: number; stderr: string }>();
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
  return promise;
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra omp -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and a
// `tool_call` handler returning { block: true } prevents the bash command from
// running (OMP ToolCallEvent contract, docs/extensions.md). Each owner script
// owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  const { promise, resolve: resolveResult } = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = spawn(`${root}/bin/${script}`, ["--command", command], {
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

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", () => {
    markLoaded();
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return {};
    // Narrow event.input to read `command` without an unchecked cast:
    // CustomToolCallEvent.toolName is `string`, so a toolName check does not
    // discriminate the input union to BashToolInput.
    const input: unknown = event.input;
    const command =
      input && typeof input === "object" && "command" in input && typeof input.command === "string"
        ? input.command
        : "";
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runChecker("fm-arm-pretool-check.sh", command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("turn_end", async () => {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      await pi.sendUserMessage(
        "TURN WOULD END BLIND - supervision is off. " +
          "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
          result.stderr,
        { deliverAs: "followUp" },
      );
    } catch {
      guardFollowupActive = false;
    }
  });

  markLoaded();
}
