import { AssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<AssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
};

const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    return;
  }

  const patch: CalmAssistantLayoutPatch = { hidesThinking };
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const presentationMessage = hideThinking
      ? {
          ...message,
          content: message.content.filter((block) => block.type !== "thinking"),
        }
      : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
