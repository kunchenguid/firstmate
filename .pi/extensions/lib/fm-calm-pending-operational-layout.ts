// Verified against Pi 0.82.1, which renders the queued "Steering:"/"Follow-up:" rows, their
// leading spacer, and the dequeue hint from InteractiveMode.updatePendingMessagesDisplay,
// reading the queue through InteractiveMode.getAllQueuedMessages. That display is a separate
// path from the delivered-row path ./fm-calm-operational-user-layout.ts adapts, so a marked
// notification delivered while a tool call is active is visible here before it is ever a chat
// row. This adapter probes both methods and throws if either is missing; fm-calm.ts catches
// that and skips only this adapter with a diagnostic instead of blocking Calm or Pi.
//
// It filters only what that one display reads. Pi still builds every row, spacer, and hint
// itself, and the queue Pi delivers from and persists is untouched.
//
// Because a hidden row is a row the captain never saw, this adapter also owns the one seam
// that would otherwise hand hidden text back to the captain: Pi's
// InteractiveMode.restoreQueuedMessagesToEditor, reached both by Escape-to-abort during a
// run and by the Option+Up dequeue shortcut, clears the whole queue into the editor. Under
// Calm it restores only genuinely captain-authored messages and re-queues the
// marker-authenticated notifications in their original order, so they are still delivered
// on the next turn instead of appearing as raw text the captain is likely to discard.
//
// Retaining them across an abort means Pi settles the aborted run, sees a non-empty queue,
// and continues into a new turn to deliver them. That delivery is wanted, but a turn that
// restarts itself right after the captain stopped one must never be silent, so this adapter
// emits one short generic status line when that happens. The line carries no notification
// text, marker, kind, path, or identifier - it says only that supervision is continuing.
//
// Hiding a queued row is only ever safe while this restore stays adapted. If the queueing
// entry point the retention needs is missing at runtime, the adapter stops hiding queued
// rows for the rest of the process and hands the seam back to Pi, rather than leaving rows
// hidden behind a restore it cannot complete.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { isFirstmateOperationalPresentationText } from "./fm-operational-input.ts";

type QueuedMessages = {
  steering: string[];
  followUp: string[];
};
type CompactionQueuedMessage = {
  text: string;
  mode: "steer" | "followUp";
};
// The queue owners Pi's own clearAllQueues reads and empties.
type InteractiveModeQueueOwner = {
  session: {
    getSteeringMessages(): string[];
    getFollowUpMessages(): string[];
    _queueSteer?(text: string): unknown;
    _queueFollowUp?(text: string): unknown;
  };
  compactionQueuedMessages: CompactionQueuedMessage[];
};
type RestoreQueuedMessagesOptions = {
  abort?: boolean;
  currentText?: string;
};
// Pi's own transient chat status line, the same one it uses for "Restored N queued messages
// to editor". It is not a session entry, so it never reaches persistence, export, or share.
type CalmRestoreHost = {
  showStatus?(message: string): void;
};
type InteractiveModePendingPrototype = {
  getAllQueuedMessages(this: unknown): QueuedMessages;
  updatePendingMessagesDisplay(this: unknown): void;
  clearAllQueues(this: InteractiveModeQueueOwner): QueuedMessages;
  restoreQueuedMessagesToEditor(
    this: CalmRestoreHost,
    options?: RestoreQueuedMessagesOptions,
  ): number;
};
type CalmPendingOperationalLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// One short generic line, deliberately carrying nothing about what was retained: no
// notification text, no U+2063 marker, no FIRSTMATE_OP, no kind, no path, no identifier.
export const CALM_SUPERVISION_CONTINUES_NOTICE =
  "Firstmate supervision continues in a new turn.";

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_PENDING_OPERATIONAL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-pending-operational-layout:pi-0.82.1",
);

