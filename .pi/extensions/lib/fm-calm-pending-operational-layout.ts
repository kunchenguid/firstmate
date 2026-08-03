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
// Hiding a queued row is only ever safe while this restore stays adapted, and two rules are
// absolute: a notification this adapter hid may never reappear as raw text, and no
// notification may ever be dropped to keep presentation clean. Deciding that at restore time
// forces a choice between them, so the capability is instead proven before the first row is
// ever hidden. The two already-expanded queueing entry points the retention needs live on the
// session rather than the prototype, so they cannot be probed at install; they are checked on
// the first render that would suppress anything, with `this` bound to the interactive mode. A
// session that lacks either one never gets any suppression at all, and says so once.
// See https://github.com/kunchenguid/firstmate/issues/1588.
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
// The two already-expanded queueing entry points the safe restore retains through. They are
// session-instance members, so the only place to prove they exist is a live interactive mode.
type QueueRetainingSession = {
  getSteeringMessages(): string[];
  getFollowUpMessages(): string[];
  _queueSteer(text: string): unknown;
  _queueFollowUp(text: string): unknown;
};
// The queue owners Pi's own clearAllQueues reads and empties.
type InteractiveModeQueueOwner = {
  session: QueueRetainingSession;
  compactionQueuedMessages: CompactionQueuedMessage[];
};
type RestoreQueuedMessagesOptions = {
  abort?: boolean;
  currentText?: string;
};
// Pi's own transient chat status line, the same one it uses for "Restored N queued messages
// to editor". It is not a session entry, so it never reaches persistence, export, or share.
type CalmQueuedRowHost = {
  session?: Partial<QueueRetainingSession>;
  showStatus?(message: string): void;
};
type InteractiveModePendingPrototype = {
  getAllQueuedMessages(this: unknown): QueuedMessages;
  updatePendingMessagesDisplay(this: CalmQueuedRowHost): void;
  clearAllQueues(this: InteractiveModeQueueOwner): QueuedMessages;
  restoreQueuedMessagesToEditor(
    this: CalmQueuedRowHost,
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
// The compatibility diagnostic for a Pi whose session cannot retain a queued message across
// the restore. Names no notification and quotes none: it reports a Pi capability only.
export const CALM_QUEUED_ROW_SUPPRESSION_UNAVAILABLE_NOTICE =
  "Firstmate Calm: this Pi cannot retain queued messages, so queued rows stay visible.";

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
  // Counts only what one restore handed back to Pi's agent queue, because that queue alone is
  // what makes Pi continue into another turn. Compaction-held retention never reaches it.
  let retainedByRestore = 0;
  // The capability answer for this process, decided the first time suppression is considered
  // and never revisited: the entry points belong to the AgentSession class, so a later session
  // in the same process cannot answer differently.
  let queueRetentionSupported: boolean | undefined;
  function sessionRetainsQueuedMessages(host: CalmQueuedRowHost): boolean {
    if (queueRetentionSupported !== undefined) return queueRetentionSupported;
    const session = host.session;
    queueRetentionSupported =
      typeof session?._queueSteer === "function" &&
      typeof session?._queueFollowUp === "function";
    if (!queueRetentionSupported) {
      // Emitted once, before anything has been hidden, so the captain learns why queued rows
      // look stock rather than watching them silently change behaviour later.
      if (typeof host.showStatus === "function") {
        host.showStatus(CALM_QUEUED_ROW_SUPPRESSION_UNAVAILABLE_NOTICE);
      } else {
        console.error(CALM_QUEUED_ROW_SUPPRESSION_UNAVAILABLE_NOTICE);
      }
    }
    return queueRetentionSupported;
  }
  const hidesQueuedOperational = (host: CalmQueuedRowHost): boolean =>
    patch.hidesOperationalInput() && sessionRetainsQueuedMessages(host);
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
  prototype.updatePendingMessagesDisplay = function (this: CalmQueuedRowHost): void {
    if (!hidesQueuedOperational(this)) {
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
    this: CalmQueuedRowHost,
    options?: RestoreQueuedMessagesOptions,
  ): number {
    if (!hidesQueuedOperational(this)) {
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
  // original order and reports only the captain-authored ones as restorable. This runs only
  // for a queue whose rows were suppressed, which the preflight already proved retainable, so
  // it never has to choose between leaking a hidden notification and dropping one.
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
    if (
      retainedSteering.length === 0 &&
      retainedFollowUp.length === 0 &&
      retainedCompaction.length === 0
    ) {
      return originalClearAllQueues.call(mode);
    }

    const cleared = originalClearAllQueues.call(mode);
    // Pi's already-expanded queueing entry points update the queue synchronously and hand
    // back a promise only because their callers are async; settling it here keeps a queue
    // listener's failure from surfacing as an unhandled rejection inside a key handler.
    const requeue = (queued: unknown): void => {
      void Promise.resolve(queued).catch(() => {});
    };
    for (const message of retainedSteering) requeue(session._queueSteer(message));
    for (const message of retainedFollowUp) requeue(session._queueFollowUp(message));
    mode.compactionQueuedMessages.push(...retainedCompaction);
    // Only the agent-queue retention can make Pi continue on its own; compaction-held
    // messages stay inside this interactive mode until a compaction flush sends them.
    retainedByRestore = retainedSteering.length + retainedFollowUp.length;
    return {
      ...cleared,
      steering: cleared.steering.filter((message) => !isOperational(message)),
      followUp: cleared.followUp.filter((message) => !isOperational(message)),
    };
  }

  registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH] = patch;
}
