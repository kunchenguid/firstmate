// omp assistant transcript adapter for Calm.
// Patches AssistantMessageComponent.updateContent from @oh-my-pi/pi-coding-agent to
// drop collapsed thinking and mid-turn assistant working-note text from a shallow
// presentation copy. The message, model context, session storage, and export
// rendering are never touched. installCalmAssistantLayout() probes the exact method
// and throws if it is missing; fm-calm.ts catches that and skips only this adapter.
// Unlike Pi, omp exposes no setHiddenThinkingLabel, so thinking hide is gated on the
// Calm policy alone (honoring an explicit component hide flag when present).
// ./fm-calm-visibility.ts owns which classes Calm hides.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = {
  stopReason?: string;
  content: Array<{ type: string; [key: string]: unknown }>;
};

type AssistantMessagePresentationState = {
  hideThinkingBlock?: boolean;
  lastMessage?: AssistantMessage;
};

type AssistantMessageComponentClass = {
  prototype: {
    updateContent: (message: AssistantMessage) => void;
  };
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
};

// A mid-turn assistant message is one the model did not end its response with: the
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and already set while it streams, so a working note is
// briefly visible before it collapses; suppressing pending text would also stop a
// genuine reply from streaming.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:omp-18",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  const patch: CalmAssistantLayoutPatch = { hidesThinking, hidesWorkingNote };
  if (typeof OmpCodingAgent.AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires omp AssistantMessageComponent");
  }
  // omp ships no type package; assert the runtime class shape probed above.
  const AssistantMessageComponent =
    OmpCodingAgent.AssistantMessageComponent as unknown as AssistantMessageComponentClass;
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires omp AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // omp has no setHiddenThinkingLabel. Honor an explicit component hide flag when
    // present, and always honor Calm's thinking policy while Calm is active.
    const hideThinking = state.hideThinkingBlock !== false && patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    const presentationMessage =
      hideThinking || hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(hideWorkingNote && block.type === "text"),
            ),
          }
        : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
