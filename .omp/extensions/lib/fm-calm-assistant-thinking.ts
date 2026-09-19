// OMP presentation adapter that collapses thinking and short mid-turn working
// notes while Calm is on.
//
// Verified against omp 18.1.17, which exports AssistantMessageComponent with
// updateContent from @oh-my-pi/pi-coding-agent. This adapter probes that exact
// seam and throws if it is missing so fm-calm.ts can skip only this adapter with
// a diagnostic. Message data, model context, session storage, and export
// rendering are never rewritten, and OMP's own hide-thinking field is never
// written: Calm-on collapse is a presentation-layer filter of the message it
// passes to the stock component.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmTextIsSubstantive } from "../../../.pi/extensions/lib/fm-calm-preservation.ts";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type ContentBlock = {
  type: string;
  text?: string;
  thinking?: string;
};

type AssistantMessage = {
  role?: string;
  stopReason?: string;
  timestamp?: number;
  responseId?: string;
  content: ContentBlock[];
};

type AssistantMessageUpdateOptions = {
  transient?: boolean;
};

type AssistantMessageComponentLike = {
  invalidate(): void;
  updateContent(message: AssistantMessage, options?: AssistantMessageUpdateOptions): void;
};

type CalmAssistantThinkingPatch = {
  remembered: Set<AssistantMessageComponentLike>;
  originalMessages: WeakMap<AssistantMessageComponentLike, AssistantMessage>;
  originalOptions: WeakMap<
    AssistantMessageComponentLike,
    AssistantMessageUpdateOptions | undefined
  >;
  presentationMessages: WeakMap<AssistantMessageComponentLike, AssistantMessage>;
  midTurnKeys: Set<string>;
  originalUpdateContent: AssistantMessageComponentLike["updateContent"] | undefined;
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  remember: (component: AssistantMessageComponentLike) => void;
  applyToRemembered: () => void;
  reset: () => void;
};

const CALM_ASSISTANT_THINKING_PATCH = Symbol.for(
  "firstmate:calm-assistant-thinking:omp-18.1.17",
);

function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    Array.isArray(message.content) &&
    message.content.some((block) => block.type === "toolCall")
  );
}

function rememberMidTurn(
  patch: CalmAssistantThinkingPatch,
  message: AssistantMessage,
): void {
  if (message.role !== undefined && message.role !== "assistant") return;
  if (!Array.isArray(message.content)) return;
  const key = assistantMessageKey(message);
  if (key === undefined) return;
  const midTurn = isMidTurnAssistantMessage(message);
  const wasMidTurn = patch.midTurnKeys.has(key);
  if (midTurn) {
    patch.midTurnKeys.add(key);
  } else {
    patch.midTurnKeys.delete(key);
  }
  if (midTurn && !wasMidTurn && patch.hidesWorkingNote()) {
    patch.applyToRemembered();
  }
}

// OMP 18.1.17 splits every assistant message at its first tool call before
// rendering and feeds the component a derived message with the tool call
// stripped, so `isMidTurnAssistantMessage` cannot see the tool call on the
// message the adapter receives. OMP still raises its own assistant message
// events with the unfiltered message; remembering the timestamp of a mid-turn
// assistant message lets the presentation filter recognise the derived
// before-tools message as mid-turn.
function assistantMessageKey(message: AssistantMessage): string | undefined {
  if (typeof message.timestamp === "number") return `t:${message.timestamp}`;
  if (typeof message.responseId === "string") return `r:${message.responseId}`;
  return undefined;
}

function isPresentationDerived(
  message: AssistantMessage,
  presentation: AssistantMessage | undefined,
): boolean {
  return presentation !== undefined && message.content === presentation.content;
}

