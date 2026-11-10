// Verified against Pi 0.87.1 (docs/calm-mode-feasibility.md), which draws queued
// "Steering:"/"Follow-up:" rows, their spacer, and the dequeue hint in
// InteractiveMode.updatePendingMessagesDisplay from InteractiveMode.getAllQueuedMessages.
// A Firstmate notification sent while a turn runs waits there before it is ever a chat row,
// so ./fm-calm-operational-user-layout.ts never sees it. This adapter filters only what that
// one listing reads; the queue Pi delivers from and persists is untouched.
//
// Hiding a queued row makes Pi's InteractiveMode.restoreQueuedMessagesToEditor (Escape during
// a run, and the dequeue key) the one place hidden text could come back: stock Pi empties the
// whole queue into the editor through clearAllQueues. Two rules are absolute: a notification
// this adapter hid never reappears as raw text, and none is dropped to keep presentation
// clean. Under Calm the restore hands only the other messages to the editor and puts the
// hidden notifications back in the queue in their original order.
//
// Putting them back needs members that live on the session object rather than the
// prototype, so they cannot be probed at install. Each session is checked on its first
// queued-listing draw while Calm is on, before any row is hidden. A session missing any of them
// gets no queued-row hiding at all and one warning; its rows and Escape stay stock.
// See https://github.com/kunchenguid/firstmate/issues/1588.
//
// Pi 0.87.1 stops its run loop once a restore is followed by an abort (Escape, or navigating
// the session tree during a run), so a queue that still holds messages when the aborted run
// settles is not delivered until something else starts a turn. After any restore that kept
// notifications in Pi's agent queue, this adapter waits for the session to settle and, if it
// is idle with messages still queued, starts that turn itself with one generic status line.
// A run that keeps going drains the queue itself, so nothing starts after a plain dequeue. A
// notification kept only in the compaction queue is flushed by Pi when compaction ends, so
// it neither counts toward that turn nor announces one.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { isFirstmateOperationalPresentationText } from "./fm-operational-input.ts";

type QueuedMessages = {
  steering: string[];
  followUp: string[];
};
type CompactionQueuedMessage = {
  text: string;
  mode: string;
};
type RetainingSession = {
  getSteeringMessages(): readonly string[];
  getFollowUpMessages(): readonly string[];
  clearQueue(): QueuedMessages;
  _queueSteer(text: string): unknown;
  _queueFollowUp(text: string): unknown;
  waitForIdle(): Promise<void>;
  sendUserMessage(content: string): Promise<void>;
  readonly isIdle: boolean;
};
type PendingRowsHost = {
  session: unknown;
  compactionQueuedMessages: CompactionQueuedMessage[];
  showStatus?(message: string): void;
  showWarning?(message: string): void;
  updatePendingMessagesDisplay(): void;
};
type RestoreOptions = {
  abort?: boolean;
  currentText?: string;
};
type InteractiveModePendingPrototype = {
  getAllQueuedMessages(this: PendingRowsHost): QueuedMessages;
  updatePendingMessagesDisplay(this: PendingRowsHost): void;
  clearAllQueues(this: PendingRowsHost): QueuedMessages;
  restoreQueuedMessagesToEditor(this: PendingRowsHost, options?: RestoreOptions): number;
};
type CalmPendingOperationalLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
  refresh: () => void;
};
type Restoring = {
  session: RetainingSession;
  retains: (text: string) => boolean;
  keptInAgentQueue: number;
};

export const CALM_QUEUE_RETENTION_SESSION_METHODS = [
  "getSteeringMessages",
  "getFollowUpMessages",
  "clearQueue",
  "_queueSteer",
  "_queueFollowUp",
  "waitForIdle",
  "sendUserMessage",
] as const;

// Generic by design: no notification text, marker, kind, path, or identifier.
export const CALM_QUEUED_ROWS_UNSUPPORTED_WARNING =
  "Firstmate Calm: this Pi session cannot keep queued messages across Escape, so queued Firstmate rows stay visible.";
