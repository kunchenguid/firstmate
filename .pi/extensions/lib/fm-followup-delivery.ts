// Deferred operational follow-up delivery for the tracked Firstmate Pi extensions.
//
// Why the deferral exists (stated once here; both Pi extensions point at this file):
// Pi's AgentSession clears its agent-run flag BEFORE it emits agent_settled
// (core/agent-session.js `_emitAgentSettled`), and `prompt()` only takes the
// follow-up queueing branch while that flag is still set. A `sendUserMessage`
// issued while an agent_settled handler is open therefore skips queueing entirely
// and starts a whole new agent run inside the parent run's still-open
// `_runAgentPrompt` frame. Verified against pi 0.83.0; on a firstmate primary that
// re-entrant run wedged every turn on "Working..." with no error output.
//
// Two things have to hold for a send to be safe:
//   1. it must not run inside the settled handler's own stack, and
//   2. it must not run while any Firstmate settled handler is still awaiting -
//      the turn-end guard awaits a helper spawn for hundreds of milliseconds, and
//      a watcher close landing in that window re-enters exactly the same way.
//
// `withSettledFrame` marks (2) and a macrotask hop clears (1), so every delivery
// lands as a fresh top-level turn. Both extensions import this one module, so the
// frame count is shared across them in the extension host process.
//
// Scope of the guarantee: this covers Firstmate's own settled handlers, which are
// the only ones that hold the frame open on a firstmate primary. A settled handler
// from some other extension that awaits for a long time would re-open the same
// window, and nothing in an extension can observe that.

/** The narrow slice of Pi's ExtensionAPI this module needs. */
export type FollowUpSender = {
  sendUserMessage(
    content: string,
    options?: { deliverAs?: "steer" | "followUp" },
  ): unknown;
};

let openSettledFrames = 0;
let heldDeliveries: Array<() => void> = [];

/**
 * Run an agent_settled handler body inside a tracked frame. Deliveries requested
 * while any frame is open are held until every frame has closed.
 */
export async function withSettledFrame<T>(body: () => Promise<T>): Promise<T> {
  openSettledFrames += 1;
  try {
    return await body();
  } finally {
    openSettledFrames -= 1;
    if (openSettledFrames === 0) releaseHeldDeliveries();
  }
}

/**
 * Send `content` as a follow-up user message from outside every open settled
 * frame. Resolves once Pi has accepted the send, and rejects if the send fails so
 * the caller can reset any one-shot latch it holds.
 */
export function deliverOperationalFollowUp(
  pi: FollowUpSender,
  content: string,
): Promise<void> {
  return new Promise<void>((resolveDelivery, rejectDelivery) => {
    const send = (): void => {
      try {
        void Promise.resolve(pi.sendUserMessage(content, { deliverAs: "followUp" })).then(
          () => resolveDelivery(),
          rejectDelivery,
        );
      } catch (error) {
        rejectDelivery(error);
      }
    };
    if (openSettledFrames > 0) {
      heldDeliveries.push(send);
      return;
    }
    setTimeout(send, 0);
  });
}

function releaseHeldDeliveries(): void {
  if (heldDeliveries.length === 0) return;
  const released = heldDeliveries;
  heldDeliveries = [];
  setTimeout(() => {
    for (const send of released) send();
  }, 0);
}
