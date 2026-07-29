// Verified against Pi 0.82.1, which exports ToolExecutionComponent with a render method.
// installCalmToolLayout() probes that exact method and throws if it is missing;
// fm-calm.ts catches that and skips only this adapter with a diagnostic instead of
// blocking Calm or Pi. It changes only transcript presentation and never tool execution.
//
// Pi routes abort, provider-failure, and tool-failure text exclusively through the tool
// row whenever the assistant turn contains a tool call
// (AssistantMessageComponent.updateContent skips its own error branch when
// hasToolCalls is true, and InteractiveMode attaches the stop-reason text to every
// pending tool row on both the live and rebuilt-transcript paths). So Calm keeps routine
// call, result, image, and shell content hidden while still surfacing an errored row's
// text as plain actionable lines.
import type { ToolExecutionComponent as PiToolExecutionComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

type CalmToolRowState = {
  result?: {
    content?: Array<{ type?: string; text?: string }>;
    isError?: boolean;
  };
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-layout:pi-0.82.1",
);

const CALM_ERROR_MAX_LINES = 6;
const ANSI_SEQUENCE = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;

function calmErrorText(state: CalmToolRowState): string {
  const result = state.result;
  if (!result?.isError) return "";
  return (result.content ?? [])
    .filter((block) => block?.type === "text")
    .map((block) => (block.text ?? "").replace(ANSI_SEQUENCE, "").replace(/\r/g, ""))
    .join("\n")
    .trim();
}

function calmErrorLines(state: CalmToolRowState, width: number): string[] {
  const text = calmErrorText(state);
  if (!text) return [];

  const usable = Math.max(1, width - 1);
  const wrapped: string[] = [];
  for (const line of text.split("\n")) {
    if (!line) {
      wrapped.push("");
      continue;
    }
    for (let index = 0; index < line.length; index += usable) {
      wrapped.push(line.slice(index, index + usable));
    }
  }

  const skipped = Math.max(0, wrapped.length - CALM_ERROR_MAX_LINES);
  const shown = skipped > 0 ? wrapped.slice(-CALM_ERROR_MAX_LINES) : wrapped;
  const lines = shown.map((line) => (line ? ` ${line}` : ""));
  if (skipped > 0) {
    lines.unshift(` ... ${skipped} earlier error line${skipped === 1 ? "" : "s"} hidden`);
  }
  return ["", ...lines];
}

export function installCalmToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolLayoutPatch | undefined;
  };
  const hidesToolRows = (): boolean =>
    calmPresentationHides("assistant-tool-call") &&
    calmPresentationHides("tool-result");
  const installed = registry[CALM_TOOL_LAYOUT_PATCH];
  if (installed) {
    installed.hidesToolRows = hidesToolRows;
    return;
  }

  const patch: CalmToolLayoutPatch = { hidesToolRows };
  const ToolExecutionComponent = PiCodingAgent.ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent");
  }
  const originalRender = ToolExecutionComponent.prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }

  ToolExecutionComponent.prototype.render = function (
    width: number,
  ): string[] {
    if (patch.hidesToolRows()) {
      return calmErrorLines(this as unknown as CalmToolRowState, width);
    }
    return originalRender.call(this as PiToolExecutionComponent, width);
  };

  registry[CALM_TOOL_LAYOUT_PATCH] = patch;
}
