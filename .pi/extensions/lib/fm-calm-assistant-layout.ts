// Calm's assistant presentation has one display-only contract with two Pi rendering
// seams. The supported Markdown transformer covers live streaming, restored history,
// terminal reflow, and bundled-class identity changes. The component projection removes
// the otherwise-empty thinking spacer on Pi versions that export the class used by the
// interactive UI. Both consume the same visibility state and only render shallow
// presentation copies; messages, model context, session storage, and exports are never
// changed. Calm paints the visible assistant range with a temporary muted dark purple
// background without changing its geometry.
import type {
  AssistantMessageComponent as PiAssistantMessageComponent,
  ExtensionAPI,
  MarkdownTransformContext,
  MarkdownTransformer,
  ToolExecutionComponent as PiToolExecutionComponent,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmOperationalRunIsActive,
  calmPresentationHides,
  calmStockExportRenderingIsActive,
} from "./fm-calm-visibility.ts";

const CALM_ASSISTANT_BACKGROUND = "\x1b[48;2;36;24;32m";
const stripTerminalSequences = (text: string): string =>
  text
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  isStreaming: boolean;
  operationalRun?: boolean;
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
  transform: MarkdownTransformer;
  originalUpdateContent: PiAssistantMessageComponent["updateContent"];
  originalRender?: PiAssistantMessageComponent["render"];
  assistantRender?: (component: PiAssistantMessageComponent, width: number) => string[];
  renderWrapper?: PiAssistantMessageComponent["render"];
  presentations: WeakMap<object, CalmAssistantPresentation>;
  ownedThinkingMessages: WeakSet<object>;
  ownedThinkingMarkdown: Set<string>;
};

// Keep the original symbol so a Pi process hot-reloading from the previous Calm source
// upgrades the implementation delegate captured by its already-installed wrapper.
const CALM_ASSISTANT_LAYOUT_CONTROLLER = Symbol.for(
  "firstmate:calm-assistant-layout-controller:pi-0.81.1",
);

type CalmToolLayoutController = {
  originalRender: PiToolExecutionComponent["render"];
  render: (component: PiToolExecutionComponent, width: number) => string[];
};

const CALM_TOOL_LAYOUT_CONTROLLER = Symbol.for(
  "firstmate:calm-tool-layout-controller:pi-0.85.1",
);

function installAssistantRenderBoundary(
  AssistantMessageComponent: typeof PiCodingAgent.AssistantMessageComponent,
  controller: CalmAssistantLayoutController,
): void {
  const prototypeRender = AssistantMessageComponent.prototype.render;
  if (!controller.originalRender) {
    if (typeof prototypeRender !== "function") {
      throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.render");
    }
    controller.originalRender = prototypeRender;
  }
  controller.assistantRender ??= (component, width) =>
    controller.originalRender!.call(component, width);
  controller.renderWrapper ??= function (width: number): string[] {
    return controller.assistantRender!(this, width);
  };
  if (prototypeRender !== controller.renderWrapper) {
    AssistantMessageComponent.prototype.render = controller.renderWrapper;
  }
}

