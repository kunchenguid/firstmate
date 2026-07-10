// Firstmate primary watcher bridge for OMP (Oh My Pi).
//
// The .omp/extensions/ twin of .pi/extensions/fm-primary-pi-watch.ts (kept in
// lockstep with the Pi watcher). OMP is a Pi fork with a Pi-compatible extension
// API; the OMP adaptations are the import specifier, the marker filename, "OMP"
// wording, a `pi.zod` (not typebox) tool schema, and a typed ChildProcess (this
// repo's TS lint disallows `any`). OMP auto-loads `.omp/extensions/`, never `.pi/`.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

let child: ChildProcess | null = null;
let seq = 0;

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

function sessionOwnsLock(): boolean {
  return lockOwnership() === "owned";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - OMP extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  function stopArm(): void {
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string) {
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume OMP supervision.`,
      { deliverAs: "followUp" },
    );
  }

  function startArm(): ArmResult {
    if (!sessionOwnsLock()) return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - OMP extension already has an arm child" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("close", async (code: number | null) => {
      child = null;
      const reason = actionableLine(`${stdout}\n${stderr}`);
      const failure = reason ? "" : failureLine(stdout, stderr, code);
      if (!reason && !failure) return;
      try {
        await sendWake(reason || failure);
      } catch {
        // OMP owns delivery errors; fail open so the extension never wedges the session.
      }
    });
    child.on("error", async (error: Error) => {
      child = null;
      try {
        await sendWake(`watcher: FAILED - OMP extension arm child ${id} failed: ${error.message}`);
      } catch {
        // Fail open.
      }
    });
    return { ok: true, message: `watcher: started OMP extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the OMP extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  // The command above is the primary arm path. The tool mirrors it for tool-driven
  // arming. OMP's ToolDefinition has no promptSnippet/promptGuidelines fields
  // (Pi 0.80.5-only), so they are omitted, and the schema uses pi.zod (OMP-canonical)
  // rather than Pi's typebox Type.Object({}). Guarded so an OMP-specific schema or
  // registration difference can never break the watcher extension load.
  try {
    pi.registerTool?.({
      name: "fm_watch_arm_omp",
      label: "Arm firstmate watcher",
      description: "Arm OMP watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
      parameters: pi.zod.object({}),
      execute: async () => {
        const result = startArm();
        return {
          content: [{ type: "text", text: result.message }],
          details: result,
        };
      },
    });
  } catch {
    // Optional tool; the /fm-watch-arm-omp command remains available.
  }

  markLoaded();
}
