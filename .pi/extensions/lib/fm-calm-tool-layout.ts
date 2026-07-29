// Verified against Pi 0.82.1, which exports ToolExecutionComponent with declared render
// and updateResult methods and pi-tui's visibleWidth, truncateToWidth, and
// wrapTextWithAnsi column helpers. installCalmToolLayout() probes those exact members and
// throws if one is missing; fm-calm.ts catches that and skips only this adapter with a
// diagnostic instead of blocking Calm or Pi. It changes only transcript presentation and
// never tool execution.
//
// Pi routes an assistant turn's abort and provider-failure text exclusively through the
// tool row whenever that turn contains a tool call
// (AssistantMessageComponent.updateContent skips its own error branch when hasToolCalls is
// true, and InteractiveMode attaches the stop-reason text to every pending tool row on both
// the live and rebuilt-transcript paths). Only that turn-level class is actionable for the
// captain, so Calm surfaces an errored row's text only while its assistant turn stopped on
// "aborted" or "error" and keeps every routine failure - a non-zero bash exit, an unmatched
// edit, a missing read - hidden with the rest of the tool row. Visible lines are measured in
// terminal columns because pi-tui treats an over-wide rendered line as a fatal render error.
import type {
  AssistantMessageComponent as PiAssistantMessageComponent,
  ToolExecutionComponent as PiToolExecutionComponent,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import * as PiTui from "@earendil-works/pi-tui";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

type CalmErrorTurn = {
  component: object | undefined;
  actionable: boolean;
  owners: Map<string, object>;
};

type CalmTurnBoundaryPatch = {
  turn: CalmErrorTurn;
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
const CALM_TOOL_ERROR_TURN_PATCH = Symbol.for(
  "firstmate:calm-tool-error-turn:pi-0.82.1",
);

const CALM_ERROR_MAX_LINES = 6;
// The only stop reasons Pi fans out to tool rows as turn-level failure text.
const CALM_ACTIONABLE_STOP_REASONS = new Set(["aborted", "error"]);
const ANSI_SEQUENCE = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;
const TAB_COLUMNS = "   ";

const calmErrorTexts = new WeakMap<object, string>();

// The turn scope lives on the shared registry entry, never in module scope: Pi re-evaluates
// this module on every extension reload while the prototype wrappers installed by the first
// evaluation survive, so any module-scoped copy would diverge from the live one.
function calmTurnScope(): CalmTurnBoundaryPatch | undefined {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmTurnBoundaryPatch | undefined;
  };
  return registry[CALM_TOOL_ERROR_TURN_PATCH];
}

function calmEmptyTurn(): CalmErrorTurn {
  return { component: undefined, actionable: false, owners: new Map() };
}

function calmActionableTurn(message: { stopReason?: string } | undefined): boolean {
  return CALM_ACTIONABLE_STOP_REASONS.has(message?.stopReason ?? "");
}

function calmResultText(result: CalmToolResult): string {
  return (result.content ?? [])
    .filter((block) => block?.type === "text")
    .map((block) => (block.text ?? "").replace(ANSI_SEQUENCE, "").replace(/\r/g, ""))
    .join("\n")
    .trim();
}

// A row's error text is actionable only while its assistant turn stopped on "aborted" or
// "error"; every other errored result is a routine per-tool failure the agent handles itself,
// so it stays hidden with the rest of the row. Pi copies one actionable text onto every
// pending row of that turn, so the first row to record a given text within the turn owns it
// and identical siblings stay silent while a genuinely distinct text still gets its own row.
// Without the turn-boundary adapter no turn can be classified, so Calm stays conversation-only
// rather than guessing that a routine failure needs the captain.
function calmActionableErrorOwner(text: string, component: object): object | undefined {
  const scope = calmTurnScope();
  if (!scope || !scope.turn.actionable) return undefined;
  const owner = scope.turn.owners.get(text);
  if (owner) return owner;
  scope.turn.owners.set(text, component);
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

// Pi builds exactly one AssistantMessageComponent per assistant message, on the live
// streaming path and once per replayed history message, and calls updateContent on it
// repeatedly: from the constructor, from every streaming delta, from message_end once the
// stop reason is known, and again from invalidate(), setHideThinkingBlock(),
// setHiddenThinkingLabel(), and setOutputPad() - the last of which Calm itself triggers.
// So the reset is keyed on the calling component rather than the call: a new component opens
// a new turn, and every repeat call on the same component only refreshes that turn's stop
// reason, leaving established ownership intact. Pi never interleaves those repeats with a
// turn's updateResult batch, which stays synchronous on both paths.
export function installCalmToolErrorTurnBoundary(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmTurnBoundaryPatch | undefined;
  };
  const installed = registry[CALM_TOOL_ERROR_TURN_PATCH];
  if (installed) {
    installed.turn = calmEmptyTurn();
    return;
  }

  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    this: PiAssistantMessageComponent,
    message: Parameters<PiAssistantMessageComponent["updateContent"]>[0],
  ): void {
    const scope = calmTurnScope();
    if (scope) {
      const actionable = calmActionableTurn(message);
      if (scope.turn.component === this) {
        scope.turn.actionable = actionable;
      } else {
        scope.turn = { component: this, actionable, owners: new Map() };
      }
    }
    originalUpdateContent.call(this, message);
  };

  registry[CALM_TOOL_ERROR_TURN_PATCH] = { turn: calmEmptyTurn() };
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
    if (errorText && calmActionableErrorOwner(errorText, this) === this) {
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
