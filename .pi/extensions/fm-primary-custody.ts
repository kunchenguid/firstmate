// Firstmate Pi-on-Herdr exact-session custody attestor.
//
// The shell owner is bin/fm-primary-pi.sh. This extension is deliberately a
// thin Pi-side witness: when that wrapper supplies FM_PRIMARY_PI_TOKEN, every
// session_start is synchronously reported through the script's `attest`
// executable interface. Recovery startup carries exact expected session
// identity and is not exposed as successful until this attestation is `ok`.
// Bare Pi launches without the wrapper stay inert and gain no recovery claim.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const owner = `${root}/bin/fm-primary-pi.sh`;

function processStart(): string {
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim().replace(/\s+/g, " ");
}

export default function (pi: ExtensionAPI) {
  const token = process.env.FM_PRIMARY_PI_TOKEN ?? "";
  if (!token) return;

  let inputAllowed = false;
  let attesting = false;

  function attest(reason: string, ctx: ExtensionContext): boolean {
    if (attesting) return inputAllowed;
    attesting = true;
    try {
      const sessionFile = ctx.sessionManager.getSessionFile() ?? "";
      const sessionId = ctx.sessionManager.getSessionId();
      const sessionDir = ctx.sessionManager.getSessionDir();
      const cwd = ctx.sessionManager.getCwd();
      const recovery = process.env.FM_PRIMARY_PI_RECOVERY === "1";
      const args = [
        "attest",
        "--token", token,
        "--actual-id", sessionId,
        "--session-file", sessionFile,
        "--session-dir", sessionDir,
        "--cwd", cwd,
        "--pi-pid", String(process.pid),
        "--pi-start", processStart(),
        "--reason", reason || "event",
      ];
      if (recovery) args.push("--recovery");
      const result = spawnSync(owner, args, {
        cwd: root,
        env: process.env,
        encoding: "utf8",
      });
      const verdict = result.status === 0 ? result.stdout.trim() : "failed";
      inputAllowed = verdict === "ok" || (!recovery && verdict === "pending");
      if (inputAllowed && recovery) {
        // Pi reloads extension factories on /new, /resume, and /fork. Clear the
        // one-time recovery expectation process-wide after the exact startup
        // attests so later deliberate same-process session changes can publish
        // their own new custody identity.
        process.env.FM_PRIMARY_PI_RECOVERY = "0";
      }
      return inputAllowed;
    } finally {
      attesting = false;
    }
  }

  pi.on("session_start", async (event, ctx) => {
    if (attest(String(event.reason ?? "startup"), ctx)) return;
    ctx.ui.notify("Firstmate exact-session custody attestation failed; Pi is shutting down without accepting input.", "error");
    ctx.shutdown();
  });

  pi.on("message_end", async (event, ctx) => {
    if (event.message.role !== "assistant" || attest("message", ctx)) return;
    ctx.ui.notify("Firstmate session custody lost integrity; Pi is shutting down.", "error");
    ctx.shutdown();
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (attest("settled", ctx)) return;
    ctx.ui.notify("Firstmate session custody lost integrity; Pi is shutting down.", "error");
    ctx.shutdown();
  });

  pi.on("input", async (_event, ctx) => {
    if (inputAllowed) return { action: "continue" as const };
    ctx.ui.notify("Firstmate custody is not attested; input was not accepted.", "error");
    return { action: "handled" as const };
  });
}
