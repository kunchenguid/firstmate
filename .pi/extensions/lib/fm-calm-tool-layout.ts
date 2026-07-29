// Verified against Pi 0.82.1, which exports ToolExecutionComponent with a render method.
// installCalmToolLayout() probes that exact method and throws if it is missing;
// fm-calm.ts catches that and skips only this adapter with a diagnostic instead of
// blocking Calm or Pi. It changes only transcript presentation and never tool execution.
import type { ToolExecutionComponent as PiToolExecutionComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-layout:pi-0.82.1",
);

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
    if (patch.hidesToolRows()) return [];
    return originalRender.call(this as PiToolExecutionComponent, width);
  };

  registry[CALM_TOOL_LAYOUT_PATCH] = patch;
}
