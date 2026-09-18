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

export function installOmpCalmAssistantThinking(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantThinkingPatch | undefined;
  };
  const remembered = new Set<AssistantMessageComponentLike>();
  const originalMessages = new WeakMap<AssistantMessageComponentLike, AssistantMessage>();
  const originalOptions = new WeakMap<
    AssistantMessageComponentLike,
    AssistantMessageUpdateOptions | undefined
  >();
  const presentationMessages = new WeakMap<AssistantMessageComponentLike, AssistantMessage>();
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  let originalUpdateContent: AssistantMessageComponentLike["updateContent"] | undefined;
  const applyToRemembered = (): void => {
    const hide = hidesThinking();
    const shouldHideWorkingNote = hidesWorkingNote();
    for (const component of remembered) {
      try {
        component.setHideThinkingBlock(hide);
        const originalMessage = originalMessages.get(component);
        if (shouldHideWorkingNote && originalMessage) {
          component.updateContent(originalMessage, originalOptions.get(component));
        } else if (originalMessage && originalUpdateContent) {
          originalUpdateContent.call(component, originalMessage, originalOptions.get(component));
        } else {
          component.invalidate();
        }
      } catch {
        remembered.delete(component);
      }
    }
  };
  const reset = (): void => {
    remembered.clear();
  };
  const installed = registry[CALM_ASSISTANT_THINKING_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    installed.applyToRemembered = applyToRemembered;
    installed.reset = reset;
    return;
  }

  const patch: CalmAssistantThinkingPatch = {
    hidesThinking,
    hidesWorkingNote,
    remember(component) {
      remembered.add(component);
    },
    applyToRemembered,
    reset,
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
  originalUpdateContent = stockUpdateContent;
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
    const isInvalidationReentry = presentationMessages.get(this) === message;
    if (!isInvalidationReentry) {
      originalMessages.set(this, message);
      originalOptions.set(this, options);
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
    presentationMessages.set(this, presentationMessage);
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
