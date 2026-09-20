import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const muse = { provider: "cliproxyapi", id: "muse-spark-1.3" };
const gemini = { provider: "antigravity", id: "gemini-3.8-flash" };
type GuardedAPI = ExtensionAPI & {
  setModelIfCurrent?: (model: NonNullable<Parameters<ExtensionAPI["setModel"]>[0]>, guard: {
    thinkingLevel?: "high"; isCurrent?: () => boolean; expectedSessionId: string; expectedProvider: string; expectedModelId: string; signal: AbortSignal;
  }) => Promise<boolean>;
};

// Owned by the primary watch extension: no supervision timer, provider registration, replay,
// queue acknowledgement, branch model change, or second session is introduced.
export function installTransportRecovery(pi: ExtensionAPI, configPath: string, ownsLock: () => boolean): void {
  let generation = 0;
  let controller = new AbortController();
  let used = false;
  let reports = 0;
  let run: { safe: boolean; attempts: number; failures: number; terminal: boolean; requestBytes?: number } | undefined;
  const invalidate = () => { generation++; controller.abort(); controller = new AbortController(); run = undefined; };
  const config = (): { mode?: unknown; exactGeminiIdentityVerified?: unknown } => {
    try {
      const value: unknown = JSON.parse(readFileSync(configPath, "utf8"));
      return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch { return {}; }
  };
  pi.on("session_start", () => { invalidate(); used = false; reports = 0; });
  pi.on("session_shutdown", invalidate);
  pi.on("input", () => { invalidate(); });
  pi.on("model_select", () => { invalidate(); });
  pi.on("before_agent_start", () => {
    invalidate();
    run = { safe: true, attempts: 0, failures: 0, terminal: false };
  });
  // Automatic retry starts another agent loop without before_agent_start.
  // Never reset the whole-run effect fence at agent_start or message_start.
  pi.on("tool_execution_start", () => { if (run) run.safe = false; });
  pi.on("message_update", () => { if (run) run.safe = false; });
  pi.on("message_end", (event) => {
    if (!run || event.message.role !== "assistant") return;
    const message = event.message;
    const failures = message.diagnostics?.filter((item) => item.type === "provider_transport_failure") ?? [];
    const details = failures.at(-1)?.details;
    if (failures.length) run.failures++;
    // A recovered WS error attached to a successful SSE response is not a
    // terminal transport failure. Auth/HTTP failures without a terminal marker
    // are unknown even when an earlier WS diagnostic survives on the message.
    run.terminal = message.stopReason === "error" && message.provider === muse.provider && message.model === muse.id &&
      details?.terminal === true && details.eventsEmitted === false && details.phase === "before_message_stream_start";
    if (!run.terminal || message.content.length !== 0 || failures.some((item) =>
      item.details?.eventsEmitted !== false || item.details?.phase !== "before_message_stream_start")) run.safe = false;
    if (run.terminal) run.attempts++;
    const bytes = details?.requestBytes;
    if (typeof bytes === "number" && Number.isSafeInteger(bytes) && bytes >= 0) run.requestBytes = bytes;
  });
  pi.on("agent_settled", async (_event, ctx) => {
    const observed = run;
    run = undefined; // Duplicate settlement cannot trigger another attempt.
    const policy = config();
    if (!observed || !ownsLock() || !["diagnostics", "muse-to-gemini"].includes(String(policy.mode))) return;
    const report = (result: string) => {
      if (reports++ >= 32) return;
      // Fixed schema only: never serialize diagnostics.error, body, prompt,
      // tool arguments, endpoint URLs, auth, or raw exception strings.
      pi.appendEntry("fm-transport-recovery", {
        version: 1, result, attempts: observed.attempts, requestBytes: observed.requestBytes,
        safe: observed.safe, source: "cliproxyapi/muse-spark-1.3", target: "antigravity/gemini-3.8-flash",
      });
    };
    if (!observed.failures) return;
    if (!observed.safe || !observed.terminal || ctx.signal?.aborted) { report("unsafe-run"); return; }
    if (observed.attempts < 2) { report("sustained-failure-threshold-not-met"); return; }
    if (policy.mode !== "muse-to-gemini") { report("diagnostics-only"); return; }
    if (used) { report("transition-budget-exhausted"); return; }
    if (ctx.model?.provider !== muse.provider || ctx.model.id !== muse.id || !ctx.isIdle() || ctx.hasPendingMessages()) {
      report("session-changed-or-busy"); return;
    }
    if (policy.exactGeminiIdentityVerified !== true) { report("gemini-identity-unverified"); return; }
    const guarded = pi as GuardedAPI;
    if (typeof guarded.setModelIfCurrent !== "function") { report("guarded-model-api-unavailable"); return; }
    const target = ctx.modelRegistry.find(gemini.provider, gemini.id);
    if (!target) { report("target-unavailable"); return; }
    if (ctx.scopedModels.length && !ctx.scopedModels.some((item) => item.model.provider === gemini.provider && item.model.id === gemini.id)) {
      report("target-outside-model-scope"); return;
    }
    const owner = generation;
    const sessionId = ctx.sessionManager.getSessionId();
    const switchController = controller;
    const signal = switchController.signal;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    let timedOut = false;
    used = true; // One auth/switch attempt per session, including failed auth.
    try {
      const transition = guarded.setModelIfCurrent(target, {
        expectedSessionId: sessionId, expectedProvider: muse.provider,
        expectedModelId: muse.id, signal, thinkingLevel: "high",
        isCurrent: () => owner === generation && ownsLock() && config().mode === "muse-to-gemini" && config().exactGeminiIdentityVerified === true,
      });
      const switched = await Promise.race([transition, new Promise<false>((resolve) => {
        deadline = setTimeout(() => {
          timedOut = true;
          switchController.abort();
          resolve(false);
        }, 10_000);
      })]);
      // A successful model_select intentionally invalidates the generation.
      // No follow-up or replay is sent: the next stock wake uses the new model.
      if (switched) {
        if (ctx.sessionManager.getSessionId() === sessionId && ctx.model?.provider === gemini.provider && ctx.model.id === gemini.id && ownsLock()) report("switched-for-next-stock-wake");
        return;
      }
      if (owner === generation) report(timedOut ? "switch-timeout" : "guard-rejected-or-no-auth");
    } catch {
      if (owner === generation) report("switch-failed");
    } finally {
      clearTimeout(deadline);
    }
  });
}
