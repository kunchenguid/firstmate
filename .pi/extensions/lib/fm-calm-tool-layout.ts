// Verified against Pi 0.82.1, which exports ToolExecutionComponent with declared render
// and updateResult methods and pi-tui's visibleWidth, truncateToWidth, and
// wrapTextWithAnsi column helpers. installCalmToolLayout() probes those exact members and
// throws if one is missing; fm-calm.ts catches that and skips only this adapter with a
// diagnostic instead of blocking Calm or Pi. It changes only transcript presentation and
// never tool execution.
//
// Pi routes abort, provider-failure, and tool-failure text exclusively through the tool
// row whenever the assistant turn contains a tool call
// (AssistantMessageComponent.updateContent skips its own error branch when
// hasToolCalls is true, and InteractiveMode attaches the stop-reason text to every
// pending tool row on both the live and rebuilt-transcript paths). So Calm keeps routine
// call, result, image, and shell content hidden while still surfacing an errored row's
// text as plain actionable lines, measured in terminal columns because pi-tui treats an
// over-wide rendered line as a fatal render error.
import type { ToolExecutionComponent as PiToolExecutionComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import * as PiTui from "@earendil-works/pi-tui";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

type CalmToolResult = {
  content?: Array<{ type?: string; text?: string }>;
  isError?: boolean;
};

type CalmColumnHelpers = {
  visibleWidth: (text: string) => number;
  truncateToWidth: (text: string, maxWidth: number, ellipsis?: string) => string;
  wrapTextWithAnsi: (text: string, width: number) => string[];
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-layout:pi-0.82.1",
);

const CALM_ERROR_MAX_LINES = 6;
const ANSI_SEQUENCE = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;
const TAB_COLUMNS = "   ";

const calmErrorTexts = new WeakMap<object, string>();
let calmErrorBatch: Map<string, object> | undefined;

function calmResultText(result: CalmToolResult): string {
  return (result.content ?? [])
    .filter((block) => block?.type === "text")
    .map((block) => (block.text ?? "").replace(ANSI_SEQUENCE, "").replace(/\r/g, ""))
    .join("\n")
    .trim();
}

// Pi attaches one turn's abort, provider-failure, or tool-failure text to every pending
// tool row in a single synchronous pass, so the first row to record a given text owns it
// and identical siblings from that pass stay silent instead of repeating it.
function calmErrorTextOwner(text: string, component: object): object {
  if (!calmErrorBatch) {
    calmErrorBatch = new Map();
    queueMicrotask(() => {
      calmErrorBatch = undefined;
    });
  }
  const owner = calmErrorBatch.get(text);
  if (owner) return owner;
  calmErrorBatch.set(text, component);
  return component;
}

function calmErrorLines(
  component: object,
  width: number,
  columns: CalmColumnHelpers,
): string[] {
  if (width <= 0) return [];
  const text = calmErrorTexts.get(component);
  if (!text) return [];

  const pad = width >= 2 ? " " : "";
  const usable = Math.max(1, width - pad.length);
  const clamp = (line: string): string => {
    if (!line) return "";
    const fitted =
      columns.visibleWidth(line) > usable
        ? columns.truncateToWidth(line, usable, "")
        : line;
    return `${pad}${fitted}`;
  };

  const wrapped: string[] = [];
  for (const logical of text.split("\n")) {
    if (!logical) {
      wrapped.push("");
      continue;
    }
    for (const line of columns.wrapTextWithAnsi(
      logical.replace(/\t/g, TAB_COLUMNS),
      usable,
    )) {
      wrapped.push(line);
    }
  }

  const skipped = Math.max(0, wrapped.length - CALM_ERROR_MAX_LINES);
  const shown = skipped > 0 ? wrapped.slice(-CALM_ERROR_MAX_LINES) : wrapped;
  const lines = shown.map(clamp);
  if (skipped > 0) {
    lines.unshift(
      clamp(`... ${skipped} earlier error line${skipped === 1 ? "" : "s"} hidden`),
    );
  }
  return ["", ...lines];
}

function requireColumnHelpers(): CalmColumnHelpers {
  const { truncateToWidth, visibleWidth, wrapTextWithAnsi } = PiTui;
  if (
    typeof visibleWidth !== "function" ||
    typeof truncateToWidth !== "function" ||
    typeof wrapTextWithAnsi !== "function"
  ) {
    throw new Error(
      "Firstmate Calm requires Pi TUI visibleWidth, truncateToWidth, and wrapTextWithAnsi",
    );
  }
  return { truncateToWidth, visibleWidth, wrapTextWithAnsi };
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
  const originalUpdateResult = ToolExecutionComponent.prototype.updateResult;
  if (typeof originalUpdateResult !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.updateResult");
  }
  const columns = requireColumnHelpers();

  ToolExecutionComponent.prototype.updateResult = function (
    this: PiToolExecutionComponent,
    result: Parameters<PiToolExecutionComponent["updateResult"]>[0],
    isPartial?: boolean,
  ): void {
    const errorResult = result as CalmToolResult;
    const errorText = errorResult?.isError && !isPartial ? calmResultText(errorResult) : "";
    if (errorText && calmErrorTextOwner(errorText, this) === this) {
      calmErrorTexts.set(this, errorText);
    } else {
      calmErrorTexts.delete(this);
    }
    originalUpdateResult.call(this, result, isPartial);
  };

  ToolExecutionComponent.prototype.render = function (
    this: PiToolExecutionComponent,
    width: number,
  ): string[] {
    if (patch.hidesToolRows()) {
      return calmErrorLines(this, width, columns);
    }
    return originalRender.call(this, width);
  };

  registry[CALM_TOOL_LAYOUT_PATCH] = patch;
}
