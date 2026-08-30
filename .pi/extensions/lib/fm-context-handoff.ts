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
    let outputExceeded = false;
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let child: ReturnType<typeof spawn> | undefined;
    const finish = (result: HandoffResult): void => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      resolve(result);
    };
    try {
      child = spawn(`${root}/bin/fm-context-handoff.py`, args, {
        env: { ...process.env, FM_HOME: fmHome },
        stdio: ["pipe", "pipe", "ignore"],
      });
    } catch {
      finish({ status: "adapter-failed" });
      return;
    }
    if (!child) {
      finish({ status: "adapter-failed" });
      return;
    }
    const runningChild = child;
    if (!runningChild.stdout || !runningChild.stdin) {
      runningChild.kill("SIGKILL");
      finish({ status: "adapter-failed" });
      return;
    }
    const childStdout = runningChild.stdout;
    const childStdin = runningChild.stdin;
    const testTimeout = Number(process.env.FM_HANDOFF_TEST_ADAPTER_TIMEOUT_MS);
    const adapterTimeoutMs = process.env.FM_HANDOFF_TESTING === "1" && Number.isFinite(testTimeout) && testTimeout >= 50 && testTimeout <= 5000
      ? testTimeout
      : 10_000;
    timeout = setTimeout(() => {
      runningChild.kill("SIGKILL");
      finish({ status: "adapter-failed" });
    }, adapterTimeoutMs);
    childStdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      if (stdout.length + text.length > 64 * 1024) {
        outputExceeded = true;
        runningChild.kill("SIGKILL");
        finish({ status: "adapter-failed" });
        return;
      }
      stdout += text;
    });
    childStdin.on("error", () => {
      runningChild.kill("SIGKILL");
      finish({ status: "adapter-failed" });
    });
    runningChild.on("error", () => finish({ status: "adapter-failed" }));
    runningChild.on("close", (code) => {
      if (code !== 0 || outputExceeded) {
        finish({ status: "adapter-failed" });
        return;
      }
      try {
        const parsed = JSON.parse(stdout || "{}") as HandoffResult;
        if (!parsed || typeof parsed !== "object" || typeof parsed.status !== "string") {
          finish({ status: "adapter-failed" });
          return;
        }
        finish(parsed);
      } catch {
        finish({ status: "adapter-failed" });
      }
    });
    childStdin.end(JSON.stringify(input));
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
    if (result.status === "adapter-failed") {
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
