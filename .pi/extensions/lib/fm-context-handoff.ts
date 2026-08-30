import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type SealBinding = {
  record_id: string;
  envelope_sha256: string;
  trigger: "manual" | "threshold" | "overflow";
};

type HandoffResult = {
  status?: string;
  had_candidates?: boolean;
  record_id?: string;
  envelope_sha256?: string;
};

type SessionContext = {
  sessionManager?: {
    getSessionId?: () => unknown;
  };
};

function sessionId(ctx: SessionContext): string {
  try {
    return String(ctx.sessionManager?.getSessionId?.() ?? "");
  } catch {
    return "";
  }
}

function runHandoff(
  root: string,
  fmHome: string,
  args: string[],
  input: Record<string, unknown>,
): Promise<HandoffResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let settled = false;
    const finish = (result: HandoffResult): void => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    let child;
    try {
      child = spawn("python3", [`${root}/bin/fm-context-handoff.py`, ...args], {
        env: { ...process.env, FM_HOME: fmHome },
        stdio: ["pipe", "pipe", "ignore"],
      });
    } catch {
      finish({ status: "adapter-failed" });
      return;
    }
    child.stdout.on("data", (chunk: Buffer) => {
      if (stdout.length <= 64 * 1024) stdout += chunk.toString("utf8");
    });
    child.on("error", () => finish({ status: "adapter-failed" }));
    child.on("close", () => {
      try {
        const parsed = JSON.parse(stdout || "{}") as HandoffResult;
        finish(parsed);
      } catch {
        finish({ status: "adapter-failed" });
      }
    });
    child.stdin.end(JSON.stringify(input));
  });
}

export function registerContextHandoff(
  pi: ExtensionAPI,
  root: string,
  fmHome: string,
): void {
  let pendingSeal: SealBinding | null = null;

  pi.on("session_before_compact", async (event, ctx) => {
    const result = await runHandoff(
      root,
      fmHome,
      ["seal", "--source-harness", "pi", "--trigger", event.reason],
      { session_id: sessionId(ctx) },
    );
    if (
      (result.status === "sealed" || result.status === "already-sealed") &&
      typeof result.record_id === "string" &&
      typeof result.envelope_sha256 === "string"
    ) {
      pendingSeal = {
        record_id: result.record_id,
        envelope_sha256: result.envelope_sha256,
        trigger: event.reason,
      };
      return;
    }
    if (result.status === "seal-failed" && result.had_candidates === true) {
      return { cancel: true };
    }
  });

  pi.on("session_compact", async (event) => {
    const binding = pendingSeal;
    pendingSeal = null;
    await runHandoff(
      root,
      fmHome,
      ["compaction-outcome", "success"],
      binding
        ? { ...binding, reason: "pi-session-compact-succeeded" }
        : { trigger: event.reason, reason: "pi-session-compact-succeeded-without-seal-binding" },
    );
  });

  pi.on("session_compact_failed", async (event) => {
    const binding = pendingSeal;
    pendingSeal = null;
    await runHandoff(
      root,
      fmHome,
      ["compaction-outcome", "failure"],
      binding
        ? { ...binding, reason: "pi-session-compact-failed" }
        : { trigger: event.reason, reason: "pi-session-compact-failed-without-seal-binding" },
    );
  });
}
