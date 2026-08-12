// Verified against Pi 0.81.1, 0.82.0, and 0.84.1, which add the ordinary-user spacer and
// row together via InteractiveMode.addMessageToChat and render the pending-message dock
// through InteractiveMode.updatePendingMessagesDisplay.
//
// Compatibility boundary: every InteractiveMode member this adapter binds is declared
// `private` in Pi's own type declarations, including the addMessageToChat path that
// predates the pending dock. Pi gives no public transcript-row or pending-dock renderer,
// so the Calm presentation boundary is only reachable through that private surface. These
// are therefore not stable API and a minor Pi upgrade may rename or remove them. The
// PRIVATE_INTERACTIVE_MODE_MEMBERS list below is the single declaration of that surface;
// it is probed by name at install time and every miss fails loudly rather than silently
// degrading, so loss of surface surfaces as a diagnostic instead of Calm quietly
// rendering operational rows again. This adapter changes only presentation and never
// changes message delivery, ordering, or persistence.
import type { UserMessageComponent as PiUserMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type PendingMessages = {
  steering: string[];
  followUp: string[];
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getMarkdownTransformers(): UserMessageConstructorArgs[3];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
// Declared optional on purpose: these are Pi-private members, so the presence probe in
// installCalmOperationalUserLayout() is a real runtime possibility rather than dead code.
type InteractiveModePrototype = {
  addMessageToChat?(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
  getAllQueuedMessages?(): PendingMessages;
  getMarkdownTransformers?(): UserMessageConstructorArgs[3];
  setHiddenThinkingLabel?(label?: string): void;
  updatePendingMessagesDisplay?(): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// setHiddenThinkingLabel is patched on the shared prototype, but the pending dock it
// guards is per InteractiveMode instance, so the last rendered state is tracked per
// instance. A single shared flag would be last-writer-wins across live instances and
// would skip a rebuild that another instance still needs.
const pendingDisplayHidesOperational = new WeakMap<object, boolean>();

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

// Classifying operational text runs bin/fm-operational-input.sh through spawnSync, so it
// costs several milliseconds per call. The pending dock re-filters every queued message on
// each repaint and Pi repaints on every queue mutation, which would otherwise block the
// TUI event loop for that cost times the queue length on each frame. Classification is a
// pure function of the exact message text, so the verdict is cached per text. The cache is
// bounded and evicts in insertion order, since queued message text is attacker-independent
// but unbounded in principle over a long session.
const OPERATIONAL_CLASSIFICATION_CACHE_LIMIT = 256;

function createOperationalInputClassifier(
  classify: (text: string) => boolean,
): (text: string) => boolean {
  const cache = new Map<string, boolean>();
  return (text: string): boolean => {
    const cached = cache.get(text);
    if (cached !== undefined) return cached;
    const verdict = classify(text);
    if (cache.size >= OPERATIONAL_CLASSIFICATION_CACHE_LIMIT) {
      const oldest = cache.keys().next();
      if (!oldest.done) cache.delete(oldest.value);
    }
    cache.set(text, verdict);
    return verdict;
  };
}

// The complete Pi-private InteractiveMode surface this adapter binds. Each name is probed
// on the prototype at install time so a Pi upgrade that renames one fails loudly.
const PRIVATE_INTERACTIVE_MODE_MEMBERS = [
  "addMessageToChat",
  "getAllQueuedMessages",
  "getMarkdownTransformers",
  "setHiddenThinkingLabel",
  "updatePendingMessagesDisplay",
] as const satisfies readonly (keyof InteractiveModePrototype)[];

function requirePrivateInteractiveModeMembers(
  prototype: InteractiveModePrototype,
): void {
  const missing = PRIVATE_INTERACTIVE_MODE_MEMBERS.filter(
    (member) => typeof prototype[member] !== "function",
  );
  if (missing.length > 0) {
    throw new Error(
      "Firstmate Calm requires Pi InteractiveMode private presentation members: " +
        `${missing.join(", ")} missing. Pi's transcript and pending-message rendering ` +
        "surface changed, so the Calm operational-row adapter cannot be installed.",
    );
  }
}

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const classifyOperationalInput = createOperationalInputClassifier(
    (text) =>
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX),
  );
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return classifyOperationalInput(text);
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    // hidesOperationalInput closes over this module's Calm visibility state, so a reload
    // must adopt the new one. isOperationalInput is deliberately left alone: it classifies
    // by the same version-stable rules either way, and replacing it would throw away the
    // warm classification cache and re-spawn the classifier for every already-queued
    // message on the next dock repaint.
    installed.hidesOperationalInput = hidesOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  requirePrivateInteractiveModeMembers(prototype);
  const originalAddMessageToChat = prototype.addMessageToChat!;
  const originalGetAllQueuedMessages = prototype.getAllQueuedMessages!;
  const originalSetHiddenThinkingLabel = prototype.setHiddenThinkingLabel!;
  const originalUpdatePendingMessagesDisplay = prototype.updatePendingMessagesDisplay!;

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      hasLeadingSpacer: boolean,
      markdownTransformers: UserMessageConstructorArgs[3],
    ) {
      super(text, markdownTheme, outputPad, markdownTransformers);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new CalmOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.chatContainer.children.length > 0,
      this.getMarkdownTransformers(),
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  prototype.updatePendingMessagesDisplay = function (this: InteractiveModePrototype): void {
    if (!patch.hidesOperationalInput()) {
      originalUpdatePendingMessagesDisplay.call(this);
      return;
    }

    const mode = this as unknown as InteractiveModePrototype & Record<string, unknown>;
    const hadOwnQueueReader = Object.prototype.hasOwnProperty.call(mode, "getAllQueuedMessages");
    const previousQueueReader = mode.getAllQueuedMessages;
    mode.getAllQueuedMessages = (): PendingMessages => {
      const pending = originalGetAllQueuedMessages.call(this);
      return {
        steering: pending.steering.filter((text) => !patch.isOperationalInput(text)),
        followUp: pending.followUp.filter((text) => !patch.isOperationalInput(text)),
      };
    };
    try {
      originalUpdatePendingMessagesDisplay.call(this);
    } finally {
      if (hadOwnQueueReader) {
        mode.getAllQueuedMessages = previousQueueReader;
      } else {
        delete mode.getAllQueuedMessages;
      }
    }
  };
  prototype.setHiddenThinkingLabel = function (
    this: InteractiveModePrototype,
    label?: string,
  ): void {
    const hidesOperational = patch.hidesOperationalInput();
    const previous = pendingDisplayHidesOperational.get(this);
    if (previous !== undefined && hidesOperational !== previous) {
      // Calm changes state before it calls this UI method. Rebuild the pending dock
      // before Pi requests its render so already-queued operational rows disappear or
      // return on the same frame as delivered rows. Queue arrivals use the patched
      // update method directly, so the initial state needs no extra render.
      prototype.updatePendingMessagesDisplay!.call(this);
    }
    pendingDisplayHidesOperational.set(this, hidesOperational);
    originalSetHiddenThinkingLabel.call(this, label);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
