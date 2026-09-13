// Verified against Pi 0.81.1, 0.82.0, and 0.84.4, which export
// AssistantMessageComponent with an updateContent method.
// installCalmAssistantLayout() probes that exact method and throws if it is missing.
// fm-calm.ts catches that failure and skips only this adapter with a diagnostic instead
// of blocking Calm or Pi.
// This layout removes collapsed thinking and ordinary mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy.
// Text whose versioned Pi signature explicitly marks a captain-facing phase stays in
// that copy even when a tool call follows it.
// The message itself, model context, session storage, and export rendering are never
// touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { TextSignatureV1 } from "@earendil-works/pi-ai";
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];
type AssistantTextBlock = Extract<AssistantMessage["content"][number], { type: "text" }>;

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  originalUpdateContent?: PiAssistantMessageComponent["updateContent"];
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

// Pi's public TextContent.textSignature field can carry the exported TextSignatureV1
// shape.
// Only its explicit commentary and final_answer phases identify user-facing text.
// Legacy opaque signatures, phase-less v1 signatures, unknown versions or phases, and
// malformed JSON stay on the conservative working-note path.
type CaptainFacingTextPhase = NonNullable<TextSignatureV1["phase"]>;

function isCaptainFacingTextPhase(value: unknown): value is CaptainFacingTextPhase {
  return value === "commentary" || value === "final_answer";
}

function hasExplicitCaptainFacingPhase(block: AssistantTextBlock): boolean {
  const rawSignature = block.textSignature;
  if (typeof rawSignature !== "string" || !rawSignature.startsWith("{")) return false;

  try {
    const parsed: unknown = JSON.parse(rawSignature);
    if (typeof parsed !== "object" || parsed === null) return false;
    const signature = parsed as Record<string, unknown>;
    return (
      signature.v === 1 &&
      typeof signature.id === "string" &&
      isCaptainFacingTextPhase(signature.phase)
    );
  } catch {
    return false;
  }
}

// Keep the introduction-version symbol stable so reload can find and replace the
// installed filter while reusing its original delegate.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent =
    installed?.originalUpdateContent ?? AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  if (installed && !installed.originalUpdateContent) {
    // Older adapters did not retain their delegate in the registry. Disable their
    // filtering before wrapping them so they cannot strip the newly retained text.
    installed.hidesThinking = () => false;
    installed.hidesWorkingNote = () => false;
  }
  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    originalUpdateContent,
  };

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    const presentationMessage =
      hideThinking || hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(
                  hideWorkingNote &&
                  block.type === "text" &&
                  !hasExplicitCaptainFacingPhase(block)
                ),
            ),
          }
        : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