export function installCalmAssistantLayout(
  pi: Pick<ExtensionAPI, "registerMarkdownTransformer">,
): void {
  if (typeof pi.registerMarkdownTransformer !== "function") {
    throw new Error("Firstmate Calm requires Pi registerMarkdownTransformer");
  }

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
      transform: (markdown) => markdown,
      originalUpdateContent,
      presentations: new WeakMap(),
      ownedThinkingMessages: new WeakSet(),
      ownedThinkingMarkdown: new Set(),
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
  installAssistantRenderBoundary(AssistantMessageComponent, activeController);
  // Controllers created by the prior source revision survive /reload and lack the two
  // Markdown fields. Upgrade them in place before replacing either delegate.
  activeController.ownedThinkingMessages ??= new WeakSet();
  activeController.ownedThinkingMarkdown ??= new Set();
  activeController.transform = (
    markdown: string,
    context: MarkdownTransformContext,
  ): string => {
    if (context.messageType !== "assistant-thinking") return markdown;
    if (calmStockExportRenderingIsActive()) return markdown;

    const hiddenNow = calmPresentationHides("assistant-thinking");
    if (hiddenNow) activeController.ownedThinkingMarkdown.add(markdown);
    return hiddenNow || activeController.ownedThinkingMarkdown.has(markdown) ? "" : markdown;
  };
  pi.registerMarkdownTransformer((markdown, context) =>
    activeController.transform(markdown, context),
  );

  activeController.assistantRender = (_component, width): string[] => {
    const lines = activeController.originalRender.call(_component, width);
    if (!calmPresentationHides("assistant-thinking") || lines.length === 0) return lines;
    return lines.map((line) =>
      stripTerminalSequences(line).trim() === ""
        ? line
        : `${CALM_ASSISTANT_BACKGROUND}${line}\x1b[49m`,
    );
  };

  activeController.render = (component, message, isStreaming): void => {
    const prior = activeController.presentations.get(component);
    const sourceMessage = message === prior?.rendered ? prior.source : message;
    const state = component as unknown as AssistantMessagePresentationState;
    const operationalRun = message === prior?.source
      ? state.operationalRun ?? calmOperationalRunIsActive()
      : calmOperationalRunIsActive();
    state.operationalRun = operationalRun;
    const hasToolCalls = sourceMessage.content.some((block) => block.type === "toolCall");
    const responseText = sourceMessage.content
      .filter((block) => block.type === "text")
      .map((block) => block.type === "text" ? block.text : "")
      .join("\n")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
    const isNoopAcknowledgement = responseText === "captain, shipshape.";
    const isCleanOperationalResponse =
      operationalRun &&
      sourceMessage.stopReason === "stop" &&
      !hasToolCalls &&
      Boolean(responseText) &&
      !isNoopAcknowledgement;
    const hideOperationalTurn =
      isNoopAcknowledgement || (operationalRun && !isCleanOperationalResponse);
    const operationalMessage = hideOperationalTurn
      ? { ...sourceMessage, content: [], stopReason: undefined, errorMessage: undefined }
      : operationalRun
        ? {
            ...sourceMessage,
            content: sourceMessage.content.filter((block) => block.type === "text"),
            errorMessage: undefined,
          }
        : sourceMessage;
    const calmOwnsThinking = calmPresentationHides("assistant-thinking");
    const thinkingOwned =
      calmOwnsThinking ||
      prior?.thinkingOwned === true ||
      activeController.ownedThinkingMessages.has(sourceMessage);
    if (thinkingOwned) activeController.ownedThinkingMessages.add(sourceMessage);
    const hideThinking = thinkingOwned && !calmStockExportRenderingIsActive();
    const presentationMessage = hideOperationalTurn || operationalRun
      ? operationalMessage
      : hideThinking
        ? {
            ...sourceMessage,
            content: sourceMessage.content.filter((block) => block.type !== "thinking"),
          }
        : sourceMessage;
    const renderedMessage = presentationMessage;

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

// ToolExecutionComponent is Pi's single interactive row for model tool calls,
// arguments, results, timing/collapsed shells, custom renderers, and result images.
// Hiding at its render boundary covers live and restored rows regardless of which tool
// definition created them, without changing execution, messages, storage, or exports.
export function installCalmToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolLayoutController | undefined;
  };
  const ToolExecutionComponent = PiCodingAgent.ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent");
  }

  let controller = registry[CALM_TOOL_LAYOUT_CONTROLLER];
  if (!controller) {
    const originalRender = ToolExecutionComponent.prototype.render;
    if (typeof originalRender !== "function") {
      throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
    }
    const newController: CalmToolLayoutController = {
      originalRender,
      render: () => [],
    };
    controller = newController;
    registry[CALM_TOOL_LAYOUT_CONTROLLER] = newController;
    ToolExecutionComponent.prototype.render = function (width: number): string[] {
      return newController.render(this, width);
    };
  }

  const activeController = controller;
  activeController.render = (component, width): string[] => {
    const hidden =
      calmPresentationHides("assistant-tool-call") ||
      calmPresentationHides("tool-result") ||
      calmPresentationHides("tool-image");
    if (hidden) return [];
    return activeController.originalRender.call(component, width);
  };
}
