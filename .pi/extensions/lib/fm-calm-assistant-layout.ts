// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes live and historical step-source thinking from a shallow
// presentation copy while leaving assistant text on Pi's ordinary transcript surface.
// Toggling Calm cannot expose superseded steps, while the message itself, model context,
// session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmPresentationHides,
  calmStockExportRenderingIsActive,
} from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  isStreaming: boolean;
};

type CalmAssistantPresentation = {
  source: AssistantMessage;
  rendered: AssistantMessage;
  thinkingOwned: boolean;
};

type CalmAssistantLayoutController = {
  render: (
    component: PiAssistantMessageComponent,
    message: AssistantMessage,
    isStreaming: boolean,
  ) => void;
  originalUpdateContent: PiAssistantMessageComponent["updateContent"];
  presentations: WeakMap<object, CalmAssistantPresentation>;
  ownedThinkingMessages: WeakSet<object>;
};

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
      ownedThinkingMessages: new WeakSet(),
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
  // Controllers installed by the prior source revision survive Pi's hot reload.
  activeController.ownedThinkingMessages ??= new WeakSet();
  // This function is deliberately replaced on every extension load. The wrapper above
  // survives /reload, but no implementation captured by an older source revision does.
  activeController.render = (component, message, isStreaming): void => {
    const prior = activeController.presentations.get(component);
    const sourceMessage = message === prior?.rendered ? prior.source : message;
    const state = component as unknown as AssistantMessagePresentationState;
    const calmOwnsThinking = calmPresentationHides("assistant-thinking");
    const thinkingOwned =
      calmOwnsThinking ||
      prior?.thinkingOwned === true ||
      activeController.ownedThinkingMessages.has(sourceMessage);
    if (thinkingOwned) activeController.ownedThinkingMessages.add(sourceMessage);
    const hideThinking = thinkingOwned && !calmStockExportRenderingIsActive();
    const renderedMessage = hideThinking
      ? {
          ...sourceMessage,
          content: sourceMessage.content.filter((block) => block.type !== "thinking"),
        }
      : sourceMessage;

    activeController.presentations.set(component, {
      source: sourceMessage,
      rendered: renderedMessage,
      thinkingOwned,
    });
    // A first-generation wrapper did not forward isStreaming to Pi. Seed the same
    // private field Pi's own default argument reads, then pass the explicit value too.
    state.isStreaming = isStreaming;
    activeController.originalUpdateContent.call(component, renderedMessage, isStreaming);
  };
}