export const CALM_SUPERVISION_CONTINUES_NOTICE =
  "Firstmate supervision continues in a new turn.";

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_PENDING_OPERATIONAL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-pending-operational-layout:pi-0.87.1",
);

function settle(queued: unknown): void {
  void Promise.resolve(queued).catch(() => {});
}

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

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePendingPrototype;
  const originalGetAllQueuedMessages = prototype.getAllQueuedMessages;
  const originalUpdatePendingMessagesDisplay = prototype.updatePendingMessagesDisplay;
  const originalClearAllQueues = prototype.clearAllQueues;
  const originalRestoreQueuedMessagesToEditor = prototype.restoreQueuedMessagesToEditor;
  for (const [name, method] of [
    ["getAllQueuedMessages", originalGetAllQueuedMessages],
    ["updatePendingMessagesDisplay", originalUpdatePendingMessagesDisplay],
    ["clearAllQueues", originalClearAllQueues],
    ["restoreQueuedMessagesToEditor", originalRestoreQueuedMessagesToEditor],
  ] as const) {
    if (typeof method !== "function") {
      throw new Error(`Firstmate Calm requires Pi InteractiveMode.${name}`);
    }
  }

  // The interactive mode that last drew queued rows, so a /calm toggle can redraw them.
  let lastHost: PendingRowsHost | undefined;
  const patch: CalmPendingOperationalLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput: isFirstmateOperationalPresentationText,
    refresh: () => lastHost?.updatePendingMessagesDisplay(),
  };

  const retentionBySession = new WeakMap<object, boolean>();
  function retainingSession(host: PendingRowsHost): RetainingSession | undefined {
    const session = host.session;
    if (typeof session !== "object" || session === null) return undefined;
    let supported = retentionBySession.get(session);
    if (supported === undefined) {
      const members = session as Record<string, unknown>;
      supported =
        CALM_QUEUE_RETENTION_SESSION_METHODS.every((name) => typeof members[name] === "function") &&
        typeof members.isIdle === "boolean" &&
        Array.isArray(host.compactionQueuedMessages);
      retentionBySession.set(session, supported);
      if (!supported) {
        if (typeof host.showWarning === "function") {
          host.showWarning(CALM_QUEUED_ROWS_UNSUPPORTED_WARNING);
        } else {
          console.error(CALM_QUEUED_ROWS_UNSUPPORTED_WARNING);
        }
      }
    }
    return supported ? (session as RetainingSession) : undefined;
  }

  // What the latest draw of the queued listing actually hid, and for which session. The
  // restore retains from this record rather than a fresh classification, so a row the
  // captain never saw stays hidden even if the classifier cannot answer a second time.
  let hidden: { session: object; texts: Set<string> } | undefined;
  // Set only for the synchronous draw below, so every other reader of the queue still
  // sees exactly what Pi queued.
  let hidingInto: Set<string> | undefined;
  // Set only for the synchronous restore below, so any other clearAllQueues caller keeps
  // Pi's stock semantics.
  let restoring: Restoring | undefined;

  prototype.getAllQueuedMessages = function (this: PendingRowsHost): QueuedMessages {
    const queued = originalGetAllQueuedMessages.call(this);
    const texts = hidingInto;
    if (!texts) return queued;
    const stays = (text: string): boolean => {
      if (!patch.isOperationalInput(text)) return true;
      texts.add(text);
      return false;
    };
    return {
      ...queued,
      steering: queued.steering.filter(stays),
      followUp: queued.followUp.filter(stays),
    };
  };

  prototype.updatePendingMessagesDisplay = function (this: PendingRowsHost): void {
    lastHost = this;
    if (!patch.hidesOperationalInput() || !retainingSession(this)) {
      hidden = undefined;
      originalUpdatePendingMessagesDisplay.call(this);
      return;
    }
    const texts = new Set<string>();
    hidingInto = texts;
    try {
      // Pi skips the spacer and dequeue hint when nothing is left to list, so an
      // all-operational queue draws no rows at all.
      originalUpdatePendingMessagesDisplay.call(this);
    } finally {
      hidingInto = undefined;
    }
    hidden = texts.size > 0 ? { session: this.session as object, texts } : undefined;
  };

  prototype.clearAllQueues = function (this: PendingRowsHost): QueuedMessages {
    const current = restoring;
    if (!current) return originalClearAllQueues.call(this);
    const { session, retains } = current;
    const steering = session.getSteeringMessages().filter(retains);
    const followUp = session.getFollowUpMessages().filter(retains);
    const compaction = this.compactionQueuedMessages.filter((message) => retains(message.text));
    const cleared = originalClearAllQueues.call(this);
    if (steering.length + followUp.length + compaction.length === 0) return cleared;
    // Pi's already-expanded queueing entry points: no input handler or template expansion
    // runs a second time on text that already went through them once.
    for (const text of steering) settle(session._queueSteer(text));
    for (const text of followUp) settle(session._queueFollowUp(text));
    this.compactionQueuedMessages.push(...compaction);
    current.keptInAgentQueue = steering.length + followUp.length;
    return {
      ...cleared,
      steering: cleared.steering.filter((text) => !retains(text)),
      followUp: cleared.followUp.filter((text) => !retains(text)),
    };
  };

  prototype.restoreQueuedMessagesToEditor = function (
    this: PendingRowsHost,
    options?: RestoreOptions,
  ): number {
    const hidesNow = patch.hidesOperationalInput();
    const hiddenTexts = hidden && hidden.session === this.session ? hidden.texts : undefined;
    const session = hidesNow || hiddenTexts ? retainingSession(this) : undefined;
    if (!session) return originalRestoreQueuedMessagesToEditor.call(this, options);

    // A notification queued since the last draw was never shown either, so while Calm
    // hides, it is kept the same way; classification is asked once per text.
    const answers = new Map<string, boolean>();
    const retains = (text: string): boolean => {
      if (hiddenTexts?.has(text)) return true;
      if (!hidesNow) return false;
      let answer = answers.get(text);
      if (answer === undefined) {
        answer = patch.isOperationalInput(text);
        answers.set(text, answer);
      }
      return answer;
    };
    const current: Restoring = { session, retains, keptInAgentQueue: 0 };
    restoring = current;
    try {
      return originalRestoreQueuedMessagesToEditor.call(this, options);
    } finally {
      restoring = undefined;
      if (current.keptInAgentQueue > 0) continueWhenSettled(this, session);
    }
  };

  // Delivers what a settled run left queued. Messages already in the queue cannot start a
  // turn by themselves, so the first is taken out and sent as the turn's prompt and the rest
  // are put back behind it: steering first, then follow-ups, the order Pi delivers them in.
  function continueWhenSettled(host: PendingRowsHost, session: RetainingSession): void {
    const settled = async (): Promise<boolean> => {
      do {
        await session.waitForIdle();
        // Pi resolves idle waiters in microtasks, and tree navigation resumes from its
        // abort in the same microtask run and marks the session busy before its first await.
        // Yielding a macrotask lets that navigation claim the session, so the turn starts on
        // the navigated branch instead of racing it on the abandoned one.
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (host.session !== session) return false;
      } while (!session.isIdle);
      return true;
    };
    settled()
      .then((idle) => {
        if (!idle) return;
        const { steering, followUp } = session.clearQueue();
        const first = steering.length > 0 ? steering.shift() : followUp.shift();
        if (first === undefined) return;
        for (const text of steering) settle(session._queueSteer(text));
        for (const text of followUp) settle(session._queueFollowUp(text));
        host.showStatus?.(CALM_SUPERVISION_CONTINUES_NOTICE);
        // Pi rejects before recording the prompt when it cannot start the turn, so the
        // message is queued again rather than lost.
        session.sendUserMessage(first).catch(() => settle(session._queueFollowUp(first)));
      })
      .catch(() => {});
  }

  registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH] = patch;
}

// Redraws the queued listing after a /calm toggle so rows already listed follow the new
// choice at once instead of at the next queue change.
export function refreshCalmPendingOperationalRows(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmPendingOperationalLayoutPatch | undefined;
  };
  registry[CALM_PENDING_OPERATIONAL_LAYOUT_PATCH]?.refresh();
}
