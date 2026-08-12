// Verified against Pi 0.81.1, 0.82.0, and 0.84.1, which add the ordinary-user spacer and
// row together via InteractiveMode.addMessageToChat and expose the pending-message dock
// through InteractiveMode.updatePendingMessagesDisplay. This adapter probes those exact
// methods and changes only presentation; it never changes message delivery.
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
  getMarkdownTransformers?(): UserMessageConstructorArgs[3];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
  getAllQueuedMessages(): PendingMessages;
  setHiddenThinkingLabel(label?: string): void;
  updatePendingMessagesDisplay(): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
  pendingDisplayHidesOperational: boolean | undefined;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

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
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
    pendingDisplayHidesOperational: undefined,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

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
      this.getMarkdownTransformers?.(),
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  const originalGetAllQueuedMessages = prototype.getAllQueuedMessages;
  const originalSetHiddenThinkingLabel = prototype.setHiddenThinkingLabel;
  const originalUpdatePendingMessagesDisplay = prototype.updatePendingMessagesDisplay;
  if (
    typeof originalGetAllQueuedMessages !== "function" ||
    typeof originalSetHiddenThinkingLabel !== "function" ||
    typeof originalUpdatePendingMessagesDisplay !== "function"
  ) {
    console.error(
      "Firstmate Calm: pending operational-message presentation adapter unavailable; " +
        "Pi's pending-message display API is missing",
    );
  } else {
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
      if (
        patch.pendingDisplayHidesOperational !== undefined &&
        hidesOperational !== patch.pendingDisplayHidesOperational
      ) {
        // Calm changes state before it calls this public UI method. Rebuild the
        // pending dock before Pi requests its render so already-queued operational
        // rows disappear or return on the same frame as delivered rows. Queue
        // arrivals use the patched update method directly, so the initial state
        // needs no extra render.
        prototype.updatePendingMessagesDisplay.call(this);
      }
      patch.pendingDisplayHidesOperational = hidesOperational;
      originalSetHiddenThinkingLabel.call(this, label);
    };
  }

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
