import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type RecordBinding = {
  record_id: string;
  envelope_sha256: string;
};

type SealBinding = {
  bindings: RecordBinding[];
  trigger: "manual" | "threshold" | "overflow";
  terminal?: "success" | "failure";
  terminalReason?: string;
};

type HandoffResult = {
  status?: string;
  had_candidates?: boolean;
  record_id?: string;
  envelope_sha256?: string;
  bindings?: RecordBinding[];
  record_ids?: string[];
  delivery?: string;
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

function exactBindings(result: HandoffResult): RecordBinding[] | null {
  if (!Array.isArray(result.bindings) || result.bindings.length < 1 || result.bindings.length > 32) return null;
  const seen = new Set<string>();
  const bindings: RecordBinding[] = [];
  for (const item of result.bindings) {
    if (!item || typeof item.record_id !== "string" || !/^handoff-[0-9a-f]{48}$/u.test(item.record_id)
      || typeof item.envelope_sha256 !== "string" || !/^[0-9a-f]{64}$/u.test(item.envelope_sha256)
      || seen.has(item.record_id)) return null;
    seen.add(item.record_id);
    bindings.push({ record_id: item.record_id, envelope_sha256: item.envelope_sha256 });
  }
  return bindings;
}

function exactSealResult(result: HandoffResult): RecordBinding[] | null {
  const bindings = exactBindings(result);
  if (!bindings) return null;
  const keys = Object.keys(result).sort();
  const expected = bindings.length === 1
    ? ["bindings", "envelope_sha256", "record_id", "status"]
    : ["bindings", "status"];
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) return null;
  if (bindings.length === 1 && (result.record_id !== bindings[0].record_id || result.envelope_sha256 !== bindings[0].envelope_sha256)) return null;
  return bindings;
}

function exactNoopResult(result: HandoffResult): boolean {
  return (result.status === "empty" || result.status === "disabled") && Object.keys(result).length === 1;
}

function exactOutcomeResult(result: HandoffResult, binding: SealBinding): boolean {
  const expectedStatus = binding.terminal === "success" ? "compaction-succeeded" : "compaction-failed";
  const expectedIds = binding.bindings.map((item) => item.record_id).sort();
  const expectedKeys = binding.terminal === "success" ? "delivery\0record_ids\0status" : "record_ids\0status";
  return result.status === expectedStatus
    && Object.keys(result).sort().join("\0") === expectedKeys
    && (binding.terminal !== "success" || ["disabled", "nothing-pending", "pending", "notified"].includes(result.delivery ?? ""))
    && Array.isArray(result.record_ids)
    && result.record_ids.length === expectedIds.length
    && result.record_ids.every((recordId, index) => recordId === expectedIds[index]);
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
    let adapterFailed = false;
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
        detached: process.platform !== "win32",
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
    const terminateAdapter = (): void => {
      adapterFailed = true;
      try {
        if (process.platform !== "win32" && runningChild.pid) process.kill(-runningChild.pid, "SIGKILL");
        else runningChild.kill("SIGKILL");
      } catch {
        try {
          runningChild.kill("SIGKILL");
        } catch {
          finish({ status: "adapter-failed" });
        }
      }
    };
    if (!runningChild.stdout || !runningChild.stdin) {
      terminateAdapter();
      runningChild.once("close", () => finish({ status: "adapter-failed" }));
      return;
    }
    const childStdout = runningChild.stdout;
    const childStdin = runningChild.stdin;
    const testTimeout = Number(process.env.FM_HANDOFF_TEST_ADAPTER_TIMEOUT_MS);
    const adapterTimeoutMs = process.env.FM_HANDOFF_TESTING === "1" && Number.isFinite(testTimeout) && testTimeout >= 50 && testTimeout <= 5000
      ? testTimeout
      : 10_000;
    timeout = setTimeout(() => {
      terminateAdapter();
    }, adapterTimeoutMs);
    childStdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      if (stdout.length + text.length > 64 * 1024) {
        outputExceeded = true;
        terminateAdapter();
        return;
      }
      stdout += text;
    });
    childStdin.on("error", () => {
      terminateAdapter();
    });
    runningChild.on("error", () => finish({ status: "adapter-failed" }));
    runningChild.on("close", (code) => {
      if (code !== 0 || outputExceeded || adapterFailed) {
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

  const persistPendingOutcome = async (): Promise<boolean> => {
    const binding = pendingSeal;
    if (!binding?.terminal || !binding.terminalReason) return false;
    const result = await runHandoff(
      root,
      fmHome,
      ["compaction-outcome", binding.terminal],
      {
        bindings: binding.bindings,
        trigger: binding.trigger,
        reason: binding.terminalReason,
      },
    );
    if (!exactOutcomeResult(result, binding)) return false;
    pendingSeal = null;
    return true;
  };

  pi.on("session_before_compact", async (event, ctx) => {
    if (pendingSeal && !(await persistPendingOutcome())) return { cancel: true };
    const result = await runHandoff(
      root,
      fmHome,
      ["seal", "--source-harness", "pi", "--trigger", event.reason],
      { session_id: sessionId(ctx) },
    );
    const bindings = exactSealResult(result);
    if ((result.status === "sealed" || result.status === "already-sealed") && bindings) {
      pendingSeal = {
        bindings,
        trigger: event.reason,
      };
      return;
    }
    if (exactNoopResult(result)) return;
    return { cancel: true };
  });

  pi.on("session_compact", async (event) => {
    const binding = pendingSeal;
    if (binding) {
      binding.terminal = "success";
      binding.terminalReason = "pi-session-compact-succeeded";
      await persistPendingOutcome();
      return;
    }
    await runHandoff(root, fmHome, ["compaction-outcome", "success"], {
      trigger: event.reason,
      reason: "pi-session-compact-succeeded-without-seal-binding",
    });
  });

  pi.on("session_compact_failed", async (event) => {
    const binding = pendingSeal;
    if (binding) {
      binding.terminal = "failure";
      binding.terminalReason = "pi-session-compact-failed";
      await persistPendingOutcome();
      return;
    }
    await runHandoff(root, fmHome, ["compaction-outcome", "failure"], {
      trigger: event.reason,
      reason: "pi-session-compact-failed-without-seal-binding",
    });
  });
}
