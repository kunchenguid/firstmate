// OMP presentation adapter that collapses thinking and short mid-turn working
// notes while Calm is on.
//
// Verified against omp 18.1.17, which exports AssistantMessageComponent with
// updateContent and setHideThinkingBlock from @oh-my-pi/pi-coding-agent. This
// adapter probes those exact seams and throws if either is missing so
// fm-calm.ts can skip only this adapter with a diagnostic. Message data, model
// context, session storage, and export rendering are never rewritten.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmTextIsSubstantive } from "../../../.pi/extensions/lib/fm-calm-preservation.ts";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type ContentBlock = {
  type: string;
  text?: string;
  thinking?: string;
};

type AssistantMessage = {
  stopReason?: string;
  content: ContentBlock[];
};

type AssistantMessageUpdateOptions = {
  transient?: boolean;
};

type AssistantMessageComponentLike = {
  setHideThinkingBlock(hide: boolean): void;
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
  return message.content.some((block) => block.type === "toolCall");
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
    originalUpdateContent: undefined,
    hidesThinking: () => calmPresentationHides("assistant-thinking"),
    hidesWorkingNote: () => calmPresentationHides("assistant-working-note"),
    remember(component) {
      patch.remembered.add(component);
    },
    applyToRemembered() {
      const hide = patch.hidesThinking();
      const shouldHideWorkingNote = patch.hidesWorkingNote();
      for (const component of patch.remembered) {
        try {
          component.setHideThinkingBlock(hide);
          const originalMessage = patch.originalMessages.get(component);
          if (shouldHideWorkingNote && originalMessage) {
            component.updateContent(originalMessage, patch.originalOptions.get(component));
          } else if (originalMessage && patch.originalUpdateContent) {
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
      prototype: AssistantMessageComponentLike & {
        setHideThinkingBlock?: unknown;
      };
    }
  ).prototype;
  const stockUpdateContent = prototype.updateContent;
  if (typeof stockUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires OMP AssistantMessageComponent.updateContent");
  }
  patch.originalUpdateContent = stockUpdateContent;
  if (typeof prototype.setHideThinkingBlock !== "function") {
    throw new Error(
      "Firstmate Calm requires OMP AssistantMessageComponent.setHideThinkingBlock",
    );
  }

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
    const hideThinking = patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() &&
      isMidTurnAssistantMessage(message) &&
      message.content.some(
        (block) => block.type === "text" && !calmTextIsSubstantive(block.text ?? ""),
      );
    const presentationMessage =
      hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(
                  block.type === "text" &&
                  !calmTextIsSubstantive(block.text ?? "")
                ),
            ),
          }
        : message;
    this.setHideThinkingBlock(hideThinking);
    patch.presentationMessages.set(this, presentationMessage);
    stockUpdateContent.call(this, presentationMessage, options);
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
