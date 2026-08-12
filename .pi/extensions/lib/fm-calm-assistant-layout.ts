// Verified against Pi 0.81.1, 0.82.0, and 0.84.0, which export AssistantMessageComponent
// with updateContent and setHideThinkingBlock methods plus InteractiveMode with
// toggleThinkingBlockVisibility. installCalmAssistantLayout() probes those exact methods
// and throws if one is missing; fm-calm.ts catches that and skips only this adapter with a
// diagnostic instead of blocking Calm or Pi.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type InteractiveThinkingPresentationState = {
  hideThinkingBlock: boolean;
  toggleThinkingBlockVisibility(): void;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  thinkingExpanded: () => boolean;
  setThinkingExpanded: (expanded: boolean) => void;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
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

  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    thinkingExpanded: () => false,
    setThinkingExpanded: () => {},
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }
  const originalSetHideThinkingBlock = AssistantMessageComponent.prototype.setHideThinkingBlock;
  if (typeof originalSetHideThinkingBlock !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.setHideThinkingBlock");
  }
  const InteractiveMode = PiCodingAgent.InteractiveMode as unknown as {
    prototype: InteractiveThinkingPresentationState;
  };
  const originalToggleThinkingBlockVisibility = InteractiveMode.prototype.toggleThinkingBlockVisibility;
  if (typeof originalToggleThinkingBlockVisibility !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.toggleThinkingBlockVisibility");
  }

  let thinkingExpanded = false;
  patch.thinkingExpanded = () => thinkingExpanded;
  patch.setThinkingExpanded = (expanded) => {
    thinkingExpanded = expanded;
  };

  AssistantMessageComponent.prototype.setHideThinkingBlock = function (hide: boolean): void {
    if (patch.hidesThinking()) patch.setThinkingExpanded(!hide);
    originalSetHideThinkingBlock.call(this, hide);
  };

  InteractiveMode.prototype.toggleThinkingBlockVisibility = function (): void {
    if (patch.hidesThinking()) {
      const nextExpanded = !patch.thinkingExpanded();
      patch.setThinkingExpanded(nextExpanded);
      // Pi's stock toggle negates this field before rebuilding the transcript.
      // Seed it with the desired expansion so the resulting stock state remains aligned.
      this.hideThinkingBlock = nextExpanded;
    }
    originalToggleThinkingBlockVisibility.call(this);
  };

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    const hideThinking = patch.hidesThinking() && !patch.thinkingExpanded();
    const presentationMessage = hideThinking
      ? {
          ...message,
          content: message.content.filter((block) => block.type !== "thinking"),
        }
      : message;
    const restoreHideThinkingBlock = state.hideThinkingBlock;
    if (patch.hidesThinking() && patch.thinkingExpanded()) state.hideThinkingBlock = false;
    try {
      originalUpdateContent.call(this, presentationMessage);
    } finally {
      state.hideThinkingBlock = restoreHideThinkingBlock;
    }
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}

export function resetCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  registry[CALM_ASSISTANT_LAYOUT_PATCH]?.setThinkingExpanded(false);
}
