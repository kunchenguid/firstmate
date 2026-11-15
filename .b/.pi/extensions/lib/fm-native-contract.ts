import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";

// Public Pi event-bus boundary for native-harness adapters. FirstMate owns the
// operational message allowlist and these tools; the adapter owns transport.
// Discovery is synchronous: emit { register(tool), allowMessageType(type) } on
// firstmate:native-tools. Only explicitly registered FirstMate controls cross
// this boundary, with the SAME execute callback and ownership checks as Pi.
// The native adapter supplies its current ExtensionContext when executing.
// Pi owns subscription cleanup with the extension runtime, including reload.
export function registerFirstmateTool<TParams extends TSchema, TDetails, TState>(
  pi: ExtensionAPI,
  tool: ToolDefinition<TParams, TDetails, TState>,
): void {
  pi.registerTool?.(tool);
  pi.events?.on?.("firstmate:native-tools", (request: unknown) => {
    if (!request || typeof request !== "object") return;
    const discovery = request as {
      register?: (tool: unknown) => void;
      allowMessageType?: (type: string) => void;
    };
    if (typeof discovery.register === "function") {
      discovery.register({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.parameters,
        execute: tool.execute,
      });
    }
    if (typeof discovery.allowMessageType === "function") {
      for (const type of ["firstmate-sessionstart-nudge", "fm-branch-merge", "fm-branch-process"]) {
        discovery.allowMessageType(type);
      }
    }
  });
}
