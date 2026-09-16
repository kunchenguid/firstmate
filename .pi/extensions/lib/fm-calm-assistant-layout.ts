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
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
  lastPresentedMessage?: AssistantMessage;
  lastSourceMessage?: AssistantMessage;
  liveStepKey?: string;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
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

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

let liveStepCounter = 0;
let liveStepSourceIds = new WeakMap<object, number>();
let nextLiveStepSourceId = 0;

export function resetCalmAssistantLiveStepCounter(): void {
  liveStepCounter = 0;
  liveStepSourceIds = new WeakMap<object, number>();
  nextLiveStepSourceId = 0;
}

type LiveStep = {
  key: string;
  block: AssistantMessage["content"][number];
  text: string;
};

function currentLiveStep(message: AssistantMessage): LiveStep | undefined {
  let sourceId = liveStepSourceIds.get(message);
  if (sourceId === undefined) {
    sourceId = nextLiveStepSourceId++;
    liveStepSourceIds.set(message, sourceId);
  }
  for (let index = message.content.length - 1; index >= 0; index--) {
    const block = message.content[index];
    if (block.type !== "thinking" && block.type !== "text") continue;
    const raw = block.type === "thinking" ? block.thinking : block.text;
    const lines = raw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const text = lines.at(-1);
    if (!text) continue;
    return { key: `${sourceId}:${index}:${lines.length}`, block, text };
  }
  return undefined;
}

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
    isStreaming = false,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // Pi's invalidate() and presentation setters call updateContent() with the
    // shallow presentation copy held by Pi itself. Do not decorate that copy a
    // second time or a live step would acquire a new prefix on every redraw.
    // A message_end can carry that same presentation copy, however, and must switch
    // back to the source message so the live row is removed rather than retained.
    const presentationReplay =
      message === state.lastPresentedMessage && message !== state.lastSourceMessage;
    const sourceMessage =
      !isStreaming && presentationReplay && state.lastSourceMessage
        ? state.lastSourceMessage
        : message;
    if (isStreaming && presentationReplay) {
      originalUpdateContent.call(this, message, isStreaming);
      return;
    }

    const midTurn = isMidTurnAssistantMessage(sourceMessage);
    const hadLiveStep = state.liveStepKey !== undefined;
    const liveStep = isStreaming && patch.hidesWorkingNote() ? currentLiveStep(sourceMessage) : undefined;
    const hideThinking =
      !isStreaming &&
      state.hiddenThinkingLabel === "" &&
      (state.hideThinkingBlock || hadLiveStep) &&
      patch.hidesThinking();
    const hideWorkingNote = !isStreaming && patch.hidesWorkingNote() && midTurn;
    let presentationMessage = sourceMessage;
    if (liveStep) {
      liveStepCounter = state.liveStepKey === liveStep.key ? liveStepCounter : liveStepCounter + 1;
      state.liveStepKey = liveStep.key;
      const text = `Step ${liveStepCounter}: ${liveStep.text}`;
      const block =
        liveStep.block.type === "thinking"
          ? { ...liveStep.block, thinking: text }
          : { ...liveStep.block, text };
      presentationMessage = { ...sourceMessage, content: [block] };
    } else if (hideThinking || hideWorkingNote) {
      presentationMessage = {
        ...sourceMessage,
        content: sourceMessage.content.filter(
          (block) =>
            !(hideThinking && block.type === "thinking") &&
            !(hideWorkingNote && block.type === "text"),
        ),
      };
    }

    originalUpdateContent.call(this, presentationMessage, isStreaming);
    state.lastMessage = sourceMessage;
    if (!isStreaming) state.liveStepKey = undefined;
    state.lastSourceMessage = sourceMessage;
    state.lastPresentedMessage = presentationMessage;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