export function installOmpCalmAssistantThinking(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantThinkingPatch | undefined;
  };
  const installed = registry[CALM_ASSISTANT_THINKING_PATCH];
  if (installed) {
    installed.hidesThinking = () => calmPresentationHides("assistant-thinking");
    installed.hidesWorkingNote = () => calmPresentationHides("assistant-working-note");
    return;
  }

  const patch: CalmAssistantThinkingPatch = {
    remembered: new Set(),
    originalMessages: new WeakMap(),
    originalOptions: new WeakMap(),
    presentationMessages: new WeakMap(),
    midTurnKeys: new Set(),
    originalUpdateContent: undefined,
    hidesThinking: () => calmPresentationHides("assistant-thinking"),
    hidesWorkingNote: () => calmPresentationHides("assistant-working-note"),
    remember(component) {
      patch.remembered.add(component);
    },
    applyToRemembered() {
      const shouldHideThinking = patch.hidesThinking();
      const shouldHideWorkingNote = patch.hidesWorkingNote();
      for (const component of patch.remembered) {
        try {
          const originalMessage = patch.originalMessages.get(component);
          if (originalMessage && (shouldHideThinking || shouldHideWorkingNote)) {
            component.updateContent(originalMessage, patch.originalOptions.get(component));
          } else if (originalMessage && patch.originalUpdateContent) {
            patch.presentationMessages.set(component, originalMessage);
            patch.originalUpdateContent.call(
              component,
              originalMessage,
              patch.originalOptions.get(component),
            );
          } else {
            component.invalidate();
          }
        } catch {
          patch.remembered.delete(component);
        }
      }
    },
    reset() {
      patch.remembered.clear();
    },
  };

  const AssistantMessageComponent = (
    OmpCodingAgent as { AssistantMessageComponent?: unknown }
  ).AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires OMP AssistantMessageComponent");
  }
  const prototype = (
    AssistantMessageComponent as {
      prototype: AssistantMessageComponentLike;
    }
  ).prototype;
  const stockUpdateContent = prototype.updateContent;
  if (typeof stockUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires OMP AssistantMessageComponent.updateContent");
  }
  const InteractiveMode = (OmpCodingAgent as { InteractiveMode?: unknown }).InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode");
  }
  const interactivePrototype = (
    InteractiveMode as {
      prototype: {
        addMessageToChat?: (message: AssistantMessage, options?: unknown) => unknown;
      };
    }
  ).prototype;
  const stockAddMessageToChat = interactivePrototype.addMessageToChat;
  if (typeof stockAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode.addMessageToChat");
  }

  patch.originalUpdateContent = stockUpdateContent;

  prototype.updateContent = function (
    this: AssistantMessageComponentLike,
    message: AssistantMessage,
    options?: AssistantMessageUpdateOptions,
  ): void {
    patch.remember(this);
    const presentation = patch.presentationMessages.get(this);
    if (isPresentationDerived(message, presentation)) {
      const originalMessage = patch.originalMessages.get(this);
      if (originalMessage) {
        patch.originalMessages.set(this, { ...message, content: originalMessage.content });
      }
    } else {
      patch.originalMessages.set(this, message);
      patch.originalOptions.set(this, options);
    }
    const hidesThinking = patch.hidesThinking();
    const key = assistantMessageKey(message);
    const midTurn =
      isMidTurnAssistantMessage(message) ||
      (key !== undefined && patch.midTurnKeys.has(key));
    const hidesWorkingNote =
      patch.hidesWorkingNote() &&
      midTurn &&
      message.content.some(
        (block) => block.type === "text" && !calmTextIsSubstantive(block.text ?? ""),
      );
    const presentationMessage =
      hidesThinking || hidesWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hidesThinking && block.type === "thinking") &&
                !(
                  hidesWorkingNote &&
                  block.type === "text" &&
                  !calmTextIsSubstantive(block.text ?? "")
                ),
            ),
          }
        : message;
    patch.presentationMessages.set(this, presentationMessage);
    stockUpdateContent.call(this, presentationMessage, options);
  };

  interactivePrototype.addMessageToChat = function (
    this: unknown,
    message: AssistantMessage,
    options?: unknown,
  ): unknown {
    rememberMidTurn(patch, message);
    return stockAddMessageToChat.call(this, message, options);
  };

  registry[CALM_ASSISTANT_THINKING_PATCH] = patch;
}

/** Re-apply Calm thinking visibility to assistant rows already on screen. */
export function applyOmpCalmThinkingToRememberedRows(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantThinkingPatch | undefined;
  };
  registry[CALM_ASSISTANT_THINKING_PATCH]?.applyToRemembered();
}

export function resetOmpCalmThinkingRememberedRows(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantThinkingPatch | undefined;
  };
  registry[CALM_ASSISTANT_THINKING_PATCH]?.reset();
}

/**
 * Record whether an unfiltered assistant message from OMP's own event stream
 * ended in tool calls, so the derived before-tools message handed to the stock
 * component is still recognised as mid-turn while Calm hides working notes.
 * The live `addMessageToChat` path seeds the same record so a restored
 * transcript hides its stored mid-turn working notes too.
 */
export function rememberOmpCalmAssistantMessage(message: AssistantMessage): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantThinkingPatch | undefined;
  };
  const patch = registry[CALM_ASSISTANT_THINKING_PATCH];
  if (!patch) return;
  rememberMidTurn(patch, message);
}
