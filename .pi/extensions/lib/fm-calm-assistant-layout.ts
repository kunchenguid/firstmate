// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes collapsed thinking and short mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy. Substantive
// mid-turn text is preserved. The message
// itself, model context, session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmTextIsSubstantive } from "./fm-calm-preservation.ts";
import {
  calmOperationalRunIsActive,
  calmPresentationHides,
} from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
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
  activeComponent?: object;
  runFinalized?: boolean;
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

function appendLatestCalmStep(message: AssistantMessage, isStreaming: boolean): void {
  if (!isStreaming || !calmPresentationHides("assistant-thinking")) return;
  for (let index = message.content.length - 1; index >= 0; index -= 1) {
    const block = message.content[index];
    if (block.type !== "thinking") continue;
    const line = block.thinking
      .split(/\r?\n/)
      .map((value) => value.trim())
      .filter(Boolean)
      .at(-1);
    if (!line) return;
    appendCalmStep(line.match(/^\*\*(.+)\*\*$/)?.[1] ?? line);
    return;
  }
}

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

function calmStepsPresentation(
  message: AssistantMessage,
  component: object,
  controller: CalmAssistantLayoutController,
): AssistantMessage {
  if (calmStockExportRenderingIsActive() || controller.activeComponent !== component) return message;
  const steps = currentCalmSteps();
  if (!calmPresentationHides("assistant-thinking") || steps.length === 0) return message;
  const stepLines = steps.map((step, index) => `Step ${index + 1}: ${step}`).join("  \n");
  return {
    ...message,
    content: [
      { type: "text", text: stepLines },
      ...message.content,
    ],
  };
}

function visibleWidth(text: string): number {
  return Array.from(stripTerminalSequences(text)).length;
}

function clipText(text: string, width: number): string {
  return Array.from(text).slice(0, Math.max(0, width)).join("");
}

function renderCalmStepLine(step: string, index: number, width: number, active: boolean, indent: string): string {
  const available = Math.max(0, width - visibleWidth(indent));
  const fixed = `Step ${index + 1}: ${step}`;
  const activityWidth = available - visibleWidth(fixed) - 2;
  const clippedFixed = clipText(fixed, available);
  const tickerText = active ? calmTickerText(Math.max(0, activityWidth)) : "";
  const ticker = activityWidth >= 8 ? tickerText : "";
  const detail = ticker === "" ? "" : `  \x1b[2m${CALM_ACTIVITY_FOREGROUND}${ticker}`;
  return `${indent}${CALM_STEP_FOREGROUND}${clippedFixed}${detail}\x1b[0m`;
}

