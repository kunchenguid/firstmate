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
  hideThinkingBlock: boolean;
  isStreaming: boolean;
};

type CalmAssistantPresentation = {
  source: AssistantMessage;
  rendered: AssistantMessage;
  streamed: boolean;
};

type CalmAssistantLayoutController = {
  render: (
    component: PiAssistantMessageComponent,
    message: AssistantMessage,
    isStreaming: boolean,
  ) => void;
  originalUpdateContent: PiAssistantMessageComponent["updateContent"];
  presentations: WeakMap<object, CalmAssistantPresentation>;
};

// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each settled message. Streaming content stays in the source message
// while this adapter gives its transcript component zero height; fm-calm.ts presents
// the latest line through one keyed widget until message_end identifies whether the
// settled text is a working note to hide or a genuine final response to retain.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// The original adapter used this symbol without a mutable implementation delegate.
// A long-lived Pi process kept that first wrapper across /reload, so source updates only
// refreshed its visibility callbacks and never installed later behavior. This second
// generation controller is itself stable across reloads, while render is replaced by
// every newly loaded extension factory. Capturing the then-current method also upgrades
// a process that still has the first-generation wrapper without mutating its transcript.
const CALM_ASSISTANT_LAYOUT_CONTROLLER = Symbol.for(
  "firstmate:calm-assistant-layout-controller:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutController | undefined;
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }

  let controller = registry[CALM_ASSISTANT_LAYOUT_CONTROLLER];
  if (!controller) {
    const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
    if (typeof originalUpdateContent !== "function") {
      throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
    }
    const newController: CalmAssistantLayoutController = {
      render: () => {},
      originalUpdateContent,
      presentations: new WeakMap(),
    };
    controller = newController;
    registry[CALM_ASSISTANT_LAYOUT_CONTROLLER] = newController;
    AssistantMessageComponent.prototype.updateContent = function (
      message: AssistantMessage,
      isStreaming = false,
    ): void {
      newController.render(this, message, isStreaming);
    };
  }

  const activeController = controller;
  // This function is deliberately replaced on every extension load. The wrapper above
  // survives /reload, but no implementation captured by an older source revision does.
  activeController.render = (component, message, isStreaming): void => {
    const prior = activeController.presentations.get(component);
    const sourceMessage = message === prior?.rendered ? prior.source : message;
    const state = component as unknown as AssistantMessagePresentationState;
    const hideThinking =
      calmPresentationHides("assistant-thinking") &&
      (state.hideThinkingBlock || prior?.streamed === true);
    const hideWorkingNote = calmPresentationHides("assistant-working-note");
    let renderedMessage = sourceMessage;

    // Streaming narration is presented by fm-calm.ts's one keyed widget. Keeping the
    // assistant component empty is what makes replacement robust even when this new
    // controller had to wrap the stale first-generation adapter in a live process.
    if (isStreaming && hideWorkingNote) {
      renderedMessage = { ...sourceMessage, content: [] };
    } else if (!isStreaming && (hideThinking || hideWorkingNote)) {
      const midTurn = isMidTurnAssistantMessage(sourceMessage);
      renderedMessage = {
        ...sourceMessage,
        content: sourceMessage.content.filter(
          (block) =>
            !(hideThinking && block.type === "thinking") &&
            !(hideWorkingNote && midTurn && block.type === "text"),
        ),
      };
    }

    activeController.presentations.set(component, {
      source: sourceMessage,
      rendered: renderedMessage,
      streamed: isStreaming || prior?.streamed === true,
    });
    // A first-generation wrapper did not forward isStreaming to Pi. Seed the same
    // private field Pi's own default argument reads, then pass the explicit value too.
    state.isStreaming = isStreaming;
    activeController.originalUpdateContent.call(component, renderedMessage, isStreaming);
  };
}
