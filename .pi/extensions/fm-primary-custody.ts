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

type Verdict = "ok" | "pending" | "failed";

function processStart(): string {
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim().replace(/\s+/g, " ");
}

export default function (pi: ExtensionAPI) {
  const token = process.env.FM_PRIMARY_PI_TOKEN ?? "";
  if (!token) return;

  let inputAllowed = false;
  let persistencePending = false;
  let attesting = false;

  function attest(reason: string, ctx: ExtensionContext): Verdict {
    if (attesting) return "failed";
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
      const output = result.status === 0 ? result.stdout.trim() : "failed";
      const verdict: Verdict = output === "ok" || output === "pending" ? output : "failed";
      if (verdict === "ok" && recovery) {
        // Pi reloads extension factories on /new, /resume, and /fork. Clear the
        // one-time recovery expectation process-wide after the exact startup
        // attests so later deliberate same-process session changes can publish
        // their own new custody identity.
        process.env.FM_PRIMARY_PI_RECOVERY = "0";
      }
      return verdict;
    } finally {
      attesting = false;
    }
  }

  pi.on("session_start", async (event, ctx) => {
    const recovery = process.env.FM_PRIMARY_PI_RECOVERY === "1";
    const verdict = attest(String(event.reason ?? "startup"), ctx);
    inputAllowed = verdict === "ok" || (!recovery && verdict === "pending");
    persistencePending = !recovery && verdict === "pending";
    if (inputAllowed) return;
    ctx.ui.notify("Firstmate exact-session custody attestation failed; Pi is shutting down without accepting input.", "error");
    ctx.shutdown();
  });

  // A brand-new Pi session can have an intended canonical file path before the
  // JSONL exists. Finalize that one pending record after Pi's first settled run.
  // Established sessions do no per-message or per-settlement subprocess work.
  pi.on("agent_settled", async (_event, ctx) => {
    if (!persistencePending) return;
    const verdict = attest("persisted", ctx);
    persistencePending = verdict === "pending";
    if (verdict === "ok" || verdict === "pending") return;
    inputAllowed = false;
    ctx.ui.notify("Firstmate session custody failed final persistence attestation; Pi is shutting down.", "error");
    ctx.shutdown();
  });

  pi.on("input", async (_event, ctx) => {
    if (inputAllowed) return { action: "continue" as const };
    ctx.ui.notify("Firstmate custody is not attested; input was not accepted.", "error");
    return { action: "handled" as const };
  });
}
