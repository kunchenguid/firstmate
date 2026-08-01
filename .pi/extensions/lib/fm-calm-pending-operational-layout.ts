// Verified against Pi 0.82.1, which renders the queued "Steering:"/"Follow-up:" rows, their
// leading spacer, and the dequeue hint from InteractiveMode.updatePendingMessagesDisplay,
// reading the queue through InteractiveMode.getAllQueuedMessages. That display is a separate
// path from the delivered-row path ./fm-calm-operational-user-layout.ts adapts, so a marked
// notification delivered while a tool call is active is visible here before it is ever a chat
// row. This adapter probes both methods and throws if either is missing; fm-calm.ts catches
// that and skips only this adapter with a diagnostic instead of blocking Calm or Pi.
//
// It filters only what that one display reads. Pi still builds every row, spacer, and hint
// itself, and the queue Pi delivers from, restores to the editor, and persists is untouched.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { isFirstmateOperationalPresentationText } from "./fm-operational-input.ts";

type QueuedMessages = {
  steering: string[];
  followUp: string[];
};
type InteractiveModePendingPrototype = {
  getAllQueuedMessages(this: unknown): QueuedMessages;
  updatePendingMessagesDisplay(this: unknown): void;
};
type CalmPendingOperationalLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

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
  const isOperationalInput = (text: string): boolean =>
    isFirstmateOperationalPresentationText(text);
  const installed = registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmPendingOperationalLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
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

  // Scoped to the synchronous pending-row rebuild below, so every other reader of the queue
  // still sees exactly what Pi queued.
  let renderingPendingRows = false;
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
    if (!patch.hidesOperationalInput()) {
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

  registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH] = patch;
}
