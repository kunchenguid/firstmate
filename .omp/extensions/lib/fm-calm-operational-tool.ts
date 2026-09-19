// OMP presentation adapter that zero-height-renders Firstmate operational
// ceremony tool rows (watcher / drain / FIRSTMATE_OP) while Calm is on.
//
// Verified against omp 18.1.17, which exports ToolExecutionComponent with render
// from @oh-my-pi/pi-coding-agent. This adapter probes that exact seam and throws
// if it is missing so fm-calm.ts can skip only this adapter with a diagnostic.
// It changes presentation only: tool execution, arguments, results, model
// context, and session storage stay untouched, ordinary tools render unchanged,
// and Calm off restores every row.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type ToolExecutionComponentLike = {
  render(width: number): string[];
};

type CalmOperationalToolPatch = {
  hidesOperationalTool: () => boolean;
};

const CALM_OPERATIONAL_TOOL_PATCH = Symbol.for(
  "firstmate:calm-operational-tool:omp-18.1.17",
);

const ANSI_ESCAPE = /\x1b\[[0-9;]*m/g;

// The Firstmate operational invocation family Calm hides from the OMP
// transcript. Ordinary tools (builds, reads, tests) never match these markers.
const OPERATIONAL_TOOL_MARKERS = [
  "FIRSTMATE_OP",
  "fm-wake-drain.sh",
  "fm-watch.sh",
  "fm-watch-arm.sh",
];

function rendersOperationalCeremony(lines: readonly string[]): boolean {
  for (const line of lines) {
    const text = line.replace(ANSI_ESCAPE, "");
    for (const marker of OPERATIONAL_TOOL_MARKERS) {
      if (text.includes(marker)) return true;
    }
  }
  return false;
}

export function installOmpCalmOperationalToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalToolPatch | undefined;
  };
  const hidesOperationalTool = (): boolean =>
    calmPresentationHides("assistant-tool-call") || calmPresentationHides("tool-result");
  const installed = registry[CALM_OPERATIONAL_TOOL_PATCH];
  if (installed) {
    installed.hidesOperationalTool = hidesOperationalTool;
    return;
  }

  const ToolExecutionComponent = (OmpCodingAgent as { ToolExecutionComponent?: unknown })
    .ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent");
  }
  const prototype = (ToolExecutionComponent as { prototype: ToolExecutionComponentLike })
    .prototype;
  const stockRender = prototype.render;
  if (typeof stockRender !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.render");
  }

  const patch: CalmOperationalToolPatch = { hidesOperationalTool };
  prototype.render = function (this: ToolExecutionComponentLike, width: number): string[] {
    const lines = stockRender.call(this, width);
    if (patch.hidesOperationalTool() && rendersOperationalCeremony(lines)) return [];
    return lines;
  };

  registry[CALM_OPERATIONAL_TOOL_PATCH] = patch;
}
