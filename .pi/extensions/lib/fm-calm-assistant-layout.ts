// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes collapsed thinking and the mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy. The message
// itself, model context, session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmOperationalTurnIsActive,
  calmPresentationHides,
  calmReplyIsBareAcknowledgement,
} from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
  calmOperationalTurn?: boolean;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  hidesOperationalReply: () => boolean;
};

// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and is already set while the message streams, so this
// layout never has to ask whether the turn ended. It stays "pending" until the tool
// call materializes, which is why a working note is briefly visible before it
// collapses; suppressing pending text would also stop a genuine reply from streaming.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// The reply that closes a turn started by a hidden operational input, and that says
// nothing the captain needs. A mid-turn message is left to the working-note rule above,
// so this only ever matches the message the model ended its response with. Which turn
// this message belongs to is decided by the caller's latched value, never by the current
// global flag, so a later internal turn cannot re-filter an already-rendered row.
//
// Accepted quirk: while a reply streams, the accumulated text can momentarily equal the
// no-action phrase before the rest arrives, so such a reply flickers before it settles.
// The final message renders correctly and latching does not change that.
function isOperationalTurnAcknowledgement(
  message: AssistantMessage,
  operationalTurn: boolean,
): boolean {
  if (!operationalTurn) return false;
  if (isMidTurnAssistantMessage(message)) return false;
  const spoken = message.content
    .filter((block) => block.type === "text")
    .map((block) => (block as { text?: string }).text ?? "")
    .join("\n");
  return calmReplyIsBareAcknowledgement(spoken);
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process. The pin therefore no longer distinguishes later
// behaviour changes such as operational-reply hiding: after an in-process upgrade the
// already-installed wrapper stays in charge, so those take effect on the next restart.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const hidesOperationalReply = (): boolean =>
    calmPresentationHides("operational-turn-reply");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    installed.hidesOperationalReply = hidesOperationalReply;
    return;
  }

  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    hidesOperationalReply,
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // Latch which turn this row belongs to the first time this component receives a
    // message. A re-layout re-calls updateContent, and Pi cascades that to every chat
    // child on a terminal resize or a screen switch, so reading the live flag here would
    // re-judge an already-rendered row under a later turn and could drop a genuine reply
    // the captain has already seen. Whether Calm hides at all stays live, so toggling
    // Calm still repaints correctly.
    state.calmOperationalTurn ??= calmOperationalTurnIsActive();
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    // The captain asked not to see internal messages in chat. The operational input that
    // started this turn is already rendered as nothing, so its bare acknowledgement is
    // the other half of the same internal exchange and is dropped from the rendered rows
    // too. Only a short acknowledgement qualifies - see calmReplyIsBareAcknowledgement -
    // so a decision, blocker, finding, review-ready outcome or PR link produced by the
    // same turn still reaches the captain.
    const hideOperationalReply =
      patch.hidesOperationalReply() &&
      isOperationalTurnAcknowledgement(message, state.calmOperationalTurn);
    const presentationMessage =
      hideThinking || hideWorkingNote || hideOperationalReply
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !((hideWorkingNote || hideOperationalReply) && block.type === "text"),
            ),
          }
        : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
