// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "dead" | "other" | "malformed" | "unknown";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

let child: any = null;
let seq = 0;

function lockEnvironment() {
  return {
    ...process.env,
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
    FM_STATE_OVERRIDE: state,
  };
}

function lockOwnership(): LockOwnership {
  const result = spawnSync(lockScript, ["ownership"], { encoding: "utf8", env: lockEnvironment() });
  const ownership = String(result.stdout || "").trim();
  if (result.status !== 0) return "unknown";
  if (["owned", "missing", "dead", "other", "malformed", "unknown"].includes(ownership)) {
    return ownership as LockOwnership;
  }
  return "unknown";
}

function markLoaded(): void {
  const ownership = lockOwnership();
  if (ownership === "other" || ownership === "malformed" || ownership === "unknown") return;
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
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
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
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      { deliverAs: "followUp" },
    );
  }

  function startArm(): ArmResult {
    let ownership = lockOwnership();
    let acquisitionError = "";
    let attemptedAcquisition = false;
    if (ownership === "missing" || ownership === "dead") {
      attemptedAcquisition = true;
      const acquisition = spawnSync(lockScript, [], { encoding: "utf8", env: lockEnvironment() });
      acquisitionError = String(acquisition.stderr || "").trim().split(/\r?\n/)[0] || "";
      ownership = lockOwnership();
    }
    if (ownership === "other") {
      const message = attemptedAcquisition
        ? "watcher: lock ownership changed during resume - a verified live firstmate session now owns this home"
        : "watcher: read-only - a verified live firstmate session owns this home";
      return { ok: false, message };
    }
    if (ownership !== "owned") {
      const detail = acquisitionError ? ` (${acquisitionError})` : "";
      return { ok: false, message: `watcher: lock acquisition failed - session lock is ${ownership}${detail}` };
    }
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
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
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
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
        // Pi owns delivery errors; fail open so the extension never wedges the session.
      }
    });
    child.on("error", async (error: Error) => {
      child = null;
      try {
        await sendWake(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`);
      } catch {
        // Fail open.
      }
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", (_event, ctx) => {
    const result = startArm();
    if (!result.ok) ctx?.ui?.notify?.(result.message, "warning");
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
