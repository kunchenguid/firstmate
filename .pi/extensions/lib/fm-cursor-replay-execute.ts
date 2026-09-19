// Complete a Cursor SDK replay tool that never returns a recorded result.
// Replay ids are display-only (pi-cursor-sdk native tool replay): the recorded
// card is stored before Pi calls execute. A live Shell belongs on the Cursor
// run, not this Pi execute. Waiting minutes copies the SDK live-run idle
// dispose and does not fix a missing recorded result. If execute is still
// pending after the recorded-result path, abort the SDK waiter, fail this tool
// as missing completion, and leave the Pi turn running.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

export const CURSOR_REPLAY_INCOMPLETE_ERROR =
  "Cursor tool did not complete\nmissing completion";

export function isCursorReplayToolCallId(toolCallId: string): boolean {
  return toolCallId.startsWith("cursor-replay-");
}

export function cursorReplayInputIsIncomplete(params: unknown): boolean {
  if (typeof params !== "object" || params === null) return false;
  return (params as { incomplete?: unknown }).incomplete === true;
}

export type CursorReplayToolExecute = (
  toolCallId: string,
  params: unknown,
  signal: AbortSignal | undefined,
  onUpdate: ((state: unknown) => void) | undefined,
  ctx: unknown,
) => unknown | Promise<unknown>;

type ReplayExecuteOutcome =
  | { status: "fulfilled"; value: unknown }
  | { status: "rejected"; error: unknown }
  | { status: "pending" };

type CursorLiveRunDrainModule = {
  getActiveCursorLiveRunForCurrentScope?: () => unknown;
  cursorLiveRuns?: { release?: (run: unknown) => Promise<unknown> };
};

function cursorLiveRunDrainHref(): string | undefined {
  const drainTs = `${homedir()}/.pi/agent/npm/node_modules/pi-cursor-sdk/src/cursor-provider-live-run-drain.ts`;
  if (!existsSync(drainTs)) return undefined;
  // SDK internals import this file as `.js`. A `.ts` file URL is a second
  // module, so getActiveCursorLiveRunForCurrentScope() would miss the live run.
  return pathToFileURL(drainTs).href.replace(/\.ts$/, ".js");
}

async function releaseActiveCursorLiveRun(): Promise<void> {
  const href = cursorLiveRunDrainHref();
  if (!href) return;
  try {
    const mod = (await import(href)) as CursorLiveRunDrainModule;
    const run = mod.getActiveCursorLiveRunForCurrentScope?.();
    if (!run || typeof mod.cursorLiveRuns?.release !== "function") return;
    await mod.cursorLiveRuns.release(run);
  } catch {
    // Missing or unloadable SDK leaves the waiter; Esc still aborts the turn.
  }
}

function linkReplayAbortSignal(
  parent: AbortSignal | undefined,
): { signal: AbortSignal; abort: () => void } {
  const controller = new AbortController();
  if (parent) {
    if (parent.aborted) controller.abort();
    else parent.addEventListener("abort", () => controller.abort(), { once: true });
  }
  return {
    signal: controller.signal,
    abort: () => {
      if (!controller.signal.aborted) controller.abort();
    },
  };
}

export function wrapCursorReplayToolExecute(
  execute: CursorReplayToolExecute,
): CursorReplayToolExecute {
  return async function wrappedCursorReplayExecute(
    this: unknown,
    ...args: Parameters<CursorReplayToolExecute>
  ) {
    const [toolCallId, params, parentSignal, onUpdate, ctx] = args;
    const replayId = String(toolCallId ?? "");
    if (!isCursorReplayToolCallId(replayId)) {
      return execute.apply(this, args);
    }
    if (cursorReplayInputIsIncomplete(params)) {
      throw new Error(CURSOR_REPLAY_INCOMPLETE_ERROR);
    }

    const replayAbort = linkReplayAbortSignal(parentSignal);
    const run = Promise.resolve(
      execute.apply(this, [toolCallId, params, replayAbort.signal, onUpdate, ctx]),
    );
    const outcome = await Promise.race([
      run.then(
        (value): ReplayExecuteOutcome => ({ status: "fulfilled", value }),
        (error: unknown): ReplayExecuteOutcome => ({ status: "rejected", error }),
      ),
      Promise.resolve().then((): ReplayExecuteOutcome => ({ status: "pending" })),
    ]);
    if (outcome.status === "pending") {
      replayAbort.abort();
      // Pi execute is done; the boat stays until Cursor's live-run wait ends.
      // Release that wait so agent_settled can fire. Missing SDK is a no-op.
      await releaseActiveCursorLiveRun();
      throw new Error(CURSOR_REPLAY_INCOMPLETE_ERROR);
    }
    if (outcome.status === "rejected") {
      throw outcome.error;
    }
    return outcome.value;
  };
}
