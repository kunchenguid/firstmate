import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { positiveInteger } from "./lib/fm-extension-env.ts";
import { deliverOperationalFollowUp, withSettledFrame } from "./lib/fm-followup-delivery.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;
let consecutiveGuardBlocks = 0;
let guardCeilingWarned = false;

type LockOwnership = "owned" | "missing" | "other";

type SpawnOutcome = { code: number; stderr: string };

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
// Spawn ceilings. bin/fm-turnend-guard.sh and both PreToolUse checkers return in
// milliseconds, so these budgets only ever fire on a genuinely wedged helper. An
// unbounded spawn awaited inside a hook is how a stuck script wedges a whole turn
// or tool call, so a timed-out helper is killed and treated as "allow" - the same
// fail-open posture bin/fm-turnend-guard.sh documents in its own header.
const guardTimeoutMs = positiveInteger("FM_PI_TURNEND_GUARD_TIMEOUT_MS", 15000);
const checkTimeoutMs = positiveInteger("FM_PI_PRETOOL_CHECK_TIMEOUT_MS", 10000);
// Ceiling on consecutive guard follow-ups. bin/fm-turnend-guard.sh applies
// FM_CLAUDE_TURNEND_BLOCK_BUDGET only in --claude mode, so the Pi path would
// otherwise re-prompt every turn forever against an unrepairable watcher. Past
// this bound the guard degrades to one visible warning instead, and any healthy
// turn clears both the count and the warning for a future independent episode.
const blockBudget = positiveInteger("FM_PI_TURNEND_BLOCK_BUDGET", 3);

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

// Collect one helper spawn under a hard time budget. A spawn error or an expired
// budget resolves as exit 0 with no stderr, which every caller reads as "allow",
// so no helper can ever wedge the session by never exiting.
function collectSpawn(child: ChildProcess, timeoutMs: number): Promise<SpawnOutcome> {
  return new Promise((resolveResult) => {
    let stderr = "";
    let settled = false;
    const finish = (outcome: SpawnOutcome): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolveResult(outcome);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({ code: 0, stderr: "" });
    }, timeoutMs);
    timer.unref();
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("error", () => finish({ code: 0, stderr: "" }));
    child.on("close", (code) => finish({ code: code ?? 0, stderr }));
  });
}

function runGuard(): Promise<SpawnOutcome> {
  const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
    stdio: ["pipe", "ignore", "pipe"],
  });
  const outcome = collectSpawn(child, guardTimeoutMs);
  child.stdin.end('{"stop_hook_active":false}');
  return outcome;
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<SpawnOutcome> {
  const child = spawn(`${root}/bin/${script}`, ["--command", command], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  return collectSpawn(child, checkTimeoutMs);
}

function runPretoolCheck(command: string): Promise<SpawnOutcome> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<SpawnOutcome> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

// Non-blocking, visible transcript warning used once the guard's follow-up bound
// is spent. sendMessage without triggerTurn appends and renders without starting
// an agent run, so a persistently unrepairable watcher degrades to a warning the
// captain can see instead of an endless re-prompt.
function warnGuardCeiling(pi: ExtensionAPI, detail: string): void {
  if (guardCeilingWarned) return;
  guardCeilingWarned = true;
  try {
    pi.sendMessage({
      customType: "firstmate-turnend-guard-ceiling",
      content:
        `SUPERVISION IS STILL OFF after ${blockBudget} consecutive turn-end guard follow-ups.\n` +
        "Firstmate has stopped re-prompting so this session stays usable. Supervision stays DOWN, " +
        "and no work is being watched, until the watcher cycle is repaired.\n\n" +
        detail,
      display: true,
      details: { kind: "turn-end-guard-ceiling", consecutiveBlocks: blockBudget },
    });
  } catch {
  }
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

  // The whole handler runs inside a tracked settled frame: awaiting the guard
  // spawn here holds Pi's agent run frame open, and any follow-up delivered from
  // inside it - this one or a watcher wake from the sibling extension - would
  // start a nested agent run. lib/fm-followup-delivery.ts owns that contract.
  pi.on("agent_settled", () =>
    withSettledFrame(async () => {
      if (guardFollowupActive) {
        guardFollowupActive = false;
        return;
      }

      const result = await runGuard();
      if (result.code !== 2) {
        consecutiveGuardBlocks = 0;
        guardCeilingWarned = false;
        return;
      }

      if (consecutiveGuardBlocks >= blockBudget) {
        warnGuardCeiling(pi, result.stderr);
        return;
      }

      guardFollowupActive = true;
      let content = "";
      try {
        content = encodeFirstmateOperationalInput(
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
      } catch {
        guardFollowupActive = false;
        return;
      }
      consecutiveGuardBlocks += 1;
      void deliverOperationalFollowUp(pi, content).catch(() => {
        guardFollowupActive = false;
      });
    }),
  );

  markLoaded();
}