function renderCalmSteps(
  lines: string[],
  width: number,
  steps: readonly string[],
  active: boolean,
): string[] {
  if (steps.length === 0) return lines;
  const rendered = [...lines];
  let searchFrom = 0;
  for (let index = 0; index < steps.length; index += 1) {
    const marker = `Step ${index + 1}:`;
    const lineIndex = rendered.findIndex((line, candidate) => {
      if (candidate < searchFrom) return false;
      return stripTerminalSequences(line).trimStart().startsWith(marker);
    });
    if (lineIndex < 0) continue;
    const plain = stripTerminalSequences(rendered[lineIndex]);
    const indent = plain.slice(0, plain.length - plain.trimStart().length);
    rendered[lineIndex] = renderCalmStepLine(steps[index]!, index, width, active && index === steps.length - 1, indent);
    searchFrom = lineIndex + 1;
  }
  const lastMarker = `Step ${steps.length}:`;
  const lastStep = rendered.findIndex((line, candidate) =>
    candidate >= searchFrom - 1 && stripTerminalSequences(line).trimStart().startsWith(lastMarker),
  );
  if (lastStep < 0) return rendered;
  let next = lastStep + 1;
  while (next < rendered.length && stripTerminalSequences(rendered[next]!).trim() === "") next += 1;
  if (next === rendered.length) return rendered;
  rendered.splice(lastStep + 1, next - lastStep - 1, "");
  return rendered;
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

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // Pi reuses the same component while one assistant message streams and
    // later invalidates it when Calm toggles. Capture the operational origin
    // on first render so a later captain prompt cannot make an old private row
    // visible during a redraw or reload.
    const operationalRun = state.lastMessage === message
      ? state.operationalRun ?? calmOperationalRunIsActive()
      : calmOperationalRunIsActive();
    state.operationalRun = operationalRun;
    const hasToolCalls = message.content.some((block) => block.type === "toolCall");
    const responseText = message.content
      .filter((block) => block.type === "text")
      .map((block) => block.type === "text" ? block.text : "")
      .join("\n")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
    const isCleanOperationalResponse =
      operationalRun &&
      message.stopReason === "stop" &&
      !hasToolCalls &&
      Boolean(responseText) &&
      responseText !== "captain, shipshape.";
    const hideOperationalTurn = operationalRun && !isCleanOperationalResponse;
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() &&
      isMidTurnAssistantMessage(message) &&
      message.content.some(
        (block) => block.type === "text" && !calmTextIsSubstantive(block.text),
      );
    const presentationMessage = hideOperationalTurn
      ? { ...message, content: [], stopReason: undefined, errorMessage: undefined }
      : operationalRun
        ? {
            ...message,
            content: message.content.filter((block) => block.type === "text"),
            errorMessage: undefined,
          }
        : hideThinking || hideWorkingNote
          ? {
              ...message,
              content: message.content.filter(
                (block) =>
                  !(hideThinking && block.type === "thinking") &&
                  !(
                    hideWorkingNote &&
                    block.type === "text" &&
                    !calmTextIsSubstantive(block.text)
                  ),
              ),
            }
          : message;

    const hiddenNow = calmPresentationHides("assistant-thinking");
    if (hiddenNow) activeController.ownedThinkingMarkdown.add(markdown);
    return hiddenNow || activeController.ownedThinkingMarkdown.has(markdown) ? "" : markdown;
  };
  pi.registerMarkdownTransformer((markdown, context) =>
    activeController.transform(markdown, context),
  );

  activeController.assistantRender = (component, width): string[] => {
    const lines = activeController.originalRender.call(component, width);
    if (!calmPresentationHides("assistant-thinking") || lines.length === 0) return lines;

    const stepLines = renderCalmSteps(
      lines,
      width,
      currentCalmSteps(),
      activeController.runFinalized !== true,
    );
    let firstVisible = -1;
    let lastVisible = -1;
    for (let index = 0; index < stepLines.length; index += 1) {
      if (stripTerminalSequences(stepLines[index]).trim() !== "") {
        if (firstVisible === -1) firstVisible = index;
        lastVisible = index;
      }
    }
    if (firstVisible === -1) return stepLines;
    return stepLines.map((line, index) =>
      index >= firstVisible && index <= lastVisible
        ? `${CALM_ASSISTANT_BACKGROUND}${line}\x1b[49m`
        : line,
    );
  };

  activeController.render = (component, message, isStreaming): void => {
    if (isStreaming) {
      if (currentCalmSteps().length === 0) activeController.runFinalized = false;
      activeController.activeComponent = component;
    } else if (
      !activeController.runFinalized &&
      currentCalmSteps().length > 0 &&
      (message.stopReason === "stop" || message.stopReason === "length")
    ) {
      activeController.activeComponent = component;
      activeController.runFinalized = true;
    }
    appendLatestCalmStep(message, isStreaming);
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
    const presentationMessage = hideThinking
      ? {
          ...sourceMessage,
          content: sourceMessage.content.filter((block) => block.type !== "thinking"),
        }
      : sourceMessage;
    const renderedMessage = calmStepsPresentation(presentationMessage, component, activeController);

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
    if (hidden) {
      const source = component as unknown as {
        toolName?: unknown;
        args?: unknown;
        cwd?: unknown;
        ui?: { requestRender?: () => void };
      };
      setCalmRenderRequester(source.ui?.requestRender?.bind(source.ui));
      appendCalmActivity(calmActivityForTool(source.toolName, source.args, source.cwd));
      return [];
    }
    return activeController.originalRender.call(component, width);
  };
}
