// Verified against Pi 0.81.1 through 0.87.1, which export ToolExecutionComponent and build
// every tool row - live, streamed, or restored - as one instance whose render(width)
// returns the row's lines. This adapter probes that exact method and throws if it is
// missing; fm-calm.ts catches that and skips only this adapter with a diagnostic instead of
// blocking Calm or Pi.
// It hides the built-in tool rows at that render seam and never registers a tool: Pi keeps
// one unmerged definition per tool name and treats a second extension's same-name claim as
// a fatal startup conflict, so claiming a built-in name would break, or silently replace,
// any other extension's own bash/read/... override. Whichever definition owns the tool
// keeps executing and rendering; Calm only decides whether its row is shown.
// Pi's HTML export renders tools from their definitions and never reaches this seam, so
// this adapter deliberately ignores the stock-export flag ./fm-calm-visibility.ts tracks:
// on-screen rows stay hidden through an export instead of flashing back into view.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmPresentationIsActive,
  calmTranscriptClassIsVisible,
} from "./fm-calm-visibility.ts";

// The Pi built-in tool names whose rows Calm hides. Other tools, including third-party
// ones, keep their own rows: Pi exposes no global renderer for them.
export const CALM_HIDDEN_BUILTIN_TOOL_NAMES: ReadonlySet<string> = new Set([
  "read",
  "bash",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);

type ToolRowPresentation = {
  toolName?: unknown;
  imageComponents?: unknown;
};
type ToolRowPrototype = {
  render(this: ToolRowPresentation, width: number): string[];
};
type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_LAYOUT_PATCH = Symbol.for("firstmate:calm-tool-layout:pi-0.81.1");

export function installCalmToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolLayoutPatch | undefined;
  };
  const hidesToolRows = (): boolean =>
    calmPresentationIsActive() &&
    !calmTranscriptClassIsVisible("assistant-tool-call") &&
    !calmTranscriptClassIsVisible("tool-result");
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
  const prototype = ToolExecutionComponent.prototype as unknown as ToolRowPrototype;
  const originalRender = prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }

  prototype.render = function (this: ToolRowPresentation, width: number): string[] {
    // A row carrying an image stays fully visible: the image is content Calm cannot
    // present on its own, and hiding only the text around it would leave a headless image.
    const hasImages = Array.isArray(this.imageComponents) && this.imageComponents.length > 0;
    if (
      patch.hidesToolRows() &&
      typeof this.toolName === "string" &&
      CALM_HIDDEN_BUILTIN_TOOL_NAMES.has(this.toolName) &&
      !hasImages
    ) {
      return [];
    }
    return originalRender.call(this, width);
  };

  registry[CALM_TOOL_LAYOUT_PATCH] = patch;
}