export function installCalmPendingOperationalLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmPendingOperationalLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const installed = registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isFirstmateOperationalPresentationText;
    return;
  }

  const patch: CalmPendingOperationalLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput: isFirstmateOperationalPresentationText,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePendingPrototype;
  const originalGetAllQueuedMessages = prototype.getAllQueuedMessages;
  if (typeof originalGetAllQueuedMessages !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.getAllQueuedMessages");
  }
  const originalUpdatePendingMessagesDisplay = prototype.updatePendingMessagesDisplay;
  if (typeof originalUpdatePendingMessagesDisplay !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.updatePendingMessagesDisplay");
  }
  // Hiding a queued row is only safe while the restore seam is adapted too, so both are
  // probed together and the adapter declines as a whole if either is gone.
  const originalClearAllQueues = prototype.clearAllQueues;
  if (typeof originalClearAllQueues !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.clearAllQueues");
  }
  const originalRestoreQueuedMessagesToEditor = prototype.restoreQueuedMessagesToEditor;
  if (typeof originalRestoreQueuedMessagesToEditor !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.restoreQueuedMessagesToEditor");
  }

  // Scoped to the synchronous pending-row rebuild below, so every other reader of the queue
  // still sees exactly what Pi queued.
  let renderingPendingRows = false;
  // Scoped to the synchronous restore below, so a future caller of clearAllQueues that is
  // not restoring to the editor keeps Pi's stock clearing semantics.
  let restoringQueuedMessages = false;
  // Counts what one restore actually retained, so the continuation notice is emitted only
  // when retained notifications are what makes Pi continue.
  let retainedByRestore = 0;
  // Latched for the rest of the process once retention proves impossible: a queued row may
  // never stay hidden behind a restore this adapter cannot complete.
  let queuedHidingUnavailable = false;
  const hidesQueuedOperational = (): boolean =>
    !queuedHidingUnavailable && patch.hidesOperationalInput();
  prototype.getAllQueuedMessages = function (this: unknown): QueuedMessages {
    const queued = originalGetAllQueuedMessages.call(this);
    if (!renderingPendingRows) return queued;
    const stays = (message: string): boolean => !patch.isOperationalInput(message);
    return {
      ...queued,
      steering: queued.steering.filter(stays),
      followUp: queued.followUp.filter(stays),
    };
  };
  prototype.updatePendingMessagesDisplay = function (this: unknown): void {
    if (!hidesQueuedOperational()) {
      originalUpdatePendingMessagesDisplay.call(this);
      return;
    }
    renderingPendingRows = true;
    try {
      // Pi skips the spacer and the dequeue hint when nothing is queued, so an all-marked
      // batch collapses to no rows at all rather than to an empty framed block.
      originalUpdatePendingMessagesDisplay.call(this);
    } finally {
      renderingPendingRows = false;
    }
  };
  prototype.clearAllQueues = function (this: InteractiveModeQueueOwner): QueuedMessages {
    if (!restoringQueuedMessages) return originalClearAllQueues.call(this);
    return clearQueuesRetainingOperational(this);
  };
  prototype.restoreQueuedMessagesToEditor = function (
    this: CalmRestoreHost,
    options?: RestoreQueuedMessagesOptions,
  ): number {
    if (!hidesQueuedOperational()) {
      return originalRestoreQueuedMessagesToEditor.call(this, options);
    }
    restoringQueuedMessages = true;
    retainedByRestore = 0;
    try {
      // Pi still builds the editor text, the status count, and the abort itself; it just
      // receives a queue that no longer contains what the captain was never shown.
      return originalRestoreQueuedMessagesToEditor.call(this, options);
    } finally {
      const retained = retainedByRestore;
      restoringQueuedMessages = false;
      retainedByRestore = 0;
      // Only an abort leaves Pi with a settled run and a non-empty queue, which is the one
      // path that restarts the agent on its own.
      if (options?.abort && retained > 0) {
        this.showStatus?.(CALM_SUPERVISION_CONTINUES_NOTICE);
      }
    }
  };

  // Clears exactly what Pi clears, then puts the marker-authenticated messages back in their
  // original order and reports only the captain-authored ones as restorable. Whether that is
  // possible is decided before anything is cleared, so a Pi without the already-expanded
  // queueing entry point ends the hiding first and then gets its own untouched restore.
  function clearQueuesRetainingOperational(mode: InteractiveModeQueueOwner): QueuedMessages {
    const session = mode.session;
    const compactionBefore = [...mode.compactionQueuedMessages];
    const sessionSteeringBefore = [...session.getSteeringMessages()];
    const sessionFollowUpBefore = [...session.getFollowUpMessages()];

    const isOperational = (text: string): boolean => patch.isOperationalInput(text);
    const retainedSteering = sessionSteeringBefore.filter(isOperational);
    const retainedFollowUp = sessionFollowUpBefore.filter(isOperational);
    const retainedCompaction = compactionBefore.filter((message) =>
      isOperational(message.text),
    );
    const retainedCount =
      retainedSteering.length + retainedFollowUp.length + retainedCompaction.length;
    if (retainedCount === 0) return originalClearAllQueues.call(mode);
    if (
      (retainedSteering.length > 0 && typeof session._queueSteer !== "function") ||
      (retainedFollowUp.length > 0 && typeof session._queueFollowUp !== "function")
    ) {
      queuedHidingUnavailable = true;
      return originalClearAllQueues.call(mode);
    }

    const cleared = originalClearAllQueues.call(mode);
    // Pi's already-expanded queueing entry points update the queue synchronously and hand
    // back a promise only because their callers are async; settling it here keeps a queue
    // listener's failure from surfacing as an unhandled rejection inside a key handler.
    const requeue = (queued: unknown): void => {
      void Promise.resolve(queued).catch(() => {});
    };
    for (const message of retainedSteering) requeue(session._queueSteer?.(message));
    for (const message of retainedFollowUp) requeue(session._queueFollowUp?.(message));
    mode.compactionQueuedMessages.push(...retainedCompaction);
    retainedByRestore = retainedCount;
    return {
      ...cleared,
      steering: cleared.steering.filter((message) => !isOperational(message)),
      followUp: cleared.followUp.filter((message) => !isOperational(message)),
    };
  }

  registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH] = patch;
}
